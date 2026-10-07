# Start an ASP.NET Core application with DAB Core

Validated on 2026-10-03 with `Microsoft.DataApiBuilder.Core` 2.0.12 and .NET 10 against a disposable SQL Server fixture. This runbook preserves the original Products-read reproduction and now documents the configuration-driven REST/GraphQL proof. The [original hosting research](../../archive/research/dab-core-hosting/README.md) and [configuration-driven proof report](../../archive/research/dab-core-hosting/CONFIGURATION-DRIVEN-PROOF.md) contain the evidence and coverage limits.

## Start the current prototype

The current application is `src/EmbeddedDab`, targeting .NET 10. The archived Products-only host later in this runbook preserves the initial proof. Use the [prototype customization guide](../prototype-handoff.md) for the current source map, settings and evidence.

First complete [local issuer setup](windows-authentication-jwt-issuer.md#local-configuration-and-startup). To run read-only Northwind access locally, copy [northwind-iis.json](../../src/EmbeddedDab/configurations/northwind-iis.json) into a private configuration file under `.scratch/local-dab.json`. Remove `runtime.base-route` for a root-mounted local host, change its JWT issuer to the configured local issuer URL and its audience to the issuer's configured audience. Keep its read-only permissions. For the evaluated IIS deployment, retain `/dab` as the base route and follow the [server procedure](windows-server-2025-clean-install.md).

In a separate PowerShell 7 terminal at the repository root, after preparing that file:

```powershell
$env:DAB_CONFIG_FILE = (Resolve-Path '.scratch/local-dab.json').Path
$resourceSecret = Read-Host 'Northwind read-only SQL connection string with Encrypt=True' -AsSecureString
$env:DAB_CONNECTION_STRING = [pscredential]::new('unused', $resourceSecret).GetNetworkCredential().Password
Remove-Item Env:DAB_ENV_FILE -ErrorAction SilentlyContinue
$env:ASPNETCORE_ENVIRONMENT = 'Development'
dotnet run --project src/EmbeddedDab/EmbeddedDab.csproj --no-launch-profile -- --initialize --urls https://localhost:5002
```

The local host requires an existing localhost HTTPS certificate. Discovery/JWKS access from the API to the issuer also needs server-side trust. If using the existing untrusted developer certificate, set the explicitly documented `DAB_DEVELOPMENT_ISSUER_CERTIFICATE_SHA256` exception before startup as described under [issuer JWT and browser-cookie integration](#issuer-jwt-and-browser-cookie-integration). Browser verification's certificate bypass is separate.

With a valid issuer access credential, the resource URLs are `/api/Products` and `/graphql`. Use the documented browser bridge or an Authorization bearer header; the `/host` diagnostic alone does not establish authenticated API access. The live fixture/browser verifier below provides the existing integrated verification procedure.

After stopping the process, clear its private process inputs:

```powershell
Remove-Item Env:DAB_CONNECTION_STRING, Env:DAB_CONFIG_FILE, Env:DAB_DEVELOPMENT_ISSUER_CERTIFICATE_SHA256 -ErrorAction SilentlyContinue
Remove-Variable resourceSecret -ErrorAction SilentlyContinue
```

## Current application baseline

The external Windows Server 2025 deployment and IIS-specific configuration/ACL requirements are in the [server runbook](windows-server-iis-evaluation.md). The [evaluation report](../../archive/research/windows-server-iis/EVALUATION.md) records the passing isolated IIS mutation proof and final Northwind REST/GraphQL browser/token proof. The deployed host can use its protected DAB connection configuration directly; the optional environment-file loader is retained for local fixtures.

The accepted [framework and package decision](../adr/0002-net10-and-proven-dab-core-baseline.md) selects `net10.0` with Core `2.0.12` for new application work, retaining the four supplemental dependency pins below. The archived .NET 8 instructions reproduce the original package-target proof; they are not the target recommendation for the new application.

The [integration decision](../adr/0001-conditional-same-process-dab-integration.md) accepts application-owned bootstrap, HTTP adapters, dependency pins, and upgrade validation. The configuration-driven proof now passes for REST CRUD/key routes, GraphQL queries and mutations, operation permissions, conditional PUT/PATCH semantics, and entity/path changes after restarting an unchanged binary. The fixed Products adapter below remains the original narrow baseline and does not by itself establish that broader result.

JWTs come from a separate .NET 10 identity issuer. The anonymous proof configurations demonstrate DAB's configured operation permissions but do not validate those issuer tokens or browser credentials. The [final interoperability proof](https://github.com/gcapnias/dab-iis-yarp/issues/10) reuses both prototypes and verifies the embedded host's cookie-to-token bridge and real DAB authentication/permissions through REST and GraphQL. Issuer-side completion and this API proof alone do not establish DAB security compatibility.

If a required proof fails, diagnose the package, supplemental dependencies, and application adapter before changing versions. A demonstrated package limitation or incompatibility permits evaluation of an exact pinned 2.1 RC and repetition of the required proofs; no RC is adopted by this runbook. Preserve the same-process boundary and original evidence.

## Prerequisites

- For the archived multi-target project, install a .NET 10 SDK and the .NET 8 and .NET 10 ASP.NET Core runtimes. The recorded builds used SDK 10.0.401. A new project targeting only .NET 8 can use its matching SDK/runtime.
- An accessible SQL Server database named `northwind`, containing `dbo.Products` with primary key `ProductID`. The proof database had 77 rows; Chai and Chang were the first two products. Verification assumes ProductIDs 1 and 2 exist.
- For the **archived Products read proof only**, a connection with table-read and metadata permissions. That proof does not provision databases or change data.
- For **disposable fixture proofs (#9 and local interoperability)**, a separate authorized SQL connection with CREATE/DROP DATABASE and fixture schema/data permissions. The verifier creates and deletes its own `dab_ticket9_...` database. Do not substitute a read-only Northwind runtime login or give it these privileges merely to run tests.
- For local issuer interoperability, Windows/PowerShell 7, Edge, Node.js and `@playwright/cli` are required on the workstation, plus a localhost developer certificate, a separate migrated Identity database, the current Windows caller mapping/roles, and the browser OIDC client. Complete [local issuer setup](windows-authentication-jwt-issuer.md#local-configuration-and-startup) first. Exact tool checks/versions are in the [clean-install guide](windows-server-2025-clean-install.md#2-prepare-access-and-the-build-workstation).
- The spike branch/artifacts available locally. Commands start from the checkout containing `archive/spikes/dab-core-hosting/`.

## Connection and secrets

Keep the connection string in a local root `.env`, outside source control. This repository ignores `.env`; confirm both commands below before using it. The second command should print nothing.

```powershell
git check-ignore -v -- .env
git ls-files -- .env
```

Example only; replace placeholders privately:

```dotenv
NORTHWIND_CONNECTION_STRING="Server=<server>;Database=northwind;User ID=<user>;Password=<password>;Encrypt=True;TrustServerCertificate=True"
```

The validated development connection uses `Encrypt=True;TrustServerCertificate=True`, explicitly approved for this instance. Encryption remains enabled, but the client does not validate the server certificate chain. Use `TrustServerCertificate=False` when the server presents a certificate trusted by the client.

The supplied DAB host loads the absolute path in `DAB_ENV_FILE`, finds a dotenv entry whose parsed database is `northwind`, and sets `DAB_CONNECTION_STRING` in its own process. **Only this DAB loader** accepts an arbitrary variable name. The issuer launcher reads only `.env`'s `ConnectionString`, which overrides an explicit Identity environment connection when present. A linked worktree can use the primary checkout's `.env`; keep credentials private. Protected deployed DAB JSON is the separately approved test-server storage mechanism, not a place to copy fixture credentials. If supplying `DAB_CONNECTION_STRING` directly, omit `DAB_ENV_FILE`.

## Run the validated host

From the checkout root:

```powershell
dotnet restore archive/spikes/dab-core-hosting/Host/Host.csproj --verbosity minimal
dotnet build archive/spikes/dab-core-hosting/Host/Host.csproj --framework net8.0 --no-restore --verbosity minimal
Set-Location archive/spikes/dab-core-hosting/Host
$env:DAB_ENV_FILE = 'E:/Shared/Workspaces/personal/dab-iis-yarp/.env'
dotnet run --project Host.csproj --framework net8.0 --no-build -- --initialize --urls http://127.0.0.1:5186
```

Replace the dotenv path with the absolute path for your checkout. Start from the Host directory so `dab-config.json` resolves against the content root. **Keep `--initialize`:** it loads configuration and initializes database metadata before activating authorization and `RestService`. Running this spike without that switch does not perform the required bootstrap.

In a second PowerShell terminal:

```powershell
Invoke-RestMethod 'http://127.0.0.1:5186/host'
Invoke-RestMethod 'http://127.0.0.1:5186/api/Products?$first=2'
```

Both requests should return HTTP 200. `/host` reports its runtime and process ID. Products returns a `value` array including Chai and Chang and a pagination `nextLink`. The diagnostic `X-Spike-Process-Id` response header is present on both routes and should match the host process ID.

Stop the foreground server with Ctrl+C. Then remove the path variable from that terminal:

```powershell
Remove-Item Env:DAB_ENV_FILE -ErrorAction SilentlyContinue
```

## Automated read-only verification and .NET 10

From the Host directory, with the dotenv path set, the following mode starts the server, checks both HTTP routes and process identity, reads SQL count/schema/sample rows, and stops/disposes the host:

```powershell
$env:DAB_ENV_FILE = 'E:/Shared/Workspaces/personal/dab-iis-yarp/.env'
dotnet run --project Host.csproj --framework net8.0 --no-build -- --verify --urls http://127.0.0.1:5186
```

Expected: exit code 0, both HTTP statuses 200, matching process IDs, a Products count of 77 for the unchanged sample database, and `Host stopped and disposed`. The count is observed output; a different database population can change it. The verifier checks the first two ProductIDs and performs only SELECT and metadata reads.

After the .NET 8 proof passes, build and run the identical source on .NET 10:

```powershell
dotnet build Host.csproj --framework net10.0 --verbosity minimal
dotnet run --project Host.csproj --framework net10.0 --no-build -- --verify --urls http://127.0.0.1:5187
Remove-Item Env:DAB_ENV_FILE -ErrorAction SilentlyContinue
```

The recorded runs passed on both frameworks. ADR-0002 subsequently selected .NET 10 for the application; the two-framework reproduction remains useful baseline evidence.

## Reproduce the configuration-driven proof (#9)

The runnable prototype and verifier are under `src/EmbeddedDab/` and `scripts/test-embedded-dab.ps1`. The verifier builds once, creates a uniquely named disposable database on the SQL Server configured by the primary checkout's ignored `.env`, runs both configurations against that same binary, then drops the fixture database. It does not write to Northwind. Run it from any checkout in this repository:

```powershell
pwsh -NoProfile -File scripts/test-embedded-dab.ps1
```

The first configuration exposes `Widget` and read-only `RetiredWidget` at `/api`, with GraphQL at `/graphql`. The expanded configuration changes the global REST path to `/v2`, changes the `Widget` entity path to `catalog/widgets`, adds `Label`, and removes `RetiredWidget`; it moves GraphQL to `/gql-v2`. The verifier checks REST collection and key reads, create/upsert/update/delete operations, permission denial for a disallowed REST mutation, GraphQL query/create/update/delete mutations, permission-driven schema omissions, and route/schema changes after restarting the unchanged binary. For PUT/PATCH, no `If-Match` header retains upsert behavior; a single exact `If-Match: *` selects update-only behavior and rejects missing keys with HTTP 400; any other present value, including multiple values, returns HTTP 400 without mutation, matching pinned DAB 2.0.12 `RestController` semantics.

Use `-DotEnvFile <absolute-path>` if the primary `.env` is stored elsewhere. Keep `Encrypt=True`; the development server trust setting described above is the only approved certificate exception. The script reports the generated fixture database name but never prints connection details. Its cleanup runs even when an assertion fails.

## Bootstrap requirements

The original fixed-read registration code is in [Host/Program.cs](../../archive/spikes/dab-core-hosting/Host/Program.cs). The broader prototype is in [EmbeddedDab/Program.cs](../../src/EmbeddedDab/Program.cs) and [HostRequestContextInterceptor.cs](../../src/EmbeddedDab/HostRequestContextInterceptor.cs). Core 2.0.12 does not supply Service/Startup or a general `AddDataApiBuilder`/`MapDataApiBuilder` hosting recipe. The application-owned composition preserves these steps:

1. Register the runtime loader/provider/validator, query/mutation/metadata factories, request validator and `RestService`, plus their public dependencies. MVC result execution is also required because `RestService` returns `IActionResult` values.
2. Register `GraphQLSchemaCreator` with the real Core query/mutation factories and compose it into Hot Chocolate through `InitializeSchemaAndResolvers`. The host request interceptor carries the current caller and `X-MS-API-ROLE` into DAB's GraphQL request context.
3. Configure authentication and authorization for the selected proof configuration. The disposable fixture configurations use the `Unauthenticated` provider and explicit per-entity actions; they are not issuer JWT evidence.
4. Load `RuntimeConfigProvider.GetConfig()`, await `IMetadataProviderFactory.InitializeAsync()`, check its metadata exceptions, then activate `RestService` and `GraphQLSchemaCreator`. Authorization initialization depends on inferred metadata.
5. Preserve middleware order: `UseAuthentication`, `UseClientRoleHeaderAuthenticationMiddleware`, `UseAuthorization`, `UseClientRoleHeaderAuthorizationMiddleware`.
6. Dispatch requests using the loaded runtime paths and configured entity paths. REST verbs map to DAB `EntityActionOperation` values, and the returned MVC `IActionResult` executes in the current ASP.NET Core request. For PUT/PATCH, no `If-Match` means upsert; when the header is present, accept only exact `*` and map to update/update-incremental, otherwise return HTTP 400. GraphQL fields and resolvers come from the configured Core schema creator.

The original [configuration](../../archive/spikes/dab-core-hosting/Host/dab-config.json) reads `@env('DAB_CONNECTION_STRING')`, enables REST at `/api`, disables GraphQL, and maps Products to `dbo.Products`; its app maps only the Products collection read. The new prototype reads the same environment variable and derives all entity routes and the GraphQL schema from the active DAB configuration.

## Issuer JWT and browser-cookie integration

The merged [interoperability implementation](../../archive/research/dab-jwt-interoperability/IMPLEMENTATION-AND-SYNTHETIC-PROOF.md) registers DAB's pinned Custom-provider JWT scheme and options. Configure `runtime.host.authentication.provider` as `Custom`, with the real issuer URL and audience under `authentication.jwt`; discovery/JWKS must be anonymously reachable with valid server-side HTTPS trust. The exact `roles` claim and configured entity permissions govern access, including permitted `X-MS-API-ROLE` selection. The application does not issue tokens.

The host reads `dab_access_token` when no Authorization header is present. Cookie extraction runs before authentication, then DAB authenticates, then the host validates identity-bound antiforgery and exact same-origin `Origin` on unsafe cookie requests. Explicit bearer credentials take precedence. A browser obtains the request token from `GET /bridge/csrf` and sends it as `X-CSRF-TOKEN` on POST/PUT/PATCH/DELETE, including GraphQL POST. The browser must send cookies to the API origin; no CORS permission is implied by shared cookie scope.

For controlled disposable regression, run `pwsh -NoProfile -File scripts/test-embedded-dab-jwt.ps1` with the fixture SQL privileges above. The [live proof](../../archive/research/dab-jwt-interoperability/LIVE-PROOF.md) records real Windows/database/browser-to-DAB reads, mutations, denials, antiforgery and logout. Controlled regression tests complement it.

`scripts/test-dab-issuer-live.ps1` is **acceptance of an already provisioned local issuer**, not a full Identity setup. It launches its own local hosts, creates/drops a mutation fixture and performs cleanup, but does not migrate Identity, map the caller or register its browser client. Complete the issuer setup and browser-client registration first; the current caller needs reader/writer roles. The browser checks accept a nonempty clearance claim, while the separate issuer HTTP harness requires `Level3`.

For that live launcher, the primary checkout's `.env` must exist with the Northwind connection used to create its separate fixture. Use the arbitrary `NORTHWIND_CONNECTION_STRING` example above; **do not add a `ConnectionString` entry with a different catalog**, because the child issuer launcher would overwrite its inherited Identity environment. Supply the isolated Identity connection using the secret-safe block in the issuer runbook and verify that catalog before launching. The launcher uses its primary `.scratch` signing/encryption keys and registers neither caller nor client; ports 5001/5002 must be unused. It selects the existing developer certificate's exact public fingerprint for the localhost DAB backchannel. Keep the Identity store separate from the fixture database that cleanup drops.

```powershell
# Workstation PowerShell 7, after issuer provisioning; stop the manually started issuer first.
# Keep ConnectionStrings__IssuerIdentity set to the isolated, migrated Identity store.
pwsh -NoProfile -File scripts/test-dab-issuer-live.ps1
```

For **already running local hosts configured with disposable Widgets/RetiredWidgets**, the default browser verifier creates and deletes REST/GraphQL fixture rows:

```powershell
pwsh -NoProfile -File scripts/test-dab-issuer-browser.ps1 -Issuer https://localhost:5001 -Api https://localhost:5002
```

Do not point that mutation mode at the Northwind deployment. For the already provisioned IIS server, use the **read-only** mode and its dedicated caller file created by the clean-install/retained-state guides:

```powershell
pwsh -NoProfile -File scripts/test-dab-issuer-browser.ps1 -Issuer https://ws2025s01.mshome.net/ -Api https://ws2025s01.mshome.net/dab -CredentialFile .scratch/ws2025s01/browser-credentials.xml -Northwind
```

Browser `ignoreHTTPSErrors` affects only the test browser. It does not grant DAB's discovery/JWKS client trust in the issuer certificate. The approved local proof uses `DAB_DEVELOPMENT_ISSUER_CERTIFICATE_SHA256`: an exact 64-hex SHA-256 certificate fingerprint, selected by the live harness from the issuer's presented public leaf only after it matches an existing ASP.NET developer certificate. This option is accepted only in Development and only for the configured HTTPS localhost issuer origin. The certificate must match the pin, be currently valid, and support Server Authentication; hostname mismatch and other origins/ports fail closed. No workstation certificate-store change is performed. Omit the pin for normal CA-backed TLS validation. Changing the developer certificate requires reselecting its pin and restarting the API; do not carry this local option into production configuration.

## Troubleshooting and limits

The authoritative [EmbeddedDab project](../../src/EmbeddedDab/EmbeddedDab.csproj) pins Core **2.0.12**, Azure.Security.KeyVault.Secrets **4.6.0**, OpenTelemetry.Exporter.OpenTelemetryProtocol **1.15.3**, Serilog.Sinks.File **7.0.0** and Humanizer.Core **2.14.1**. Retain all five in a separately created host; restoring Core alone is insufficient.

| Symptom | Check |
| --- | --- |
| Missing KeyVault, OpenTelemetry, Serilog File or Humanizer assembly | Restore all five direct package pins; Core alone compiled but failed at runtime. |
| SQL TLS certificate chain untrusted | Verify the intended connection's Encrypt/TrustServerCertificate flags privately. Use the approved development trust option or a trusted server certificate. |
| Products object not inferred | Ensure initialization runs before RestService/authorization activation and that SQL metadata permissions are available. |
| GraphQL mutation reports no client role | Preserve the host-owned GraphQL request interceptor and ensure it places the client-role header in request context. |
| Configuration file missing | Run from the project directory or set a deliberate content root/config path. |
| Address already in use | Select an unused localhost port and stop only the host started for this run. |

The original Products proof establishes only an anonymous collection read and same-process shutdown. Configuration-driven proof adds fixture REST CRUD/key routes, GraphQL query/mutation, permissions and restart-based changes; issuer interoperability adds JWT/cookie and role evidence. The later [IIS evaluation](../../archive/research/windows-server-iis/EVALUATION.md) separately establishes the tested Windows Server topology. These proofs do not establish live reload, MCP, production observability or an upstream-supported hosting contract. Keep secrets out of diagnostics; the prototype disables logging providers and returns generic REST rejection errors.
