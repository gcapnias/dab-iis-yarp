# Configuration-driven REST and GraphQL proof

Ticket: [Prove configuration-driven REST and GraphQL access through embedded DAB](https://github.com/gcapnias/dab-iis-yarp/issues/9). Date: 2026-10-02.

## Result

**Go for the scoped configuration-driven prototype on .NET 10 with `Microsoft.DataApiBuilder.Core` 2.0.12.** The application loads DAB configuration into the same-process Core engine and serves REST and GraphQL from its own ASP.NET Core process. The verifier compiled the binary once, ran the initial configuration, stopped the host, replaced only the configuration file, and restarted the same binary. All 46 checks passed against a random disposable SQL Server database, and the database was removed by the verifier.

This extends the original narrow Products-read result documented in the [hosting research](README.md) and [runbook](../../../docs/runbooks/dab-core-web-application.md). The original Products evidence and source remain unchanged.

## Implementation

The prototype is under [`src/EmbeddedDab/`](../../../src/EmbeddedDab/). It pins Core 2.0.12 and the same four supplemental dependencies as the original proof. The host registers the public runtime loader/provider, metadata/query/mutation factories, `RestService`, `GraphQLSchemaCreator`, and the dependencies observed by the first spike.

The REST adapter enforces a segment-aware match on the configured `RestPath`, then uses Core's entity-path parser and dispatches configured routes to `RestService.ExecuteAsync` for read, insert, update/upsert, and delete operations. It executes the returned MVC result within the same ASP.NET Core request. The host composes `GraphQLSchemaCreator.InitializeSchemaAndResolvers` into Hot Chocolate's schema builder and maps the configured GraphQL path. Its request interceptor passes the current `HttpContext`, principal, and client-role header in the context form expected by the DAB GraphQL mutation engine.

The two sanitized, reproducible configurations are [`initial.json`](../../../src/EmbeddedDab/configurations/initial.json) and [`expanded.json`](../../../src/EmbeddedDab/configurations/expanded.json). The first exposes `Widget` and read-only `RetiredWidget`; the second changes the global REST path and the Widget entity path, adds `Label`, and removes `RetiredWidget`. The [verification script](../../../scripts/test-embedded-dab.ps1) creates all three tables and seed rows in an isolated, randomly named database, exercises the API, and drops the database.

## Verification

Run from a checkout with .NET 10 and access to the SQL Server specified by the primary checkout's ignored `.env`:

```powershell
./scripts/test-embedded-dab.ps1
```

The script compiled with **zero warnings and zero errors** and passed **46 checks**. The [captured transcript](evidence-ticket-9.txt) records the run. It verifies:

- Host and REST responses share a process ID; GraphQL requests share that ID as well.
- REST collection and primary-key reads return fixture rows. POST, PUT, PATCH, and DELETE operate on fixture data, with follow-up reads confirming updated values and removed rows.
- DAB returns HTTP 403 when a role configured only for `read` attempts a REST create.
- GraphQL query, create, update, and delete mutations execute against fixture data; follow-up reads confirm mutation effects. The read-only entity's create mutation fails schema validation because that field is absent.
- The expanded configuration exposes the changed global REST path and nested Widget path, exposes the added Label entity, and no longer exposes RetiredWidget.
- GraphQL moves to its configured path, exposes Label, and reports the removed RetiredWidget query field as unknown.
- REST paths that merely share a configured prefix without a segment boundary are rejected.
- The restarted host has a new process ID while the verifier uses the same compiled assembly.
- Fixture cleanup completes.

No Northwind tables or rows are written. The script requires the SQL identity in `.env` to create and drop a database. If the SQL account lacks those permissions, it fails before running the API proof. Connection details are not stored in source, configuration files, or the transcript.

## Limits and handoff

The two configs use DAB's `Unauthenticated` provider and a controlled `anonymous` role. The configured read-only entity demonstrates per-operation REST denial and GraphQL mutation generation based on configured permissions. In an additional check, an arbitrary `X-MS-API-ROLE` on an anonymous read did not change the effective role. Role-selection security is therefore not established by this prototype; the behavior must be resolved against the real issuer in ticket #10.

This result does not prove JWT validation, issuer/audience checks, cookie-to-token bridging, invalid or expired token denial, real caller role selection, IIS hosting, other database providers, every database-specific operation, MCP, live configuration reload, or an upstream-supported Core hosting contract. Configuration takes effect after restart. Ticket #10 remains the security interoperability gate; ticket #12 remains the Windows Server/IIS evaluation.

The scoped implementation finding is **GO**: Core 2.0.12 and application-owned bootstrap/adapters can expose fixture-configured REST and GraphQL access in the same process, including tested operations and restart-based entity/path changes. Keep production use conditional on the separate JWT, cookie, deployment, and lifecycle proofs.

## Primary API references

- [DAB Core 2.0.12 `RestService`](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Services/RestService.cs) parses configured entity paths and executes REST operations.
- [DAB Core 2.0.12 `GraphQLSchemaCreator`](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Services/GraphQLSchemaCreator.cs) creates configured schema fields and resolvers from Core query and mutation engines.
- [DAB 2.0.12 `Startup`](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Service/Startup.cs) composes that schema creator with Hot Chocolate and maps the configured GraphQL pipeline; the prototype independently implements the required host-owned integration without the Service assembly.
