# Browser OIDC callback/navigation investigation

Date: 2026-10-02. Investigation: [GitHub #13](https://github.com/gcapnias/dab-iis-yarp/issues/13), child of issuer ticket #11. Windows Server/IIS environment evaluation is separately tracked by #12.

## Finding and scope

The local Edge/Playwright browser proof completes 16 cookie/session checks and obtains an OIDC authorization code, then fails during callback-to-issuer navigation before token exchange. No browser token POST was reached in the reported failing runs. This does not establish a server token-exchange failure or a Windows Authentication caching defect. The cause remains unconfirmed.

This report records the implementer's sanitized handoff; the report author did not independently rerun the browser or query the database. The observation occurred during the follow-up to commit 628605ffea80ff558f3718ecd82ad2591688cb57. That follow-up is now committed as 144a73b509bfeff12b1842d60ea1bd04da35250d (Refactor issuer session and browser verification seams), with the root cookie-path fix, browser scripts and documented limitation. Reproduce from that pinned follow-up revision; the final inconclusive route-abort experiment is not proof of a passing committed harness.

## Verified observations reported by the implementer

- Fresh local Kestrel HTTPS server and isolated headless Edge browser. This was not an IIS run.
- Three fresh-server runs completed 16 browser assertions: public discovery, authenticated Windows identity/SID-presence booleans, CSRF, session issuance, HttpOnly invisibility, cookie security attributes/scope, explicit future expiries, two sequential refresh rotations, stale-refresh rejection, and logout.
- The OIDC authorization navigation returned an authorization code to the registered callback.
- The return navigation failed with sanitized stage `oidc_return_to_issuer_navigation_runtime_error`. Token exchange was not reached.
- A final callback interception/route.abort experiment attempted to preserve the issuer origin. The runner returned only `SERVER_READY` without its expected JSON result. This is inconclusive, not a passing proof.
- The separate PowerShell live OIDC code/PKCE, signed-token validation, refresh and replay tests passed. The latest reported automated suite passed 32 tests. Those establish separate protocol evidence; they do not replace the missing browser-flow proof.

The previously discovered refresh-cookie path defect is a separate resolved issue: omitting the root Path let different endpoint URLs create same-name cookies at different paths. Explicit `/` and fresh-browser sequential rotations now pass. Do not conflate that fix with this remaining navigation/reporting issue.

## Reproduction inputs and commands

The following paths are in the #11 implementation worktree until delivered to develop:

- `scripts/run-identity-issuer.ps1`
- `scripts/test-identity-issuer-iis.ps1`
- `scripts/identity-issuer-browser-check.js`
- `requests/playwright-cli.iis-test.config.json`
- `archive/research/identity-issuer/browser-proof-2026-10-02.md`

Use a fresh build and server to avoid earlier stale-server results. The current machine needs its existing .NET runtime, Edge and playwright-cli, retained ignored test keys, authorized SQL configuration and provisioned Windows-user mapping. The registered client and callback must match the test parameters. No prerequisite installation is authorized on this workstation.

```powershell
./scripts/run-identity-issuer.ps1 -RepositoryRoot <implementation-checkout> -Url https://localhost:5001
```

From another shell in the same implementation checkout:

```powershell
./scripts/test-identity-issuer-iis.ps1 -Issuer https://localhost:5001 -ClientId dab-issuer-test-client -RedirectUri https://localhost:5443/callback -AccessAudience api://northwind-dab
```

The verifier uses isolated headless Chromium with the existing Edge channel and process-only `--auth-server-allowlist=localhost`. Browser/CLI exact versions were not recorded in the handoff and must be captured in the investigation. The existence and behavior of a real callback listener at port 5443 were not established by that handoff.

Approved test context:

```json
{
  "browser": {
    "contextOptions": {
      "ignoreHTTPSErrors": true
    }
  }
}
```

This allows local/self-signed test certificates without modifying system trust. It does not verify server certificate trust or hostname validity. Production certificate handling is separate.

## Evidence locations and privacy

The implementer identifies ignored diagnostics under `.scratch/identity-issuer/local-browser/server*.out` and `.err`. Their existence/content has not been independently reviewed for this report. Inspect only sanitized diagnostics and never publish callback URLs with authorization codes, request authorization headers, token/cookie values, account names/SIDs/profile values, private keys, or connection strings.

The harness should return only named checks, status codes, presence/match booleans and public metadata. Persistent private test keys stay gitignored. Do not save browser storage state or traces containing credentials into tracked artifacts.

## Focused hypotheses to test

1. Callback listener/navigation: establish whether the registered callback exists and how unavailable callbacks or cross-origin page transitions affect Playwright's page/execution context.
2. Browser flow design: confirm authorization response capture, state/nonce/PKCE and the intended public-client token POST context. A same-origin fetch assumption after navigation must be verified rather than bypassed.
3. Runner lifecycle: determine why the abort experiment produced no final JSON record, and ensure every failure is reported safely with a nonzero exit.

These are hypotheses, not established causes. Browser cached Windows credentials do not by themselves explain this callback-navigation failure. Do not use browser restarts, skipped assertions or an API-only token call to claim the required browser proof.

## Completion criteria

Pin a committed revision and exact tool versions. Demonstrate a fresh-browser code/PKCE exchange, signed ID/access token validation with issuer/audience/nonce/claim assertions, refresh rotation, rejection of old-token replay and rotated descendants. Preserve the passing cookie/session assertions. Ensure sanitized result emission and correct process exit on every failure, cleanup only this test's sessions, and update report/runbook with the verified cause/fix and actual limitations.

Real Windows Server/IIS execution remains #12; this investigation can run locally.