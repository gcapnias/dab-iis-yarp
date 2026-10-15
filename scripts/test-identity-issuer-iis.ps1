param(
    [Parameter(Mandatory)][uri]$Issuer,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][uri]$RedirectUri,
    [Parameter(Mandatory)][string]$AccessAudience,
    [string]$AccessCookieName = 'dab_access_token',
    [string]$RefreshCookieName = 'issuer_refresh_token',
    [string]$CookieDomain,
    [string]$CredentialFile,
    [switch]$ValidateServerCertificate
)

$ErrorActionPreference = 'Stop'
$runnerFailures = @{
    Open = 'playwright_open_failed'
    RunCode = 'playwright_run_code_failed'
    MissingResult = 'playwright_result_missing'
}
$result = [ordered]@{ failure = 'browser_setup_failed' }
$cleanupFailures = [Collections.Generic.List[string]]::new()
$scratch = $null
$cliCommand = $null
$session = 'issuer-iis-' + [guid]::NewGuid().ToString('N')
$phase = 'setup'

try {
    if ($Issuer.Scheme -ne 'https' -or $Issuer.Query -or $Issuer.Fragment -or $Issuer.UserInfo -or
        $RedirectUri.Scheme -ne 'https' -or $RedirectUri.Query -or $RedirectUri.Fragment -or $RedirectUri.UserInfo) {
        throw 'browser_setup_failed'
    }
    if ($RedirectUri.GetLeftPart([UriPartial]::Authority) -ne $Issuer.GetLeftPart([UriPartial]::Authority) -or
        $RedirectUri.AbsolutePath -ne ($Issuer.AbsolutePath.TrimEnd('/') + '/oidc-browser-test/callback')) {
        throw 'browser_setup_failed'
    }

    . (Join-Path $PSScriptRoot 'ProtectedBrowserScratch.ps1')
    . (Join-Path $PSScriptRoot 'ProtectedBrowserRunner.ps1')
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $scratchBase = Join-Path $repositoryRoot '.scratch/identity-issuer'
    $ignoredPath = '.scratch/identity-issuer/playwright-iis-run'
    $null = git -C $repositoryRoot check-ignore --quiet $ignoredPath
    if ($LASTEXITCODE -ne 0) { throw 'browser_setup_failed' }

    # Establish the trusted storage boundary before credential import or config serialization.
    $scratch = New-ProtectedBrowserScratchDirectory -BasePath $scratchBase -NamePrefix 'playwright-iis'

    $cliCommand = Get-Command playwright-cli -ErrorAction SilentlyContinue
    if ($null -eq $cliCommand) { throw 'browser_setup_failed' }
    $edgePaths = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft/Edge/Application/msedge.exe')
    )
    if (-not ($edgePaths | Where-Object { Test-Path -LiteralPath $_ })) { throw 'browser_setup_failed' }

    $configPath = Join-Path $scratch.Path 'cli.config.json'
    $codePath = Join-Path $scratch.Path 'browser-check.js'
    $templatePath = Join-Path $PSScriptRoot 'identity-issuer-browser-check.js'
    $issuerBase = $Issuer.AbsoluteUri.TrimEnd('/') + '/'
    $metadataUrl = [Uri]::new([Uri]$issuerBase, '.well-known/openid-configuration')
    $browserOptions = [ordered]@{
        issuer = $Issuer.AbsoluteUri.TrimEnd('/')
        clientId = $ClientId
        redirectUri = $RedirectUri.AbsoluteUri
        accessAudience = $AccessAudience
        accessCookieName = $AccessCookieName
        refreshCookieName = $RefreshCookieName
        cookieDomain = $CookieDomain
    }

    $template = [IO.File]::ReadAllText($templatePath)
    $testCode = $template.Replace('__OPTIONS__', ($browserOptions | ConvertTo-Json -Compress -Depth 8))
    [IO.File]::WriteAllText($codePath, $testCode, [Text.UTF8Encoding]::new($false))

    $configPathTemplate = Join-Path $repositoryRoot 'requests/playwright-cli.iis-test.config.json'
    $config = Get-Content -LiteralPath $configPathTemplate -Raw | ConvertFrom-Json -AsHashtable
    Set-ProtectedBrowserCliConfiguration -Config $config -Issuer $Issuer -ScratchPath $scratch.Path -ValidateServerCertificate ([bool]$ValidateServerCertificate)
    if ($CredentialFile) {
        Set-ProtectedBrowserCliCredentials -Config $config -Issuer $Issuer -CredentialFile $CredentialFile
    }
    $serializedConfig = $config | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($configPath, $serializedConfig, [Text.UTF8Encoding]::new($false))

    $null = Test-ProtectedBrowserScratchArtifact -Scratch $scratch -Path $codePath
    $null = Test-ProtectedBrowserScratchArtifact -Scratch $scratch -Path $configPath
    $phase = 'runner'
    $runnerOutcome = Invoke-ProtectedBrowserCliLifecycle `
        -CliCommand $cliCommand -Session $session -ConfigPath $configPath -CodePath $codePath `
        -MetadataUrl $metadataUrl -ResultMarker 'ISSUER_IIS_BROWSER_RESULT'
    if ($runnerOutcome.CloseFailed) { $cleanupFailures.Add('browser_close_failed') }
    if ($runnerOutcome.Failure) { throw $runnerOutcome.Failure }
    $result = $runnerOutcome.Result
}
catch {
    if ($_.Exception.Data.Contains('Scratch') -and $null -eq $scratch) {
        $scratch = $_.Exception.Data['Scratch']
    }
    $failure = if ($runnerFailures.Values -contains $_.Exception.Message) {
        $_.Exception.Message
    } elseif ($phase -eq 'runner') {
        'browser_runner_runtime_error'
    } else {
        'browser_setup_failed'
    }
    if ($result.Contains('failure') -and $result.failure -eq 'browser_setup_failed') {
        $result.failure = $failure
    } elseif (-not $result.Contains('failure')) {
        $result.failure = $failure
    }
}
finally {
    if ($null -ne $scratch) {
        try {
            $cleanupResult = Remove-ProtectedBrowserScratchDirectory -Scratch $scratch
            if (-not $cleanupResult.Success) {
                $cleanupCode = if ($cleanupResult.Code -in @('scratch_cleanup_failed', 'scratch_cleanup_unsafe')) { $cleanupResult.Code } else { 'scratch_cleanup_failed' }
                $cleanupFailures.Add($cleanupCode)
            }
        }
        catch {
            $cleanupFailures.Add('scratch_cleanup_failed')
        }
    }
}

if ($cleanupFailures.Count -gt 0) {
    $result.cleanupFailures = @($cleanupFailures)
    if ($cleanupFailures -contains 'scratch_cleanup_failed' -or $cleanupFailures -contains 'scratch_cleanup_unsafe') {
        $result.artifactsRetained = $true
    }
    if (-not $result.Contains('failure') -or -not $result.failure) { $result.failure = 'browser_cleanup_failed' }
}
$json = $result | ConvertTo-Json -Depth 8 -Compress
[Console]::Out.WriteLine($json)
if ($result.Contains('failure') -and $result.failure) { exit 1 }
exit 0
