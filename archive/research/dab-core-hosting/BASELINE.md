# Baseline snapshot notice

Source/evidence references below are relative to the [spike artifact folder](../../spikes/dab-core-hosting/), rather than this report folder.

This is the original report from commit `11d120179a99d26e553f44981353b66ef254b783`. Host and Inspect source at that commit reproduce the baseline. Current Host/Inspect sources include the later authorized runtime-dependency supplement. The original evidence files outside `evidence/supplemented/` remain unchanged.

# Core-only same-process DAB hosting spike

Date: 2026-09-30. Ticket: [Prove minimal same-process DAB hosting](https://github.com/gcapnias/dab-iis-yarp/issues/6).

## Result

**A host using the actual Core public API compiles on .NET 8, but the pinned package-only runtime does not initialize.** Configuration loading throws `FileNotFoundException` for `Azure.Security.KeyVault.Secrets, Version=4.6.0.0`. That assembly is referenced by the bundled Config assembly but is absent from the restored dependency closure. No database connection or entity read was reached, and .NET 10 was not attempted.

This result establishes a failure of this package-only composition with the dependencies supplied by Core 2.0.12. It does not establish that no independently implemented bootstrap or supplemented dependency set could ever work. Such an investigation requires a scope decision in [Decide whether Core-only same-process DAB is viable](https://github.com/gcapnias/dab-iis-yarp/issues/7).

| Gate | Outcome | Evidence |
| --- | --- | --- |
| Actual pinned package and APIs | Inspected | `evidence/package-files.txt`, `core.nuspec.txt`, `public-api.txt`, `constructors-targeted.txt` |
| Minimal actual Core-only net8.0 composition | Compile passed, 0 warnings/errors | `Host/Host.csproj`, `Host/Program.cs`, `evidence/build-net8.txt` |
| Northwind-backed runtime | Initialization failed before listening or SQL access | `evidence/initialize-net8.txt` |
| Same code on net10.0 | Not attempted: net8 runtime prerequisite failed | No net10 claim |

## Package and composition

The only direct host package reference is `Microsoft.DataApiBuilder.Core` **2.0.12**; the project uses `Microsoft.NET.Sdk.Web` and `net8.0`. Ordinary ASP.NET Core framework APIs and dependencies restored transitively by Core are used. No Service assembly/source, copied upstream implementation, child process, separate application, or modified upstream code was introduced.

The package contains five managed assemblies under `lib/net8.0`, each with assembly version **2.0.12.0**:

- `Microsoft.DataApiBuilder.Core.dll`
- `Azure.DataApiBuilder.Auth.dll`
- `Azure.DataApiBuilder.Config.dll`
- `Azure.DataApiBuilder.Product.dll`
- `Azure.DataApiBuilder.Service.GraphQLBuilder.dll`

There is no Service assembly, Startup type, or RestController in this package. The metadata inventory found middleware helpers and engine APIs, but no complete DAB registration or REST route extension. Consequently this host does not attempt the already-known-absent `Startup.ConfigureServices` seam or invent an `AddDataApiBuilder` method.

The real public API provides:

```text
RestService.ExecuteAsync(string entityName, EntityActionOperation operationType, string primaryKeyRoute)
    -> Task<IActionResult>
```

Its constructor requires `IQueryEngineFactory`, `IMutationEngineFactory`, `IMetadataProviderFactory`, `IHttpContextAccessor`, `IAuthorizationService`, `RuntimeConfigProvider`, and `RequestValidator`. The targeted reflection inventory records their actual signatures.

The independently authored host registers these real factories and configuration services, maps `/host` to a host-owned response including the process ID, and maps GET `/api/Products` to `RestService.ExecuteAsync("Products", EntityActionOperation.Read, null)`, executing its MVC result in the same application. Both routes compile into one application pipeline.

The disposable configuration proposes `dbo.Products` from Northwind and anonymous read only. The root `.env` is loaded privately using the transitive DotNetEnv dependency; an entry is selected only if `SqlConnectionStringBuilder.InitialCatalog` is `northwind`. Only the catalog name is printed. Connection details are never passed on the command line or stored in these artifacts. The worktree has no `.env` copy.

The `--initialize` mode deliberately forces runtime configuration loading and RestService activation before starting the server. Loading configuration fails before RestService activation, so these registrations are a compile proof, **not a proven complete initialization graph**. Further factory dependencies include the OBO token provider, authorization resolver, Cosmos client provider, GraphQL filter parser, and cache service. Their wiring has not been validated because the package dependency blocker occurs earlier. No successful host-owned HTTP response, DAB read, process identity observation, schema confirmation, or shutdown behavior is claimed.

## Runtime blocker

The exact startup trace is in `evidence/initialize-net8.txt`. The failure is at:

```text
Azure.DataApiBuilder.Config.DeserializationVariableReplacementSettings..ctor(...)
Azure.DataApiBuilder.Config.FileSystemRuntimeConfigLoader.TryLoadKnownConfig(...)
Azure.DataApiBuilder.Core.Configurations.RuntimeConfigProvider.GetConfig()
```

The Core nuspec has no Azure Key Vault Secrets dependency. `evidence/restored-libraries.txt` independently confirms its absence from the resolved graph. This failure is during normal configuration loading, despite the SQL connection being supplied through an environment variable rather than Key Vault. No prerequisite/dependency repair was applied.

Separately, reflection over all exported Core types fails with missing `OpenTelemetry.Exporter.OpenTelemetryProtocol, Version=1.0.0.0`; see `evidence/reflection-all-net8.txt`. This is an API-discovery observation, **not the primary host startup failure**. Metadata-only enumeration avoids runtime type loading and completes successfully.

## Reproduce

Run from this worktree with an installed .NET SDK capable of targeting .NET 8. This run used SDK 10.0.401 and runtime 8.0.31, with SDK 8.0.425 also installed; `evidence/dotnet-info.txt` records the full environment. No environment install was needed.

```powershell
dotnet restore archive/spikes/dab-core-hosting/Host/Host.csproj --verbosity minimal
dotnet build archive/spikes/dab-core-hosting/Host/Host.csproj --no-restore --verbosity minimal
dotnet run --project archive/spikes/dab-core-hosting/Inspect/Inspect.csproj

$packagePath = Join-Path $env:USERPROFILE '.nuget/packages/microsoft.dataapibuilder.core/2.0.12'
$assemblies = Get-ChildItem $packagePath -Recurse -Filter *.dll | ForEach-Object FullName
dotnet run --project archive/spikes/dab-core-hosting/Inspect/Inspect.csproj --no-build -- --metadata $assemblies

# Optional: reproduces the separate reflection-only dependency failure.
dotnet run --project archive/spikes/dab-core-hosting/Inspect/Inspect.csproj --no-build -- --all
```

For the runtime attempt, run from `archive/spikes/dab-core-hosting/Host` so the content-root-relative configuration is found. Set the private dotenv path to the primary checkout path; this is a file path, not a connection string.

```powershell
$env:DAB_ENV_FILE = 'E:/Shared/Workspaces/personal/dab-iis-yarp/.env'
dotnet run --project Host.csproj --no-build -- --initialize
Remove-Item Env:DAB_ENV_FILE
```

Restore and build exited 0. Runtime initialization exited 1. The broad reflection run exited -532462766 due to an unhandled managed exception. Successful inventory files were generated by the included inspection utility; `public-api.txt` lists public types and methods plus assembly references, and `constructors-targeted.txt` adds actual parameter/return types for the proposed composition.

Package SHA-256: `BC4D3B033091CD1516135ACDEA84EAEB770EBD57D069B2BD8D59D01F4CF99267`. Nuspec repository commit: `0b38aa7cbf4118034ad8dee1f2712b1c4bac4c32`.

## Source cross-checks

The package binaries are the primary evidence. Source at `v2.0.12` was read only to explain the present APIs and the absent bootstrap:

- [Core package project](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Azure.DataApiBuilder.Core.csproj)
- [RestService public engine API](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Services/RestService.cs)
- [Separate Service startup](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Service/Startup.cs)
- [Separate REST controller](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Service/Controllers/RestController.cs)
- [Pinned package](https://www.nuget.org/packages/Microsoft.DataApiBuilder.Core/2.0.12)

The Firecrawl Developer Index skill was used with `firecrawl developer "Microsoft.DataApiBuilder.Core RestService AddDataApiBuilder ConfigureServices embedding" --limit 3`. It returned no applicable composition passage, so the investigation used the actual package and pinned upstream source. No external search hit was treated as a working hosting recipe.
