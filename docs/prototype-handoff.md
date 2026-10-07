# Prototype handoff and customization

Use this guide to understand, run and adapt the delivered issuer and embedded DAB application. The source and documentation travel together in Git; record `git rev-parse HEAD` when building a copy so a recipient can identify its revision. Recorded proof reports identify the revisions and environments they evaluated.

## Architecture and source map

The browser authenticates to the separate issuer with Windows Authentication. The issuer maps the caller's SID to a persisted issuer account, profile and roles in its SQL Identity store, then supplies signed access credentials and renewal credentials. The embedded application uses DAB's Custom JWT provider to validate access credentials and apply configured resource permissions. It does not issue tokens.

The embedded application composes the real DAB Core engine inside its ASP.NET Core process. Its bootstrap and HTTP adapters are application-owned code. The evaluated IIS layout has one HTTPS website, the issuer at its root and the embedded application at `/dab`, in separate non-administrator application pools.

| Customization area | Source to read |
| --- | --- |
| DAB bootstrap, endpoint dispatch and middleware order | [EmbeddedDab/Program.cs](../src/EmbeddedDab/Program.cs) |
| GraphQL caller and requested role | [HostRequestContextInterceptor.cs](../src/EmbeddedDab/HostRequestContextInterceptor.cs) |
| Access-cookie adaptation and API antiforgery | [IssuerCookieBearerBridgeMiddleware.cs](../src/EmbeddedDab/IssuerCookieBearerBridgeMiddleware.cs) |
| Local discovery certificate exception | [DevelopmentIssuerCertificate.cs](../src/EmbeddedDab/DevelopmentIssuerCertificate.cs) |
| Issuer routes, authentication and OIDC composition | [IdentityIssuer/Program.cs](../src/IdentityIssuer/Program.cs) |
| Windows caller lookup and current account restrictions | [IdentityDirectory.cs](../src/IdentityIssuer/IdentityDirectory.cs) |
| Caller/profile/role creation | [IdentityProvisioner.cs](../src/IdentityIssuer/IdentityProvisioner.cs) and [IdentityProvisioningCommand.cs](../src/IdentityIssuer/IdentityProvisioningCommand.cs) |
| JWT and browser cookies | [JwtIssuer.cs](../src/IdentityIssuer/JwtIssuer.cs) and [IssuerSessionCookies.cs](../src/IdentityIssuer/IssuerSessionCookies.cs) |
| Browser refresh rotation and replay | [RefreshTokenService.cs](../src/IdentityIssuer/RefreshTokenService.cs) |
| OIDC client registration and account-state validation | [OpenIddictClientProvisioningCommand.cs](../src/IdentityIssuer/OpenIddictClientProvisioningCommand.cs) and [ValidateOidcRefreshAccountState.cs](../src/IdentityIssuer/ValidateOidcRefreshAccountState.cs) |
| Profile claim allowlist and token destinations | [OidcProfileClaims.cs](../src/IdentityIssuer/OidcProfileClaims.cs) and [OidcClaimDestinations.cs](../src/IdentityIssuer/OidcClaimDestinations.cs) |

## Choose a setup procedure

1. For local use, follow [issuer setup](runbooks/windows-authentication-jwt-issuer.md#local-configuration-and-startup), including the isolated Identity catalog, migrations, protected keys, caller mapping and OIDC client registration. Then follow [current DAB startup](runbooks/dab-core-web-application.md#start-the-current-prototype).
2. For a new Windows Server/IIS test installation, follow the [clean-install guide](runbooks/windows-server-2025-clean-install.md). Replace its sample server name and paths consistently. It distinguishes administrator setup, runtime pools, SQL credentials and the non-administrator browser caller.
3. For an existing evaluated deployment, follow the [retained-state runbook](runbooks/windows-server-iis-evaluation.md). Its verification inputs reuse the existing store and keys.

Local browser proof additionally requires the existing workstation tools described in those guides. The standalone application builds require the .NET 10 SDK. The API pins Core 2.0.12 and four supplemental dependencies in [EmbeddedDab.csproj](../src/EmbeddedDab/EmbeddedDab.csproj); the issuer's dependencies are pinned in [IdentityIssuer.csproj](../src/IdentityIssuer/IdentityIssuer.csproj).

Before adapting a copy, choose its issuer URL, API URL/application prefix, audience, resource SQL catalog, separate Identity catalog, caller mappings, roles, OIDC client/redirect, HTTPS certificate and protected key/configuration locations. The evaluated hostname and audiences in examples are sample inputs. Keep private material outside tracked files; the existing runbooks describe protected provisioning.

## Change DAB resources and permissions

Select the JSON file using an absolute `DAB_CONFIG_FILE` path. Changes to resources, permissions and API paths take effect after restarting the application, without recompiling it. Keep `--initialize` on the startup command to load and validate metadata before serving the documented prototype.

| Example configuration | What it demonstrates |
| --- | --- |
| [initial.json](../src/EmbeddedDab/configurations/initial.json) | Anonymous fixture operations at REST `/api` and GraphQL `/graphql`, plus a read-only entity |
| [expanded.json](../src/EmbeddedDab/configurations/expanded.json) | Added/removed entities, REST `/v2/catalog/widgets` and GraphQL `/gql-v2` after restart |
| [jwt-interoperability.json](../src/EmbeddedDab/configurations/jwt-interoperability.json) | Custom JWT validation; `reader` reads, `writer` performs fixture CRUD |
| [northwind-iis.json](../src/EmbeddedDab/configurations/northwind-iis.json) | `dbo.Products`, both roles read-only, IIS `/dab` prefix and explicit GraphQL names |

For example, an entity entry inside the `entities` object can map another authorized table:

```json
"Orders": {
  "source": { "object": "dbo.Orders", "type": "table" },
  "rest": { "path": "orders" },
  "graphql": true,
  "permissions": [{ "role": "reader", "actions": ["read"] }]
}
```

This is a customization example: the target table and its metadata must exist in the selected database. Restart and verify the new REST and GraphQL reads. Declare each role's actions explicitly; the role name `writer` does not itself grant writes. An issuer role is usable only when it is present in the validated credential and allowed by the resource configuration. `X-MS-API-ROLE` selects a granted role, not a new grant.

The fixtures establish the tested SQL Server behavior. Additional configured features should be checked against the pinned engine and application adapter. Preserve the configuration-driven boundary when extending adapter coverage. The [API coverage decision](https://github.com/gcapnias/dab-iis-yarp/issues/16#issuecomment-6014166490) describes intended coverage and response compatibility.

### DAB host settings

| Input | Meaning |
| --- | --- |
| `DAB_CONFIG_FILE` | Configuration file; default `dab-config.json` under the content root |
| `DAB_CONNECTION_STRING` | Resource connection override; supplied examples also reference it with `@env('DAB_CONNECTION_STRING')` |
| `--initialize` / `DAB_INITIALIZE=true` | Initialize runtime configuration and database metadata |
| `DAB_ENV_FILE` | Optional local dotenv loader; finds a connection whose parsed catalog is `northwind`; a direct connection takes precedence |
| `DAB_FIXTURE_DATABASE` | Fixture catalog substitution during dotenv loading |
| `DAB_DEVELOPMENT_ISSUER_CERTIFICATE_SHA256` | Opt-in Development-only exact HTTPS localhost issuer certificate pin |

The local certificate pin is scoped to the configured HTTPS localhost authority and still checks hostname, validity and server usage. For a server hostname use the normal certificate trust setup described in the IIS guides. Browser test certificate bypass and DAB's server-side discovery trust are separate settings.

### API paths and browser calls

In IIS, the `/dab` application prefix becomes ASP.NET `PathBase`. Also set DAB `runtime.base-route` to `/dab` so generated URLs include that prefix; keep REST `/api` and GraphQL `/graphql` application-relative. Their external URLs are `/dab/api/Products` and `/dab/graphql`. Update host, configuration and client paths together for another deployment prefix, and check generated links as well as direct requests.

The API uses `dab_access_token` only when no Authorization header is supplied. Explicit bearer credentials take precedence. For cookie-authenticated POST/PUT/PATCH/DELETE, obtain an API antiforgery token from `GET /bridge/csrf` and send it in `X-CSRF-TOKEN` with the exact API `Origin`. This includes GraphQL POST. Under IIS these helper URLs carry the application prefix. The issuer's `/csrf` token serves its own session endpoints; it is a separate token.

Cookie name, CSRF names and helper routes are code constants in the embedded host. Changing them requires a coordinated code change with the issuer and browser client. Shared cookie scope does not enable CORS; use the demonstrated same-origin IIS topology or separately verify another origin arrangement.

REST PUT/PATCH perform upserts without `If-Match`; exact `If-Match: *` selects update-only behavior. Other present values return HTTP 400. Preserve these pinned semantics when adapting REST dispatch.

## Change issuer identity and session settings

The [issuer configuration example](../src/IdentityIssuer/appsettings.example.json) contains non-secret defaults. Environment names replace `:` with `__`, for example `Issuer__Audience`. Set the same issuer and audience in the issuer and DAB configuration.

| Setting | Current behavior |
| --- | --- |
| `ConnectionStrings:IssuerIdentity` | Separate SQL Identity store; supply the same explicit connection to migration, provisioning and startup |
| `Issuer:Url` / `Issuer:Audience` | Issuer identity and intended API audience |
| `Issuer:SigningKeyPath` / `Issuer:EncryptionKeyPath` | Separate persisted RSA keys; relative paths resolve from the application content root |
| `Issuer:KeyId` / `Issuer:PreviousSigningKeys` | Active key identifier and configured overlapping signing material; see the existing key rollover procedure |
| `Issuer:LifetimeMinutes` | Access lifetime, default 10, accepted range 1–60 minutes |
| `Issuer:RefreshLifetimeDays` | Refresh-token lifetime, default 7, accepted range 1–30 days; browser rotation renews the deadline |
| `Issuer:CookieName` / `Issuer:RefreshCookieName` | Access and refresh cookie names; access name must match the API bridge |
| `Issuer:CookieDomain` | Host-only by default; changes need corresponding browser/topology verification |
| `WindowsAuthentication:Mode` | `Negotiate` locally, `IIS` on the evaluated server |
| `Oidc:ClientId` / `Oidc:RedirectUri` | Exact persisted public/native authorization-code + PKCE registration |

Migrations are explicit operator commands, not application startup actions. Follow the [database and provisioning procedure](runbooks/windows-authentication-jwt-issuer.md#database-and-operator-provisioning); it shows secret-safe connection input and caller provisioning. `--provision-identity` creates a mapping and rejects an existing SID/profile. It is not an account editor. Windows groups do not automatically become issuer roles.

`--provision-oidc-client` succeeds for an already matching registration but rejects a mismatching one. Editing its settings does not update a stored registration. Provision a distinct client or deliberately adapt the provisioning code for your client's exact redirect and permissions.

Only the persisted `ClearanceLevel` profile claim is currently allowlisted; conflicting values fail closed. To add another claim, change the profile lookup/allowlist, token destinations and relevant tests, then explicitly configure any DAB policy that uses it. A claim's presence alone does not grant resource access.

The local convenience issuer launcher reads the primary checkout's `.env` entry named `ConnectionString`, which overrides an inherited `ConnectionStrings__IssuerIdentity`. Prefer the documented direct startup if that entry targets another catalog. The DAB dotenv loader accepts arbitrary entry names; the issuer launcher does not.

### Current session behavior and extension points

Issuer discovery/JWKS are anonymously reachable. `/connect/authorize` binds to the authenticated Windows caller; `/connect/token` handles protocol redemption. Windows-authenticated issuer `/csrf` supplies antiforgery for `POST /session`, `/session/refresh` and `/session/logout`.

Browser refresh tokens rotate; reusing a consumed credential revokes its family. The current replacement gets a new expiry from the rotation time. It does not preserve a fixed original family deadline. Logout removes browser cookies and revokes refresh, while a copied stateless access JWT can remain valid until expiry.

The [application scope decision](https://github.com/gcapnias/dab-iis-yarp/issues/15#issuecomment-5984802519) and [identity/security decision](https://github.com/gcapnias/dab-iis-yarp/issues/17#issuecomment-6017488915) describe further customization directions. The current source has no integrated session page or cross-tab coordinator, no two-hour absolute/15-minute renewal session limits, no full account-change/revoke-all management command, and no independent recovery record. Recipients can use these later design decisions when choosing extensions for their needs; implementing them is optional for this prototype handoff.

Similarly, `/host` and `X-Spike-Process-Id` are proof diagnostics. They are not readiness checks. The [IIS operational decision](https://github.com/gcapnias/dab-iis-yarp/issues/14#issuecomment-5984426565) provides guidance for recipients choosing additional health, logging, shutdown and recovery behavior. The handoff does not add a production acceptance programme.

## Build, package and verify a customized copy

From the repository root, the following commands build/test source without deploying either application:

```powershell
dotnet build src/IdentityIssuer/IdentityIssuer.csproj -c Release
dotnet build src/EmbeddedDab/EmbeddedDab.csproj -c Release
dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj -c Release
dotnet test tests/EmbeddedDab.Tests/EmbeddedDab.Tests.csproj -c Release
```

Standalone DAB tests skip SQL-backed integration checks when `DAB_ENV_FILE` or `DAB_FIXTURE_DATABASE` is absent. Use `scripts/test-embedded-dab-jwt.ps1` with its authorized fixture connection for those checks; a standalone test pass alone does not report that coverage.

For framework-dependent delivery, publish both projects into separate staging folders:

```powershell
dotnet publish src/IdentityIssuer/IdentityIssuer.csproj -c Release --no-self-contained -o .scratch/delivery/issuer
dotnet publish src/EmbeddedDab/EmbeddedDab.csproj -c Release --no-self-contained -o .scratch/delivery/api
```

Keep the source revision, this guide, linked runbooks, configuration examples, migrations and verification scripts available to the recipient. Supply environment-specific credentials, keys and certificates through the protected setup procedure. The [clean-install guide](runbooks/windows-server-2025-clean-install.md) covers the runtime/ANCM prerequisites, generated `web.config`, application boundaries and ACLs. `.scratch` staging output is temporary and gitignored.

Choose verification matching your changes:

| Change | Existing verification entry point |
| --- | --- |
| Resource routes, configured permissions or REST/GraphQL dispatch | `scripts/test-embedded-dab.ps1` |
| JWT validation, caller role or cookie bridge | `scripts/test-embedded-dab-jwt.ps1` and `tests/EmbeddedDab.Tests` |
| Issuer account lookup, issuance, refresh or OIDC | `tests/IdentityIssuer.Tests` and the issuer runbook's HTTP/browser procedures |
| Real local Windows/Identity/browser-to-DAB integration | `scripts/test-dab-issuer-live.ps1`, after its issuer/client prerequisites |
| Existing IIS deployment with read-only Northwind | `scripts/test-dab-issuer-browser.ps1 -Issuer <issuer-root-url> -Api <api-url> -CredentialFile <protected-xml> -Northwind` |

The fixture verifiers create/drop isolated databases and require a separate authorized fixture connection. They do not use the read-only Northwind runtime login for database creation. The IIS browser script's `-Northwind` switch selects the read-only path; its default mode writes disposable Widgets fixture data. Exact required tools, credentials and cleanup procedures remain in the linked runbooks.

## Recorded evidence

These are historical results for their stated revisions and scopes, not tests rerun while preparing this guide.

| Evidence | Recorded result |
| --- | --- |
| [Configuration-driven API proof](../archive/research/dab-core-hosting/CONFIGURATION-DRIVEN-PROOF.md) | 62 checks; same-process REST/GraphQL and configuration changes after restart |
| [Issuer implementation report](../archive/research/identity-issuer/implementation-report.md) | Real Windows/Identity/OIDC issuer proof, with source and validation details |
| [Local interoperability proof](../archive/research/dab-jwt-interoperability/LIVE-PROOF.md) | Real Windows/database/browser credential chain, resource permissions and mutation protection |
| [Windows Server/IIS evaluation](../archive/research/windows-server-iis/EVALUATION.md) | Separate pools, real browser/token checks, fixture operations and final read-only Northwind |

The first completed ground-up Windows installation is accepted for this effort. Recipients can use its procedure for their own environment; a second empty-server repetition is not a handoff requirement. Earlier reports and decision text may describe later gates as pending at their publication date; use the linked subsequent results for their status, and current source for implemented behavior.
