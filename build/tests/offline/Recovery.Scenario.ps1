# Same-tenant recovery (build/specs/recovery-spec.md): the status check on a fresh landing zone, a
# configuration snapshot (with the registration token kept out), drift, a copy read back, the monthly
# verify catching a corrupted copy, a profile recovery test planned, run and torn down, and tier R1.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) "avdlz-recovery-$PID"
$null = New-Item -ItemType Directory -Path $root -Force
$runs = Join-Path $root 'avdlz-runs'
$schemas = Join-Path (Get-Location) 'contracts/schemas'
$now = (Get-Date).ToUniversalTime()
$commit = '0123456789abcdef0123456789abcdef01234567'
$global:St.deploymentRecords = @(@{ name = 'avdlz-dev-20261020-100000'; state = 'Succeeded'; timestamp = $now.AddDays(-1).ToString('o')
    parameters = @{ autoShutdownRunbookUri = @{ value = 'https://raw.githubusercontent.com/contoso/avd-landing-zone/master/scripts/automation/Invoke-AvdPowerAction.ps1' } } })
$global:St.recovery = @{ points = @($now.AddHours(-5).ToString('o'), $now.AddHours(-29).ToString('o')); restoreStatus = 'Completed'; replicaRegions = @() }
$state = { param($o) [regex]::Matches(($o | Out-String), '<<<AVDLZ-STATE (.*?) AVDLZ-STATE>>>') | Select-Object -Last 1 | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json } }
$ids = { param($s, $status) @($s.failures + $s.warnings | Where-Object { $_ } | ForEach-Object id) -join ',' }
$snapshots = { @(Get-ChildItem $runs -Filter run.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.extensions.recovery.kind -eq 'snapshot' } | Sort-Object { $_.ended }) }

Invoke-ScenarioStep 'status-fresh' { & ./scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment dev -LocalRoot $root } *>&1 | Tee-Object -Variable out
$s = & $state $out
Write-Host "RESULT status-fresh stage=$($s.stage) status=$($s.status) met=$($s.context.met)/$($s.context.total) ids=$(& $ids $s)"

Invoke-ScenarioStep 'export' { & ./scripts/ops/Export-AvdConfiguration.ps1 -NamePrefix avdlz -Environment dev -LocalRoot $root }
$snap = (& $snapshots)[-1]
$folder = Join-Path $runs $snap.runId
$valid = Test-Json -Path (Join-Path $folder 'run.json') -SchemaFile (Join-Path $schemas 'run-record.schema.json')
$all = (Get-ChildItem $folder -Recurse -File | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
Write-Host "RESULT export valid=$valid useCase=$($snap.useCase) kind=$($snap.extensions.recovery.kind) configFiles=$(@($snap.files | Where-Object kind -eq 'config').Count) tokenLeaked=$($all -match 'secret-registration-token') tokenPresent=$($all -match '"registrationInfo": "<present>"') roleAssignments=$((Get-Content (Join-Path $folder 'config/roleassignments.json') -Raw | ConvertFrom-Json).Count)"

[System.Threading.Thread]::Sleep(1100)
$global:St.recovery.maxSessions = 10
Invoke-ScenarioStep 'export-drift' { & ./scripts/ops/Export-AvdConfiguration.ps1 -NamePrefix avdlz -Environment dev -LocalRoot $root }
$snap = (& $snapshots)[-1]
$folder = Join-Path $runs $snap.runId
$drift = @(Get-Content (Join-Path $folder 'config/drift.json') -Raw | ConvertFrom-Json)
Write-Host "RESULT drift changes=$($drift.Count) path=$($drift[0].Path) before=$($drift[0].Before) after=$($drift[0].After)"

# What Stop-AvdRunRecorder.ps1 -CopyTo github records after reading the copy back: each file gzip-compressed,
# committed under runs/<runId>/<path>.gz, its SHA-256 in copies[]. The fake gh below serves those blobs.
$global:Blobs = @{}
$run = Get-Content (Join-Path $folder 'run.json') -Raw | ConvertFrom-Json -AsHashtable
foreach ($f in $run.files) {
  $ms = [IO.MemoryStream]::new(); $z = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionLevel]::Optimal)
  $bytes = [IO.File]::ReadAllBytes((Join-Path $folder $f.path)); $z.Write($bytes, 0, $bytes.Length); $z.Dispose()
  $gz = $ms.ToArray(); $sha = -join ([Security.Cryptography.SHA256]::HashData($gz) | ForEach-Object { $_.ToString('x2') })
  $f.gzSha256 = $sha; $f.copies = @(@{ target = 'github'; verifiedAt = $now.ToString('yyyy-MM-ddTHH:mm:ssZ'); sha256 = $sha })
  $global:Blobs["runs/$($snap.runId)/$($f.path).gz"] = [Convert]::ToBase64String($gz)
}
$run | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $folder 'run.json')
function global:gh {
  $a = $args -join ' '
  if ($a -match 'git/trees/runs') { $i = 0; foreach ($k in $global:Blobs.Keys) { $i++; "$k blob$i" }; $global:LASTEXITCODE = 0; return }
  if ($a -match 'git/blobs/blob(\d+)') { $k = @($global:Blobs.Keys)[[int]$Matches[1] - 1]; $global:LASTEXITCODE = 0; return $global:Blobs[$k] }
  $global:LASTEXITCODE = 1; 'HTTP 404: Not Found'
}
$env:AVD_PRIVATE_REPO = 'contoso/avd-private'

Invoke-ScenarioStep 'status-copied' { & ./scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment dev -LocalRoot $root } *>&1 | Tee-Object -Variable out
$s = & $state $out
Write-Host "RESULT status-copied met=$($s.context.met)/$($s.context.total) ids=$(& $ids $s)"

Invoke-ScenarioStep 'verify' { & ./scripts/ops/Test-AvdRecoveryCopies.ps1 -NamePrefix avdlz -Environment dev -LocalRoot $root }
$k = @($global:Blobs.Keys | Where-Object { $_ -like '*hostpools.json.gz' })[0]
$global:Blobs[$k] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('tampered'))
Invoke-ScenarioStep 'verify-corrupted' { & ./scripts/ops/Test-AvdRecoveryCopies.ps1 -NamePrefix avdlz -Environment dev -LocalRoot $root } *>&1 | Tee-Object -Variable out
Write-Host "RESULT verify-corrupted mismatch=$(($out | Out-String) -match 'config/hostpools.json')"

$before = $global:Calls.Count
Invoke-ScenarioStep 'test-plan' { & ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix avdlz -Environment dev -LocalRoot $root } *>&1 | Tee-Object -Variable out
$writes = @($global:Calls | Select-Object -Skip $before | Where-Object { $_ -match '^ARM (PUT|POST|PATCH|DELETE)' }).Count
$s = & $state $out
Write-Host "RESULT test-plan writes=$writes status=$($s.status) estimate=$((($out | Out-String) -match 'Estimate for 2 h\s+0\.05 USD'))"

Invoke-ScenarioStep 'test-go' { & ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix avdlz -Environment dev -Go -LocalRoot $root } *>&1 | Tee-Object -Variable out
$s = & $state $out
$test = Get-ChildItem $runs -Filter run.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.extensions.recovery.kind -eq 'test' } | Select-Object -Last 1
$body = $global:St.recovery.restored[0].body.properties
$valid = Test-Json -Path (Join-Path (Join-Path $runs $test.runId) 'run.json') -SchemaFile (Join-Path $schemas 'run-record.schema.json')
Write-Host "RESULT test-go status=$($s.status) outcome=$($test.extensions.recovery.outcome) valid=$valid recoveryType=$($body.recoveryType) intoNew=$($body.targetDetails.targetResourceId -match '/storageAccounts/strt') rpoMinutes=$($test.extensions.recovery.measured.rpoMinutes -ge 299) created=$(@($global:St.recovery.created).Count)"

Invoke-ScenarioStep 'status-tested' { & ./scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment dev -LocalRoot $root } *>&1 | Tee-Object -Variable out
$s = & $state $out
Write-Host "RESULT status-tested met=$($s.context.met)/$($s.context.total) ids=$(& $ids $s)"

$rg = $test.extensions.recovery.target.resourceGroup
$global:St.rgs = @($global:St.rgs) + $rg
Invoke-ScenarioStep 'test-cleanup' { & ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix avdlz -Environment dev -Cleanup -RunId $test.runId -LocalRoot $root }
$after = Get-Content (Join-Path (Join-Path $runs $test.runId) 'run.json') -Raw | ConvertFrom-Json
Write-Host "RESULT test-cleanup rgGone=$($global:St.rgs -notcontains $rg) teardown=$($after.teardown.status) sourceKept=$($global:St.rgs -contains 'rg-avdlz-dev-storage')"

$global:St.recovery.restoreStatus = 'Failed'; $global:St.recovery.restored = @(); $global:St.recovery.jobPolls = 0
Invoke-ScenarioStep 'test-go-failed' { & ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix avdlz -Environment dev -Go -LocalRoot $root } *>&1 | Tee-Object -Variable out
Write-Host "RESULT test-go-failed errorShown=$(($out | Out-String) -match 'UserErrorStorageAccountInternetRoutingNotSupported')"

Invoke-ScenarioStep 'status-r1-snapshot' { & ./scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment dev -RecoveryTier R1 -RecoveryLocation southcentralus -LocalRoot $root } *>&1 | Tee-Object -Variable out
$s = & $state $out
Write-Host "RESULT status-r1-snapshot ids=$(& $ids $s)"
$global:St.recovery.vaulted = $true; $global:St.recovery.gallery = $true; $global:St.recovery.replicaRegions = @('North Central US', 'South Central US')
Invoke-ScenarioStep 'status-r1-vaulted' { & ./scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment dev -RecoveryTier R1 -RecoveryLocation southcentralus -LocalRoot $root } *>&1 | Tee-Object -Variable out
$s = & $state $out
Write-Host "RESULT status-r1-vaulted ids=$(& $ids $s)"
Remove-Item -Recurse -Force $root
