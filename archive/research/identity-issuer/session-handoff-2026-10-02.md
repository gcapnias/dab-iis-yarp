# Issuer session handoff, 2026-10-02

Work is intentionally stopped at the user's request. Completed source and artifacts are committed and integrated onto local `develop`; nothing has been pushed. Existing linked worktrees and ignored local keys are retained. Do not treat stopped work as ticket completion.

## Delivered local work

- Branch `task/11-windows-jwt-issuer`: `aaad731`, `43607d1`, `355001e`, `628605f`, and final follow-up `144a73b`.
- ASP.NET Core Identity/SQL Server account mapping, profile/role claims, account restrictions, JWT cookies, genuine OpenIddict code/PKCE, signed ID/access tokens, persisted refresh rotation/replay-family protection and cleanup, key overlap, runnable configuration, PowerShell/HTTP request tooling, and publish/browser scripts.
- Final implementer checks: Release issuer build with zero warnings/errors; 32 tests passed, zero failed/skipped; PowerShell/JavaScript syntax and whitespace checks passed. These results were reported by the implementer; no redundant suite/server/database rerun was done during persistence.
- Real Kestrel/default-Windows-credential/SQL proof validated request WindowsIdentity/SID presence, JWT/public keys, CSRF, session/refresh/logout and the full OIDC protocol through the PowerShell harness. Local Edge browser passed 16 cookie/session assertions, including explicit future expiries, sequential rotation, stale replay rejection and logout. Browser OIDC obtained a code but did not reach verified token exchange.
- The three advisor duplication findings were addressed with shared OIDC profile claims, cookie write/expiry semantics, and refresh-family revocation. Browser testing uncovered an empty root refresh-cookie Path; explicit `/` fixed browser replacement, verified on fresh processes.

## Review record and unresolved findings

Fresh advisor review at `628605f` found no hard standards violations or verified high-severity defect; it requested three duplication improvements and a concrete browser-origin/cookie contract. The follow-up at `144a73b` implements those extractions, defines the local contract and records browser proof limits. Its Spec reviewer found no actionable follow-up gap; Standards review identified the remaining verifier origin/CORS mismatch and the diagnostic prerequisite mismatch.

- [#11](https://github.com/gcapnias/dab-iis-yarp/issues/11): issuer ticket, claimed by gcapnias, remains open. Local implementation is integrated; final tracker resolution is deliberately not claimed while child investigation remains open.
- [#13](https://github.com/gcapnias/dab-iis-yarp/issues/13): native child of #11. Investigate browser callback/navigation and sanitized runner results before browser token exchange. Review also identified callback-origin token-fetch/CORS and unconditional Development-only diagnostic assumptions. See [separate report](browser-oidc-investigation.md).
- [#9](https://github.com/gcapnias/dab-iis-yarp/issues/9): configuration-driven embedded REST/GraphQL proof, still independent of issuer.
- [#10](https://github.com/gcapnias/dab-iis-yarp/issues/10): issuer-to-real-DAB cookie bridge, REST/GraphQL authentication and configured permissions; depends on issuer/API proofs.
- [#12](https://github.com/gcapnias/dab-iis-yarp/issues/12): last native child of map #2, blocked by #11/#9/#10. Evaluate completed applications and runbooks on the user's Windows Server/IIS test environment. The server and access details are not yet supplied; local workstation has no IIS/WAS/appcmd/ANCM and nothing was installed.

## Decisions and operational state

[ADR-0003](../../../docs/adr/0003-windows-bound-identity-issuer-and-validation-gates.md) records the accepted issuer ownership, SID binding and validation boundaries. The root glossary was updated with caller/account/profile/role/session/family/bridge/proof vocabulary. Original user Identity and Windows-auth research artifacts are retained unchanged and tracked.

Disposable Northwind has five applied `IdentityIssuer` migrations, a synthetic current-Windows-account mapping/profile/role/claim, and a registered PKCE test client. Sample DAB tables were not targeted. A migration-tooling mistake temporarily reverted initial Identity tables; the reviewed migration set and synthetic data were restored. A connection string was accidentally printed once in a tool transcript; no credential value is in tracked artifacts and no rotation was requested or performed. The detailed sanitized note is in the implementation report.

Private signing/encryption keys remain in `.scratch/identity-issuer/keys/`, verified gitignored; `.env` remains ignored. Do not delete these on cleanup or include them in a publish/commit. Temporary browser sessions are not proof artifacts. No new server/test processes were launched for the handoff.

Playwright test certificates use the approved `ignoreHTTPSErrors: true` browser-context setting for both local and IIS test environments. This does not modify system trust and does not validate certificate chain/hostname; production TLS remains separate.

## Resume

Read this handoff, ADR-0003, the issuer runbook, and #13 first. Continue the narrowly scoped local browser verifier investigation from committed revision `144a73b`; do not retry the old stale-server results or assume token exchange failed when it was never reached. Once verified, record precise evidence and obtain fresh review of any code changes before the #11 resolution report. Windows Server deployment/testing occurs under #12 after the local proofs and runbooks are complete; do not install prerequisites on this workstation.
