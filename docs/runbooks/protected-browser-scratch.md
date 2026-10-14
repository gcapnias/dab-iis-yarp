# Protected browser scratch

The DAB browser verifier serializes a temporary Playwright configuration that can contain the imported browser password in plaintext. Before importing credentials or writing that configuration, `scripts/test-dab-issuer-browser.ps1` creates a unique child under the existing repository-relative `.scratch/identity-issuer` base through `scripts/ProtectedBrowserScratch.ps1`.

The shared helper inspects the existing path from the local volume root through the scratch base. It fails closed on unavailable ACL inspection, reparse points, untrusted owners, or untrusted effective allow grants that can change ownership/security, delete/rename/replace, or redirect a path component. It also checks a parent's delete-child rights when that parent will contain an existing or newly created protected child. The TrustedInstaller SID is resolved by Windows and is accepted only as the owner or security-control principal of the existing Windows system-volume root. Other volume roots do not receive this exception.

Each new run directory is created exclusively with its protected security descriptor already applied. It disables DACL inheritance, is owned by the executing Windows operator, and grants FullControl with child inheritance to only that operator, LocalSystem, and local Administrators. The helper verifies the directory and each child artifact's actual SID-based ACL before browser invocation. It does not change the imported credential file or repair the existing checkout's ACLs.

The helper exposes three entry points for both browser verifiers:

- `New-ProtectedBrowserScratchDirectory -BasePath <existing-base> -NamePrefix <safe-prefix>` creates and verifies a new run directory.
- `Test-ProtectedBrowserScratchArtifact -Scratch <returned-object> -Path <child-path>` rechecks the boundary and child ACL.
- `Remove-ProtectedBrowserScratchDirectory -Scratch <returned-object>` revalidates the path, Windows volume/file identity, creation time and operator SID before deleting only that directory. It returns a fixed cleanup code and retains a changed or unverified path.

## Offline verification

Run from the repository with PowerShell 7. The script uses synthetic `PSCredential` data, a process-local PowerShell stub in place of `playwright-cli`, actual Windows ACL inspection, and a controlled worker termination. It creates one uniquely named fixture directly under the executing user's profile directory, verifies the full ancestor chain first, changes ACLs only within that fixture, and removes the fixture in `finally`.

```powershell
pwsh -NoProfile -File scripts/verify-dab-browser-scratch.ps1
```

The verifier covers the protected run and child ACLs, all four credential/Northwind combinations, setup and config-write failures, runner open/run/result failures, close and cleanup failures, single-JSON result/exit behavior, sensitive-output checks, broad-user and parent delete-child grants, inherit-only ACEs, reparse points, inspection failures, collisions, the TrustedInstaller system-volume-root exception, and retained ACLs after abrupt worker termination. An explicitly unsafe synthetic checkout proves boundary failure happens before credential import or browser invocation. The actual shared checkout is probed separately and reported according to its observed boundary state.

This is filesystem and process-lifecycle evidence. It does not use real browser credentials, start a browser, make network requests, contact an issuer/API, or establish cross-account access behavior. ACL results do not prevent the approved operator, SYSTEM, or administrators from accessing the files. The verifier uses a read-only existing Windows directory owned by TrustedInstaller to check that the SID exception is rejected below the volume root; it does not change that directory's ACL. On Windows installations where that owner differs, the verifier reports that no suitable existing owner case was available. The current shared E: checkout is expected to fail closed under the approved policy; do not change its ACL or relocate scratch to make the check pass.

The PowerShell 7 run on 2026-10-14 passed the actual profile-fixture run and child ACL checks, all four credential/Northwind variants, four setup failures (template, config template, credential import and config write), nine runner/cleanup cases, untrusted mutation and parent delete-child rejection, inherit-only handling, actual TrustedInstaller owner rejection below the root, reparse rejection, unavailable-path and collision checks, retained protected ACLs after abrupt termination, and the actual TrustedInstaller-owned volume-root exception. The shared E: checkout failed closed before credential import and browser invocation. A separate assertion also confirmed that a mismatched generated file identity is retained as unsafe. This result is local Windows ACL evidence; it is not live-browser or cross-account evidence.

## Issuer verifier follow-up

Issue #21 owns this helper and the DAB verifier integration. Issue #22 is the separate issuer-verifier integration and depends on #21. The issuer verifier can reuse the same three entry points, but it retains its own credential setup, issuer/OIDC behavior, cleanup handling and acceptance tests. #21's offline DAB results do not establish #22's issuer behavior.
