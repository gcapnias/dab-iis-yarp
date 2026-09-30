# DAB host extension points and support contract

> Historical investigation, retained with its original findings. Review corrected the proposed Startup seam: Service/Startup is outside Core 2.0.12, so it is not available from that package. A later independently authored Core adapter, with explicit runtime dependencies, passed on .NET 8 and .NET 10. See the [current hosting proof](dab-core-hosting/README.md) and [startup runbook](../../docs/runbooks/dab-core-web-application.md). The original Startup-composition recommendation below is superseded.

**Question:** Can an ASP.NET Core application call DAB's service registration and endpoint pipeline in the same process without changing DAB source? What seams, package, initialization requirements, and support boundary exist? How does this differ from IIS ANCM in-process hosting?

**Reviewed:** 2026-09-29. Upstream source snapshot: [`Azure/data-api-builder` commit `0cba8b79072dacc789a1d81f85f8f7fc1ae6d959`](https://github.com/Azure/data-api-builder/commit/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959).

## Finding

There is **no documented or packaged DAB host-extension contract** (such as `AddDataApiBuilder` / `MapDataApiBuilder`) in the upstream repository. Same-process integration is nevertheless **technically plausible** through DAB's public `Startup.ConfigureServices` and `Startup.Configure` methods. That is a direct use of the runtime's implementation class, not a supported embedding API; it needs a prototype before it can be treated as viable.

The separate public `Program.CreateHostBuilder` seam builds a DAB-owned ASP.NET Core host with its own configuration, web server, middleware, and lifetime. Calling `StartEngine` runs that host synchronously. This could put a second host in the same OS process, but it does not attach DAB routes to the application's existing `WebApplication` pipeline and may conflict over process-wide settings or listen addresses. These methods are source-visible, but Microsoft does not document them as a host-integration API.

IIS ANCM `hostingModel="inprocess"` means IIS hosts **one ASP.NET Core application** inside `w3wp.exe` using `IISHttpServer`; it does not mean DAB is loaded into a different parent application's ASP.NET Core pipeline. Microsoft requires a separate app pool for an in-process IIS sub-application. This is process hosting of a separate IIS app, not application-level integration.

## Evidence and implications

### Upstream code seams

- [`Program.StartEngine` and `Program.CreateHostBuilder`](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Program.cs#L94-L168): `StartEngine` builds the host returned by `CreateHostBuilder` and runs it. `CreateHostBuilder` starts with `Host.CreateDefaultBuilder`, configures DAB's configuration and logging, then calls `ConfigureWebHostDefaults` and installs `Startup` with `UseStartup` ([web-host section](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Program.cs#L215-L229)).
- [`Startup.ConfigureServices`](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Startup.cs#L82-L145) is public and registers the runtime configuration loader/provider and DAB services. [`Startup.Configure`](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Startup.cs#L832-L910) initializes runtime configuration and performs startup work against an `IApplicationBuilder`. These methods are the only direct same-pipeline seam found in the source search; no `AddDataApiBuilder`, `AddDataAPIBuilder`, `UseDataApiBuilder`, or `UseDataAPIBuilder` API exists in the upstream source/docs search.
- DAB retains process-wide static state (`Program.LogLevelProvider` and several `Startup` static settings), and `ConfigureServices` constructs a file-system loader and reads configuration during host setup. See the same [`Startup` source](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Startup.cs#L82-L145). Multiple instances and cohabitation with an application's own DI/logging/configuration therefore need explicit testing.

### Package and .NET versions

- The current `main` service project targets `net10.0` ([service project](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Azure.DataApiBuilder.Service.csproj)). Its CLI project packages as a .NET tool named `dab`, references the service project, and the CLI invokes `Program.StartEngine` for the `start` command ([CLI project](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Cli/Cli.csproj), [start invocation](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Cli/ConfigGenerator.cs#L3150-L3158)). This describes a command-line runtime package, not a web-host integration package.
- At review time, the latest stable release was [DAB 2.0.12](https://github.com/Azure/data-api-builder/releases/tag/v2.0.12), with `net8.0` platform zips; the latest prerelease was [2.1.3-rc](https://github.com/Azure/data-api-builder/releases/tag/v2.1.3-rc), with `net10.0` zips. The [official App Service deployment guide](https://learn.microsoft.com/azure/data-api-builder/deployment/azure-app-service) restores the pinned .NET tool payload and launches `Microsoft.DataApiBuilder.dll start` as the app's startup command. It does not describe loading DAB as a library inside another ASP.NET Core application.
- The host application's target alone does not pick which DAB payload is used. A .NET 8 host cannot load a .NET 10-targeted DAB assembly; a separate process avoids that in-process compatibility constraint. For in-process composition, test the actual DAB release/package against the selected host TFM. No separate official hosting package or supported `PackageReference` recipe was found.

### Configuration and initialization if prototyped

- `Startup.ConfigureServices` selects `ConfigFileName` from host configuration and otherwise defaults to `dab-config.json`; it constructs `FileSystemRuntimeConfigLoader` and `RuntimeConfigProvider` ([source](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Startup.cs#L123-L145)). Pass an explicit config path and test resolution relative to the web application's working directory.
- DAB config values can use `@env(...)` for secrets; official deployment guidance supplies those through environment variables and copies the restored runtime payload into its deployment package ([App Service guide](https://learn.microsoft.com/azure/data-api-builder/deployment/azure-app-service), [deployment checklist](https://learn.microsoft.com/azure/data-api-builder/deployment/checklist)). A co-hosted prototype must decide which app owns configuration precedence, environment, logging, shutdown, telemetry, and database initialization.
- The direct `Startup` route would compose DAB's service registrations and middleware into the host application's `IServiceCollection` and `IApplicationBuilder`. Validate service-registration collisions, startup failure/lifetime behavior, path base/routing, endpoint conflicts, configuration reload, telemetry/log providers, and whether the desired DAB release can be referenced as an ordinary library. The existing code alone does not establish compatibility or support for this composition.

## Support boundary and recommendation

Microsoft's DAB deployment documentation presents the CLI/runtime, App Service, and container deployment flows; it does not document a first-class ASP.NET Core embedding API. Therefore describe direct `Startup` composition as **unsupported/uncommitted integration until an upstream contract or successful spike proves otherwise**, not as a supported DAB feature. `Program.CreateHostBuilder` is a public source method, but its documented behavior is to build DAB's own host, not merge DAB into the caller's pipeline.

For this Wayfinder, the next useful decision step is a small prototype against a pinned release: attempt to compose `Startup` with a minimal .NET 8 and/or .NET 10 `WebApplication`, then verify startup, REST/GraphQL routing, shutdown, and collision behavior. If a supported same-pipeline design is required, an upstream API (or maintained fork) that explicitly exposes service and endpoint registration may be needed.

The archived IIS guides remain useful for operational patterns, but they describe a separate DAB IIS application. The guide itself notes IIS is not a dedicated official DAB deployment recipe and that its `/dab` application has its own app pool ([out-of-process guide](../dab-using-net-application/iis-sub-application-deployment-guide.md#22-known-limitations-and-caveats)); this should not be used as evidence of embedding DAB into the parent's application.

## Sources

- [DAB Program.cs at reviewed source commit](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Program.cs)
- [DAB Startup.cs at reviewed source commit](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Startup.cs)
- [DAB service project](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Service/Azure.DataApiBuilder.Service.csproj)
- [DAB CLI project](https://github.com/Azure/data-api-builder/blob/0cba8b79072dacc789a1d81f85f8f7fc1ae6d959/src/Cli/Cli.csproj)
- [DAB stable release 2.0.12](https://github.com/Azure/data-api-builder/releases/tag/v2.0.12)
- [DAB prerelease 2.1.3-rc](https://github.com/Azure/data-api-builder/releases/tag/v2.1.3-rc)
- [Deploy DAB to Azure App Service](https://learn.microsoft.com/azure/data-api-builder/deployment/azure-app-service)
- [ASP.NET Core Module for IIS](https://learn.microsoft.com/aspnet/core/host-and-deploy/aspnet-core-module)
- [IIS sub-applications](https://learn.microsoft.com/aspnet/core/host-and-deploy/iis/advanced)
- [In-process hosting with IIS and ASP.NET Core](https://learn.microsoft.com/aspnet/core/host-and-deploy/iis/in-process-hosting?view=aspnetcore-10.0)
