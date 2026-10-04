param(
    [Parameter(Mandatory)][uri]$Issuer,
    [Parameter(Mandatory)][uri]$Api,
    [string]$CredentialFile,
    [switch]$Northwind,
    [switch]$ValidateServerCertificate
)

$ErrorActionPreference = 'Stop'
$runnerFailures = @{
    Open = 'playwright_open_failed'
    RunCode = 'playwright_run_code_failed'
    MissingResult = 'playwright_result_missing'
}
trap {
    [pscustomobject]@{ failure = 'browser_setup_failed' } | ConvertTo-Json -Compress
    exit 1
}
foreach ($endpoint in @($Issuer, $Api)) {
    if ($endpoint.Scheme -ne 'https' -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.UserInfo) {
        throw 'The proof requires HTTPS application URLs without query, fragment or user information.'
    }
}
if ($Issuer.DnsSafeHost -ne $Api.DnsSafeHost -or $Issuer.AbsoluteUri.TrimEnd('/') -eq $Api.AbsoluteUri.TrimEnd('/')) {
    throw 'Issuer and embedded API must be distinct applications on the same cookie hostname.'
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
$scratchRoot = Join-Path $repositoryRoot ('.scratch/identity-issuer/playwright-dab-' + [guid]::NewGuid().ToString('N'))
$ignoredPath = '.scratch/identity-issuer/' + (Split-Path -Leaf $scratchRoot)
$null = git -C $repositoryRoot check-ignore --quiet $ignoredPath
if ($LASTEXITCODE -ne 0) {
    throw 'The generated browser config and test source are not under a gitignored scratch directory.'
}
$session = 'issuer-dab-' + [guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Path $scratchRoot | Out-Null
$configPath = Join-Path $scratchRoot 'cli.config.json'
$codePath = Join-Path $scratchRoot 'browser-check.js'
$templatePath = Join-Path $PSScriptRoot $(if ($Northwind) { 'dab-northwind-browser-check.js' } else { 'dab-issuer-browser-check.js' })
$issuerBase = $Issuer.AbsoluteUri.TrimEnd('/') + '/'
$metadataUrl = [Uri]::new([Uri]$issuerBase, '.well-known/openid-configuration')
$browserOptions = [ordered]@{
    issuer = $Issuer.AbsoluteUri.TrimEnd('/')
    api = $Api.AbsoluteUri.TrimEnd('/')
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
if ($CredentialFile) {
    $browserCredential = Import-Clixml -LiteralPath $CredentialFile
    $config.browser.contextOptions.httpCredentials = @{
        username = $browserCredential.UserName
        password = $browserCredential.GetNetworkCredential().Password
        origin = $Issuer.GetLeftPart([UriPartial]::Authority)
    }
}
$config.outputMode = 'stdout'
$config.outputDir = $scratchRoot
$config.timeouts = @{ action = 15000; navigation = 60000 }
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8

try {
    $openOutput = & $cliCommand.Source --config $configPath "-s=$session" open $metadataUrl.AbsoluteUri 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw $runnerFailures.Open
    }
    $testOutput = & $cliCommand.Source "-s=$session" run-code "--filename=$codePath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw $runnerFailures.RunCode
    }
    $serialized = ($testOutput | ForEach-Object { [string]$_ }) -join "`n"
    $match = [regex]::Match($serialized, 'DAB_ISSUER_BROWSER_RESULT:(\{[^\r\n]+\})')
    if (-not $match.Success) {
        throw $runnerFailures.MissingResult
    }
    $resultJson = $match.Groups[1].Value -replace '\\"', '"'
    $result = $resultJson | ConvertFrom-Json
    $result | ConvertTo-Json -Depth 4
    if ($result.failure) {
        exit 1
    }
}
catch {
    $failure = if ($runnerFailures.Values -contains $_.Exception.Message) {
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
