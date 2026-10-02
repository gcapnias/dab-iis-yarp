param(
    [Parameter(Mandatory)][uri]$Issuer,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][uri]$RedirectUri,
    [Parameter(Mandatory)][string]$AccessAudience,
    [string]$AccessCookieName = 'dab_access_token',
    [string]$RefreshCookieName = 'issuer_refresh_token',
    [string]$CookieDomain,
    [switch]$ValidateServerCertificate
)

$ErrorActionPreference = 'Stop'
trap {
    [pscustomobject]@{ failure = 'browser_setup_failed' } | ConvertTo-Json -Compress
    exit 1
}
if ($Issuer.Scheme -ne 'https' -or $Issuer.Query -or $Issuer.Fragment) {
    throw 'Issuer must be an absolute HTTPS URL without query or fragment.'
}
if ($RedirectUri.Scheme -ne 'https' -or $RedirectUri.Query -or $RedirectUri.Fragment) {
    throw 'The registered redirect URI must be an absolute HTTPS URI without query or fragment.'
}
if ($RedirectUri.GetLeftPart([UriPartial]::Authority) -ne $Issuer.GetLeftPart([UriPartial]::Authority) -or
    $RedirectUri.AbsolutePath -ne ($Issuer.AbsolutePath.TrimEnd('/') + '/oidc-browser-test/callback')) {
    throw 'The browser verifier requires a registered same-origin /oidc-browser-test/callback redirect URI.'
}
$cliCommand = Get-Command playwright-cli -ErrorAction SilentlyContinue
if ($null -eq $cliCommand) {
    throw 'playwright-cli is not installed on this test machine. Use an existing approved Windows Server/browser environment; this script never installs software.'
}
$edgePaths = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft/Edge/Application/msedge.exe')
)
if (-not ($edgePaths | Where-Object { Test-Path -LiteralPath $_ })) {
    throw 'Microsoft Edge is unavailable. This script will not download a browser.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scratchRoot = Join-Path $repositoryRoot ('.scratch/identity-issuer/playwright-iis-' + [guid]::NewGuid().ToString('N'))
$ignoredPath = '.scratch/identity-issuer/' + (Split-Path -Leaf $scratchRoot)
$null = git -C $repositoryRoot check-ignore --quiet $ignoredPath
if ($LASTEXITCODE -ne 0) {
    throw 'The generated browser config and test source are not under a gitignored scratch directory.'
}
$session = 'issuer-iis-' + [guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Path $scratchRoot | Out-Null
$configPath = Join-Path $scratchRoot 'cli.config.json'
$codePath = Join-Path $scratchRoot 'browser-check.js'
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
$config = Get-Content (Join-Path $repositoryRoot 'requests/playwright-cli.iis-test.config.json') -Raw | ConvertFrom-Json -AsHashtable
$config.browser.browserName = 'chromium'
$config.browser.isolated = $true
$config.browser.launchOptions = @{
    channel = 'msedge'
    headless = $true
    args = @('--auth-server-allowlist=' + $Issuer.DnsSafeHost)
}
$config.browser.contextOptions.ignoreHTTPSErrors = -not [bool]$ValidateServerCertificate
$config.outputMode = 'stdout'
$config.outputDir = $scratchRoot
$config.timeouts = @{ action = 15000; navigation = 60000 }
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8

try {
    $openOutput = & $cliCommand.Source --config $configPath "-s=$session" open $metadataUrl.AbsoluteUri 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'playwright_open_failed'
    }
    $testOutput = & $cliCommand.Source "-s=$session" run-code "--filename=$codePath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'playwright_run_code_failed'
    }
    $serialized = ($testOutput | ForEach-Object { [string]$_ }) -join "`n"
    $match = [regex]::Match($serialized, 'ISSUER_IIS_BROWSER_RESULT:(\{[^\r\n]+\})')
    if (-not $match.Success) {
        throw 'playwright_result_missing'
    }
    $resultJson = $match.Groups[1].Value -replace '\\"', '"'
    $result = $resultJson | ConvertFrom-Json
    $result | ConvertTo-Json -Depth 4
    if ($result.failure) {
        exit 1
    }
}
catch {
    $failure = if ($_.Exception.Message -match '^(playwright_open_failed|playwright_run_code_failed|playwright_result_missing)$') {
        $_.Exception.Message
    } else {
        'browser_runner_runtime_error'
    }
    [pscustomobject]@{ failure = $failure } | ConvertTo-Json -Compress
    exit 1
}
finally {
    & $cliCommand.Source "-s=$session" close *> $null
    $resolvedScratch = [IO.Path]::GetFullPath($scratchRoot)
    $resolvedScratchParent = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.scratch/identity-issuer')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedScratch.StartsWith($resolvedScratchParent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit 0
