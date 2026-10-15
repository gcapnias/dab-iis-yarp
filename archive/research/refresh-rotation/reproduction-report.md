# Ticket #25: SQL Server refresh-rotation reproduction

Observed on 2026-10-15 against issuer source at `04e5dc5463fefe29d6c4a66cddcf89a2050edc87`. The suspected service-level defect is confirmed: all three synchronized races produced one successful rotation and one escaping exception containing SQL error `1205`, with the winning replacement still unrevoked.

## Scope and execution

The maintainer authorized continuing after a read-only availability check succeeded. The [prepared harness](repro/Program.cs) used the real issuer project, EF SQL Server model and `RefreshTokenService`. Only the newly created `dab_ticket25_f495883a4274` database on `vs2026` received schema/data mutations. The connection's original `northwind` catalog was replaced before opening connections; it and the retained issuer store were not opened by the reproduction. Master connections were used for fixture creation/identity checks/teardown and read-only metadata checks. All account/profile/refresh inputs were synthetic and no browser or HTTP application was started.

The execute command was:

```powershell
dotnet archive/research/refresh-rotation/repro/bin/Release/net10.0/RefreshRotationRepro.dll --execute --dotenv .env --plan-file .scratch/triage-25/fixture-plan.json
```

Exit code was **1**, the harness's observed-contract-violation result, with successful fixture cleanup. The complete [sanitized JSON result](reproduction-result-2026-10-15.json) contains no tokens, hashes, credential values, connection strings, exception messages or stack traces.

| Configuration | Observed value |
| --- | --- |
| SQL product version | `17.0.5015.4` |
| Database compatibility | `170` |
| Read committed snapshot | Off |
| Snapshot isolation | Off |
| Service transaction isolation | `Serializable`, selected by the real service |
| Retry strategy | Not enabled by the harness |
| Connection protection | Existing `Encrypt=True;TrustServerCertificate=True` preserved |

## Controls and race outcomes

The sequential control used independent contexts: normal rotation returned `Rotated`, then reuse returned `ReplayDetected`. The resulting family had two records, one consumed record and both records revoked. This control passed.

Each concurrent case used two independent contexts and SQL sessions for the same valid original refresh token. A test-only save interceptor waited until both real service calls had completed lookup and reached their first rotation save with a consumed original and an added replacement. Both callers reached that point in all cases. The interceptor only synchronized the first eligible save per context; subsequent recovery/revocation saves passed through unchanged. It changed no SQL, isolation level, result or exception.

| Race | Actor 1 | Actor 2 | Revoked records after both calls | Unrevoked replacements |
| --- | --- | --- | --- | --- |
| 1 | `Rotated` | Escaping SQL `1205` exception chain | 0 of 2 | 1 |
| 2 | `Rotated` | Escaping SQL `1205` exception chain | 0 of 2 | 1 |
| 3 | Escaping SQL `1205` exception chain | `Rotated` | 0 of 2 | 1 |

The exception chain was `InvalidOperationException` -> `DbUpdateException` -> `SqlException`, with SQL error number `1205`. No race was classified as a barrier timeout, command timeout or cancellation. Each family contained the consumed original and a live replacement; the loser did not return explicit replay handling or revoke the family. This is the same service contract gap described in the ticket, rather than an InMemory simulation of it.

The existing focused comparison command also passed all three tests:

```powershell
dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj --configuration Release --no-restore --filter FullyQualifiedName~RefreshTokenServiceTests
```

Those sequential InMemory tests exercise normal rotation/replay, a security-stamp change and cleanup. Their success does not cover the relational race, which failed in all three controlled SQL cases.

## Cleanup verification

The harness checked the new fixture's database ID, creation timestamp and ownership marker before dropping it. It reported `dropped_verified_new_fixture`. A separate read-only query through `master` then found zero `sys.databases` rows with the fixture name (`fixtureDatabasePresent: false`). No fixture database remains from this run.

## Consequences and limits

The service's current `DbUpdateConcurrencyException` catch does not handle the observed exception chain. The race can therefore leave the winning refresh family unrevoked. This is confirmed for the recorded provider/version/configuration and synchronized interleaving; it is not a measurement of unsynchronized production frequency or a claim about every SQL configuration.

No HTTP request was made. An actual HTTP 500 remains an unverified endpoint consequence; an implementation must include suitable endpoint-level regression evidence rather than presenting this direct-service run as an HTTP result. No concurrency fix has been selected or applied, no retry behavior has been introduced and no claim is made about invalidating already-issued access JWTs.

The after-read barrier deliberately exposes the starting implementation's concurrent-reader window. A fix that serializes reads before this point requires a different regression synchronization scheme; failure of a second reader to reach this barrier would be inconclusive, not proof the fixed implementation is wrong.

The recorded plan is bound to revision `04e5dc5`. Later documentation-only commit `f6a0200` does not change the tested service code, but the harness intentionally requires refreshing/reviewing a plan for a new execution at a different HEAD. No further execution is necessary to establish this triage finding.
