# Ticket #11 issuer implementation report

Date: 2026-10-01. Ticket: [Prove the Windows Authentication issuer, Profile and Roles lookup, and JWT cookie contract](https://github.com/gcapnias/dab-iis-yarp/issues/11).

## Result and completion status

The .NET 10 issuer prototype now passes fixture validation and a local Kestrel real-chain proof. The verified chain was default Windows credentials → Negotiate-authenticated request principal → SID-mapped SQL Server ASP.NET Identity profile and role → RS256 JWT → secure cookie, with anonymous metadata/JWKS retrieval and token validation. **Issuer-side result: go for the local Kestrel proof.** IIS deployment and DAB cookie bridge/REST/GraphQL authorization remain for ticket #10.

## Implemented behavior

- `src/IdentityIssuer/` is a separate `net10.0` ASP.NET Core project. It references ASP.NET Core Identity EF Core, EF Core SQL Server, EF Design, and Negotiate at version `10.0.12`; it does not reference or host DAB.
- Windows identity comes only from the authenticated request principal's SID. The lookup binds that SID to a unique persisted `ApplicationUser.WindowsSid`; the result is checked again for exact SID match. Unknown SID, mismatch, or no assigned role fails closed with HTTP 403. No request field or header can select an identity or role.
- `ApplicationUser` stores `WindowsSid`, unique `ProfileId`, and optional `DisplayName`. ASP.NET Core Identity stores role assignments. The emitted `sub` is the Identity user ID; `profile_id` and optional `name` are persisted profile values; `roles` is populated from the user's persisted role membership. These profile claims grant no authorization unless a consumer explicitly configures policy behavior.
- A local console provisioning command uses `UserManager` and `RoleManager` to create an Identity user with no password sign-in, create the requested role names if absent, and attach role assignments transactionally. No web registration or client role-assignment route exists.
- Tokens are RS256 access-token JWTs with `iss`, `aud`, `sub`, `iat`, `nbf`, and `exp`; lifetime is configurable from one to 60 minutes and defaults to ten. The `kid` identifies the one active RSA key. Discovery metadata identifies the issuer and JWKS. JWKS contains public RSA `n` and `e` only.
- Anonymous access is limited to discovery and JWKS for DAB's server-side signing-key retrieval. `/csrf`, `/session`, and `/session/logout` require Windows authentication; the state-changing routes also require antiforgery validation.
- `/session` sets `dab_access_token` as a host-only `HttpOnly`, `Secure`, `SameSite=Lax` cookie by default, with the same expiry as the JWT. Optional domain scope is a deployment choice. `/csrf` issues an antiforgery request token; session and logout POSTs require it in `X-CSRF-TOKEN`. Logout expires the cookie.
- The generated Identity schema is isolated under SQL Server schema `IdentityIssuer`; tables are the standard ASP.NET Identity tables and EF history table, with unique SID and profile ID indexes. `dotnet ef database update` is never run automatically.

The project and complete creation/verification instructions are in [the runbook](../../../docs/runbooks/windows-authentication-jwt-issuer.md). Sanitized live results are in [the local proof evidence](live-proof-2026-10-01.md). Primary-source framework/protocol research is in the [Windows/JWT/cookie note](../aspnet-windows-jwt-cookie-contracts.md), [.NET 10 Identity/SQL Server note](../aspnet-identity-net10-issuer.md), and [DAB discovery implementation note](discovery-implementation-details.md). Identity research was authored in `723fd9bb385731982df5370cb3cb405fb2aa96a0` and is on local `develop` at `13bbe1b`; discovery research was authored in `ab739ab` and is on local `develop` at `2565aac`.

## Validation performed

- `dotnet build src/IdentityIssuer/IdentityIssuer.csproj --no-restore --configuration Release`: succeeded with 0 warnings and 0 errors on .NET 10.0.12.
- `dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj --no-restore --configuration Release`: **17 passed, 0 failed** on .NET 10.0.12.
- Focused formatting verification passed for the modified issuer and HTTP test files; `git diff --check` passed.
- Tests cover SID-only lookup, missing/mismatched mappings, roleless users, ASP.NET Identity UserManager/RoleManager reads, schema/index constraints, claims/expiry/signature, metadata and public-only JWKS, secure cookie/logout/CSRF, unauthenticated route behavior, and IdentityModel discovery/JWKS parsing plus validation of a JWT using the published keys.
- `dotnet ef database update` applied migration `20261001152500_IdentityIssuerInitialCreate` to the authorized disposable Northwind database. Read-only verification found schema `IdentityIssuer`, its eight expected Identity/history tables, and that applied migration ID. The reviewed SQL creates only that schema; no Northwind sample table or row was modified.
- A live HTTPS Kestrel host used Negotiate and Windows default credentials. Anonymous discovery/JWKS returned 200 while anonymous `/csrf` and `/session` returned 401. The authenticated but unmapped account got 403; after provisioning one synthetic user and role against the current account SID, session creation returned 204 and the JWT validated through the public metadata/JWKS. Temporarily removing the persisted role returned 403; it was restored before successful issuance and logout checks. Missing CSRF returned 400; logout returned 204 and expired the cookie.

## Real-chain prerequisites and outcome

The approved disposable Northwind database received only the reviewed `IdentityIssuer` migration and one synthetic test identity/role mapping. The test user's Windows SID was taken from the current local Windows account and matched through the authenticated Negotiate request; account name, SID, profile identifier, JWT, connection string, and private signing key were not recorded. The generated signing key and temporary smoke harness were created under ignored `.scratch`, never committed, and removed after testing.

The live host was Kestrel on HTTPS loopback with the existing localhost development certificate. Because Windows did not trust that certificate, the temporary test client accepted only a currently valid certificate whose subject was `CN=localhost`; this validates the local protocol and Negotiate chain, not a production certificate trust path. IIS and actual DAB REST/GraphQL consumption were not exercised.

## Findings and limits

- The local Windows/Kestrel/SQL Server/Identity/JWT/cookie chain is green. The complete production hosting topology and IIS configuration are not proven.
- The accepted discovery boundary is DAB JWT key-discovery metadata (`issuer` and `jwks_uri`), not a complete OpenID Connect Provider. There is no authorization-code/token endpoint or ID-token flow. IdentityModel retrieval was exercised against the local Kestrel endpoints; actual DAB host discovery and token validation remain for ticket #10.
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
