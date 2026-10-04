param([Parameter(Mandatory)][uri]$Issuer,[Parameter(Mandatory)][uri]$Api,[Parameter(Mandatory)][string]$CredentialFile)
$ErrorActionPreference='Stop'
foreach($endpoint in @($Issuer,$Api)){if($endpoint.Scheme -ne 'https' -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment){throw 'Use identified HTTPS proof applications.'}}
$credential=Import-Clixml $CredentialFile
$session=[Microsoft.PowerShell.Commands.WebRequestSession]::new()
$issuerBase=$Issuer.AbsoluteUri.TrimEnd('/')
$apiBase=$Api.AbsoluteUri.TrimEnd('/')
$options=@{SkipCertificateCheck=$true;NoProxy=$true;TimeoutSec=20}
$results=[ordered]@{}
try {
    $csrf=Invoke-RestMethod "$issuerBase/csrf" -Credential $credential -WebSession $session @options
    $null=Invoke-WebRequest "$issuerBase/session" -Method Post -Credential $credential -WebSession $session -Headers @{'X-CSRF-TOKEN'=$csrf.requestToken} @options
    $bridge=Invoke-RestMethod "$apiBase/bridge/csrf" -WebSession $session -Headers @{'X-MS-API-ROLE'='reader'} @options
    foreach($origin in @($issuerBase,'https://wrong-origin.invalid')) {
        $headers=@{'X-MS-API-ROLE'='reader';'X-CSRF-TOKEN'=$bridge.requestToken;Origin=$origin}
        $body=@{query='{ products(first: 1) { items { ProductID ProductName } } }'} | ConvertTo-Json
        $response=Invoke-WebRequest "$apiBase/graphql" -Method Post -ContentType application/json -Body $body -WebSession $session -Headers $headers -SkipHttpErrorCheck @options
        if($origin -eq $issuerBase){$results.same_origin_graphql_post=$response.StatusCode -eq 200}else{$results.foreign_origin_graphql_post_denied=$response.StatusCode -eq 400}
    }
    $null=$session.Headers.Remove('X-CSRF-TOKEN')
    $headers=@{'X-MS-API-ROLE'='reader';Origin=$issuerBase}
    $noToken=Invoke-WebRequest "$apiBase/graphql" -Method Post -ContentType application/json -Body $body -WebSession $session -Headers $headers -SkipHttpErrorCheck @options
    $results.missing_antiforgery_post_denied=$noToken.StatusCode -eq 400
    foreach($path in @('/csrf','/diagnostics/windows-auth')) {
        $anonymous=Invoke-WebRequest "$issuerBase$path" -SkipHttpErrorCheck @options
        $results['anonymous_'+$path.TrimStart('/').Replace('/','_')+'_denied']=$anonymous.StatusCode -in 401,403
    }
} finally {
    $csrf=Invoke-RestMethod "$issuerBase/csrf" -Credential $credential -WebSession $session @options
    $null=Invoke-WebRequest "$issuerBase/session/logout" -Method Post -Credential $credential -WebSession $session -Headers @{'X-CSRF-TOKEN'=$csrf.requestToken} @options
}
$results | ConvertTo-Json
if($results.Values -contains $false){exit 1}
