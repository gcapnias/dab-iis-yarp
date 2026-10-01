using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Encodings.Web;
using System.Text.Json;

using IdentityIssuer;

using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

namespace IdentityIssuer.Tests;

public sealed class IdentityIssuerHttpTests : IClassFixture<IdentityIssuerFactory>
{
    private readonly HttpClient client;

    public IdentityIssuerHttpTests(IdentityIssuerFactory factory)
    {
        client = factory.CreateClient(new WebApplicationFactoryClientOptions { HandleCookies = true, AllowAutoRedirect = false });
        client.BaseAddress = new Uri("https://localhost");
    }

    [Fact]
    public async Task Only_discovery_and_signing_keys_are_anonymous()
    {
        using var discovery = new HttpRequestMessage(HttpMethod.Get, "/.well-known/openid-configuration");
        discovery.Headers.Add("X-Test-Anonymous", "true");
        using var discoveryResponse = await client.SendAsync(discovery);
        Assert.Equal(HttpStatusCode.OK, discoveryResponse.StatusCode);

        using var jwks = new HttpRequestMessage(HttpMethod.Get, "/.well-known/jwks.json");
        jwks.Headers.Add("X-Test-Anonymous", "true");
        using var jwksResponse = await client.SendAsync(jwks);
        Assert.Equal(HttpStatusCode.OK, jwksResponse.StatusCode);

        using var csrf = new HttpRequestMessage(HttpMethod.Get, "/csrf");
        csrf.Headers.Add("X-Test-Anonymous", "true");
        using var csrfResponse = await client.SendAsync(csrf);
        Assert.Equal(HttpStatusCode.Unauthorized, csrfResponse.StatusCode);

        using var session = new HttpRequestMessage(HttpMethod.Post, "/session");
        session.Headers.Add("X-Test-Anonymous", "true");
        using var sessionResponse = await client.SendAsync(session);
        Assert.Equal(HttpStatusCode.Unauthorized, sessionResponse.StatusCode);
    }

    [Fact]
    public async Task Discovery_publishes_the_issuer_and_public_key_used_to_verify_session_tokens()
    {
        using var discoveryResponse = await client.GetAsync("/.well-known/openid-configuration");
        Assert.True(discoveryResponse.IsSuccessStatusCode, await discoveryResponse.Content.ReadAsStringAsync());
        using var discovery = JsonDocument.Parse(await discoveryResponse.Content.ReadAsStringAsync());
        Assert.Equal("https://issuer.example.test", discovery.RootElement.GetProperty("issuer").GetString());
        Assert.Equal("https://issuer.example.test/.well-known/jwks.json", discovery.RootElement.GetProperty("jwks_uri").GetString());

        using var keyResponse = await client.GetAsync("/.well-known/jwks.json");
        Assert.True(keyResponse.IsSuccessStatusCode, await keyResponse.Content.ReadAsStringAsync());
        using var keys = JsonDocument.Parse(await keyResponse.Content.ReadAsStringAsync());
        Assert.Equal(1, keys.RootElement.GetProperty("keys").GetArrayLength());
        Assert.False(keys.RootElement.GetProperty("keys")[0].TryGetProperty("d", out _));
    }

    [Fact]
    public async Task IdentityModel_retrieves_discovery_and_validates_the_issued_token_with_published_keys()
    {
        var issuer = "https://issuer.example.test";
        using var retrievalClient = new HttpClient(new TestServerForwarder(client));
        var documentRetriever = new HttpDocumentRetriever(retrievalClient) { RequireHttps = true };
        var manager = new ConfigurationManager<OpenIdConnectConfiguration>(
            issuer + "/.well-known/openid-configuration",
            new OpenIdConnectConfigurationRetriever(),
            documentRetriever);

        var configuration = await manager.GetConfigurationAsync(CancellationToken.None);
        Assert.Equal(issuer, configuration.Issuer);
        Assert.Contains(configuration.SigningKeys, key => key.KeyId == "test-key");

        using var csrfResponse = await client.GetAsync("/csrf");
        using var csrf = JsonDocument.Parse(await csrfResponse.Content.ReadAsStringAsync());
        using var session = new HttpRequestMessage(HttpMethod.Post, "/session");
        session.Headers.Add("X-CSRF-TOKEN", csrf.RootElement.GetProperty("requestToken").GetString());
        using var sessionResponse = await client.SendAsync(session);
        Assert.Equal(HttpStatusCode.NoContent, sessionResponse.StatusCode);
        var cookie = Assert.Single(sessionResponse.Headers.GetValues("Set-Cookie"));
        var token = cookie.Split(';')[0]["dab_access_token=".Length..];

        var validator = new JwtSecurityTokenHandler { MapInboundClaims = false };
        var validation = new TokenValidationParameters
        {
            ValidIssuer = issuer,
            ValidAudience = "api://northwind-dab",
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            IssuerSigningKeys = configuration.SigningKeys,
            ValidAlgorithms = [SecurityAlgorithms.RsaSha256],
            ClockSkew = TimeSpan.Zero
        };
        var principal = validator.ValidateToken(token, validation, out var validatedToken);
        Assert.Equal("test-user", principal.FindFirst("sub")?.Value);
        Assert.Equal("test-key", Assert.IsType<JwtSecurityToken>(validatedToken).Header.Kid);

        var tokenParts = token.Split('.');
        tokenParts[2] = tokenParts[2][..^1] + (tokenParts[2][^1] == 'A' ? 'B' : 'A');
        Assert.ThrowsAny<SecurityTokenException>(() => validator.ValidateToken(string.Join('.', tokenParts), validation, out _));
    }

    [Fact]
    public async Task Session_requires_antiforgery_and_issues_an_expiring_secure_cookie_then_logout_clears_it()
    {
        using var csrfResponse = await client.GetAsync("/csrf");
        Assert.True(csrfResponse.IsSuccessStatusCode, await csrfResponse.Content.ReadAsStringAsync());
        using var csrf = JsonDocument.Parse(await csrfResponse.Content.ReadAsStringAsync());
        var requestToken = csrf.RootElement.GetProperty("requestToken").GetString()!;

        using var rejected = await client.PostAsync("/session", new StringContent(string.Empty));
        Assert.NotEqual(HttpStatusCode.NoContent, rejected.StatusCode);

        using var create = new HttpRequestMessage(HttpMethod.Post, "/session");
        create.Headers.Add("X-CSRF-TOKEN", requestToken);
        using var created = await client.SendAsync(create);
        Assert.Equal(HttpStatusCode.NoContent, created.StatusCode);
        var issuedCookie = Assert.Single(created.Headers.GetValues("Set-Cookie"));
        Assert.Contains("dab_access_token=", issuedCookie, StringComparison.Ordinal);
        Assert.Contains("httponly", issuedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", issuedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("samesite=lax", issuedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("expires=", issuedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("path=/", issuedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("domain=", issuedCookie, StringComparison.OrdinalIgnoreCase);
        var expiryAttribute = issuedCookie.Split(';').Single(attribute => attribute.TrimStart().StartsWith("expires=", StringComparison.OrdinalIgnoreCase)).Trim();
        var expiration = DateTimeOffset.Parse(expiryAttribute["expires=".Length..]);
        Assert.InRange(expiration, DateTimeOffset.UtcNow.AddMinutes(9), DateTimeOffset.UtcNow.AddMinutes(11));

        var compactJwt = issuedCookie.Split(';')[0]["dab_access_token=".Length..];
        using var payload = JsonDocument.Parse(Decode(compactJwt.Split('.')[1]));
        Assert.Equal("test-user", payload.RootElement.GetProperty("sub").GetString());
        Assert.Equal("catalog-profile-1", payload.RootElement.GetProperty("profile_id").GetString());
        Assert.Equal("Fixture User", payload.RootElement.GetProperty("name").GetString());
        Assert.Equal("catalog.reader", payload.RootElement.GetProperty("roles")[0].GetString());

        using var rejectedLogout = await client.PostAsync("/session/logout", new StringContent(string.Empty));
        Assert.Equal(HttpStatusCode.BadRequest, rejectedLogout.StatusCode);

        using var logout = new HttpRequestMessage(HttpMethod.Post, "/session/logout");
        logout.Headers.Add("X-CSRF-TOKEN", requestToken);
        using var loggedOut = await client.SendAsync(logout);
        Assert.Equal(HttpStatusCode.NoContent, loggedOut.StatusCode);
        var deletedCookie = Assert.Single(loggedOut.Headers.GetValues("Set-Cookie"));
        Assert.Contains("dab_access_token=", deletedCookie, StringComparison.Ordinal);
        Assert.Contains("expires=thu, 01 jan 1970", deletedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", deletedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("httponly", deletedCookie, StringComparison.OrdinalIgnoreCase);
    }

    private static byte[] Decode(string value)
    {
        var base64 = value.Replace('-', '+').Replace('_', '/');
        return Convert.FromBase64String(base64.PadRight(base64.Length + ((4 - base64.Length % 4) % 4), '='));
    }
}

public sealed class TestServerForwarder(HttpClient testServerClient) : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using var forwarded = new HttpRequestMessage(request.Method, request.RequestUri!.PathAndQuery);
        using var response = await testServerClient.SendAsync(forwarded, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        return new HttpResponseMessage(response.StatusCode)
        {
            Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json")
        };
    }
}

public sealed class IdentityIssuerFactory : WebApplicationFactory<Program>
{
    private const string TestScheme = "issuer-test";
    private readonly string keyPath;
    private readonly Dictionary<string, string?> previousEnvironment = new(StringComparer.OrdinalIgnoreCase);

    public IdentityIssuerFactory()
    {
        using var key = RSA.Create(2048);
        keyPath = Path.Combine(Path.GetTempPath(), $"identity-issuer-test-{Guid.NewGuid():N}.pem");
        File.WriteAllText(keyPath, key.ExportPkcs8PrivateKeyPem());
        SetEnvironment("Issuer__Url", "https://issuer.example.test");
        SetEnvironment("Issuer__Audience", "api://northwind-dab");
        SetEnvironment("Issuer__KeyId", "test-key");
        SetEnvironment("Issuer__SigningKeyPath", keyPath);
        SetEnvironment("Issuer__LifetimeMinutes", "10");
        SetEnvironment("WindowsAuthentication__Mode", "IIS");
        SetEnvironment("ConnectionStrings__IssuerIdentity", "Server=localhost;Database=northwind;Integrated Security=true;Encrypt=true;TrustServerCertificate=true");
    }

    private void SetEnvironment(string name, string value)
    {
        previousEnvironment[name] = Environment.GetEnvironmentVariable(name);
        Environment.SetEnvironmentVariable(name, value);
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Development");
        builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Issuer:Url"] = "https://issuer.example.test",
            ["Issuer:Audience"] = "api://northwind-dab",
            ["Issuer:KeyId"] = "test-key",
            ["Issuer:SigningKeyPath"] = keyPath,
            ["Issuer:LifetimeMinutes"] = "10",
            ["WindowsAuthentication:Mode"] = "IIS",
            ["ConnectionStrings:IssuerIdentity"] = "Server=localhost;Database=northwind;Integrated Security=true;Encrypt=true;TrustServerCertificate=true"
        }));
        builder.ConfigureTestServices(services =>
        {
            services.AddAuthentication(options =>
            {
                options.DefaultAuthenticateScheme = TestScheme;
                options.DefaultChallengeScheme = TestScheme;
                options.DefaultForbidScheme = TestScheme;
            }).AddScheme<AuthenticationSchemeOptions, TestAuthenticationHandler>(TestScheme, _ => { });
            services.RemoveAll<IIdentityDirectory>();
            services.AddSingleton<IIdentityDirectory>(new FixtureIdentityDirectory());
        });
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing)
        {
            foreach (var (name, value) in previousEnvironment)
                Environment.SetEnvironmentVariable(name, value);
            if (File.Exists(keyPath)) File.Delete(keyPath);
        }
    }
}

public sealed class TestAuthenticationHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (Request.Headers.ContainsKey("X-Test-Anonymous"))
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        var identity = new ClaimsIdentity([new Claim(ClaimTypes.PrimarySid, "S-1-5-21-10-20-30-1001")], Scheme.Name);
        var ticket = new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name);
        return Task.FromResult(AuthenticateResult.Success(ticket));
    }
}

public sealed class FixtureIdentityDirectory : IIdentityDirectory
{
    public Task<IdentityProfile?> FindByWindowsSidAsync(string sid, CancellationToken cancellationToken)
    {
        IdentityProfile? profile = sid == "S-1-5-21-10-20-30-1001"
            ? new IdentityProfile(sid, "test-user", "catalog-profile-1", "Fixture User", ["catalog.reader"])
            : null;
        return Task.FromResult(profile);
    }
}