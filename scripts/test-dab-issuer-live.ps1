param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path $repositoryRoot ('.scratch/dab-live-' + [Guid]::NewGuid().ToString('N'))
$fixture = 'dab_ticket9_' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$created = $false
$issuerProcess = $null
$apiProcess = $null
$ownedLaunches = @()
$environmentNames = @('DAB_ENV_FILE', 'DAB_FIXTURE_DATABASE', 'DAB_CONFIG_FILE', 'DAB_CONNECTION_STRING',
    'DAB_INITIALIZE', 'DOTNET_ENVIRONMENT', 'DAB_DEVELOPMENT_ISSUER_CERTIFICATE_SHA256')
$originalEnvironment = @{}
foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

function Wait-LocalHost([string]$Url, [Diagnostics.Process]$Process) {
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        if ($Process.HasExited) { throw 'Owned application exited during startup.' }
        try {
            $response = Invoke-WebRequest $Url -SkipCertificateCheck -TimeoutSec 2 -SkipHttpErrorCheck
            if ($response.StatusCode -eq 200) { return }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    throw 'Owned application startup timed out.'
}

function Test-Descendant($Process, [int]$AncestorId) {
    $visited = [Collections.Generic.HashSet[int]]::new()
    while ($null -ne $Process -and $visited.Add([int]$Process.ProcessId)) {
        if ($Process.ProcessId -eq $AncestorId) { return $true }
        $Process = Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.ParentProcessId)"
    }
    return $false
}

function Stop-OwnedTree($Launch) {
    $processes = @(Get-CimInstance Win32_Process)
    $root = $processes | Where-Object ProcessId -eq $Launch.Id | Select-Object -First 1
    # Refuse a recycled root PID. A stopped wrapper may still have live descendants.
    if ($null -ne $root -and [Math]::Abs(($root.CreationDate - $Launch.StartTime).TotalSeconds) -gt 1) { return }
    $ownedIds = [Collections.Generic.HashSet[int]]::new()
    $null = $ownedIds.Add($Launch.Id)
    do {
        $added = $false
        foreach ($process in $processes) {
            if ($process.CreationDate -ge $Launch.StartTime -and $ownedIds.Contains([int]$process.ParentProcessId)) {
                if ($ownedIds.Add([int]$process.ProcessId)) { $added = $true }
            }
        }
    } while ($added)
    foreach ($process in ($processes | Where-Object { $ownedIds.Contains([int]$_.ProcessId) } | Sort-Object CreationDate -Descending)) {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.ProcessId)"
        if ($null -ne $current -and $current.CreationDate -eq $process.CreationDate) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 is required.' }
    if (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in 5001,5002).Count) {
        throw 'Local test ports are already occupied; no existing listener will be stopped.'
    }
    $commonGitDirectory = (git -C $repositoryRoot rev-parse --path-format=absolute --git-common-dir).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot locate primary checkout.' }
    $primaryRoot = Split-Path -Parent $commonGitDirectory
    $env:DAB_ENV_FILE = Join-Path $primaryRoot '.env'
    Remove-Item Env:DAB_CONNECTION_STRING -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $env:DAB_ENV_FILE)) { throw 'Existing ignored development SQL configuration is required.' }
    New-Item -ItemType Directory -Path $scratch | Out-Null
    git -C $repositoryRoot check-ignore --quiet $scratch
    if ($LASTEXITCODE -ne 0) { throw 'Proof scratch path must be ignored by Git.' }
    $apiProject = Join-Path $repositoryRoot 'src/EmbeddedDab/EmbeddedDab.csproj'
    $apiAssembly = Join-Path $repositoryRoot 'src/EmbeddedDab/bin/Release/net10.0/EmbeddedDab.dll'
    dotnet build $apiProject -c Release --verbosity minimal
    if ($LASTEXITCODE -ne 0) { throw 'Embedded API build failed.' }
    $issuerProcess = Start-Process pwsh -ArgumentList @('-NoProfile','-File',(Join-Path $PSScriptRoot 'run-identity-issuer.ps1')) `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $scratch 'issuer.stdout.log') -RedirectStandardError (Join-Path $scratch 'issuer.stderr.log')
    $ownedLaunches += [pscustomobject]@{ Id = $issuerProcess.Id; StartTime = $issuerProcess.StartTime }
    Wait-LocalHost 'https://localhost:5001/.well-known/openid-configuration' $issuerProcess
    $issuerPid = (Get-NetTCPConnection -LocalPort 5001 -State Listen | Select-Object -First 1).OwningProcess
    $issuerListener = Get-CimInstance Win32_Process -Filter "ProcessId = $issuerPid"
    if (-not (Test-Descendant $issuerListener $issuerProcess.Id)) { throw 'Issuer listener does not belong to the owned launcher.' }

    # Inspect only the public TLS leaf, then require it to match an existing ASP.NET development certificate.
    # No authenticated request is sent during this inspection, and no trust store is modified.
    if (-not ('DabLive.LocalIssuerCertificateInspector' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
namespace DabLive {
    public static class LocalIssuerCertificateInspector {
        public static X509Certificate2 Read() {
            X509Certificate2 certificate = null;
            using var tcp = new TcpClient("localhost", 5001);
            using var tls = new SslStream(tcp.GetStream(), false, (_, leaf, chain, errors) => {
                certificate = new X509Certificate2(leaf);
                return true;
            });
            tls.AuthenticateAsClient("localhost");
            return certificate;
        }
    }
}
'@
    }
    $leaf = [DabLive.LocalIssuerCertificateInspector]::Read()
    try {
        $pin = $leaf.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256)
        $existing = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object {
            $_.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256) -eq $pin -and
            @($_.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.84.1.1' }).Count -gt 0
        })
        if ($existing.Count -ne 1) { throw 'Issuer did not present an existing ASP.NET development certificate.' }
        $env:DAB_DEVELOPMENT_ISSUER_CERTIFICATE_SHA256 = $pin
    } finally { $leaf.Dispose() }

    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $metadata = Invoke-RestMethod 'https://localhost:5001/.well-known/openid-configuration' -SkipCertificateCheck
    $csrf = Invoke-RestMethod 'https://localhost:5001/csrf' -UseDefaultCredentials -WebSession $session -SkipCertificateCheck
    $null = Invoke-WebRequest 'https://localhost:5001/session' -Method Post -UseDefaultCredentials -WebSession $session -SkipCertificateCheck -Headers @{'X-CSRF-TOKEN'=$csrf.requestToken}
    $access = $session.Cookies.GetCookies([uri]'https://localhost:5001')['dab_access_token']
    if ($null -eq $access) { throw 'Real issuer did not provide the access cookie.' }
    $part = $access.Value.Split('.')[1].Replace('-','+').Replace('_','/')
    $part = $part.PadRight($part.Length + ((4-$part.Length%4)%4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
    if (-not $claims.profile_id -or @($claims.roles).Count -eq 0) { throw 'Persisted profile and roles are required.' }
    $config = Get-Content (Join-Path $repositoryRoot 'src/EmbeddedDab/configurations/jwt-interoperability.json') -Raw | ConvertFrom-Json
    $config.runtime.host.authentication.jwt.issuer = $metadata.issuer
    $config.runtime.host.authentication.jwt.audience = $claims.aud
    $config.entities.Widget.permissions = @($claims.roles | ForEach-Object { @{role=$_;actions=@('create','read','update','delete')} })
    $config.entities.RetiredWidget.permissions = @($claims.roles | ForEach-Object { @{role=$_;actions=@('read')} })
    $env:DAB_CONFIG_FILE = Join-Path $scratch 'dab-config.json'
    $config | ConvertTo-Json -Depth 20 | Set-Content $env:DAB_CONFIG_FILE
    $null = Invoke-WebRequest 'https://localhost:5001/session/logout' -Method Post -UseDefaultCredentials -WebSession $session -SkipCertificateCheck -Headers @{'X-CSRF-TOKEN'=$csrf.requestToken}
    $env:DAB_FIXTURE_DATABASE = $fixture
    dotnet $apiAssembly --prepare-fixture $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Disposable fixture creation failed.' }
    $created = $true
    $env:DAB_INITIALIZE = 'true'
    $env:DOTNET_ENVIRONMENT = 'Development'
    $apiProcess = Start-Process dotnet -ArgumentList @($apiAssembly,'--urls','https://localhost:5002') `
        -WorkingDirectory (Join-Path $repositoryRoot 'src/EmbeddedDab') -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $scratch 'api.stdout.log') -RedirectStandardError (Join-Path $scratch 'api.stderr.log')
    $ownedLaunches += [pscustomobject]@{ Id = $apiProcess.Id; StartTime = $apiProcess.StartTime }
    Wait-LocalHost 'https://localhost:5002/host' $apiProcess
    & (Join-Path $PSScriptRoot 'test-dab-issuer-browser.ps1') -Issuer https://localhost:5001 -Api https://localhost:5002
    if ($LASTEXITCODE -ne 0) { throw 'Live browser acceptance failed.' }
}
catch {
    Write-Output 'Live proof failed; only sanitized browser results and ignored application logs are retained.'
    $global:LASTEXITCODE = 1
}
finally {
    $resultCode = $LASTEXITCODE
    foreach ($launch in $ownedLaunches) { Stop-OwnedTree $launch }
    if ($created) {
        Remove-Item Env:DAB_CONNECTION_STRING -ErrorAction SilentlyContinue
        dotnet $apiAssembly --cleanup-fixture $fixture
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Disposable fixture cleanup failed.'; $resultCode = 1 }
    }
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name]) }
}
exit $resultCode
