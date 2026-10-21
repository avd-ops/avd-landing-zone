# Run recorder, phase 3 (build/specs/run-recorder-spec.md sections 6.3, 9.3, 9.3a, 13a): set up the run
# store once (Defender for Storage and the private repo checked first), then open a run whose expected
# cost must be at most half the cap with every line priced.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) "avdlz-runs-$PID"
$null = New-Item -ItemType Directory -Path $root -Force
$runId = 'run-20261020-1800-t3st'
$deploys = { @($global:Calls | Where-Object { $_ -match '^deploy avdlzruns-store' }).Count }

Invoke-ScenarioStep 'start-no-store' {
  $global:St.runStore = @{ defender = 'Free'; deployed = $false }
  & ./scripts/ops/Start-AvdRunRecorder.ps1 -RunId $runId -Location northcentralus -LocalRoot $root
}
Invoke-ScenarioStep 'store-defender-on' {
  $global:St.runStore = @{ defender = 'Standard'; deployed = $false }
  & ./scripts/ops/Initialize-AvdRunStore.ps1 -Location northcentralus
}
Write-Host "RESULT defender-on deploys=$(& $deploys)"
Invoke-ScenarioStep 'store-public-repo' {
  $global:St.runStore = @{ defender = 'Free'; deployed = $false }
  $env:AVDLZ_FAKE_GH = 'public'
  & ./scripts/ops/Initialize-AvdRunStore.ps1 -Location northcentralus -PrivateRepo 'contoso/run-records'
}
Write-Host "RESULT public-repo deploys=$(& $deploys)"
Invoke-ScenarioStep 'store-whatif' {
  $env:AVDLZ_FAKE_GH = 'private'
  & ./scripts/ops/Initialize-AvdRunStore.ps1 -Location northcentralus -PrivateRepo 'contoso/run-records' -WhatIf
}
Write-Host "RESULT whatif deploys=$(& $deploys)"
Invoke-ScenarioStep 'store' {
  & ./scripts/ops/Initialize-AvdRunStore.ps1 -Location northcentralus -PrivateRepo 'contoso/run-records' -TeardownLogs Ask
}
$d = @($global:Calls | Where-Object { $_ -match '^deploy avdlzruns-store' })
Write-Host "RESULT store deploys=$($d.Count) $(($d | Select-Object -Last 1) -replace '^deploy \S+ ')"

Invoke-ScenarioStep 'start' {
  & ./scripts/ops/Start-AvdRunRecorder.ps1 -RunId $runId -Location northcentralus -Hours 3 -Cap 10 -LocalRoot $root
}
$folder = Join-Path (Join-Path $root 'avdlz-runs') $runId
$cost = Get-Content (Join-Path $folder 'cost.json') -Raw | ConvertFrom-Json
$run = Get-Content (Join-Path $folder 'run.json') -Raw | ConvertFrom-Json
$schemas = Join-Path (Get-Location) 'contracts/schemas'
$valid = (Test-Json -Path (Join-Path $folder 'run.json') -SchemaFile (Join-Path $schemas 'run-record.schema.json')) -and
  (Test-Json -Path (Join-Path $folder 'cost.json') -SchemaFile (Join-Path $schemas 'run-cost.schema.json'))
$uploaded = @($global:St.blobs.Keys | Sort-Object) -join ','
Write-Host "RESULT start-files valid=$valid gate=$($cost.gate.passed) limit=$($cost.gate.limit) unpriced=$($cost.expected.unpriced) totalUnderLimit=$($cost.expected.total -le $cost.gate.limit) useCase=$($run.useCase) teardown=$($run.teardown.status) uploaded=$uploaded"

Invoke-ScenarioStep 'start-unpriced' {
  # As if the retail prices API renamed a meter: the line stays unpriced and the gate can't pass.
  $global:St.ipMeterRenamed = $true
  & ./scripts/ops/Start-AvdRunRecorder.ps1 -RunId 'run-20261020-1805-t3st' -Location northcentralus -LocalRoot $root -Local
}
$c2 = Get-Content (Join-Path (Join-Path (Join-Path $root 'avdlz-runs') 'run-20261020-1805-t3st') 'cost.json') -Raw | ConvertFrom-Json
$line = $c2.expected.lines | Where-Object { $null -eq $_.cost } | Select-Object -First 1
Write-Host "RESULT start-unpriced gate=$($c2.gate.passed) unpriced=$($c2.expected.unpriced) match=$($line.match) noGuess=$($null -eq $line.cost) localOnly=$(-not $global:St.blobs.ContainsKey('runs/run-20261020-1805-t3st/cost.json'))"

# Closing the run (Stop-AvdRunRecorder.ps1): export the landing zone's AVD logs before cleanup, then the
# first actual cost reading, then a later reading Cost Management refuses, then a copy to a public repo.
$lzArgs = @{ NamePrefix = 'avdlz'; Environment = 'dev'; RunId = $runId; LocalRoot = $root }
$row = @{ CorrelationId = 'c0ffee00-0000-4000-8000-000000000001'; StartedAt = '2026-10-20T18:20:00Z'; ConnectedAt = '2026-10-20T18:20:12Z' }
Invoke-ScenarioStep 'stop-before-cleanup' {
  $global:St.logPolls = @(, @($row, $row)); $global:St.logQueries = 0; $global:Calls.Clear()
  & ./scripts/ops/Stop-AvdRunRecorder.ps1 @lzArgs -BeforeCleanup
}
$logs = @(Get-ChildItem (Join-Path $folder 'logs') -Filter '*.json')
$rows = @(Get-Content (Join-Path $folder 'logs/WVDConnections.json') -Raw | ConvertFrom-Json).Count
Write-Host "RESULT before-cleanup tables=$($logs.Count) queries=$($global:St.logQueries) rows=$rows uploaded=$(@($global:St.blobs.Keys | Where-Object { $_ -like "runs/$runId/logs/*" }).Count)"

Invoke-ScenarioStep 'stop-end' {
  $global:St.runStore.costRows = @(, @(3.1, 'E4as v5', 'USD')) + @(, @(0.4, 'Standard Static IP', 'USD')); $global:Calls.Clear()
  & ./scripts/ops/Stop-AvdRunRecorder.ps1 @lzArgs -Status torn-down
}
$cost = Get-Content (Join-Path $folder 'cost.json') -Raw | ConvertFrom-Json
$run = Get-Content (Join-Path $folder 'run.json') -Raw | ConvertFrom-Json
$valid = (Test-Json -Path (Join-Path $folder 'run.json') -SchemaFile (Join-Path $schemas 'run-record.schema.json')) -and
  (Test-Json -Path (Join-Path $folder 'cost.json') -SchemaFile (Join-Path $schemas 'run-cost.schema.json'))
$scope = @($global:Calls | Where-Object { $_ -like 'COSTQUERY *' })[0]
Write-Host "RESULT stop-end valid=$valid status=$($run.status) files=$(@($run.files).Count) readings=$(@($cost.actuals).Count) total=$($cost.actuals[0].total) settled=$($cost.actuals[0].settled) unexpected=$(@($cost.comparison.unexpectedMeters) -join ',') afterTeardown=$($cost.comparison.billingAfterTeardown) runStoreInScope=$($scope -match 'avdlz-runs-rg') lzInScope=$($scope -match 'rg-avdlz-dev-hosts')"

Invoke-ScenarioStep 'stop-update-forbidden' {
  $global:St.runStore.costForbidden = $true
  & ./scripts/ops/Stop-AvdRunRecorder.ps1 @lzArgs -UpdateCost
}
$cost = Get-Content (Join-Path $folder 'cost.json') -Raw | ConvertFrom-Json
Write-Host "RESULT update-forbidden readings=$(@($cost.actuals).Count) kept=$($cost.actuals[0].total) why=$($cost.actuals[1].unavailable -match 'no access')"

# Two days after teardown, the landing zone's resource groups still bill: flagged. The teardown day never counts.
$runPath = Join-Path $folder 'run.json'
$r = Get-Content $runPath -Raw | ConvertFrom-Json -AsHashtable
$r.ended = [datetime]::UtcNow.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'); $r | ConvertTo-Json -Depth 10 | Set-Content $runPath
Invoke-ScenarioStep 'stop-update-after' {
  $global:St.runStore.costForbidden = $false; $global:St.runStore.costRowsAfter = @(, @(0.2, 'Standard Static IP', 'USD')); $global:Calls.Clear()
  & ./scripts/ops/Stop-AvdRunRecorder.ps1 @lzArgs -UpdateCost
}
$cost = Get-Content (Join-Path $folder 'cost.json') -Raw | ConvertFrom-Json
$queries = @($global:Calls | Where-Object { $_ -like 'COSTQUERY *' })
Write-Host "RESULT update-after readings=$(@($cost.actuals).Count) afterTeardown=$($cost.comparison.billingAfterTeardown) queries=$($queries.Count) afterExcludesStore=$($queries[-1] -notmatch 'avdlz-runs-rg') afterFrom=$($queries[-1] -like "COSTQUERY $([datetime]::UtcNow.AddDays(-1).Date) *")"

Invoke-ScenarioStep 'copy-public' {
  $env:AVDLZ_FAKE_GH = 'public'
  & ./scripts/ops/Stop-AvdRunRecorder.ps1 @lzArgs -CopyTo github -PrivateRepo 'contoso/run-records'
}
$run = Get-Content (Join-Path $folder 'run.json') -Raw | ConvertFrom-Json
Write-Host "RESULT copy-public copies=$(@($run.files | Where-Object { @($_.copies | Where-Object { $_ }).Count }).Count)"
Remove-Item -Recurse -Force $root
