param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ProtectedBrowserScratch.ps1')

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Set-TestProtectedAcl([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) { $null = $acl.RemoveAccessRuleAll($rule) }
    $operator = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $acl.SetOwner($operator)
    foreach ($sid in @($operator, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $allow = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $null = $acl.AddAccessRule($allow)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Add-TestAllowRule([string]$Path, [string]$Sid, [Security.AccessControl.FileSystemRights]$Rights) {
    $acl = Get-Acl -LiteralPath $Path
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($Sid), $Rights,
        [Security.AccessControl.InheritanceFlags]::None, [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)
    $null = $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-ActualAcl([string]$Path, [switch]$Directory) {
    $acl = Get-Acl -LiteralPath $Path
    $allowed = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $allowed = @($allowed | Sort-Object -Unique)
    Assert-That ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) 'generated artifact owner is not the operator'
    if ($Directory) { Assert-That $acl.AreAccessRulesProtected 'run directory inherits its DACL' }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $allowRules = @($rules | Where-Object AccessControlType -eq Allow)
    $allowSids = @($allowRules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    Assert-That (($allowSids -join ',') -eq ($allowed -join ',')) 'generated artifact does not have exactly the approved three allow SIDs'
    foreach ($rule in $allowRules) {
            Assert-That ($rule.FileSystemRights -eq [Security.AccessControl.FileSystemRights]::FullControl) 'generated artifact allow grant is not FullControl'
            if (-not $Directory) { Assert-That $rule.IsInherited 'artifact ACL grant is not inherited from its run directory' }
    }
}

function Assert-SingleResult($Run) {
    $lines = @($Run.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-That ($lines.Count -eq 1) ('issuer verifier did not emit exactly one stdout result; exit=' + $Run.ExitCode + '; stdout=' + $Run.Stdout + '; stderr=' + $Run.Stderr)
    $parsed = $lines[0] | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    Assert-That ($parsed -is [System.Collections.IDictionary]) 'issuer verifier did not emit a JSON object'
    $parsed
}

function Assert-Sanitized($Run, [string]$Marker, [string]$Path) {
    $all = $Run.Stdout + $Run.Stderr
    Assert-That ($all -notmatch [regex]::Escape($Marker)) 'synthetic secret marker leaked to output'
    Assert-That ($all -notmatch [regex]::Escape($Path)) 'fixture path leaked to output'
    Assert-That ($all -notmatch 'playwright-iis-[0-9a-f]{32}') 'generated artifact name leaked to output'
}

function Invoke-IssuerVerifier([string]$Root, [string]$Bin, [string]$Mode, [string]$Control, [string]$Credential, [string]$Issuer = 'https://proof.example.test/issuer', [string]$Redirect = 'https://proof.example.test/issuer/oidc-browser-test/callback', [switch]$Validate, [switch]$CustomCookies) {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $verifierParameters = @{ Issuer = $Issuer; ClientId = 'fixture-client'; RedirectUri = $Redirect; AccessAudience = 'fixture-api' }
    if ($Credential) { $verifierParameters.CredentialFile = $Credential }
    if ($Validate) { $verifierParameters.ValidateServerCertificate = $true }
    if ($CustomCookies) { $verifierParameters.AccessCookieName = 'fixture_access'; $verifierParameters.RefreshCookieName = 'fixture_refresh'; $verifierParameters.CookieDomain = 'proof.example.test' }
    $importMarker = $Control + '.import-called'
    Remove-Item -LiteralPath $importMarker -Force -ErrorAction SilentlyContinue
    foreach ($argument in @('-NoProfile', '-File', $script:wrapperPath, (Join-Path $Root 'scripts/test-identity-issuer-iis.ps1'), $importMarker, (ConvertTo-Json -InputObject $verifierParameters -Compress))) { $start.ArgumentList.Add($argument) }
    $start.Environment['PATH'] = $Bin + ';' + $env:PATH
    $start.Environment['ProgramFiles'] = Join-Path $script:fixtureRoot 'fake-program-files'
    $start.Environment['ProgramFiles(x86)'] = Join-Path $script:fixtureRoot 'fake-program-files-x86'
    $start.Environment['ISSUER_STUB_MODE'] = $Mode
    $start.Environment['ISSUER_STUB_CONTROL'] = $Control
    $start.Environment['ISSUER_STUB_SECRET'] = $script:secretMarker
    $start.Environment['ISSUER_STUB_LOG'] = Join-Path $Root 'invocations.log'
    if ($Mode -split ',' -contains 'config-write-fail') { $start.Environment['ISSUER_TEST_BLOCK_CONFIG_WRITE'] = '1' }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult() }
}

function Invoke-WithScratchHelperFailure {
    param(
        [Parameter(Mandatory)][string]$HelperPath,
        [Parameter(Mandatory)][string]$FunctionName,
        [Parameter(Mandatory)][string]$FailureCode,
        [Parameter(Mandatory)][scriptblock]$Invocation
    )

    $backupPath = $HelperPath + '.held'
    $originalMoved = $false
    try {
        Move-Item -LiteralPath $HelperPath -Destination $backupPath
        $originalMoved = $true
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ProtectedBrowserScratch.ps1') -Destination $HelperPath
        $override = "`nfunction {0} {{ throw '{1}' }}" -f $FunctionName, $FailureCode
        Add-Content -LiteralPath $HelperPath -Value $override
        & $Invocation
    }
    finally {
        if ($originalMoved) {
            Remove-Item -LiteralPath $HelperPath -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $backupPath -Destination $HelperPath -Force
        }
    }
}

Assert-That $IsWindows 'issuer ACL verification requires Windows'
Assert-That ($PSVersionTable.PSVersion.Major -ge 7) 'run with PowerShell 7'
$profileRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile))
$null = Test-ProtectedBrowserScratchBoundary -Path $profileRoot -IncludeLeafDeleteChild
$fixtureName = 'issuer-browser-scratch-verify-' + [guid]::NewGuid().ToString('N')
$fixture = Join-Path $profileRoot $fixtureName
Assert-That ((Split-Path -Parent ([IO.Path]::GetFullPath($fixture))) -eq $profileRoot) 'fixture is not a direct child of the verified profile root'
$fixtureCreated = $false
$script:secretMarker = 'SYNTHETIC-ISSUER-' + [guid]::NewGuid().ToString('N')
$report = [Collections.Generic.List[string]]::new()

try {
    $null = [IO.Directory]::CreateDirectory($fixture)
    $fixtureCreated = $true
    $script:fixtureRoot = $fixture
    Set-TestProtectedAcl $fixture
    $null = Test-ProtectedBrowserScratchBoundary -Path $fixture
    $scripts = Join-Path $fixture 'scripts'
    $requests = Join-Path $fixture 'requests'
    $scratchBase = Join-Path $fixture '.scratch/identity-issuer'
    $bin = Join-Path $fixture 'stub-bin'
    foreach ($path in @($scripts, $requests, $scratchBase, $bin, (Join-Path $fixture 'fake-program-files/Microsoft/Edge/Application'), (Join-Path $fixture 'fake-program-files-x86/Microsoft/Edge/Application'))) {
        $null = [IO.Directory]::CreateDirectory($path)
    }
    $script:wrapperPath = Join-Path $fixture 'invoke-with-import-hook.ps1'
    @'
param([string]$VerifierPath, [string]$ImportMarker, [string]$VerifierParametersJson)
function Import-Clixml {
    param([Parameter(Mandatory)][string]$LiteralPath)
    Set-Content -LiteralPath $ImportMarker -Value 'called' -NoNewline
    $credential = Microsoft.PowerShell.Utility\Import-Clixml -LiteralPath $LiteralPath
    if ($env:ISSUER_TEST_BLOCK_CONFIG_WRITE -eq '1') {
        $ready = $env:ISSUER_STUB_CONTROL + '.block-ready'
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
        if (-not (Test-Path -LiteralPath $ready)) { throw 'fixture config write blocker timed out' }
    }
    $credential
}
$VerifierParameters = ConvertFrom-Json -InputObject $VerifierParametersJson -AsHashtable
& $VerifierPath @VerifierParameters
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $script:wrapperPath
    Set-Content -LiteralPath (Join-Path $fixture 'fake-program-files/Microsoft/Edge/Application/msedge.exe') -Value 'fixture-only' -NoNewline
    Set-Content -LiteralPath (Join-Path $fixture 'fake-program-files-x86/Microsoft/Edge/Application/msedge.exe') -Value 'fixture-only' -NoNewline
    foreach ($name in @('ProtectedBrowserScratch.ps1', 'ProtectedBrowserRunner.ps1', 'test-identity-issuer-iis.ps1', 'identity-issuer-browser-check.js')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $scripts $name)
    }
    Copy-Item -LiteralPath (Join-Path $repo 'requests/playwright-cli.iis-test.config.json') -Destination (Join-Path $requests 'playwright-cli.iis-test.config.json')
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value '.scratch/' -NoNewline
    $null = git -C $fixture init --quiet
    Assert-That ($LASTEXITCODE -eq 0) 'fixture repository initialization failed'
    $null = git -C $fixture check-ignore --quiet '.scratch/identity-issuer/probe'
    Assert-That ($LASTEXITCODE -eq 0) 'fixture scratch path is not ignored'

    $stub = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$ErrorActionPreference = 'Stop'
$mode = @($env:ISSUER_STUB_MODE -split ',')
Add-Content -LiteralPath $env:ISSUER_STUB_LOG -Value (@($Arguments) -join '|')
$verb = [string](@($Arguments | Where-Object { $_ -in @('open', 'run-code', 'close') })[-1])
if ($verb -eq 'open') {
    $index = [Array]::IndexOf($Arguments, '--config')
    $configPath = [IO.Path]::GetFullPath($Arguments[$index + 1])
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    $runDirectory = Split-Path -Parent $configPath
    $codePath = Join-Path $runDirectory 'browser-check.js'
    $source = Get-Content -LiteralPath $codePath -Raw
    $acl = Get-Acl -LiteralPath $runDirectory
    $childAcl = Get-Acl -LiteralPath $codePath
    $configAcl = Get-Acl -LiteralPath $configPath
    $allowed = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $actualAllowed = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq Allow | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    $actualChildAllowed = @($childAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq Allow | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    $actualConfigAllowed = @($configAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq Allow | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    $runRules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq Allow)
    $childRules = @($childAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq Allow)
    $configRules = @($configAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq Allow)
    $expectedPassword = if ($config.browser.contextOptions.Contains('httpCredentials')) { $config.browser.contextOptions.httpCredentials.password -eq $env:ISSUER_STUB_SECRET } else { $false }
    $control = @{
        ConfigPath = $configPath; RunDirectory = $runDirectory; CodePath = $codePath; Config = $config
        Source = $source; PasswordMatched = $expectedPassword; RunOwner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        RunProtected = $acl.AreAccessRulesProtected; RunAllowed = $actualAllowed; ChildAllowed = $actualChildAllowed
        ChildOwner = $childAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        ChildInherited = (@($childAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq Allow | Where-Object { -not $_.IsInherited }).Count -eq 0)
        ConfigAllowed = $actualConfigAllowed; ConfigOwner = $configAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        ConfigInherited = (@($configAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq Allow | Where-Object { -not $_.IsInherited }).Count -eq 0)
        RunFullControl = (@($runRules | Where-Object { $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl }).Count -eq 0)
        ChildFullControl = (@($childRules | Where-Object { $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl }).Count -eq 0)
        ConfigFullControl = (@($configRules | Where-Object { $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl }).Count -eq 0)
        MetadataUrl = [string]($Arguments[-1]);
    }
    $control | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $env:ISSUER_STUB_CONTROL -NoNewline
    if ($mode -contains 'terminate') {
        Set-Content -LiteralPath $env:ISSUER_STUB_SIGNAL -Value 'ready' -NoNewline
        while (-not (Test-Path -LiteralPath $env:ISSUER_STUB_PID_FILE)) { Start-Sleep -Milliseconds 20 }
        Stop-Process -Id ([int](Get-Content -LiteralPath $env:ISSUER_STUB_PID_FILE -Raw)) -Force
    }
    $global:LASTEXITCODE = if ($mode -contains 'open-fail') { 1 } else { 0 }
    return
}
if ($verb -eq 'run-code') {
    if ($mode -contains 'run-fail') { $global:LASTEXITCODE = 1; return }
    if ($mode -contains 'missing-result') { Write-Output 'completed'; $global:LASTEXITCODE = 0; return }
    if ($mode -contains 'malformed-result') { Write-Output 'ISSUER_IIS_BROWSER_RESULT:{malformed}'; $global:LASTEXITCODE = 0; return }
    if ($mode -contains 'browser-fail') { Write-Output 'ISSUER_IIS_BROWSER_RESULT:{"failure":"discovery_status"}'; $global:LASTEXITCODE = 0; return }
    Write-Output 'ISSUER_IIS_BROWSER_RESULT:{"discovery_status":true,"oidc_code_pkce_exchange":true}'
    $global:LASTEXITCODE = 0
    return
}
if ($verb -eq 'close') {
    if ($mode -contains 'delete-fail' -and (Test-Path -LiteralPath $env:ISSUER_STUB_CONTROL)) {
        $control = Get-Content -LiteralPath $env:ISSUER_STUB_CONTROL -Raw | ConvertFrom-Json -AsHashtable
        $lockPath = Join-Path $control.RunDirectory 'delete-lock.bin'
        [IO.File]::WriteAllText($lockPath, 'fixture')
        $global:issuerScratchDeleteLock = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    if ($mode -contains 'unsafe-cleanup' -and (Test-Path -LiteralPath $env:ISSUER_STUB_CONTROL)) {
        $control = Get-Content -LiteralPath $env:ISSUER_STUB_CONTROL -Raw | ConvertFrom-Json -AsHashtable
        & icacls.exe $control.RunDirectory /grant '*S-1-5-11:(RX)' /Q | Out-Null
    }
    if ($mode -contains 'close-throw') { throw 'synthetic-close-failure' }
    $global:LASTEXITCODE = if ($mode -contains 'close-fail') { 1 } else { 0 }
    return
}
$global:LASTEXITCODE = 2
'@
    Set-Content -LiteralPath (Join-Path $bin 'playwright-cli.ps1') -Value $stub
    $credentialPath = Join-Path $fixture 'synthetic-credential.xml'
    [PSCredential]::new('synthetic-browser-user', (ConvertTo-SecureString $script:secretMarker -AsPlainText -Force)) | Export-Clixml -LiteralPath $credentialPath

    # Positive evidence uses a real new run directory and real artifact ACLs in this fixture.
    $variants = @(
        @{ Name = 'credential_root'; Credential = $credentialPath; Issuer = 'https://proof.example.test'; Redirect = 'https://proof.example.test/oidc-browser-test/callback'; Validate = $false; Custom = $false },
        @{ Name = 'no_credential_subpath_custom'; Credential = $null; Issuer = 'https://proof.example.test/issuer'; Redirect = 'https://proof.example.test/issuer/oidc-browser-test/callback'; Validate = $true; Custom = $true }
    )
    foreach ($variant in $variants) {
        $controlPath = Join-Path $fixture ($variant.Name + '.json')
        $run = Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'success' -Control $controlPath -Credential $variant.Credential -Issuer $variant.Issuer -Redirect $variant.Redirect -Validate:$variant.Validate -CustomCookies:$variant.Custom
        $result = Assert-SingleResult $run
        Assert-That ($run.ExitCode -eq 0 -and $result.Contains('discovery_status') -and $result.Contains('oidc_code_pkce_exchange')) ($variant.Name + ' did not preserve the issuer result fields')
        Assert-That (-not $result.Contains('cleanupFailures')) 'successful issuer run reported cleanup failures'
        Assert-Sanitized $run $script:secretMarker $fixture
        $control = Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json -AsHashtable
        $operatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Assert-That ($control.RunProtected -and $control.RunOwner -eq $operatorSid) 'actual run ACL lacks protected inheritance or operator owner'
        $expectedAllowSids = @('S-1-5-18', 'S-1-5-32-544', $operatorSid)
        $expectedAllowSids = @($expectedAllowSids | Sort-Object -Unique)
        Assert-That (($control.RunAllowed -join ',') -eq ($expectedAllowSids -join ',')) 'actual run ACL does not contain exactly the approved three allow SIDs'
        Assert-That (($control.ChildAllowed -join ',') -eq ($expectedAllowSids -join ',')) 'actual source ACL does not contain exactly the approved three allow SIDs'
        Assert-That ($control.ChildOwner -eq $operatorSid) 'actual artifact owner is not the operator'
        Assert-That $control.ChildInherited 'source ACL grants were not inherited'
        Assert-That $control.ConfigInherited 'config ACL grants were not inherited'
        Assert-That ($control.ConfigOwner -eq $operatorSid) 'actual config owner is not the operator'
        Assert-That (($control.ConfigAllowed -join ',') -eq ($expectedAllowSids -join ',')) 'actual config ACL does not contain exactly the approved three allow SIDs'
        Assert-That ($control.RunFullControl -and $control.ChildFullControl -and $control.ConfigFullControl) 'actual ACLs do not grant FullControl to every approved SID'
        Assert-That ($control.PasswordMatched -eq [bool]$variant.Credential) 'synthetic credential import/serialization did not match the selected variant'
        Assert-That ((Test-Path -LiteralPath ($controlPath + '.import-called')) -eq [bool]$variant.Credential) 'credential import ordering did not match the selected variant'
        if ($variant.Credential) { Assert-That ($control.Config.browser.contextOptions.httpCredentials.username -eq 'synthetic-browser-user' -and $control.Config.browser.contextOptions.httpCredentials.username -ne [Security.Principal.WindowsIdentity]::GetCurrent().Name) 'imported credential incorrectly defined the executing operator identity' }
        Assert-That ($control.Config.browser.browserName -eq 'chromium' -and $control.Config.browser.launchOptions.channel -eq 'msedge' -and $control.Config.browser.isolated) 'browser engine settings changed'
        Assert-That ($control.Config.browser.contextOptions.ignoreHTTPSErrors -eq (-not $variant.Validate)) 'certificate validation setting was not preserved'
        Assert-That ($control.MetadataUrl -eq ($variant.Issuer.TrimEnd('/') + '/.well-known/openid-configuration')) 'issuer metadata navigation changed'
        $options = [regex]::Match($control.Source, 'const options = (\{[^;]+\});').Groups[1].Value | ConvertFrom-Json -AsHashtable
        Assert-That ($options.issuer -eq $variant.Issuer.TrimEnd('/') -and $options.clientId -eq 'fixture-client' -and $options.redirectUri -eq $variant.Redirect) 'issuer browser options were not preserved'
        if ($variant.Custom) {
            Assert-That ($options.accessCookieName -eq 'fixture_access' -and $options.refreshCookieName -eq 'fixture_refresh' -and $options.cookieDomain -eq 'proof.example.test') 'custom cookie options were not preserved'
        } else {
            Assert-That ($options.accessCookieName -eq 'dab_access_token' -and $options.refreshCookieName -eq 'issuer_refresh_token' -and -not $options.cookieDomain) 'default cookie options changed'
        }
        Assert-That (-not (Test-Path -LiteralPath $control.RunDirectory)) 'successful issuer run did not clean generated artifacts'
        Assert-That (Test-Path -LiteralPath $credentialPath) 'issuer verifier removed the imported synthetic credential file'
    }
    $report.Add('issuer_entrypoint=credential_no_credential_root_subpath_options_actual_acl_successful_cleanup')

    # A protected shared-checkout boundary must reject before attempting to import even a valid synthetic credential.
    $sharedControl = Join-Path $fixture 'shared-checkout.json'
    $shared = Invoke-IssuerVerifier -Root $repo -Bin $bin -Mode 'success' -Control $sharedControl -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
    $sharedResult = Assert-SingleResult $shared
    Assert-That ($shared.ExitCode -eq 1 -and $sharedResult.failure -eq 'browser_setup_failed') ('shared checkout did not fail safely; exit=' + $shared.ExitCode + '; stdout=' + $shared.Stdout + '; stderr=' + $shared.Stderr)
    Assert-That (-not (Test-Path -LiteralPath ($sharedControl + '.import-called'))) 'shared checkout attempted credential import before boundary rejection'
    Assert-That (-not (Test-Path -LiteralPath $sharedControl)) 'runner ran for the shared checkout'
    Assert-Sanitized $shared $script:secretMarker $repo
    $report.Add('shared_checkout=failed_before_credential_import_and_runner')

    # An actual broad mutation grant on an isolated checkout base is rejected before import or runner use.
    $negativeRoot = Join-Path $fixture 'untrusted-checkout'
    $negativeScripts = Join-Path $negativeRoot 'scripts'
    $negativeRequests = Join-Path $negativeRoot 'requests'
    $negativeBase = Join-Path $negativeRoot '.scratch/identity-issuer'
    foreach ($path in @($negativeScripts, $negativeRequests, $negativeBase)) { $null = [IO.Directory]::CreateDirectory($path) }
    foreach ($name in @('ProtectedBrowserScratch.ps1', 'test-identity-issuer-iis.ps1', 'identity-issuer-browser-check.js')) { Copy-Item (Join-Path $PSScriptRoot $name) (Join-Path $negativeScripts $name) }
    Copy-Item (Join-Path $repo 'requests/playwright-cli.iis-test.config.json') (Join-Path $negativeRequests 'playwright-cli.iis-test.config.json')
    Set-Content -LiteralPath (Join-Path $negativeRoot '.gitignore') -Value '.scratch/' -NoNewline
    $null = git -C $negativeRoot init --quiet
    $sentinel = Join-Path $negativeBase 'keep-sentinel.txt'
    Set-Content -LiteralPath $sentinel -Value 'preserve' -NoNewline
    Add-TestAllowRule $negativeBase 'S-1-5-11' ([Security.AccessControl.FileSystemRights]::Modify)
    $negativeControl = Join-Path $fixture 'untrusted-checkout.json'
    $negativeRun = Invoke-IssuerVerifier -Root $negativeRoot -Bin $bin -Mode 'success' -Control $negativeControl -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
    $negativeResult = Assert-SingleResult $negativeRun
    Assert-That ($negativeRun.ExitCode -eq 1 -and $negativeResult.failure -eq 'browser_setup_failed' -and -not (Test-Path -LiteralPath ($negativeControl + '.import-called')) -and -not (Test-Path -LiteralPath $negativeControl)) 'untrusted checkout did not fail before credential import and runner invocation'
    Assert-That (Test-Path -LiteralPath $sentinel) 'untrusted checkout contents were changed'
    Assert-Sanitized $negativeRun $script:secretMarker $negativeRoot
    $report.Add('untrusted_mutation_grant=actual_fixture_acl_rejected_before_import')

    # Simulate the helper's actual untrusted-owner decision; changing an existing owner needs SeSecurityPrivilege on this workstation.
    $helperPath = Join-Path $scripts 'ProtectedBrowserScratch.ps1'
    $ownerControl = Join-Path $fixture 'untrusted-owner.json'
    $ownerRun = Invoke-WithScratchHelperFailure -HelperPath $helperPath -FunctionName 'New-ProtectedBrowserScratchDirectory' -FailureCode 'scratch_path_untrusted_owner' -Invocation {
        Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'success' -Control $ownerControl -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
    }
    $ownerResult = Assert-SingleResult $ownerRun
    Assert-That ($ownerRun.ExitCode -eq 1 -and $ownerResult.failure -eq 'browser_setup_failed' -and -not (Test-Path -LiteralPath ($ownerControl + '.import-called')) -and -not (Test-Path -LiteralPath $ownerControl)) 'untrusted-owner helper failure reached credential import or runner invocation'
    Assert-Sanitized $ownerRun $script:secretMarker $fixture
    $report.Add('untrusted_owner_helper_failure=failed_before_import; actual_owner_mutation_unavailable')

    # A reparse-point scratch base is rejected at the issuer integration boundary.
    $reparseRoot = Join-Path $fixture 'reparse-checkout'
    $null = [IO.Directory]::CreateDirectory((Join-Path $reparseRoot 'scripts'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $reparseRoot 'requests'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $reparseRoot '.scratch'))
    $reparseTarget = Join-Path $reparseRoot 'safe-target'
    $null = [IO.Directory]::CreateDirectory($reparseTarget)
    foreach ($name in @('ProtectedBrowserScratch.ps1', 'ProtectedBrowserRunner.ps1', 'test-identity-issuer-iis.ps1', 'identity-issuer-browser-check.js')) { Copy-Item (Join-Path $PSScriptRoot $name) (Join-Path $reparseRoot 'scripts' $name) }
    Copy-Item (Join-Path $repo 'requests/playwright-cli.iis-test.config.json') (Join-Path $reparseRoot 'requests/playwright-cli.iis-test.config.json')
    Set-Content -LiteralPath (Join-Path $reparseRoot '.gitignore') -Value '.scratch/' -NoNewline
    $null = git -C $reparseRoot init --quiet
    $null = New-Item -ItemType Junction -Path (Join-Path $reparseRoot '.scratch/identity-issuer') -Target $reparseTarget
    $reparseControl = Join-Path $fixture 'reparse-checkout.json'
    $reparseRun = Invoke-IssuerVerifier -Root $reparseRoot -Bin $bin -Mode 'success' -Control $reparseControl -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
    $reparseResult = Assert-SingleResult $reparseRun
    Assert-That ($reparseRun.ExitCode -eq 1 -and $reparseResult.failure -eq 'browser_setup_failed' -and -not (Test-Path -LiteralPath ($reparseControl + '.import-called')) -and -not (Test-Path -LiteralPath $reparseControl)) 'reparse checkout was not rejected before import and runner invocation'
    $report.Add('reparse_redirection=actual_fixture_junction_rejected')

    # Inject only the helper result at the integration seam; actual ACL acceptance remains covered above.
    $collisionControl = Join-Path $fixture 'helper-collision.json'
    $collisionRun = Invoke-WithScratchHelperFailure -HelperPath $helperPath -FunctionName 'New-ProtectedBrowserScratchDirectory' -FailureCode 'scratch_collision' -Invocation {
        Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'success' -Control $collisionControl -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
    }
    $collisionResult = Assert-SingleResult $collisionRun
    Assert-That ($collisionRun.ExitCode -eq 1 -and $collisionResult.failure -eq 'browser_setup_failed' -and -not (Test-Path -LiteralPath ($collisionControl + '.import-called')) -and -not (Test-Path -LiteralPath $collisionControl)) 'helper collision failure reached credential import or runner invocation'
    $report.Add('helper_collision_failure=setup_result_without_import_or_runner')

    $inspectionControl = Join-Path $fixture 'helper-inspection-unavailable.json'
    $inspectionRun = Invoke-WithScratchHelperFailure -HelperPath $helperPath -FunctionName 'Get-BrowserScratchSecurityDescriptor' -FailureCode 'scratch_path_unavailable' -Invocation {
        Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'success' -Control $inspectionControl -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
    }
    $inspectionResult = Assert-SingleResult $inspectionRun
    Assert-That ($inspectionRun.ExitCode -eq 1 -and $inspectionResult.failure -eq 'browser_setup_failed' -and -not (Test-Path -LiteralPath ($inspectionControl + '.import-called')) -and -not (Test-Path -LiteralPath $inspectionControl)) 'unavailable security-descriptor inspection reached credential import or runner invocation'
    Assert-Sanitized $inspectionRun $script:secretMarker $fixture
    $report.Add('unavailable_acl_inspection=helper_failure_rejected_before_import')

    # If the helper unexpectedly throws while deleting, preserve one JSON result and report unknown artifacts as retained.
    $removeControl = Join-Path $fixture 'helper-remove-exception.json'
    $removeRun = Invoke-WithScratchHelperFailure -HelperPath $helperPath -FunctionName 'Remove-ProtectedBrowserScratchDirectory' -FailureCode 'fixture_cleanup_exception' -Invocation {
        Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'success' -Control $removeControl -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
    }
    $removeResult = Assert-SingleResult $removeRun
    Assert-That ($removeRun.ExitCode -eq 1 -and $removeResult.failure -eq 'browser_cleanup_failed' -and $removeResult.cleanupFailures[0] -eq 'scratch_cleanup_failed' -and $removeResult.artifactsRetained) 'throwing cleanup helper bypassed or misreported the final result'
    $removeControlData = Get-Content -LiteralPath $removeControl -Raw | ConvertFrom-Json -AsHashtable
    Assert-That (Test-Path -LiteralPath $removeControlData.RunDirectory) 'throwing cleanup helper did not retain artifacts'
    Assert-ActualAcl $removeControlData.RunDirectory -Directory
    Remove-Item -LiteralPath $removeControlData.RunDirectory -Recurse -Force
    $report.Add('throwing_cleanup_helper=bounded_failure_and_artifacts_retained')

    # Invalid callback origins and paths remain setup failures before any runner call.
    $invalidUrls = @(
        @{ Issuer = 'http://proof.example.test'; Redirect = 'http://proof.example.test/oidc-browser-test/callback' },
        @{ Issuer = 'https://proof.example.test?unexpected=1'; Redirect = 'https://proof.example.test/oidc-browser-test/callback' },
        @{ Issuer = 'https://user@proof.example.test'; Redirect = 'https://user@proof.example.test/oidc-browser-test/callback' },
        @{ Issuer = 'https://proof.example.test'; Redirect = 'https://other.example.test/oidc-browser-test/callback' },
        @{ Issuer = 'https://proof.example.test'; Redirect = 'https://proof.example.test/wrong' },
        @{ Issuer = 'https://proof.example.test'; Redirect = 'http://proof.example.test/oidc-browser-test/callback' }
    )
    foreach ($invalid in $invalidUrls) {
        $controlPath = Join-Path $fixture ('invalid-' + [guid]::NewGuid().ToString('N') + '.json')
        $run = Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'success' -Control $controlPath -Credential $credentialPath -Issuer $invalid.Issuer -Redirect $invalid.Redirect
        $result = Assert-SingleResult $run
        Assert-That ($run.ExitCode -eq 1 -and $result.failure -eq 'browser_setup_failed' -and -not (Test-Path -LiteralPath ($controlPath + '.import-called')) -and -not (Test-Path -LiteralPath $controlPath)) 'invalid issuer/callback URL was accepted before protection or invoked the runner'
    }

    foreach ($mode in @('open-fail', 'run-fail', 'missing-result', 'malformed-result', 'browser-fail', 'close-fail', 'close-throw', 'unsafe-cleanup', 'run-fail,unsafe-cleanup', 'close-fail,unsafe-cleanup', 'delete-fail')) {
        $controlPath = Join-Path $fixture ($mode.Replace(',', '-') + '.json')
        $run = Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode $mode -Control $controlPath -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
        $result = Assert-SingleResult $run
        Assert-Sanitized $run $script:secretMarker $fixture
        if ($mode -in @('close-fail', 'close-throw')) {
            Assert-That ($result.failure -eq 'browser_cleanup_failed' -and $result.cleanupFailures[0] -eq 'browser_close_failed' -and -not $result.Contains('artifactsRetained')) 'close failure was not safely reported'
        } elseif ($mode -eq 'unsafe-cleanup') {
            Assert-That ($result.failure -eq 'browser_cleanup_failed' -and $result.cleanupFailures[0] -eq 'scratch_cleanup_unsafe' -and $result.artifactsRetained) 'unsafe cleanup was not safely reported'
        } elseif ($mode -eq 'close-fail,unsafe-cleanup') {
            Assert-That ($result.cleanupFailures.Count -eq 2 -and $result.cleanupFailures[0] -eq 'browser_close_failed' -and $result.cleanupFailures[1] -eq 'scratch_cleanup_unsafe' -and $result.artifactsRetained) 'cleanup failure order or retention reporting is wrong'
        } elseif ($mode -eq 'delete-fail') {
            Assert-That ($result.failure -eq 'browser_cleanup_failed' -and $result.cleanupFailures[0] -eq 'scratch_cleanup_failed' -and $result.artifactsRetained) 'actual scratch deletion failure was not safely reported'
        } elseif ($mode -eq 'run-fail,unsafe-cleanup') {
            Assert-That ($result.failure -eq 'playwright_run_code_failed' -and $result.cleanupFailures[0] -eq 'scratch_cleanup_unsafe' -and $result.artifactsRetained) 'primary failure was not preserved with unsafe cleanup'
        } elseif ($mode -eq 'open-fail') { Assert-That ($result.failure -eq 'playwright_open_failed') 'open failure meaning changed'
        } elseif ($mode -eq 'run-fail') { Assert-That ($result.failure -eq 'playwright_run_code_failed') 'run-code failure meaning changed'
        } elseif ($mode -eq 'missing-result') { Assert-That ($result.failure -eq 'playwright_result_missing') 'missing-result failure meaning changed'
        } elseif ($mode -eq 'malformed-result') { Assert-That ($result.failure -eq 'browser_runner_runtime_error') 'malformed-result failure meaning changed'
        } elseif ($mode -eq 'browser-fail') { Assert-That ($result.failure -eq 'discovery_status') 'browser-reported failure was not preserved' }
        if ($mode -in @('unsafe-cleanup', 'run-fail,unsafe-cleanup', 'close-fail,unsafe-cleanup')) {
            $control = Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-That (Test-Path -LiteralPath $control.RunDirectory) 'unsafe artifacts were not retained'
            $retainedAcl = Get-Acl -LiteralPath $control.RunDirectory
            $retainedAllows = @($retainedAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -eq Allow | ForEach-Object { $_.IdentityReference.Value })
            Assert-That $retainedAcl.AreAccessRulesProtected 'retained run directory lost its protected DACL'
            Assert-That ($retainedAllows -contains 'S-1-5-11') 'unsafe cleanup fixture did not retain the injected untrusted grant'
            Remove-Item -LiteralPath $control.RunDirectory -Recurse -Force
        } elseif ($mode -notin @('close-fail', 'close-throw', 'delete-fail')) {
            $control = Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-That (-not (Test-Path -LiteralPath $control.RunDirectory)) 'catchable runner failure did not clean generated artifacts'
        } elseif ($mode -in @('close-fail', 'close-throw')) {
            $control = Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-That (-not (Test-Path -LiteralPath $control.RunDirectory)) ('browser-close failure bypassed scratch deletion; mode=' + $mode + '; result=' + $run.Stdout + '; path_exists=' + (Test-Path -LiteralPath $control.RunDirectory))
        }
        if ($mode -eq 'delete-fail') {
            $control = Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-That (Test-Path -LiteralPath $control.RunDirectory) 'failed deletion did not retain its generated directory'
            Assert-ActualAcl $control.RunDirectory -Directory
            Remove-Item -LiteralPath $control.RunDirectory -Recurse -Force
        }
    }
    $report.Add('runner_result_and_cleanup_failures=11_passed')

    # Template, config-template and credential failures all use the same cleanup path.
    $template = Join-Path $scripts 'identity-issuer-browser-check.js'
    Move-Item -LiteralPath $template -Destination ($template + '.held')
    try { $templateRun = Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'success' -Control (Join-Path $fixture 'template-failure.json') -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback' }
    finally { Move-Item -LiteralPath ($template + '.held') -Destination $template }
    $templateResult = Assert-SingleResult $templateRun
    Assert-That ($templateResult.failure -eq 'browser_setup_failed' -and -not (Test-Path -LiteralPath (Join-Path $fixture 'template-failure.json')) -and -not (Test-Path -LiteralPath ((Join-Path $fixture 'template-failure.json') + '.import-called'))) 'template failure did not use setup cleanup before credential import'

    $requestConfig = Join-Path $requests 'playwright-cli.iis-test.config.json'
    Move-Item -LiteralPath $requestConfig -Destination ($requestConfig + '.held')
    try { $configTemplateRun = Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'success' -Control (Join-Path $fixture 'config-template-failure.json') -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback' }
    finally { Move-Item -LiteralPath ($requestConfig + '.held') -Destination $requestConfig }
    $configTemplateResult = Assert-SingleResult $configTemplateRun
    Assert-That ($configTemplateResult.failure -eq 'browser_setup_failed' -and -not (Test-Path -LiteralPath (Join-Path $fixture 'config-template-failure.json')) -and -not (Test-Path -LiteralPath ((Join-Path $fixture 'config-template-failure.json') + '.import-called'))) 'config-template failure did not clean before credential import'

    $watcherPath = Join-Path $fixture 'block-config-write.ps1'
    $watcherSignal = Join-Path $fixture 'config-directory-created.signal'
    @'
param([string]$ScratchBase, [string]$Signal)
$deadline = [DateTime]::UtcNow.AddSeconds(20)
while ([DateTime]::UtcNow -lt $deadline) {
    foreach ($run in @(Get-ChildItem -LiteralPath $ScratchBase -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^playwright-iis-[0-9a-f]{32}$')) {
        $code = Join-Path $run.FullName 'browser-check.js'
        $config = Join-Path $run.FullName 'cli.config.json'
        if ((Test-Path -LiteralPath $code) -and -not (Test-Path -LiteralPath $config)) {
            [IO.Directory]::CreateDirectory($config) | Out-Null
            Set-Content -LiteralPath $Signal -Value 'created' -NoNewline
            exit 0
        }
    }
    Start-Sleep -Milliseconds 5
}
exit 1
'@ | Set-Content -LiteralPath $watcherPath
    $watcherStart = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $watcherStart.UseShellExecute = $false; $watcherStart.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-File', $watcherPath, $scratchBase, $watcherSignal)) { $watcherStart.ArgumentList.Add($argument) }
    $watcher = [Diagnostics.Process]::Start($watcherStart)
    $writeControl = Join-Path $fixture 'config-write-failure.json'
    $writeRun = Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'config-write-fail' -Control $writeControl -Credential $credentialPath -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
    if (-not $watcher.HasExited) { $watcher.Kill($true) }
    $writeResult = Assert-SingleResult $writeRun
    Assert-That ($writeResult.failure -eq 'browser_setup_failed' -and (Test-Path -LiteralPath $watcherSignal) -and (Test-Path -LiteralPath ($writeControl + '.import-called')) -and -not (Test-Path -LiteralPath $writeControl)) 'config-write failure did not clean the generated scratch directory'
    Assert-That (@(Get-ChildItem -LiteralPath $scratchBase -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^playwright-iis-[0-9a-f]{32}$').Count -eq 0) 'config-write failure retained its generated run directory'
    $badCredential = Join-Path $fixture 'malformed-credential.xml'
    Set-Content -LiteralPath $badCredential -Value '<synthetic-invalid-clixml>' -NoNewline
    $credentialRun = Invoke-IssuerVerifier -Root $fixture -Bin $bin -Mode 'success' -Control (Join-Path $fixture 'credential-failure.json') -Credential $badCredential -Issuer 'https://proof.example.test' -Redirect 'https://proof.example.test/oidc-browser-test/callback'
    $credentialResult = Assert-SingleResult $credentialRun
    Assert-That ($credentialResult.failure -eq 'browser_setup_failed' -and (Test-Path -LiteralPath ((Join-Path $fixture 'credential-failure.json') + '.import-called')) -and -not (Test-Path -LiteralPath (Join-Path $fixture 'credential-failure.json'))) ('credential import failure did not use setup cleanup; result=' + $credentialRun.Stdout + '; stderr=' + $credentialRun.Stderr)
    Assert-Sanitized $templateRun $script:secretMarker $fixture
    Assert-Sanitized $credentialRun $script:secretMarker $fixture
    $report.Add('template_config_template_credential_and_config_write_failures=cleaned')

    # Abrupt process termination leaves the actual protected config in place for inspection.
    $signal = Join-Path $fixture 'terminated.signal'
    $workerPid = Join-Path $fixture 'worker.pid'
    $controlPath = Join-Path $fixture 'terminated.json'
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $scripts 'test-identity-issuer-iis.ps1'), '-Issuer', 'https://proof.example.test', '-ClientId', 'fixture-client', '-RedirectUri', 'https://proof.example.test/oidc-browser-test/callback', '-AccessAudience', 'fixture-api', '-CredentialFile', $credentialPath)) { $start.ArgumentList.Add($argument) }
    $start.Environment['PATH'] = $bin + ';' + $env:PATH; $start.Environment['ProgramFiles'] = Join-Path $fixture 'fake-program-files'; $start.Environment['ProgramFiles(x86)'] = Join-Path $fixture 'fake-program-files-x86'
    $start.Environment['ISSUER_STUB_MODE'] = 'terminate'; $start.Environment['ISSUER_STUB_CONTROL'] = $controlPath; $start.Environment['ISSUER_STUB_SECRET'] = $script:secretMarker; $start.Environment['ISSUER_STUB_LOG'] = Join-Path $fixture 'invocations.log'; $start.Environment['ISSUER_STUB_SIGNAL'] = $signal; $start.Environment['ISSUER_STUB_PID_FILE'] = $workerPid
    $worker = [Diagnostics.Process]::Start($start)
    Set-Content -LiteralPath $workerPid -Value $worker.Id -NoNewline
    $stdout = $worker.StandardOutput.ReadToEndAsync(); $stderr = $worker.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $signal) -and -not $worker.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert-That (Test-Path -LiteralPath $signal) 'termination worker did not reach config creation'
    $worker.WaitForExit(15000) | Out-Null
    if (-not $worker.HasExited) { $worker.Kill($true); throw 'termination worker did not stop' }
    $terminated = [pscustomobject]@{ Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult() }
    Assert-Sanitized $terminated $script:secretMarker $fixture
    $control = Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-That (Test-Path -LiteralPath $control.ConfigPath) 'abrupt termination did not retain generated config'
    Assert-ActualAcl $control.RunDirectory -Directory; Assert-ActualAcl $control.CodePath; Assert-ActualAcl $control.ConfigPath
    Assert-That (Test-Path -LiteralPath $credentialPath) 'abrupt termination removed the imported credential file'
    Remove-Item -LiteralPath $control.RunDirectory -Recurse -Force
    $report.Add('abrupt_termination=retained_actual_acl_verified')

    $report | ForEach-Object { Write-Output $_ }
}
finally {
    if ($fixtureCreated) {
        $resolved = [IO.Path]::GetFullPath($fixture)
        if ((Split-Path -Parent $resolved) -ne $profileRoot -or (Split-Path -Leaf $resolved) -ne $fixtureName) { throw 'refusing to remove outside the unique profile fixture' }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
