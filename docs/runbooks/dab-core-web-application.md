# Start an ASP.NET Core application with DAB Core

Validated on 2026-09-30 with `Microsoft.DataApiBuilder.Core` 2.0.12, .NET 8.0.31 and .NET 10.0.12 against Northwind. The [research report](../../archive/research/dab-core-hosting/README.md) contains results and evidence. This runbook reproduces a web application with its own endpoint and a custom Products read adapter using DAB's engine in the same process.

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

The recorded runs passed on both frameworks. This does not determine the eventual application's target framework policy.

## Start a new project from this configuration

From the repository root, create a web project and seed it from the independently authored bootstrap and configuration:

```powershell
dotnet new web --name NorthwindDab --output src/NorthwindDab --framework net8.0 --no-restore
Copy-Item archive/spikes/dab-core-hosting/Host/Program.cs src/NorthwindDab/Program.cs
Copy-Item archive/spikes/dab-core-hosting/Host/dab-config.json src/NorthwindDab/dab-config.json
```

Set the new project's package references to the following exact tested set. Use `net8.0` initially; use `net8.0;net10.0` in `TargetFrameworks` if reproducing the two-framework comparison.

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.DataApiBuilder.Core" Version="2.0.12" />
    <PackageReference Include="Azure.Security.KeyVault.Secrets" Version="4.6.0" />
    <PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.15.3" />
    <PackageReference Include="Serilog.Sinks.File" Version="7.0.0" />
    <PackageReference Include="Humanizer.Core" Version="2.14.1" />
  </ItemGroup>
</Project>
```

The four supplemental dependencies fix observed missing runtime assemblies in the bundled Config code. Keep package pins with this bootstrap; their assembly versions can differ from their package versions. The code also uses dependencies restored transitively by this exact set.

```powershell
dotnet restore src/NorthwindDab/NorthwindDab.csproj
dotnet build src/NorthwindDab/NorthwindDab.csproj --no-restore
Set-Location src/NorthwindDab
$env:DAB_ENV_FILE = 'E:/Shared/Workspaces/personal/dab-iis-yarp/.env'
dotnet run --project NorthwindDab.csproj --no-build -- --initialize --urls http://127.0.0.1:5186
```

This seeds a disposable starting point from the tested host, including its diagnostic/verification modes. Adapt those modes and dotenv selection for the actual application's requirements before treating it as application architecture.

## Bootstrap requirements

The complete working registration code is in [Host/Program.cs](../../archive/spikes/dab-core-hosting/Host/Program.cs). Core 2.0.12 does not supply Service/Startup or a general `AddDataApiBuilder`/`MapDataApiBuilder` hosting recipe. Preserve these steps when adapting the code:

1. Register the runtime loader/provider/validator, query/mutation/metadata factories, request validator and `RestService`, plus their public dependencies. The tested graph includes authorization resolver/handler, HTTP context, CosmosClientProvider, GQLFilterParser and FusionCache/DabCacheService even though this example reads SQL only.
2. Configure `AddAuthentication().AddUnauthenticatedAuthentication()` and authorization services for this anonymous example. The JSON selects provider `Unauthenticated` and grants only anonymous `read` on Products.
3. Load `RuntimeConfigProvider.GetConfig()`, await `IMetadataProviderFactory.InitializeAsync()`, check its metadata exceptions, then resolve `RestService`. Authorization initialization depends on inferred metadata.
4. Preserve middleware order: `UseAuthentication`, `UseClientRoleHeaderAuthenticationMiddleware`, `UseAuthorization`, `UseClientRoleHeaderAuthorizationMiddleware`.
5. Map the app's own route and the Products adapter into the same app. The adapter invokes `RestService.ExecuteAsync("Products", EntityActionOperation.Read, null)` and executes the returned MVC `IActionResult` in the current request.

The [configuration](../../archive/spikes/dab-core-hosting/Host/dab-config.json) reads `@env('DAB_CONNECTION_STRING')`, enables REST at `/api`, disables GraphQL, and maps Products to `dbo.Products`. Adding an entity to JSON alone does not create another HTTP route: this host explicitly maps just the Products collection read.

## Troubleshooting and limits

| Symptom | Check |
| --- | --- |
| Missing KeyVault, OpenTelemetry, Serilog File or Humanizer assembly | Restore all five direct package pins; Core alone compiled but failed at runtime. |
| SQL TLS certificate chain untrusted | Verify the intended connection's Encrypt/TrustServerCertificate flags privately. Use the approved development trust option or a trusted server certificate. |
| Products object not inferred | Ensure initialization runs before RestService/authorization activation and that SQL metadata permissions are available. |
| DAB request lacks a client role | Preserve the unauthenticated provider and both Core client-role middleware steps. |
| Configuration file missing | Run from the project directory or set a deliberate content root/config path. |
| Address already in use | Select an unused localhost port and stop only the host started for this run. |

This proves a custom anonymous collection-read adapter and clean shutdown. It does not establish complete REST CRUD/key-route coverage, GraphQL/MCP, production authentication, hot reload, observability, IIS deployment or an upstream-supported hosting contract. Keep secrets out of diagnostics: the supplied spike disables logging providers and sanitizes exception strings rather than providing a production logging design.
