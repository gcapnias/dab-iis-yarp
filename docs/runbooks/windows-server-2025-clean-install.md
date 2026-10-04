# Reproduce the issuer and Northwind DAB deployment on Windows Server 2025

This is the complete installation recipe for the test topology evaluated in issue [#12](https://github.com/gcapnias/dab-iis-yarp/issues/12). Start with an empty **Windows Server 2025 Standard x64** web server and a checkout of this repository on the build workstation. Commands below create new configuration, keys and credentials; no files from an earlier `.scratch` directory are required. The request mentioned “Windows Server 2005”; the evaluated operating system is **2025**. This guide does not establish compatibility with another version.

The existing SQL Server is a separate machine. Installing SQL Server itself is not part of the web-server installation. You must have a reachable SQL instance containing the Northwind sample database and `dbo.Products`, and permission to create a separate Identity database. The evaluated instance was `vs2026` on TCP 1433. Supply your own SQL credentials through prompts. A hostname, an administrator credential, SQL credentials and the source checkout are deployment inputs, rather than secrets supplied by this document.

This is a development/test deployment, including Development configuration and a self-signed HTTPS certificate. The embedded Core adapter is the implementation in this repository, not a standalone DAB Service installation. Commands are for a **new server**, not an unattended upgrade of an occupied IIS site. Do not rerun database creation, account creation or key generation over a working deployment.

## 1. Know the resulting layout and identities

There is **one IIS website and two IIS applications**, not two independent websites. The issuer is the Default Web Site root; the API is its `/dab` child application. Both use ANCM in-process hosting, with separate worker processes.

| Setting | Issuer | Embedded DAB API |
| --- | --- | --- |
| IIS location | `Default Web Site` | `Default Web Site/dab` |
| URL | `https://<server-dns-name>/` | `https://<server-dns-name>/dab` |
| Physical directory | `C:\DabIisProof\issuer` | `C:\DabIisProof\api` |
| Application pool | `DabProofIssuer` | `DabProofApi` |
| Identity | `IIS AppPool\DabProofIssuer` | `IIS AppPool\DabProofApi` |
| Pool identity type | ApplicationPoolIdentity | ApplicationPoolIdentity |
| Custom pool username/password | None; Windows manages the virtual account | None; Windows manages the virtual account |
| Managed CLR / pipeline | No Managed Code / Integrated | No Managed Code / Integrated |
| 32-bit applications / user profile | False / True | False / True |
| Anonymous authentication | Enabled; IIS anonymous user `IUSR` | Enabled; inherited `IUSR` |
| Windows authentication | Enabled; kernel mode, Negotiate then NTLM | Disabled explicitly |
| Application authentication | Windows principal mapped to Identity profile | DAB Custom provider validates issuer JWT |
| SQL target | New isolated database, `IdentityIssuer` schema | Existing `Northwind`, `dbo.Products` |

The administrator used to install software and configure IIS does not run either pool. The browser caller created below is a separate non-administrator account. SQL authentication uses credentials stored in protected application configuration; it does not impersonate either pool or browser caller. `IUSR` is the IIS anonymous identity, not the .NET worker-process identity.

Issuer discovery/JWKS and OAuth bootstrap endpoints need anonymous access. The issuer application challenges Windows authentication on protected routes such as `/csrf`, `/session`, `/diagnostics/windows-auth` and `/connect/authorize`. Disabling Anonymous at the root would break anonymous discovery. The API does not challenge Windows authentication; it requires valid application credentials and authorized roles.

## 2. Prepare access and the build workstation

On the new server, finish Windows setup, set the intended computer name, install applicable OS updates, reboot if needed, configure its IP/DNS and synchronized time. These steps depend on your network; the DNS name used below must resolve from both the server and workstation. Sign in as a local administrator and open **64-bit Windows PowerShell 5.1 as Administrator**. All blocks marked **Server** run in this same elevated console, retaining their variables. Server Core can execute the PowerShell procedure, but the recorded evaluation used Standard with Desktop Experience.

For the artifact transfer and remote access used by this recipe, run on the server console:

```powershell
# Server
Enable-PSRemoting -Force
```

On a trusted workgroup test network, WinRM may require a narrowly scoped TrustedHosts entry on the workstation. Inspect existing entries first; append this hostname without overwriting them. This changes workstation WinRM configuration and requires its elevated console. Domain Kerberos or a separately configured WinRM HTTPS listener can avoid this workgroup step. Do not enable Basic authentication or AllowUnencrypted.

```powershell
# Workstation, elevated; only if workgroup WinRM requires it
$ServerDns = 'ws2025s01.mshome.net' # Replace with the new server's DNS name
$prior = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
$hosts = @($prior -split ',' | Where-Object { $_ }) + $ServerDns
Set-Item WSMan:\localhost\Client\TrustedHosts -Value (($hosts | Select-Object -Unique) -join ',') -Force
```

Run the build and browser blocks in **PowerShell 7 on the workstation**, at the repository root. The evaluated tools were .NET SDK **10.0.401**, PowerShell **7.6.6**, Node.js **24.19.0**, `@playwright/cli` **0.1.22**, and Microsoft Edge. Git is needed to obtain/identify the source. Check them before publishing:

```powershell
# Workstation
git rev-parse HEAD
dotnet --version
pwsh --version
node --version
playwright-cli --version
Test-Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
```

If these tools are absent, install them on the build workstation using the official [.NET SDK downloads](https://dotnet.microsoft.com/download/dotnet/10.0), [PowerShell MSI installation](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), [Node.js downloads](https://nodejs.org/en/download) and [Microsoft Edge](https://www.microsoft.com/edge/download). Use the evaluated versions for an exact reproduction. With Node installed, install the browser CLI with `npm install --global @playwright/cli@0.1.22`. No SDK, Node, Edge, Playwright or PowerShell 7 installation is required on the web server. The tests use workstation Edge; they do not download browser engines. Existing workstation tools were used in the recorded deployment.

Create a fresh staging directory and administrator remoting credential:

```powershell
# Workstation
$ErrorActionPreference = 'Stop'
$ServerDns = 'ws2025s01.mshome.net' # Replace throughout with the new DNS name
$Stage = Join-Path (Get-Location) ('.scratch/deploy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Stage | Out-Null
$AdminCredential = Get-Credential -Message 'New server administrator: SERVER\Administrator'
$Session = New-PSSession -ComputerName $ServerDns -Credential $AdminCredential
Invoke-Command -Session $Session { $env:COMPUTERNAME }
$AdminCredential | Export-Clixml (Join-Path $Stage 'administrator.xml')
```

On Windows, Export-Clixml encrypts the password for the exporting user on that workstation. Regenerate it after changing workstation/user or if decryption fails. Do not commit it or substitute this administrator credential for the browser account.

## 3. Install all web-server operating-system components

```powershell
# Server
$ErrorActionPreference = 'Stop'
$ServerDns = 'ws2025s01.mshome.net' # New server's DNS name, same as workstation
$Root = 'C:\DabIisProof'
$IssuerDir = Join-Path $Root 'issuer'
$ApiDir = Join-Path $Root 'api'
$KeysDir = Join-Path $Root 'keys'
New-Item -ItemType Directory -Path $Root,"$Root\installers","$Root\evidence",$IssuerDir,$ApiDir,$KeysDir -Force | Out-Null
$result = Install-WindowsFeature Web-Server,Web-Windows-Auth,Web-Mgmt-Tools -IncludeManagementTools
if (-not $result.Success) { throw 'IIS feature installation failed.' }
$result | Select-Object Success,RestartNeeded
if ($result.RestartNeeded -eq 'Yes') { throw 'Restart Windows, reopen an elevated console and restore the variables above before continuing.' }
Import-Module WebAdministration
Backup-WebConfiguration -Name 'Wayfinder-BeforeDeployment'
Get-WindowsFeature Web-* | Where-Object Installed | Select-Object Name,DisplayName
```

The feature command installs the following IIS tree (including dependencies/default role services): `Web-Server`, `Web-WebServer`, `Web-Common-Http`, `Web-Default-Doc`, `Web-Dir-Browsing`, `Web-Http-Errors`, `Web-Static-Content`, `Web-Health`, `Web-Http-Logging`, `Web-Performance`, `Web-Stat-Compression`, `Web-Security`, `Web-Filtering`, **`Web-Windows-Auth`**, `Web-Mgmt-Tools`, `Web-Mgmt-Console`. Anonymous authentication is a built-in IIS feature, not a separately downloaded package. WAS/W3SVC services are supplied by the role installation; verify they exist with `Get-Service WAS,W3SVC`.

In Server Manager the added authentication role service is **Web Server (IIS) → Web Server → Security → Windows Authentication**. Application-specific enable/disable settings are applied later in IIS Manager → Sites → Default Web Site → Authentication, and separately at its `dab` application.

Windows PowerShell 5.1 and Windows Server's existing .NET Framework 4.8 are OS facilities. The ASP.NET Core applications run on modern .NET 10, not the .NET Framework CLR. Installing ASP.NET 4.x, CGI, WebDAV, URL Rewrite, ARR, a DAB CLI, or a standalone DAB Service is not required by this deployment. Other installed OS features such as Defender, storage services, Wi-Fi and XPS on the reference machine are not application prerequisites.

## 4. Install and verify the .NET Hosting Bundle

Install IIS **before** the Hosting Bundle so ANCM is registered. Run this on the server with outbound HTTPS access; alternatively download/verify on the workstation and copy the installer with `Copy-Item -ToSession`. The installer is pinned to the tested release; do not silently replace it with whatever “latest” returns.

```powershell
# Server
$Release = '10.0.12'
$metadata = Invoke-RestMethod 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
$releaseEntry = $metadata.releases | Where-Object { $_.'release-version' -eq $Release }
$file = $releaseEntry.'aspnetcore-runtime'.files | Where-Object { $_.name -eq 'dotnet-hosting-win.exe' }
if (@($file).Count -ne 1) { throw 'Pinned Hosting Bundle missing or ambiguous in release metadata.' }
$Installer = "$Root\installers\dotnet-hosting-$Release-win.exe"
Invoke-WebRequest $file.url -OutFile $Installer -UseBasicParsing
if ((Get-FileHash $Installer -Algorithm SHA512).Hash -ne $file.hash) { throw 'Installer SHA512 mismatch.' }
$signature = Get-AuthenticodeSignature $Installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw 'Expected valid Microsoft installer signature.'
}
$install = Start-Process $Installer -ArgumentList '/install','/quiet','/norestart','/log',"$Root\installers\hosting-install.log" -WindowStyle Hidden -Wait -PassThru
if ($install.ExitCode -notin 0,3010) { throw "Hosting Bundle failed: $($install.ExitCode). Inspect installer log." }
if ($install.ExitCode -eq 3010) { throw 'Restart Windows and restore console variables before continuing.' }
Restart-Service W3SVC -Force
& 'C:\Program Files\dotnet\dotnet.exe' --list-runtimes
& 'C:\Program Files (x86)\dotnet\dotnet.exe' --list-runtimes
Get-WebGlobalModule | Where-Object Name -eq 'AspNetCoreModuleV2'
(Get-Item 'C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll').VersionInfo.FileVersion
```

Expected bundle components: .NET Host, Host FX Resolver, Microsoft.NETCore.App and Microsoft.AspNetCore.App **10.0.12**, both x64 and x86; ASP.NET Core Module V2; and Visual C++ x64/x86 Redistributable dependencies. On the reference server the bundle installed Visual C++ **14.29.30139** Minimum/Additional runtimes, Hosting Bundle registry version **10.0.12.26422**, ANCM product registry version **110.0.26234.0**, and ANCM DLL file version **20.0.26234.12**. Registry package version numbers are not the runtime version. Do not skip x86/VC dependency components when reproducing this bundle installation, although both application pools run x64.

Hosting installer URL: `https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/10.0.12/dotnet-hosting-10.0.12-win.exe`. Verified SHA512:

```text
ccfb101fc9287e2e10f16e68957a52778463a266d0ea9dc36df1c635ae2396cefba818146d1008f3d8540b90869eaa6fb59bdc4044bd532fe1f30bb26048ad68
```

If IIS was installed after the bundle, rerun/repair the bundle before proceeding. Microsoft's [IIS hosting documentation](https://learn.microsoft.com/aspnet/core/host-and-deploy/iis/?view=aspnetcore-10.0) describes the Hosting Bundle and virtual application-pool identities.

## 5. Publish, generate private keys, and transfer artifacts

```powershell
# Workstation, PowerShell 7, repository root; $Stage/$Session from step 2
dotnet publish src/IdentityIssuer/IdentityIssuer.csproj -c Release --no-self-contained -o "$Stage/issuer"
if ($LASTEXITCODE -ne 0) { throw 'Issuer publish failed.' }
dotnet publish src/EmbeddedDab/EmbeddedDab.csproj -c Release --no-self-contained -o "$Stage/api"
if ($LASTEXITCODE -ne 0) { throw 'API publish failed.' }
New-Item -ItemType Directory "$Stage/keys" | Out-Null
# Protect local private-key staging before creating keys.
$operatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls $Stage /inheritance:r /grant:r "*${operatorSid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
if ($LASTEXITCODE -ne 0) { throw 'Local staging ACL failed.' }
foreach ($name in 'signing','encryption') {
    $rsa = [Security.Cryptography.RSA]::Create(3072)
    try { [IO.File]::WriteAllText("$Stage/keys/$name.pem",$rsa.ExportPkcs8PrivateKeyPem()) }
    finally { $rsa.Dispose() }
}
Copy-Item "$Stage/issuer/*" -Destination 'C:\DabIisProof\issuer' -ToSession $Session -Recurse -Force
Copy-Item "$Stage/api/*" -Destination 'C:\DabIisProof\api' -ToSession $Session -Recurse -Force
Copy-Item "$Stage/keys/*" -Destination 'C:\DabIisProof\keys' -ToSession $Session -Force
Copy-Item src/EmbeddedDab/configurations/northwind-iis.json -Destination 'C:\DabIisProof\northwind-template.json' -ToSession $Session
Copy-Item archive/research/identity-issuer/IdentityIssuer-current-idempotent.sql -Destination 'C:\DabIisProof\identity-schema.sql' -ToSession $Session
git rev-parse HEAD | Set-Content "$Stage/source-commit.txt"
Copy-Item "$Stage/source-commit.txt" -Destination 'C:\DabIisProof\evidence\source-commit.txt' -ToSession $Session
```

Keep staging private; it contains proof signing keys used by the negative-token verifier later. Generate fresh keys per installation. Windows PowerShell 5.1 cannot call `ExportPkcs8PrivateKeyPem`; that is why key generation runs on workstation PowerShell 7. The certificate for HTTPS is generated separately on the server, with a non-exportable private key.

Publishing restores all NuGet components; nothing needs a separate DAB installer. The issuer uses .NET/EF/Negotiate **10.0.12** and OpenIddict **7.7.1**. Embedded DAB uses Core **2.0.12**, Azure.Security.KeyVault.Secrets **4.6.0**, OpenTelemetry.Exporter.OpenTelemetryProtocol **1.15.3**, Serilog.Sinks.File **7.0.0**, Humanizer.Core **2.14.1**. The project files are the authoritative package pins.

## 6. Create pools and restrict files before adding secrets

```powershell
# Server
foreach ($name in 'DabProofIssuer','DabProofApi') {
    New-WebAppPool -Name $name | Out-Null
    Set-ItemProperty "IIS:\AppPools\$name" -Name managedRuntimeVersion -Value ''
    Set-ItemProperty "IIS:\AppPools\$name" -Name managedPipelineMode -Value 'Integrated'
    Set-ItemProperty "IIS:\AppPools\$name" -Name enable32BitAppOnWin64 -Value $false
    Set-ItemProperty "IIS:\AppPools\$name" -Name processModel.identityType -Value 4
    Set-ItemProperty "IIS:\AppPools\$name" -Name processModel.loadUserProfile -Value $true
    Stop-WebAppPool $name
}
function Set-PrivateDirectoryAcl([string]$Path,[string]$Pool) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
        $principal = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule("IIS AppPool\$Pool",'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
Set-PrivateDirectoryAcl $IssuerDir 'DabProofIssuer'
Set-PrivateDirectoryAcl $ApiDir 'DabProofApi'
Set-PrivateDirectoryAcl $KeysDir 'DabProofIssuer'
```

These are fresh directories/files, with no separately protected child ACLs. Verify `icacls $IssuerDir`, `icacls $ApiDir`, `icacls $KeysDir` and the key files: only SYSTEM, Administrators and the appropriate pool should have access. Administrators/SYSTEM have Full Control; each pool has Read & Execute. No `Everyone`, `Users`, `IUSR`, shared `IIS_IUSRS`, or API-pool grant belongs on the issuer's secrets. No write permission is needed for normal application files. The pools retain the tested default 20-minute idle timeout and default recycling settings; lifecycle tuning is a separate production decision.

## 7. Create the Identity database and confirm Northwind

Run on the server. This uses built-in .NET Framework SqlClient, so it needs **no sqlcmd installation**. Ask your SQL administrator for a login that can create a database and apply its schema. Runtime accounts need access to their respective databases; the proof can use the same SQL login for both but that is not a production privilege recommendation. The tested setup used SQL authentication with encryption and explicitly permitted development `TrustServerCertificate=True`.

```powershell
# Server
$SqlServer = 'vs2026,1433' # Replace with your external SQL endpoint
if (-not (Test-NetConnection ($SqlServer -split ',')[0] -Port 1433).TcpTestSucceeded) { throw 'SQL TCP connectivity failed.' }
$SqlAdmin = Get-Credential -Message 'SQL login allowed to create the isolated Identity database'
$IssuerSql = Get-Credential -Message 'SQL login for the Identity runtime (must have rights to the new database)'
$NorthwindSql = Get-Credential -Message 'SQL login with SELECT permission on Northwind.dbo.Products'
$IdentityDb = 'dab_ticket9_' + [guid]::NewGuid().ToString('N').Substring(0,12)
function New-SqlConnectionString([string]$Database,[pscredential]$Credential) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    # Explicit setters avoid PowerShell treating builder properties as dictionary keys.
    $b.set_DataSource($SqlServer)
    $b.set_InitialCatalog($Database)
    $b.set_UserID($Credential.UserName)
    $b.set_Password($Credential.GetNetworkCredential().Password)
    $b.set_Encrypt($true)
    $b.set_TrustServerCertificate($true) # Test SQL TLS policy; use a trusted SQL certificate for production
    return $b.get_ConnectionString()
}
function Invoke-SqlBatches([string]$ConnectionString,[string]$Sql) {
    $connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try {
        $connection.Open()
        foreach ($batch in [regex]::Split($Sql,'(?im)^\s*GO\s*(?:--[^\r\n]*)?\r?$')) {
            if ([string]::IsNullOrWhiteSpace($batch)) { continue }
            $command = $connection.CreateCommand()
            try { $command.CommandText=$batch; $command.CommandTimeout=120; [void]$command.ExecuteNonQuery() }
            finally { $command.Dispose() }
        }
    } finally { $connection.Dispose() }
}
$AdminMaster = New-SqlConnectionString 'master' $SqlAdmin
Invoke-SqlBatches $AdminMaster "CREATE DATABASE [$IdentityDb];"
$AdminIdentity = New-SqlConnectionString $IdentityDb $SqlAdmin
Invoke-SqlBatches $AdminIdentity ([IO.File]::ReadAllText("$Root\identity-schema.sql"))
```

If using a separate existing SQL-authenticated issuer login, map it into the new database and grant only runtime schema rights with this continuation. This assumes the SQL login already exists; its creation/password is managed by your SQL administrator. The original proof's privileged SQL login already had access. Schema setup still uses the administrative connection above.

```powershell
# Server; create a database user for the supplied issuer SQL login unless it is dbo/sysadmin
$loginLiteral = $IssuerSql.UserName.Replace("'","''")
$loginIdentifier = $IssuerSql.UserName.Replace(']',']]')
$grantSql = @"
IF SUSER_ID(N'$loginLiteral') IS NULL THROW 50000, 'Issuer SQL login does not exist', 1;
IF IS_SRVROLEMEMBER('sysadmin', N'$loginLiteral') <> 1
   AND SUSER_SID(N'$loginLiteral') <> (SELECT owner_sid FROM sys.databases WHERE name = DB_NAME())
BEGIN
    IF DATABASE_PRINCIPAL_ID(N'$loginLiteral') IS NULL CREATE USER [$loginIdentifier] FOR LOGIN [$loginIdentifier];
    GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[IdentityIssuer] TO [$loginIdentifier];
END;
"@
Invoke-SqlBatches $AdminIdentity $grantSql
$IssuerConnection = New-SqlConnectionString $IdentityDb $IssuerSql
$NorthwindConnection = New-SqlConnectionString 'Northwind' $NorthwindSql
Invoke-SqlBatches $IssuerConnection 'SELECT TOP (1) [MigrationId] FROM [IdentityIssuer].[__EFMigrationsHistory];'
Invoke-SqlBatches $NorthwindConnection 'SELECT TOP (1) [ProductID],[ProductName] FROM [dbo].[Products];'
$IdentityDb | Set-Content "$Root\evidence\identity-database.txt"
```

Stop on SQL errors. This guide does not create or mutate Northwind sample data. The complete idempotent schema script includes all five issuer migrations and is applied to the **new Identity database**, never Northwind. The generated `dab_ticket9_` prefix also satisfies the optional isolated account-restriction verifier. Do not print any connection variable or enable transcription while entering secrets.

## 8. Write complete application configuration

```powershell
# Server; retain variables and private connection strings from step 7
$IssuerUrl = "https://$ServerDns/"
$Audience = 'api://dab-interoperability-test'
$ClientId = 'dab-issuer-iis-browser-client'
$RedirectUri = "https://$ServerDns/oidc-browser-test/callback"
$issuerSettings = @{
    ConnectionStrings = @{ IssuerIdentity = $IssuerConnection }
    Issuer = @{
        Url=$IssuerUrl; Audience=$Audience; KeyId='iis-proof-2026-10'
        SigningKeyPath="$KeysDir\signing.pem"; EncryptionKeyPath="$KeysDir\encryption.pem"
        LifetimeMinutes=10; RefreshLifetimeDays=7; CookieName='dab_access_token'
        RefreshCookieName='issuer_refresh_token'; CookieDomain=$null; PreviousSigningKeys=@()
    }
    WindowsAuthentication = @{ Mode='IIS' }
    Oidc = @{ ClientId=$ClientId; RedirectUri=$RedirectUri }
}
$issuerSettings | ConvertTo-Json -Depth 10 | Set-Content "$IssuerDir\appsettings.Development.json" -Encoding UTF8
$dab = Get-Content "$Root\northwind-template.json" -Raw | ConvertFrom-Json
$dab.'data-source'.'connection-string' = $NorthwindConnection
$dab.runtime.host.authentication.jwt.issuer = $IssuerUrl
$dab.runtime.host.authentication.jwt.audience = $Audience
$dab | ConvertTo-Json -Depth 30 | Set-Content "$ApiDir\dab-config.json" -Encoding UTF8
```

The safe repository template supplies `runtime.base-route=/dab`, REST `/api`, GraphQL `/graphql`, development mode, Custom JWT authentication, and only `dbo.Products` with **read** permission for `reader` and `writer`. Even the writer role cannot write Northwind in this deployment. REST URLs are `/dab/api/Products`; GraphQL is `/dab/graphql`. Base-route must include `/dab` for generated pagination links.

The final server DAB JSON contains the SQL-authentication secret in plaintext, protected by the API directory ACL. This storage was explicitly approved for the test deployment. Only SYSTEM, administrators and `DabProofApi` may read it. Issuer SQL credentials are separately protected for `DabProofIssuer`. Keep both files out of source control and public artifacts. Configuration changes require an application-pool restart, not a source rebuild.

Replace the SDK-generated web.config files with these complete in-process definitions. They contain no SQL connection strings. The `inheritInChildApplications=false` boundary is essential.

```powershell
# Server
foreach ($entry in @(@{Path=$IssuerDir;Dll='IdentityIssuer.dll';Api=$false},@{Path=$ApiDir;Dll='EmbeddedDab.dll';Api=$true})) {
    $extra = if ($entry.Api) { '<environmentVariable name="DAB_INITIALIZE" value="true" />' } else { '' }
    $config = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <handlers>
        <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
      </handlers>
      <aspNetCore processPath="dotnet" arguments=".\$($entry.Dll)" stdoutLogEnabled="false" stdoutLogFile=".\logs\stdout" hostingModel="inprocess">
        <environmentVariables>
          <environmentVariable name="ASPNETCORE_ENVIRONMENT" value="Development" />
          $extra
        </environmentVariables>
      </aspNetCore>
    </system.webServer>
  </location>
</configuration>
"@
    [IO.File]::WriteAllText((Join-Path $entry.Path 'web.config'),$config,(New-Object Text.UTF8Encoding($false)))
}
# Parent configuration discovery needs directory-only access and this one non-secret file.
$parentAcl = Get-Acl $IssuerDir
$parentAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('IIS AppPool\DabProofApi','ListDirectory,ReadAttributes,Traverse,Synchronize','None','None','Allow')))
Set-Acl $IssuerDir $parentAcl
$webAcl = Get-Acl "$IssuerDir\web.config"
$webAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('IIS AppPool\DabProofApi','Read','Allow')))
Set-Acl "$IssuerDir\web.config" $webAcl
icacls "$IssuerDir\appsettings.Development.json"
icacls "$KeysDir\signing.pem"
icacls "$ApiDir\dab-config.json"
```

Confirm the API has no ACE on issuer appsettings/private keys. Its issuer-directory grant must have **no inheritance**. Giving only ReadAttributes/Traverse caused an ANCM startup hang on the tested server; ListDirectory was also required. Do not recursively grant the API access to the issuer directory to fix startup.

## 9. Configure IIS applications, authentication and logs

```powershell
# Server
Stop-Website 'Default Web Site'
Set-ItemProperty 'IIS:\Sites\Default Web Site' -Name physicalPath -Value $IssuerDir
Set-ItemProperty 'IIS:\Sites\Default Web Site' -Name applicationPool -Value 'DabProofIssuer'
New-WebApplication -Site 'Default Web Site' -Name 'dab' -PhysicalPath $ApiDir -ApplicationPool 'DabProofApi' | Out-Null
$ConfigPath = 'MACHINE/WEBROOT/APPHOST'
$Auth = 'system.webServer/security/authentication'
Set-WebConfigurationProperty -PSPath $ConfigPath -Location 'Default Web Site' -Filter "$Auth/anonymousAuthentication" -Name enabled -Value $true
Set-WebConfigurationProperty -PSPath $ConfigPath -Location 'Default Web Site' -Filter "$Auth/anonymousAuthentication" -Name userName -Value 'IUSR'
Set-WebConfigurationProperty -PSPath $ConfigPath -Location 'Default Web Site' -Filter "$Auth/windowsAuthentication" -Name enabled -Value $true
Set-WebConfigurationProperty -PSPath $ConfigPath -Location 'Default Web Site' -Filter "$Auth/windowsAuthentication" -Name useKernelMode -Value $true
Clear-WebConfiguration -PSPath $ConfigPath -Location 'Default Web Site' -Filter "$Auth/windowsAuthentication/providers"
Add-WebConfigurationProperty -PSPath $ConfigPath -Location 'Default Web Site' -Filter "$Auth/windowsAuthentication/providers" -Name '.' -Value @{value='Negotiate'}
Add-WebConfigurationProperty -PSPath $ConfigPath -Location 'Default Web Site' -Filter "$Auth/windowsAuthentication/providers" -Name '.' -Value @{value='NTLM'}
Set-WebConfigurationProperty -PSPath $ConfigPath -Location 'Default Web Site/dab' -Filter "$Auth/windowsAuthentication" -Name enabled -Value $false
Set-ItemProperty 'IIS:\Sites\Default Web Site' -Name logFile.logExtFileFlags -Value 'Date,Time,ClientIP,UserName,SiteName,ComputerName,ServerIP,Method,UriStem,HttpStatus,Win32Status,BytesSent,BytesRecv,TimeTaken,ServerPort,UserAgent,ProtocolVersion,Host,HttpSubStatus'
```

Use native `C:\...` physical paths. Forward-slash paths prevented IIS loading web.config in the evaluation. In IIS Manager confirm Basic Settings at the root and `dab` match the table in step 1; Application Pools → each pool → Advanced Settings should show ApplicationPoolIdentity, Load User Profile=True and Enable 32-Bit Applications=False. No password is entered for either pool. Verify root Authentication has both enabled, and `dab` has Anonymous enabled, Windows disabled. Fresh IIS defaults leave Basic/Digest authentication disabled/uninstalled.

The logging command deliberately excludes **UriQuery**, preventing OIDC callback authorization codes from appearing in IIS access logs. Logs are otherwise written to the default `%SystemDrive%\inetpub\logs\LogFiles`. ANCM stdout logging stays disabled. Application request-start Information logging is already suppressed by the source; do not add diagnostics that record cookies, tokens, SIDs or connection strings.

## 10. Install HTTPS binding, server trust and firewall rule

```powershell
# Server
$cert = New-SelfSignedCertificate -DnsName $ServerDns -CertStoreLocation 'Cert:\LocalMachine\My' -FriendlyName 'Wayfinder IIS proof HTTPS' -NotAfter (Get-Date).AddMonths(3) -KeyExportPolicy NonExportable
$publicCertificate = "$Root\evidence\https-public.cer"
Export-Certificate -Cert $cert -FilePath $publicCertificate | Out-Null
Import-Certificate -FilePath $publicCertificate -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -IPAddress '*'
(Get-WebBinding -Name 'Default Web Site' -Protocol https).AddSslCertificate($cert.Thumbprint,'My')
New-NetFirewallRule -Name 'DabProofHttps' -DisplayName 'DAB proof HTTPS from local subnet' -Direction Inbound -Protocol TCP -LocalPort 443 -RemoteAddress LocalSubnet -Action Allow | Out-Null
```

The binding is `*:443:` with no SNI/host restriction; reserve port 443 for this site on the empty server. The default port-80 binding remains, but use HTTPS for all issuer/API tests. If the workstation is outside LocalSubnet, replace that scope with its approved subnet/address. Allow server outbound TCP to SQL and HTTPS to its own issuer URL; check DNS resolves correctly on the server.

A **localhost-only developer certificate is insufficient** for a remote hostname. This certificate has the server hostname in its SAN. Trusting its public certificate in the **server** LocalMachine Root store lets DAB validate issuer discovery/JWKS normally. The workstation test harness intentionally bypasses HTTPS validation for this development certificate; it does not import workstation trust. A normal browser may show a certificate warning. A CA-issued certificate with the correct name/trust is an alternative, but is not the evaluated certificate setup. Record the expiry; renewal requires updating the binding and server trust.

## 11. Create a browser caller, Identity mapping and OIDC client

```powershell
# Server; choose a new strong password in the prompt and retain it in your password manager
$CallerCredential = Get-Credential -UserName "$env:COMPUTERNAME\DabProofUser" -Message 'Password for the NEW non-administrator test caller'
$caller = New-LocalUser -Name 'DabProofUser' -Password $CallerCredential.Password -Description 'Windows caller for IIS proof' -AccountExpires (Get-Date).AddDays(14)
$usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
Add-LocalGroupMember -Group $usersGroup.Name -Member $caller
# Run from the issuer content root so appsettings files are found; no web server is started by these flags.
Push-Location $IssuerDir
try {
    $env:ASPNETCORE_ENVIRONMENT = 'Development'
    $env:ConnectionStrings__IssuerIdentity = $IssuerConnection
    $env:Oidc__ClientId = $ClientId
    $env:Oidc__RedirectUri = $RedirectUri
    @($caller.SID.Value,'iis-proof-profile','IIS proof caller','writer,reader','test') | & 'C:\Program Files\dotnet\dotnet.exe' .\IdentityIssuer.dll --provision-identity
    if ($LASTEXITCODE -ne 0) { throw 'Identity provisioning failed.' }
    & 'C:\Program Files\dotnet\dotnet.exe' .\IdentityIssuer.dll --provision-oidc-client
    if ($LASTEXITCODE -ne 0) { throw 'OIDC client provisioning failed.' }
} finally {
    Remove-Item Env:\ConnectionStrings__IssuerIdentity,Env:\Oidc__ClientId,Env:\Oidc__RedirectUri,Env:\ASPNETCORE_ENVIRONMENT -ErrorAction SilentlyContinue
    Pop-Location
}
```

The Identity provisioning input is five lines: Windows SID, profile ID, display name, comma-separated roles, optional ClearanceLevel. SID is read directly from the newly created server account; do not copy a SID from the old server. No Identity password is created: Windows authenticates the caller, and persisted Identity roles govern issued credentials. Do not add the caller to Administrators. The browser OIDC client is public, requires PKCE, and has the exact HTTPS redirect URI shown above. Replacing a server/account requires a new SID mapping. The account expires after 14 days; renew its expiry explicitly for later testing.

## 12. Start and inspect the deployment

```powershell
# Server
foreach ($name in 'DabProofIssuer','DabProofApi') {
    while ((Get-WebAppPoolState $name).Value -eq 'Stopping') { Start-Sleep -Milliseconds 300 }
    Start-WebAppPool $name
}
Start-Website 'Default Web Site'
Get-Website 'Default Web Site' | Select-Object Name,State,PhysicalPath,ApplicationPool
Get-WebApplication -Site 'Default Web Site' | Select-Object Path,PhysicalPath,ApplicationPool
Get-WebBinding -Name 'Default Web Site'
foreach ($location in 'Default Web Site','Default Web Site/dab') {
    foreach ($kind in 'anonymousAuthentication','windowsAuthentication') {
        Get-WebConfiguration -PSPath $ConfigPath -Location $location -Filter "$Auth/$kind" | Select-Object @{n='Location';e={$location}},@{n='Kind';e={$kind}},enabled,userName,useKernelMode
    }
}
# Server trust must work WITHOUT certificate-validation bypass.
$discovery = Invoke-RestMethod "$IssuerUrl.well-known/openid-configuration"
if ($discovery.issuer -ne $IssuerUrl) { throw 'Discovery issuer mismatch.' }
Invoke-RestMethod "https://$ServerDns/dab/host" | Select-Object processId,framework
Get-FileHash "$IssuerDir\IdentityIssuer.dll","$ApiDir\EmbeddedDab.dll" -Algorithm SHA256
```

Discovery should return HTTP 200 with the configured issuer. `/dab/host` should return HTTP 200 and .NET 10 host information. An anonymous protected Products request must not succeed. Avoid dumping error response bodies; Development exceptions may contain private configuration. SQL login/catalog failures, invalid issuer URLs or failed JWKS TLS validation must be fixed before browser acceptance.

## 13. Run acceptance tests from the workstation

Create a **new** browser credential file using the server's actual computer name and the caller password from step 11. It is separate from the administrator remoting file.

```powershell
# Workstation, PowerShell 7, repository root
$ServerComputerName = Invoke-Command -Session $Session { $env:COMPUTERNAME }
Get-Credential -UserName "$ServerComputerName\DabProofUser" -Message 'Password chosen in step 11' | Export-Clixml "$Stage/browser-credentials.xml"
$IssuerUrl = "https://$ServerDns/"
$ApiUrl = "https://$ServerDns/dab"
$BrowserCredentials = "$Stage/browser-credentials.xml"
pwsh -NoProfile -File scripts/test-identity-issuer-iis.ps1 -Issuer $IssuerUrl -ClientId dab-issuer-iis-browser-client -RedirectUri "https://$ServerDns/oidc-browser-test/callback" -AccessAudience 'api://dab-interoperability-test' -CredentialFile $BrowserCredentials
if ($LASTEXITCODE -ne 0) { throw 'Issuer browser acceptance failed.' }
pwsh -NoProfile -File scripts/test-dab-issuer-browser.ps1 -Issuer $IssuerUrl -Api $ApiUrl -CredentialFile $BrowserCredentials -Northwind
if ($LASTEXITCODE -ne 0) { throw 'Northwind browser acceptance failed.' }
pwsh -NoProfile -File scripts/test-dab-iis-token-validation.ps1 -Issuer $IssuerUrl -Api $ApiUrl -CredentialFile $BrowserCredentials -SigningKeyFile "$Stage/keys/signing.pem"
if ($LASTEXITCODE -ne 0) { throw 'Token validation acceptance failed.' }
```

Expected reference totals: **27 issuer checks, 12 Northwind browser checks, 24 token-validation checks**. Northwind mode verifies REST, key lookup, pagination under `/dab`, GraphQL and logout denial without writing sample tables. A standard Northwind dataset contains Chai (ProductID 1), Chang (2) and the subsequent pagination rows used by the proof. Do not omit `-Northwind`: the other verifier mode expects Widgets/RetiredWidgets in a disposable mutation fixture, not this database.

The token verifier requires the matching **test** signing key; it compares its public modulus with issuer JWKS. It tests expiry, wrong issuer/audience, signature/key and role rejection alongside real Windows/Identity-issued credentials. Do not use a production key. The harness scopes explicit Windows browser credentials to the issuer origin and removes its temporary browser configuration after closing. You do not need to install certificates into workstation stores for these tests.

Optional regression tests of the source, using existing configured fixture credentials where required, are documented in the project test scripts. The deployment acceptance above is the required check of the real IIS installation. Additional origin/account/lifecycle evidence and the earlier mutation-fixture evaluation are preserved in [the evaluation report](../../archive/research/windows-server-iis/EVALUATION.md), not prerequisites for provisioning this Northwind deployment.

## 14. Record, update and troubleshoot safely

Retain the source commit from `evidence/source-commit.txt`, published DLL SHA256 hashes, OS/runtime versions, pool/authentication inspection, Identity database name, certificate thumbprint/expiry and acceptance result counts. Keep configurations, private keys and credential XML in restricted operator storage, outside git. Back up the Identity database and keys if the installation must survive a rebuild; losing either invalidates part of the issuer state. Close the workstation remoting session with `Remove-PSSession $Session` after testing.

For binary updates: publish to a fresh directory; stop the owned pool; wait until `Get-WebAppPoolState` reports `Stopped`; copy only selected binary artifacts; preserve server appsettings, DAB config and keys; restart the pool; rerun acceptance. Do not mirror-delete publish output over the deployed secret configuration. Immediate start after stop can fail with `0x80070425` while the pool is stopping. Rotating keys or changing issuer URL/client redirect requires coordinated configuration and validation, not only copying DLLs.

| Symptom | Check and correction |
| --- | --- |
| Remoting access denied / XML decryption fails | Re-export correct server administrator credentials under the current workstation user; check WinRM/network/TrustedHosts. |
| 500.19 or no ASP.NET Core handler | Hosting Bundle installed after IIS; ANCM registered; valid web.config and native Windows physical path. |
| 500.30/startup failure or startup hang | Event Viewer → Windows Logs → Application, ANCM events; runtime present; pool identities/ACLs; API parent directory ListDirectory and parent web.config Read. Avoid displaying secret-bearing exception bodies. |
| API 404 or pagination points at `/api` | API is an IIS application with its own pool; DAB base-route `/dab`; REST `/api`; Request.PathBase source fix included. |
| Discovery succeeds in browser but DAB cannot validate JWT | Server trusts hostname certificate; issuer URL includes trailing slash; server DNS/backchannel HTTPS works without bypass. |
| Windows login succeeds but no roles / denied session | New account SID is mapped into the correct Identity database; caller active/not locked/expired; explicit reader/writer roles persisted. |
| SQL failure | TCP 1433 reachable, correct login and catalog, Identity migrations applied, Northwind.dbo.Products readable, configured SQL encryption policy. |
| Browser test cannot authenticate | Fresh caller credential XML, current password, exact issuer origin; never use the administrator file as browser caller. |

For temporary ANCM stdout diagnostics, create `api\logs` or `issuer\logs` and grant Modify **only** to that application's pool plus administrators/SYSTEM, enable stdout in its web.config briefly, then disable it and protect/remove diagnostic logs after inspection. Do not grant Modify to the entire application directory. Routine operation uses the default IIS logs and stdout disabled.

The `Wayfinder-BeforeDeployment` IIS backup restores configuration, not binaries, certificates, firewall rules, accounts, private keys or SQL data. Review its scope before `Restore-WebConfiguration -Name 'Wayfinder-BeforeDeployment'`; it affects server-wide IIS configuration. Cleanup is a separate authorized operation: identify and stop only these pools/apps, revoke this test account/client, then remove specifically identified certificates/trust/firewall/files/database artifacts. Never drop Northwind.

## Verification scope

The deployed settings and dependency inventory were re-read from the evaluated server on 2026-10-04. This guide expands the previously successful deployment into an ordered recipe and is syntax-checked against PowerShell. A second empty-server deployment has **not** been performed; completing steps 12–13 on the replacement machine is the final reproduction check. The earlier installation and acceptance results are recorded in [the evaluation report](../../archive/research/windows-server-iis/EVALUATION.md); the shorter [evaluation runbook](windows-server-iis-evaluation.md) preserves its historical context.
