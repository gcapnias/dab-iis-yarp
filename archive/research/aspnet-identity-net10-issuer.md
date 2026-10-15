# ASP.NET Core Identity on .NET 10 for the ticket #11 issuer

**Research date:** 2026-10-01
**Scope:** .NET 10 ASP.NET Core Identity, EF Core SQL Server persistence in the existing Northwind database, binding Windows-authenticated callers to persisted local Identity accounts, and using those records to create a JWT for the issuer prototype.

## Finding

ASP.NET Core Identity belongs inside the ticket #11 issuer as its user/profile/role/claim persistence and management layer. Register the EF Core Identity stores against a dedicated application context using SQL Server. Authenticate each request with Windows Authentication, bind the authenticated Windows SID to one provisioned Identity user, load that user's persisted profile and claims/roles, then have a separate token-issuer component create and sign the JWT.

Identity does not automatically turn `UserManager` or `RoleManager` data into a standards-based JWT or make the application an OAuth/OIDC authorization server. The built-in Identity API bearer tokens are a limited application token format; Microsoft's guidance says they are intended for simple scenarios and aren't suitable for third-party application access. For the cross-application contract in tickets #9/#10, the issuer needs an explicit JWT contract and public-key validation/discovery arrangement. A production OIDC server is a distinct decision and is outside this research's implementation recommendation.

## Identity model and APIs

ASP.NET Core Identity manages user accounts, profile data, roles, claims, and tokens. Its EF Core integration defines the user, role, user-claim, role-claim, user-role, login, and token entity types. The application can derive `ApplicationUser` from `IdentityUser` and add persisted profile fields, such as display name and other profile attributes needed by the two clients. Role-enabled persistence should use `IdentityDbContext<ApplicationUser, ApplicationRole, string>` (or the corresponding generic key types) and `AddEntityFrameworkStores<ApplicationDbContext>()`.

Use `UserManager<ApplicationUser>` for application-user lookups and persisted user claims/roles; relevant APIs include `FindByIdAsync`, `GetClaimsAsync`, and `GetRolesAsync`. Use `RoleManager<ApplicationRole>` in a controlled provisioning path to create/manage roles and role claims. These are database-backed management APIs, not authorization by themselves. The issuer must reject an unmapped Windows principal and should not create an account or grant roles merely because a first request arrived.

The user's profile fields and Identity claims do not automatically become token claims. Map only intended profile attributes to a stable, documented set of JWT claims. Emit each persisted role as a role claim of the claim type expected by the clients and by their JWT bearer handlers. Avoid serializing all Identity metadata or credentials into the token.

## Windows identity binding and provisioning

Windows Authentication authenticates the request with the operating system and exposes the authenticated principal through `HttpContext.User`. The issuer should require an authenticated principal and derive its account key from the authenticated Windows identity, preferably the user's SID (`WindowsIdentity.User.Value`) rather than trusting a request field or relying only on a display name that can change. Keep the SID as an external authentication key in a unique `ApplicationUser` property or a dedicated Identity external-login record. Resolve exactly one local Identity user from that trusted key before reading any profile or role data.

This establishes the boundary: Windows proves who made this request; the local Identity store supplies issuer-specific profile and role authorization. Provision the user-to-SID mapping and role assignments through an administrative/setup path that is not exposed as self-service by the token endpoint. A caller cannot choose the SID, profile, role names, or role claims submitted in the token request. Missing mapping, disabled/unprovisioned account, missing role data, duplicate SID mappings, and database errors should fail closed and be logged without returning sensitive details.

The documentation describes Windows Authentication with IIS, Kestrel, and HTTP.sys. It does not prove the configured development host actually has Windows Authentication enabled, that browser negotiation works in this environment, or that the host returns the expected SID. Those require an environment-specific run.

## SQL Server and Northwind schema boundary

The SQL Server EF Core provider is `Microsoft.EntityFrameworkCore.SqlServer`; Identity's EF store is `Microsoft.AspNetCore.Identity.EntityFrameworkCore`. Use matching EF Core and Identity EF package patch versions. NuGet listed stable `10.0.12` for `Microsoft.AspNetCore.Identity.EntityFrameworkCore`, `Microsoft.EntityFrameworkCore.SqlServer`, `Microsoft.EntityFrameworkCore.Design`, and `dotnet-ef` when checked on 2026-10-01. This is a point-in-time observed patch, not a durable pin: confirm the repository's central package policy and installed SDK before changing versions, and keep all Microsoft EF Core packages and migration tooling on the same 10.0.x patch.

Northwind can be the shared SQL Server database while DAB reads its sample entities and the issuer persists Identity rows. Keep the issuer context and migrations independent from DAB's configuration and data model. Give Identity its own SQL schema (for example, `issuer`) and map every Identity entity into that schema with `HasDefaultSchema` or explicit table mappings. Use distinct Identity table names if the target database's existing schemas could contain `AspNet*` tables. Keep Identity table creation additive; do not scaffold the entire Northwind database into `ApplicationDbContext` or let Identity migrations alter DAB's sample tables.

EF Core migrations have separate preparation and application stages: `dotnet ef migrations add ...` generates migration code and a model snapshot; `dotnet ef database update` executes pending migrations and writes to the database. Configure a dedicated migrations-history table for this context so it does not share history with another EF context. If placing that history table in the new `issuer` schema, account for the schema existing before EF tries to create the history table; one safe design is a uniquely named history table in an existing schema while the first Identity migration creates the new Identity schema, or a reviewed bootstrap step that creates the schema before applying migrations. Confirm the generated migration and SQL script contain only the new issuer schema/tables/history metadata before any application.

**Authorization boundary:** the current Northwind evidence is read-only, and there is no authorization here to write its schema. Preparing a migration and reviewing generated SQL is within this prototype research; applying it to Northwind is a separate database write and must remain pending until the target/database owner authorizes it. Do not auto-apply migrations at app startup.

## JWT issuance and app boundaries

Identity is the source of persisted user/profile/role state; a separate issuer service turns that state into an access token. For ticket #11, document a stable issuer (`iss`), intended API audience (`aud`), a stable non-PII local account identifier for `sub`, issue/expiry times (`iat`, `exp`), signing algorithm and key rotation plan, profile-claim names, role claim type, and failure behavior. Build the token only after Windows authentication and the local user lookup succeed. Keep the private signing key in protected configuration/secrets rather than source control, and publish only the public verification key. JWT consumers must validate signature, issuer, audience, and lifetime.

If consumers discover keys dynamically, publish a defined JWKS endpoint and the corresponding discovery metadata, or explicitly configure the public verification key for the prototype. ASP.NET Core JWT bearer middleware validates incoming JWTs; it does not provide issuer discovery/JWKS hosting or token issuance by itself. A self-implemented token endpoint plus a JWKS endpoint is a bounded prototype contract, not evidence of a complete OAuth 2.0/OIDC authorization server.

Ticket boundaries remain distinct: #11 implements and proves the Windows-to-Identity-to-JWT issuer; #9 is the embedded DAB configuration/REST/GraphQL work; #10 consumes the issuer contract and proves JWT/cookie interoperability and actual DAB permissions. Do not treat an issuer-only claim-generation test as the #10 DAB authorization proof.

## Validation that would establish the contract

- Verify anonymous requests fail and a real authenticated Windows principal is visible at the protected issuer endpoint.
- Verify SID binding finds only the provisioned local Identity user, and rejects missing or duplicate mappings without accepting client-selected identifiers.
- Provision a profile, a user claim, and one or more roles in SQL Server; verify that the issuer reads the persisted values via Identity stores and emits only the documented profile/role claims.
- Verify role changes and profile changes affect newly issued tokens; document that already-issued JWTs remain valid until expiry unless a revocation strategy is added.
- Verify the token signature and all registered validation checks (issuer, audience, expiry, not-before if used) using the same public-key contract consumers receive.
- Verify JWKS/discovery output, key identifiers, and rotation behavior if advertised. A static signing key hard-coded for local tests does not prove secure key management or rotation.
- Inspect generated migrations and SQL before any update; validate that they add only issuer-owned objects and don't rename/drop/change Northwind or DAB objects. Applying them requires separate database authorization.
- Record environmental gaps honestly: no real Windows host test means no real Windows-auth proof; no authorized schema write means no database-persistence proof against Northwind. Local test doubles/SQLite/InMemory cannot substitute for those proofs.

## Primary sources

- [Introduction to Identity on ASP.NET Core (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/identity?view=aspnetcore-10.0)
- [Customize the Identity model (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/customize-identity-model?view=aspnetcore-10.0)
- [Add, download, and delete user data to Identity (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/add-user-data?view=aspnetcore-10.0)
- [Role-based authorization in ASP.NET Core (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/authorization/roles?view=aspnetcore-10.0)
- [Configure Windows Authentication in ASP.NET Core (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/windowsauth?view=aspnetcore-10.0)
- [WindowsIdentity.User API (.NET 10)](https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.windowsidentity.user?view=net-10.0)
- [Choose an identity management solution (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/how-to-choose-identity-solution?view=aspnetcore-10.0)
- [Microsoft SQL Server EF Core provider](https://learn.microsoft.com/en-us/ef/core/providers/sql-server/)
- [EF Core migrations overview](https://learn.microsoft.com/en-us/ef/core/managing-schemas/migrations/)
- [Applying migrations](https://learn.microsoft.com/en-us/ef/core/managing-schemas/migrations/applying)
- [Customize the EF Core migrations history table](https://learn.microsoft.com/en-us/ef/core/managing-schemas/migrations/history-table)
- [NuGet: Microsoft.AspNetCore.Identity.EntityFrameworkCore](https://www.nuget.org/packages/Microsoft.AspNetCore.Identity.EntityFrameworkCore)
- [NuGet: Microsoft.EntityFrameworkCore.SqlServer](https://www.nuget.org/packages/Microsoft.EntityFrameworkCore.SqlServer)
- [NuGet: Microsoft.EntityFrameworkCore.Design](https://www.nuget.org/packages/Microsoft.EntityFrameworkCore.Design)
- [NuGet: dotnet-ef](https://www.nuget.org/packages/dotnet-ef)
- [Configure JWT bearer authentication in ASP.NET Core (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/configure-jwt-bearer-authentication?view=aspnetcore-10.0)
- [RFC 7519: JSON Web Token (JWT)](https://www.rfc-editor.org/rfc/rfc7519)
- [RFC 7517: JSON Web Key (JWK)](https://www.rfc-editor.org/rfc/rfc7517)
- [RFC 8414: OAuth 2.0 Authorization Server Metadata](https://www.rfc-editor.org/rfc/rfc8414)
- [RFC 9068: JWT Profile for OAuth 2.0 Access Tokens](https://www.rfc-editor.org/rfc/rfc9068)

## Source and interpretation notes

The framework/package behavior above is based on Microsoft Learn, .NET API docs, EF Core docs/source-linked pages, official NuGet metadata, and the cited RFCs. The isolated `issuer` schema, SID uniqueness, fail-closed provisioning, custom JWT claim mapping, and migration-review steps are recommendations for this ticket's security boundary, not defaults that ASP.NET Identity configures for the application. The sources establish framework behavior; they do not establish this repository's SQL Server credentials, Northwind schema-write authorization, real IIS/Windows negotiation, production signing-key custody, or a final decision to operate a full OIDC server.

Firecrawl Developer Index was used to discover the primary documentation and API sources; documentation pages and NuGet metadata were then scraped for verification. No third-party tutorials were used as authority for framework behavior.
