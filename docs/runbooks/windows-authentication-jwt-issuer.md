# Run the Windows Authentication OIDC/JWT issuer

This standalone ASP.NET Core 10 app authenticates a Windows request, maps the request principal's SID to an operator-provisioned ASP.NET Core Identity account, loads persisted profile claims and roles, and acts as a real OpenID Connect Provider. It also has a first-party session-cookie bridge for the separate DAB embedding work. The issuer does not host DAB. The real DAB REST/GraphQL bridge proof passed under ticket #10; the subsequent Windows Server/IIS and Northwind evaluation passed under ticket #12. This runbook owns local issuer/protocol setup. For full server replication use the [Windows Server 2025 clean-install guide](windows-server-2025-clean-install.md).

Primary-source research: [.NET 10 Identity and SQL Server](../../archive/research/aspnet-identity-net10-issuer.md), [Windows request-principal SID binding](../../archive/research/identity-issuer/windows-principal-identity-binding.md), [OpenIddict discovery and OIDC client behavior](../../archive/research/identity-issuer/discovery-implementation-details.md), and the [user-supplied Windows Authentication artifact](../../archive/research/windows-authentication-in-net-identity.md). The complete current schema script is [here](../../archive/research/identity-issuer/IdentityIssuer-current-idempotent.sql); live Kestrel/SQL evidence is [here](../../archive/research/identity-issuer/live-proof-2026-10-02.md).

## Project creation and reproducible build

The delivered prototype is [src/IdentityIssuer](../../src/IdentityIssuer/IdentityIssuer.csproj) on `develop`. With the existing .NET 10 SDK, restore and build that source:

```powershell
dotnet restore src/IdentityIssuer/IdentityIssuer.csproj
dotnet build src/IdentityIssuer/IdentityIssuer.csproj --configuration Release --no-restore
```

To create a separate starting shell, use `dotnet new web --framework net10.0 --name IdentityIssuer --output <new-directory>`. The template alone is not the issuer: use the delivered project file's exact package pins and bring across its application source, configuration and reviewed migrations. The project pins Negotiate, ASP.NET Core Identity EF stores and EF Core SQL Server/Design to `10.0.12`, and OpenIddict ASP.NET Core/EF Core to `7.7.1`. The delivered tests under `tests/IdentityIssuer.Tests` provide the regression baseline. Restore/build do not provision database accounts, apply migrations or create signing keys; complete the configuration and explicit operator steps below before starting the application.

## Local configuration and startup

Use Windows, **PowerShell 7** and the .NET 10 SDK (evaluated SDK 10.0.401). Windows PowerShell 5.1 cannot generate these PEM keys. Run setup, migrations, provisioning and startup in the same dedicated PowerShell 7 console at the repository root. A reachable, explicitly authorized **isolated Identity database must already exist**; the SQL login needs schema/migration rights for setup and DML rights on `IdentityIssuer` for runtime. The [server guide's database procedure](windows-server-2025-clean-install.md#7-create-the-identity-database-and-confirm-northwind) shows database creation separately. Do not target Northwind for a new Identity installation.

The tracked [appsettings.json](../../src/IdentityIssuer/appsettings.json) contains safe defaults and no secrets. Runtime can read user secrets, but the EF design-time factory reads **only** `ConnectionStrings__IssuerIdentity`; provisioning commands do not load `.env`. Supply one explicit process connection to every operation:

```powershell
# Workstation, PowerShell 7, repository root
$ErrorActionPreference = 'Stop'
$ExpectedIdentityDb = Read-Host 'Existing isolated Identity database name (not Northwind)'
if ([string]::IsNullOrWhiteSpace($ExpectedIdentityDb) -or $ExpectedIdentityDb -ieq 'Northwind') { throw 'Choose an isolated Identity catalog.' }
$secret = Read-Host 'Full Identity SQL connection string; include catalog and Encrypt=True' -AsSecureString
$connection = [pscredential]::new('unused',$secret).GetNetworkCredential().Password
$parsed = [System.Data.Common.DbConnectionStringBuilder]::new()
$parsed.set_ConnectionString($connection)
$catalog = if ($parsed.ContainsKey('Initial Catalog')) { [string]$parsed['Initial Catalog'] } else { [string]$parsed['Database'] }
if ($catalog -ine $ExpectedIdentityDb) { throw 'Connection catalog differs from the approved Identity database.' }
if (-not $parsed.ContainsKey('Encrypt') -or [string]$parsed['Encrypt'] -notmatch '^(true|yes|mandatory|strict)$') { throw 'SQL encryption must be explicit.' }
$env:ConnectionStrings__IssuerIdentity = $connection
Write-Host "Identity configuration catalog: $catalog" # No credentials or SID
$env:Issuer__Url = 'https://localhost:5001'
$env:Issuer__Audience = 'api://northwind-dab'
$env:WindowsAuthentication__Mode = 'Negotiate'
$env:Oidc__ClientId = 'dab-issuer-test-client'
$env:Oidc__RedirectUri = 'https://localhost:5443/callback'
$env:DOTNET_ENVIRONMENT = 'Development'
$env:ASPNETCORE_ENVIRONMENT = 'Development'
```

This is a configuration-destination check; EF's migration-history query below verifies connectivity against that catalog. Keep encryption enabled. Use trusted SQL certificates, or the explicitly authorized development `TrustServerCertificate=True` policy. Do not enable transcription or print connection/environment objects.

Prepare localhost HTTPS explicitly without changing workstation trust:

```powershell
dotnet dev-certs https --check
if ($LASTEXITCODE -ne 0) {
    dotnet dev-certs https
    if ($LASTEXITCODE -ne 0) { throw 'Developer certificate creation failed.' }
}
dotnet dev-certs https --check
if ($LASTEXITCODE -ne 0) { throw 'No valid localhost developer certificate.' }
```

Creation is an operator step and does not use `--trust`. The HTTP harness bypasses validation only for HTTPS localhost; browser bypass is separate. If normal local browser trust is desired, `dotnet dev-certs https --trust` is a separate operator-approved workstation trust change. A localhost certificate is insufficient for a remote server hostname.

Create protected, gitignored keys and retain them across restarts:

```powershell
$commonGit = (git rev-parse --path-format=absolute --git-common-dir).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot locate primary checkout.' }
$primaryRoot = Split-Path -Parent $commonGit
$keyDirectory = Join-Path $primaryRoot '.scratch/identity-issuer/keys'
foreach ($file in 'issuer-private.pem','issuer-encryption.pem') {
    git -C $primaryRoot check-ignore --quiet ".scratch/identity-issuer/keys/$file"
    if ($LASTEXITCODE -ne 0) { throw 'Private-key path is not gitignored.' }
}
New-Item -ItemType Directory $keyDirectory -Force | Out-Null
$operatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls $keyDirectory /inheritance:r /grant:r "*${operatorSid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
if ($LASTEXITCODE -ne 0) { throw 'Private key ACL failed.' }
foreach ($file in 'issuer-private.pem','issuer-encryption.pem') {
    $path = Join-Path $keyDirectory $file
    if (-not (Test-Path $path)) {
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        try { [IO.File]::WriteAllText($path,$rsa.ExportPkcs8PrivateKeyPem()) }
        finally { $rsa.Dispose() }
    }
}
$env:Issuer__SigningKeyPath = Join-Path $keyDirectory 'issuer-private.pem'
$env:Issuer__EncryptionKeyPath = Join-Path $keyDirectory 'issuer-encryption.pem'
```

After database and operator provisioning below, start **directly** in this same console:

```powershell
dotnet run --project src/IdentityIssuer/IdentityIssuer.csproj --no-launch-profile --urls https://localhost:5001
```

This avoids `.env` precedence. The optional `pwsh -NoProfile -File scripts/run-identity-issuer.ps1` convenience launcher resolves the primary checkout and reads **only** `.env`'s `ConnectionString` entry; that entry **overrides** `ConnectionStrings__IssuerIdentity`. It restores its environment changes on exit. Do not use it if that catalog differs from the migration/provisioning connection. DAB's arbitrary dotenv variable-name behavior does not apply to this launcher.

The project targets `net10.0`, with the pins above; DAB Core is a separate `2.0.12` baseline. The early local proof applied Identity schema to an authorized disposable Northwind catalog; that is historical evidence, not the destination recommended here.

## Database and operator provisioning

`ApplicationDbContext` maps standard Identity and OpenIddict persistence plus `RefreshTokens` into the dedicated `IdentityIssuer` schema. The user table has unique Windows SID and profile ID indexes, an explicit `IsEnabled` switch, and normal Identity lockout/security-stamp fields. Migrations are never applied at startup.

Restore the pinned tool once, inspect the target, generate and review an idempotent script, then apply only to an explicitly authorized development database:

```powershell
dotnet tool restore
if ($LASTEXITCODE -ne 0) { throw 'EF tool restore failed.' }
dotnet ef migrations list --project src/IdentityIssuer/IdentityIssuer.csproj
if ($LASTEXITCODE -ne 0) { throw 'Identity catalog/migration-history query failed.' }
New-Item -ItemType Directory .scratch -Force | Out-Null
dotnet ef migrations script --idempotent --project src/IdentityIssuer/IdentityIssuer.csproj --output .scratch/identity-issuer-migration.sql
if ($LASTEXITCODE -ne 0) { throw 'Migration script generation failed.' }
# Inspect .scratch/identity-issuer-migration.sql before executing the update.
dotnet ef database update --project src/IdentityIssuer/IdentityIssuer.csproj
if ($LASTEXITCODE -ne 0) { throw 'Identity schema update failed.' }
```

All five migrations are applied to the selected isolated Identity database using the connection above. The checked-in script creates objects only in `IdentityIssuer`; it has no `DROP` or sample-data DML. It includes Identity, OpenIddict persistence, refresh tokens, replay markers with expiry and schema-local migration history. Verify the destination and review SQL before applying it.

Provision identities only through a trusted local operator command:

```powershell
# Exact local HTTP fixture, mapped to the current interactive Windows caller.
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
@($currentSid,'local-proof-profile','Local proof caller','writer,reader','Level3') | dotnet run --project src/IdentityIssuer/IdentityIssuer.csproj --no-launch-profile -- --provision-identity
if ($LASTEXITCODE -ne 0) { throw 'Identity provisioning failed.' }
```

The five input lines are SID, opaque profile ID, optional display name, granted roles and optional `ClearanceLevel`; the example passes SID from memory. Run once for a new mapping; inspect existing profiles instead of blindly reprovisioning. Clearance is optional in the application, but the local HTTP harness requires **`Level3`**, a nonempty profile and roles. Its other fixed inputs are issuer `https://localhost:5001`, audience `api://northwind-dab`, native client `dab-issuer-test-client` and redirect `https://localhost:5443/callback`. These differ from the server guide's `test` clearance and IIS client/audience.

Provisioning uses `UserManager`/`RoleManager` in a transaction and creates no password/web registration route. A client cannot select identity/roles. Only a single nonempty `ClearanceLevel` from persisted user/role claims is copied; conflicts fail closed. Email/security stamps are not authorization claims. Never put SID or real profile values in command history, logs, fixtures or evidence.

Register the configured native OIDC client after applying migrations:

```powershell
dotnet run --project src/IdentityIssuer/IdentityIssuer.csproj --no-launch-profile -- --provision-oidc-client
if ($LASTEXITCODE -ne 0) { throw 'Native OIDC client provisioning failed.' }
```

This is an idempotent, local operator command for the exact configured HTTPS redirect URI. The client is public, uses authorization code with PKCE, and has only the configured issuer scopes.

## OIDC and session contracts

OpenIddict serves a genuine OpenID Connect Discovery document at `/.well-known/openid-configuration` and the corresponding public RSA JWKS at `/.well-known/jwks`. Discovery describes the implemented authorization and token endpoints, authorization-code and refresh grants, scopes, response types, signing algorithm, and PKCE methods. Anonymous GET access to discovery/JWKS is required so server-side relying parties can bootstrap signing-key retrieval without a browser credential. The authorization endpoint authenticates the current Windows request before resolving its SID. The registered native client redeems the code with its PKCE verifier at the token endpoint. The token endpoint accepts protocol grants only; invalid code, verifier, client, refresh token, or replay is rejected. Refresh-token use markers are persisted by token and authorization family; replay revokes the family and causes remaining descendants to fail.

OIDC ID tokens identify the Identity user as `sub`; access tokens carry `profile_id`, persisted `roles`, and the allowlisted `ClearanceLevel` claim. Tokens are signed with RS256 and are not access-token encrypted, so resource servers can validate them from the public JWKS. Identity lockout, `IsEnabled`, and security-stamp changes are checked before new Windows sessions and before OIDC refresh grants. Already-issued access JWTs are stateless and remain usable by a downstream validator until their short expiry; logout cannot revoke a JWT already copied by another service. Keep the access lifetime short and enforce revocation/session policy in the consuming application where needed.

For cookie-based first-party embedding, the protected endpoints are:

| Endpoint | Purpose | Access |
| --- | --- | --- |
| `GET /csrf` | Issue the antiforgery cookie and request token | Windows Authentication |
| `POST /session` | Resolve current SID and set the short-lived `dab_access_token` cookie plus a separate refresh cookie | Windows Authentication + antiforgery |
| `POST /session/refresh` | Rotate the persisted cookie refresh-token family and renew the access cookie | Windows Authentication + antiforgery |
| `POST /session/logout` | Revoke the refresh-token family and expire both cookies | Windows Authentication + antiforgery |

The access cookie is `HttpOnly`, `Secure`, `SameSite=Lax`, host-only by default, and has an explicit `Expires` matching its JWT expiry. The refresh cookie is a distinct opaque random secret, `HttpOnly`, `Secure`, `SameSite=Strict`, and scoped to the issuer path; its explicit `Expires` matches the persisted refresh record's absolute `ExpiresAt`. Rotation keeps the same family lifetime rather than extending it indefinitely. Only a SHA-256 hash of a refresh token is stored. Rotation marks each token consumed; replay revokes the whole family. OIDC refresh tokens use the configured absolute lifetime. OIDC replay markers remain until the consumed token's original expiration; after it expires, OpenIddict rejects replay without the marker. For an orphan marker whose token entry was already pruned, the migration uses a conservative 30-day expiry from consumption, matching the configured maximum refresh-token lifetime. Disabled, locked, mismatched, expired, or security-stamp-changed accounts cannot refresh. Daily cleanup removes expired custom refresh rows and OIDC replay markers, and prunes old invalid OpenIddict tokens/authorizations after 30 days. Session-cookie logout clears cookies and revokes refresh, while access JWTs already issued remain valid until expiry.

The browser bridge currently has a same-origin request contract: a browser client calls `/csrf`, `/session`, `/session/refresh`, and `/session/logout` on the issuer origin with credentials included. The app does not enable CORS. `CookieDomain` is unset by default, making the access cookie host-only; the refresh cookie stays path-scoped to the issuer. Setting a shared cookie domain does not grant cross-origin JavaScript access, and `SameSite=Lax`/`Strict` still govern browser sending rules. Additional origin topologies need a separately validated origin/cookie contract; the specific localhost and IIS contracts below have passed.

The implemented DAB bridge receives the HttpOnly cookie server-side and adapts its access JWT to a bearer credential for embedded DAB. The app validates identity-bound antiforgery on state-changing cookie requests after DAB authenticates. Browser JavaScript does not read the JWT. A requested role is accepted only if present in the validated JWT; configured DAB permissions still apply. The local proof below validates actual browser cookie delivery, host behavior, forwarding, and REST/GraphQL permissions.

## Embedded DAB interoperability status

The embedded application now implements the access-cookie-to-bearer bridge and uses DAB's actual Custom-provider JWT validation. See the [host security setup](dab-core-web-application.md#issuer-jwt-and-browser-cookie-integration) and [synthetic verification](../../archive/research/dab-jwt-interoperability/IMPLEMENTATION-AND-SYNTHETIC-PROOF.md). On cookie requests, API antiforgery token creation and validation occur after DAB has authenticated the same caller. The API origin's `/bridge/csrf` token is separate from the issuer's `/csrf` token.

For a local browser proof, `https://localhost:5001` issues a host-only cookie that the browser can also send to `https://localhost:5002`; cookies have no port scope. Navigate to the API origin before making API fetch requests so its exact same-origin check is satisfied. This proves a specific localhost topology, not arbitrary cross-origin requests or production cookie domains.

Before using the owned-host live launcher, complete the [DAB fixture and connection prerequisites](dab-core-web-application.md#issuer-jwt-and-browser-cookie-integration). It requires the primary ignored `.env` with a Northwind fixture connection and inherits the isolated Identity environment; a conflicting `.env` `ConnectionString` would override that Identity connection. Stop the foreground issuer started above and leave ports 5001/5002 free: this launcher starts both hosts itself. Keep the existing Identity environment for this run, and defer the environment cleanup below until afterward.

Run `pwsh -NoProfile -File scripts/test-dab-issuer-live.ps1` for browser/cleanup acceptance of an already provisioned local issuer, or `./scripts/test-dab-issuer-browser.ps1 -Issuer https://localhost:5001 -Api https://localhost:5002` with both applications already running and the API pointing at disposable fixture data. The [live evidence](../../archive/research/dab-jwt-interoperability/LIVE-PROOF.md) records successful Windows/database session issuance, configured REST/GraphQL access, cookie mutations and antiforgery, permission/role denial, and browser logout followed by denied API access. The user approved the existing local developer certificate: the harness pins its exact public certificate for DAB's Development-only localhost metadata/JWKS backchannel without changing Windows trust. Browser certificate bypass remains a separate test-client setting. The subsequent IIS evaluation passed as recorded below; production TLS remains a separate acceptance requirement.

## Key rollover

The active private key is at `Issuer:SigningKeyPath`; its configured `KeyId` is included in signed tokens. To rotate, generate a new active key and configure the outgoing active private key temporarily under `Issuer:PreviousSigningKeys` with its original key ID and restricted `PrivateKeyPath`. The issuer publishes the active and overlap public keys together while signing with the new active key. Verify that a token from each key validates through JWKS. Keep the previous private key accessible only for the overlap deployment, then remove it after the maximum access-token lifetime and relying-party cache window have elapsed. The sample automated suite proves overlapping JWKS keys and validation of a prior-key token. Never commit private key material; local development keys remain in ignored `.scratch`.

## Run verification

Run automated tests and the real local HTTP integration harness:

```powershell
dotnet test tests/IdentityIssuer.Tests/IdentityIssuer.Tests.csproj
pwsh -NoProfile -File scripts/test-identity-issuer.ps1
```

The harness uses PowerShell 7 `UseDefaultCredentials` for Windows Negotiate and skips certificate validation only for `https://localhost` (the development certificate chain and subject are not validated by that client). It prints HTTP statuses, identity runtime type, and SID-presence booleans. It never prints a SID, account/profile value, code, cookie, JWT, refresh token, or connection string. It checks anonymous discovery/JWKS, anonymous denial, antiforgery, secure cookie flags, JWT signature/issuer/audience/lifetime/claims, refresh rotation/replay/logout, and a full Windows-authenticated authorization-code/PKCE/token/refresh flow.

The accompanying [HTTP request file](../../requests/windows-jwt-issuer.http) is suitable for anonymous metadata and negative unauthenticated requests. VS Code REST Client does not supply default Windows credentials; use the PowerShell harness for successful Windows-authenticated requests. The development-only `/diagnostics/windows-auth` endpoint reports the request identity type and whether SID claims/request token SID exist, never their values.

The tests also reject wrong issuers, audiences, expiry, unknown key IDs, tampered signatures, unmapped SIDs, disabled/locked accounts, roleless users, and conflicting claims. Fixture tests use isolated in-memory data and are separate from the live SQL/Windows proof.

Run the HTTP harness from a **second PowerShell 7 console** while the foreground issuer is running. Complete browser-client provisioning below before starting if browser/interop tests are planned. After testing, stop the foreground issuer with Ctrl+C, then remove the setup console's connection/key/configuration variables (or close that dedicated console). Keep the key files and Identity database:

```powershell
foreach ($name in 'ConnectionStrings__IssuerIdentity','Issuer__SigningKeyPath','Issuer__EncryptionKeyPath','Issuer__Url','Issuer__Audience','WindowsAuthentication__Mode','Oidc__ClientId','Oidc__RedirectUri','DOTNET_ENVIRONMENT','ASPNETCORE_ENVIRONMENT') {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
Remove-Variable connection,secret,parsed,currentSid -ErrorAction SilentlyContinue
```

## Windows Server IIS browser test

The supplied Windows Server 2025 deployment is documented in the [IIS evaluation runbook](windows-server-iis-evaluation.md), with [verified server results](../../archive/research/windows-server-iis/EVALUATION.md). Its real IIS issuer, fixture interoperability and final Northwind browser/token suites passed with an environment GO. The user explicitly authorized preparing the test server and installing missing components. Use the complete clean-install guide for those steps.

`scripts/publish-identity-issuer.ps1 -OutputDirectory <directory-outside-checkout>` produces the framework-dependent `net10.0` IIS publish output and SDK-generated `web.config`; private signing/encryption keys are never included. The web server needs IIS/WAS, the .NET 10 Hosting Bundle/ANCM v2 and an HTTPS binding. The clean-install guide supplies the feature/bundle installation commands. Microsoft Edge, Node.js, Playwright CLI and PowerShell 7 belong on the testing workstation; no browser tooling or SDK is required on the web server.

Deploy the issuer at the website root, matching the evaluated topology, and configure its app pool to use `ApplicationPoolIdentity` with no administrator membership. Configure the issuer URL, audience, signing/encryption key file paths, Identity SQL connection string, OIDC client ID/redirect URI, and `WindowsAuthentication:Mode=IIS` using the test site's approved secret/configuration mechanism. The app pool needs read/execute access to publish output and read access only to the configured private-key files. If integrated SQL authentication is used, the selected app-pool identity needs the minimum required access to the isolated `IdentityIssuer` schema. Provision an authorized synthetic Windows SID mapping, enabled Identity user, role, and allowlisted claim in the development database before testing.

At the IIS site, enable both Anonymous Authentication and Windows Authentication. Anonymous access is required for discovery/JWKS and OAuth protocol retrieval; the issuer's authorization fallback still requires Windows Authentication for the session endpoints, and `/connect/authorize` explicitly authenticates the request Windows principal. The browser verifier requires the Development environment: it checks `/diagnostics/windows-auth` and uses `/oidc-browser-test/callback` as a real same-origin public-client callback. The callback returns only an inert no-store HTML page; the verifier performs the code/PKCE exchange in that browser page. Neither test route is available in production.

The callback URL carries an authorization code in its query. ASP.NET Core's `Microsoft.AspNetCore.Hosting.Diagnostics` request-start Information log includes the raw query before browser JavaScript can clear it. The issuer sets that logging category to Warning or higher in all environments, suppressing its request-start and request-finish Information messages while retaining its warnings/errors and other application logging. The browser runner never prints the callback URL. This application filter does not govern IIS/proxy access logs, telemetry collectors, traces, or custom logging providers added outside the issuer; exclude UriQuery from IIS access logs as shown in the clean-install guide; review any additional telemetry query capture separately.

Provision a dedicated public PKCE browser client with the **exact issuer origin** as its redirect base. Use the same explicit Identity connection as migrations, without the `.env` launcher. For local Kestrel, before starting the issuer:

```powershell
$nativeId = $env:Oidc__ClientId
$nativeRedirect = $env:Oidc__RedirectUri
try {
    $env:Oidc__ClientId = 'dab-issuer-browser-test-client'
    $env:Oidc__RedirectUri = 'https://localhost:5001/oidc-browser-test/callback'
    dotnet run --project src/IdentityIssuer/IdentityIssuer.csproj --no-launch-profile -- --provision-oidc-client
    if ($LASTEXITCODE -ne 0) { throw 'Browser OIDC client provisioning failed.' }
} finally {
    $env:Oidc__ClientId = $nativeId
    $env:Oidc__RedirectUri = $nativeRedirect
}
```

This registers `dab-issuer-browser-test-client` with `https://localhost:5001/oidc-browser-test/callback` in the authorized development Identity store. It does not replace the separate native client used by the PowerShell protocol harness. On an IIS test site, provision a distinct browser client with the site's exact HTTPS issuer origin and application path using the documented operator command and configuration overrides. The issuer intentionally grants no token-endpoint CORS access to a separate-origin callback.

The tested issuer is at the **website root**, with the API at `/dab`. An issuer hosted as an `/identity` child is unverified; its route construction may duplicate IIS PathBase. Do not use that topology until a dedicated routing/IIS proof passes.

Run the Playwright CLI verifier from the workstation checkout, using the dedicated caller created by the [clean-install guide](windows-server-2025-clean-install.md#11-create-a-browser-caller-identity-mapping-and-oidc-client). The account must already exist and be mapped. Create its DPAPI file locally:

```powershell
New-Item -ItemType Directory .scratch/issuer-iis-test -Force | Out-Null
Get-Credential -UserName 'WS2025S01\DabProofUser' -Message 'Existing dedicated server test caller' | Export-Clixml .scratch/issuer-iis-test/browser-credentials.xml
```

Replace host/computer names with your deployed server. Use workstation PowerShell 7, Edge, Node and Playwright CLI, with the versions/prerequisite checks in the clean-install guide.

```powershell
pwsh .\scripts\test-identity-issuer-iis.ps1 `
  -Issuer 'https://ws2025s01.mshome.net/' `
  -ClientId 'dab-issuer-iis-browser-client' `
  -RedirectUri 'https://ws2025s01.mshome.net/oidc-browser-test/callback' `
  -AccessAudience 'api://dab-interoperability-test' `
  -CredentialFile .scratch/issuer-iis-test/browser-credentials.xml
```

The test uses Microsoft Edge with a process-scoped authentication allowlist, without editing machine-wide browser policy. `-CredentialFile` supplies the dedicated caller only to the issuer origin. Without it, the interactive account must already have a valid mapping. The script writes temporary config/source under ignored `.scratch`, uses an isolated context, and prints only checks/statuses/booleans. It saves no browser state, traces, screenshots, dumps or private identity/token values. Recreate DPAPI files when workstation/user changes.

For a correctly named certificate trusted by the workstation, append `-ValidateServerCertificate` to the same command. This disables browser bypass without importing trust. The evaluated self-signed server tests omit it; the server's DAB backchannel still validates HTTPS normally using its separately configured trust store.

The test-only browser config is [playwright-cli.iis-test.config.json](../../requests/playwright-cli.iis-test.config.json):

```json
{
  "browser": {
    "contextOptions": {
      "ignoreHTTPSErrors": true
    }
  }
}
```

This setting allows local/self-signed certificates in test Kestrel and Windows Server IIS test environments without installing or trusting them in the workstation certificate store. It bypasses certificate-chain and hostname validation in the browser test; it is not an application TLS setting and does not establish production certificate validity. Production browsers and resource clients should perform normal HTTPS certificate validation.

The browser check validates discovery issuer, Windows request identity type/SID-presence booleans, antiforgery rejection, session creation, cookie attributes and JavaScript invisibility, refresh replacement/replay, logout, callback state and origin, code/PKCE exchange, signed ID/access tokens, and OIDC refresh replay-family revocation. The earlier separate-origin callback run stopped before token exchange; the corrected same-origin local Kestrel run passed every browser check with exit 0. [Ticket #13](https://github.com/gcapnias/dab-iis-yarp/issues/13) records the investigation and exact local evidence. A passing local Kestrel browser run is separate from IIS evidence. The subsequent Windows Server 2025 root-site IIS evaluation passed under [ticket #12](https://github.com/gcapnias/dab-iis-yarp/issues/12), with its dedicated caller/client and workstation browser tests documented in the clean-install guide.

## Evidence and limits

The earlier local Kestrel record is [live-proof-2026-10-02.md](../../archive/research/identity-issuer/live-proof-2026-10-02.md), with the requirement coverage matrix in [implementation-report.md](../../archive/research/identity-issuer/implementation-report.md). Real Kestrel/Negotiate, SQL-backed Identity, cookies, discovery/JWKS, OIDC PKCE, and refresh were exercised. The test workstation has no W3SVC/WAS, `appcmd.exe`, or ANCM v2; no IIS features, bundles, browsers, or certificates were installed or enabled. The later [Windows Server/IIS evaluation](../../archive/research/windows-server-iis/EVALUATION.md) records successful issuer, embedded DAB and final Northwind acceptance. It supersedes the earlier pending-server status; server components were installed only on that authorized server.

## Completed local issuer proof

[The browser-verifier investigation](https://github.com/gcapnias/dab-iis-yarp/issues/13#issuecomment-5954469504) is closed. Commits `48d6f07`, `e8f595a` and `607055f` are integrated on `develop` by `6d7fc6c`. The [investigation report](../../archive/research/identity-issuer/browser-oidc-investigation.md) and [browser evidence](../../archive/research/identity-issuer/browser-proof-2026-10-02.md) record the successful real callback, browser code/PKCE exchange, signed ID/access JWT validation, refresh rotation, replay rejection and application-log safeguard. The merged Release suite passed 34/34 with zero build warnings/errors. This completes the local issuer proof. DAB JWT/cookie compatibility and permissions subsequently passed under #10, and Windows Server/IIS plus access-log evaluation passed under #12. These test results do not establish production readiness or an upstream-supported embedding contract.
