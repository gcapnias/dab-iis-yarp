param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Release')][string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$projectPath = Join-Path $repositoryRoot 'src/IdentityIssuer/IdentityIssuer.csproj'
$repositoryPath = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

if ($outputPath.StartsWith($repositoryPath, [StringComparison]::OrdinalIgnoreCase) -or
    $outputPath.Equals($repositoryPath.TrimEnd([IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose a deployment output directory outside the source checkout.'
}

. (Join-Path $PSScriptRoot 'Publish-Application.ps1')
Publish-ApplicationSafely -ProjectPath $projectPath -OutputDirectory $outputPath -ApplicationName 'issuer' -Configuration $Configuration
