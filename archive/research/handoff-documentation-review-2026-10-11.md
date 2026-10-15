# Prototype handoff documentation review, 2026-10-11

## Scope and conclusion

Reviewed the recipient documentation for a `develop` to `main` PR against the accepted [ticket #18 resolution](https://github.com/gcapnias/dab-iis-yarp/issues/18#issuecomment-6043097637): delivery of the working issuer and embedded DAB prototype with instructions to understand, run and customize it. This review covers documentation and supporting verification, rather than a fresh review of every application change in the branch.

Application source baseline: `4146a9b01f0a8616fda9bed3f9ab7842a73addff`. PR comparison base: `93cccf24ddf2966fa4322b7debb2b5b1aad3264e` (`origin/main` at review time). Documentation corrections follow that source baseline.

The reviewed handoff covers architecture/source boundaries, required environment inputs, separate resource and Identity catalogs, resource/permission customization, issuer identity/claims, browser paths, build/publish commands, setup and verification. The standards and spec reviews identified the corrections below. The accepted first empty-server installation remains sufficient; later session, health and recovery extensions are optional for this handoff.

## Corrections

- Replaced the failing standalone DAB test command with the three SQL-independent checks. Documented that the current runner treats the intended dynamic SQL skip as a failure, and provided the full fixture-backed harness command.
- Distinguished the localhost browser proof from the retained IIS environment and linked the latter's three verification commands and protected input recovery procedure.
- Aligned the clean-install runbook and ADR operational-status paragraphs with #18's optional-extension scope.
- Updated agent domain guidance to the existing `GLOSSARY.md` and made the issuer source entry point independent of branch name.

Historical reports retain their original results and publication-time pending gates. Current evidence is recorded here without rewriting those reports.

Both review axes rechecked the corrections and found no remaining documentation blocker. Final checks covered 13 documents, 127 existing local link targets and 53 parseable PowerShell snippets; Git whitespace checks passed. Both publish folders contained SDK-generated `web.config` and no private PEM files.

The subsequent README landing-page review added recipient steps, destination-specific setup links, database-free build/test commands, publish instructions and a delivery checklist. All 17 README local links, including section anchors, and both PowerShell blocks validated. Its commands reuse the verified handoff commands above.

## Executed verification

All tests below were run during this review against the source baseline above. Fixture databases used generated `dab_ticket9_<12 hex>` names on `vs2026` and were removed by their harnesses. Northwind checks were read-only.

| Check | Command or procedure | Result |
| --- | --- | --- |
| SQL login/read | Existing private connection; read database/version and `COUNT_BIG(*) FROM dbo.Products` | Northwind reachable; 77 Products; SQL `17.0.5005.3` |
| Issuer regression baseline | `dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj -c Release --no-build --no-restore` | 34 passed, zero failed/skipped |
| SQL-independent DAB baseline | `dotnet test tests/EmbeddedDab.Tests/EmbeddedDab.Tests.csproj -c Release --no-restore --filter 'FullyQualifiedName!~JwtDabIntegrationTests'` | 3 passed, zero failed/skipped |
| Configuration-driven REST/GraphQL | `pwsh -NoProfile -File scripts/test-embedded-dab.ps1` | 62 checks passed; fixture removed |
| JWT/roles/cookie antiforgery and application-prefix handling | `pwsh -NoProfile -File scripts/test-embedded-dab-jwt.ps1` | 13 passed, zero failed/skipped; fixture removed |
| IIS Windows/session/OIDC browser flow | `scripts/test-identity-issuer-iis.ps1` with retained-server runbook parameters | Every reported check passed; token endpoint HTTP 200; exit 0 |
| IIS Northwind REST/GraphQL browser flow | `scripts/test-dab-issuer-browser.ps1 -Northwind` with retained-server parameters | 12 checks passed; exit 0 |
| IIS valid/invalid token matrix | `scripts/test-dab-iis-token-validation.ps1` with retained-server parameters and existing matching test key | 24 checks passed; exit 0 |
| Framework-dependent package builds | The handoff's two `dotnet publish` commands, with `--no-restore` using existing restored dependencies | Both succeeded; issuer/API staged separately under `.scratch/delivery` |

The retained server was `ws2025s01.mshome.net`, with issuer `https://ws2025s01.mshome.net/` and API `https://ws2025s01.mshome.net/dab`, reporting .NET `10.0.12`. Tests used its existing non-administrator caller and Identity state. The matching signing key was already retained; no key recovery or rotation occurred. See the [retained-server procedure](../../docs/runbooks/windows-server-iis-evaluation.md#recover-verification-inputs-for-the-retained-server) for exact parameters and how recipients obtain their own inputs. Ignored workstation files are not part of the handoff.

## Evidence limits

The workstation did not trust the server certificate: a normally validated HTTPS request failed with `UntrustedRoot`. The IIS test clients used the documented certificate bypass. These reruns establish application behavior, not normal workstation certificate-chain validation; workstation trust was not changed. They do not independently re-prove the deployed DAB backchannel trust configuration.

The separate localhost live launcher failed during issuer session creation with SQL error 53 and a Named Pipes network-path failure. That result is distinct from the passing retained IIS suites. A recipient choosing local setup must supply a reachable explicit Identity connection through the local runbook; the localhost proof was not re-established here.

An unfiltered standalone DAB test invocation without fixture inputs produced 10 failures and 3 passes before SQL-backed application checks ran. The fixture-backed suite passed all 13. This is a test skip/reporting limitation documented by the corrected handoff, not a fixed test-runner implementation.

No application code, deployed configuration, account provisioning, database migrations, IIS pool lifecycle or production acceptance behavior was changed by this review. No fresh empty-server installation was performed. The publish checks produced temporary staging output; source, guides and protected environment setup remain the recipient delivery contract.

Raw runtime logs and private verification inputs remain in ignored scratch space. The review records only outcomes and non-secret environment metadata.
