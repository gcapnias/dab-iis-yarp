# DAB in an ASP.NET Core application

This repository contains two working .NET 10 prototypes: a Windows-authenticated identity issuer and an ASP.NET Core application embedding Microsoft Data API builder Core 2.0.12 in its own process. The issuer supplies credentials; the embedded application validates them and serves configuration-driven REST and GraphQL access.

The handoff package is this repository's source, configuration examples, migrations, verification scripts and documentation. Start with the [prototype handoff and customization guide](docs/prototype-handoff.md) to understand the architecture and adapt it to your environment.

## Use the handoff package

1. Clone the repository or extract its source archive. Keep the source and linked documentation together. From a Git checkout, record `git rev-parse HEAD` with your delivery so recipients know its revision.
2. Prepare a Windows build workstation with the .NET 10 SDK and PowerShell 7, a SQL Server resource database, and a separate Identity database. Supply your own connection strings, persisted signing/encryption keys, HTTPS certificates and Windows caller mappings using the selected setup procedure below. Existing ignored `.scratch` files and test credentials are workstation-specific inputs.
3. Choose the setup procedure for your destination. Provision the issuer's Identity account/profile/roles and OIDC client before running the issuer, then configure and start the embedded API.
4. Customize resources, permissions, issuer settings and browser/application paths using the [handoff guide](docs/prototype-handoff.md). Build and verify your copy, then publish each application into its own folder for delivery.

| Destination | Procedure |
| --- | --- |
| Local development | [Set up and start the issuer](docs/runbooks/windows-authentication-jwt-issuer.md#local-configuration-and-startup), then [start the embedded API](docs/runbooks/dab-core-web-application.md#start-the-current-prototype) |
| New Windows Server/IIS installation | Follow the [complete clean-install procedure](docs/runbooks/windows-server-2025-clean-install.md), including runtime/ANCM prerequisites, SQL setup, keys, application pools and HTTPS |
| Existing IIS deployment | Use the [retained-state verification procedure](docs/runbooks/windows-server-iis-evaluation.md#recover-verification-inputs-for-the-retained-server) with its existing Identity store, caller and keys |

The evaluated IIS layout places the issuer at the HTTPS website root and the embedded API at `/dab`, in separate application pools. DAB runs inside the API worker; the issuer supplies its access credentials. The server examples identify the evaluated test environment; replace those inputs consistently for your own deployment.

## Build, verify and publish

Run these commands from the repository root to build both applications and run the tests that need no external database:

```powershell
dotnet build src/IdentityIssuer/IdentityIssuer.csproj -c Release
dotnet build src/EmbeddedDab/EmbeddedDab.csproj -c Release
dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj -c Release
dotnet test tests/EmbeddedDab.Tests/EmbeddedDab.Tests.csproj -c Release --filter 'FullyQualifiedName!~JwtDabIntegrationTests'
```

For SQL-backed API/JWT checks, use the [fixture verification instructions](docs/prototype-handoff.md#build-package-and-verify-a-customized-copy) with an authorized fixture connection. Those harnesses create and remove isolated databases; the filtered command above does not establish SQL integration coverage. For deployed IIS verification, use the retained-state procedure rather than the localhost launcher.

Create separate framework-dependent application packages:

```powershell
dotnet publish src/IdentityIssuer/IdentityIssuer.csproj -c Release --no-self-contained -o .scratch/delivery/issuer
dotnet publish src/EmbeddedDab/EmbeddedDab.csproj -c Release --no-self-contained -o .scratch/delivery/api
```

Deliver both publish folders alongside the source revision, [handoff guide](docs/prototype-handoff.md), runbooks, configuration examples, migrations and verification scripts. Provision private credentials, keys and certificates separately through the protected setup procedure. `.scratch/delivery` is temporary, gitignored staging space; copy the delivery to its intended destination when prepared. Server runtime installation and IIS configuration are covered by the clean-install procedure.

## Verified scope

The [handoff documentation review](archive/research/handoff-documentation-review-2026-10-11.md) records passing issuer tests, configuration-driven REST/GraphQL and JWT fixture checks, retained IIS browser/token checks, and publish validation. It also records the standalone test-runner limitation, unsuccessful separate localhost proof and test-client certificate bypass.

The handoff delivers the demonstrated prototype. Later session, health, deployment and recovery design decisions are optional guidance for recipient extensions, with their implementation status identified in the handoff guide. The recorded first installation on an empty Windows environment is accepted for this effort; production delivery remains outside this handoff.

## Repository contents

| Location | Purpose |
| --- | --- |
| [src/IdentityIssuer](src/IdentityIssuer) | Windows caller mapping, SQL-backed Identity, JWT/cookie and OIDC issuance |
| [src/EmbeddedDab](src/EmbeddedDab) | Same-process DAB bootstrap, REST/GraphQL adapters and browser credential bridge |
| [scripts](scripts) and [tests](tests) | Launch/publish helpers and scoped verification |
| [docs/runbooks](docs/runbooks) | Setup, startup and IIS procedures |
| [docs/adr](docs/adr) | Architecture decisions and their evolution |
| [archive/research](archive/research) | Recorded research and prototype evidence |
| [archive/spikes](archive/spikes) | Earlier proof source, including the fixed Products-read spike |
