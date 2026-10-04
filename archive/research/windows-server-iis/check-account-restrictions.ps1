param([Parameter(Mandatory)][uri]$Issuer,[Parameter(Mandatory)][string]$CredentialFile,[Parameter(Mandatory)][string]$ConnectionFile)
$ErrorActionPreference='Stop'
if($Issuer.Scheme -ne 'https' -or $Issuer.UserInfo -or $Issuer.Query -or $Issuer.Fragment){throw 'Use the identified HTTPS proof issuer.'}

$sql=[System.Data.Common.DbConnectionStringBuilder]::new()
$sql.set_ConnectionString((Get-Content $ConnectionFile -Raw).Trim())
$database=[string]$sql['Initial Catalog']
if($database -notmatch '^dab_ticket9_[0-9a-f]{12}$'){throw 'Only the dedicated disposable Identity store is authorized by this verifier.'}
$credential=Import-Clixml $CredentialFile
$results=[ordered]@{}
$env:SQLCMDPASSWORD=[string]$sql['Password']
$stateWasVerified=$false
function Set-ProofRestriction([string]$statement) {
    sqlcmd -S $sql['Data Source'] -U $sql['User ID'] -d $database -C -b -Q $statement *> $null
    if($LASTEXITCODE -ne 0){throw 'Disposable account state update failed.'}
}
try {
    Set-ProofRestriction "IF (SELECT COUNT(*) FROM IdentityIssuer.AspNetUsers WHERE ProfileId=N'iis-proof-profile' AND IsEnabled=1 AND LockoutEnd IS NULL) <> 1 THROW 50000, 'Expected one enabled, unlocked synthetic proof account.', 1;"
    $stateWasVerified=$true
    foreach($case in @('disabled','locked')) {
        if($case -eq 'disabled'){$statement="UPDATE IdentityIssuer.AspNetUsers SET IsEnabled=0 WHERE ProfileId=N'iis-proof-profile';"}else{$statement="UPDATE IdentityIssuer.AspNetUsers SET IsEnabled=1, LockoutEnd=DATEADD(day,1,SYSUTCDATETIME()) WHERE ProfileId=N'iis-proof-profile';"}
        Set-ProofRestriction $statement
        $session=[Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $csrf=Invoke-RestMethod ($Issuer.AbsoluteUri.TrimEnd('/')+'/csrf') -Credential $credential -WebSession $session -SkipCertificateCheck -NoProxy
        $response=Invoke-WebRequest ($Issuer.AbsoluteUri.TrimEnd('/')+'/session') -Method Post -Credential $credential -WebSession $session -SkipCertificateCheck -NoProxy -SkipHttpErrorCheck -Headers @{'X-CSRF-TOKEN'=$csrf.requestToken}
        $results[$case+'_account_denied']=$response.StatusCode -in 401,403
    }
} finally {
    if($stateWasVerified){Set-ProofRestriction "UPDATE IdentityIssuer.AspNetUsers SET IsEnabled=1,LockoutEnd=NULL WHERE ProfileId=N'iis-proof-profile';"}
    Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
}
$results | ConvertTo-Json
if($results.Values -contains $false){exit 1}
