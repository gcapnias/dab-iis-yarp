# Core same-process DAB hosting spike

Ticket: [Prove minimal same-process DAB hosting](https://github.com/gcapnias/dab-iis-yarp/issues/6). Date: 2026-09-30.

For startup and new-project instructions, use the [runbook](../../../docs/runbooks/dab-core-web-application.md). Reports, reference host and evidence are available on the local `develop` branch; the spike branch is retained separately.

## Result

**The supplemented Core host passed the read-only Northwind proof on both .NET 8 and .NET 10.** One ASP.NET Core application serves its own `/host` endpoint and an independently authored `/api/Products` adapter that calls the actual public DAB `RestService.ExecuteAsync` engine. Both responses in each run report the same process ID. Database metadata, DAB read permissions, a real SQL query, host shutdown, and disposal all completed successfully.

This successful result supersedes the original unsupplemented runtime failure, which is preserved in [BASELINE.md](BASELINE.md), baseline evidence files, and commit `11d120179a99d26e553f44981353b66ef254b783`. The failure exposed omitted runtime dependencies; adding those ordinary dependencies preserves the same-process integration boundary.

| Gate | Final outcome | Evidence |
| --- | --- | --- |
| Actual Core 2.0.12 package/API inspection | Completed; five bundled net8.0 assemblies, no Service/Startup/controller | `evidence/public-api.txt`, `package-files.txt`, `core.nuspec.txt`, `constructors-targeted.txt` |
| .NET 8 compilation | Passed, zero warnings/errors | [build-net8-final.txt](../../spikes/dab-core-hosting/evidence/supplemented/build-net8-final.txt) |
| .NET 8 runtime | Passed on .NET 8.0.31; both HTTP 200; PID 44808 | [verify-net8.txt](../../spikes/dab-core-hosting/evidence/supplemented/verify-net8.txt) |
| Same source on .NET 10 | Passed on .NET 10.0.12; both HTTP 200; PID 44540; zero build warnings/errors | [build-net10.txt](../../spikes/dab-core-hosting/evidence/supplemented/build-net10.txt), [verify-net10.txt](../../spikes/dab-core-hosting/evidence/supplemented/verify-net10.txt) |

The build environment has SDK 10.0.401, SDK 8.0.425, and the above runtimes installed. The build used SDK 10.0.401 with the indicated target framework; the response explicitly records the actual execution runtime. This is observed runtime compatibility, not a claim based on NuGet's computed compatibility. No SDK or OS prerequisite installation was needed.

Disposable source and raw evidence remain under `archive/spikes/dab-core-hosting/`: [Host/Program.cs](../../spikes/dab-core-hosting/Host/Program.cs), [Host.csproj](../../spikes/dab-core-hosting/Host/Host.csproj), [DAB configuration](../../spikes/dab-core-hosting/Host/dab-config.json), [API inspection utility](../../spikes/dab-core-hosting/Inspect/Program.cs), and [evidence](../../spikes/dab-core-hosting/evidence). File paths in this report are relative to that artifact folder unless the commands explicitly start at the worktree root.

## Exact direct dependencies

The host targets `net8.0;net10.0` and has exactly five direct package references. The inspection utility uses the same set plus the ordinary `Microsoft.AspNetCore.App` framework reference.

| Package | Exact pin | Reason and evidence |
| --- | --- | --- |
| Microsoft.DataApiBuilder.Core | 2.0.12 | Pinned DAB engine; actual binaries inventoried |
| Azure.Security.KeyVault.Secrets | 4.6.0 | Config references assembly 4.6.0.0; baseline initialization fails in variable-replacement settings |
| OpenTelemetry.Exporter.OpenTelemetryProtocol | 1.15.3 | After KeyVault addition, JSON deserialization requires telemetry-model assembly 1.0.0.0; `initialize-keyvault.txt` |
| Serilog.Sinks.File | 7.0.0 | After exporter addition, deserialization requires file-sink-model assembly 7.0.0.0; `initialize-otel.txt` |
| Humanizer.Core | 2.14.1 | Entity defaults require Humanizer assembly 2.14.0.0 even with GraphQL disabled; `initialize-serilog.txt`. The Core package supplies that assembly without localized resources |

Versions follow the pinned upstream [`src/Directory.Packages.props`](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Directory.Packages.props). The bundled [Config project](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Config/Azure.DataApiBuilder.Config.csproj) declares these dependencies, but Core's nuspec omits them. Package and assembly versions differ: exporter 1.15.3 and Humanizer.Core 2.14.1 are intentional source pins. Each added dependency followed an actual missing-assembly failure, with sanitized intermediate traces retained under `evidence/supplemented/`.

No Service assembly, copied Service source, modified upstream implementation, separate DAB executable, or child process is involved. All host glue was independently authored against public package APIs. The missing dependency supplement also allows broad public-type reflection to succeed; `evidence/supplemented/reflection-all-net8.txt` records it.

## Actual bootstrap and endpoint adapter

`Host/Program.cs` registers the public runtime loader/provider/validator, query/mutation/metadata factories, HTTP context and authorization services, CosmosClientProvider (a constructor dependency even for SQL), GQLFilterParser, AuthorizationResolver and RestAuthorizationHandler, an in-memory FusionCache, DabCacheService, RequestValidator, and RestService. Optional OBO arguments retain normal constructor defaults; there are no identity or authorization stubs.

Initialization loads configuration, calls `IMetadataProviderFactory.InitializeAsync()`, checks recorded metadata exceptions, and activates RestService. Metadata must be inferred before AuthorizationResolver builds entity permissions. Intermediate configuration/DI iterations are preserved; they are not the final verdict.

For the anonymous read proof, configuration selects DAB's `Unauthenticated` provider. The pipeline uses Core's public unauthenticated authentication registration and client-role authentication/authorization middleware. The independently authored adapter calls:

```csharp
await rest.ExecuteAsync("Products", EntityActionOperation.Read, null);
```

It executes the returned MVC `IActionResult` in the same ASP.NET Core request. DAB supplies request parsing, metadata, permissions, query execution, serialization, pagination, and the `nextLink`; the host supplies the narrow route adapter and bootstrap. A diagnostic `X-Spike-Process-Id` header and `/host` response establish identical process identity for both endpoints.

This is a **minimal, custom read adapter**, not a packaged general-purpose DAB hosting extension or a complete recreation of DAB's Service REST surface. The proof establishes feasibility of invoking the engine in the host; it does not establish an upstream-supported embedding contract or the scope of a production adapter.

## Northwind evidence and connection settings

Both framework runs returned two genuine DAB rows: ProductID 1, Chai, and ProductID 2, Chang. Separate direct read-only SQL checks confirmed:

- Database `northwind`, table `dbo.Products`, **77 rows**.
- **10 columns**; full names, SQL types, and nullable flags are in each verification transcript.
- Primary key `ProductID`.
- Matching first two SQL rows, ordered by ProductID.

No schema, data, or server changes were performed. Metadata discovery and verification commands only read schema/data.

The server initially failed SQL login because its TLS certificate chain is untrusted; `initialize-metadata.txt` preserves that trace. The user explicitly approved trusting this development server certificate and then requested that the primary root `.env` retain the setting for future reference. Its connection was privately updated to **TrustServerCertificate=True and Encrypt=True**, preserving server, database, user, and password. The root `.env` remains ignored and untracked; no copy exists in the worktree, and it is not part of any commit.

Final successful runs use those persistent `.env` settings. The optional spike-only `DAB_TRUST_SERVER_CERTIFICATE=true` override remains available; it enforces encryption as well. OS certificate trust was not changed.

The dotenv loader privately selects a connection whose parsed catalog is `northwind`. Secrets are neither passed on the command line nor written to tracked config/evidence. Logging providers are disabled. Exception traces scrub the original and normalized connection strings, server, username, and password before printing. Secret checks passed against the tracked artifacts.

## Reproduce final proof

From the worktree root:

```powershell
dotnet restore archive/spikes/dab-core-hosting/Host/Host.csproj --verbosity minimal
dotnet build archive/spikes/dab-core-hosting/Host/Host.csproj --framework net8.0 --no-restore --verbosity minimal
dotnet run --project archive/spikes/dab-core-hosting/Inspect/Inspect.csproj
```

From `archive/spikes/dab-core-hosting/Host`, with the primary `.env` already containing the approved development certificate settings:

```powershell
$env:DAB_ENV_FILE = 'E:/Shared/Workspaces/personal/dab-iis-yarp/.env'
dotnet run --project Host.csproj --framework net8.0 --no-build -- --verify --urls http://127.0.0.1:5186
Remove-Item Env:DAB_ENV_FILE
```

Only after the .NET 8 proof succeeds:

```powershell
dotnet build Host.csproj --framework net10.0 --verbosity minimal
$env:DAB_ENV_FILE = 'E:/Shared/Workspaces/personal/dab-iis-yarp/.env'
dotnet run --project Host.csproj --framework net10.0 --no-build -- --verify --urls http://127.0.0.1:5187
Remove-Item Env:DAB_ENV_FILE
```

Both builds and both verification runs exited **0**. Verification starts the actual web server, checks both HTTP responses and the process header, reads SQL schema/count/sample rows, then calls `StopAsync` and `DisposeAsync`. Both transcripts end with `Host stopped and disposed`; no listeners remained on ports 5186 or 5187 afterward. `--initialize` instead starts the host for manual inspection; use it only when a persistent disposable server is wanted.

## Remaining decisions

This disposable proof does not decide the production target framework/package policy, general REST routing/CRUD coverage, authentication design, configuration reload, observability, IIS deployment, or acceptance contract. GraphQL and MCP are disabled/unproven. The next viability decision should evaluate the custom bootstrap/adapter maintenance cost and dependency pinning with the user; it should no longer treat omitted runtime dependencies as a same-process blocker.

Primary API source references: [Core project](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Azure.DataApiBuilder.Core.csproj), [RestService](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Services/RestService.cs), [MetadataProviderFactory](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Services/MetadataProviders/MetadataProviderFactory.cs), and [client-role authentication middleware](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/AuthenticationHelpers/ClientRoleHeaderAuthenticationMiddleware.cs). The actual package binaries and successful executions are the proof; source was used only to explain their public APIs. Firecrawl Developer Index searches found no applicable host composition passage, so no search result was treated as a working recipe.
