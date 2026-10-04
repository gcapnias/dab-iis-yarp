# Start an ASP.NET Core application with DAB Core

Validated on 2026-10-03 with `Microsoft.DataApiBuilder.Core` 2.0.12 and .NET 10 against a disposable SQL Server fixture. This runbook preserves the original Products-read reproduction and now documents the configuration-driven REST/GraphQL proof. The [original hosting research](../../archive/research/dab-core-hosting/README.md) and [configuration-driven proof report](../../archive/research/dab-core-hosting/CONFIGURATION-DRIVEN-PROOF.md) contain the evidence and coverage limits.

## Current application baseline

The external Windows Server 2025 deployment and IIS-specific configuration/ACL requirements are in the [server runbook](windows-server-iis-evaluation.md). The [evaluation report](../../archive/research/windows-server-iis/EVALUATION.md) records the passing isolated IIS mutation proof and final Northwind REST/GraphQL browser/token proof. The deployed host can use its protected DAB connection configuration directly; the optional environment-file loader is retained for local fixtures.

The accepted [framework and package decision](../adr/0002-net10-and-proven-dab-core-baseline.md) selects `net10.0` with Core `2.0.12` for new application work, retaining the four supplemental dependency pins below. The archived .NET 8 instructions reproduce the original package-target proof; they are not the target recommendation for the new application.

The [integration decision](../adr/0001-conditional-same-process-dab-integration.md) accepts application-owned bootstrap, HTTP adapters, dependency pins, and upgrade validation. The configuration-driven proof now passes for REST CRUD/key routes, GraphQL queries and mutations, operation permissions, conditional PUT/PATCH semantics, and entity/path changes after restarting an unchanged binary. The fixed Products adapter below remains the original narrow baseline and does not by itself establish that broader result.

JWTs come from a separate .NET 10 identity issuer. The anonymous proof configurations demonstrate DAB's configured operation permissions but do not validate those issuer tokens or browser credentials. The [final interoperability proof](https://github.com/gcapnias/dab-iis-yarp/issues/10) reuses both prototypes and verifies the embedded host's cookie-to-token bridge and real DAB authentication/permissions through REST and GraphQL. Issuer-side completion and this API proof alone do not establish DAB security compatibility.

If a required proof fails, diagnose the package, supplemental dependencies, and application adapter before changing versions. A demonstrated package limitation or incompatibility permits evaluation of an exact pinned 2.1 RC and repetition of the required proofs; no RC is adopted by this runbook. Preserve the same-process boundary and original evidence.

## Prerequisites

- For the archived multi-target project, install a .NET 10 SDK and the .NET 8 and .NET 10 ASP.NET Core runtimes. The recorded builds used SDK 10.0.401. A new project targeting only .NET 8 can use its matching SDK/runtime.
- An accessible SQL Server database named `northwind`, containing `dbo.Products` with primary key `ProductID`. The proof database had 77 rows; Chai and Chang were the first two products. Verification assumes ProductIDs 1 and 2 exist.
- A connection with permission to read the table and discover its metadata. No database provisioning or data changes are required by this runbook.
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

The supplied host loads the absolute path in `DAB_ENV_FILE`, finds a dotenv entry whose parsed database is `northwind`, and sets `DAB_CONNECTION_STRING` in its own process. The dotenv variable name is not fixed. A linked worktree can use the primary checkout's `.env`; do not copy credentials into the worktree or into DAB JSON. If supplying `DAB_CONNECTION_STRING` directly through the process environment instead, omit `DAB_ENV_FILE` and configure secret-safe logging appropriate to that host.

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
./scripts/test-embedded-dab.ps1
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

For the controlled disposable regression proof, run `./scripts/test-embedded-dab-jwt.ps1`. For the complete real local setup/browser/cleanup proof, run `pwsh -NoProfile -File scripts/test-dab-issuer-live.ps1`. For already running applications, run `./scripts/test-dab-issuer-browser.ps1 -Issuer https://localhost:5001 -Api https://localhost:5002`. The [live proof](../../archive/research/dab-jwt-interoperability/LIVE-PROOF.md) records successful real Windows/database/browser-to-DAB reads, mutations, permission/role denials, antiforgery and logout on both REST and GraphQL. Twelve controlled regression tests complement that live evidence.

Browser `ignoreHTTPSErrors` affects only the test browser. It does not grant DAB's discovery/JWKS client trust in the issuer certificate. The approved local proof uses `DAB_DEVELOPMENT_ISSUER_CERTIFICATE_SHA256`: an exact 64-hex SHA-256 certificate fingerprint, selected by the live harness from the issuer's presented public leaf only after it matches an existing ASP.NET developer certificate. This option is accepted only in Development and only for the configured HTTPS localhost issuer origin. The certificate must match the pin, be currently valid, and support Server Authentication; hostname mismatch and other origins/ports fail closed. No workstation certificate-store change is performed. Omit the pin for normal CA-backed TLS validation. Changing the developer certificate requires reselecting its pin and restarting the API; do not carry this local option into production configuration.

## Troubleshooting and limits

| Symptom | Check |
| --- | --- |
| Missing KeyVault, OpenTelemetry, Serilog File or Humanizer assembly | Restore all five direct package pins; Core alone compiled but failed at runtime. |
| SQL TLS certificate chain untrusted | Verify the intended connection's Encrypt/TrustServerCertificate flags privately. Use the approved development trust option or a trusted server certificate. |
| Products object not inferred | Ensure initialization runs before RestService/authorization activation and that SQL metadata permissions are available. |
| GraphQL mutation reports no client role | Preserve the host-owned GraphQL request interceptor and ensure it places the client-role header in request context. |
| Configuration file missing | Run from the project directory or set a deliberate content root/config path. |
| Address already in use | Select an unused localhost port and stop only the host started for this run. |

The original Products proof establishes only an anonymous collection read and same-process shutdown. The configuration-driven API proof adds fixture-backed REST CRUD/key routes, GraphQL query/mutation, configuration permissions, and restart-based configuration changes. The issuer interoperability proof above adds real local JWT/cookie and role-selection evidence. These proofs do not establish live reload, MCP, production observability, IIS deployment, or an upstream-supported hosting contract. Keep secrets out of diagnostics; the prototype disables logging providers and returns generic errors for rejected REST requests.
