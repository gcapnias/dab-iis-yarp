using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Encodings.Web;
using System.Text.Json;

using IdentityIssuer;

using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

namespace IdentityIssuer.Tests;

public sealed class IdentityIssuerHttpTests : IClassFixture<IdentityIssuerFactory>
{
    private readonly HttpClient client;
    private readonly IdentityIssuerFactory factory;

    public IdentityIssuerHttpTests(IdentityIssuerFactory factory)
    {
        this.factory = factory;
        client = factory.CreateClient(new WebApplicationFactoryClientOptions { HandleCookies = true, AllowAutoRedirect = false });
        client.BaseAddress = new Uri("https://issuer.example.test");
    }

    [Fact]
    public async Task Only_discovery_and_signing_keys_are_anonymous()
    {
        using var discovery = new HttpRequestMessage(HttpMethod.Get, "/.well-known/openid-configuration");
        discovery.Headers.Add("X-Test-Anonymous", "true");
        using var discoveryResponse = await client.SendAsync(discovery);
        Assert.Equal(HttpStatusCode.OK, discoveryResponse.StatusCode);

        using var jwks = new HttpRequestMessage(HttpMethod.Get, "/.well-known/jwks");
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
        Assert.Equal("https://issuer.example.test/", discovery.RootElement.GetProperty("issuer").GetString());
        Assert.Equal("https://issuer.example.test/.well-known/jwks", discovery.RootElement.GetProperty("jwks_uri").GetString());
        Assert.Contains("code", discovery.RootElement.GetProperty("response_types_supported").EnumerateArray().Select(value => value.GetString()));
        Assert.Contains("authorization_code", discovery.RootElement.GetProperty("grant_types_supported").EnumerateArray().Select(value => value.GetString()));
        Assert.Contains("refresh_token", discovery.RootElement.GetProperty("grant_types_supported").EnumerateArray().Select(value => value.GetString()));
        Assert.Contains("public", discovery.RootElement.GetProperty("subject_types_supported").EnumerateArray().Select(value => value.GetString()));
        Assert.Contains("RS256", discovery.RootElement.GetProperty("id_token_signing_alg_values_supported").EnumerateArray().Select(value => value.GetString()));
        var supportedClaims = discovery.RootElement.GetProperty("claims_supported").EnumerateArray().Select(value => value.GetString()).ToArray();
        Assert.Contains("role", supportedClaims);
        Assert.Contains("profile_id", supportedClaims);
        Assert.Contains("ClearanceLevel", supportedClaims);
        Assert.Contains("https://issuer.example.test/connect/authorize", discovery.RootElement.GetProperty("authorization_endpoint").GetString());
        Assert.Contains("https://issuer.example.test/connect/token", discovery.RootElement.GetProperty("token_endpoint").GetString());

        using var keyResponse = await client.GetAsync(discovery.RootElement.GetProperty("jwks_uri").GetString());
        Assert.True(keyResponse.IsSuccessStatusCode, await keyResponse.Content.ReadAsStringAsync());
        using var keys = JsonDocument.Parse(await keyResponse.Content.ReadAsStringAsync());
        Assert.Equal(2, keys.RootElement.GetProperty("keys").GetArrayLength());
        Assert.All(keys.RootElement.GetProperty("keys").EnumerateArray(), key => Assert.False(key.TryGetProperty("d", out _)));
        Assert.Contains(keys.RootElement.GetProperty("keys").EnumerateArray(), key => key.GetProperty("kid").GetString() == "previous-test-key");
    }

    [Fact]
    public async Task IdentityModel_retrieves_discovery_and_validates_the_issued_token_with_published_keys()
    {
        var issuer = "https://issuer.example.test/";
        using var retrievalClient = new HttpClient(new TestServerForwarder(client));
        var documentRetriever = new HttpDocumentRetriever(retrievalClient) { RequireHttps = true };
        var manager = new ConfigurationManager<OpenIdConnectConfiguration>(
            issuer.TrimEnd('/') + "/.well-known/openid-configuration",
            new OpenIdConnectConfigurationRetriever(),
            documentRetriever);

        var configuration = await manager.GetConfigurationAsync(CancellationToken.None);
        Assert.Equal(issuer, configuration.Issuer);
        Assert.Contains(configuration.SigningKeys, key => key.KeyId == "test-key");
        Assert.Contains(configuration.SigningKeys, key => key.KeyId == "previous-test-key");

        using var csrfResponse = await client.GetAsync("/csrf");
        using var csrf = JsonDocument.Parse(await csrfResponse.Content.ReadAsStringAsync());
        using var session = new HttpRequestMessage(HttpMethod.Post, "/session");
        session.Headers.Add("X-CSRF-TOKEN", csrf.RootElement.GetProperty("requestToken").GetString());
        using var sessionResponse = await client.SendAsync(session);
        Assert.Equal(HttpStatusCode.NoContent, sessionResponse.StatusCode);
        var accessCookie = Assert.Single(sessionResponse.Headers.GetValues("Set-Cookie"), value => value.StartsWith("dab_access_token=", StringComparison.Ordinal));
        var token = accessCookie.Split(';')[0]["dab_access_token=".Length..];

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

        var previousSigningKey = new RsaSecurityKey(factory.PreviousSigningKey.ExportParameters(includePrivateParameters: true))
        {
            KeyId = "previous-test-key"
        };
        var priorToken = new JwtSecurityToken(
            issuer,
            "api://northwind-dab",
            [new Claim("sub", "previously-issued-subject")],
            DateTime.UtcNow.AddMinutes(-1),
            DateTime.UtcNow.AddMinutes(5),
            new SigningCredentials(previousSigningKey, SecurityAlgorithms.RsaSha256));
        var priorPrincipal = validator.ValidateToken(validator.WriteToken(priorToken), validation, out _);
        Assert.Equal("previously-issued-subject", priorPrincipal.FindFirst("sub")?.Value);

        var tokenParts = token.Split('.');
        tokenParts[2] = tokenParts[2][..^1] + (tokenParts[2][^1] == 'A' ? 'B' : 'A');
        Assert.ThrowsAny<SecurityTokenException>(() => validator.ValidateToken(string.Join('.', tokenParts), validation, out _));

        var wrongIssuer = validation.Clone();
        wrongIssuer.ValidIssuer = "https://untrusted.example/";
        Assert.Throws<SecurityTokenInvalidIssuerException>(() => validator.ValidateToken(token, wrongIssuer, out _));

        var wrongAudience = validation.Clone();
        wrongAudience.ValidAudience = "api://different-resource";
        Assert.Throws<SecurityTokenInvalidAudienceException>(() => validator.ValidateToken(token, wrongAudience, out _));

        var expiredProfile = new IdentityProfile("fixture-sid", "test-user", "catalog-profile-1", "Fixture User", ["catalog.reader"])
        {
            Claims = new Dictionary<string, string> { ["ClearanceLevel"] = "Level3" }
        };
        var expiredToken = factory.Services.GetRequiredService<JwtIssuer>()
            .CreateToken(expiredProfile, DateTimeOffset.UtcNow.AddHours(-1));
        Assert.Throws<SecurityTokenExpiredException>(() => validator.ValidateToken(expiredToken, validation, out _));

        var unknownKeyHeader = Base64UrlEncoder.Encode(System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new
        {
            alg = SecurityAlgorithms.RsaSha256,
            typ = "at+jwt",
            kid = "unknown-test-key"
        }));
        var unknownKeyToken = string.Join('.', unknownKeyHeader, tokenParts[1], tokenParts[2]);
        Assert.ThrowsAny<SecurityTokenException>(() => validator.ValidateToken(unknownKeyToken, validation, out _));
    }

    [Fact]
    public async Task Oidc_authorization_code_pkce_issues_signed_tokens_and_rotating_refresh_token()
    {
        var issuer = "https://issuer.example.test/";
        const string clientId = "dab-issuer-test-client";
        const string redirectUri = "https://localhost:5443/callback";
        var verifier = Base64UrlEncoder.Encode(RandomNumberGenerator.GetBytes(32));
        var challenge = Base64UrlEncoder.Encode(SHA256.HashData(System.Text.Encoding.ASCII.GetBytes(verifier)));
        var authorizationQuery = QueryString.Create(new Dictionary<string, string?>
        {
            ["client_id"] = clientId,
            ["redirect_uri"] = redirectUri,
            ["response_type"] = "code",
            ["scope"] = "openid profile roles offline_access",
            ["state"] = "test-state",
            ["nonce"] = "test-nonce",
            ["code_challenge"] = challenge,
            ["code_challenge_method"] = "S256"
        });

        using var authorization = await client.GetAsync("/connect/authorize" + authorizationQuery);
        Assert.Equal(HttpStatusCode.Redirect, authorization.StatusCode);
        var callback = Assert.IsType<Uri>(authorization.Headers.Location);
        Assert.StartsWith(redirectUri, callback.AbsoluteUri, StringComparison.Ordinal);
        var callbackQuery = QueryHelpers.ParseQuery(callback.Query);
        Assert.Equal("test-state", callbackQuery["state"].ToString());
        var code = callbackQuery["code"].ToString();
        Assert.False(string.IsNullOrWhiteSpace(code));

        using var tokenResponse = await client.PostAsync("/connect/token", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "authorization_code",
            ["client_id"] = clientId,
            ["redirect_uri"] = redirectUri,
            ["code"] = code,
            ["code_verifier"] = verifier
        }));
        Assert.Equal(HttpStatusCode.OK, tokenResponse.StatusCode);
        using var tokens = JsonDocument.Parse(await tokenResponse.Content.ReadAsStringAsync());
        var idToken = tokens.RootElement.GetProperty("id_token").GetString()!;
        var accessToken = tokens.RootElement.GetProperty("access_token").GetString()!;
        var refreshToken = tokens.RootElement.GetProperty("refresh_token").GetString()!;

        using var metadataClient = new HttpClient(new TestServerForwarder(client));
        var metadata = await new ConfigurationManager<OpenIdConnectConfiguration>(
            issuer.TrimEnd('/') + "/.well-known/openid-configuration",
            new OpenIdConnectConfigurationRetriever(),
            new HttpDocumentRetriever(metadataClient) { RequireHttps = true })
            .GetConfigurationAsync(CancellationToken.None);
        var jwtHandler = new JwtSecurityTokenHandler { MapInboundClaims = false };
        var idPrincipal = jwtHandler.ValidateToken(idToken, new TokenValidationParameters
        {
            ValidIssuer = issuer,
            ValidAudience = clientId,
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            IssuerSigningKeys = metadata.SigningKeys,
            ClockSkew = TimeSpan.FromSeconds(2)
        }, out var validatedIdToken);
        Assert.Equal("test-user", idPrincipal.FindFirst("sub")?.Value);
        Assert.Equal("test-nonce", idPrincipal.FindFirst("nonce")?.Value);
        Assert.Equal("test-key", Assert.IsType<JwtSecurityToken>(validatedIdToken).Header.Kid);
        var accessPrincipal = jwtHandler.ValidateToken(accessToken, new TokenValidationParameters
        {
            ValidIssuer = issuer,
            ValidAudience = "api://northwind-dab",
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            IssuerSigningKeys = metadata.SigningKeys,
            ClockSkew = TimeSpan.FromSeconds(2)
        }, out var validatedAccessToken);
        Assert.Equal("test-key", Assert.IsType<JwtSecurityToken>(validatedAccessToken).Header.Kid);
        Assert.Equal("catalog-profile-1", accessPrincipal.FindFirst("profile_id")?.Value);
        Assert.Equal("Level3", accessPrincipal.FindFirst("ClearanceLevel")?.Value);
        Assert.Contains(accessPrincipal.Claims, claim => claim.Type == "role" && claim.Value == "catalog.reader");
        Assert.DoesNotContain(accessPrincipal.Claims, claim => claim.Type is "issuer_windows_sid" or "issuer_security_stamp");

        factory.IdentityDirectory.Profile = new IdentityProfile(
            "S-1-5-21-10-20-30-1001", "test-user", "catalog-profile-2", "Updated Fixture User", ["catalog.writer"])
        {
            Claims = new Dictionary<string, string> { ["ClearanceLevel"] = "Level4" },
            SecurityStamp = "fixture-security-stamp"
        };

        using var refreshResponse = await client.PostAsync("/connect/token", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["client_id"] = clientId,
            ["refresh_token"] = refreshToken
        }));
        Assert.Equal(HttpStatusCode.OK, refreshResponse.StatusCode);
        using var rotated = JsonDocument.Parse(await refreshResponse.Content.ReadAsStringAsync());
        var rotatedRefresh = rotated.RootElement.GetProperty("refresh_token").GetString();
        var refreshedAccessToken = rotated.RootElement.GetProperty("access_token").GetString()!;
        Assert.False(string.IsNullOrWhiteSpace(rotatedRefresh));
        Assert.NotEqual(refreshToken, rotatedRefresh);
        Assert.Equal(1, await factory.GetOidcRefreshUseCountAsync());
        Assert.True(await factory.RefreshTokensShareAuthorizationAsync(refreshToken, rotatedRefresh!));
        var markerNow = DateTimeOffset.UtcNow;
        await factory.SetOidcRefreshMarkerExpiryAsync(markerNow.AddDays(7));
        Assert.Equal(0, await factory.CleanupOidcRefreshMarkersAsync(markerNow));
        Assert.Equal(1, await factory.GetOidcRefreshUseCountAsync());
        var refreshedPrincipal = jwtHandler.ValidateToken(refreshedAccessToken, new TokenValidationParameters
        {
            ValidIssuer = issuer,
            ValidAudience = "api://northwind-dab",
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            IssuerSigningKeys = metadata.SigningKeys,
            ClockSkew = TimeSpan.FromSeconds(2)
        }, out _);
        Assert.Equal("catalog-profile-2", refreshedPrincipal.FindFirst("profile_id")?.Value);
        Assert.Equal("Level4", refreshedPrincipal.FindFirst("ClearanceLevel")?.Value);
        Assert.Contains(refreshedPrincipal.Claims, claim => claim.Type == "role" && claim.Value == "catalog.writer");
        Assert.DoesNotContain(refreshedPrincipal.Claims, claim => claim.Type == "role" && claim.Value == "catalog.reader");

        using var replayResponse = await client.PostAsync("/connect/token", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["client_id"] = clientId,
            ["refresh_token"] = refreshToken
        }));
        Assert.True(replayResponse.StatusCode == HttpStatusCode.BadRequest, $"Replay returned {(int)replayResponse.StatusCode}: {await replayResponse.Content.ReadAsStringAsync()}");
        Assert.True(await factory.IsOidcFamilyRevokedAsync(rotatedRefresh!));
        Assert.Equal(1, await factory.GetOidcRefreshUseCountAsync());

        using var descendantAfterReplay = await client.PostAsync("/connect/token", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["client_id"] = clientId,
            ["refresh_token"] = rotatedRefresh!
        }));
        Assert.Equal(HttpStatusCode.BadRequest, descendantAfterReplay.StatusCode);
        var markerExpiry = DateTimeOffset.UtcNow;
        await factory.SetOidcRefreshMarkerExpiryAsync(markerExpiry.AddSeconds(-1));
        Assert.Equal(1, await factory.CleanupOidcRefreshMarkersAsync(markerExpiry));
        Assert.Equal(0, await factory.GetOidcRefreshUseCountAsync());

        await using (var scope = factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
            var account = await database.Users.SingleAsync(user => user.Id == "test-user");
            account.IsEnabled = false;
            await database.SaveChangesAsync();
        }

        using var disabledRefresh = await client.PostAsync("/connect/token", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["client_id"] = clientId,
            ["refresh_token"] = rotatedRefresh!
        }));
        Assert.Equal(HttpStatusCode.BadRequest, disabledRefresh.StatusCode);
    }

    [Fact]
    public async Task Openid_only_scope_omits_profile_and_role_claims_from_tokens()
    {
        const string clientId = "dab-issuer-test-client";
        const string redirectUri = "https://localhost:5443/callback";
        var verifier = Base64UrlEncoder.Encode(RandomNumberGenerator.GetBytes(32));
        var challenge = Base64UrlEncoder.Encode(SHA256.HashData(System.Text.Encoding.ASCII.GetBytes(verifier)));
        var query = QueryString.Create(new Dictionary<string, string?>
        {
            ["client_id"] = clientId,
            ["redirect_uri"] = redirectUri,
            ["response_type"] = "code",
            ["scope"] = "openid",
            ["nonce"] = "scope-test-nonce",
            ["code_challenge"] = challenge,
            ["code_challenge_method"] = "S256"
        });

        using var authorization = await client.GetAsync("/connect/authorize" + query);
        Assert.Equal(HttpStatusCode.Redirect, authorization.StatusCode);
        var callback = Assert.IsType<Uri>(authorization.Headers.Location);
        var code = QueryHelpers.ParseQuery(callback.Query)["code"].ToString();
        using var tokenResponse = await client.PostAsync("/connect/token", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "authorization_code",
            ["client_id"] = clientId,
            ["redirect_uri"] = redirectUri,
            ["code"] = code,
            ["code_verifier"] = verifier
        }));
        Assert.Equal(HttpStatusCode.OK, tokenResponse.StatusCode);
        using var tokens = JsonDocument.Parse(await tokenResponse.Content.ReadAsStringAsync());
        var idToken = tokens.RootElement.GetProperty("id_token").GetString()!;
        var accessToken = tokens.RootElement.GetProperty("access_token").GetString()!;
        var handler = new JwtSecurityTokenHandler { MapInboundClaims = false };
        foreach (var token in new[] { idToken, accessToken })
        {
            var claims = handler.ReadJwtToken(token).Claims.Select(claim => claim.Type).ToArray();
            Assert.Contains("sub", claims);
            Assert.DoesNotContain("profile_id", claims);
            Assert.DoesNotContain("name", claims);
            Assert.DoesNotContain("role", claims);
            Assert.DoesNotContain("ClearanceLevel", claims);
            Assert.DoesNotContain("issuer_windows_sid", claims);
            Assert.DoesNotContain("issuer_security_stamp", claims);
        }
    }

    [Fact]
    public async Task Existing_oidc_client_must_match_the_configured_public_pkce_contract()
    {
        await using var scope = factory.Services.CreateAsyncScope();
        var manager = scope.ServiceProvider.GetRequiredService<OpenIddict.Abstractions.IOpenIddictApplicationManager>();
        const string clientId = "dab-issuer-test-client";
        var redirect = new Uri("https://localhost:5443/callback");
        var application = await manager.FindByClientIdAsync(clientId);
        Assert.NotNull(application);

        await OpenIddictClientProvisioningCommand.EnsureClientAsync(manager, clientId, redirect);

        var descriptor = new OpenIddict.Abstractions.OpenIddictApplicationDescriptor();
        await manager.PopulateAsync(descriptor, application!);
        var expectedRedirect = descriptor.RedirectUris.Single();
        descriptor.RedirectUris.Clear();
        descriptor.RedirectUris.Add(new Uri("https://localhost:5444/other"));
        await manager.UpdateAsync(application!, descriptor);
        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await OpenIddictClientProvisioningCommand.EnsureClientAsync(manager, clientId, redirect));

        descriptor.RedirectUris.Clear();
        descriptor.RedirectUris.Add(expectedRedirect);
        await manager.UpdateAsync(application!, descriptor);
    }

    [Fact]
    public async Task Session_requires_antiforgery_and_issues_an_expiring_secure_cookie_then_logout_clears_it()
    {
        using var csrfResponse = await client.GetAsync("/csrf");
        Assert.True(csrfResponse.IsSuccessStatusCode, await csrfResponse.Content.ReadAsStringAsync());
        using var csrf = JsonDocument.Parse(await csrfResponse.Content.ReadAsStringAsync());
        var requestToken = csrf.RootElement.GetProperty("requestToken").GetString()!;

        using var rejected = await client.PostAsync("/session", new StringContent(string.Empty));
        Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);

        using var create = new HttpRequestMessage(HttpMethod.Post, "/session");
        create.Headers.Add("X-CSRF-TOKEN", requestToken);
        using var created = await client.SendAsync(create);
        Assert.Equal(HttpStatusCode.NoContent, created.StatusCode);
        var issuedCookies = created.Headers.GetValues("Set-Cookie").ToArray();
        var issuedCookie = Assert.Single(issuedCookies, value => value.StartsWith("dab_access_token=", StringComparison.Ordinal));
        var refreshCookie = Assert.Single(issuedCookies, value => value.StartsWith("issuer_refresh_token=", StringComparison.Ordinal));
        Assert.Contains("httponly", refreshCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", refreshCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("samesite=strict", refreshCookie, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("=", refreshCookie.Split(';')[0].Split('=')[1]);
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

        using var rejectedRefresh = await client.PostAsync("/session/refresh", new StringContent(string.Empty));
        Assert.Equal(HttpStatusCode.BadRequest, rejectedRefresh.StatusCode);

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
        var deletedCookies = loggedOut.Headers.GetValues("Set-Cookie").ToArray();
        var deletedCookie = Assert.Single(deletedCookies, value => value.StartsWith("dab_access_token=", StringComparison.Ordinal));
        Assert.Contains("dab_access_token=", deletedCookie, StringComparison.Ordinal);
        Assert.Contains("expires=thu, 01 jan 1970", deletedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", deletedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("httponly", deletedCookie, StringComparison.OrdinalIgnoreCase);
        Assert.Contains(deletedCookies, value => value.StartsWith("issuer_refresh_token=", StringComparison.Ordinal) && value.Contains("expires=thu, 01 jan 1970", StringComparison.OrdinalIgnoreCase));
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
    private readonly string encryptionKeyPath;
    private readonly string previousSigningKeyPath;
    public RSA SigningKey { get; }
    public RSA PreviousSigningKey { get; }
    public FixtureIdentityDirectory IdentityDirectory { get; } = new();
    private readonly Dictionary<string, string?> previousEnvironment = new(StringComparer.OrdinalIgnoreCase);

    public IdentityIssuerFactory()
    {
        SigningKey = RSA.Create(2048);
        PreviousSigningKey = RSA.Create(2048);
        keyPath = Path.Combine(Path.GetTempPath(), $"identity-issuer-test-{Guid.NewGuid():N}.pem");
        encryptionKeyPath = Path.Combine(Path.GetTempPath(), $"identity-issuer-encryption-test-{Guid.NewGuid():N}.pem");
        previousSigningKeyPath = Path.Combine(Path.GetTempPath(), $"identity-issuer-previous-private-{Guid.NewGuid():N}.pem");
        File.WriteAllText(keyPath, SigningKey.ExportPkcs8PrivateKeyPem());
        File.WriteAllText(encryptionKeyPath, SigningKey.ExportPkcs8PrivateKeyPem());
        File.WriteAllText(previousSigningKeyPath, PreviousSigningKey.ExportPkcs8PrivateKeyPem());
        SetEnvironment("Issuer__Url", "https://issuer.example.test");
        SetEnvironment("Issuer__Audience", "api://northwind-dab");
        SetEnvironment("Issuer__KeyId", "test-key");
        SetEnvironment("Issuer__SigningKeyPath", keyPath);
        SetEnvironment("Issuer__EncryptionKeyPath", encryptionKeyPath);
        SetEnvironment("Issuer__PreviousSigningKeys__0__KeyId", "previous-test-key");
        SetEnvironment("Issuer__PreviousSigningKeys__0__PrivateKeyPath", previousSigningKeyPath);
        SetEnvironment("Issuer__LifetimeMinutes", "10");
        SetEnvironment("WindowsAuthentication__Mode", "IIS");
        SetEnvironment("ConnectionStrings__IssuerIdentity", "Server=localhost;Database=northwind;Integrated Security=true;Encrypt=true;TrustServerCertificate=true");
    }

    private void SetEnvironment(string name, string value)
    {
        previousEnvironment[name] = Environment.GetEnvironmentVariable(name);
        Environment.SetEnvironmentVariable(name, value);
    }

    public async Task<int> GetOidcRefreshUseCountAsync()
    {
        await using var scope = Services.CreateAsyncScope();
        return await scope.ServiceProvider.GetRequiredService<ApplicationDbContext>().OidcRefreshTokenUses.CountAsync();
    }

    public async Task SetOidcRefreshMarkerExpiryAsync(DateTimeOffset expiresAt)
    {
        await using var scope = Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
        foreach (var marker in await database.OidcRefreshTokenUses.ToListAsync())
            marker.ExpiresAt = expiresAt;
        await database.SaveChangesAsync();
    }

    public async Task<int> CleanupOidcRefreshMarkersAsync(DateTimeOffset now)
    {
        await using var scope = Services.CreateAsyncScope();
        return await OidcRefreshReplayMarkerCleanup.RemoveExpiredAsync(
            scope.ServiceProvider.GetRequiredService<ApplicationDbContext>(),
            now,
            CancellationToken.None);
    }

    public async Task<bool> RefreshTokensShareAuthorizationAsync(string first, string second)
    {
        await using var scope = Services.CreateAsyncScope();
        var manager = scope.ServiceProvider.GetRequiredService<OpenIddict.Abstractions.IOpenIddictTokenManager>();
        var firstToken = await manager.FindByReferenceIdAsync(first);
        var secondToken = await manager.FindByReferenceIdAsync(second);
        if (firstToken is null || secondToken is null)
            return false;
        return string.Equals(
            await manager.GetAuthorizationIdAsync(firstToken),
            await manager.GetAuthorizationIdAsync(secondToken),
            StringComparison.Ordinal);
    }

    public async Task<bool> IsOidcFamilyRevokedAsync(string value)
    {
        await using var scope = Services.CreateAsyncScope();
        var manager = scope.ServiceProvider.GetRequiredService<OpenIddict.Abstractions.IOpenIddictTokenManager>();
        var token = await manager.FindByReferenceIdAsync(value);
        if (token is null)
            return false;
        var authorizationId = await manager.GetAuthorizationIdAsync(token);
        return await scope.ServiceProvider.GetRequiredService<ApplicationDbContext>().OidcRefreshTokenUses
            .AnyAsync(item => item.AuthorizationId == authorizationId && item.FamilyRevokedAt != null);
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
            ["Issuer:EncryptionKeyPath"] = encryptionKeyPath,
            ["Issuer:PreviousSigningKeys:0:KeyId"] = "previous-test-key",
            ["Issuer:PreviousSigningKeys:0:PrivateKeyPath"] = previousSigningKeyPath,
            ["Issuer:LifetimeMinutes"] = "10",
            ["WindowsAuthentication:Mode"] = "IIS",
            ["ConnectionStrings:IssuerIdentity"] = "Server=localhost;Database=northwind;Integrated Security=true;Encrypt=true;TrustServerCertificate=true"
        }));
        builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<DbContextOptions<ApplicationDbContext>>();
            services.RemoveAll<IDbContextOptionsConfiguration<ApplicationDbContext>>();
            services.RemoveAll<ApplicationDbContext>();
            services.AddDbContext<ApplicationDbContext>(options => options.UseInMemoryDatabase("issuer-http-tests").UseOpenIddict());
            services.AddAuthentication(options =>
            {
                options.DefaultAuthenticateScheme = TestScheme;
                options.DefaultChallengeScheme = TestScheme;
                options.DefaultForbidScheme = TestScheme;
            }).AddScheme<AuthenticationSchemeOptions, TestAuthenticationHandler>(TestScheme, _ => { });
            services.RemoveAll<IIdentityDirectory>();
            services.AddSingleton<IIdentityDirectory>(IdentityDirectory);
        });
    }

    protected override IHost CreateHost(IHostBuilder builder)
    {
        var host = base.CreateHost(builder);
        using var scope = host.Services.CreateScope();
        var context = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
        context.Database.EnsureCreated();
        if (!context.Users.Any(user => user.Id == "test-user"))
        {
            context.Users.Add(new ApplicationUser
            {
                Id = "test-user",
                UserName = "issuer-http-test",
                NormalizedUserName = "ISSUER-HTTP-TEST",
                WindowsSid = "S-1-5-21-10-20-30-1001",
                ProfileId = "catalog-profile-1",
                DisplayName = "Fixture User",
                SecurityStamp = "fixture-security-stamp",
                LockoutEnabled = true
            });
            context.SaveChanges();
        }
        var openIddictApplications = scope.ServiceProvider.GetRequiredService<OpenIddict.Abstractions.IOpenIddictApplicationManager>();
        OpenIddictClientProvisioningCommand.EnsureClientAsync(openIddictApplications,
            "dab-issuer-test-client", new Uri("https://localhost:5443/callback")).GetAwaiter().GetResult();
        return host;
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing)
        {
            foreach (var (name, value) in previousEnvironment)
                Environment.SetEnvironmentVariable(name, value);
            if (File.Exists(keyPath)) File.Delete(keyPath);
            if (File.Exists(encryptionKeyPath)) File.Delete(encryptionKeyPath);
            if (File.Exists(previousSigningKeyPath)) File.Delete(previousSigningKeyPath);
            SigningKey.Dispose();
            PreviousSigningKey.Dispose();
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
    public IdentityProfile Profile { get; set; } = new(
        "S-1-5-21-10-20-30-1001", "test-user", "catalog-profile-1", "Fixture User", ["catalog.reader"])
    {
        Claims = new Dictionary<string, string> { ["ClearanceLevel"] = "Level3" },
        SecurityStamp = "fixture-security-stamp"
    };

    public Task<IdentityProfile?> FindByWindowsSidAsync(string sid, CancellationToken cancellationToken)
    {
        IdentityProfile? profile = sid == Profile.WindowsSid ? Profile : null;
        return Task.FromResult(profile);
    }
}
