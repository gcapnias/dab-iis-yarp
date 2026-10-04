# Deploy and evaluate the issuer and embedded DAB under IIS

This is the test-server deployment for [Evaluate the completed issuer and embedded DAB on Windows Server IIS](https://github.com/gcapnias/dab-iis-yarp/issues/12). The user authorized server preparation, missing components, runtimes, deployment under the Default Web Site, and tests from the development workstation. Installation on the workstation is not part of this procedure.

## Evaluated topology

| Component | Address or setting |
| --- | --- |
| Server | `ws2025s01.mshome.net`, Windows Server 2025 Standard |
| IIS site | Default Web Site, HTTPS port 443 |
| Issuer | `https://ws2025s01.mshome.net/` |
| Embedded API | `https://ws2025s01.mshome.net/dab` |
| Issuer pool | `DabProofIssuer`, ApplicationPoolIdentity, no managed CLR |
| API pool | `DabProofApi`, ApplicationPoolIdentity, no managed CLR |
| Physical paths | `C:\DabIisProof\issuer`, `C:\DabIisProof\api` |
| Private issuer keys | `C:\DabIisProof\keys`, separate from published files |
| Runtime | ASP.NET Core/.NET 10.0.12, ANCM 20.0.26234.12 |
| DAB package | Microsoft.DataApiBuilder.Core 2.0.12 |
| Final DAB database | Northwind, `dbo.Products`, authenticated read permissions |
| Identity store | Dedicated disposable SQL database, `IdentityIssuer` schema |

Both applications use ANCM **in-process**, each in its own application pool. The API embeds DAB Core in its worker process; the issuer stays separate. There is no separately running DAB Service executable. Keep the physical paths in native Windows form: IIS did not load application `web.config` files when the site used `C:/...` paths.

## Server preparation

Load the operator-provided DPAPI credential file locally and use `New-PSSession`/`Invoke-Command`. Do not print the credential object, password, SID, connection strings, cookies or JWTs.

Before installing components, inventory `Get-WindowsFeature`, `dotnet --list-runtimes`, IIS sites/applications/pools, disk space, and the intended test network. Preserve existing sites. This server initially had no IIS or .NET runtime.

On the authorized server:

```powershell
Install-WindowsFeature Web-Server,Web-Windows-Auth,Web-Mgmt-Tools -IncludeManagementTools
```

Install IIS **before** the Hosting Bundle. Obtain the exact installer URL and SHA-512 digest from [Microsoft's .NET 10 release metadata](https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json), selecting release `10.0.12` and file `dotnet-hosting-win.exe`. Verify the digest and a valid Microsoft Authenticode signature before copying the installer to the server. Run it with `/install /quiet /norestart /log <restricted-log-path>`, wait for completion, and accept only exit codes 0 or 3010. Handle a required restart explicitly. The recorded installation returned 0; IIS feature installation required no restart.

Restart W3SVC after installation and verify both runtimes and `AspNetCoreModuleV2`. The server needs the Hosting Bundle, not an SDK. Builds and browser tests run from the existing workstation tooling.

## Publish and configure

Publish both projects from the exact reviewed source revision into ignored local staging directories:

```powershell
dotnet publish src/IdentityIssuer/IdentityIssuer.csproj -c Release --no-self-contained -o .scratch/ws2025s01/publish/issuer
dotnet publish src/EmbeddedDab/EmbeddedDab.csproj -c Release --no-self-contained -o .scratch/ws2025s01/publish/api
```

Verify SDK-generated `web.config` has `hostingModel="inprocess"` and `inheritInChildApplications="false"`. Set `ASPNETCORE_ENVIRONMENT=Development` for this proof and `DAB_INITIALIZE=true` for the API. Production deployment requires a different configuration and acceptance process.

Create dedicated pools with `processModel.identityType=ApplicationPoolIdentity`, `loadUserProfile=true`, and empty `managedRuntimeVersion`. Set the Default Web Site's root to the issuer directory/pool and create the `dab` child application pointing to the API directory/pool. Take an IIS configuration backup before changes. The recorded backup is `Wayfinder-BeforeDeployment`.

Enable Anonymous and Windows Authentication at the issuer root; disable Windows Authentication at `/dab`. Discovery/JWKS and OAuth endpoints must remain anonymously reachable; the issuer application requires a Windows principal for its protected endpoints. The API authenticates JWT credentials through DAB's Custom provider.

The issuer needs its exact HTTPS issuer URL, DAB audience, key ID, signing/encryption PEM paths, `WindowsAuthentication:Mode=IIS`, and Identity SQL connection. Register a distinct public PKCE browser client whose redirect is exactly `https://ws2025s01.mshome.net/oidc-browser-test/callback`. Apply the complete idempotent Identity script to the **identified disposable Identity database**, then provision the dedicated non-administrator Windows caller's SID mapping, profile, and explicit roles through the operator commands in the [issuer runbook](windows-authentication-jwt-issuer.md). Never log the SID or provision real Northwind tables as Identity schema targets implicitly.

The API can read its connection directly from a protected DAB configuration without an additional `DAB_CONNECTION_STRING` environment variable. The user explicitly approved credential storage in the protected test-server DAB JSON. `DAB_ENV_FILE` is the optional local fixture workflow, not a deployed-host requirement. Keep the final connection's catalog explicitly `Northwind`, with encryption enabled. Configure Products as a read-only resource for the persisted test roles. Use an isolated disposable fixture for mutation tests; never run the Widget mutation verifier against Northwind sample tables.

Set `runtime.base-route` to `/dab` in DAB configuration. The REST path remains `/api` and GraphQL path `/graphql`, relative to the application. DAB's pagination/creation URL helpers use base-route to include the IIS prefix; Request.PathBase alone does not fix generated links. The [safe Northwind configuration template](../../src/EmbeddedDab/configurations/northwind-iis.json) uses an environment placeholder for the SQL connection, which must be supplied privately or replaced in the protected server configuration.

Restrict the issuer directory and key directory to SYSTEM, administrators and `DabProofIssuer`; restrict the API directory to SYSTEM, administrators and `DabProofApi`. For configuration inheritance, the API pool also needs **non-inherited directory listing/traversal/metadata permissions** on the issuer parent directory and read access to its non-secret `web.config`. It must have no access to `appsettings.Development.json` or private issuer keys. Check effective child-file ACLs after changes: applying a parent ACL can change inheritance metadata without granting additional principals. Avoid recursive grants across the issuer directory.

For updates, stop only the owned application pool, wait until it reports `Stopped`, copy the selected publish files, then start it. Stopping a pool is asynchronous; immediately starting it can fail with `0x80070425`. Preserve configuration and keys when copying updated binaries.

## HTTPS and logs

Generate a short-lived self-signed Server Authentication certificate whose SAN covers `ws2025s01.mshome.net`, store its non-exportable private key in LocalMachine/My, and bind it to the site's HTTPS listener. Trust its public certificate in LocalMachine/Root on the **test server** so DAB's issuer discovery/JWKS backchannel validates normally. The localhost-only development certificate pin is not valid for this topology.

The workstation browser tests use the already approved `ignoreHTTPSErrors: true` option. This bypass covers browser chain/hostname validation only; no workstation certificate-store change was made. Ordinary workstation browsers may display a certificate warning. Restrict the test HTTPS firewall rule to the test network. Production certificate issuance and workstation trust policy are outside this proof.

Exclude `UriQuery` from IIS site logging before any OIDC callback tests. The application already suppresses ASP.NET request-start Information logging, but that does not govern IIS access logs. Avoid printing HTTP response bodies for failed startup requests, since Development errors can contain configuration details. Temporary ANCM/stdout tracing must use a restricted directory and be disabled after diagnosis.

## Browser verification from the workstation

Use the existing Microsoft Edge and `playwright-cli` installation. The dedicated caller credential is stored with `Export-Clixml`, under ignored scratch space; neither the administrator remoting credential nor a signing key is required by these browser commands.

```powershell
pwsh -NoProfile -File scripts/test-identity-issuer-iis.ps1 `
  -Issuer 'https://ws2025s01.mshome.net/' `
  -ClientId dab-issuer-iis-browser-client `
  -RedirectUri 'https://ws2025s01.mshome.net/oidc-browser-test/callback' `
  -AccessAudience 'api://dab-interoperability-test' `
  -CredentialFile .scratch/ws2025s01/browser-credentials.xml

pwsh -NoProfile -File scripts/test-dab-issuer-browser.ps1 `
  -Issuer 'https://ws2025s01.mshome.net/' `
  -Api 'https://ws2025s01.mshome.net/dab' `
  -CredentialFile .scratch/ws2025s01/browser-credentials.xml `
  -Northwind

pwsh -NoProfile -File scripts/test-dab-iis-token-validation.ps1 `
  -Issuer 'https://ws2025s01.mshome.net/' `
  -Api 'https://ws2025s01.mshome.net/dab' `
  -CredentialFile .scratch/ws2025s01/browser-credentials.xml `
  -SigningKeyFile .scratch/ws2025s01/signing.pem
```

The harness restricts explicit Windows browser credentials to the issuer origin, writes its transient browser configuration under ignored scratch space, and removes it after closing the browser. Without `-Northwind`, the DAB verifier expects the disposable Widgets/RetiredWidgets configuration and exercises mutations. Its test rows are deleted during a successful run. Keep the issuer Identity database separate from any fixture that a local test harness automatically drops.

Check `/dab/host`, authenticated Products REST/key/pagination URLs, GraphQL queries, denied roles, and post-logout denial. Verify pagination stays under `/dab`; a root `/api/...` link would incorrectly reach the issuer. Confirm the response process header matches the API worker PID for both REST and GraphQL. Change configuration, restart only the API pool, and confirm routes/permissions change with an unchanged binary.

The token matrix accepts only a proof key whose public RSA modulus matches the actual issuer JWKS. Valid-reader/writer cases use a real Windows/Identity-issued credential; expiry, issuer/audience, unknown key, signature and role failures are controlled tests against the actual IIS DAB validator. Never provide a production signing key to this verifier. The Northwind browser mode passed 12 checks and the token matrix passed 24 checks in the recorded run. Additional durable [origin](../../archive/research/windows-server-iis/check-origin-boundaries.ps1) and [isolated account restriction](../../archive/research/windows-server-iis/check-account-restrictions.ps1) scripts are linked from the report.

## Recovery and retained state

The applications, keys, HTTPS binding, test-server trust entry, firewall rule, dedicated caller, and isolated Identity database are retained for further testing. The test caller expires 14 days after provisioning; the HTTPS certificate expires three months after creation. Keep credentials and private keys in protected ignored/operator storage.

Use the named IIS configuration backup to recover site settings if needed, after reviewing its scope; it predates the proof deployment. Stop the proof pools before replacing binaries or removing the applications. Do not remove the isolated Identity database while the issuer still points to it. Revoke the test account/client and remove only explicitly identified test artifacts when cleanup is authorized. No production data was modified by the Northwind read verifier.

The sanitized findings, acceptance results, fixes and limitations belong in [the server evaluation report](../../archive/research/windows-server-iis/EVALUATION.md).
