# Protected browser scratch

The DAB and issuer IIS browser verifiers serialize temporary Playwright configurations that can contain the imported browser password in plaintext. Before importing credentials or writing those configurations, `scripts/test-dab-issuer-browser.ps1` and `scripts/test-identity-issuer-iis.ps1` create a unique child under the existing repository-relative `.scratch/identity-issuer` base through `scripts/ProtectedBrowserScratch.ps1`. This protected lifecycle also applies when no credential file is supplied.

The [domain glossary](../../GLOSSARY.md) distinguishes the verification operator from the browser's Windows caller and the application's worker identity. Artifact permissions belong to the executing operator, not the identity imported for browser authentication. [ADR-0003](../adr/0003-windows-bound-identity-issuer-and-validation-gates.md#browser-verification-artifact-protection-refinement-2026-10-15) records the agreed security and evidence boundaries.

The shared helper inspects the existing path from the local volume root through the scratch base. It fails closed on unavailable ACL inspection, reparse points, untrusted owners, or untrusted effective allow grants that can change ownership/security, delete/rename/replace, or redirect a path component. It also checks a parent's delete-child rights when that parent will contain an existing or newly created protected child. The TrustedInstaller SID is resolved by Windows and is accepted only as the owner or security-control principal of the existing Windows system-volume root. Other volume roots do not receive this exception.

Each new run directory is created exclusively with its protected security descriptor already applied. It disables DACL inheritance, is owned by the executing Windows operator, and grants FullControl with child inheritance to only that operator, LocalSystem, and local Administrators. The helper verifies the directory and each child artifact's actual SID-based ACL before browser invocation. It does not change the imported credential file or repair the existing checkout's ACLs.

The helper exposes three entry points for both browser verifiers:

- `New-ProtectedBrowserScratchDirectory -BasePath <existing-base> -NamePrefix <safe-prefix>` creates and verifies a new run directory.
- `Test-ProtectedBrowserScratchArtifact -Scratch <returned-object> -Path <child-path>` rechecks the boundary and child ACL.
- `Remove-ProtectedBrowserScratchDirectory -Scratch <returned-object>` revalidates the path, Windows volume/file identity, creation time and operator SID before deleting only that directory. It returns a fixed cleanup code and retains a changed or unverified path.

Both verifiers use `scripts/ProtectedBrowserRunner.ps1` for shared Playwright configuration, credential import into configuration, and the open/run/result parsing and close lifecycle. Each caller keeps its own endpoint validation, browser-check template, configuration-file serialization, artifact verification and final result/cleanup policy; the runner module does not change the scratch helper's ACL contract.

## Cleanup and result meaning

Setup is inside the cleanup lifecycle, including template/config loading, credential import and artifact writes. A protection failure invokes no browser CLI operation, including close. Once browser open is attempted, browser close is attempted before scratch cleanup; a close failure cannot skip file cleanup.

The verifier emits one final JSON result after all catchable cleanup attempts. Primary setup/runner/browser failures are preserved. Secondary failures appear in `cleanupFailures`, in operation order, using only `browser_close_failed`, `scratch_cleanup_failed` or `scratch_cleanup_unsafe`. Without a primary failure, cleanup failure sets `failure` to `browser_cleanup_failed`. `artifactsRetained: true` appears when generated artifacts remain or safe deletion cannot be confirmed. Diagnostics omit credentials, artifact paths, exception text and runner dumps. Exit 0 requires both browser success and successful cleanup; failures exit 1.

Abrupt termination cannot emit the final result and may retain artifacts. Their restrictive ACLs remain the protection in that case. Retention following an unsafe cleanup check is intentional: do not recursively delete through an unverified or redirected path.

## Offline verification

Run from the repository with PowerShell 7. The script uses synthetic `PSCredential` data, a process-local PowerShell stub in place of `playwright-cli`, actual Windows ACL inspection, and a controlled worker termination. It creates one uniquely named fixture directly under the executing user's profile directory, verifies the full ancestor chain first, changes ACLs only within that fixture, and removes the fixture in `finally`.

```powershell
pwsh -NoProfile -File scripts/verify-dab-browser-scratch.ps1
```

The verifier covers the protected run and child ACLs, all four credential/Northwind combinations, setup and config-write failures, runner open/run/result failures, close and cleanup failures, single-JSON result/exit behavior, sensitive-output checks, broad-user and parent delete-child grants, inherit-only ACEs, reparse points, inspection failures, collisions, the TrustedInstaller system-volume-root exception, and retained ACLs after abrupt worker termination. An explicitly unsafe synthetic checkout proves boundary failure happens before credential import or browser invocation. The actual shared checkout is probed separately and reported according to its observed boundary state.

This is filesystem and process-lifecycle evidence. It does not use real browser credentials, start a browser, make network requests, contact an issuer/API, or establish cross-account access behavior. ACL results do not prevent the approved operator, SYSTEM, or administrators from accessing the files. The verifier uses a read-only existing Windows directory owned by TrustedInstaller to check that the SID exception is rejected below the volume root; it does not change that directory's ACL. On Windows installations where that owner differs, the verifier reports that no suitable existing owner case was available. The current shared E: checkout is expected to fail closed under the approved policy; do not change its ACL or relocate scratch to make the check pass.

The PowerShell 7 run on 2026-10-14 passed the actual profile-fixture run and child ACL checks, all four credential/Northwind variants, four setup failures (template, config template, credential import and config write), nine runner/cleanup cases, untrusted mutation and parent delete-child rejection, inherit-only handling, actual TrustedInstaller owner rejection below the root, reparse rejection, unavailable-path and collision checks, retained protected ACLs after abrupt termination, and the actual TrustedInstaller-owned volume-root exception. The shared E: checkout failed closed before credential import and browser invocation. A separate assertion also confirmed that a mismatched generated file identity is retained as unsafe. This result is local Windows ACL evidence; it is not live-browser or cross-account evidence.

## Issuer verifier follow-up

Issue #21 owns this helper and the DAB verifier integration. Issue #22 integrates the issuer IIS verifier separately, using the same three helper entry points while retaining its issuer/OIDC behavior.

Run the issuer-specific offline integration verification from the repository with PowerShell 7 on Windows:

```powershell
pwsh -NoProfile -File scripts/verify-issuer-browser-scratch.ps1
```

This entry point creates one unique fixture directly beneath the independently checked operator profile root, protects only that new fixture, and removes it in `finally`. It exports and imports a synthetic `PSCredential`, wraps `Import-Clixml` in the child process to prove the shared-checkout and untrusted-base cases stop before import, and shadows the Edge executable paths and `playwright-cli` with fixture-local stubs. The runner stub records the actual ACLs of the generated directory, source and config while they exist; assertions require exactly the operator, SYSTEM and Administrators allow SIDs, each with FullControl. The checks cover credential and no-credential runs, root and issuer-subpath callback URLs, default/custom cookie options, certificate validation, invalid URLs, broad-mutation and junction boundaries, owner-rejection and unavailable-inspection helper failures, helper collision and throwing-helper cases, template/config/credential/write failures, runner/result/browser-close failures, actual deletion failure, unsafe cleanup retention, and controlled worker termination. It makes no browser launch or network request and installs no prerequisite.

On 2026-10-15, the issuer-specific fixture passed on PowerShell 7 on Windows. It observed the operator as owner, a protected run-directory DACL, exactly the three approved allow SIDs with FullControl on generated artifacts, inherited file grants, no credential import before a rejected boundary, safe cleanup after catchable failures, bounded cleanup diagnostics, and protected retained files after abrupt termination. The fixture injects the helper's untrusted-owner and unavailable-inspection failures to verify issuer fail-before-import handling. Changing an existing fixture path's owner was unavailable because this workstation process lacks `SeSecurityPrivilege`; the DAB fixture separately observed and rejected the actual TrustedInstaller-owned Windows directory. The existing DAB fixture remains the source for the helper's detailed effective-rights, owner, collision, unavailable-inspection and TrustedInstaller boundary matrix; rerun it independently with `pwsh -NoProfile -File scripts/verify-dab-browser-scratch.ps1` after issuer changes.

The DAB fixture was rerun on 2026-10-15 after this issuer integration and passed its four credential/Northwind variants, setup and runner/cleanup matrices, broad-grant and parent-delete-child checks, reparse/unavailable/collision cases, actual untrusted-owner and TrustedInstaller-root checks, and retained ACL inspection after abrupt termination. After centralizing the shared Playwright lifecycle, both offline fixtures passed again: the issuer matrix and the DAB four credential/Northwind variants, nine runner/cleanup cases, ACL boundary matrix, and abrupt-termination inspection all remained green.

These checks establish local Windows ACL and process-lifecycle behavior for the executing operator. They do not establish cross-account access behavior, live browser behavior, issuer availability, or access by approved administrators and SYSTEM. Fixture ACL modifications are confined to its unique profile-root child; the existing checkout and its ancestors are never repaired or relocated.
