# Ticket #11 issuer implementation report

Date: 2026-10-01. Ticket: [Prove the Windows Authentication issuer, Profile and Roles lookup, and JWT cookie contract](https://github.com/gcapnias/dab-iis-yarp/issues/11).

## Result and completion status

The .NET 10 issuer prototype is implemented and passes its fixture-level validation. **Issuer-side go/no-go: no-go for the required real-chain proof yet.** A real IIS/Kestrel Windows identity → persisted SQL Server Identity profile and roles → signed JWT → browser cookie run was not possible in this environment. The ticket must remain open until that authorized real-chain gate is completed. DAB token validation, cookie bridge behavior, and permission enforcement through REST/GraphQL remain assigned to ticket #10.

## Implemented behavior

- `src/IdentityIssuer/` is a separate `net10.0` ASP.NET Core project. It references ASP.NET Core Identity EF Core, EF Core SQL Server, EF Design, and Negotiate at version `10.0.12`; it does not reference or host DAB.
- Windows identity comes only from the authenticated request principal's SID. The lookup binds that SID to a unique persisted `ApplicationUser.WindowsSid`; the result is checked again for exact SID match. Unknown SID, mismatch, or no assigned role fails closed with HTTP 403. No request field or header can select an identity or role.
- `ApplicationUser` stores `WindowsSid`, unique `ProfileId`, and optional `DisplayName`. ASP.NET Core Identity stores role assignments. The emitted `sub` is the Identity user ID; `profile_id` and optional `name` are persisted profile values; `roles` is populated from the user's persisted role membership. These profile claims grant no authorization unless a consumer explicitly configures policy behavior.
- A local console provisioning command uses `UserManager` and `RoleManager` to create an Identity user with no password sign-in, create the requested role names if absent, and attach role assignments transactionally. No web registration or client role-assignment route exists.
- Tokens are RS256 access-token JWTs with `iss`, `aud`, `sub`, `iat`, `nbf`, and `exp`; lifetime is configurable from one to 60 minutes and defaults to ten. The `kid` identifies the one active RSA key. Discovery metadata identifies the issuer and JWKS. JWKS contains public RSA `n` and `e` only.
- `/session` sets `dab_access_token` as a host-only `HttpOnly`, `Secure`, `SameSite=Lax` cookie by default, with the same expiry as the JWT. Optional domain scope is a deployment choice. `/csrf` issues an antiforgery request token; session and logout POSTs require it in `X-CSRF-TOKEN`. Logout expires the cookie.
- The generated Identity schema is isolated under SQL Server schema `IdentityIssuer`; tables are the standard ASP.NET Identity tables and EF history table, with unique SID and profile ID indexes. `dotnet ef database update` is never run automatically.

The project and complete creation/verification instructions are in [the runbook](../../../docs/runbooks/windows-authentication-jwt-issuer.md). Primary-source framework/protocol research is in [the Windows/JWT/cookie note](../aspnet-windows-jwt-cookie-contracts.md) and [the .NET 10 Identity/SQL Server note](../aspnet-identity-net10-issuer.md). The latter research note is in the separate `research/11-identity-net10` commit `723fd9bb385731982df5370cb3cb405fb2aa96a0` and must be included in the final delivery branch.

## Validation performed

- `dotnet build src/IdentityIssuer/IdentityIssuer.csproj --no-restore --configuration Release`: succeeded with 0 warnings and 0 errors on .NET 10.0.12.
- `dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj --no-restore --configuration Release`: **14 passed, 0 failed** on .NET 10.0.12.
- `dotnet format src/IdentityIssuer/IdentityIssuer.csproj --verify-no-changes --no-restore`: passed.
- The 14 tests cover authenticated-SID-only lookup, absent SID, no profile mapping, a mismatched SID row, missing roles, ASP.NET Identity user/role retrieval using an isolated EF InMemory fixture, SQL Server model schema/index constraints without a database connection, JWT profile and role claims, exact expiry, RS256 signature verification using the published JWKS values, discovery metadata, public-only JWK serialization, secure cookie attributes/expiry, logout clearing, and rejection of missing antiforgery headers.
- `dotnet ef migrations add IdentityIssuerInitialCreate` generated source under `src/IdentityIssuer/Migrations/` using a synthetic design-time connection string. `dotnet ef migrations script --idempotent` generated [IdentityIssuerInitialCreate.sql](IdentityIssuerInitialCreate.sql). The script creates only schema `IdentityIssuer`, the standard ASP.NET Identity tables, unique SID/ProfileId indexes, and migration history. It contains no Northwind sample-table or sample-row changes. Neither command connected to SQL Server; the script has not been applied.
- The ASP.NET test host uses a test-only authentication handler and fixture directory. That is not Windows Authentication evidence. The Identity lookup unit tests use EF InMemory. Those fixtures do not prove a SQL Server read or migration.

## Real-chain prerequisites and outcome

The checkout documents Northwind only as a read-only database for DAB Products proof. It contains no authorization to create a new schema there. This machine has Windows 11 Pro and .NET SDK 10.0.401/runtime 10.0.12, but no IIS configuration/service was found; Windows optional-feature inspection required elevation. No approved test Windows identity or issuer host configuration was supplied. The worktree has no `.env` file or configured issuer SQL connection string. No schema migration or user/role provisioning was applied.

The latest user direction selects ASP.NET Core Identity and SQL Server in the existing Northwind development catalog instead of an unknown external identity schema. This avoids guessing an external schema. It does not grant DDL rights on Northwind. Before a real run, confirm the specific development SQL Server/catalog is disposable or approved for the `IdentityIssuer` schema, grant the issuer's test process the minimum required access, and identify an authorized Windows test identity and IIS or Kestrel host. Review the checked-in migration script before any authorized application.

No credential, signing key, JWT, actual SID, display name, or database row has been recorded in this report.

## Findings and limits

- Issuer-side identity/claims mechanics are internally testable and the implementation fails closed for unknown mappings and missing roles.
- Full issuer proof is not green because the Windows authentication and SQL Server chain was not exercised. Current machine-specific environment does not establish those prerequisites.
- The metadata endpoint supplies the issuer and JWKS needed for DAB's documented discovery path. It is not a general OIDC interactive authorization server: there is no authorization-code or token endpoint. DAB's exact discovery/validation behavior with this issuer remains for ticket #10.
- Only one signing key is published at a time; automated overlapping-key rotation, revocation, and production key custody are outside this spike.
- The `profile_id` and `name` claims are informational in the prototype. DAB authorization based on them requires explicit policy and later interoperability proof.
- Cookie interoperability depends on the final host names and browser origin arrangement. The default host-only cookie may need an intentionally shared parent-domain scope; no actual deployment topology was available. Ticket #10 must verify scope, CSRF, and cookie-to-bearer forwarding.

## Relevant artifact links

- [Issuer source](../../../src/IdentityIssuer/)
- [Issuer tests](../../../tests/IdentityIssuer.Tests/)
- [Runbook](../../../docs/runbooks/windows-authentication-jwt-issuer.md)
- [Generated unapplied migration script](IdentityIssuerInitialCreate.sql)
- [Windows/JWT/cookie research](../aspnet-windows-jwt-cookie-contracts.md)
- [ASP.NET Identity research](../aspnet-identity-net10-issuer.md)
