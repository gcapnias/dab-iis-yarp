param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Release')][string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot 'src/EmbeddedDab/EmbeddedDab.csproj'

. (Join-Path $PSScriptRoot 'Publish-Application.ps1')
Publish-ApplicationSafely -ProjectPath $projectPath -OutputDirectory $OutputDirectory -ApplicationName 'embedded DAB' -Configuration $Configuration
