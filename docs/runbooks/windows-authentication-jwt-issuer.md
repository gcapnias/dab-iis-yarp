# Run the Windows Authentication JWT issuer prototype

This runbook creates the separate ASP.NET Core .NET 10 identity issuer used by the DAB architecture proof. The issuer authenticates a Windows request, maps the caller's SID to an explicitly provisioned ASP.NET Core Identity user, reads that user's profile and roles from SQL Server, and issues a short-lived RS256 JWT in an HttpOnly cookie. It does not host DAB, accept a client-selected identity or role, or establish DAB compatibility.

Research notes: [ASP.NET Identity and SQL Server design](../../archive/research/aspnet-identity-net10-issuer.md) and [Windows, JWT discovery, and browser cookie contracts](../../archive/research/aspnet-windows-jwt-cookie-contracts.md). The generated schema-only migration is [IdentityIssuerInitialCreate.sql](../../archive/research/identity-issuer/IdentityIssuerInitialCreate.sql); its source is under `src/IdentityIssuer/Migrations/`.

## Contract

| Token value | Source | Purpose |
| --- | --- | --- |
| `iss` | `Issuer:Url` | Must match DAB's configured issuer exactly, including any trailing slash. |
| `aud` | `Issuer:Audience` | Resource identifier configured as DAB's audience. |
| `sub` | ASP.NET Identity user `Id` | Stable subject for this issuer. |
| `profile_id` | Persisted `ApplicationUser.ProfileId` | Opaque profile reference; it grants no access on its own. |
| `name` | Persisted optional `ApplicationUser.DisplayName` | Display-only profile claim. |
| `roles` | Persisted Identity user-to-role assignments | Role names emitted as an array; DAB requires this exact claim type. |
| `iat`, `nbf`, `exp` | Issuer clock and configured lifetime | Lifetime is 1–60 minutes; the default is 10. |

Tokens use `RS256` and `typ=at+jwt`. The issuer publishes the public RSA key at `/.well-known/jwks.json` and the issuer/key location at `/.well-known/openid-configuration`. The private key stays in a restricted local or managed secret file. This prototype exposes metadata and keys for JWT validation; it does not implement an OAuth authorization-code flow. DAB validation of the metadata/token contract remains for ticket #10.

The browser cookie is named `dab_access_token`, `HttpOnly`, `Secure`, `SameSite=Lax`, host-only by default, scoped to `/`, and expires with the JWT. `Issuer:CookieDomain` is optional and should be set only after choosing a shared DNS trust boundary for the issuer and embedded application. The issuer provides a request token at `/csrf`; callers must send it in `X-CSRF-TOKEN` for both `POST /session` and `POST /session/logout`. The embedded application's cookie-to-bearer bridge must validate CSRF again before forwarding the JWT to DAB.

## Requirements and preparation

- .NET 10 SDK. This worktree used SDK 10.0.401 and runtime 10.0.12.
- A Windows host configured for Windows Authentication. For IIS, install/enable its Windows Authentication role service and disable anonymous access for the issuer site. For local Kestrel, use the Negotiate handler on Windows and an approved Windows test identity.
- An authorized development SQL Server database named `northwind` and a connection string for it. The DAB proof's existing Northwind use is read-only. This issuer adds tables only under a separate `IdentityIssuer` schema, but applying that schema still requires explicit development DDL authorization and an approved backup/target.
- An RSA private key of at least 2048 bits, stored outside the repository and readable only by the issuer process identity.
- One operator-approved Windows SID, profile ID, display name, and initial role set to provision for testing.

The checked-in migration has been generated but not applied. Do not point `database update` at Northwind until the database owner has approved schema creation on the named development instance. Do not use a production database.

The repository pins EF tooling to `10.0.12` in `.config/dotnet-tools.json`. Run `dotnet tool restore` before using `dotnet ef` on a new checkout.

## Create and configure

The runnable project is [IdentityIssuer.csproj](../../src/IdentityIssuer/IdentityIssuer.csproj). It targets `net10.0` and pins Identity EF Core, EF Core SQL Server, EF Core Design, and Negotiate to `10.0.12`. The separate DAB host remains on `Microsoft.DataApiBuilder.Core` `2.0.12` and is not referenced by this project.

Copy the safe example settings and provide secrets using the local .NET User Secrets store or the approved secret provider for the host:

```powershell
Copy-Item src/IdentityIssuer/appsettings.example.json src/IdentityIssuer/appsettings.Development.json
dotnet user-secrets set "ConnectionStrings:IssuerIdentity" "<approved Northwind development connection string>" --project src/IdentityIssuer/IdentityIssuer.csproj
```

Keep the actual connection string out of tracked files, command output, issue comments, and evidence. The app rejects a connection string whose initial catalog is not `northwind`. Set `Issuer:Url`, `Issuer:Audience`, `Issuer:KeyId`, `Issuer:SigningKeyPath`, `Issuer:LifetimeMinutes`, and `WindowsAuthentication:Mode` in local settings. Use an HTTPS issuer URL in non-development environments. `Mode` is `IIS` for IIS integration or `Negotiate` for Kestrel.

Generate a private PKCS#8 key on the trusted host and store it outside the repository. For example, run this in a protected PowerShell session after choosing a restricted path:

```powershell
$issuerRsa = [System.Security.Cryptography.RSA]::Create(3072)
[System.IO.File]::WriteAllText('C:\secure\issuer-rsa-private.pem', $issuerRsa.ExportPkcs8PrivateKeyPem())
$issuerRsa.Dispose()
```

Set `Issuer:KeyId` to a non-secret identifier for that key. Never commit or copy the private key into an artifact. This prototype publishes one active signing key at a time; rotate after existing tokens expire and verify the DAB key refresh behavior in ticket #10.

## Review and apply the Identity schema

The `ApplicationDbContext` derives from `IdentityDbContext` and maps ASP.NET Identity tables plus two custom profile fields into schema `IdentityIssuer`. It adds unique indexes for `WindowsSid` and `ProfileId`. The idempotent migration also places EF's migration-history table in that schema. It does not create or alter Northwind sample tables.

To generate a migration after an approved model change, set `ConnectionStrings__IssuerIdentity` in the process environment to the approved Northwind development connection string, then run:

```powershell
dotnet ef migrations add <MigrationName> --project src/IdentityIssuer/IdentityIssuer.csproj --output-dir Migrations
dotnet ef migrations script --idempotent --project src/IdentityIssuer/IdentityIssuer.csproj --output .scratch/identity-issuer-migration.sql
```

Review the SQL script and its target before applying it. The generated script for the current model is already preserved under `archive/research/identity-issuer/`. Only after explicit DDL authorization, apply the migration with `dotnet ef database update --project src/IdentityIssuer/IdentityIssuer.csproj`. Startup does not automatically migrate the database.

## Provision a test identity

After the approved migration has been applied to the authorized development database, run the local operator command:

```powershell
dotnet run --project src/IdentityIssuer/IdentityIssuer.csproj -- --provision-identity
```

The console prompts for the Windows SID, opaque `ProfileId`, optional display name, and roles. It creates an ASP.NET Identity user with no password sign-in, creates only the explicitly entered roles that do not already exist, and attaches the user to those roles in a transaction. It has no web registration or role-selection endpoint. Do not derive roles from client input, request headers, or unreviewed Windows groups. Provision only test values approved for the development proof.

## Start and verify

Start the app under its configured Windows Authentication host. On local Kestrel, use the HTTPS development endpoint:

```powershell
dotnet run --project src/IdentityIssuer/IdentityIssuer.csproj --urls https://localhost:5001
```

Check the metadata and JWKS over HTTPS. Confirm the metadata `issuer` exactly matches the `iss` claim produced in a token; confirm that the JWKS has the configured `kid`, RSA `n` and `e`, and no private parameters. A browser client first GETs `/csrf`, retains the antiforgery cookie and request token, then POSTs `/session` with `X-CSRF-TOKEN`. A successful response sets the JWT cookie without returning the token in the response body. Logout uses the same antiforgery contract at `POST /session/logout` and clears the cookie.

Verify the token's signature with the published JWK and inspect only sanitized claims: `iss`, `aud`, `sub`, `profile_id`, optional `name`, `roles`, `iat`, `nbf`, and `exp`. Test an unauthenticated request, unknown SID, SID mismatch, user without roles, invalid CSRF token, and logout. Never put a raw JWT, SID, display name, email, or database credential in tracked evidence or issue comments.

The test suite can be run without database access:

```powershell
dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj
```

Its HTTP tests use a test-only authentication handler and fixture directory; EF user/role lookup uses an isolated in-memory provider. Those tests verify the issuer pipeline and Identity behavior but do not prove Windows Authentication or the SQL Server connection. The SQL Server model test checks mapping and unique constraints without connecting to the database.

## Proposed embedded DAB integration

The browser sends the issuer cookie to an application-owned endpoint on the embedded DAB host. Ticket #10 must validate the cookie's issuer contract, enforce a CSRF token on state-changing requests, extract the JWT server-side, and forward it to DAB as `Authorization: Bearer <token>`. The browser must not read the HttpOnly JWT or choose a DAB role it does not hold. Same-origin or explicitly configured same-site cookie scope is required; cross-site `SameSite=None` behavior requires `Secure` and a separate review. REST/GraphQL compatibility, DAB permission enforcement, cookie scope across the actual hosts, and CORS are unproven here.

## Troubleshooting and limits

- **401 from `/session`:** verify IIS Windows Authentication is enabled, anonymous access is disabled as intended, the client can negotiate with the host, and the selected principal is a Windows identity.
- **403 from `/session`:** the authenticated SID has no mapped Identity user, does not match the stored `WindowsSid`, or has no persisted role assignment.
- **400 from `/session` or logout:** fetch a current `/csrf` request token and send it in `X-CSRF-TOKEN` along with its antiforgery cookie.
- **JWT rejected by DAB:** compare configured issuer, token `iss`, audience, expiry, signature, published `kid`/JWKS, and exact `roles` claim spelling. DAB validation remains a ticket #10 proof.
- **SQL error at issuance:** verify the approved connection, that the migration was reviewed/applied, and that the issuer process identity may read/write the `IdentityIssuer` schema as needed. Do not diagnose from a partial import or create tables without approval.

The implementation proof is not a production deployment. It does not yet establish a live Windows-host/test-identity chain, a live Northwind-backed Identity lookup, multi-key signing rollover, token revocation, an OAuth authorization-code flow, or actual embedded-DAB REST/GraphQL validation.
