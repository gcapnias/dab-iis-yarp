# Windows Server IIS evaluation

Date: 2026-10-04. Ticket: [Evaluate the completed issuer and embedded DAB on Windows Server IIS](https://github.com/gcapnias/dab-iis-yarp/issues/12).

**Environment finding: GO for the evaluated Windows Server/IIS test topology.** The separate issuer and same-process embedded DAB applications run under non-administrator pools. Real Windows/Identity/browser interoperability, OIDC, configured authorization, invalid-token handling and lifecycle checks passed. The deployed DAB application accesses **Northwind**, with read-only `dbo.Products` REST/GraphQL permissions. Mutation checks used an isolated fixture; no Northwind sample data was changed.

Implementation source is local `develop` commit `0d96f69` (unpushed), based on `3230628`. The final documentation/evidence commit follows it. Deployed application SHA-256 values, unchanged across restart checks:

- `EmbeddedDab.dll`: `73D67CD203AA41E064E9406BBD838CF2E88A3B2849D4B785B0C779FB4364E053`
- `IdentityIssuer.dll`: `7983355CCCDA9B47C9DC18F8AD35DE09B53C228FD43A9529E6F36591477C1488`

## Authorization and environment

The user supplied a DPAPI-protected remoting credential file and authorized PowerShell remote access, server preparation, installation of missing components/runtimes, deployment under the Default Web Site, and testing from the existing workstation. The user approved a self-signed test HTTPS certificate for the server hostname and explicitly requires the deployed DAB application to access Northwind.

Sanitized inventory:

| Item | Verified value |
| --- | --- |
| Host | `ws2025s01.mshome.net` |
| OS | Windows Server 2025 Standard, 10.0.26100.0 |
| Server PowerShell | 5.1.26100.33438 |
| IIS | Microsoft-IIS/10.0; Web-Server and Web-Windows-Auth installed |
| .NET runtimes | Microsoft.NETCore.App and Microsoft.AspNetCore.App 10.0.12 |
| ANCM | 20.0.26234.12, in-process |
| Site | Default Web Site, HTTP 80 and HTTPS 443 |
| Issuer | Root application, `DabProofIssuer` pool |
| Embedded DAB | `/dab`, `DabProofApi` pool |
| Worker identities | Both ApplicationPoolIdentity; no administrator worker |
| Browser caller | Dedicated expiring local proof account; administrator membership checked false |
| Issuer HTTPS | SAN covers server hostname, three-month self-signed test certificate |
| Server trust | Public certificate installed in server LocalMachine/Root for discovery/JWKS |
| Workstation trust | Unchanged; browser and HTTP test clients bypass certificate validation explicitly |
| Signing/encryption | Separate RSA-3072 PEM keys outside published files |
| Identity store | Dedicated disposable database with five IdentityIssuer migrations |
| Mutation fixture | Isolated Widgets/RetiredWidgets SQL tables, separate from Northwind |

The exact Microsoft Hosting Bundle downloaded from official release metadata passed SHA-512 verification and Microsoft Authenticode validation. Installer exit code was 0. IIS installation reported no required restart. The workstation received no IIS features, runtimes, browsers or certificate trust changes.

## Completed acceptance

| Check | Result and evidence |
| --- | --- |
| Workstation-to-server WinRM | Successful, server hostname/version returned |
| Issuer anonymous discovery | HTTPS 200 from workstation |
| Real Windows identity | HTTPS 200; WindowsIdentity, SID claim and request-token SID presence true; values not logged |
| Issuer browser OIDC/session suite | 27 checks passed; token fetch HTTP 200; normal proof caller |
| Embedded fixture browser suite | 19 checks passed over real IIS issuer/database/browser/DAB chain |
| Final Northwind browser suite | 12 checks passed, including Chai/Chang, generated `/dab` pagination, process identity and post-logout denial |
| Real-IIS bearer validation | 24 REST/GraphQL checks passed; real reader/writer credentials and controlled missing/malformed/expired/future/wrong-issuer/wrong-audience/no-role/unknown-key/invalid-signature cases |
| Origin and anonymous boundaries | 5 checks passed; same-origin GraphQL POST accepted, foreign origin/missing antiforgery denied, anonymous protected issuer routes denied |
| Persisted account restrictions | Disabled and locked synthetic accounts both denied; original enabled/unlocked state restored |
| Fixture REST and GraphQL | Authenticated reads and mutations passed; created rows deleted |
| Cookie protection | HttpOnly/Secure/host-only flags, API JavaScript invisibility, both missing-CSRF denials passed |
| Configured authorization | REST/GraphQL write denial on RetiredWidget and ungranted-role denial passed |
| Logout | Browser credentials removed; subsequent REST/GraphQL denied |
| Issuer regressions | 34/34 Release tests passed |
| DAB regressions | 13/13 Release tests passed, including an IIS PathBase integration regression |
| Fresh SQL installation | Corrected complete idempotent script passed on a clean disposable database |
| Repeated SQL installation | Same script reapplied successfully; verification database removed |
| SQL reachability | Server reached SQL Server TCP port 1433 |
| Same-process API startup | `/dab/host` returned application PID and .NET 10.0.12 after configuration/ACL fixes |
| Configuration changes | Fixture-to-Northwind entity/permission change and base-route correction used configuration and pool restart with unchanged binary |
| Lifecycle/recovery | API stopped and recovered with a new worker PID; issuer pool restarted successfully; both binaries unchanged |
| Discovery TLS | Server-side HTTPS discovery validated the hostname/certificate using normal Windows trust |
| Callback access-log handling | IIS log field list excludes UriQuery; application category already suppresses raw callback queries |

Issuer browser checks covered discovery, same-origin callback, real SID binding, antiforgery, session issuance, access/refresh attributes, rotation/replay, logout, OIDC code/PKCE, callback state, ID/access token signatures/claims and OIDC refresh-family replay rejection. The fixture browser checks exercised both API transports through the real issuer cookie bridge. Neither suite serialized passwords, SID values, profile values, authorization codes, JWTs or refresh secrets into result output.

## Deployment findings and fixes

1. **IIS physical paths:** forward-slash physical paths produced static-file 404 responses and omitted the published ANCM handler from effective configuration. Native `C:\...` paths loaded `web.config` correctly.
2. **Child-application configuration access:** the separate API pool required read access to the parent's non-secret `web.config` and non-inherited directory listing/traversal/metadata rights for IIS monitoring. Without the directory rights, the worker loaded ANCM but not CoreCLR and requests timed out. Restricting those rights to the directory and checking that the API had no issuer secret-file ACE restored startup. No recursive issuer grant was applied.
3. **REST adapter:** concatenating IIS `Request.PathBase` with `Request.Path` passed `/dab/api/...` to DAB's parser, which expects application-relative `/api/...`. The adapter now supplies Request.Path. The integration regression drives the real REST and GraphQL routes with `/dab` removed by a startup filter.
4. **Optional local SQL bootstrap:** the API host previously required a Northwind `.env` setting even with a complete deployed DAB connection configuration. The local loader is now invoked only for the environment-file/fixture workflow. IIS can consume its protected DAB configuration directly.
5. **Clean SQL migration:** adding ExpiresAt then referencing it in the same generated SQL batch failed at compilation. Deferred compilation through `EXEC(N'...')` fixes the migration source and regenerated complete/incremental scripts. Clean and repeated execution passed.
6. **Browser verifier:** the previous DAB harness enforced localhost root URLs. It now supports distinct same-host HTTPS applications and application prefixes. Both browser harnesses accept an optional DPAPI credential file restricted to the issuer origin, and remove their transient scratch configuration after execution. The new Northwind mode reads sample Products without mutating them.
7. **Pool restart timing:** immediately starting a just-stopped pool can fail with `0x80070425`; wait for Stopped before copying/starting.
8. **Generated URLs:** DAB Core's pagination helper uses `runtime.base-route`, rather than ASP.NET Request.PathBase. Setting `/dab` fixes pagination without recompiling. The regression follows the generated link; the Northwind browser proof follows it to ProductID 3. The same setting governs creation Location URLs. [Pinned pagination helper](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Resolvers/SqlPaginationUtil.cs), [pinned response helper](https://github.com/Azure/data-api-builder/blob/v2.0.12/src/Core/Resolvers/SqlResponseHelpers.cs).
9. **Verifier response handling:** PowerShell receives GraphQL's response content as bytes for its media type. The token verifier explicitly decodes UTF-8 before parsing JSON. WebRequestSession also caches custom headers; the standalone missing-antiforgery check removes the cached token header before asserting denial.

## Resolved configuration interruption

While switching the deployed API from the isolated mutation fixture to Northwind, the server's legacy System.Data.SqlClient connection parser rejected the `trust server certificate` keyword used by the Microsoft.Data.SqlClient connection. The attempted command continued and left an incomplete connection string. This is a deployment configuration failure, not an established DAB package limitation.

Automatic approval review rejected restoring credential-bearing SQL configuration into the deployed DAB JSON, stating that persistent storage at that destination needed explicit authorization. The user then explicitly approved protected test-server credential storage at `C:\DabIisProof\api\dab-config.json`. Restoration used the generic connection-string builder, preserved encryption/test SQL trust settings, and set the catalog to Northwind. The file ACL is restricted to SYSTEM, administrators and the API pool. No rejected credential-copy action was executed before that approval. Final API startup and all remaining acceptance checks passed.

## Reproduce the evaluated checks

The [server runbook](../../../docs/runbooks/windows-server-iis-evaluation.md) contains publishing, topology, certificates, configuration, recovery and issuer/Northwind browser commands. Additional read-only API and isolated account checks:

```powershell
pwsh -NoProfile -File scripts/test-dab-iis-token-validation.ps1 -Issuer 'https://ws2025s01.mshome.net/' -Api 'https://ws2025s01.mshome.net/dab' -CredentialFile .scratch/ws2025s01/browser-credentials.xml -SigningKeyFile .scratch/ws2025s01/signing.pem
pwsh -NoProfile -File archive/research/windows-server-iis/check-origin-boundaries.ps1 -Issuer 'https://ws2025s01.mshome.net/' -Api 'https://ws2025s01.mshome.net/dab' -CredentialFile .scratch/ws2025s01/browser-credentials.xml
pwsh -NoProfile -File archive/research/windows-server-iis/check-account-restrictions.ps1 -Issuer 'https://ws2025s01.mshome.net/' -CredentialFile .scratch/ws2025s01/browser-credentials.xml -ConnectionFile .scratch/ws2025s01/fixture-connection.txt
dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj -c Release
pwsh -NoProfile -File scripts/test-embedded-dab-jwt.ps1
```

The signing-key argument is the explicitly provisioned **test issuer key**, not the HTTPS certificate or a production signing key. The verifier checks its public key against the actual issuer JWKS before generating otherwise-valid controlled negative tokens; successful reader/writer cases use the real Windows/Identity issuer token. The account restriction script operates only on the generated disposable database and the synthetic proof profile, verifies its initial state and restores it in finally. Origin checks send only read queries to Northwind. Normal TLS validation remains on the server; these workstation HTTP/browser commands deliberately use the test certificate bypass.

For lifecycle verification, record each application's file hash, use `Stop-WebAppPool DabProofApi`, wait for Stopped, start the pool, and confirm `/dab/host` returns a new PID. Restart the issuer pool and confirm anonymous discovery returns 200. Compare hashes after restart. Inspect effective pool identities, disabled temporary stdout/ANCM tracing, and the site's log fields excluding UriQuery. These exact checks passed in the recorded run.

## Limits and retained state

This is a test-server environment proof, not production readiness. Production CA certificates, signing-key rotation/revocation, secret management, least-privilege SQL login rollout, production identity operations, arbitrary cross-origin clients, production profile policies and production rollout are outside this ticket. The server worker identities and browser caller are non-administrative; that does not by itself establish least-privilege SQL credentials.

The proof keys, account/client, isolated Identity database, applications, server certificate/trust entry and HTTPS rule remain for authorized continuation. The caller expires after 14 days and the certificate after three months. Other disposable regression/migration fixtures were removed. No Northwind sample-data writes were performed. Linked worktrees and unrelated history were preserved.

See the [IIS deployment and recovery runbook](../../../docs/runbooks/windows-server-iis-evaluation.md) for reproducible topology/setup and browser commands. Sensitive setup material and temporary diagnostics remain ignored; no secrets are in this report.
