# DAB distribution and .NET compatibility

> Historical investigation, retained with its original findings. The initial recommendation to test .NET 10 first was corrected: prove the package-aligned .NET 8 host first, then test .NET 10 separately. Both runtime proofs have now passed with explicit supplemental dependencies. See the [current hosting proof](dab-core-hosting/README.md) and [startup runbook](../../docs/runbooks/dab-core-web-application.md). The original framework recommendation below is superseded; final application policy remains undecided.

**Checked:** 2026-09-29  
**Decision supported:** choose a reproducible package/framework pair for the first integrated-hosting spike.

## Recommendation

Use the stable **`Microsoft.DataApiBuilder.Core` 2.0.12** package as the embedding candidate. Target **`net10.0`** for a new ASP.NET Core host and pin the package explicitly:

```xml
<PackageReference Include="Microsoft.DataApiBuilder.Core" Version="2.0.12" />
```

The package itself targets `net8.0`. NuGet reports it as compatible with `net10.0` (computed compatibility), and upstream documents this package specifically for embedding or extending DAB in .NET applications. This is the best current candidate for testing same-process hosting. The package README only gives high-level setup guidance (“register the DAB services”); it does not provide a complete host/pipeline sample, so route registration, lifecycle, path-base behavior, and coexistence with the app's own services remain spike questions.

If minimizing framework-version variables is more important than the support horizon, a `net8.0` host exactly matches the package TFM. That choice has a short runway: .NET 8 support ends November 11, 2026. .NET 10 LTS is supported until November 15, 2028. The package's computed `net10.0` compatibility is not a substitute for a runtime integration test.

## Pin and distribution

As of this check, the latest stable DAB release is **v2.0.12** (published 2026-09-02); NuGet also shows newer `2.1.4-rc`, which is prerelease. Release v2.0.12 provides the matching `Microsoft.DataApiBuilder.Core.2.0.12.nupkg`, `Microsoft.DataApiBuilder.2.0.12.nupkg`, and platform release zips. Pin package versions; do not use an unqualified “latest” restore.

There are two different package roles:

| Package | Intended use | Compatibility/evidence |
| --- | --- | --- |
| `Microsoft.DataApiBuilder.Core` 2.0.12 | Referenceable engine library for embedding/extending DAB in a host app | Package README explicitly describes embedding; TFM `net8.0`, NuGet-computed compatibility through `net10.0`; broad runtime dependencies below. |
| `Microsoft.DataApiBuilder` 2.0.12 | .NET CLI tool for authoring, validating, and starting DAB as its own host/process | NuGet says it is a .NET tool, not a regular library reference. The DAB release source CLI targets `net8.0` and is packed as a tool. |
| v2.0.12 platform zip | Runtime distribution for a separately launched DAB service | The archive's existing IIS guides use this for a standalone IIS application. This confirms the separate-process route, not a shared ASP.NET Core pipeline. |

Microsoft's App Service guide documents a reproducible standalone deployment pattern: pin the tool version, copy the restored `tools/net8.0/any` runtime payload, and start `Microsoft.DataApiBuilder.dll` with `dotnet`. This is useful fallback prior art if the Core-library spike cannot be completed. It starts DAB as the app's main process and does not demonstrate hosting DAB beside other routes in the same ASP.NET Core host.

## Framework, dependency, and source-build constraints

- The v2.0.12 service project and CLI target `net8.0`; the Core package project targets `net8.0` and packages DAB's internal Auth, Config, GraphQLBuilder, and Product assemblies alongside its main assembly.
- NuGet lists the Core package's external dependencies, including HotChocolate 16.x, `Microsoft.AspNetCore.Authentication.JwtBearer` >= 8.0.10, `Microsoft.Extensions.Configuration.Binder` and `.Json` >= 9.0.0, Cosmos/SQL/MySQL/PostgreSQL providers, OData, Newtonsoft.Json, OpenAPI, Polly, FusionCache, and **MSTest.TestFramework >= 3.3.1**. Expect restore to bring in a sizable graph; inspect `project.assets.json` and test for version conflicts with the host. The .NET 9 minimums on Extensions.Configuration are a notable point to verify in a `net8.0` host.
- A source build of tag v2.0.12 selects SDK `8.0.418` through `global.json` (`rollForward: latestFeature`) and builds `net8.0` projects. Prefer the published, pinned package for the first spike so the experiment is about host integration rather than reproducing Microsoft's build.
- Current upstream `main` has moved the service project to `net10.0`, but it is mutable and is not the same artifact as stable v2.0.12. The stable NuGet package avoids coupling the first experiment to an unpinned main-branch revision.

## Archived quick-start documents

The three `archive/dab-using-net-application/` guides are useful for the fallback IIS deployment, config, and endpoint smoke-test details. They are not evidence of in-process integration: two guides use ANCM out-of-process hosting and one recommends in-process hosting, while all show DAB as its own IIS application. Their disagreement supports testing the actual topology instead of treating those guides as a hosting contract.

## Next spike contract

Use a minimal `net10.0` ASP.NET Core application plus `Microsoft.DataApiBuilder.Core` 2.0.12. Record whether the package can register DAB into the same service provider and HTTP pipeline; demonstrate one DAB endpoint and one app-owned endpoint in one process; then check shutdown/restart, config loading, auth, and path-base behavior. If API/bootstrap work becomes source-dependent or cannot be made supportable from the package surface, compare the officially documented standalone `Microsoft.DataApiBuilder` tool payload as a separate-process fallback. This research identifies candidates; it does not claim runtime proof.

## Sources

- [DAB v2.0.12 release and assets](https://github.com/Azure/data-api-builder/releases/tag/v2.0.12)
- [Microsoft.DataApiBuilder.Core 2.0.12 on NuGet](https://www.nuget.org/packages/Microsoft.DataApiBuilder.Core/2.0.12)
- [Core package README at v2.0.12](https://github.com/Azure/data-api-builder/blob/v2.0.12/nuget/nuget_core/README.md)
- [Core package project at v2.0.12](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Azure.DataApiBuilder.Core.csproj)
- [DAB service project at v2.0.12](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Service/Azure.DataApiBuilder.Service.csproj)
- [DAB CLI project at v2.0.12](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Cli/Cli.csproj)
- [v2.0.12 SDK selection](https://github.com/Azure/data-api-builder/blob/v2.0.12/global.json)
- [DAB current service project on main](https://github.com/Azure/data-api-builder/blob/main/src/Service/Azure.DataApiBuilder.Service.csproj)
- [Deploy DAB to Azure App Service](https://learn.microsoft.com/en-us/azure/data-api-builder/deployment/azure-app-service)
- [.NET lifecycle dates](https://learn.microsoft.com/en-us/lifecycle/products/microsoft-net-and-net-core)
- [.NET releases and support policy](https://learn.microsoft.com/en-us/dotnet/core/releases-and-support)
