# Ticket #11: DAB JWT metadata and discovery implementation details

Research date: 2026-10-01. Scope: exact signing-key metadata contract for the current Windows-authenticated JWT issuer and its DAB consumer. This note does not change issuer code, configuration, database, or host settings.

## Finding

Ticket #11 can honestly implement the metadata needed by DAB's custom JWT provider at the conventional `/.well-known/openid-configuration` path, and it can publish a public JWKS. It cannot honestly claim full OpenID Connect Discovery 1.0 conformance without adding genuine OAuth/OIDC provider endpoints and flows. The current issuer has a Windows-authenticated `/session` endpoint that creates an application-specific access-token cookie; it does not implement an OIDC authorization endpoint, token endpoint, client protocol, or ID tokens.

The smallest correct implementation for this architecture is therefore **DAB-compatible JWT key-discovery metadata**, with ticket wording/reporting narrowed so “OpenID Connect discovery” does not imply a complete OIDC Provider. If the ticket must require full OIDC Discovery, that is an explicit scope/architecture change to add an authorization server. Do not fill mandatory OIDC fields with pretend endpoints, empty arrays, or unsupported flow names.

## Exact metadata and key contract

DAB's official Custom JWT guide says the configured `runtime.host.authentication.jwt.issuer` is the JWT Authority and DAB discovers keys from `<issuer>/.well-known/openid-configuration`. The documented DAB settings are `jwt.issuer` and `jwt.audience`; DAB validates token signature, exact issuer, audience, expiration, and `nbf` when present. DAB reads application roles from a claim named exactly `roles`. [DAB custom JWT guidance](https://learn.microsoft.com/en-us/azure/data-api-builder/concept/security/authenticate-custom)

For that DAB/IdentityModel consumer, the discovery JSON needs these two useful fields:

```json
{
  "issuer": "https://issuer.example.test",
  "jwks_uri": "https://issuer.example.test/.well-known/jwks.json"
}
```

`issuer` must be the exact issuer identifier used in the access token's `iss` claim and the DAB `jwt.issuer` setting, including path and trailing-slash choices. `jwks_uri` must resolve to HTTPS and return a JSON Web Key Set. The IdentityModel `OpenIdConnectConfigurationRetriever` GETs the metadata, reads `jwks_uri`, GETs that endpoint, creates a `JsonWebKeySet`, and adds its signing keys to the configuration. Its code does not call an authorization or token endpoint. [IdentityModel OpenIdConnectConfigurationRetriever.cs](https://github.com/AzureAD/azure-activedirectory-identitymodel-extensions-for-dotnet/blob/dev/src/Microsoft.IdentityModel.Protocols.OpenIdConnect/Configuration/OpenIdConnectConfigurationRetriever.cs)

For the issuer's RS256 key, the JWKS entry should contain:

```json
{
  "keys": [
    {
      "kty": "RSA",
      "kid": "issuer-signing-key-id",
      "use": "sig",
      "alg": "RS256",
      "n": "BASE64URL_RSA_MODULUS",
      "e": "AQAB"
    }
  ]
}
```

The key ID (`kid`) must match the JWT protected header. Publish only public key parameters; never include private RSA parameters such as `d`, `p`, or `q`. Current `JwtIssuer.CreatePublicKeySet()` already emits `kty`, `kid`, `use`, `alg`, `n`, and `e`, and the HTTP test checks the set exists and omits `d`. The current metadata route already emits `issuer` and `jwks_uri`; this research does not validate reachability from a real DAB process or key rotation.

This is sufficient for the IdentityModel parser's signing-key retrieval path, not a complete OIDC document. The IdentityModel configuration model has `Issuer` and `JwksUri` properties; the retriever only fetches JWKS when `JwksUri` is nonempty. [IdentityModel OpenIdConnectConfiguration.cs](https://github.com/AzureAD/azure-activedirectory-identitymodel-extensions-for-dotnet/blob/dev/src/Microsoft.IdentityModel.Protocols.OpenIdConnect/Configuration/OpenIdConnectConfiguration.cs)

## Why it is not complete OIDC Discovery

OpenID Connect Discovery 1.0 requires more than these two fields. Its provider metadata requires `issuer`, `authorization_endpoint`, `response_types_supported`, `subject_types_supported`, and `id_token_signing_alg_values_supported`; it requires `token_endpoint` unless the provider supports only the implicit flow. The specification describes these as actual endpoints and supported capabilities, and requires `RS256` in the advertised ID-token signing algorithms. These fields describe an OpenID Provider that supports OIDC flows and ID tokens. The current issuer does not do that. [OpenID Connect Discovery 1.0, Provider Metadata](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata)

The user has confirmed the accepted boundary: anonymous metadata/JWKS and Windows-authenticated user/session routes. For #11 under the current system design, report the endpoint as DAB JWT key-discovery metadata rather than a complete OIDC Provider. Full OIDC Discovery would require a separate scope/architecture change to add a real OAuth/OIDC authorization server. OpenIddict is a maintained .NET framework with executable ASP.NET Core examples—including an authorization-code sample with Integrated Windows Authentication—but adopting it would introduce authorization/token endpoints and flows beyond the accepted issuer-to-cookie-to-access-token contract. [OpenIddict samples](https://github.com/openiddict/openiddict-samples)

## Anonymous retrieval and Windows-authenticated sessions

The accepted boundary is that discovery metadata and JWKS are anonymously GETtable by the DAB server process; they contain no private signing secret or user profile. Session creation/logout remain Windows-authenticated and antiforgery-protected.

This distinction is operationally required by the default .NET metadata retrieval path. `HttpDocumentRetriever` uses a shared default `new HttpClient()` when no custom client is supplied; it does not attach the interactive Windows user's credentials. DAB's server-side metadata/JWKS fetch therefore cannot depend on that user's Windows session. [IdentityModel HttpDocumentRetriever.cs](https://github.com/AzureAD/azure-activedirectory-identitymodel-extensions-for-dotnet/blob/dev/src/Microsoft.IdentityModel.Protocols/Configuration/HttpDocumentRetriever.cs)

The ASP.NET Core `JwtBearer` post-configuration similarly creates a `ConfigurationManager<OpenIdConnectConfiguration>` using `MetadataAddress` and `OpenIdConnectConfigurationRetriever` by default, and the .NET API docs describe the manager as responsible for retrieval, caching, and refresh. [ASP.NET Core JwtBearerPostConfigureOptions.cs](https://source.dot.net/Microsoft.AspNetCore.Authentication.JwtBearer/JwtBearerPostConfigureOptions.cs.html), [JwtBearerOptions.ConfigurationManager](https://learn.microsoft.com/en-us/dotnet/api/microsoft.aspnetcore.authentication.jwtbearer.jwtbeareroptions.configurationmanager?view=aspnetcore-10.0)

For Kestrel/Negotiate, leave only metadata/JWKS endpoints without endpoint authorization and mark session endpoints `.RequireAuthorization()`. If IIS Windows Authentication is enabled while Anonymous Authentication is disabled for the whole site, the IIS layer can challenge before endpoint routing; configure anonymous access only for those read-only metadata paths (or serve them from a separate public metadata host). Do not make `/session` or logout anonymous to work around metadata retrieval.

## Runnable retrieval and validation recipe

The official ASP.NET Core JWT bearer guide shows `AddJwtBearer` with `Authority` and `Audience`; it explains that `Authority` supplies issuer and signing-key metadata. The issuer project targets `net10.0` and uses ASP.NET Core package version `10.0.12`. For a standalone consumer/integration harness, reference `Microsoft.AspNetCore.Authentication.JwtBearer` version `10.0.12`; that package declares `Microsoft.IdentityModel.Protocols.OpenIdConnect` version `8.19.2` or later. [ASP.NET Core JWT bearer guide](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/configure-jwt-bearer-authentication?view=aspnetcore-10.0), [JwtBearer 10.0.12 package](https://www.nuget.org/packages/Microsoft.AspNetCore.Authentication.JwtBearer/10.0.12)

Configure a protected harness endpoint as follows, using the issuer's real configured URL and audience:

```csharp
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Authority = issuer;
        options.Audience = audience;
        options.RequireHttpsMetadata = true;
        options.TokenValidationParameters.ValidAlgorithms =
            [SecurityAlgorithms.RsaSha256];
    });

builder.Services.AddAuthorization();
app.UseAuthentication();
app.UseAuthorization();
app.MapGet("/whoami", (ClaimsPrincipal user) =>
        Results.Json(user.Claims.Select(c => new { c.Type, c.Value })))
    .RequireAuthorization();
```

Then:

1. With no credentials, GET the discovery endpoint and JWKS and require HTTP 200 with JSON content types. Assert `issuer` equals the configured issuer and `jwks_uri` is an absolute HTTPS URL. Require `/whoami` to return 401 without a bearer token.
2. Authenticate to the issuer's `/session` using Windows Authentication and valid antiforgery material. In a controlled local test, extract the issued JWT from the `HttpOnly` cookie on the response; do not log or check the token into the repo.
3. Call `/whoami` with `Authorization: Bearer <JWT>`. Require success and inspect `iss`, `aud`, `sub`, `exp`, and `roles`.
4. Verify negative cases: alter the signature, use a different `kid`/unknown key, change `iss`, change `aud`, expire `exp`, and remove the required signature. Each must fail bearer authentication. For DAB itself, repeat via configured REST and GraphQL entities and assert role permission outcomes under #10; a harness proves IdentityModel retrieval/validation only, not DAB Core integration.
5. Confirm metadata/JWKS retrieval has no `Authorization` header and succeeds from the DAB host network context. Test the Windows-authenticated issuer routes separately and record the actual request identity.

For a lower-level retrieval test, the exact upstream sample shape is:

```csharp
var manager = new ConfigurationManager<OpenIdConnectConfiguration>(
    issuer + "/.well-known/openid-configuration",
    new OpenIdConnectConfigurationRetriever(),
    new HttpDocumentRetriever { RequireHttps = true });

var configuration = await manager.GetConfigurationAsync(CancellationToken.None);
Assert.Equal(issuer, configuration.Issuer);
Assert.Contains(configuration.SigningKeys, key => key.KeyId == expectedKeyId);
```

The `ConfigurationManager` caches and refreshes metadata, so hold it as a singleton in a hosted consumer instead of constructing one per request. An IdentityModel issue contains the same concrete `ConfigurationManager` + `OpenIdConnectConfigurationRetriever` retrieval example, though the source implementation and current docs above are the authority for behavior. [IdentityModel issue with retrieval example](https://github.com/AzureAD/azure-activedirectory-identitymodel-extensions-for-dotnet/issues/2511)

## Current implementation gap

The current source has the core shape already:

- `Program.cs` maps `/.well-known/openid-configuration` to `issuer` and `jwks_uri`, and maps `/.well-known/jwks.json` to `JwtIssuer.CreatePublicKeySet()` without `.RequireAuthorization()`.
- `/session` and `/session/logout` require authorization and antiforgery validation.
- `JwtIssuer` signs `RS256` with `kid`, and includes `iss`, `aud`, `sub`, time claims, and `roles`.
- The HTTP tests exercise metadata/JWKS shape and token cookie issuance, but do not feed the metadata through the real .NET configuration retriever, nor do they prove DAB can retrieve and use the key. Ticket #10 remains the place to prove embedded DAB REST/GraphQL validation and role enforcement.

The remaining discovery-specific proof is a real retrieval/validation run from a consumer context and confirmation of host-level anonymous access for only metadata/JWKS. The accepted wording is explicit: with this flow, describe the endpoint as DAB JWT key-discovery metadata, not a complete OpenID Connect Provider discovery document.

## Sources

- [DAB custom JWT authentication](https://learn.microsoft.com/en-us/azure/data-api-builder/concept/security/authenticate-custom)
- [IdentityModel OpenIdConnectConfigurationRetriever.cs](https://github.com/AzureAD/azure-activedirectory-identitymodel-extensions-for-dotnet/blob/dev/src/Microsoft.IdentityModel.Protocols.OpenIdConnect/Configuration/OpenIdConnectConfigurationRetriever.cs)
- [IdentityModel OpenIdConnectConfiguration.cs](https://github.com/AzureAD/azure-activedirectory-identitymodel-extensions-for-dotnet/blob/dev/src/Microsoft.IdentityModel.Protocols.OpenIdConnect/Configuration/OpenIdConnectConfiguration.cs)
- [IdentityModel HttpDocumentRetriever.cs](https://github.com/AzureAD/azure-activedirectory-identitymodel-extensions-for-dotnet/blob/dev/src/Microsoft.IdentityModel.Protocols/Configuration/HttpDocumentRetriever.cs)
- [ASP.NET Core JwtBearerPostConfigureOptions.cs](https://source.dot.net/Microsoft.AspNetCore.Authentication.JwtBearer/JwtBearerPostConfigureOptions.cs.html)
- [JwtBearerOptions.ConfigurationManager (.NET 10)](https://learn.microsoft.com/en-us/dotnet/api/microsoft.aspnetcore.authentication.jwtbearer.jwtbeareroptions.configurationmanager?view=aspnetcore-10.0)
- [ASP.NET Core JWT bearer authentication (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/configure-jwt-bearer-authentication?view=aspnetcore-10.0)
- [Microsoft.AspNetCore.Authentication.JwtBearer 10.0.12](https://www.nuget.org/packages/Microsoft.AspNetCore.Authentication.JwtBearer/10.0.12)
- [OpenID Connect Discovery 1.0, Provider Metadata](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata)
- [OpenIddict .NET samples](https://github.com/openiddict/openiddict-samples)
- [IdentityModel issue showing ConfigurationManager retrieval](https://github.com/AzureAD/azure-activedirectory-identitymodel-extensions-for-dotnet/issues/2511)
