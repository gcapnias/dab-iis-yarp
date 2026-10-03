param(
    [string]$DotEnvFile = ''
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitCommonDirectory = (& git -C $repositoryRoot rev-parse --path-format=absolute --git-common-dir).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot find the primary Git checkout for this worktree.' }
$primaryRoot = Split-Path -Parent $gitCommonDirectory
if ([string]::IsNullOrWhiteSpace($DotEnvFile)) { $DotEnvFile = Join-Path $primaryRoot '.env' }
$testProject = Join-Path $repositoryRoot 'tests/EmbeddedDab.Tests/EmbeddedDab.Tests.csproj'
$embeddedProject = Join-Path $repositoryRoot 'src/EmbeddedDab/EmbeddedDab.csproj'
$embeddedAssembly = Join-Path $repositoryRoot 'src/EmbeddedDab/bin/Release/net10.0/EmbeddedDab.dll'
$environmentNames = @('DAB_ENV_FILE', 'DAB_FIXTURE_DATABASE', 'DAB_CONNECTION_STRING', 'DAB_CONFIG_FILE', 'DAB_INITIALIZE', 'DAB_TEST_ISSUER')
$oldEnvironment = @{}
foreach ($name in $environmentNames) { $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

$databaseName = 'dab_ticket9_' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$fixtureCreated = $false

try {
    if (-not (Test-Path -LiteralPath $DotEnvFile)) { throw "Dotenv file not found: $DotEnvFile" }
    dotnet build $embeddedProject --configuration Release --verbosity minimal
    if ($LASTEXITCODE -ne 0) { throw 'Embedded DAB build failed.' }

    Remove-Item Env:DAB_CONNECTION_STRING -ErrorAction SilentlyContinue
    $env:DAB_ENV_FILE = [System.IO.Path]::GetFullPath($DotEnvFile)
    $env:DAB_FIXTURE_DATABASE = $databaseName
    dotnet $embeddedAssembly --prepare-fixture $databaseName
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the disposable JWT interoperability database.' }
    $fixtureCreated = $true

    Remove-Item Env:DAB_CONNECTION_STRING -ErrorAction SilentlyContinue
    $env:DAB_ENV_FILE = [System.IO.Path]::GetFullPath($DotEnvFile)
    $env:DAB_FIXTURE_DATABASE = $databaseName
    dotnet test $testProject --configuration Release --verbosity minimal
    if ($LASTEXITCODE -ne 0) { throw 'JWT interoperability tests failed.' }
}
finally {
    if ($fixtureCreated) {
        Remove-Item Env:DAB_CONNECTION_STRING -ErrorAction SilentlyContinue
        $env:DAB_ENV_FILE = [System.IO.Path]::GetFullPath($DotEnvFile)
        dotnet $embeddedAssembly --cleanup-fixture $databaseName
        if ($LASTEXITCODE -ne 0) { Write-Warning "JWT fixture cleanup failed; database name: $databaseName" }
    }

    foreach ($name in $environmentNames) {
        if ($null -eq $oldEnvironment[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process') }
    }
}
