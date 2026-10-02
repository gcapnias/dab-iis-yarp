# Sanitized live issuer proof

Date: 2026-10-02. Host: local Windows 11, ASP.NET Core 10 Kestrel, HTTPS loopback, SQL Server disposable Northwind database. The evidence contains no connection string, user name, SID, profile identifier, token, authorization code, cookie value, or private key.

## Database state

All five reviewed migrations are applied:

- `20261001152500_IdentityIssuerInitialCreate`
- `20261002042057_AddOpenIddictAndRefreshTokens`
- `20261002054856_OidcRefreshReplayProtection`
- `20261002061343_OidcRefreshMarkerExpiry`
- `20261002062249_BoundOidcRefreshMarkerOrphans`

A read-only database probe before the three latest additive migrations listed 13 base tables in `IdentityIssuer`: `__EFMigrationsHistory`, the seven ASP.NET Identity role/user tables, `OpenIddictApplications`, `OpenIddictAuthorizations`, `OpenIddictScopes`, `OpenIddictTokens`, and `RefreshTokens`. It also confirmed Northwind `Categories`, `Customers`, `Orders`, and `Products` remained present. The additive migrations add `OidcRefreshTokenUses`, its consumed-token expiry column, and a finite expiry backfill for orphan markers whose OpenIddict token row has been pruned. The regenerated complete idempotent SQL has 14 `CREATE TABLE` statements, zero `DROP` statements, and no Northwind sample-table references. No Northwind sample rows were changed by the issuer migrations.

One synthetic Identity profile is mapped to the current Windows account's request SID, with one operator-granted role and one allowlisted persisted `ClearanceLevel` claim. No identity values were queried into or printed with this report.

## Live Kestrel and Windows-auth results

`scripts/run-identity-issuer.ps1` launched the app on `https://localhost:5001`, and `scripts/test-identity-issuer.ps1` used PowerShell 7 default Windows credentials. The startup script verified both key paths were gitignored before creating RSA-3072 keys, created them only if absent, and left them in the primary repository's ignored `.scratch/identity-issuer/keys/` directory. `git check-ignore` confirmed that directory is ignored. A valid but untrusted localhost development certificate was already present; no trust store or IIS configuration was changed. The request harness skipped certificate chain and subject validation only for the exact `https://localhost` URL.

The development-only identity diagnostic returned HTTP 200 and reported:

- authenticated request identity runtime type: `WindowsIdentity`;
- Windows SID claim present: true;
- request principal contains a `WindowsIdentity`: true;
- request `WindowsIdentity.User` SID present: true.

Only these type/boolean facts were observed. Application binding uses the authenticated request principal SID claim or `WindowsIdentity.User`, not `WindowsIdentity.GetCurrent()` and not an AD query.

| Request or validation | Result |
| --- | --- |
| Anonymous GET `/.well-known/openid-configuration` | 200 |
| Anonymous GET `/.well-known/jwks` | 200 |
| Anonymous GET `/csrf` | 401 |
| Authenticated GET `/csrf` | 200 |
| Authenticated POST `/session` without antiforgery | 400 |
| Authenticated POST `/session` with antiforgery | 204 |
| Session JWT signature verified with published JWKS key | true |
| Session token issuer, audience and expiry checks | true |
| Session token subject/profile/role/ClearanceLevel presence | true |
| Authenticated POST `/session/refresh` without antiforgery | 400 |
| Authenticated POST `/session/refresh` with antiforgery | 204 |
| Cookie refresh token changed after rotation | true |
| Replay of consumed cookie refresh token | 401 |
| Authenticated POST `/session/logout` with antiforgery | 204 |
| Refresh with pre-logout token after logout | 401 |
| Windows-authenticated `/connect/authorize` PKCE request | 302 to registered callback |
| Authorization-code + PKCE token exchange | 200 |
| ID token signature/issuer/audience/lifetime/subject/nonce | valid |
| Access token signature and profile/role/claim contract | valid |
| OIDC refresh token exchange | 200 |
| OIDC replay of consumed refresh token | 400 |
| Replay of rotated OIDC refresh descendant after ancestor replay | 400 |

Token and cookie values were held in process memory and omitted from output. The Kestrel application's database commands were parameterized; SQL logs displayed parameter placeholders only.

## Automated coverage

The final local Release run of `dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj --no-restore` passed 27 tests with no failures or skips; the Release build had zero warnings and errors. The suite covers Identity user/role claim reads and allowlisting, unknown/mismatched SID, roleless/disabled/locked users, security-stamp checks, schema/catalog constraints, session antiforgery and cookie flags, JWT signature and negative issuer/audience/lifetime/unknown-key cases, full OpenIddict discovery/code/PKCE/refresh/replay, current profile/role/claim reload during refresh, scope-filtered claims, OIDC descendant-family replay, refresh cleanup retention, exact registered-client validation, account disable before refresh, and key overlap.

The Windows/SQL harness is a separate real-chain check. Fixture tests use a test authentication handler and in-memory database; they are not counted as live Windows/SQL evidence.

## Limits

IIS and browser-specific cross-host cookie behavior were not exercised. The app's actual DAB REST/GraphQL consumption, permission checks, and cookie-to-bearer bridge belong to ticket #10 and remain unproven. The localhost certificate was not trusted by Windows, and the harness bypassed chain and subject validation for the exact loopback URL; this local test does not prove production TLS trust. Already issued access JWTs remain valid to stateless downstream validators until their short expiry even after issuer logout or account disable.
