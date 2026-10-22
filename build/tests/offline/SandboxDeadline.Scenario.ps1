# Teardown that doesn't depend on the shell (decision 0021), with records in the run store: a group
# refuses to start, claiming nothing, when the deadline teardown is missing or can't be armed; a
# runner that stops on an error tears its group down before it ends; the deadline runbook, as
# Automation runs it, deletes a dead group's landing zone (and leaves a closed one alone, and only
# deallocates when the approved teardown keeps the last copy); and the next group's block closes
# the dead group by itself before it starts.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) "avdlz-deadline-$PID"
$null = New-Item -ItemType Directory -Path $work -Force
$records = Join-Path $work 'records'
$items = Join-Path $work 'items'
$null = New-Item -ItemType Directory -Path $items -Force
$inv = Join-Path $work 'inventory.json'
$log = Join-Path $work 'steps.log'
$break = Join-Path $work 'break-records-once'
$sub = '00000000-aaaa-bbbb-cccc-000000000001'
$global:St.records = @{}; $global:St.recordsEtag = 0; $global:St.recordsBreakFile = $break
$aa = @{ runbook = $null; schedules = @{}; jobSchedules = @{}; failPut = $false }
$global:St.spend = @{ inventoryFile = $inv; monthToDate = 12.5; runStore = $true; automation = $aa; budgets = @(@{ name = 'sandbox-spend'; properties = @{ amount = 150; timeGrain = 'Monthly' } }) }

$src = Join-Path $work 'remote/contoso/lab-tests'
$null = New-Item -ItemType Directory -Path $src -Force
git -C $src init -q -b main; git -C $src config user.email t@example.invalid; git -C $src config user.name t
'x' | Set-Content (Join-Path $src 'README.md'); git -C $src add -A; git -C $src commit -q -m one
$sha = (git -C $src rev-parse HEAD).Trim()

# deploy adds the landing zone's hosts group and a VM in it; teardown removes the group.
'param($rg) $r = @(if (Test-Path $env:INV) { Get-Content $env:INV -Raw | ConvertFrom-Json | ForEach-Object { $_ } }); $r += [pscustomobject]@{ id = "/subscriptions/x/resourcegroups/$rg"; type = ''microsoft.resources/subscriptions/resourcegroups''; resourceGroup = $rg; name = $rg }; $r += [pscustomobject]@{ id = "/subscriptions/x/resourcegroups/$rg/providers/microsoft.compute/virtualmachines/avdlzdsh-001"; type = ''microsoft.compute/virtualmachines''; resourceGroup = $rg; name = ''avdlzdsh-001'' }; ConvertTo-Json @($r) | Set-Content $env:INV' | Set-Content (Join-Path $work 'add-rg.ps1')
'param($rg) $r = @(if (Test-Path $env:INV) { Get-Content $env:INV -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.resourceGroup -ne $rg -and $_.name -ne $rg } }); ConvertTo-Json @($r) | Set-Content $env:INV' | Set-Content (Join-Path $work 'del-rg.ps1')
$env:INV = $inv
$rg = 'rg-avdlz-dev-hosts'
$item = {
  param([int] $n, [string] $key, [string] $test, [string] $down)
  [ordered]@{
    schema = 'sandbox-run/v1'; number = $n; purpose = "Check $n"; source = "contoso/lab-tests@$sha"; tests = "Check $n passes"
    kind = 'avd'; sandbox = 'lab'; region = 'northcentralus'; shape = 'dev LZ, 1 x D2as_v5'; deploymentKey = $key
    ratePerHour = 0.5; hours = 2; hoursWhenSharing = 1; estimateNote = 'Retail prices'; unattended = $true
    deploy = "echo deploy $n >> '$log'`npwsh -NoProfile -File '$work/add-rg.ps1' $rg"; test = $test; teardown = $down; evidence = 'Spend record'
  } | ConvertTo-Json | Set-Content (Join-Path $items "item-$n.json")
}
$down = { param($n) "echo teardown $n -DiscardLastCopy >> '$log'`npwsh -NoProfile -File '$work/del-rg.ps1' $rg" }
# G1's test makes the next records write fail once: the runner stops on an error, outside any step.
& $item 1 'lz-a' "echo test 1 >> '$log'; touch '$break'" (& $down 1)
& $item 2 'lz-b' "echo test 2 >> '$log'" (& $down 2)
& $item 3 'lz-c' "echo test 3 >> '$log'" (& $down 3)
$now = [datetime]::new(2026, 10, 21, 1, 0, 0, [DateTimeKind]::Utc)
$batchId = 'b20261021-0100'
$batchArgs = @{ BatchId = $batchId; MonthlyCap = 150; RunCap = 25; WorkRoot = (Join-Path $work 'src'); CloneBase = (Join-Path $work 'remote'); RecordsPath = $records }
$dir = "queue/2026-10/$batchId"
$results = { param($g) $b = $global:St.records["$dir/results-$g.json"]; if ($b) { $b.content | ConvertFrom-Json } }
$count = { param($line) @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -eq $line }).Count }
$armed = { "schedules=$(@($aa.schedules.Keys) -join ',') jobSchedules=$($aa.jobSchedules.Count)" }

Invoke-ScenarioStep 'build' { & ./scripts/ops/New-AvdSandboxBatch.ps1 -ItemsPath $items -MonthToDate 12.5 -Now $now -BatchCap 10 -MonthlyCap 150 -RunCap 25 -RecordsPath $records }
$batch = Get-Content (Join-Path $records "$dir/batch.json") -Raw | ConvertFrom-Json
Write-Host "RESULT build groups=$(@($batch.groups).Count) inStore=$($global:St.records.ContainsKey("$dir/batch.json"))"
Invoke-ScenarioStep 'approve' { & ./scripts/ops/Approve-AvdSandboxBatch.ps1 -BatchId $batchId -Phrase ("go batch {0} `${1:N2}" -f $batchId, $batch.total) -RecordsPath $records }

Invoke-ScenarioStep 'no-runbook' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G1 @batchArgs }
Write-Host "RESULT no-runbook claimed=$([bool](& $results G1)) deploys=$(& $count 'deploy 1')"
$aa.runbook = 'Published'; $aa.failPut = $true
Invoke-ScenarioStep 'arm-fails' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G1 @batchArgs }
Write-Host "RESULT arm-fails claimed=$([bool](& $results G1)) deploys=$(& $count 'deploy 1') $(& $armed)"
$aa.failPut = $false

Invoke-ScenarioStep 'crash' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G1 @batchArgs }
$r = & $results G1
Write-Host "RESULT crash outcome=$($r.outcome) steps=$(($r.steps | ForEach-Object { "$($_.step):$($_.exitCode)" }) -join ',') teardowns=$(& $count 'teardown 1 -DiscardLastCopy') action=$($r.deadline.action) prefix=$($r.deadline.resourceGroupPrefix) armed=$($r.deadline.armed) $(& $armed)"

# The deadline runbook as Automation starts it (managed identity endpoint), for G1, which closed clean.
$env:IDENTITY_ENDPOINT = 'http://127.0.0.1:42/msi/token'; $env:IDENTITY_HEADER = 'test-header'
Import-Module ./scripts/ops/AvdRunRecorder.psm1 -Force
$sa = Get-AvdRunStoreName -SubscriptionId $sub
$rb = { param($g, $action) @{ SubscriptionId = $sub; StorageAccount = $sa; ResultsBlob = "$dir/results-$g.json"; BatchId = $batchId; Group = $g; ResourceGroupPrefix = 'rg-avdlz-dev-'; Action = $action; WaitMinutes = 1 } }
$p = & $rb G1 Delete
Invoke-ScenarioStep 'runbook-closed' { & ./scripts/automation/Invoke-AvdSandboxDeadline.ps1 @p }
Write-Host "RESULT runbook-closed outcome=$(($global:St.records["$dir/deadline-G1.json"].content | ConvertFrom-Json).outcome)"

# G2: Cloud Shell died during its test, hours ago. Its spend run is open and its landing zone is still there.
Invoke-ScenarioStep 'g2-died' {
  $global:LASTEXITCODE = 0
  & ./scripts/ops/Start-AvdSpendRun.ps1 -Sandbox lab -Kind avd -Purpose "batch $batchId G2" -Hours 2 -ManualAmount 1 -ManualNote 'approved' -MonthlyCap 150 -RunCap 25 -RecordsPath $records
  pwsh -NoProfile -File (Join-Path $work 'add-rg.ps1') $rg
  $t = (Get-Date).ToUniversalTime().AddHours(-6).ToString('o')
  $json = [ordered]@{ schema = 'sandbox-batch-results/v1'; batchId = $batchId; group = 'G2'; approvedBy = 'operator'; startedAt = $t; finishedAt = $null; spendRunId = $null; runId = $null; outcome = 'running'
    steps = @([ordered]@{ step = 'start'; item = 0; exitCode = 0; startedAt = $t; minutes = 0.2 }, [ordered]@{ step = 'deploy'; item = 2; exitCode = 0; startedAt = $t; minutes = 9 }, [ordered]@{ step = 'test'; item = 2; exitCode = $null; startedAt = $t; minutes = $null })
    keeps = @(); deadline = [ordered]@{ armed = $true; fireAt = $t; action = 'Delete'; resourceGroupPrefix = 'rg-avdlz-dev-'; schedule = "deadline-$batchId-G2"; jobSchedule = 'js-g2' } } | ConvertTo-Json -Depth 10
  $global:St.recordsEtag++; $global:St.records["$dir/results-G2.json"] = @{ etag = "r$($global:St.recordsEtag)"; content = $json }
}
$p = & $rb G2 Delete
Invoke-ScenarioStep 'runbook-whatif' { & ./scripts/automation/Invoke-AvdSandboxDeadline.ps1 @p -WhatIf }
Write-Host "RESULT runbook-whatif rgLeft=$((Get-Content $inv -Raw) -match $rg) recorded=$($global:St.records.ContainsKey("$dir/deadline-G2.json"))"
Invoke-ScenarioStep 'runbook-dead' { & ./scripts/automation/Invoke-AvdSandboxDeadline.ps1 @p }
$d = $global:St.records["$dir/deadline-G2.json"].content | ConvertFrom-Json
Write-Host "RESULT runbook-dead outcome=$($d.outcome) found=$($d.found -join ',') deleted=$($d.deleted -join ',') rgLeft=$((Get-Content $inv -Raw) -match $rg)"
Invoke-ScenarioStep 'status' { & ./scripts/ops/Get-AvdSandboxBatchStatus.ps1 -RecordsPath $records }

# Approved teardown that keeps the last copy: the runbook only deallocates, and keeps the group.
pwsh -NoProfile -File (Join-Path $work 'add-rg.ps1') $rg
$p = & $rb G9 Deallocate; $p.ResultsBlob = "$dir/results-G9.json"
Invoke-ScenarioStep 'runbook-deallocate' { & ./scripts/automation/Invoke-AvdSandboxDeadline.ps1 @p }
$d = $global:St.records["$dir/deadline-G9.json"].content | ConvertFrom-Json
Write-Host "RESULT runbook-deallocate outcome=$($d.outcome) deallocated=$($d.deallocated -join ',') rgLeft=$((Get-Content $inv -Raw) -match $rg)"
pwsh -NoProfile -File (Join-Path $work 'del-rg.ps1') $rg
Remove-Item env:IDENTITY_ENDPOINT, env:IDENTITY_HEADER

# G3's block: G2's runner is gone, so it closes G2 first (teardown and spend close, with evidence),
# then stops, because G2 stopped the batch; once that's seen, it runs and disarms its own deadline.
Invoke-ScenarioStep 'g3' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G3 @batchArgs }
$r2 = & $results G2
Write-Host "RESULT g3 g2outcome=$($r2.outcome) g2closed=$([bool]@($r2.steps | Where-Object { $_.step -eq 'close' -and $_.exitCode -eq 0 }).Count) g3claimed=$([bool](& $results G3))"
Invoke-ScenarioStep 'g3-continue' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G3 -ContinueAfterStop @batchArgs }
$r = & $results G3
Write-Host "RESULT g3-continue outcome=$($r.outcome) armed=$($r.deadline.armed) disarmed=$([bool]$r.deadline.disarmedAt) $(& $armed)"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
