# Sanitized live issuer proof

Date: 2026-10-01. Scope: local Kestrel/Negotiate and SQL Server Identity proof for issue #11. This record contains no account name, Windows SID, profile identifier, JWT, private key, or connection string.

## Database state

- The user-authorized disposable database was `northwind`.
- The reviewed idempotent migration `20261001152500_IdentityIssuerInitialCreate` was applied.
- A read-only follow-up query confirmed schema `IdentityIssuer`, these eight tables, and the migration history entry:
  `__EFMigrationsHistory`, `AspNetRoleClaims`, `AspNetRoles`, `AspNetUserClaims`, `AspNetUserLogins`, `AspNetUserRoles`, `AspNetUsers`, and `AspNetUserTokens`.
- Migration review confirmed all created objects are under `IdentityIssuer`; the script has no `DROP`, `DELETE`, `TRUNCATE`, `UPDATE`, or `dbo` target. The DDL did not alter Northwind sample tables or rows.
- One synthetic ASP.NET Identity user and one test role were provisioned for the SID of the current local Windows account. A temporary role-removal check was restored before the final successful issuance. No user/profile values were queried into the evidence.

## Kestrel/Negotiate results

The issuer ran on HTTPS loopback using ASP.NET Core Negotiate and the current process's default Windows credentials. Requests used a cookie-aware HTTP client; the client accepted only a currently valid localhost development certificate with subject `CN=localhost`. No IIS feature was installed or configured.

| Request | Result |
| --- | --- |
| Anonymous GET discovery metadata | 200 |
| Anonymous GET JWKS | 200 |
| Anonymous GET `/csrf` | 401 |
| Anonymous POST `/session` | 401 |
| Windows-default-credential GET `/csrf` | 200 |
| Authenticated `/session` before a SID mapping existed | 403 |
| Authenticated `/session` with the persisted test role temporarily removed | 403 |
| Authenticated `/session` with the restored SID mapping and role, valid antiforgery token | 204 |
| Authenticated session request without antiforgery material | 400 |
| Authenticated logout without antiforgery material | 400 |
| Authenticated logout with valid antiforgery material | 204 |

The successful response set an `HttpOnly`, `Secure`, `SameSite=Lax` JWT cookie whose expiry matched the token. IdentityModel fetched the live metadata and JWKS anonymously. JWT validation succeeded with the retrieved public signing key and checked signature/algorithm, issuer, audience, lifetime, `kid`, persisted profile claim, and persisted role claim. Logout expired the cookie. No JWT or claim value was written to the logs or this report.

## Verification and limits

- Release build: 0 warnings, 0 errors.
- Issuer test suite: 17 passed, 0 failed. It includes IdentityModel parsing of metadata/JWKS and JWT verification against retrieved keys.
- The SQL connection came from the primary checkout's ignored `.env`; it was loaded only into process memory and never printed or copied.
- The temporary signing key, read-only SQL probe, and live HTTP smoke utility were created under ignored `.scratch`, not committed, and removed after the proof.
- This proves the local Kestrel/Negotiate/SQL Identity/JWT/cookie path. The development certificate was not trusted by Windows; the smoke client's validation exception was restricted to a currently valid `CN=localhost` certificate. Production TLS trust, IIS hosting, browser-specific SameSite behavior, and actual DAB REST/GraphQL validation remain unproven. DAB integration and cookie-to-bearer behavior remain in ticket #10.
