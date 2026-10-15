param(
    [string]$ArtifactRoot = (Join-Path $env:TEMP ('dab-iis-yarp-ticket-20-' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Publish-Application.ps1')
$fixtureRoot = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) 'fixtures'
$issuerOutput = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) 'issuer'
$issuerEmptyOutput = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) 'issuer-empty'
$apiOutput = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) 'api'
$apiEmptyOutput = Join-Path ([IO.Path]::GetFullPath($ArtifactRoot)) 'api-empty'
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Verification failed: $Message" }
}

function Get-TreeSnapshot {
    param([string]$Path)
    $root = [IO.Path]::GetFullPath($Path)
    @(Get-ChildItem -LiteralPath $root -Force -Recurse | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($root, $_.FullName)
        $hash = if (-not $_.PSIsContainer) { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } else { '' }
        "$relative|$($_.Attributes)|$hash"
    } | Sort-Object)
}

function New-ValidPackageFixture {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Path 'web.config'), '<configuration><system.webServer><aspNetCore processPath="dotnet" arguments=".\App.dll" /></system.webServer></configuration>')
    [IO.File]::WriteAllText((Join-Path $Path 'App.runtimeconfig.json'), '{"runtimeOptions":{"tfm":"net10.0","framework":{"name":"Microsoft.NETCore.App","version":"10.0.0"}}}')
}

$testPatternHex = [Convert]::ToHexString([byte[]]@(0xAB, 0xCD))
Assert-True (-not (Test-ByteSequence -BytesHex '0ABCD0' -PatternHex $testPatternHex -Alignment 1 -StartOffset 0)) 'nibble-shifted PEM marker bytes were accepted'
Assert-True (Test-ByteSequence -BytesHex '0ABCD0ABCD' -PatternHex $testPatternHex -Alignment 1 -StartOffset 0) 'valid byte-aligned marker after a nibble-shifted occurrence was missed'
Write-Output 'PASS: scanner rejects nibble-shifted patterns and continues to the next byte-aligned match'

# Publish entry-point rejection is checked with a dotnet shim. Any unexpected invocation fails the verifier.
$global:ticket20PublishCalls = 0
function global:dotnet {
    $global:ticket20PublishCalls++
    throw 'The publish shim was unexpectedly invoked during a negative destination check.'
}

$destinationCases = @(
    @{ Name = 'ordinary file'; Entry = 'ordinary.txt'; Content = 'ordinary sentinel' },
    @{ Name = 'hidden-only entry'; Entry = '.hidden-sentinel'; Content = 'hidden sentinel' },
    @{ Name = 'synthetic key'; Entry = 'synthetic.pem'; Content = "-----BEGIN PRIVATE KEY-----`nSYNTHETIC-SENTINEL`n-----END PRIVATE KEY-----" },
    @{ Name = 'subdirectory'; Entry = 'nested/sentinel.txt'; Content = 'nested sentinel' }
)
foreach ($case in $destinationCases) {
    $destination = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    $entryPath = Join-Path $destination $case.Entry
    New-Item -ItemType Directory -Path (Split-Path -Parent $entryPath) -Force | Out-Null
    [IO.File]::WriteAllText($entryPath, $case.Content)
    if ($case.Name -eq 'hidden-only entry') {
        [IO.File]::SetAttributes($entryPath, [IO.File]::GetAttributes($entryPath) -bor [IO.FileAttributes]::Hidden)
    }
    $before = Get-TreeSnapshot -Path $destination
    $failed = $false
    foreach ($publisher in @('publish-identity-issuer.ps1', 'publish-embedded-dab.ps1')) {
        $failed = $false
        try { & (Join-Path $PSScriptRoot $publisher) -OutputDirectory $destination } catch { $failed = $true }
        Assert-True $failed "$publisher accepted a $($case.Name) destination"
        Assert-True ($global:ticket20PublishCalls -eq 0) "$publisher rejection for $($case.Name) invoked dotnet publish"
    }
    $after = Get-TreeSnapshot -Path $destination
    Assert-True (($before -join "`n") -ceq ($after -join "`n")) "$($case.Name) destination changed during rejection"
    Write-Output "PASS: rejects $($case.Name) destination and preserves names, attributes and hashes"
}

$fileDestination = Join-Path $fixtureRoot 'destination-file'
[IO.File]::WriteAllText($fileDestination, 'destination sentinel')
$failed = $false
try { & (Join-Path $PSScriptRoot 'publish-identity-issuer.ps1') -OutputDirectory $fileDestination } catch { $failed = $true }
Assert-True $failed 'file destination was accepted'
Assert-True ($global:ticket20PublishCalls -eq 0) 'file destination rejection invoked dotnet publish'

$invalidParent = Join-Path $fixtureRoot 'not-a-directory'
[IO.File]::WriteAllText($invalidParent, 'parent sentinel')
$failed = $false
try { & (Join-Path $PSScriptRoot 'publish-embedded-dab.ps1') -OutputDirectory (Join-Path $invalidParent 'child') } catch { $failed = $true }
Assert-True $failed 'uninspectable parent was accepted'
Assert-True ($global:ticket20PublishCalls -eq 0) 'uninspectable parent rejection invoked dotnet publish'
Remove-Item Function:\dotnet -Force
Write-Output 'PASS: rejects file destinations and inaccessible destination parents before publish'

$failed = $false
try { & (Join-Path $PSScriptRoot 'publish-identity-issuer.ps1') -OutputDirectory (Join-Path $repositoryRoot '.scratch/ticket-20-issuer-inside-checkout') } catch { $failed = $true }
Assert-True $failed 'issuer destination inside source checkout was accepted'
Assert-True ($global:ticket20PublishCalls -eq 0) 'issuer checkout restriction invoked dotnet publish'
Write-Output 'PASS: issuer still rejects output inside the source checkout'

$failed = $false
$failureText = ''
try { Assert-PackageContainsNoRecognizedPrivateKeys -OutputDirectory (Join-Path $fixtureRoot 'missing-package') } catch { $failureText = $_.Exception.Message; $failed = $true }
Assert-True $failed 'package inspection error was accepted'
Assert-True ($failureText -like 'Package validation failed*') 'package inspection failure was not sanitized'
Write-Output 'PASS: package inspection errors fail with a sanitized message'

function global:dotnet {
    $global:ticket20PublishCalls++
    $global:LASTEXITCODE = 17
    $publishArgs = @($args)
    $outputIndex = [Array]::IndexOf($publishArgs, '-o')
    if ($outputIndex -ge 0) {
        New-Item -ItemType Directory -Path $publishArgs[$outputIndex + 1] -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $publishArgs[$outputIndex + 1] 'partial-output.txt'), 'synthetic partial output')
    }
}
$failedPublishPath = Join-Path $fixtureRoot 'failed-publish/deep/output'
$failed = $false
$failureOutput = @()
try { $failureOutput = @(& { Publish-ApplicationSafely -ProjectPath (Join-Path $repositoryRoot 'src/EmbeddedDab/EmbeddedDab.csproj') -OutputDirectory $failedPublishPath -ApplicationName 'synthetic' -Configuration 'Release' } 2>&1) }
catch { $failed = $true; $failureOutput += $_.Exception.Message }
$publishOutput = $failureOutput | Out-String
Assert-True $failed 'failed publish did not report failure'
Assert-True ($global:LASTEXITCODE -eq 17) 'failed publish exit code was not propagated'
Assert-True (-not $publishOutput.Contains('Published and validated')) 'failed publish emitted success output'
Assert-True ($publishOutput.Contains('different empty directory')) 'failed publish did not give sanitized retry guidance'
Remove-Item Function:\dotnet -Force
Write-Output 'PASS: failed publish prevents success output and supports absent nested destinations'

$privateKeyMarkers = @(
    'PRIVATE KEY', 'ENCRYPTED PRIVATE KEY', 'RSA PRIVATE KEY', 'EC PRIVATE KEY', 'DSA PRIVATE KEY', 'OPENSSH PRIVATE KEY'
)
foreach ($marker in $privateKeyMarkers) {
    $package = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    New-ValidPackageFixture -Path $package
    [IO.File]::WriteAllText((Join-Path $package 'marker-without-key-extension.txt'), "-----BEGIN $marker-----`nSYNTHETIC-DO-NOT-USE`n-----END $marker-----")
    $failureText = ''
    try { Assert-ValidApplicationPackage -OutputDirectory $package } catch { $failureText = $_.Exception.Message }
    Assert-True ($failureText.Contains('marker-without-key-extension.txt')) "$marker marker was not detected by filename-independent scan"
    Assert-True (-not $failureText.Contains('SYNTHETIC-DO-NOT-USE')) "$marker sentinel contents leaked into validation output"
    Write-Output "PASS: detects $marker marker without exposing contents"
}

$unicodePackage = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
New-ValidPackageFixture -Path $unicodePackage
[IO.File]::WriteAllBytes((Join-Path $unicodePackage 'utf16-marker.txt'), [Text.Encoding]::Unicode.GetBytes("-----BEGIN PRIVATE KEY-----`nSYNTHETIC-UNICODE-SENTINEL"))
$failureText = ''
try { Assert-ValidApplicationPackage -OutputDirectory $unicodePackage } catch { $failureText = $_.Exception.Message }
Assert-True ($failureText.Contains('utf16-marker.txt')) 'UTF-16 PEM marker was not detected'
Write-Output 'PASS: detects UTF-16 PEM marker'

$boundaryPackage = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
New-ValidPackageFixture -Path $boundaryPackage
$boundaryText = ('A' * 8190) + "-----BEGIN PRIVATE KEY-----`nSYNTHETIC-BOUNDARY-SENTINEL"
[IO.File]::WriteAllText((Join-Path $boundaryPackage 'boundary-marker.txt'), $boundaryText, [Text.Encoding]::ASCII)
$failureText = ''
try { Assert-ValidApplicationPackage -OutputDirectory $boundaryPackage } catch { $failureText = $_.Exception.Message }
Assert-True ($failureText.Contains('boundary-marker.txt')) 'PEM marker spanning a scan chunk boundary was not detected'
Assert-True (-not $failureText.Contains('SYNTHETIC-BOUNDARY-SENTINEL')) 'boundary sentinel contents leaked into validation output'
Write-Output 'PASS: detects PEM marker spanning an 8192-byte scan boundary without exposing contents'

foreach ($extension in @('.pfx', '.p12', '.snk', '.key', '.PFX', '.P12', '.SNK', '.KEY')) {
    $package = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    New-ValidPackageFixture -Path $package
    [IO.File]::WriteAllText((Join-Path $package "synthetic$extension"), 'SYNTHETIC-CONTAINER-SENTINEL')
    $failureText = ''
    try { Assert-ValidApplicationPackage -OutputDirectory $package } catch { $failureText = $_.Exception.Message }
    Assert-True ($failureText.Contains("synthetic$extension")) "$extension file was not rejected"
    Assert-True (-not $failureText.Contains('SYNTHETIC-CONTAINER-SENTINEL')) "$extension contents leaked into validation output"
    Write-Output "PASS: rejects $extension without exposing contents"
}

$publicPackage = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
New-ValidPackageFixture -Path $publicPackage
[IO.File]::WriteAllText((Join-Path $publicPackage 'public-cert.pem'), "-----BEGIN CERTIFICATE-----`nSYNTHETIC-PUBLIC-CERTIFICATE`n-----END CERTIFICATE-----`n-----BEGIN PUBLIC KEY-----`nSYNTHETIC-PUBLIC-KEY`n-----END PUBLIC KEY-----")
Assert-ValidApplicationPackage -OutputDirectory $publicPackage
Write-Output 'PASS: public certificate and public-key PEM pass private-key scan'

$missingConfigPackage = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $missingConfigPackage | Out-Null
[IO.File]::WriteAllText((Join-Path $missingConfigPackage 'App.runtimeconfig.json'), '{"runtimeOptions":{}}')
$failed = $false
try { Assert-ValidApplicationPackage -OutputDirectory $missingConfigPackage } catch { $failed = $true }
Assert-True $failed 'package without web.config was accepted'
Write-Output 'PASS: package missing generated web.config fails validation'

# Real integration publishes use unique output folders; absent and empty cases are retained for inspection.
& (Join-Path $PSScriptRoot 'publish-identity-issuer.ps1') -OutputDirectory $issuerOutput
New-Item -ItemType Directory -Path $issuerEmptyOutput | Out-Null
& (Join-Path $PSScriptRoot 'publish-identity-issuer.ps1') -OutputDirectory $issuerEmptyOutput
& (Join-Path $PSScriptRoot 'publish-embedded-dab.ps1') -OutputDirectory $apiOutput
New-Item -ItemType Directory -Path $apiEmptyOutput | Out-Null
& (Join-Path $PSScriptRoot 'publish-embedded-dab.ps1') -OutputDirectory $apiEmptyOutput
Write-Output "PASS: fresh Release publishes validated for absent and empty destinations for both applications; retained at $ArtifactRoot"
Write-Output 'Package check limit: supported PEM markers and key-container extensions only; arbitrary encoded or embedded secrets are outside the scan policy.'
