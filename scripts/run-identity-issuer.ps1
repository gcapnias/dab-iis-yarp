param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Url = "https://localhost:5001",
    [switch]$ProvisionBrowserClient
)

$ErrorActionPreference = "Stop"
$environmentNames = @(
    "ConnectionStrings__IssuerIdentity",
    "Issuer__SigningKeyPath",
    "Issuer__EncryptionKeyPath",
    "Issuer__Url",
    "DOTNET_ENVIRONMENT",
    "Oidc__ClientId",
    "Oidc__RedirectUri"
)
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$commonGitDirectory = git -C $RepositoryRoot rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve the primary repository from this checkout."
}
$primaryRoot = Split-Path -Parent $commonGitDirectory
$project = Join-Path $RepositoryRoot "src/IdentityIssuer/IdentityIssuer.csproj"
$envFile = Join-Path $primaryRoot ".env"
$keyDirectory = Join-Path $primaryRoot ".scratch/identity-issuer/keys"
$keyPath = Join-Path $keyDirectory "issuer-private.pem"
$encryptionKeyPath = Join-Path $keyDirectory "issuer-encryption.pem"

$connectionString = $env:ConnectionStrings__IssuerIdentity
if (Test-Path -LiteralPath $envFile) {
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match '^\s*ConnectionString\s*=\s*(.*)\s*$') {
            $connectionString = $matches[1].Trim()
            if ($connectionString.Length -ge 2 -and (($connectionString[0] -eq '"' -and $connectionString[-1] -eq '"') -or ($connectionString[0] -eq "'" -and $connectionString[-1] -eq "'"))) {
                $connectionString = $connectionString.Substring(1, $connectionString.Length - 2)
            }
            break
        }
    }
}

$ignored = git -C $primaryRoot check-ignore --quiet ".scratch/identity-issuer/keys/issuer-private.pem"
$signingIgnored = $LASTEXITCODE -eq 0
$ignored = git -C $primaryRoot check-ignore --quiet ".scratch/identity-issuer/keys/issuer-encryption.pem"
$encryptionIgnored = $LASTEXITCODE -eq 0
if (-not $signingIgnored -or -not $encryptionIgnored) {
    throw "The private key paths are not ignored by Git; refusing to create keys or launch."
}

New-Item -ItemType Directory -Path $keyDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $keyPath)) {
    $rsa = [System.Security.Cryptography.RSA]::Create(3072)
    try {
        [System.IO.File]::WriteAllText($keyPath, $rsa.ExportPkcs8PrivateKeyPem())
    }
    finally {
        $rsa.Dispose()
    }
}
if (-not (Test-Path -LiteralPath $encryptionKeyPath)) {
    $rsa = [System.Security.Cryptography.RSA]::Create(3072)
    try {
        [System.IO.File]::WriteAllText($encryptionKeyPath, $rsa.ExportPkcs8PrivateKeyPem())
    }
    finally {
        $rsa.Dispose()
    }
}

dotnet dev-certs https --check *> $null
if ($LASTEXITCODE -ne 0) {
    throw "A valid HTTPS development certificate is not available. Use the documented manual certificate setup; this script does not install or trust certificates."
}

$pushedLocation = $false
try {
    if (-not [string]::IsNullOrWhiteSpace($connectionString)) {
        $env:ConnectionStrings__IssuerIdentity = $connectionString
    }
    $env:Issuer__SigningKeyPath = $keyPath
    $env:Issuer__EncryptionKeyPath = $encryptionKeyPath
    $env:Issuer__Url = $Url
    $env:DOTNET_ENVIRONMENT = "Development"
    if ($ProvisionBrowserClient) {
        $env:Oidc__ClientId = "dab-issuer-browser-test-client"
        $env:Oidc__RedirectUri = $Url.TrimEnd('/') + "/oidc-browser-test/callback"
    }
    Push-Location $RepositoryRoot
    $pushedLocation = $true
    if ($ProvisionBrowserClient) {
        dotnet run --project $project -- --provision-oidc-client
    }
    else {
        dotnet run --project $project --urls $Url
    }
    if ($LASTEXITCODE -ne 0) {
        throw "The issuer exited with code $LASTEXITCODE."
    }
}
finally {
    if ($pushedLocation) { Pop-Location }
    foreach ($name in $environmentNames) {
        if ($null -eq $originalEnvironment[$name]) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
        }
    }
}
