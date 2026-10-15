function Set-ProtectedBrowserCliConfiguration {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][uri]$Issuer,
        [Parameter(Mandatory)][string]$ScratchPath,
        [bool]$ValidateServerCertificate
    )

    $Config.browser.browserName = 'chromium'
    $Config.browser.isolated = $true
    $Config.browser.launchOptions = @{
        channel = 'msedge'
        headless = $true
        args = @('--auth-server-allowlist=' + $Issuer.DnsSafeHost)
    }
    $Config.browser.contextOptions.ignoreHTTPSErrors = -not $ValidateServerCertificate
    $Config.outputMode = 'stdout'
    $Config.outputDir = $ScratchPath
    $Config.timeouts = @{ action = 15000; navigation = 60000 }
}

function Set-ProtectedBrowserCliCredentials {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][uri]$Issuer,
        [Parameter(Mandatory)][string]$CredentialFile
    )

    $browserCredential = Import-Clixml -LiteralPath $CredentialFile
    $Config.browser.contextOptions.httpCredentials = @{
        username = $browserCredential.UserName
        password = $browserCredential.GetNetworkCredential().Password
        origin = $Issuer.GetLeftPart([UriPartial]::Authority)
    }
}

function Invoke-ProtectedBrowserCliLifecycle {
    param(
        [Parameter(Mandatory)]$CliCommand,
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$CodePath,
        [Parameter(Mandatory)][uri]$MetadataUrl,
        [Parameter(Mandatory)][string]$ResultMarker
    )

    $result = $null
    $failure = $null
    $closeFailed = $false
    try {
        $null = @(& $CliCommand.Source --config $ConfigPath "-s=$Session" open $MetadataUrl.AbsoluteUri 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $failure = 'playwright_open_failed'
        } else {
            $testOutput = @(& $CliCommand.Source "-s=$Session" run-code "--filename=$CodePath" 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $failure = 'playwright_run_code_failed'
            } else {
                $serialized = ($testOutput | ForEach-Object { [string]$_ }) -join "`n"
                $pattern = [regex]::Escape($ResultMarker) + ':(\{[^\r\n]+\})'
                $match = [regex]::Match($serialized, $pattern)
                if (-not $match.Success) {
                    $failure = 'playwright_result_missing'
                } else {
                    try {
                        $parsedResult = $match.Groups[1].Value -replace '\\"', '"' | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        if ($parsedResult -isnot [System.Collections.IDictionary]) { throw 'invalid_result' }
                        $result = [ordered]@{}
                        foreach ($key in $parsedResult.Keys) { $result[$key] = $parsedResult[$key] }
                    }
                    catch {
                        $result = $null
                        $failure = 'browser_runner_runtime_error'
                    }
                }
            }
        }
    }
    catch {
        $result = $null
        $failure = 'browser_runner_runtime_error'
    }
    finally {
        try {
            $null = @(& $CliCommand.Source "-s=$Session" close 2>&1)
            if ($LASTEXITCODE -ne 0) { $closeFailed = $true }
        }
        catch {
            $closeFailed = $true
        }
    }

    [pscustomobject]@{ Result = $result; Failure = $failure; CloseFailed = $closeFailed }
}
