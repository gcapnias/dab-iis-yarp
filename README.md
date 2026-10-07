# DAB in an ASP.NET Core application

This repository contains two working .NET 10 prototypes: a Windows-authenticated identity issuer and an ASP.NET Core application embedding Microsoft Data API builder Core 2.0.12 in its own process. The issuer supplies credentials; the embedded application validates them and serves configuration-driven REST and GraphQL access.

Start with the [prototype handoff and customization guide](docs/prototype-handoff.md). It connects the current source, setup instructions, customization points and recorded verification evidence.

## Run the prototype

- [Local issuer setup](docs/runbooks/windows-authentication-jwt-issuer.md#local-configuration-and-startup): Identity database, caller mapping, roles, keys and startup.
- [Current embedded application](docs/runbooks/dab-core-web-application.md#start-the-current-prototype): select a DAB configuration and start the current host.
- [New Windows Server/IIS installation](docs/runbooks/windows-server-2025-clean-install.md): complete evaluated installation procedure.
- [Retained IIS deployment](docs/runbooks/windows-server-iis-evaluation.md): verify an existing installation while retaining its identity store and keys.

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

The handoff describes the delivered prototype. Later design decisions are linked as customization guidance, with their implementation status identified. The recorded first installation on an empty Windows environment is accepted for this effort.
