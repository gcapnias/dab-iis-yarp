param(
    [Parameter(Mandatory)][uri]$Issuer,
    [Parameter(Mandatory)][uri]$Api,
    [Parameter(Mandatory)][string]$CredentialFile,
    [Parameter(Mandatory)][string]$SigningKeyFile,
    [switch]$ValidateServerCertificate
)

# Use only the explicitly provisioned proof issuer's key. Values never enter results.
$ErrorActionPreference = 'Stop'
foreach ($endpoint in @($Issuer, $Api)) {
    if ($endpoint.Scheme -ne 'https' -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment) {
        throw 'HTTPS application URLs without credentials, query or fragment are required.'
    }
}
if ($Issuer.DnsSafeHost -ne $Api.DnsSafeHost) { throw 'Use the identified same-host IIS proof topology.' }
$requestOptions = @{ NoProxy = $true; TimeoutSec = 30; SkipCertificateCheck = -not [bool]$ValidateServerCertificate }
$issuerBase = $Issuer.AbsoluteUri.TrimEnd('/')
$apiBase = $Api.AbsoluteUri.TrimEnd('/')
$credential = Import-Clixml -LiteralPath $CredentialFile
$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$rsa = [Security.Cryptography.RSA]::Create()
$results = [ordered]@{}

function Encode-Base64Url([byte[]]$bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}
function Read-JwtPart([string]$part) {
    $base64 = $part.Replace('-','+').Replace('_','/')
    $base64 = $base64.PadRight($base64.Length + ((4 - $base64.Length % 4) % 4), '=')
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64)) | ConvertFrom-Json -AsHashtable
}
function Read-ResponseJson($response) {
    $content = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { $response.Content }
    $content | ConvertFrom-Json
}
function New-ProofToken([hashtable]$claims, [hashtable]$header, [Security.Cryptography.RSA]$signingRsa = $rsa) {
    $unsigned = (Encode-Base64Url ([Text.Encoding]::UTF8.GetBytes(($header | ConvertTo-Json -Compress)))) + '.' +
        (Encode-Base64Url ([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress -Depth 8))))
    $signature = $signingRsa.SignData([Text.Encoding]::ASCII.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $unsigned + '.' + (Encode-Base64Url $signature)
}
function Check-Access([string]$name, [string]$token, [string]$role, [bool]$allowed) {
    $headers = @{}
    if ($token) { $headers.Authorization = 'Bearer ' + $token }
    if ($role) { $headers['X-MS-API-ROLE'] = $role }
    $rest = Invoke-WebRequest "$apiBase/api/Products?`$first=2" -Headers $headers -SkipHttpErrorCheck @requestOptions
    $query = [uri]::EscapeDataString('{ products(first: 2) { items { ProductID ProductName } } }')
    $graph = Invoke-WebRequest "$apiBase/graphql?query=$query" -Headers $headers -SkipHttpErrorCheck @requestOptions
    $graphDenied = $graph.StatusCode -in 400,401,403
    if (-not $graphDenied -and $graph.StatusCode -eq 200) {
        $body = Read-ResponseJson $graph
        $graphDenied = [bool]$body.errors -and -not $body.data.products
    }
    if ($allowed) {
        $restBody = Read-ResponseJson $rest
        $graphBody = Read-ResponseJson $graph
        $results[$name + '_rest'] = $rest.StatusCode -eq 200 -and $restBody.value[0].ProductName -eq 'Chai'
        $results[$name + '_graphql'] = $graph.StatusCode -eq 200 -and -not $graphBody.errors -and $graphBody.data.products.items[0].ProductName -eq 'Chai'
    } else {
        $results[$name + '_rest'] = $rest.StatusCode -in 401,403
        $results[$name + '_graphql'] = $graphDenied
    }
    if (-not $results[$name + '_rest'] -or -not $results[$name + '_graphql']) { throw "Failed acceptance case: $name" }
}

try {
    $csrf = Invoke-RestMethod "$issuerBase/csrf" -Credential $credential -WebSession $session @requestOptions
    $null = Invoke-WebRequest "$issuerBase/session" -Method Post -Credential $credential -WebSession $session -Headers @{ 'X-CSRF-TOKEN' = $csrf.requestToken } @requestOptions
    $access = $session.Cookies.GetCookies($Issuer)['dab_access_token']
    if (-not $access) { throw 'The real Windows/Identity issuer session did not return an access cookie.' }
    $parts = $access.Value.Split('.')
    $header = Read-JwtPart $parts[0]
    $claims = Read-JwtPart $parts[1]
    $rsa.ImportFromPem([IO.File]::ReadAllText((Resolve-Path $SigningKeyFile).Path))
    $jwks = Invoke-RestMethod "$issuerBase/.well-known/jwks" @requestOptions
    $public = $rsa.ExportParameters($false)
    if (-not @($jwks.keys | Where-Object { $_.kid -eq $header.kid -and $_.n -eq (Encode-Base64Url $public.Modulus) }).Count) {
        throw 'The supplied proof key does not match the actual issuer JWKS.'
    }
    Check-Access real_reader $access.Value reader $true
    Check-Access real_writer $access.Value writer $true
    Check-Access missing_token '' reader $false
    Check-Access malformed_token 'not.a.jwt' reader $false
    Check-Access ungranted_role $access.Value ungranted-iis-proof-role $false
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($case in @('expired','future','wrong_audience','wrong_issuer','no_roles','unknown_key')) {
        $modified = $claims.Clone()
        $modifiedHeader = $header.Clone()
        switch ($case) {
            expired { $modified.iat = $now - 1800; $modified.nbf = $now - 1800; $modified.exp = $now - 1200 }
            future { $modified.nbf = $now + 1200; $modified.exp = $now + 1800 }
            wrong_audience { $modified.aud = 'api://wrong-iis-proof-audience' }
            wrong_issuer { $modified.iss = 'https://wrong-issuer.invalid/' }
            no_roles { $modified.Remove('roles'); $modified.Remove('role') }
            unknown_key { $modifiedHeader.kid = 'unknown-iis-proof-key' }
        }
        if ($case -eq 'unknown_key') {
            $unknownRsa = [Security.Cryptography.RSA]::Create(3072)
            try { $token = New-ProofToken $modified $modifiedHeader $unknownRsa } finally { $unknownRsa.Dispose() }
        } else {
            $token = New-ProofToken $modified $modifiedHeader
        }
        Check-Access $case $token reader $false
    }
    $badParts = $access.Value.Split('.')
    # Replace all signature bytes so this cannot accidentally preserve a valid signature.
    $badParts[2] = Encode-Base64Url ([Security.Cryptography.RandomNumberGenerator]::GetBytes(384))
    Check-Access invalid_signature ($badParts -join '.') reader $false
} catch {
    $results.failure = if ($_.Exception.Message -like 'Failed acceptance case:*') { $_.Exception.Message } else { 'iis_token_validation_failed' }
} finally {
    try {
        if ($session.Cookies.GetCookies($Issuer)['dab_access_token']) {
            $csrf = Invoke-RestMethod "$issuerBase/csrf" -Credential $credential -WebSession $session @requestOptions
            $null = Invoke-WebRequest "$issuerBase/session/logout" -Method Post -Credential $credential -WebSession $session -Headers @{ 'X-CSRF-TOKEN' = $csrf.requestToken } @requestOptions
        }
    } catch { $results.logout_failure = $true }
    $rsa.Dispose()
}
$results | ConvertTo-Json -Depth 4
if ($results.failure -or $results.logout_failure) { exit 1 }
