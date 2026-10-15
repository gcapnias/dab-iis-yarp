# Ticket #25: refresh-rotation reproduction and fixture plan

Prepared and executed on 2026-10-15 for [ticket #25](https://github.com/gcapnias/dab-iis-yarp/issues/25). This document records the fixture design; the [reproduction report](reproduction-report.md) and [sanitized result](reproduction-result-2026-10-15.json) record the subsequently authorized execution. Initial preparation opened no SQL connections. The completed run confirmed all three service races failed their contract and the new fixture was dropped; no application fix has been selected or applied.

## Prepared target and authorization boundary

The local ignored `.env` contains one `ConnectionString` entry. Offline parsing identified this proposed target:

| Item | Planned value |
| --- | --- |
| SQL Server | `vs2026` |
| New disposable database | `dab_ticket25_f495883a4274` |
| Existing source catalog | `northwind`, used only to obtain connection settings; never opened by this harness |
| Administrative connection catalog | `master`, solely to create/identify/drop the new fixture |
| Authentication | Existing SQL login, read privately from `.env` |
| Encryption | Existing `Encrypt=True;TrustServerCertificate=True` preserved |
| Source revision | `04e5dc5463fefe29d6c4a66cddcf89a2050edc87` |
| Iterations | One sequential control and three independent concurrent races |

The maintainer authorized creating, initializing, exercising and dropping that one new database on that server through the existing connection after a successful read-only availability check. No account/login grants, server settings, installation, retained issuer-store changes or Northwind reads/writes were included. Creation/DDL/DML and teardown subsequently succeeded without permission changes. For any future run, if permission is unavailable, stop and report it; do not grant privileges or choose another target automatically.

The generated local approval plan is `.scratch/triage-25/fixture-plan.json`. It includes the target, source revision and a synthetic database ownership marker, but no credentials. Plan files are local ignored artifacts and must be regenerated/reviewed if lost. The harness refuses a changed server, source catalog, authentication mode, encryption setting or source revision, an invalid fixture name, or reuse of an existing plan file in generation mode. It never falls back to the source catalog.

## Reviewable harness

The [console project](repro/RefreshRotationRepro.csproj) references the real issuer project; [its source](repro/Program.cs) invokes the real `ApplicationDbContext` and `RefreshTokenService`. There are no application-source changes or new package pins. All fixture identities, keys used for ownership marking and refresh credentials are synthetic. Refresh tokens, hashes, connection strings, SQL text containing parameters, credentials, raw exception messages and stack traces are not emitted.

From the primary checkout, compile and validate the plan without SQL access:

```powershell
dotnet build archive/research/refresh-rotation/repro/RefreshRotationRepro.csproj --configuration Release
dotnet archive/research/refresh-rotation/repro/bin/Release/net10.0/RefreshRotationRepro.dll --validate-plan --dotenv .env --plan-file .scratch/triage-25/fixture-plan.json
```

After explicit approval for the target and operations above, execute with:

```powershell
dotnet archive/research/refresh-rotation/repro/bin/Release/net10.0/RefreshRotationRepro.dll --execute --dotenv .env --plan-file .scratch/triage-25/fixture-plan.json
```

Run from the primary checkout so the revision check identifies the approved source. Preserve the sanitized JSON and exit code. The execute command was run once under the recorded authorization; see the reproduction report. The recorded local plan is historical and will reject a different current HEAD, including a documentation-only revision, until a fresh execution plan is prepared/reviewed.

## Exact database operations

1. Open an encrypted, nonpooled connection to `master` on the approved server. Reject a pre-existing database with the planned name. Issue `CREATE DATABASE [dab_ticket25_f495883a4274]`; no existing catalog is reused or dropped to make creation succeed.
2. Record that new database's ID and creation timestamp. Open only the new catalog and set its `Ticket25ReproductionOwner` database extended property to the plan's synthetic marker.
3. Record product version, compatibility level, RCSI and snapshot-isolation settings. Observe existing defaults rather than changing server or isolation settings. The actual service still selects `Serializable` itself; no retry strategy is enabled by the harness.
4. Use the real EF model's `EnsureCreatedAsync` against this new empty database to create the issuer schema and its constraints. Insert one synthetic issuer-account row to satisfy the real refresh-token foreign key. Do not provision a Windows account, real browser caller or OIDC client.
5. Create a synthetic refresh family through `RefreshTokenService.CreateAsync`. Run normal rotation and then sequential replay through independent contexts. Verify one replacement and revocation of both records as a setup/control check.
6. For each of three new families, create two distinct `ApplicationDbContext` instances and independently opened SQL connections, record distinct SQL session IDs, and concurrently call the real `RotateAsync` with the same original token/profile.
7. In `finally`, dispose fixture contexts and connections. Before deletion, require the same database name, database ID, creation timestamp and ownership marker created by this invocation. Only then run `ALTER DATABASE [dab_ticket25_f495883a4274] SET SINGLE_USER WITH ROLLBACK IMMEDIATE` and `DROP DATABASE [dab_ticket25_f495883a4274]` through `master`. This targets only this invocation's verified new fixture.

There is no standalone cleanup mode that can delete a pre-existing database from a plan. A collision is not cleaned up. If creation times out before success can be established, if marker setup fails, or if cleanup identity cannot be proven, retain the possible fixture and report the fixed cleanup status rather than guessing ownership. Uncatchable process termination may also retain the new database; investigate its recorded identity before a separately authorized manual cleanup. This bounded cleanup does not claim protection against a concurrently acting SQL administrator replacing the target between validation and deletion.

## Race synchronization and signal

The harness attaches a test-only `SaveChangesInterceptor` to the two race contexts. At the first eligible `SavingChangesAsync`, it checks for a modified consumed refresh record and an added replacement. This confirms that each service call has completed its real lookup and reached the rotation-write path. It waits for both distinct contexts, then releases them together. Other saves, including subsequent recovery/revocation saves in the same context, pass through without another barrier or injected error. It does not replace results, rewrite queries, add hints, change application code or simulate a SQL exception.

The barrier has a 20-second deadline, SQL commands a 30-second timeout and each race a 50-second cancellation deadline. A barrier miss, cancellation or command timeout is inconclusive evidence. This synchronization deliberately forces the current concurrent-reader window; if a future fix serializes reads before that point, this barrier must be adapted rather than declaring the changed implementation wrong because the second reader cannot arrive.

Each actor produces only its rotation status or exception type chain and SQL error numbers. An independent context reads the final family and reports counts of total, consumed, revoked and unrevoked records, including unrevoked replacements. No token, token hash, SID/account record or connection value is included.

The intended contract is exactly one successful rotation, explicit replay handling for the competitor, two resulting records and no unrevoked family member. Any escaping exception or violation is reported. In particular, SQL error `1205` would establish the suspected deadlock outcome at the service boundary if observed; it is not assumed in advance. No HTTP host is started, so this experiment does not itself demonstrate an HTTP 500 response. Endpoint-level failure/status regression verification belongs in the subsequent implementation brief once the actual failure is established.

Exit codes:

- `0`: offline plan/validation succeeded, or all executed races satisfied the service contract and cleanup succeeded.
- `1`: synchronized races observed a service contract violation, with successful fixture cleanup.
- `2`: invalid/stale plan, setup/control failure, inconclusive execution or failed/unsafe cleanup. Inspect the sanitized report rather than treating this as reproduction of the suspected bug.

## Verified preparation and limits

- The retained project compiled on the existing .NET 10 toolchain with zero compilation errors.
- Plan-only generation and final offline validation both reported `databaseConnectionsOpened: 0`.
- A changed-target approval plan was rejected offline, and generation refused to overwrite the existing plan. The original plan remained unchanged.
- Subsequent authorized execution created/seeded/exercised/dropped the fixture and confirmed the defect in all three synchronized service races. A separate master-metadata check confirmed deletion. No endpoint request was made; the report preserves this distinction from an HTTP proof.
- The original sequential EF InMemory tests are useful regression coverage but do not exercise the SQL locking path. The planned fixture uses the actual SQL Server provider/model rather than an InMemory substitute.
- This work selects no concurrency fix and changes no transaction/replay semantics. Reproduction is complete; implementation and its regression acceptance remain separate work.

## Primary-source basis

Microsoft's [transaction locking guide](https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide?view=sql-server-ver17) states that serializable transactions retain read/write locks until transaction completion and describes possible deadlocks with concurrent select-then-update patterns. That supports investigating this service, but does not prove its observed outcome on the configured server.

The [SQL Server error 1205 reference](https://learn.microsoft.com/en-us/sql/relational-databases/errors-events/mssqlserver-1205-database-engine-error?view=sql-server-ver17) documents deadlock-victim rollback. Do not infer that a generic retry preserves this application's refresh-family replay/revocation contract.

The [EF Core interceptor documentation](https://learn.microsoft.com/en-us/ef/core/logging-events-diagnostics/interceptors) places `SavingChangesAsync` before changes are sent to the database. The prepared barrier uses this supported test seam without modifying service SQL or enabling retry behavior.
