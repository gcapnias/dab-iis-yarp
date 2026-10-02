param(
    [string]$DotEnvFile = ''
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitCommonDirectory = (& git -C $repositoryRoot rev-parse --path-format=absolute --git-common-dir).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot find the primary Git checkout for this worktree.' }
$primaryRoot = Split-Path -Parent $gitCommonDirectory
if ([string]::IsNullOrWhiteSpace($DotEnvFile)) { $DotEnvFile = Join-Path $primaryRoot '.env' }
$projectRoot = Join-Path $repositoryRoot 'src/EmbeddedDab'
$projectFile = Join-Path $projectRoot 'EmbeddedDab.csproj'
$activeConfig = Join-Path $projectRoot 'dab-config.json'
$initialConfig = Join-Path $projectRoot 'configurations/initial.json'
$expandedConfig = Join-Path $projectRoot 'configurations/expanded.json'
$assembly = Join-Path $projectRoot 'bin/Debug/net10.0/EmbeddedDab.dll'
$hadActiveConfig = Test-Path -LiteralPath $activeConfig
$originalConfig = if ($hadActiveConfig) { Get-Content -LiteralPath $activeConfig -Raw } else { $null }
$envNames = @('DAB_ENV_FILE', 'DAB_FIXTURE_DATABASE', 'DAB_CONNECTION_STRING')
$oldEnvironment = @{}
foreach ($name in $envNames) { $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

$databaseName = 'dab_ticket9_' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$portListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$portListener.Start()
$port = ([System.Net.IPEndPoint]$portListener.LocalEndpoint).Port
$portListener.Stop()
$baseUri = "http://127.0.0.1:$port"
$stdout = Join-Path $env:TEMP "$databaseName.stdout.log"
$stderr = Join-Path $env:TEMP "$databaseName.stderr.log"
$fixtureCreated = $false
$server = $null
$http = [System.Net.Http.HttpClient]::new()
$checks = [System.Collections.Generic.List[string]]::new()

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAILED: $message" }
    $checks.Add($message)
    Write-Host "PASS $message"
}

function Get-Response([string]$method, [string]$path, [string]$role = 'anonymous', [string]$json = '') {
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($method), "$baseUri$path")
    if ($role) { $request.Headers.Add('X-MS-API-ROLE', $role) }
    if ($json) { $request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json') }
    $response = $http.Send($request)
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $responseProcessId = $response.Headers.GetValues('X-Spike-Process-Id') -join ''
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $body; ProcessId = $responseProcessId }
}

function Wait-ForServer {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if ($server.HasExited) {
            $out = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { '' }
            $err = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { '' }
            throw "DAB prototype exited during startup. stdout=$out stderr=$err"
        }
        try {
            $response = Get-Response 'GET' '/host' ''
            if ($response.Status -eq 200) { return }
        } catch { Start-Sleep -Milliseconds 300 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for the DAB prototype.'
}

function Start-ProofHost([string]$configPath) {
    Copy-Item -LiteralPath $configPath -Destination $activeConfig -Force
    $env:DAB_ENV_FILE = [System.IO.Path]::GetFullPath($DotEnvFile)
    $env:DAB_FIXTURE_DATABASE = $databaseName
    $script:server = Start-Process -FilePath 'dotnet' -ArgumentList @($assembly, '--initialize', '--urls', $baseUri) -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Wait-ForServer
}

function Stop-ProofHost {
    if ($server -and -not $server.HasExited) {
        $server.Kill($true)
        $server.WaitForExit()
    }
    if ($server) { $server.Dispose(); $script:server = $null }
    Start-Sleep -Milliseconds 500
}

function Assert-GraphQL([string]$path, [string]$query, [string]$role, [string]$description) {
    $payload = @{ query = $query } | ConvertTo-Json -Compress
    $response = Get-Response 'POST' $path $role $payload
    Assert-True ($response.Status -eq 200) "$description HTTP 200"
    Assert-True ($response.ProcessId -eq $script:expectedProcessId) "$description is served by the host process"
    $parsed = $response.Body | ConvertFrom-Json
    Assert-True ($null -eq $parsed.errors) "$description has no GraphQL errors (body $($response.Body))"
    return $parsed
}

try {
    if (-not (Test-Path -LiteralPath $DotEnvFile)) { throw "Dotenv file not found: $DotEnvFile" }
    dotnet build $projectFile --verbosity minimal
    if ($LASTEXITCODE -ne 0) { throw 'Embedded DAB build failed.' }
    if (-not (Test-Path -LiteralPath $assembly)) { throw 'Build did not produce EmbeddedDab.dll.' }

    Remove-Item Env:DAB_CONNECTION_STRING -ErrorAction SilentlyContinue
    $env:DAB_ENV_FILE = [System.IO.Path]::GetFullPath($DotEnvFile)
    dotnet $assembly --prepare-fixture $databaseName
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the disposable SQL fixture database.' }
    $fixtureCreated = $true

    Start-ProofHost $initialConfig
    $hostResponse = Get-Response 'GET' '/host' ''
    Assert-True ($hostResponse.Status -eq 200) 'host-owned route is served by ASP.NET Core'
    $processId = ($hostResponse.Body | ConvertFrom-Json).processId.ToString()
    $script:expectedProcessId = $processId

    $items = Get-Response 'GET' '/api/Widget?$first=2'
    Assert-True ($items.Status -eq 200) "configured REST collection route reads Widget rows (status $($items.Status), body $($items.Body))"
    Assert-True ($items.ProcessId -eq $processId) 'REST adapter is served by the same process as the host route'
    $rows = ($items.Body | ConvertFrom-Json).value
    Assert-True ($rows.Count -eq 2 -and $rows[0].name -eq 'fixture-one') 'REST response comes from the disposable fixture'
    $created = Get-Response 'POST' '/api/Widget' 'anonymous' '{"name":"rest-created","quantity":1}'
    Assert-True ($created.Status -in @(200, 201)) "configured create operation accepts a disposable fixture write (status $($created.Status), body $($created.Body))"
    $detail = Get-Response 'GET' '/api/Widget/id/3'
    Assert-True ($detail.Status -eq 200) 'configured key route reads the created row'
    $patched = Get-Response 'PATCH' '/api/Widget/id/3' 'anonymous' '{"quantity":2}'
    Assert-True ($patched.Status -in @(200, 204)) 'configured PATCH operation updates the fixture row'
    $afterPatch = Get-Response 'GET' '/api/Widget/id/3'
    Assert-True (($afterPatch.Body | ConvertFrom-Json).value[0].quantity -eq 2) 'PATCH persists the updated fixture quantity'
    $put = Get-Response 'PUT' '/api/Widget/id/3' 'anonymous' '{"name":"rest-upserted","quantity":4}'
    Assert-True ($put.Status -in @(200, 201, 204)) 'configured PUT operation upserts the fixture row'
    $afterPut = Get-Response 'GET' '/api/Widget/id/3'
    $putRow = ($afterPut.Body | ConvertFrom-Json).value[0]
    Assert-True ($putRow.name -eq 'rest-upserted' -and $putRow.quantity -eq 4) 'PUT persists the upserted fixture values'
    $deleted = Get-Response 'DELETE' '/api/Widget/id/3'
    Assert-True ($deleted.Status -in @(200, 204)) 'configured delete operation removes the fixture row'
    $afterDelete = Get-Response 'GET' '/api/Widget/id/3'
    $deleteReadRows = if ($afterDelete.Status -eq 200) { ($afterDelete.Body | ConvertFrom-Json).value } else { @() }
    Assert-True ($afterDelete.Status -eq 404 -or $deleteReadRows.Count -eq 0) "DELETE removes the fixture row from subsequent reads (status $($afterDelete.Status), body $($afterDelete.Body))"
    $denied = Get-Response 'POST' '/api/RetiredWidget' 'anonymous' '{"name":"denied"}'
    Assert-True ($denied.Status -in @(401, 403)) "per-entity REST permissions reject unconfigured create (status $($denied.Status), body $($denied.Body))"
    $gql = Assert-GraphQL '/graphql' '{ widgets(first: 2) { items { id name quantity } } }' 'anonymous' 'configured GraphQL query'
    Assert-True ($gql.data.widgets.items.Count -ge 2) 'GraphQL query reads fixture rows'
    $createWidget = Assert-GraphQL '/graphql' 'mutation { createWidget(item: { name: "graphql-created", quantity: 6 }) { id name quantity } }' 'anonymous' 'configured GraphQL mutation'
    Assert-True ($createWidget.data.createWidget.name -eq 'graphql-created') 'GraphQL mutation writes the disposable fixture'
    $updateWidget = Assert-GraphQL '/graphql' 'mutation { updateWidget(id: 4, item: { quantity: 9 }) { id name quantity } }' 'anonymous' 'configured GraphQL update mutation'
    Assert-True ($updateWidget.data.updateWidget.quantity -eq 9) 'GraphQL update mutation changes the fixture row'
    $deleteWidget = Assert-GraphQL '/graphql' 'mutation { deleteWidget(id: 4) { id } }' 'anonymous' 'configured GraphQL delete mutation'
    Assert-True ($deleteWidget.data.deleteWidget.id -eq 4) 'GraphQL delete mutation returns the deleted fixture key'
    $afterGraphQLDelete = Get-Response 'GET' '/api/Widget/id/4'
    $graphQLDeleteReadRows = if ($afterGraphQLDelete.Status -eq 200) { ($afterGraphQLDelete.Body | ConvertFrom-Json).value } else { @() }
    Assert-True ($afterGraphQLDelete.Status -eq 404 -or $graphQLDeleteReadRows.Count -eq 0) "GraphQL delete mutation removes the fixture row (status $($afterGraphQLDelete.Status), body $($afterGraphQLDelete.Body))"
    $retiredMutation = Get-Response 'POST' '/graphql' 'anonymous' ('{"query":"mutation { createRetiredWidget(item: { name: \"denied\" }) { id } }"}')
    $retiredMutationErrors = (($retiredMutation.Body | ConvertFrom-Json).errors | ForEach-Object { $_.message }) -join ' '
    Assert-True ($retiredMutationErrors -match 'createRetiredWidget' -and $retiredMutationErrors -match 'does not exist') 'GraphQL schema rejects the specific permission-denied create field'

    $retired = Get-Response 'GET' '/api/RetiredWidget'
    Assert-True ($retired.Status -eq 200) 'initial configuration exposes RetiredWidget through REST'
    $initialPathPrefixCollision = Get-Response 'GET' '/apiWidget'
    Assert-True ($initialPathPrefixCollision.Status -eq 404) 'REST rejects paths that only share the configured path prefix'
    $oldLabel = Get-Response 'GET' '/api/Label'
    Assert-True ($oldLabel.Status -eq 404) 'initial configuration does not expose Label'
    Stop-ProofHost

    Start-ProofHost $expandedConfig
    $expandedHost = Get-Response 'GET' '/host' ''
    $script:expectedProcessId = ($expandedHost.Body | ConvertFrom-Json).processId.ToString()
    $newWidgetPath = Get-Response 'GET' '/v2/catalog/widgets?$first=2'
    Assert-True ($newWidgetPath.Status -eq 200) "configuration-only path change exposes the same Widget entity at its new route (status $($newWidgetPath.Status), body $($newWidgetPath.Body))"
    Assert-True ($newWidgetPath.ProcessId -eq $script:expectedProcessId) 'expanded REST adapter is served by the restarted host process'
    $oldWidgetPath = Get-Response 'GET' '/api/Widget'
    Assert-True ($oldWidgetPath.Status -ne 200) 'previous REST base path is inactive after restart'
    $expandedPathPrefixCollision = Get-Response 'GET' '/v2catalog/widgets'
    Assert-True ($expandedPathPrefixCollision.Status -eq 404) 'expanded REST path rejects prefix collisions without a segment boundary'
    $newLabel = Get-Response 'GET' '/v2/Label'
    Assert-True ($newLabel.Status -eq 200) 'configuration-only entity addition exposes Label after restart'
    $removedRetired = Get-Response 'GET' '/v2/RetiredWidget'
    Assert-True ($removedRetired.Status -eq 404) 'configuration-only entity removal hides RetiredWidget after restart'
    $expandedQuery = Assert-GraphQL '/gql-v2' '{ labels { items { id name } } }' 'anonymous' 'expanded GraphQL schema query'
    Assert-True ($expandedQuery.data.labels.items[0].name -eq 'added-by-config') 'new GraphQL entity is queryable after restart'
    $retiredQuery = Get-Response 'POST' '/gql-v2' 'anonymous' ('{"query":"{ retiredWidgets { items { id } } }"}')
    $retiredQueryErrors = (($retiredQuery.Body | ConvertFrom-Json).errors | ForEach-Object { $_.message }) -join ' '
    Assert-True ($retiredQueryErrors -match 'retiredWidgets' -and $retiredQueryErrors -match 'does not exist') 'GraphQL schema reports the removed entity field as unknown after restart'
    $newHost = Get-Response 'GET' '/host' ''
    Assert-True (($newHost.Body | ConvertFrom-Json).processId -ne $processId) 'configuration changes were applied by restarting the same built binary'

    Write-Host "PASS total checks: $($checks.Count)"
}
finally {
    Stop-ProofHost
    $http.Dispose()
    if ($fixtureCreated) {
        $env:DAB_ENV_FILE = [System.IO.Path]::GetFullPath($DotEnvFile)
        Remove-Item Env:DAB_FIXTURE_DATABASE -ErrorAction SilentlyContinue
        dotnet $assembly --cleanup-fixture $databaseName
        if ($LASTEXITCODE -ne 0) { Write-Warning "Fixture cleanup failed; database name: $databaseName" }
    }
    if ($hadActiveConfig) { Set-Content -LiteralPath $activeConfig -Value $originalConfig -NoNewline } else { Remove-Item -LiteralPath $activeConfig -Force -ErrorAction SilentlyContinue }
    foreach ($name in $envNames) {
        if ($null -eq $oldEnvironment[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process') }
    }
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
}
