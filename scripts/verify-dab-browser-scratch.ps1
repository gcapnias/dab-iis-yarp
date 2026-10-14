param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ProtectedBrowserScratch.ps1')

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Set-TestProtectedAcl {
    param([Parameter(Mandatory)][string]$Path)

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
        $null = $acl.RemoveAccessRuleAll($existing)
    }
    $operatorSid = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $adminsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($operatorSid)
    foreach ($sid in @($operatorSid, $systemSid, $adminsSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $null = $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Add-TestAllowRule {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][Security.AccessControl.FileSystemRights]$Rights,
        [Security.AccessControl.InheritanceFlags]$Inheritance = [Security.AccessControl.InheritanceFlags]::None,
        [Security.AccessControl.PropagationFlags]$Propagation = [Security.AccessControl.PropagationFlags]::None
    )
    $acl = Get-Acl -LiteralPath $Path
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($Sid), $Rights, $Inheritance, $Propagation,
        [Security.AccessControl.AccessControlType]::Allow)
    $null = $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-ActualApprovedAcl {
    param([Parameter(Mandatory)][string]$Path, [switch]$RunDirectory, [switch]$RequireInheritedAllows)
    $null = Assert-ProtectedBrowserScratchAcl -Path $Path -RunDirectoryPath $(if ($RunDirectory) { $Path } else { Split-Path -Parent $Path }) -RunDirectory:$RunDirectory
    $acl = Get-Acl -LiteralPath $Path
    $allowed = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) {
            Assert-That ($rule.IdentityReference.Value -in $allowed) 'unexpected allowed SID in actual ACL'
            if ($RequireInheritedAllows) { Assert-That $rule.IsInherited 'child artifact allow grant was not inherited from its run directory' }
        }
    }
}

function Invoke-Verifier {
    param(
        [Parameter(Mandatory)][string]$FixtureRoot,
        [Parameter(Mandatory)][string]$StubDirectory,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$ControlPath,
        [string]$CredentialPath,
        [switch]$Northwind
    )
    $pwshPath = (Get-Command pwsh).Source
    $verifierPath = Join-Path $FixtureRoot 'scripts/test-dab-issuer-browser.ps1'
    $start = [Diagnostics.ProcessStartInfo]::new($pwshPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $verifierPath, '-Issuer', 'https://proof.example.test/issuer', '-Api', 'https://proof.example.test/api')) {
        $start.ArgumentList.Add($argument)
    }
    if ($CredentialPath) {
        $start.ArgumentList.Add('-CredentialFile')
        $start.ArgumentList.Add($CredentialPath)
    }
    if ($Northwind) { $start.ArgumentList.Add('-Northwind') }
    $start.Environment['PATH'] = $StubDirectory + ';' + $env:PATH
    $start.Environment['DAB_STUB_MODE'] = $Mode
    $start.Environment['DAB_STUB_CONTROL'] = $ControlPath
    $start.Environment['DAB_STUB_INVOCATION_LOG'] = (Join-Path (Split-Path -Parent $ControlPath) 'stub-invocations.log')
    $start.Environment['DAB_STUB_EXPECT_SECRET'] = $credentialMarker
    $start.Environment['DAB_BROWSER_SCRATCH_TEST_DIAGNOSTICS'] = '1'
    $process = [Diagnostics.Process]::Start($start)
    $stdoutRead = $process.StandardOutput.ReadToEndAsync()
    $stderrRead = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutRead.GetAwaiter().GetResult()
        Stderr = $stderrRead.GetAwaiter().GetResult()
    }
}

function Assert-SingleJsonResult {
    param([Parameter(Mandatory)][psobject]$Run)
    $lines = @($Run.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-That ($lines.Count -eq 1) ('verifier did not emit exactly one final stdout line; stdout=' + $Run.Stdout + '; stderr=' + $Run.Stderr)
    try { $lines[0] | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'verifier stdout was not one JSON object' }
}

function Assert-NoSensitiveOutput {
    param([Parameter(Mandatory)][psobject]$Run, [Parameter(Mandatory)][string]$Marker, [Parameter(Mandatory)][string]$FixtureRoot)
    $combined = $Run.Stdout + $Run.Stderr
    Assert-That ($combined -notmatch [regex]::Escape($Marker)) 'synthetic password marker leaked to process output'
    Assert-That ($combined -notmatch [regex]::Escape($FixtureRoot)) 'fixture or artifact path leaked to process output'
    Assert-That ($combined -notmatch 'playwright-dab-[0-9a-f]{32}') 'generated run-directory name leaked to process output'
}

function Get-ControlledRunDirectory {
    param([Parameter(Mandatory)][string]$ControlPath, [Parameter(Mandatory)][string]$FixtureRoot)
    if (-not (Test-Path -LiteralPath $ControlPath -PathType Leaf)) { return $null }
    $control = Get-Content -LiteralPath $ControlPath -Raw | ConvertFrom-Json -AsHashtable
    $configPath = [IO.Path]::GetFullPath([string]$control.ConfigPath)
    $fixtureScratch = [IO.Path]::GetFullPath((Join-Path $FixtureRoot '.scratch/identity-issuer'))
    if (-not $configPath.StartsWith($fixtureScratch.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'stub reported a path outside its fixture scratch tree'
    }
    $runDirectory = Split-Path -Parent $configPath
    if ((Split-Path -Leaf $runDirectory) -notmatch '^playwright-dab-[0-9a-f]{32}$') {
        throw 'stub reported an unexpected generated directory name'
    }
    [pscustomobject]@{ ConfigPath = $configPath; RunDirectory = $runDirectory; Control = $control }
}

function Invoke-TerminatedWorker {
    param([string]$FixtureRoot, [string]$StubDirectory, [string]$SignalPath, [string]$ControlPath, [string]$CredentialPath)
    $pwshPath = (Get-Command pwsh).Source
    $start = [Diagnostics.ProcessStartInfo]::new($pwshPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $FixtureRoot 'scripts/test-dab-issuer-browser.ps1'), '-Issuer', 'https://proof.example.test/issuer', '-Api', 'https://proof.example.test/api', '-CredentialFile', $CredentialPath)) {
        $start.ArgumentList.Add($argument)
    }
    $start.Environment['PATH'] = $StubDirectory + ';' + $env:PATH
    $start.Environment['DAB_STUB_MODE'] = 'terminate'
    $start.Environment['DAB_STUB_SIGNAL'] = $SignalPath
    $start.Environment['DAB_STUB_CONTROL'] = $ControlPath
    $start.Environment['DAB_STUB_INVOCATION_LOG'] = (Join-Path (Split-Path -Parent $ControlPath) 'stub-invocations.log')
    $start.Environment['DAB_STUB_EXPECT_SECRET'] = $credentialMarker
    $start.Environment['DAB_BROWSER_SCRATCH_TEST_DIAGNOSTICS'] = '1'
    $workerPidPath = Join-Path $FixtureRoot 'termination-worker.pid'
    $start.Environment['DAB_STUB_WORKER_PID_FILE'] = $workerPidPath
    $process = [Diagnostics.Process]::Start($start)
    Set-Content -LiteralPath $workerPidPath -Value $process.Id -NoNewline
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $SignalPath) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    Assert-That (Test-Path -LiteralPath $SignalPath) 'worker did not signal after creating browser config'
    $process.WaitForExit(15000) | Out-Null
    if (-not $process.HasExited) { $process.Kill($true); throw 'terminated verifier process did not exit' }
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $outTask.GetAwaiter().GetResult()
        Stderr = $errTask.GetAwaiter().GetResult()
    }
}

function Invoke-ConfigWriteFailure {
    param([Parameter(Mandatory)][string]$FixtureRoot, [Parameter(Mandatory)][string]$StubDirectory, [Parameter(Mandatory)][string]$CredentialPath)

    $watcherScript = Join-Path $FixtureRoot 'block-config-write.ps1'
    $watcherReady = Join-Path $FixtureRoot 'blocker-ready.signal'
    $watcherCreated = Join-Path $FixtureRoot 'config-directory-created.signal'
    $watcherBody = @'
param([string]$ScratchBase, [string]$ReadyPath, [string]$CreatedPath)
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath $ReadyPath -Value 'ready' -NoNewline
$deadline = [DateTime]::UtcNow.AddSeconds(20)
while ([DateTime]::UtcNow -lt $deadline) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $ScratchBase -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^playwright-dab-[0-9a-f]{32}$')) {
        $configDirectory = Join-Path $directory.FullName 'cli.config.json'
        if (-not (Test-Path -LiteralPath $configDirectory)) {
            [IO.Directory]::CreateDirectory($configDirectory) | Out-Null
            Set-Content -LiteralPath $CreatedPath -Value 'blocked' -NoNewline
            exit 0
        }
    }
    Start-Sleep -Milliseconds 5
}
exit 1
'@
    Set-Content -LiteralPath $watcherScript -Value $watcherBody
    $scratchBase = Join-Path $FixtureRoot '.scratch/identity-issuer'
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-File', $watcherScript, $scratchBase, $watcherReady, $watcherCreated)) { $start.ArgumentList.Add($argument) }
    $watcher = [Diagnostics.Process]::Start($start)
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $watcherReady) -and -not $watcher.HasExited -and [DateTime]::UtcNow -lt $readyDeadline) { Start-Sleep -Milliseconds 20 }
    Assert-That (Test-Path -LiteralPath $watcherReady) 'config blocker did not become ready'
    $controlPath = Join-Path $FixtureRoot 'config-write-failure-control.json'
    $run = Invoke-Verifier -FixtureRoot $FixtureRoot -StubDirectory $StubDirectory -Mode 'success' -ControlPath $controlPath -CredentialPath $CredentialPath
    if (-not $watcher.HasExited) { $watcher.Kill($true) }
    Assert-That (Test-Path -LiteralPath $watcherCreated) 'config blocker did not create the write failure'
    Assert-That ($run.ExitCode -eq 1) 'config serialization failure did not fail the verifier'
    $result = Assert-SingleJsonResult $run
    Assert-That ($result.failure -eq 'browser_setup_failed') 'config serialization failure changed the primary setup code'
    Assert-That ($run.Stderr -match 'setup_stage=config_write') 'config serialization failure was not exercised'
    Assert-NoSensitiveOutput -Run $run -Marker $credentialMarker -FixtureRoot $FixtureRoot
    Assert-That (-not (Test-Path -LiteralPath $controlPath)) 'browser CLI ran after config serialization failed'
    $leftovers = @(Get-ChildItem -LiteralPath $scratchBase -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^playwright-dab-[0-9a-f]{32}$')
    Assert-That ($leftovers.Count -eq 0) 'config serialization failure did not clean its generated run directory'
    [pscustomobject]@{ ExitCode = $run.ExitCode; Stdout = $run.Stdout; Stderr = $run.Stderr }
}

Assert-That $IsWindows 'this verification requires Windows ACLs'
Assert-That ($PSVersionTable.PSVersion.Major -ge 7) 'run this entry point with PowerShell 7'
$profileRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile))
$null = Test-ProtectedBrowserScratchBoundary -Path $profileRoot -IncludeLeafDeleteChild
$fixtureName = 'dab-browser-scratch-verify-' + [guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $profileRoot $fixtureName
$fixtureFull = [IO.Path]::GetFullPath($fixtureRoot)
if ((Split-Path -Parent $fixtureFull) -ne $profileRoot -or (Split-Path -Leaf $fixtureFull) -notmatch '^dab-browser-scratch-verify-[0-9a-f]{32}$') {
    throw 'fixture path was not a new direct child of the verified operator profile root'
}
$fixtureCreated = $false
$report = [Collections.Generic.List[string]]::new()
$credentialMarker = 'SYNTHETIC-ONLY-' + [guid]::NewGuid().ToString('N')
$credentialFile = Join-Path $fixtureRoot 'synthetic-credential.xml'

try {
    $null = [IO.Directory]::CreateDirectory($fixtureRoot)
    $fixtureCreated = $true
    Set-TestProtectedAcl $fixtureRoot
    $null = Test-ProtectedBrowserScratchBoundary -Path $fixtureRoot
    $report.Add('profile_fixture_ancestor_chain=trusted')

    $fixtureScripts = Join-Path $fixtureRoot 'scripts'
    $fixtureRequests = Join-Path $fixtureRoot 'requests'
    $fixtureScratchBase = Join-Path $fixtureRoot '.scratch/identity-issuer'
    $stubDirectory = Join-Path $fixtureRoot 'stub-bin'
    foreach ($directory in @($fixtureScripts, $fixtureRequests, $fixtureScratchBase, $stubDirectory)) {
        $null = [IO.Directory]::CreateDirectory($directory)
    }
    foreach ($name in @('ProtectedBrowserScratch.ps1', 'test-dab-issuer-browser.ps1', 'dab-issuer-browser-check.js', 'dab-northwind-browser-check.js')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $fixtureScripts $name)
    }
    Copy-Item -LiteralPath (Join-Path $repo 'requests/playwright-cli.iis-test.config.json') -Destination (Join-Path $fixtureRequests 'playwright-cli.iis-test.config.json')
    Set-Content -LiteralPath (Join-Path $fixtureRoot '.gitignore') -Value '.scratch/' -NoNewline
    $null = git -C $fixtureRoot init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'fixture git initialization failed' }
    $null = git -C $fixtureRoot check-ignore --quiet '.scratch/identity-issuer/probe'
    Assert-That ($LASTEXITCODE -eq 0) 'fixture scratch base was not ignored'

    $stubScript = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$ErrorActionPreference = 'Stop'
$mode = @($env:DAB_STUB_MODE -split ',')
Add-Content -LiteralPath $env:DAB_STUB_INVOCATION_LOG -Value (@($Arguments) -join '|')
$verb = [string](@($Arguments | Where-Object { $_ -in @('open', 'run-code', 'close') })[-1])
if ($verb -eq 'open') {
    $configIndex = [Array]::IndexOf($Arguments, '--config')
    $configPath = [IO.Path]::GetFullPath($Arguments[$configIndex + 1])
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    $containsExpectedPassword = $false
    if ($config.browser.contextOptions.Contains('httpCredentials')) {
        $containsExpectedPassword = $config.browser.contextOptions.httpCredentials.password -eq $env:DAB_STUB_EXPECT_SECRET
    }
    $control = @{
        ConfigPath = $configPath
        OpenArguments = @($Arguments)
        ContainsExpectedPassword = $containsExpectedPassword
    }
    $control | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:DAB_STUB_CONTROL -NoNewline
    if ($mode -contains 'terminate') {
        Set-Content -LiteralPath $env:DAB_STUB_SIGNAL -Value 'config-created' -NoNewline
        $pidDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $env:DAB_STUB_WORKER_PID_FILE) -and [DateTime]::UtcNow -lt $pidDeadline) { Start-Sleep -Milliseconds 50 }
        Stop-Process -Id ([int](Get-Content -LiteralPath $env:DAB_STUB_WORKER_PID_FILE -Raw)) -Force
    }
        if ($mode -contains 'open-fail') { $global:LASTEXITCODE = 1; return }
    $global:LASTEXITCODE = 0
    return
}
if ($verb -eq 'run-code') {
    if ($mode -contains 'run-fail') { $global:LASTEXITCODE = 1; return }
    if ($mode -contains 'missing-result') { Write-Output 'stub completed without result'; $global:LASTEXITCODE = 0; return }
    if ($mode -contains 'malformed-result') { Write-Output 'DAB_ISSUER_BROWSER_RESULT:{malformed'; $global:LASTEXITCODE = 0; return }
    Write-Output 'DAB_ISSUER_BROWSER_RESULT:{"passed":true,"fixture":true}'
    $global:LASTEXITCODE = 0
    return
}
if ($verb -eq 'close') {
    Add-Content -LiteralPath $env:DAB_STUB_INVOCATION_LOG -Value ('close-enter mode=' + ($mode -join ',') + ';unsafe=' + [bool]($mode -contains 'unsafe-cleanup'))
    if (Test-Path -LiteralPath $env:DAB_STUB_CONTROL) {
        $control = Get-Content -LiteralPath $env:DAB_STUB_CONTROL -Raw | ConvertFrom-Json -AsHashtable
        $config = Get-Content -LiteralPath $control.ConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $control.RunDirectoryExistedAtClose = Test-Path -LiteralPath $config.outputDir -PathType Container
        if ($mode -contains 'unsafe-cleanup') {
            & icacls.exe $config.outputDir /grant '*S-1-5-11:(RX)' /Q | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'fixture_acl_mutation_failed' }
            Add-Content -LiteralPath $env:DAB_STUB_INVOCATION_LOG -Value 'unsafe-acl-set'
        }
        $control | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:DAB_STUB_CONTROL -NoNewline
        Add-Content -LiteralPath $env:DAB_STUB_INVOCATION_LOG -Value 'control-written'
    }
    if ($mode -contains 'close-throw') { throw 'synthetic-close-exception' }
    if ($mode -contains 'close-fail') { $global:LASTEXITCODE = 1; return }
    $global:LASTEXITCODE = 0
    return
}
$global:LASTEXITCODE = 2
'@
    Set-Content -LiteralPath (Join-Path $stubDirectory 'playwright-cli.ps1') -Value $stubScript

    $syntheticCredential = [PSCredential]::new('synthetic-user', (ConvertTo-SecureString $credentialMarker -AsPlainText -Force))
    $syntheticCredential | Export-Clixml -LiteralPath $credentialFile
    Assert-ActualApprovedAcl -Path $credentialFile

    # Positive run-directory and child-file ACL assertions use the live Windows ACLs.
    $directScratch = New-ProtectedBrowserScratchDirectory -BasePath $fixtureScratchBase -NamePrefix 'helper-check'
    $directArtifact = Join-Path $directScratch.Path 'synthetic.json'
    [IO.File]::WriteAllText($directArtifact, '{"synthetic":true}', [Text.UTF8Encoding]::new($false))
    $null = Test-ProtectedBrowserScratchArtifact -Scratch $directScratch -Path $directArtifact
    Assert-ActualApprovedAcl -Path $directScratch.Path -RunDirectory
    Assert-ActualApprovedAcl -Path $directArtifact -RequireInheritedAllows
    $wrongIdentity = [pscustomobject]@{
        Path = $directScratch.Path
        CreationTimeUtc = $directScratch.CreationTimeUtc
        FileIdentity = 'fixture-mismatch'
        OperatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $identityCleanup = Remove-ProtectedBrowserScratchDirectory -Scratch $wrongIdentity
    Assert-That (-not $identityCleanup.Success -and $identityCleanup.Code -eq 'scratch_cleanup_unsafe' -and (Test-Path -LiteralPath $directScratch.Path)) 'cleanup did not retain a directory with a mismatched generated identity'
    $directCleanup = Remove-ProtectedBrowserScratchDirectory -Scratch $directScratch
    Assert-That $directCleanup.Success 'verified helper fixture did not clean up'
    $report.Add('actual_run_and_child_acl=fullcontrol_approved_sids_inherited_from_protected_directory')

    # The executing checkout is deliberately a negative boundary; it remains unchanged.
    $negativeControl = Join-Path $fixtureRoot 'negative-control.json'
    $negative = Invoke-Verifier -FixtureRoot $repo -StubDirectory $stubDirectory -Mode 'success' -ControlPath $negativeControl -CredentialPath (Join-Path $fixtureRoot 'missing-credential-marker.xml')
    $negativeResult = Assert-SingleJsonResult $negative
    Assert-That ($negative.ExitCode -eq 1 -and $negativeResult.failure -eq 'browser_setup_failed') 'shared checkout did not fail closed'
    Assert-That ($negative.Stderr -match 'setup_stage=gitignore_check') 'shared checkout did not fail before credential import'
    Assert-NoSensitiveOutput -Run $negative -Marker $credentialMarker -FixtureRoot $fixtureRoot
    Assert-That (-not (Test-Path -LiteralPath $negativeControl)) 'runner was invoked for the untrusted shared checkout'
    $report.Add('shared_checkout=failed_closed_before_runner_or_credential_import')

    foreach ($variant in @(
        @{ Name = 'default_with_credential'; Mode = 'success'; Credential = $credentialFile; Northwind = $false },
        @{ Name = 'default_without_credential'; Mode = 'success'; Credential = $null; Northwind = $false },
        @{ Name = 'northwind_with_credential'; Mode = 'success'; Credential = $credentialFile; Northwind = $true },
        @{ Name = 'northwind_without_credential'; Mode = 'success'; Credential = $null; Northwind = $true }
    )) {
        $control = Join-Path $fixtureRoot ($variant.Name + '.json')
        $run = Invoke-Verifier -FixtureRoot $fixtureRoot -StubDirectory $stubDirectory -Mode $variant.Mode -ControlPath $control -CredentialPath $variant.Credential -Northwind:$variant.Northwind
        if ($run.ExitCode -ne 0) {
            $safeOut = $run.Stdout -replace [regex]::Escape($credentialMarker), '<redacted>'
            $safeErr = $run.Stderr -replace [regex]::Escape($credentialMarker), '<redacted>'
            throw ($variant.Name + ' failed: exit=' + $run.ExitCode + '; stdout=' + $safeOut + '; stderr=' + $safeErr + '; control=' + (Get-Content -LiteralPath $control -Raw -ErrorAction SilentlyContinue) + '; invocations=' + (Get-Content -LiteralPath (Join-Path $fixtureRoot 'stub-invocations.log') -Raw -ErrorAction SilentlyContinue))
        }
        $result = Assert-SingleJsonResult $run
        Assert-That ($run.ExitCode -eq 0 -and $result.passed -eq $true) ($variant.Name + ' did not succeed')
        Assert-That (-not $result.Contains('cleanupFailures')) ($variant.Name + ' reported unexpected cleanup failure')
        Assert-NoSensitiveOutput -Run $run -Marker $credentialMarker -FixtureRoot $fixtureRoot
        $generated = Get-ControlledRunDirectory -ControlPath $control -FixtureRoot $fixtureRoot
        Assert-That ($generated.Control.RunDirectoryExistedAtClose -eq $true) 'browser close did not precede scratch cleanup'
        Assert-That ($generated.Control.ContainsExpectedPassword -eq [bool]$variant.Credential) ($variant.Name + ' serialized unexpected browser credentials')
        Assert-That (-not (Test-Path -LiteralPath $generated.RunDirectory)) 'successful verifier retained run artifacts'
        Assert-That (Test-Path -LiteralPath $credentialFile) 'verifier removed the imported credential file'
    }
    $report.Add('credential_and_northwind_variants=4_passed')

    $issuerTemplate = Join-Path $fixtureScripts 'dab-issuer-browser-check.js'
    $temporarilyMissingTemplate = $issuerTemplate + '.held'
    Move-Item -LiteralPath $issuerTemplate -Destination $temporarilyMissingTemplate
    try {
        $control = Join-Path $fixtureRoot 'template-load-failure.json'
        $templateRun = Invoke-Verifier -FixtureRoot $fixtureRoot -StubDirectory $stubDirectory -Mode 'success' -ControlPath $control -CredentialPath $credentialFile
    } finally {
        Move-Item -LiteralPath $temporarilyMissingTemplate -Destination $issuerTemplate
    }
    $templateResult = Assert-SingleJsonResult $templateRun
    Assert-That ($templateRun.ExitCode -eq 1 -and $templateResult.failure -eq 'browser_setup_failed' -and $templateRun.Stderr -match 'setup_stage=template_load') 'template-load setup failure policy mismatch'
    Assert-NoSensitiveOutput -Run $templateRun -Marker $credentialMarker -FixtureRoot $fixtureRoot
    Assert-That (-not (Test-Path -LiteralPath $control)) 'browser CLI ran after template load failed'
    Assert-That (@(Get-ChildItem -LiteralPath $fixtureScratchBase -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^playwright-dab-[0-9a-f]{32}$').Count -eq 0) 'template-load failure retained generated artifacts'

    $requestConfig = Join-Path $fixtureRequests 'playwright-cli.iis-test.config.json'
    $heldRequestConfig = $requestConfig + '.held'
    Move-Item -LiteralPath $requestConfig -Destination $heldRequestConfig
    try {
        $control = Join-Path $fixtureRoot 'config-template-load-failure.json'
        $configTemplateRun = Invoke-Verifier -FixtureRoot $fixtureRoot -StubDirectory $stubDirectory -Mode 'success' -ControlPath $control -CredentialPath $credentialFile
    } finally {
        Move-Item -LiteralPath $heldRequestConfig -Destination $requestConfig
    }
    $configTemplateResult = Assert-SingleJsonResult $configTemplateRun
    Assert-That ($configTemplateRun.ExitCode -eq 1 -and $configTemplateResult.failure -eq 'browser_setup_failed' -and $configTemplateRun.Stderr -match 'setup_stage=config_template_load') 'config-template-load setup failure policy mismatch'
    Assert-NoSensitiveOutput -Run $configTemplateRun -Marker $credentialMarker -FixtureRoot $fixtureRoot
    Assert-That (-not (Test-Path -LiteralPath $control)) 'browser CLI ran after config-template load failed'
    Assert-That (@(Get-ChildItem -LiteralPath $fixtureScratchBase -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^playwright-dab-[0-9a-f]{32}$').Count -eq 0) 'config-template-load failure retained generated artifacts'

    $malformedCredential = Join-Path $fixtureRoot 'malformed-synthetic-credential.xml'
    Set-Content -LiteralPath $malformedCredential -Value '<not-clixml>' -NoNewline
    $control = Join-Path $fixtureRoot 'credential-import-failure.json'
    $credentialRun = Invoke-Verifier -FixtureRoot $fixtureRoot -StubDirectory $stubDirectory -Mode 'success' -ControlPath $control -CredentialPath $malformedCredential
    $credentialResult = Assert-SingleJsonResult $credentialRun
    Assert-That ($credentialRun.ExitCode -eq 1 -and $credentialResult.failure -eq 'browser_setup_failed' -and $credentialRun.Stderr -match 'setup_stage=credential_import') 'credential-import setup failure policy mismatch'
    Assert-NoSensitiveOutput -Run $credentialRun -Marker $credentialMarker -FixtureRoot $fixtureRoot
    Assert-That (-not (Test-Path -LiteralPath $control)) 'browser CLI ran after credential import failed'
    Assert-That (@(Get-ChildItem -LiteralPath $fixtureScratchBase -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^playwright-dab-[0-9a-f]{32}$').Count -eq 0) 'credential-import failure retained generated artifacts'

    $configWriteRun = Invoke-ConfigWriteFailure -FixtureRoot $fixtureRoot -StubDirectory $stubDirectory -CredentialPath $credentialFile
    $report.Add('setup_failures=template_load_config_template_load_credential_import_config_write_all_cleaned')

    foreach ($mode in @('open-fail', 'run-fail', 'missing-result', 'malformed-result', 'close-fail', 'close-throw', 'unsafe-cleanup', 'run-fail,unsafe-cleanup', 'close-fail,unsafe-cleanup')) {
        $control = Join-Path $fixtureRoot ($mode.Replace(',', '-') + '.json')
        $run = Invoke-Verifier -FixtureRoot $fixtureRoot -StubDirectory $stubDirectory -Mode $mode -ControlPath $control -CredentialPath $credentialFile
        $result = Assert-SingleJsonResult $run
        Assert-NoSensitiveOutput -Run $run -Marker $credentialMarker -FixtureRoot $fixtureRoot
        if ($mode -eq 'close-fail' -or $mode -eq 'close-throw') {
            Assert-That ($run.ExitCode -eq 1 -and $result.failure -eq 'browser_cleanup_failed' -and $result.cleanupFailures[0] -eq 'browser_close_failed') 'browser close failure policy mismatch'
            Assert-That (-not $result.Contains('artifactsRetained')) 'close failure alone claimed retained artifacts'
        } elseif ($mode -eq 'close-fail,unsafe-cleanup') {
            Assert-That ($run.ExitCode -eq 1 -and $result.failure -eq 'browser_cleanup_failed' -and $result.cleanupFailures.Count -eq 2 -and $result.cleanupFailures[0] -eq 'browser_close_failed' -and $result.cleanupFailures[1] -eq 'scratch_cleanup_unsafe' -and $result.artifactsRetained) 'combined close and scratch cleanup order mismatch'
        } elseif ($mode -eq 'unsafe-cleanup') {
            Assert-That ($run.ExitCode -eq 1 -and $result.failure -eq 'browser_cleanup_failed' -and $result.cleanupFailures[0] -eq 'scratch_cleanup_unsafe' -and $result.artifactsRetained) ('successful browser plus unsafe cleanup policy mismatch: ' + $run.Stdout + '; ' + $run.Stderr + '; invocations=' + ((Get-Content -LiteralPath (Join-Path $fixtureRoot 'stub-invocations.log') -ErrorAction SilentlyContinue | Select-Object -Last 8) -join '|'))
        } elseif ($mode -eq 'run-fail,unsafe-cleanup') {
            Assert-That ($run.ExitCode -eq 1 -and $result.failure -eq 'playwright_run_code_failed' -and $result.cleanupFailures[0] -eq 'scratch_cleanup_unsafe' -and $result.artifactsRetained) 'combined primary and cleanup failure policy mismatch'
        } elseif ($mode -eq 'open-fail') {
            Assert-That ($run.ExitCode -eq 1 -and $result.failure -eq 'playwright_open_failed') 'open failure code was not preserved'
        } elseif ($mode -eq 'run-fail') {
            Assert-That ($run.ExitCode -eq 1 -and $result.failure -eq 'playwright_run_code_failed') 'run-code failure code was not preserved'
        } else {
            Assert-That ($run.ExitCode -eq 1 -and $result.failure -eq 'playwright_result_missing') 'missing or malformed result code mismatch'
        }
        $generated = Get-ControlledRunDirectory -ControlPath $control -FixtureRoot $fixtureRoot
        if ($mode -eq 'unsafe-cleanup' -or $mode -eq 'run-fail,unsafe-cleanup' -or $mode -eq 'close-fail,unsafe-cleanup') {
            Assert-That (Test-Path -LiteralPath $generated.RunDirectory) 'unsafe cleanup did not retain artifacts'
            Assert-ActualApprovedAcl -Path $generated.ConfigPath -RequireInheritedAllows
            Remove-Item -LiteralPath $generated.RunDirectory -Recurse -Force
        } else {
            Assert-That (-not (Test-Path -LiteralPath $generated.RunDirectory)) 'failed run did not clean generated artifacts'
        }
    }
    $report.Add('runner_and_cleanup_failure_matrix=9_passed')

    # Boundary-specific checks all live inside this one unique fixture directory.
    $broadBase = Join-Path $fixtureRoot 'broad-base'
    $null = [IO.Directory]::CreateDirectory($broadBase)
    Add-TestAllowRule -Path $broadBase -Sid 'S-1-5-11' -Rights ([Security.AccessControl.FileSystemRights]::Modify) -Inheritance ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit)
    Set-Content -LiteralPath (Join-Path $broadBase 'keep.txt') -Value 'preserve' -NoNewline
    $broadFailure = $null
    try { $null = New-ProtectedBrowserScratchDirectory -BasePath $broadBase -NamePrefix 'must-fail' } catch { $broadFailure = $_.Exception.Message }
    Assert-That ($broadFailure -eq 'scratch_path_untrusted_grant') 'broad-user mutation grant was not rejected'
    Assert-That (Test-Path -LiteralPath (Join-Path $broadBase 'keep.txt')) 'untrusted base contents were changed'

    $trustedInstallerSid = ([Security.Principal.NTAccount]'NT SERVICE\TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value
    $windowsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $windowsOwner = (Get-Acl -LiteralPath $windowsDirectory).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($windowsOwner -eq $trustedInstallerSid) {
        $ownerFailure = $null
        try { $null = Test-ProtectedBrowserScratchBoundary -Path $windowsDirectory } catch { $ownerFailure = $_.Exception.Message }
        Assert-That ($ownerFailure -eq 'scratch_path_untrusted_owner') 'TrustedInstaller ownership was incorrectly accepted below the volume root'
        $report.Add('untrusted_owner_case=actual_windows_directory_ti_owner_rejected')
    } else {
        $report.Add('untrusted_owner_case=no_untrusted_existing_windows_directory_owner_to_test')
    }

    $reparsePath = Join-Path $fixtureRoot 'reparse-to-fixture'
    $null = New-Item -ItemType Junction -Path $reparsePath -Target $broadBase
    $reparseFailure = $null
    try { $null = Test-ProtectedBrowserScratchBoundary -Path $reparsePath } catch { $reparseFailure = $_.Exception.Message }
    Assert-That ($reparseFailure -eq 'scratch_path_reparse_point') 'reparse redirection was not rejected'
    Remove-Item -LiteralPath $reparsePath -Force

    $deleteChildBase = Join-Path $fixtureRoot 'delete-child-base'
    $null = [IO.Directory]::CreateDirectory($deleteChildBase)
    Add-TestAllowRule -Path $deleteChildBase -Sid 'S-1-5-11' -Rights ([Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles)
    $deleteFailure = $null
    try { $null = New-ProtectedBrowserScratchDirectory -BasePath $deleteChildBase -NamePrefix 'must-fail' } catch { $deleteFailure = $_.Exception.Message }
    Assert-That ($deleteFailure -eq 'scratch_path_untrusted_grant') 'parent delete-child grant was not rejected'

    $readOnlyBase = Join-Path $fixtureRoot 'read-only-grant-base'
    $null = [IO.Directory]::CreateDirectory($readOnlyBase)
    Add-TestAllowRule -Path $readOnlyBase -Sid 'S-1-5-11' -Rights ([Security.AccessControl.FileSystemRights]::ReadAndExecute)
    Assert-That (Test-ProtectedBrowserScratchBoundary -Path $readOnlyBase -IncludeLeafDeleteChild) 'read-only ancestor grant was incorrectly rejected'

    $inheritOnly = Join-Path $fixtureRoot 'inherit-only'
    $null = [IO.Directory]::CreateDirectory($inheritOnly)
    Add-TestAllowRule -Path $inheritOnly -Sid 'S-1-5-11' -Rights ([Security.AccessControl.FileSystemRights]::Modify) -Inheritance ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit) -Propagation ([Security.AccessControl.PropagationFlags]::InheritOnly)
    Assert-That (Test-ProtectedBrowserScratchBoundary -Path $inheritOnly) 'inherit-only grant incorrectly applied to its parent'
    $inheritedChild = Join-Path $inheritOnly 'existing-child'
    $null = [IO.Directory]::CreateDirectory($inheritedChild)
    $inheritedFailure = $null
    try { $null = Test-ProtectedBrowserScratchBoundary -Path $inheritedChild } catch { $inheritedFailure = $_.Exception.Message }
    Assert-That ($inheritedFailure -eq 'scratch_path_untrusted_grant') 'inherit-only grant effect was not checked on its descendant'
    $inheritScratch = New-ProtectedBrowserScratchDirectory -BasePath $inheritOnly -NamePrefix 'inherit-only-check'
    Assert-ActualApprovedAcl -Path $inheritScratch.Path -RunDirectory
    $inheritCleanup = Remove-ProtectedBrowserScratchDirectory -Scratch $inheritScratch
    Assert-That $inheritCleanup.Success 'inherit-only test directory did not clean up safely'

    $trustedInstallerChild = Join-Path $fixtureRoot 'trusted-installer-child'
    $null = [IO.Directory]::CreateDirectory($trustedInstallerChild)
    Add-TestAllowRule -Path $trustedInstallerChild -Sid $trustedInstallerSid -Rights ([Security.AccessControl.FileSystemRights]::FullControl)
    $tiFailure = $null
    try { $null = Test-ProtectedBrowserScratchBoundary -Path $trustedInstallerChild } catch { $tiFailure = $_.Exception.Message }
    Assert-That ($tiFailure -eq 'scratch_path_untrusted_grant') 'TrustedInstaller exception escaped the system-volume root'

    $missingFailure = $null
    try { $null = Test-ProtectedBrowserScratchBoundary -Path (Join-Path $fixtureRoot 'does-not-exist') } catch { $missingFailure = $_.Exception.Message }
    Assert-That ($missingFailure -eq 'scratch_path_unavailable') 'unavailable path inspection did not fail closed'
    $collisionPath = Join-Path $fixtureRoot 'existing-collision'
    $null = [IO.Directory]::CreateDirectory($collisionPath)
    Assert-That (-not [Codex.BrowserScratchNative]::CreateDirectoryExclusive($collisionPath, [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) 'exclusive directory creation reused an existing collision'
    $report.Add('boundary_matrix=broad_grants_parent_delete_child_readonly_allowed_inherit_only_effects_reparse_ti_scope_missing_path_collision')

    $signalPath = Join-Path $fixtureRoot 'termination.signal'
    $control = Join-Path $fixtureRoot 'termination-control.json'
    # The stub receives the verifier PID through a fixture-local signal file after process start.
    $terminated = Invoke-TerminatedWorker -FixtureRoot $fixtureRoot -StubDirectory $stubDirectory -SignalPath $signalPath -ControlPath $control -CredentialPath $credentialFile
    $terminatedResult = Get-ControlledRunDirectory -ControlPath $control -FixtureRoot $fixtureRoot
    Assert-That (Test-Path -LiteralPath $terminatedResult.ConfigPath) 'abruptly terminated worker did not retain its generated config'
    Assert-ActualApprovedAcl -Path $terminatedResult.RunDirectory -RunDirectory
    Assert-ActualApprovedAcl -Path $terminatedResult.ConfigPath -RequireInheritedAllows
    $retainedConfig = Get-Content -LiteralPath $terminatedResult.ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-That ($retainedConfig.browser.contextOptions.httpCredentials.password -eq $credentialMarker) 'abrupt termination fixture did not contain the synthetic plaintext password'
    Assert-NoSensitiveOutput -Run $terminated -Marker $credentialMarker -FixtureRoot $fixtureRoot
    Remove-Item -LiteralPath $terminatedResult.RunDirectory -Recurse -Force
    $report.Add('abrupt_worker_termination=retained_config_acl_verified_then_fixture_cleaned')

    $volumeRoot = [IO.Path]::GetPathRoot($profileRoot)
    $volumeAcl = Get-Acl -LiteralPath $volumeRoot
    $volumeOwner = $volumeAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($volumeOwner -eq $trustedInstallerSid) {
        Assert-That (Test-ProtectedBrowserScratchBoundary -Path $profileRoot) 'TrustedInstaller system-volume-root owner was not accepted'
        $report.Add('trustedinstaller_system_volume_root=actual_owner_case_passed')
    } else {
        $report.Add('trustedinstaller_system_volume_root=not-present_on_executing_volume')
    }
    $report | ForEach-Object { Write-Output $_ }
}
finally {
    Remove-Item Env:DAB_WORKER_PID -ErrorAction SilentlyContinue
    if ($fixtureCreated) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
        if ((Split-Path -Parent $resolvedFixture) -ne $profileRoot -or (Split-Path -Leaf $resolvedFixture) -ne $fixtureName) {
            throw 'refusing to remove outside the unique operator-profile fixture'
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
