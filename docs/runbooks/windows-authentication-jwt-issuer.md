# Run the Windows Authentication OIDC/JWT issuer

This standalone ASP.NET Core 10 app authenticates a Windows request, maps the request principal's SID to an operator-provisioned ASP.NET Core Identity account, loads persisted profile claims and roles, and acts as a real OpenID Connect Provider. It also has a first-party session-cookie bridge for the separate DAB embedding work. The issuer does not host DAB. The actual cookie-to-DAB bearer bridge and DAB REST/GraphQL authorization proof belong to ticket #10.

Primary-source research: [.NET 10 Identity and SQL Server](../../archive/research/aspnet-identity-net10-issuer.md), [Windows request-principal SID binding](../../archive/research/identity-issuer/windows-principal-identity-binding.md), [OpenIddict discovery and OIDC client behavior](../../archive/research/identity-issuer/discovery-implementation-details.md), and the [user-supplied Windows Authentication artifact](../../archive/research/windows-authentication-in-net-identity.md). The complete current schema script is [here](../../archive/research/identity-issuer/IdentityIssuer-current-idempotent.sql); live Kestrel/SQL evidence is [here](../../archive/research/identity-issuer/live-proof-2026-10-02.md).

## Local configuration and startup

The tracked [appsettings.json](../../src/IdentityIssuer/appsettings.json) contains safe local defaults for issuer URL/audience, cookies, Negotiate, key paths, lifetime, and the local public OIDC client. It contains no database credential or signing material. Supply `ConnectionStrings:IssuerIdentity` from the authorized local environment variable, .NET user secrets, or the primary checkout's ignored `.env` file. The startup script reads that file into process memory without printing it.

From the assigned worktree, run:

```powershell
.\scripts\run-identity-issuer.ps1
```

The script resolves the primary checkout even when launched from a linked worktree. It verifies both key paths are gitignored before it creates RSA-3072 signing and encryption keys; the keys are generated only when absent under the ignored primary path `.scratch/identity-issuer/keys/` and survive app restarts. The script does not install, trust, or provision an HTTPS certificate. A valid localhost development certificate must already exist. The PowerShell test harness bypasses certificate validation only for an HTTPS URL whose host is exactly `localhost`; it does not validate the certificate chain or subject name. This loopback-only test bypass is not production TLS validation.

The project targets `net10.0`. ASP.NET Core Identity EF Core, EF Core SQL Server/Design, and Negotiate are pinned to `10.0.12`; OpenIddict ASP.NET Core and EF Core are pinned to `7.7.1`. DAB Core remains on its separate `2.0.12` baseline and is not referenced here. The issuer uses the configured SQL Server catalog; `Northwind` is only the authorized disposable proof target, not a runtime requirement.

## Database and operator provisioning

`ApplicationDbContext` maps standard Identity and OpenIddict persistence plus `RefreshTokens` into the dedicated `IdentityIssuer` schema. The user table has unique Windows SID and profile ID indexes, an explicit `IsEnabled` switch, and normal Identity lockout/security-stamp fields. Migrations are never applied at startup.

Restore the pinned tool once, inspect the target, generate and review an idempotent script, then apply only to an explicitly authorized development database:

```powershell
dotnet tool restore
dotnet ef migrations list --project src/IdentityIssuer/IdentityIssuer.csproj
dotnet ef migrations script --idempotent --project src/IdentityIssuer/IdentityIssuer.csproj --output .scratch/identity-issuer-migration.sql
dotnet ef database update --project src/IdentityIssuer/IdentityIssuer.csproj
```

All five migrations are applied to the authorized disposable Northwind database for the recorded proof. The checked-in idempotent script creates objects only in `IdentityIssuer`; it has no `DROP` or sample-data DML. It includes ASP.NET Identity, OpenIddict Applications/Authorizations/Scopes/Tokens, refresh-token storage, replay markers with token expiry, and the schema-local EF migration history. Verify the destination and review the generated SQL before applying this to any other database.

Provision identities only through a trusted local operator command:

```powershell
dotnet run --project src/IdentityIssuer/IdentityIssuer.csproj -- --provision-identity
```

The command prompts for a Windows SID, opaque profile ID, optional display name, explicitly granted role names, and an optional `ClearanceLevel` claim. It uses `UserManager` and `RoleManager` in a transaction. It creates no password or web registration path. The API accepts no client-selected identity or role. The current claim contract copies only a single non-empty `ClearanceLevel` value from persisted user/role claims; conflicting values fail closed. Other claims such as email and security stamps are not emitted as authorization claims. Never put a SID or real profile values in command history, logs, test fixtures, or evidence.

Register the configured native OIDC client after applying migrations:

```powershell
dotnet run --project src/IdentityIssuer/IdentityIssuer.csproj -- --provision-oidc-client
```

This is an idempotent, local operator command for the exact configured HTTPS redirect URI. The client is public, uses authorization code with PKCE, and has only the configured issuer scopes.

## OIDC and session contracts

OpenIddict serves a genuine OpenID Connect Discovery document at `/.well-known/openid-configuration` and the corresponding public RSA JWKS at `/.well-known/jwks`. Discovery describes the implemented authorization and token endpoints, authorization-code and refresh grants, scopes, response types, signing algorithm, and PKCE methods. Anonymous GET access to discovery/JWKS is required so server-side relying parties can bootstrap signing-key retrieval without a browser credential. The authorization endpoint authenticates the current Windows request before resolving its SID. The registered native client redeems the code with its PKCE verifier at the token endpoint. The token endpoint accepts protocol grants only; invalid code, verifier, client, refresh token, or replay is rejected. Refresh-token use markers are persisted by token and authorization family; replay revokes the family and causes remaining descendants to fail.

OIDC ID tokens identify the Identity user as `sub`; access tokens carry `profile_id`, persisted `roles`, and the allowlisted `ClearanceLevel` claim. Tokens are signed with RS256 and are not access-token encrypted, so resource servers can validate them from the public JWKS. Identity lockout, `IsEnabled`, and security-stamp changes are checked before new Windows sessions and before OIDC refresh grants. Already-issued access JWTs are stateless and remain usable by a downstream validator until their short expiry; logout cannot revoke a JWT already copied by another service. Keep the access lifetime short and enforce revocation/session policy in the consuming application where needed.

For cookie-based first-party embedding, the protected endpoints are:

| Endpoint | Purpose | Access |
| --- | --- | --- |
| `GET /csrf` | Issue the antiforgery cookie and request token | Windows Authentication |
| `POST /session` | Resolve current SID and set the short-lived `dab_access_token` cookie plus a separate refresh cookie | Windows Authentication + antiforgery |
| `POST /session/refresh` | Rotate the persisted cookie refresh-token family and renew the access cookie | Windows Authentication + antiforgery |
| `POST /session/logout` | Revoke the refresh-token family and expire both cookies | Windows Authentication + antiforgery |

The access cookie is `HttpOnly`, `Secure`, `SameSite=Lax`, host-only by default, and has an explicit `Expires` matching its JWT expiry. The refresh cookie is a distinct opaque random secret, `HttpOnly`, `Secure`, `SameSite=Strict`, and scoped to the issuer path; its explicit `Expires` matches the persisted refresh record's absolute `ExpiresAt`. Rotation keeps the same family lifetime rather than extending it indefinitely. Only a SHA-256 hash of a refresh token is stored. Rotation marks each token consumed; replay revokes the whole family. OIDC refresh tokens use the configured absolute lifetime. OIDC replay markers remain until the consumed token's original expiration; after it expires, OpenIddict rejects replay without the marker. For an orphan marker whose token entry was already pruned, the migration uses a conservative 30-day expiry from consumption, matching the configured maximum refresh-token lifetime. Disabled, locked, mismatched, expired, or security-stamp-changed accounts cannot refresh. Daily cleanup removes expired custom refresh rows and OIDC replay markers, and prunes old invalid OpenIddict tokens/authorizations after 30 days. Session-cookie logout clears cookies and revokes refresh, while access JWTs already issued remain valid until expiry.

The browser bridge currently has a same-origin request contract: a browser client calls `/csrf`, `/session`, `/session/refresh`, and `/session/logout` on the issuer origin with credentials included. The app does not enable CORS. `CookieDomain` is unset by default, making the access cookie host-only; the refresh cookie stays path-scoped to the issuer. Setting a shared cookie domain does not grant cross-origin JavaScript access, and `SameSite=Lax`/`Strict` still govern browser sending rules. Any DAB or separate-origin bridge needs a separately validated origin and cookie contract under ticket #10.

The proposed DAB bridge is a same-origin or explicitly same-site application endpoint: the browser sends the HttpOnly cookie; the app validates antiforgery on state-changing calls, reads the cookie server-side, and forwards its access JWT as a bearer token to embedded DAB. The browser never reads the JWT or chooses roles. Ticket #10 must validate actual cookie scope, host behavior, forwarding, and DAB REST/GraphQL permissions.

## Key rollover

The active private key is at `Issuer:SigningKeyPath`; its configured `KeyId` is included in signed tokens. To rotate, generate a new active key and configure the outgoing active private key temporarily under `Issuer:PreviousSigningKeys` with its original key ID and restricted `PrivateKeyPath`. The issuer publishes the active and overlap public keys together while signing with the new active key. Verify that a token from each key validates through JWKS. Keep the previous private key accessible only for the overlap deployment, then remove it after the maximum access-token lifetime and relying-party cache window have elapsed. The sample automated suite proves overlapping JWKS keys and validation of a prior-key token. Never commit private key material; local development keys remain in ignored `.scratch`.

## Run verification

Run automated tests and the real local HTTP integration harness:

```powershell
dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj
.
scripts\test-identity-issuer.ps1
```

The harness uses PowerShell 7 `UseDefaultCredentials` for Windows Negotiate and skips certificate validation only for `https://localhost` (the development certificate chain and subject are not validated by that client). It prints HTTP statuses, identity runtime type, and SID-presence booleans. It never prints a SID, account/profile value, code, cookie, JWT, refresh token, or connection string. It checks anonymous discovery/JWKS, anonymous denial, antiforgery, secure cookie flags, JWT signature/issuer/audience/lifetime/claims, refresh rotation/replay/logout, and a full Windows-authenticated authorization-code/PKCE/token/refresh flow.

The accompanying [HTTP request file](../../requests/windows-jwt-issuer.http) is suitable for anonymous metadata and negative unauthenticated requests. VS Code REST Client does not supply default Windows credentials; use the PowerShell harness for successful Windows-authenticated requests. The development-only `/diagnostics/windows-auth` endpoint reports the request identity type and whether SID claims/request token SID exist, never their values.

The tests also reject wrong issuers, audiences, expiry, unknown key IDs, tampered signatures, unmapped SIDs, disabled/locked accounts, roleless users, and conflicting claims. Fixture tests use isolated in-memory data and are separate from the live SQL/Windows proof.

## Windows Server IIS browser test

`scripts/publish-identity-issuer.ps1 -OutputDirectory <directory-outside-checkout>` produces the framework-dependent `net10.0` IIS publish output and SDK-generated `web.config`; private signing/encryption keys are never included. The target test server must already have IIS/WAS, the .NET 10 Hosting Bundle and ANCM v2, a test site binding, and Microsoft Edge. This repository does not install those prerequisites or alter server features.

Deploy the publish output to a dedicated test application and configure its existing app pool to use `ApplicationPoolIdentity` with no administrator membership. Configure the issuer URL, audience, signing/encryption key file paths, Identity SQL connection string, OIDC client ID/redirect URI, and `WindowsAuthentication:Mode=IIS` using the test site's approved secret/configuration mechanism. The app pool needs read/execute access to publish output and read access only to the configured private-key files. If integrated SQL authentication is used, the selected app-pool identity needs the minimum required access to the isolated `IdentityIssuer` schema. Provision an authorized synthetic Windows SID mapping, enabled Identity user, role, and allowlisted claim in the development database before testing.

At the IIS site, enable both Anonymous Authentication and Windows Authentication. Anonymous access is required for discovery/JWKS and OAuth protocol retrieval; the issuer's authorization fallback still requires Windows Authentication for the session endpoints, and `/connect/authorize` explicitly authenticates the request Windows principal. The browser verifier requires the Development environment: it checks `/diagnostics/windows-auth` and uses `/oidc-browser-test/callback` as a real same-origin public-client callback. The callback returns only an inert no-store HTML page; the verifier performs the code/PKCE exchange in that browser page. Neither test route is available in production.

Provision a dedicated public PKCE browser client with the **exact issuer origin and application path** as its redirect URI. For local Kestrel, the existing ignored `.env` and keys can be used without printing them:

```powershell
pwsh .\scripts\run-identity-issuer.ps1 -ProvisionBrowserClient -Url https://localhost:5001
```

This registers `dab-issuer-browser-test-client` with `https://localhost:5001/oidc-browser-test/callback` in the authorized development Identity store. It does not replace the separate native client used by the PowerShell protocol harness. On an IIS test site, provision a distinct browser client with the site's exact HTTPS issuer origin and application path using the documented operator command and configuration overrides. The issuer intentionally grants no token-endpoint CORS access to a separate-origin callback.

Run the installed Playwright CLI verifier from this checkout, in an interactive logon for the intended Windows test account:

```powershell
pwsh .\scripts\test-identity-issuer-iis.ps1 `
  -Issuer 'https://issuer-test.example/identity' `
  -ClientId 'the-provisioned-browser-public-client-id' `
  -RedirectUri 'https://issuer-test.example/identity/oidc-browser-test/callback' `
  -AccessAudience 'the-configured-resource-audience'
```

The test uses Microsoft Edge with Chromium's process-scoped `--auth-server-allowlist=<issuer-host>` flag, so it exercises the current Windows account's browser-integrated authentication without editing machine-wide browser policy. The script writes a temporary CLI config/source under gitignored `.scratch`, uses an isolated non-persistent context, and prints only check names, statuses, and booleans. It does not save browser state, traces, screenshots, request/response dumps, tokens, cookies, codes, identities, or profiles.

The test-only browser config is [playwright-cli.iis-test.config.json](../../requests/playwright-cli.iis-test.config.json):

```json
{
  "browser": {
    "contextOptions": {
      "ignoreHTTPSErrors": true
    }
  }
}
```

This setting allows local/self-signed certificates in test Kestrel and Windows Server IIS test environments without installing or trusting them in the workstation certificate store. It bypasses certificate-chain and hostname validation in the browser test; it is not an application TLS setting and does not establish production certificate validity. Production browsers and resource clients should perform normal HTTPS certificate validation.

The browser check validates discovery issuer, Windows request identity type/SID-presence booleans, antiforgery rejection, session creation, cookie attributes and JavaScript invisibility, refresh replacement/replay, logout, callback state and origin, code/PKCE exchange, signed ID/access tokens, and OIDC refresh replay-family revocation. The earlier separate-origin callback run stopped before token exchange; the corrected same-origin local Kestrel run passed every browser check with exit 0. [Ticket #13](https://github.com/gcapnias/dab-iis-yarp/issues/13) records the investigation and exact local evidence. A passing local Kestrel browser run is separate from IIS evidence. The IIS result remains pending under [ticket #12](https://github.com/gcapnias/dab-iis-yarp/issues/12), which owns execution on an identified Windows Server endpoint with existing prerequisites, provisioned test client, and synthetic Windows-to-Identity mapping.

## Evidence and limits

The current live record is [live-proof-2026-10-02.md](../../archive/research/identity-issuer/live-proof-2026-10-02.md), with the requirement coverage matrix in [implementation-report.md](../../archive/research/identity-issuer/implementation-report.md). Real Kestrel/Negotiate, SQL-backed Identity, cookies, discovery/JWKS, OIDC PKCE, and refresh were exercised. The test workstation has no W3SVC/WAS, `appcmd.exe`, or ANCM v2; no IIS features, bundles, browsers, or certificates were installed or enabled. The deployable IIS browser verification is prepared, but its live result is pending the external Windows Server test site. Actual DAB REST/GraphQL compatibility remains ticket #10.
