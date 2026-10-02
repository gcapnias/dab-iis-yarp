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
## Follow-up review and persisted revision

The completed follow-up is commit `144a73b509bfeff12b1842d60ea1bd04da35250d`, now integrated onto local develop. The implementer reported a clean Release build and 32 passing tests; no subsequent browser rerun was performed when filing this handoff.

Read-only review identified a deterministic flow mismatch to investigate alongside navigation: the verifier navigates to the separately registered client callback, then uses page JavaScript `fetch` to post to the issuer token endpoint. With distinct origins and the documented issuer CORS policy, that request is expected to be blocked unless the flow is redesigned; this does not prove that such a POST occurred in the earlier failing runs. The investigator must choose and test a real browser/public-client origin contract rather than silently substitute an API-only client or enable broad credentialed CORS.

The IIS verifier also always requests the Development-only `/diagnostics/windows-auth` route, whereas its runbook calls Development optional. Make that test prerequisite explicit or make that diagnostic check optional. A minor unused result-file variable can be removed with the verifier fix. These are verifier reliability issues, not verified OIDC issuer defects.

These follow-up findings are included in #13. Actual IIS execution remains #12.

## Ticket #13 implementation and current validation, 2026-10-02

The verifier previously observed a redirect request for the separately registered callback, then continued as if the callback page were usable. The registered callback had no established listener; Chromium can replace an unreachable target with its network error page, so observing its request does not establish successful navigation. The next `page.evaluate(fetch(token_endpoint))` would also run after leaving the issuer origin. The issuer deliberately grants no token-endpoint CORS access to that separate origin. The original failing run never reached this fetch, so the CORS mismatch is a separate code-path finding, not a retroactive explanation of its runtime error. [Playwright's page-navigation API](https://playwright.dev/docs/api/class-page#page-goto) and [its unreachable-page discussion](https://github.com/microsoft/playwright-java/issues/1035) support the navigation distinction.

Commit `48d6f07e0234ff92cbe69cb3d18d5ce271e51199` adds a Development-only, anonymous, no-store `/oidc-browser-test/callback` page at the issuer origin. A dedicated public PKCE test client registers that exact URI. The browser verifier requires that contract before launching Edge, navigates to the real callback response, checks its origin/path and returned state, then performs token and JWKS fetches in that browser page's JavaScript origin. It does not grant CORS or redeem a browser code in PowerShell. The original cookie/session checks remain in place. The test checks the RS256 JWT header and persisted profile/role access claims. The runner emits only a sanitized JSON result and nonzero exit for setup, CLI, missing-result, and failed-check paths, and closes only its own isolated CLI session. The Development prerequisite for both diagnostic and callback routes is explicit in the runbook.

Exact local tools: .NET SDK 10.0.401, PowerShell 7.6.6, Microsoft Edge 154.0.4258.48, playwright-cli 0.1.22. The issuer pins ASP.NET Core/EF Core 10.0.12 and OpenIddict 7.7.1. The test uses `ignoreHTTPSErrors: true`, which bypasses browser certificate chain and hostname validation. The original separate-callback client was preserved; the dedicated `dab-issuer-browser-test-client` was registered in the authorized disposable Northwind `IdentityIssuer` schema with `https://localhost:5001/oidc-browser-test/callback`. No private key, code, token, cookie, account identity or connection string was copied into this report.

An initial fresh Kestrel baseline at revision `144a73b` failed before OIDC: both the browser and separate PowerShell harness received HTTP 500 at authenticated `POST /session`. The revised runner returned `windows_session_created: false`, `failure: windows_session_created`, and process exit 1, with no sensitive payload. A temporary SQL unavailability coincided with this result. An intermediate diagnostic used a generic connection-string parser that did not normalize the `Server` synonym; its empty `Data Source` answer was incorrect and must not be used as evidence of a different configured host. A fresh .NET SqlClient probe later confirmed that the current ignored `.env` targets the user-identified `vs2026` host, opens the authorized Northwind catalog, reads Identity rows, and finds the original PKCE client. No database connection setting or service was changed here.

After provisioning the dedicated browser client, the owned Kestrel process was restarted from the ticket worktree and the actual Development callback returned HTTP 200. Run `pwsh ./scripts/run-identity-issuer.ps1 -ProvisionBrowserClient -Url https://localhost:5001` for first-time client registration, start the issuer with `pwsh ./scripts/run-identity-issuer.ps1 -Url https://localhost:5001`, then run `pwsh ./scripts/test-identity-issuer-iis.ps1 -Issuer https://localhost:5001 -ClientId dab-issuer-browser-test-client -RedirectUri https://localhost:5001/oidc-browser-test/callback -AccessAudience api://northwind-dab`. The fresh isolated Edge run exited 0 and reported all cookie/session checks true, callback load/origin/state/code checks true, same-origin token fetch true, code/PKCE token HTTP 200, signed ID token issuer/audience/nonce true, signed access token issuer/audience/profile/role true, refresh rotation true, and old-token plus rotated-descendant replay rejection true. It returned only named booleans and token HTTP status. The focused HTTP callback test passed, Release build had zero warnings/errors, and the full suite passed 33/33. This local result does not establish IIS behavior; #12 owns the server evaluation.
