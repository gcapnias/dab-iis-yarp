extern alias IssuerProject;

using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Security.Claims;
using System.Text.Json;
using IdentityIssuer = IssuerProject::IdentityIssuer;
using Azure.DataApiBuilder.Core.AuthenticationHelpers;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.Tokens;

namespace EmbeddedDab.Tests;

public sealed class JwtDabIntegrationTests
{
    private const string Audience = "api://dab-interoperability-test";

    [Fact]
    public async Task CustomProviderValidatesIssuerTokensAndEnforcesConfiguredRestAndGraphQlPermissions()
    {
        await WithDabHostAsync(async (client, signingKey, issuerUrl) =>
        {
            var issuer = CreateIssuer(signingKey, issuerUrl);
            string readerToken = CreateToken(issuer, ["reader"]);
            string writerToken = CreateToken(issuer, ["writer"]);
            string anotherWriterToken = issuer.CreateToken(
                new IdentityIssuer.IdentityProfile("other-sid", "other-subject", "other-profile", "Another Test Caller", ["writer"]),
                DateTimeOffset.UtcNow);

            var (csrfCookie, csrfToken) = await GetCsrfAsync(client, writerToken);
            using var cookieCreate = await SendCookieMutationAsync(client, "/api/Widget", writerToken, csrfCookie, csrfToken,
                new { id = 75, name = "writer-cookie-created", quantity = 2 });
            Assert.True(cookieCreate.StatusCode is HttpStatusCode.Created or HttpStatusCode.OK,
                $"Valid cookie REST mutation returned {(int)cookieCreate.StatusCode}.");
            using var cookieGraphQlCreate = await SendCookieMutationAsync(client, "/graphql", writerToken, csrfCookie, csrfToken,
                new { query = "mutation { createWidget(item: { id: 76, name: \"writer-cookie-graphql-created\", quantity: 2 }) { id name } }" });
            Assert.Equal(HttpStatusCode.OK, cookieGraphQlCreate.StatusCode);
            using var cookieGraphQlCreateBody = JsonDocument.Parse(await cookieGraphQlCreate.Content.ReadAsStringAsync());
            Assert.Equal("writer-cookie-graphql-created", cookieGraphQlCreateBody.RootElement.GetProperty("data").GetProperty("createWidget").GetProperty("name").GetString());

            using var missingCsrf = await SendCookieMutationAsync(client, "/api/Widget", writerToken, csrfCookie, null,
                new { id = 77, name = "missing-csrf", quantity = 1 });
            Assert.Equal(HttpStatusCode.BadRequest, missingCsrf.StatusCode);
            using var wrongCsrf = await SendCookieMutationAsync(client, "/api/Widget", writerToken, csrfCookie, "wrong-token",
                new { id = 77, name = "wrong-csrf", quantity = 1 });
            Assert.Equal(HttpStatusCode.BadRequest, wrongCsrf.StatusCode);
            using var foreignOrigin = await SendCookieMutationAsync(client, "/api/Widget", writerToken, csrfCookie, csrfToken,
                new { id = 77, name = "foreign-origin", quantity = 1 }, origin: "https://attacker.invalid");
            Assert.Equal(HttpStatusCode.BadRequest, foreignOrigin.StatusCode);

            using var graphqlMissingCsrf = await SendCookieMutationAsync(client, "/graphql", writerToken, csrfCookie, null,
                new { query = "mutation { createWidget(item: { id: 78, name: \"missing-csrf\", quantity: 1 }) { id } }" });
            Assert.Equal(HttpStatusCode.BadRequest, graphqlMissingCsrf.StatusCode);
            using var graphqlWrongCsrf = await SendCookieMutationAsync(client, "/graphql", writerToken, csrfCookie, "wrong-token",
                new { query = "mutation { createWidget(item: { id: 78, name: \"wrong-csrf\", quantity: 1 }) { id } }" });
            Assert.Equal(HttpStatusCode.BadRequest, graphqlWrongCsrf.StatusCode);
            using var graphqlForeignOrigin = await SendCookieMutationAsync(client, "/graphql", writerToken, csrfCookie, csrfToken,
                new { query = "mutation { createWidget(item: { id: 78, name: \"foreign-origin\", quantity: 1 }) { id } }" }, origin: "https://attacker.invalid");
            Assert.Equal(HttpStatusCode.BadRequest, graphqlForeignOrigin.StatusCode);

            using var wrongIdentityCsrf = await SendCookieMutationAsync(client, "/api/Widget", anotherWriterToken, csrfCookie, csrfToken,
                new { id = 79, name = "wrong-identity-csrf", quantity = 1 });
            Assert.Equal(HttpStatusCode.BadRequest, wrongIdentityCsrf.StatusCode);

            var (readerCsrfCookie, readerCsrfToken) = await GetCsrfAsync(client, readerToken, csrfCookie);
            using var readerCookieRestMutation = await SendCookieMutationAsync(client, "/api/Widget", readerToken, readerCsrfCookie, readerCsrfToken,
                new { id = 79, name = "reader-denied", quantity = 1 }, role: "reader");
            Assert.True(readerCookieRestMutation.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized);
            using var readerCookieGraphQlMutation = await SendCookieMutationAsync(client, "/graphql", readerToken, readerCsrfCookie, readerCsrfToken,
                new { query = "mutation { createWidget(item: { id: 79, name: \"reader-denied\", quantity: 1 }) { id } }" }, role: "reader");
            await AssertGraphQlDeniedAsync(readerCookieGraphQlMutation, "reader cookie GraphQL mutation");

            using var readerCollection = await SendAsync(client, HttpMethod.Get, "/api/Widget?$first=2", readerToken, "reader");
            Assert.Equal(HttpStatusCode.OK, readerCollection.StatusCode);
            using var readerBody = JsonDocument.Parse(await readerCollection.Content.ReadAsStringAsync());
            Assert.Equal("fixture-one", readerBody.RootElement.GetProperty("value")[0].GetProperty("name").GetString());

            using var cookieRead = await SendCookieAsync(client, HttpMethod.Get, "/api/Widget?$first=2", readerToken, "reader");
            Assert.Equal(HttpStatusCode.OK, cookieRead.StatusCode);
            using var cookieReadBody = JsonDocument.Parse(await cookieRead.Content.ReadAsStringAsync());
            Assert.Equal("fixture-one", cookieReadBody.RootElement.GetProperty("value")[0].GetProperty("name").GetString());

            using var explicitBearer = new HttpRequestMessage(HttpMethod.Get, "/api/Widget");
            explicitBearer.Headers.Add("Cookie", $"dab_access_token={readerToken}");
            explicitBearer.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "not.a.jwt");
            explicitBearer.Headers.Add("X-MS-API-ROLE", "reader");
            using var explicitBearerResponse = await client.SendAsync(explicitBearer);
            Assert.Equal(HttpStatusCode.Unauthorized, explicitBearerResponse.StatusCode);

            using var readerCreate = await SendAsync(client, HttpMethod.Post, "/api/Widget", readerToken, "reader", new { id = 71, name = "reader-must-not-create", quantity = 1 });
            Assert.True(readerCreate.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized);

            using var readerGraphQlQuery = await SendGraphQlAsync(client, readerToken, "reader", "{ widgets(first: 2) { items { id name quantity } } }");
            Assert.Equal(HttpStatusCode.OK, readerGraphQlQuery.StatusCode);
            using var queryBody = JsonDocument.Parse(await readerGraphQlQuery.Content.ReadAsStringAsync());
            Assert.False(queryBody.RootElement.TryGetProperty("errors", out _));
            Assert.Equal("fixture-one", queryBody.RootElement.GetProperty("data").GetProperty("widgets").GetProperty("items")[0].GetProperty("name").GetString());

            using var cookieGraphQlQuery = await SendGraphQlCookieQueryAsync(client, readerToken, "reader", "{ widgets(first: 2) { items { id name quantity } } }");
            Assert.Equal(HttpStatusCode.OK, cookieGraphQlQuery.StatusCode);
            using var cookieGraphQlBody = JsonDocument.Parse(await cookieGraphQlQuery.Content.ReadAsStringAsync());
            Assert.False(cookieGraphQlBody.RootElement.TryGetProperty("errors", out _));
            Assert.Equal("fixture-one", cookieGraphQlBody.RootElement.GetProperty("data").GetProperty("widgets").GetProperty("items")[0].GetProperty("name").GetString());

            using var cookieGraphQlGetMutation = await SendGraphQlCookieQueryAsync(client, writerToken, "writer",
                "mutation { createWidget(item: { id: 80, name: \"get-must-not-mutate\", quantity: 1 }) { id } }");
            Assert.Equal(HttpStatusCode.MethodNotAllowed, cookieGraphQlGetMutation.StatusCode);

            using var readerGraphQlMutation = await SendGraphQlAsync(client, readerToken, "reader", "mutation { createWidget(item: { id: 72, name: \"reader-must-not-create\", quantity: 1 }) { id } }");
            await AssertGraphQlDeniedAsync(readerGraphQlMutation, "reader bearer GraphQL mutation");
            await AssertWidgetAbsentAsync(client, writerToken, 72);
            await AssertWidgetAbsentAsync(client, writerToken, 79);

            using var writerCreate = await SendAsync(client, HttpMethod.Post, "/api/Widget", writerToken, "writer", new { id = 73, name = "writer-created", quantity = 2 });
            Assert.True(writerCreate.StatusCode is HttpStatusCode.Created or HttpStatusCode.OK);
            using var writerGraphQlMutation = await SendGraphQlAsync(client, writerToken, "writer", "mutation { createWidget(item: { id: 74, name: \"writer-graphql-created\", quantity: 2 }) { id name } }");
            Assert.Equal(HttpStatusCode.OK, writerGraphQlMutation.StatusCode);
            using var createdMutationBody = JsonDocument.Parse(await writerGraphQlMutation.Content.ReadAsStringAsync());
            Assert.Equal("writer-graphql-created", createdMutationBody.RootElement.GetProperty("data").GetProperty("createWidget").GetProperty("name").GetString());

            using var writerDelete = await SendAsync(client, HttpMethod.Delete, "/api/Widget/id/73", writerToken, "writer");
            Assert.True(writerDelete.StatusCode is HttpStatusCode.OK or HttpStatusCode.NoContent);
            using var writerGraphQlDelete = await SendGraphQlAsync(client, writerToken, "writer", "mutation { deleteWidget(id: 74) { id } }");
            using var deleteBody = JsonDocument.Parse(await writerGraphQlDelete.Content.ReadAsStringAsync());
            Assert.Equal(74, deleteBody.RootElement.GetProperty("data").GetProperty("deleteWidget").GetProperty("id").GetInt32());

            await AssertWidgetAbsentAsync(client, readerToken, 73, "reader");
        });
    }

    [Theory]
    [InlineData("malformed")]
    [InlineData("expired")]
    [InlineData("wrong issuer")]
    [InlineData("wrong audience")]
    [InlineData("wrong signature")]
    public async Task CustomProviderRejectsInvalidTokenThroughRestAndGraphQl(string invalidCase)
    {
        await WithDabHostAsync(async (client, signingKey, issuerUrl) =>
        {
            using var wrongSigningKey = RSA.Create(2048);
            string invalidToken = invalidCase switch
            {
                "malformed" => "not.a.jwt",
                "expired" => CreateToken(CreateIssuer(signingKey, issuerUrl), ["reader"], DateTimeOffset.UtcNow.AddHours(-1)),
                "wrong issuer" => CreateToken(CreateIssuer(signingKey, "http://wrong-issuer.invalid/"), ["reader"]),
                "wrong audience" => CreateToken(CreateIssuer(signingKey, issuerUrl, audience: "api://wrong-audience"), ["reader"]),
                "wrong signature" => CreateToken(CreateIssuer(wrongSigningKey, issuerUrl), ["reader"]),
                _ => throw new ArgumentOutOfRangeException(nameof(invalidCase))
            };

            if (invalidCase == "expired")
            {
                var decoded = new JwtSecurityTokenHandler().ReadJwtToken(invalidToken);
                Assert.True(decoded.ValidFrom < decoded.ValidTo);
                Assert.True(decoded.ValidTo < DateTime.UtcNow.AddMinutes(-5));
            }

            using var restResponse = await SendAsync(client, HttpMethod.Get, "/api/Widget", invalidToken, "reader");
            using var graphQlResponse = await SendGraphQlAsync(client, invalidToken, "reader", "{ widgets(first: 1) { items { id } } }");
            Assert.True(restResponse.StatusCode == HttpStatusCode.Unauthorized, $"REST {invalidCase} returned {(int)restResponse.StatusCode}.");
            await AssertGraphQlDeniedAsync(graphQlResponse, $"GraphQL {invalidCase}");

            if (invalidCase == "expired")
            {
                using var expiredCookie = await SendCookieAsync(client, HttpMethod.Get, "/api/Widget", invalidToken, "reader");
                Assert.Equal(HttpStatusCode.Unauthorized, expiredCookie.StatusCode);
            }
        });
    }

    [Theory]
    [InlineData("missing credentials")]
    [InlineData("missing roles claim")]
    [InlineData("forged role selection")]
    public async Task CustomProviderRejectsMissingIdentityOrUnauthorizedRoleThroughRestAndGraphQl(string deniedCase)
    {
        await WithDabHostAsync(async (client, signingKey, issuerUrl) =>
        {
            string? token = deniedCase switch
            {
                "missing credentials" => null,
                "missing roles claim" => CreateTokenWithoutRoles(signingKey, issuerUrl, Audience),
                "forged role selection" => CreateToken(CreateIssuer(signingKey, issuerUrl), ["reader"]),
                _ => throw new ArgumentOutOfRangeException(nameof(deniedCase))
            };
            string selectedRole = deniedCase == "forged role selection" ? "writer" : "reader";
            using var restResponse = await SendAsync(client, HttpMethod.Get, "/api/Widget", token, selectedRole);
            using var graphQlResponse = await SendGraphQlAsync(client, token, selectedRole, "{ widgets(first: 1) { items { id } } }");
            Assert.True(restResponse.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden,
                $"REST {deniedCase} returned {(int)restResponse.StatusCode}.");
            await AssertGraphQlDeniedAsync(graphQlResponse, $"GraphQL {deniedCase}");
        });
    }

    private static async Task WithDabHostAsync(Func<HttpClient, RSA, string, Task> run)
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("DAB_ENV_FILE"))
            || string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("DAB_FIXTURE_DATABASE")))
        {
            throw Xunit.Sdk.SkipException.ForSkip("Run scripts/test-embedded-dab-jwt.ps1 to provide an isolated SQL fixture database.");
        }

        using var signingKey = RSA.Create(2048);
        await using var fakeIssuer = await FakeIssuer.StartAsync(signingKey);
        var issuerUrl = fakeIssuer.IssuerUrl;
        string? originalIssuer = Environment.GetEnvironmentVariable("DAB_TEST_ISSUER");
        string? originalConfig = Environment.GetEnvironmentVariable("DAB_CONFIG_FILE");
        string? originalInitialize = Environment.GetEnvironmentVariable("DAB_INITIALIZE");
        Environment.SetEnvironmentVariable("DAB_TEST_ISSUER", issuerUrl);
        Environment.SetEnvironmentVariable("DAB_CONFIG_FILE", Path.Combine(AppContext.BaseDirectory, "configurations", "jwt-interoperability.json"));
        Environment.SetEnvironmentVariable("DAB_INITIALIZE", "true");

        try
        {
            using var factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
                builder.ConfigureTestServices(services =>
                {
                    services.Configure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options => options.RequireHttpsMetadata = false);
                    services.Configure<JwtBearerOptions>(GenericOAuthDefaults.AUTHENTICATIONSCHEME, options => options.RequireHttpsMetadata = false);
                }));
            using var client = factory.CreateClient(new WebApplicationFactoryClientOptions { BaseAddress = new Uri("https://localhost") });
            await run(client, signingKey, issuerUrl);
        }
        finally
        {
            Environment.SetEnvironmentVariable("DAB_TEST_ISSUER", originalIssuer);
            Environment.SetEnvironmentVariable("DAB_CONFIG_FILE", originalConfig);
            Environment.SetEnvironmentVariable("DAB_INITIALIZE", originalInitialize);
        }
    }

    private static IdentityIssuer.JwtIssuer CreateIssuer(RSA signingKey, string issuerUrl, string audience = Audience) =>
        new(signingKey, new IdentityIssuer.IssuerSettings(issuerUrl, audience, "fixture-key", TimeSpan.FromMinutes(10), "dab_access_token", null));

    private static string CreateToken(IdentityIssuer.JwtIssuer issuer, IReadOnlyList<string> roles, DateTimeOffset? now = null) => issuer.CreateToken(
        new IdentityIssuer.IdentityProfile("synthetic-sid", "synthetic-subject", "synthetic-profile", "Synthetic Test Caller", roles),
        now ?? DateTimeOffset.UtcNow);

    private static string CreateTokenWithoutRoles(RSA signingKey, string issuer, string audience)
    {
        var now = DateTime.UtcNow;
        var descriptor = new SecurityTokenDescriptor
        {
            Issuer = issuer,
            Audience = audience,
            Claims = new Dictionary<string, object>
            {
                ["sub"] = "synthetic-subject",
                ["profile_id"] = "synthetic-profile"
            },
            NotBefore = now.AddSeconds(-1),
            Expires = now.AddMinutes(10),
            SigningCredentials = new SigningCredentials(new RsaSecurityKey(signingKey.ExportParameters(true)) { KeyId = "fixture-key" }, SecurityAlgorithms.RsaSha256)
        };
        var handler = new JwtSecurityTokenHandler();
        return handler.WriteToken(handler.CreateToken(descriptor));
    }

    private static async Task<HttpResponseMessage> SendAsync(HttpClient client, HttpMethod method, string path, string? token, string? role, object? body = null)
    {
        using var request = new HttpRequestMessage(method, path);
        if (token is not null)
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        if (role is not null)
            request.Headers.Add("X-MS-API-ROLE", role);
        if (body is not null)
            request.Content = JsonContent.Create(body);
        return await client.SendAsync(request);
    }

    private static Task<HttpResponseMessage> SendGraphQlAsync(HttpClient client, string? token, string role, string query) =>
        SendAsync(client, HttpMethod.Post, "/graphql", token, role, new { query });

    private static async Task<HttpResponseMessage> SendCookieAsync(HttpClient client, HttpMethod method, string path, string token, string? role,
        object? body = null, string? csrfCookie = null, string? csrfToken = null, string? origin = null)
    {
        using var request = new HttpRequestMessage(method, path);
        request.Headers.Add("Cookie", csrfCookie is null ? $"dab_access_token={token}" : $"dab_access_token={token}; {csrfCookie}");
        if (role is not null)
            request.Headers.Add("X-MS-API-ROLE", role);
        if (origin is not null)
            request.Headers.Add("Origin", origin);
        if (csrfToken is not null)
            request.Headers.Add("X-CSRF-TOKEN", csrfToken);
        if (body is not null)
            request.Content = JsonContent.Create(body);
        return await client.SendAsync(request);
    }

    private static async Task<(string Cookie, string Token)> GetCsrfAsync(HttpClient client, string accessToken, string? existingCookie = null)
    {
        using var response = await SendCookieAsync(client, HttpMethod.Get, "/bridge/csrf", accessToken, null);
        Assert.True(response.IsSuccessStatusCode, $"CSRF endpoint returned {(int)response.StatusCode}.");
        var cookie = response.Headers.TryGetValues("Set-Cookie", out var setCookies)
            ? setCookies.Single(value => value.StartsWith("dab_bridge_csrf=", StringComparison.Ordinal)).Split(';', 2)[0]
            : existingCookie ?? throw new InvalidOperationException("CSRF response did not include a cookie.");
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        return (cookie, body.RootElement.GetProperty("requestToken").GetString()!);
    }

    private static Task<HttpResponseMessage> SendCookieMutationAsync(HttpClient client, string path, string accessToken, string csrfCookie, string? csrfToken,
        object body, string role = "writer", string origin = "https://localhost") =>
        SendCookieAsync(client, HttpMethod.Post, path, accessToken, role, body, csrfCookie, csrfToken, origin);

    private static async Task AssertGraphQlDeniedAsync(HttpResponseMessage response, string caseName)
    {
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            return;
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        Assert.True(body.RootElement.TryGetProperty("errors", out var errors) && errors.GetArrayLength() > 0,
            $"{caseName} returned a successful GraphQL result.");
        if (body.RootElement.TryGetProperty("data", out var data) && data.ValueKind != JsonValueKind.Null)
        {
            Assert.All(data.EnumerateObject(), field => Assert.Equal(JsonValueKind.Null, field.Value.ValueKind));
        }
        var codes = errors.EnumerateArray()
            .Select(error => error.TryGetProperty("extensions", out var extensions)
                && extensions.TryGetProperty("code", out var code) ? code.GetString() : null)
            .ToArray();
        Assert.Contains(codes, code => code is not null && code.Contains("AUTH", StringComparison.OrdinalIgnoreCase));
    }

    private static async Task AssertWidgetAbsentAsync(HttpClient client, string token, int id, string role = "writer")
    {
        using var response = await SendAsync(client, HttpMethod.Get, $"/api/Widget/id/{id}", token, role);
        Assert.True(response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.OK);
        if (response.StatusCode == HttpStatusCode.OK)
        {
            using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            Assert.Empty(body.RootElement.GetProperty("value").EnumerateArray());
        }
    }

    private static Task<HttpResponseMessage> SendGraphQlCookieQueryAsync(HttpClient client, string token, string role, string query) =>
        SendCookieAsync(client, HttpMethod.Get, "/graphql?query=" + Uri.EscapeDataString(query), token, role);

    private sealed class FakeIssuer : IAsyncDisposable
    {
        private readonly WebApplication app;

        private FakeIssuer(WebApplication app, string issuerUrl)
        {
            this.app = app;
            IssuerUrl = issuerUrl;
        }

        public string IssuerUrl { get; }

        public static async Task<FakeIssuer> StartAsync(RSA signingKey)
        {
            var builder = WebApplication.CreateBuilder();
            builder.WebHost.UseKestrel().UseUrls("http://127.0.0.1:0");
            var app = builder.Build();
            app.MapGet("/.well-known/openid-configuration", (HttpContext context) =>
            {
                string issuer = $"{context.Request.Scheme}://{context.Request.Host}/";
                return Results.Json(new
                {
                    issuer,
                    jwks_uri = $"{issuer}jwks",
                    id_token_signing_alg_values_supported = new[] { "RS256" },
                    token_endpoint_auth_methods_supported = new[] { "none" }
                });
            });
            var jwks = CreateIssuer(signingKey, "http://unused/").CreatePublicKeySet();
            app.MapGet("/jwks", () => Results.Json(jwks, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
            await app.StartAsync();
            var server = app.Services.GetRequiredService<Microsoft.AspNetCore.Hosting.Server.IServer>();
            var address = server.Features.Get<Microsoft.AspNetCore.Hosting.Server.Features.IServerAddressesFeature>()!.Addresses.Single();
            return new FakeIssuer(app, address.EndsWith('/') ? address : address + "/");
        }

        public async ValueTask DisposeAsync() => await app.DisposeAsync();
    }
}
