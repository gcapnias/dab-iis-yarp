# Issue #20: Safe application publishing

## Implementation

Both supported publishers now require an absent or empty destination, check the nearest existing parent before invoking `dotnet publish`, and leave existing or partial output untouched. The issuer publisher still rejects output inside the source checkout. The guarded entry points are `scripts/publish-identity-issuer.ps1` and `scripts/publish-embedded-dab.ps1`; both share `scripts/Publish-Application.ps1`.

Before reporting success, each publisher verifies SDK-generated `web.config`, a framework-dependent runtime configuration, and all package files. The scan includes hidden files and detects PKCS#8, encrypted PKCS#8, RSA, EC, DSA and OpenSSH private-key PEM begin markers in ASCII/UTF-8-compatible bytes and aligned UTF-16, plus `.pfx`, `.p12`, `.snk` and `.key` extensions without regard to case. It rejects reparse points because their contents cannot be verified consistently. Errors and offending relative paths are reported without file contents. This policy does not detect arbitrary encoded or embedded secrets and is not a general secret scanner.

README, prototype handoff, issuer runbook, clean-install guide and retained IIS evaluation instructions use the guarded entry points. Each example uses fresh staging paths and checks the external PowerShell process exit code before continuing. Protected issuer keys remain separately provisioned beside, rather than inside, publish output.

## Verification

Source base: `develop` revision `e9aa849130671710ec3cd0e208a0ccdd458b2ed5`.

Command, run from the repository root with PowerShell 7 and the existing .NET SDK 10.0.402:

```powershell
pwsh -NoProfile -File scripts/verify-publish-safety.ps1
```

Result: exit code 0. Synthetic checks confirmed:

- Both publishers rejected ordinary-file, actual Hidden-attribute, synthetic private-key, and nested-directory destinations before the publish shim ran. Each destination's names, attributes and SHA-256 values were unchanged.
- File destinations, a file in the destination parent path, issuer output inside the checkout, and package inspection errors failed closed. A simulated failed publish returned failure, emitted no success message, and gave fresh-destination retry guidance.
- All six supported PEM labels were detected without exposing the synthetic sentinel contents. UTF-16 markers and a marker split across the 8192-byte scan boundary were detected. A nibble-shifted byte pattern was rejected while a following byte-aligned marker was found.
- Lowercase and uppercase `.pfx`, `.p12`, `.snk` and `.key` fixtures were rejected without exposing their contents. Public certificate and public-key PEM fixtures passed. A package missing `web.config` failed validation.

Four actual framework-dependent Release publishes also passed package validation: issuer to absent and empty directories, and EmbeddedDab to absent and empty directories. Generated `web.config` and runtime configuration were validated; package scans completed without recognized key material.

The verification retained package outputs and synthetic fixtures at:

`C:\Users\georg\AppData\Local\Temp\dab-iis-yarp-ticket-20-aa96b1d2708b411687e658df26bf286a`

The output root is unique to this run and outside the source checkout. It contains no real keys, credentials or database/server artifacts.
