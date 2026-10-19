# Verify access (decision 0014): Test-AvdUserConnection.ps1 against canned Log Analytics query results.
# It fails closed: only a connection that reached Connected is verified; no rows, a connection still in
# progress and a failed query are "not verified", and errors without a connection are "failed".
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$lz = @{ NamePrefix = 'avdlz'; Environment = 'dev' }
$connected = @{ CorrelationId = 'c0ffee00-0000-4000-8000-000000000001'; StartedAt = '2026-10-05T09:00:00Z'; ConnectedAt = '2026-10-05T09:00:12.4Z'; CompletedAt = $null
  ConnectionSetupSeconds = 12.4; SessionHost = 'avdlzdsh-001.contoso.local'; ClientType = 'HTML'; ClientOS = 'Windows 11'; GatewayRegion = 'NCUS'; TransportType = 'TCP'
  Errors = $null; Checkpoints = @('LoadBalancedNewConnection', 'RdpStackConnectionEstablished') }
$errored = @{ CorrelationId = 'c0ffee00-0000-4000-8000-000000000002'; StartedAt = '2026-10-05T08:50:00Z'; ConnectedAt = $null
  Errors = @(@{ code = 'ExampleCodeForTests'; message = 'Example failure message.'; source = 'RDGateway'; serviceError = $false }); FirstErrorAt = '2026-10-05T08:50:03Z' }
$started = @{ CorrelationId = 'c0ffee00-0000-4000-8000-000000000003'; StartedAt = '2026-10-05T09:05:00Z' }
function Invoke-VerifyCase([string] $Name, [object[]] $Polls, [hashtable] $Extra = @{}) {
  $global:St.logPolls = $Polls; $global:St.logQueries = 0; $global:Calls.Clear()
  Invoke-ScenarioStep $Name { & ./scripts/ops/Test-AvdUserConnection.ps1 @lz -PollSeconds 60 @Extra }
  $q = @($global:Calls | Where-Object { $_ -like 'LAQUERY *' })
  Write-Host "RESULT $Name-calls queries=$($global:St.logQueries) first=$($q[0])"
}

# Nothing yet, then the connection arrives on the third check.
Invoke-VerifyCase 'verified' @(@(), @($started), @($connected, $errored)) @{ TimeoutMinutes = 5 }
# Errors and no connection on two checks in a row: failed.
Invoke-VerifyCase 'failed' @(@($errored)) @{ TimeoutMinutes = 5 }
# Nothing at all until the timeout: three checks over two minutes, then not verified.
Invoke-VerifyCase 'none' @(@()) @{ TimeoutMinutes = 2 }
# Started, never connected, no errors: not verified (still in progress), never a pass.
Invoke-VerifyCase 'inprogress' @(@($started)) @{ TimeoutMinutes = 1 }
# The query is refused: not verified, with the status and the role to grant.
Invoke-VerifyCase 'forbidden' @(@{ status = 403 }) @{ TimeoutMinutes = 5 }
# Another user, the demo desktop, and a single check.
$global:St.rgs += 'rg-avdlz-dev-demo'
Invoke-VerifyCase 'demo' @(, @($connected)) @{ Demo = $true; UserPrincipalName = 'alex@contoso.com'; TimeoutMinutes = 0 }
