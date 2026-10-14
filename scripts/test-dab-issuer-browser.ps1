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
$result = [ordered]@{ failure = 'browser_setup_failed' }
$cleanupFailures = [Collections.Generic.List[string]]::new()
$scratch = $null
$cliCommand = $null
$session = 'issuer-dab-' + [guid]::NewGuid().ToString('N')
$runnerStarted = $false
$phase = 'setup'
$stage = 'url_validation'

try {
    foreach ($endpoint in @($Issuer, $Api)) {
        if ($endpoint.Scheme -ne 'https' -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.UserInfo) {
            throw 'browser_setup_failed'
        }
    }
    if ($Issuer.DnsSafeHost -ne $Api.DnsSafeHost -or $Issuer.AbsoluteUri.TrimEnd('/') -eq $Api.AbsoluteUri.TrimEnd('/')) {
        throw 'browser_setup_failed'
    }

    . (Join-Path $PSScriptRoot 'ProtectedBrowserScratch.ps1')
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $scratchBase = Join-Path $repositoryRoot '.scratch/identity-issuer'
    $stage = 'gitignore_check'
    $ignoredPath = '.scratch/identity-issuer/playwright-dab-run'
    $null = git -C $repositoryRoot check-ignore --quiet $ignoredPath
    if ($LASTEXITCODE -ne 0) { throw 'browser_setup_failed' }
    $scratch = New-ProtectedBrowserScratchDirectory -BasePath $scratchBase -NamePrefix 'playwright-dab'

    $stage = 'prerequisite_check'
    $cliCommand = Get-Command playwright-cli -ErrorAction SilentlyContinue
    if ($null -eq $cliCommand) {
        throw 'browser_setup_failed'
    }
    $edgePaths = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft/Edge/Application/msedge.exe')
    )
    if (-not ($edgePaths | Where-Object { Test-Path -LiteralPath $_ })) {
        throw 'browser_setup_failed'
    }

    $configPath = Join-Path $scratch.Path 'cli.config.json'
    $codePath = Join-Path $scratch.Path 'browser-check.js'
    $templatePath = Join-Path $PSScriptRoot $(if ($Northwind) { 'dab-northwind-browser-check.js' } else { 'dab-issuer-browser-check.js' })
    $issuerBase = $Issuer.AbsoluteUri.TrimEnd('/') + '/'
    $metadataUrl = [Uri]::new([Uri]$issuerBase, '.well-known/openid-configuration')
    $browserOptions = [ordered]@{
        issuer = $Issuer.AbsoluteUri.TrimEnd('/')
        api = $Api.AbsoluteUri.TrimEnd('/')
    }
    $stage = 'template_load'
    $template = [IO.File]::ReadAllText($templatePath)
    $testCode = $template.Replace('__OPTIONS__', ($browserOptions | ConvertTo-Json -Compress -Depth 8))
    [IO.File]::WriteAllText($codePath, $testCode, [Text.UTF8Encoding]::new($false))

    $stage = 'config_template_load'
    $configPathTemplate = Join-Path $repositoryRoot 'requests/playwright-cli.iis-test.config.json'
    $config = Get-Content -LiteralPath $configPathTemplate -Raw | ConvertFrom-Json -AsHashtable
    $config.browser.browserName = 'chromium'
    $config.browser.isolated = $true
    $config.browser.launchOptions = @{
        channel = 'msedge'
        headless = $true
        args = @('--auth-server-allowlist=' + $Issuer.DnsSafeHost)
    }
    $config.browser.contextOptions.ignoreHTTPSErrors = -not [bool]$ValidateServerCertificate
    if ($CredentialFile) {
        $stage = 'credential_import'
        $browserCredential = Import-Clixml -LiteralPath $CredentialFile
        $config.browser.contextOptions.httpCredentials = @{
            username = $browserCredential.UserName
            password = $browserCredential.GetNetworkCredential().Password
            origin = $Issuer.GetLeftPart([UriPartial]::Authority)
        }
    }
    $config.outputMode = 'stdout'
    $config.outputDir = $scratch.Path
    $config.timeouts = @{ action = 15000; navigation = 60000 }
    $serializedConfig = $config | ConvertTo-Json -Depth 10
    $stage = 'config_write'
    [IO.File]::WriteAllText($configPath, $serializedConfig, [Text.UTF8Encoding]::new($false))

    $null = Test-ProtectedBrowserScratchArtifact -Scratch $scratch -Path $codePath
    $null = Test-ProtectedBrowserScratchArtifact -Scratch $scratch -Path $configPath
    $runnerStarted = $true
    $phase = 'runner'
    $stage = 'runner_open'
    $openOutput = @(& $cliCommand.Source --config $configPath "-s=$session" open $metadataUrl.AbsoluteUri 2>&1)
    $openExitCode = $LASTEXITCODE
    if ($openExitCode -ne 0) { throw $runnerFailures.Open }

    $testOutput = @(& $cliCommand.Source "-s=$session" run-code "--filename=$codePath" 2>&1)
    $runExitCode = $LASTEXITCODE
    if ($runExitCode -ne 0) { throw $runnerFailures.RunCode }

    $serialized = ($testOutput | ForEach-Object { [string]$_ }) -join "`n"
    $match = [regex]::Match($serialized, 'DAB_ISSUER_BROWSER_RESULT:(\{[^\r\n]+\})')
    if (-not $match.Success) { throw $runnerFailures.MissingResult }
    try {
        $parsedResult = $match.Groups[1].Value -replace '\\"', '"' | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($parsedResult -isnot [System.Collections.IDictionary]) { throw 'invalid_result' }
        $result = [ordered]@{}
        foreach ($key in $parsedResult.Keys) { $result[$key] = $parsedResult[$key] }
    }
    catch {
        throw 'browser_runner_runtime_error'
    }
}
catch {
    if ($env:DAB_BROWSER_SCRATCH_TEST_DIAGNOSTICS -eq '1') { [Console]::Error.WriteLine('setup_stage=' + $stage) }
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
    if ($runnerStarted -and $null -ne $cliCommand) {
        try {
            $closeOutput = @(& $cliCommand.Source "-s=$session" close 2>&1)
            $closeExitCode = $LASTEXITCODE
            if ($closeExitCode -ne 0) { $cleanupFailures.Add('browser_close_failed') }
        }
        catch {
            $cleanupFailures.Add('browser_close_failed')
        }
    }
    if ($null -ne $scratch) {
        $cleanupResult = Remove-ProtectedBrowserScratchDirectory -Scratch $scratch
        if (-not $cleanupResult.Success) { $cleanupFailures.Add($cleanupResult.Code) }
    }
}

if ($cleanupFailures.Count -gt 0) {
    $result.cleanupFailures = @($cleanupFailures)
    if ($cleanupFailures -contains 'scratch_cleanup_failed' -or $cleanupFailures -contains 'scratch_cleanup_unsafe') {
        $result.artifactsRetained = $true
    }
    if (-not $result.Contains('failure')) { $result.failure = 'browser_cleanup_failed' }
}
$json = $result | ConvertTo-Json -Depth 8 -Compress
[Console]::Out.WriteLine($json)
if ($result.Contains('failure') -and $result.failure) { exit 1 }
exit 0
