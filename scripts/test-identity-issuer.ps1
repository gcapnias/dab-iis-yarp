param([string]$Issuer = "https://localhost:5001")

$ErrorActionPreference = "Stop"
$issuerUri = [Uri]$Issuer
if ($issuerUri.Scheme -ne "https" -or $issuerUri.Host -ne "localhost") {
    throw "This development harness only accepts the HTTPS localhost issuer."
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Run this harness with PowerShell 7 or newer."
}

function Assert-Check([bool]$Condition, [string]$Failure) {
    if (-not $Condition) { throw $Failure }
}

function Invoke-IssuerRequest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Method,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
        [hashtable]$Headers,
        [object]$Body,
        [string]$ContentType,
        [switch]$WindowsCredentials,
        [int]$MaximumRedirection = 5
    )

    $parameters = @{
        Uri = "$($issuerUri.AbsoluteUri.TrimEnd('/'))$Path"
        Method = $Method
        SkipCertificateCheck = $true
        MaximumRedirection = $MaximumRedirection
        ErrorAction = "Stop"
    }
    if ($WindowsCredentials) { $parameters.UseDefaultCredentials = $true }
    if ($null -ne $WebSession) { $parameters.WebSession = $WebSession }
    if ($null -ne $Headers) { $parameters.Headers = $Headers }
    if ($null -ne $Body) { $parameters.Body = $Body }
    if ($null -ne $ContentType) { $parameters.ContentType = $ContentType }

    try {
        $response = Invoke-WebRequest @parameters
        return [PSCustomObject]@{
            Status = [int]$response.StatusCode
            Content = $response.Content
            Headers = $response.Headers
        }
    }
    catch {
        $response = $_.Exception.Response
        if ($null -eq $response) { throw "Issuer request failed without an HTTP response." }
        $status = [int]$response.StatusCode
        $content = ""
        try { $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
        return [PSCustomObject]@{
            Status = $status
            Content = $content
            Headers = $response.Headers
        }
    }
}

function ConvertFrom-Base64Url([string]$Value) {
    $normalized = $Value.Replace('-', '+').Replace('_', '/')
    return [Convert]::FromBase64String($normalized.PadRight($normalized.Length + ((4 - $normalized.Length % 4) % 4), '='))
}

function Test-Rs256Token {
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Audience)
    $parts = $Token.Split('.')
    Assert-Check ($parts.Length -eq 3) "A signed compact JWT was not issued."
    $header = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[0])) | ConvertFrom-Json
    $payload = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[1])) | ConvertFrom-Json
    $jwk = $script:publishedKeys.keys | Where-Object kid -eq $header.kid | Select-Object -First 1
    Assert-Check ($null -ne $jwk) "The JWT signing key is absent from published JWKS."

    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportParameters([Security.Cryptography.RSAParameters]@{
            Modulus = ConvertFrom-Base64Url $jwk.n
            Exponent = ConvertFrom-Base64Url $jwk.e
        })
        $unsigned = [Text.Encoding]::ASCII.GetBytes("$($parts[0]).$($parts[1])")
        $signatureValid = $rsa.VerifyData(
            $unsigned,
            (ConvertFrom-Base64Url $parts[2]),
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
    finally { $rsa.Dispose() }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return [PSCustomObject]@{
        SignatureValid = $signatureValid
        IssuerValid = ($payload.iss -eq $script:metadata.issuer)
        AudienceValid = (@($payload.aud) -contains $Audience)
        LifetimeValid = ([long]$payload.exp -gt $now)
        HasSubject = (-not [string]::IsNullOrWhiteSpace($payload.sub))
        HasProfile = (-not [string]::IsNullOrWhiteSpace($payload.profile_id))
        HasRole = ((@($payload.roles).Count -gt 0) -or (@($payload.role).Count -gt 0))
        HasClearanceClaim = ($payload.ClearanceLevel -eq "Level3")
    }
}

$results = [ordered]@{}
$metadataResponse = Invoke-IssuerRequest -Path "/.well-known/openid-configuration" -Method GET
$results.DiscoveryStatus = $metadataResponse.Status
Assert-Check ($metadataResponse.Status -eq 200) "OIDC discovery did not return 200."
$script:metadata = $metadataResponse.Content | ConvertFrom-Json
$supportedClaims = @($script:metadata.claims_supported)
$expectedClaims = @("role", "profile_id", "ClearanceLevel")
$results.MetadataContainsIssuerClaimContract = (@($expectedClaims | Where-Object { $supportedClaims -contains $_ }).Count -eq $expectedClaims.Count)
Assert-Check $results.MetadataContainsIssuerClaimContract "Discovery does not list the emitted persisted role/profile claim contract."
$jwksResponse = Invoke-IssuerRequest -Path "/.well-known/jwks" -Method GET
$results.JwksStatus = $jwksResponse.Status
Assert-Check ($jwksResponse.Status -eq 200) "JWKS did not return 200 anonymously."
$script:publishedKeys = $jwksResponse.Content | ConvertFrom-Json

$anonymousCsrf = Invoke-IssuerRequest -Path "/csrf" -Method GET
$results.AnonymousCsrfStatus = $anonymousCsrf.Status
Assert-Check ($anonymousCsrf.Status -eq 401) "Anonymous CSRF access was not denied."
$diagnostic = Invoke-IssuerRequest -Path "/diagnostics/windows-auth" -Method GET -WindowsCredentials
$identity = $diagnostic.Content | ConvertFrom-Json
$results.RequestIdentityType = $identity.identityType
$results.RequestSidClaimPresent = [bool]$identity.hasSidClaim
$results.RequestWindowsIdentityPresent = [bool]$identity.hasRequestWindowsIdentity
$results.RequestTokenSidPresent = [bool]$identity.hasRequestWindowsIdentityUser
Assert-Check ($diagnostic.Status -eq 200 -and $identity.identityType -eq "WindowsIdentity") "Windows authentication did not supply a WindowsIdentity request principal."
Assert-Check ($identity.hasSidClaim -or $identity.hasRequestWindowsIdentityUser) "The authenticated request principal has no SID source."

$webSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$csrfResponse = Invoke-IssuerRequest -Path "/csrf" -Method GET -WebSession $webSession -WindowsCredentials
$results.AuthenticatedCsrfStatus = $csrfResponse.Status
Assert-Check ($csrfResponse.Status -eq 200) "Windows-authenticated CSRF request did not return 200."
$csrfToken = ($csrfResponse.Content | ConvertFrom-Json).requestToken
$badSession = Invoke-IssuerRequest -Path "/session" -Method POST -WebSession ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) -WindowsCredentials
$results.MissingCsrfStatus = $badSession.Status
Assert-Check ($badSession.Status -eq 400) "Session creation did not reject a missing antiforgery token."
$sessionResponse = Invoke-IssuerRequest -Path "/session" -Method POST -WebSession $webSession -WindowsCredentials -Headers @{ "X-CSRF-TOKEN" = $csrfToken }
$results.SessionStatus = $sessionResponse.Status
Assert-Check ($sessionResponse.Status -eq 204) "Antiforgery-backed Windows session creation did not return 204."
$cookies = $webSession.Cookies.GetCookies($issuerUri)
$accessCookie = $cookies["dab_access_token"]
$refreshCookie = $cookies["issuer_refresh_token"]
$refreshCookieHeader = @($sessionResponse.Headers["Set-Cookie"]) | Where-Object { $_ -like "issuer_refresh_token=*" } | Select-Object -First 1
Assert-Check ($null -ne $accessCookie -and $accessCookie.HttpOnly -and $accessCookie.Secure) "The access cookie is missing or lacks secure cookie flags."
Assert-Check ($null -ne $refreshCookie -and $refreshCookie.HttpOnly -and $refreshCookie.Secure -and $refreshCookieHeader -match "(?i);\s*SameSite=Strict(?:;|$)") "The refresh cookie is missing or lacks secure cookie flags."
$tokenChecks = Test-Rs256Token -Token $accessCookie.Value -Audience "api://northwind-dab"
foreach ($property in $tokenChecks.PSObject.Properties) {
    $results["SessionJwt$($property.Name)"] = [bool]$property.Value
    Assert-Check ([bool]$property.Value) "The issued session JWT failed a signature, issuer, audience, expiry or claim-presence check."
}
$oldRefresh = $refreshCookie.Value

$badRefresh = Invoke-IssuerRequest -Path "/session/refresh" -Method POST -WebSession ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) -WindowsCredentials
$results.MissingRefreshCsrfStatus = $badRefresh.Status
Assert-Check ($badRefresh.Status -eq 400) "Refresh did not reject a missing antiforgery token."
$refreshResponse = Invoke-IssuerRequest -Path "/session/refresh" -Method POST -WebSession $webSession -WindowsCredentials -Headers @{ "X-CSRF-TOKEN" = $csrfToken }
$results.SessionRefreshStatus = $refreshResponse.Status
Assert-Check ($refreshResponse.Status -eq 204) "Antiforgery-backed refresh did not return 204."
$rotatedRefresh = $webSession.Cookies.GetCookies($issuerUri)["issuer_refresh_token"].Value
$results.RefreshRotated = ($rotatedRefresh -ne $oldRefresh)
Assert-Check $results.RefreshRotated "Refresh token rotation did not replace the cookie."

$replaySession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$csrfCookie = $webSession.Cookies.GetCookies($issuerUri)["issuer_csrf"]
$replaySession.Cookies.Add([Net.Cookie]::new("issuer_csrf", $csrfCookie.Value, "/", "localhost"))
$replaySession.Cookies.Add([Net.Cookie]::new("issuer_refresh_token", $oldRefresh, "/", "localhost"))
$replay = Invoke-IssuerRequest -Path "/session/refresh" -Method POST -WebSession $replaySession -WindowsCredentials -Headers @{ "X-CSRF-TOKEN" = $csrfToken }
$results.RefreshReplayStatus = $replay.Status
Assert-Check ($replay.Status -eq 401) "Replaying the consumed refresh cookie was not rejected."

$newSession = Invoke-IssuerRequest -Path "/session" -Method POST -WebSession $webSession -WindowsCredentials -Headers @{ "X-CSRF-TOKEN" = $csrfToken }
Assert-Check ($newSession.Status -eq 204) "A fresh session could not be created after replay-family revocation."
$logoutRefresh = $webSession.Cookies.GetCookies($issuerUri)["issuer_refresh_token"].Value
$logout = Invoke-IssuerRequest -Path "/session/logout" -Method POST -WebSession $webSession -WindowsCredentials -Headers @{ "X-CSRF-TOKEN" = $csrfToken }
$results.LogoutStatus = $logout.Status
Assert-Check ($logout.Status -eq 204) "Antiforgery-backed logout did not return 204."
$logoutReplay = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$logoutCsrfCookie = $webSession.Cookies.GetCookies($issuerUri)["issuer_csrf"]
$logoutReplay.Cookies.Add([Net.Cookie]::new("issuer_csrf", $logoutCsrfCookie.Value, "/", "localhost"))
$logoutReplay.Cookies.Add([Net.Cookie]::new("issuer_refresh_token", $logoutRefresh, "/", "localhost"))
$afterLogout = Invoke-IssuerRequest -Path "/session/refresh" -Method POST -WebSession $logoutReplay -WindowsCredentials -Headers @{ "X-CSRF-TOKEN" = $csrfToken }
$results.RefreshAfterLogoutStatus = $afterLogout.Status
Assert-Check ($afterLogout.Status -eq 401) "A refresh token remained usable after logout."

$oidcVerifier = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$oidcChallengeBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($oidcVerifier))
$oidcChallenge = [Convert]::ToBase64String($oidcChallengeBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$redirectUri = "https://localhost:5443/callback"
$query = "client_id=dab-issuer-test-client&redirect_uri=$([Uri]::EscapeDataString($redirectUri))&response_type=code&scope=openid%20profile%20roles%20offline_access&state=issuer-test-state&nonce=issuer-test-nonce&code_challenge=$oidcChallenge&code_challenge_method=S256"
$authorize = Invoke-IssuerRequest -Path "/connect/authorize?$query" -Method GET -WebSession $webSession -WindowsCredentials -MaximumRedirection 0
$results.AuthorizationStatus = $authorize.Status
Assert-Check ($authorize.Status -eq 302) "Windows-authenticated authorization-code request did not redirect to the registered callback."
$location = [Uri]$authorize.Headers.Location
$authorizationCode = [System.Web.HttpUtility]::ParseQueryString($location.Query)["code"]
$results.AuthorizationCodeReturned = (-not [string]::IsNullOrWhiteSpace($authorizationCode))
Assert-Check $results.AuthorizationCodeReturned "The authorization callback did not contain a code."
$oidcTokenResponse = Invoke-IssuerRequest -Path "/connect/token" -Method POST -WindowsCredentials -ContentType "application/x-www-form-urlencoded" -Body @{
    grant_type = "authorization_code"
    client_id = "dab-issuer-test-client"
    redirect_uri = $redirectUri
    code = $authorizationCode
    code_verifier = $oidcVerifier
}
$results.OidcTokenStatus = $oidcTokenResponse.Status
Assert-Check ($oidcTokenResponse.Status -eq 200) "PKCE token exchange did not return 200."
$oidcTokens = $oidcTokenResponse.Content | ConvertFrom-Json
$idChecks = Test-Rs256Token -Token $oidcTokens.id_token -Audience "dab-issuer-test-client"
$accessChecks = Test-Rs256Token -Token $oidcTokens.access_token -Audience "api://northwind-dab"
$results.OidcIdTokenSignatureValid = $idChecks.SignatureValid
$results.OidcIdTokenIssuerValid = $idChecks.IssuerValid
$results.OidcIdTokenAudienceValid = $idChecks.AudienceValid
$results.OidcIdTokenLifetimeValid = $idChecks.LifetimeValid
$results.OidcIdTokenSubjectPresent = $idChecks.HasSubject
$results.OidcAccessTokenSignatureValid = $accessChecks.SignatureValid
$results.OidcAccessTokenClaimsPresent = ($accessChecks.HasProfile -and $accessChecks.HasRole -and $accessChecks.HasClearanceClaim)
$results.OidcNonceValid = (([Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url ($oidcTokens.id_token.Split('.')[1]))) | ConvertFrom-Json).nonce -eq "issuer-test-nonce")
Assert-Check ($results.OidcIdTokenSignatureValid -and $results.OidcIdTokenIssuerValid -and $results.OidcIdTokenAudienceValid -and $results.OidcIdTokenLifetimeValid -and $results.OidcIdTokenSubjectPresent -and $results.OidcAccessTokenSignatureValid -and $results.OidcAccessTokenClaimsPresent -and $results.OidcNonceValid) "OIDC token signature, standard claims or nonce validation failed."
$oidcRefresh = Invoke-IssuerRequest -Path "/connect/token" -Method POST -WindowsCredentials -ContentType "application/x-www-form-urlencoded" -Body @{
    grant_type = "refresh_token"
    client_id = "dab-issuer-test-client"
    refresh_token = $oidcTokens.refresh_token
}
$results.OidcRefreshStatus = $oidcRefresh.Status
Assert-Check ($oidcRefresh.Status -eq 200) "OIDC refresh-token exchange did not return 200."
$rotatedOidcRefresh = ($oidcRefresh.Content | ConvertFrom-Json).refresh_token
$oidcReplay = Invoke-IssuerRequest -Path "/connect/token" -Method POST -WindowsCredentials -ContentType "application/x-www-form-urlencoded" -Body @{
    grant_type = "refresh_token"
    client_id = "dab-issuer-test-client"
    refresh_token = $oidcTokens.refresh_token
}
$results.OidcRefreshReplayStatus = $oidcReplay.Status
Assert-Check ($oidcReplay.Status -eq 400 -and $rotatedOidcRefresh -ne $oidcTokens.refresh_token) "OIDC refresh rotation/replay handling failed."
$descendantReplay = Invoke-IssuerRequest -Path "/connect/token" -Method POST -WindowsCredentials -ContentType "application/x-www-form-urlencoded" -Body @{
    grant_type = "refresh_token"
    client_id = "dab-issuer-test-client"
    refresh_token = $rotatedOidcRefresh
}
$results.OidcDescendantAfterReplayStatus = $descendantReplay.Status
Assert-Check ($descendantReplay.Status -eq 400) "The rotated OIDC refresh token remained usable after its ancestor was replayed."

$results.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Check = $_.Key; Result = $_.Value } } | Format-Table -AutoSize
$oidcTokens = $null
$accessCookie = $null
$refreshCookie = $null
$oldRefresh = $null
$logoutRefresh = $null
$authorizationCode = $null
