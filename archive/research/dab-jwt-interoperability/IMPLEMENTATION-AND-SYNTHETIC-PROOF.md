# Embedded DAB JWT interoperability: implementation and synthetic proof

Date: 2026-10-03. DAB: `Microsoft.DataApiBuilder.Core` 2.0.12. Runtime: .NET 10.

## Result

The embedded host now translates the issuer's `dab_access_token` cookie into an HTTP bearer credential before authentication middleware runs. DAB Core's own Custom-provider `JwtBearerHandler` validates that credential through the configured issuer discovery document and JWKS, including signature, exact issuer and audience, token lifetime, and the `roles` claim. REST and GraphQL continue through the same-process DAB engine and its configured entity permissions.

Cookie-authenticated unsafe requests require an antiforgery token and an exact same-origin `Origin` header. The host extracts the cookie before DAB authentication, then validates the request after DAB has populated the authenticated caller; this order is required because ASP.NET Core antiforgery tokens are bound to that identity. `GET /bridge/csrf` returns a non-cacheable request token and sets a host-only, Secure, HttpOnly, SameSite=Strict antiforgery cookie. No CORS policy is added. Requests with an explicit `Authorization` header keep that credential and do not fall back to the cookie. [Microsoft's antiforgery guide](https://learn.microsoft.com/en-us/aspnet/core/security/anti-request-forgery?view=aspnetcore-10.0) documents rejection when the token does not match the authenticated identity.

## Pinned-provider composition

DAB 2.0.12 maps a `Custom` provider to its `OAuthAuthentication` JWT bearer scheme. The application registers this scheme and the other provider schemes used by DAB's Development-mode request-time provider selection. It also registers Core's public `ConfigureJwtBearerOptions`, which reads the active DAB configuration to set `Authority`, audience, issuer validation, and the exact `roles` role-claim type. This uses the same DAB JWT handler that performs runtime authentication; the host does not implement token validation or grant access itself.

The configuration fixture at [`jwt-interoperability.json`](../../../src/EmbeddedDab/configurations/jwt-interoperability.json) uses the pinned Custom provider, an issuer supplied at process start, a fixed test audience, and `reader`/`writer` permissions. The host accepts `DAB_CONFIG_FILE` for an explicit configuration path; ordinary runs retain `dab-config.json` as the default.

Primary-source contracts:

- [DAB 2.0.12 `Startup.ConfigureAuthenticationV2`](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Service/Startup.cs) registers the JWT bearer and provider schemes in Development mode.
- [DAB 2.0.12 `ClientRoleHeaderAuthenticationMiddleware`](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/AuthenticationHelpers/ClientRoleHeaderAuthenticationMiddleware.cs) selects `OAuthAuthentication` for Custom providers, validates bearer credentials, and allows `X-MS-API-ROLE` only after authentication.
- [DAB 2.0.12 `ConfigureJwtBearerOptions`](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/AuthenticationHelpers/ConfigureJwtBearerOptions.cs) configures issuer, audience, and the `roles` claim for the JWT handler.
- [Microsoft's Custom JWT provider guide](https://learn.microsoft.com/en-us/azure/data-api-builder/concept/security/authenticate-custom) describes discovery/JWKS signature validation, issuer/audience/expiry checks, and the exact `roles` claim contract.
- Issuer cookie scope, expiry, and same-origin/CSRF behavior are recorded in the [issuer runbook](../../../docs/runbooks/windows-authentication-jwt-issuer.md) and [issuer live proof](../identity-issuer/live-proof-2026-10-02.md).

## Reproduction

From a checkout with .NET 10 and the primary checkout's ignored `.env` pointing to the approved development SQL Server:

```powershell
./scripts/test-embedded-dab-jwt.ps1
```

The script creates a uniquely named `dab_ticket9_<12 hex>` database with the existing fixture helper, invokes the .NET Release integration suite, and removes that database in `finally`. It leaves `Northwind` unchanged. The integration test hosts a local synthetic OIDC discovery/JWKS endpoint and generates issuer-format tokens in memory using the existing `IdentityIssuer.JwtIssuer`; it does not log token or key values. The test-only `RequireHttpsMetadata=false` setting applies to the local HTTP metadata endpoint in the in-memory DAB test host. It is not configured in the product host or intended for real issuer runs.

## Sanitized verification

Latest command: `./scripts/test-embedded-dab-jwt.ps1`.

- Embedded host Release build: passed, zero warnings and zero errors.
- Test Release build: passed, zero warnings and zero errors.
- Automated tests: **10 passed, 0 failed, 0 skipped**.
- Disposable fixture database: prepared and then removed by the script.
- Real DAB Custom provider: discovered the synthetic issuer and JWKS, accepted current tokens signed by the published key, and rejected malformed, expired, wrong-signature, wrong-issuer, and wrong-audience tokens in separately named REST and GraphQL cases. The expired JWT has a valid `nbf`/`exp` interval and an expiry more than five minutes in the past.
- REST and GraphQL: a `reader` token read the fixture through both transports. A `writer` token created/deleted disposable rows through REST and GraphQL. A `reader` mutation was rejected. Missing credentials, missing `roles`, and a requested `writer` role absent from a `reader` token were denied.
- Cookie bridge: a cookie token reached the real DAB engine for REST and GraphQL reads and writer mutations. Explicit bearer credentials took precedence over a present access cookie. The issuer access-cookie response contract was checked for host-only scope, `Path=/`, Secure, HttpOnly, SameSite=Lax, explicit expiry, and logout expiry. A missing/cleared cookie did not create an authenticated request; an expired JWT delivered as a cookie was rejected by DAB.
- CSRF and permissions: identity-bound tokens issued by the actual embedded host allowed writer cookie mutations through REST and GraphQL. Missing or wrong CSRF tokens and foreign Origins were rejected on both transports; a token issued to another caller was rejected. A reader with a valid CSRF token still could not mutate through either transport. DAB rejected a GraphQL mutation sent by GET with HTTP 405, so it cannot bypass the unsafe-method check. The former stand-in host was removed from bridge behavior testing because it did not authenticate the caller as DAB does.

No credentials, personal profile values, raw JWTs, authorization codes, refresh tokens, or private keys are present in the source, test output, or report.

## Evidence boundary

These tests are controlled synthetic evidence. They establish that issuer-shaped RS256 JWTs and the issuer cookie contract interoperate with the actual embedded DAB 2.0.12 Custom provider on a disposable SQL schema. The signing key and discovery server are generated solely for the test; identity and roles are fixture values.

This result does not establish the live Windows caller-to-SQL Identity profile/roles-to-JWT/cookie-to-DAB chain, browser delivery under a real origin, or trusted TLS between the applications. Those remain local interoperability acceptance work for this ticket. Windows Server/IIS behavior, external IIS/proxy access-log handling, and production deployment are separate later evaluation or delivery work. The synthetic proof alone is not an end-to-end go finding.

The subsequent [live proof](LIVE-PROOF.md) records the completed local Windows/database/browser chain, the explicitly approved Development-only developer-certificate pin, and the later 12-test regression result. This document preserves the original ten-test synthetic implementation evidence.
