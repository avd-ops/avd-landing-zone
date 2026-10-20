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
Remove-Item -Recurse -Force $root
