Set-StrictMode -Version Latest

function Assert-EmptyPublishDestination {
    param([Parameter(Mandatory)][string]$OutputDirectory)

    $outputPath = [IO.Path]::GetFullPath($OutputDirectory)
    try {
        $ancestorPath = [IO.Path]::GetDirectoryName($outputPath)
        $destination = $null
        try {
            $destination = Get-Item -LiteralPath $outputPath -Force -ErrorAction Stop
        }
        catch {
            if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound) { throw }
        }
        while ($null -eq $destination -and -not [string]::IsNullOrWhiteSpace($ancestorPath)) {
            try {
                $ancestor = Get-Item -LiteralPath $ancestorPath -Force -ErrorAction Stop
                break
            }
            catch {
                if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound) { throw }
                $ancestorPath = [IO.Path]::GetDirectoryName($ancestorPath)
            }
        }
        if ($null -eq $destination -and ($null -eq $ancestor -or [string]::IsNullOrWhiteSpace($ancestorPath))) {
            throw 'The publish destination parent is unavailable.'
        }
        if ($null -ne $destination) {
            if (-not $destination.PSIsContainer) {
                throw 'The publish destination must be a directory.'
            }
            if (($destination.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The publish destination must be a regular directory.'
            }

            $existingEntry = Get-ChildItem -LiteralPath $outputPath -Force -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $existingEntry) {
                throw 'The publish destination must be absent or empty. Choose another empty directory; existing files were left unchanged.'
            }
        }
        else {
            if (-not $ancestor.PSIsContainer) { throw 'The publish destination parent is not a directory.' }
            # Enumerating the nearest existing ancestor distinguishes an absent path from an inaccessible location.
            [void](Get-ChildItem -LiteralPath $ancestorPath -Force -ErrorAction Stop | Select-Object -First 1)
        }
    }
    catch {
        if ($_.Exception.Message -like 'The publish destination*') { throw }
        throw 'Unable to inspect the publish destination. Choose an accessible absent or empty directory; existing files were left unchanged.'
    }
}

function Test-ByteSequence {
    param(
        [Parameter(Mandatory)][string]$BytesHex,
        [Parameter(Mandatory)][string]$PatternHex,
        [Parameter(Mandatory)][int]$Alignment,
        [Parameter(Mandatory)][long]$StartOffset
    )

    $searchFrom = 0
    while (($matchAt = $BytesHex.IndexOf($PatternHex, $searchFrom, [StringComparison]::Ordinal)) -ge 0) {
        if (($matchAt % 2) -ne 0) {
            $searchFrom = $matchAt + 1
            continue
        }
        if ((($StartOffset + [long]($matchAt / 2)) % $Alignment) -eq 0) { return $true }
        $searchFrom = $matchAt + 2
    }
    return $false
}

function Find-PrivateKeyMarkers {
    param([Parameter(Mandatory)][string]$FilePath)

    $markerTexts = @(
        '-----BEGIN PRIVATE KEY-----',
        '-----BEGIN ENCRYPTED PRIVATE KEY-----',
        '-----BEGIN RSA PRIVATE KEY-----',
        '-----BEGIN EC PRIVATE KEY-----',
        '-----BEGIN DSA PRIVATE KEY-----',
        '-----BEGIN OPENSSH PRIVATE KEY-----'
    )
    $markers = [Collections.Generic.List[object]]::new()
    foreach ($markerText in $markerTexts) {
        $asciiBytes = [Text.Encoding]::ASCII.GetBytes($markerText)
        $unicodeBytes = [Text.Encoding]::Unicode.GetBytes($markerText)
        $bigEndianBytes = [Text.Encoding]::BigEndianUnicode.GetBytes($markerText)
        $markers.Add([pscustomobject]@{ ByteLength = $asciiBytes.Length; Hex = [Convert]::ToHexString($asciiBytes); Alignment = 1 })
        $markers.Add([pscustomobject]@{ ByteLength = $unicodeBytes.Length; Hex = [Convert]::ToHexString($unicodeBytes); Alignment = 2 })
        $markers.Add([pscustomobject]@{ ByteLength = $bigEndianBytes.Length; Hex = [Convert]::ToHexString($bigEndianBytes); Alignment = 2 })
    }
    $maxMarkerLength = ($markers | ForEach-Object { $_.ByteLength } | Measure-Object -Maximum).Maximum
    $buffer = [byte[]]::new(8192)
    $carry = [byte[]]::new(0)
    $totalBytesRead = [long]0
    $stream = $null
    try {
        $stream = [IO.File]::Open($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $combinedStartOffset = $totalBytesRead - $carry.Length
            $combined = [byte[]]::new($carry.Length + $read)
            [Array]::Copy($carry, 0, $combined, 0, $carry.Length)
            [Array]::Copy($buffer, 0, $combined, $carry.Length, $read)
            $totalBytesRead += $read
            $combinedHex = [Convert]::ToHexString($combined)
            foreach ($marker in $markers) {
                if (Test-ByteSequence -BytesHex $combinedHex -PatternHex $marker.Hex -Alignment $marker.Alignment -StartOffset $combinedStartOffset) { return $true }
            }

            $carryLength = [Math]::Min($maxMarkerLength - 1, $combined.Length)
            $carry = [byte[]]::new($carryLength)
            [Array]::Copy($combined, $combined.Length - $carryLength, $carry, 0, $carryLength)
        }
        return $false
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-FrameworkDependentPackage {
    param([Parameter(Mandatory)][string]$OutputDirectory)

    $webConfigPath = Join-Path $OutputDirectory 'web.config'
    $runtimeConfig = Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.runtimeconfig.json' -File -Force -ErrorAction Stop | Select-Object -First 1
    if (-not (Test-Path -LiteralPath $webConfigPath -PathType Leaf -ErrorAction Stop) -or $null -eq $runtimeConfig) {
        throw 'Package validation failed: generated web.config or framework-dependent runtime configuration is missing.'
    }

    try {
        [xml]$webConfig = [IO.File]::ReadAllText($webConfigPath)
        $aspNetCore = $webConfig.SelectSingleNode('//system.webServer/aspNetCore')
        if ($null -eq $aspNetCore -or $aspNetCore.processPath -ne 'dotnet' -or [string]::IsNullOrWhiteSpace($aspNetCore.arguments)) {
            throw 'invalid framework-dependent configuration'
        }
        $runtimeOptions = [IO.File]::ReadAllText($runtimeConfig.FullName) | ConvertFrom-Json -ErrorAction Stop
        $runtimeSettings = $runtimeOptions.runtimeOptions
        $tfmProperty = $runtimeSettings.PSObject.Properties['tfm']
        $frameworkProperty = $runtimeSettings.PSObject.Properties['framework']
        $frameworksProperty = $runtimeSettings.PSObject.Properties['frameworks']
        $hasFramework = $false
        if ($null -ne $frameworkProperty -and $null -ne $frameworkProperty.Value) {
            $hasFramework = -not [string]::IsNullOrWhiteSpace($frameworkProperty.Value.name) -and
                -not [string]::IsNullOrWhiteSpace($frameworkProperty.Value.version)
        }
        if ($null -ne $frameworksProperty -and $null -ne $frameworksProperty.Value) {
            $frameworkEntries = @($frameworksProperty.Value)
            $hasFramework = $frameworkEntries.Count -gt 0
            foreach ($frameworkEntry in $frameworkEntries) {
                if ([string]::IsNullOrWhiteSpace($frameworkEntry.name) -or [string]::IsNullOrWhiteSpace($frameworkEntry.version)) {
                    $hasFramework = $false
                    break
                }
            }
        }
        if ($null -eq $runtimeSettings -or $null -eq $tfmProperty -or $tfmProperty.Value -notlike 'net*' -or -not $hasFramework) {
            throw 'invalid framework-dependent runtime configuration'
        }
    }
    catch {
        throw 'Package validation failed: generated web.config is missing or is not a framework-dependent ASP.NET Core configuration.'
    }
}

function Assert-PackageContainsNoRecognizedPrivateKeys {
    param([Parameter(Mandatory)][string]$OutputDirectory)

    $outputPath = [IO.Path]::GetFullPath($OutputDirectory)
    $blockedExtensions = @('.pfx', '.p12', '.snk', '.key')
    $offenders = [Collections.Generic.List[string]]::new()
    try {
        $entries = @(Get-ChildItem -LiteralPath $outputPath -Force -Recurse -ErrorAction Stop)
        foreach ($entry in $entries) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Package inspection encountered a reparse point.'
            }
        }
        $files = @($entries | Where-Object { -not $_.PSIsContainer })
        foreach ($file in $files) {
            $relativePath = [IO.Path]::GetRelativePath($outputPath, $file.FullName)
            if ($blockedExtensions -ccontains $file.Extension.ToLowerInvariant()) {
                $offenders.Add($relativePath)
                continue
            }
            if (Find-PrivateKeyMarkers -FilePath $file.FullName) {
                $offenders.Add($relativePath)
            }
        }
    }
    catch {
        throw 'Package validation failed because one or more files could not be inspected.'
    }

    if ($offenders.Count -gt 0) {
        $paths = ($offenders | Sort-Object -Unique) -join ', '
        throw "Package validation found recognizable private-key material in: $paths"
    }
}

function Assert-ValidApplicationPackage {
    param([Parameter(Mandatory)][string]$OutputDirectory)

    try {
        Test-FrameworkDependentPackage -OutputDirectory $OutputDirectory
        Assert-PackageContainsNoRecognizedPrivateKeys -OutputDirectory $OutputDirectory
    }
    catch {
        if ($_.Exception.Message -like 'Package validation*') { throw }
        throw 'Package validation failed because package contents could not be inspected.'
    }
}

function Publish-ApplicationSafely {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ApplicationName,
        [Parameter(Mandatory)][string]$Configuration
    )

    $outputPath = [IO.Path]::GetFullPath($OutputDirectory)
    Assert-EmptyPublishDestination -OutputDirectory $outputPath

    & dotnet publish $ProjectPath -c $Configuration --no-self-contained -o $outputPath
    if ($LASTEXITCODE -ne 0) {
        throw "$ApplicationName publish failed with exit code $LASTEXITCODE. The destination may contain partial output; use a different empty directory for a retry."
    }

    Assert-ValidApplicationPackage -OutputDirectory $outputPath
    Write-Output "Published and validated $ApplicationName files at $outputPath."
    Write-Output 'The package scan rejects supported PEM private-key markers and .pfx, .p12, .snk and .key files; it cannot detect arbitrary encoded or embedded secrets. Provision private keys and environment secrets separately through the protected operator procedure.'
}
