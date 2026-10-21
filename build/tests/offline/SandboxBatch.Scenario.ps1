# Sandbox batches from Cloud Shell (docs/sandbox-runs.md, decision 0020), records on this disk
# (-Local): build a batch from item files, a wrong go refused, the right go, a group with a failed
# test, a group that leaves a resource behind (stop the batch, clean up, close again), and a group
# Cloud Shell dropped part way, resumed without deploying twice and never started a second time.
# Item scripts add and remove rows of the Resource Graph inventory the mock serves.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) "avdlz-batch-$PID"
$null = New-Item -ItemType Directory -Path $work -Force
$records = Join-Path $work 'records'
$items = Join-Path $work 'items'
$null = New-Item -ItemType Directory -Path $items -Force
$inv = Join-Path $work 'inventory.json'
$log = Join-Path $work 'steps.log'
$global:St.spend = @{ inventoryFile = $inv; monthToDate = 12.5; budgets = @(@{ name = 'sandbox-spend'; properties = @{ amount = 150; timeGrain = 'Monthly' } }) }

# A local repo standing in for GitHub: the items' source, pinned by commit.
$src = Join-Path $work 'remote/contoso/lab-tests'
$null = New-Item -ItemType Directory -Path $src -Force
git -C $src init -q -b main; git -C $src config user.email t@example.invalid; git -C $src config user.name t
'x' | Set-Content (Join-Path $src 'README.md'); git -C $src add -A; git -C $src commit -q -m one
$sha = (git -C $src rev-parse HEAD).Trim()

# deploy adds a resource group row; teardown removes it unless told to leave it.
'param($rg) $r = @(if (Test-Path $env:INV) { Get-Content $env:INV -Raw | ConvertFrom-Json | ForEach-Object { $_ } }); $r += [pscustomobject]@{ id = "/subscriptions/x/resourcegroups/$rg"; type = ''microsoft.resources/subscriptions/resourcegroups''; resourceGroup = $rg; name = $rg }; ConvertTo-Json @($r) | Set-Content $env:INV' | Set-Content (Join-Path $work 'add-rg.ps1')
'param($rg) $r = @(Get-Content $env:INV -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.name -ne $rg }); ConvertTo-Json @($r) | Set-Content $env:INV' | Set-Content (Join-Path $work 'del-rg.ps1')
$env:INV = $inv
$deploy = { param($rg) "echo deploy $rg >> '$log'`npwsh -NoProfile -File '$work/add-rg.ps1' $rg" }
$teardown = { param($rg) "echo teardown $rg >> '$log'`npwsh -NoProfile -File '$work/del-rg.ps1' $rg" }
$item = {
  param([int] $n, [string] $key, [string] $test, [string] $down)
  [ordered]@{
    schema = 'sandbox-run/v1'; number = $n; purpose = "Check $n"; source = "contoso/lab-tests@$sha"; tests = "Check $n passes"
    kind = 'avd'; sandbox = 'lab'; region = 'northcentralus'; shape = 'dev LZ, 1 x D2as_v5'; deploymentKey = $key
    ratePerHour = 0.5; hours = 2; hoursWhenSharing = 1; estimateNote = 'Retail prices'; unattended = $true
    deploy = (& $deploy "rg-$key"); test = $test; teardown = $down; evidence = 'Spend record'
  } | ConvertTo-Json | Set-Content (Join-Path $items "item-$n.json")
}
& $item 1 'lz-a' "echo test 1 >> '$log'" (& $teardown 'rg-lz-a')
& $item 2 'lz-a' "echo test 2 >> '$log'; exit 1" ''
& $item 3 'lz-b' "echo test 3 >> '$log'" "echo teardown rg-lz-b left >> '$log'"
& $item 4 'lz-c' "echo test 4 >> '$log'" (& $teardown 'rg-lz-c')
$now = [datetime]::new(2026, 10, 21, 1, 0, 0, [DateTimeKind]::Utc)
$batchId = 'b20261021-0100'
$common = @{ RecordsPath = $records; Local = $true }
$batchArgs = @{ BatchId = $batchId; MonthlyCap = 150; RunCap = 25; WorkRoot = (Join-Path $work 'src'); CloneBase = (Join-Path $work 'remote') } + $common
$results = { param($g) Get-Content (Join-Path $records "queue/2026-10/$batchId/results-$g.json") -Raw | ConvertFrom-Json }
$count = { param($line) @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -eq $line }).Count }

Invoke-ScenarioStep 'build' { & ./scripts/ops/New-AvdSandboxBatch.ps1 -ItemsPath $items -MonthToDate 12.5 -Now $now -BatchCap 10 -MonthlyCap 150 -RunCap 25 @common }
$batch = Get-Content (Join-Path $records "queue/2026-10/$batchId/batch.json") -Raw | ConvertFrom-Json
Write-Host "RESULT build groups=$(@($batch.groups).Count) total=$($batch.total) g1=$(($batch.groups[0].items) -join '+') unattended=$($batch.groups[0].unattended) md=$(Test-Path (Join-Path $records "queue/2026-10/$batchId/batch.md"))"

Invoke-ScenarioStep 'no-approval' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G1 @batchArgs }
Invoke-ScenarioStep 'wrong-go' { try { & ./scripts/ops/Approve-AvdSandboxBatch.ps1 -BatchId $batchId -Phrase "go batch $batchId `$0.01" @common } catch { Write-Host "REFUSED $($_.Exception.Message)"; $global:LASTEXITCODE = 1 } }
Invoke-ScenarioStep 'approve' { & ./scripts/ops/Approve-AvdSandboxBatch.ps1 -BatchId $batchId -Phrase ("go batch {0} `${1:N2}" -f $batchId, $batch.total) @common }

Invoke-ScenarioStep 'g1' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G1 @batchArgs }
$r = & $results G1
Write-Host "RESULT g1 outcome=$($r.outcome) steps=$(($r.steps | ForEach-Object { "$($_.step):$($_.exitCode)" }) -join ',') spend=$([bool]$r.spendRunId) tests=$(& $count 'test 1')$(& $count 'test 2')"
Invoke-ScenarioStep 'g1-again' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G1 @batchArgs }

Invoke-ScenarioStep 'g2-leftover' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G2 @batchArgs }
Write-Host "RESULT g2-leftover outcome=$((& $results G2).outcome)"
Invoke-ScenarioStep 'g2-cleaned' {
  pwsh -NoProfile -File (Join-Path $work 'del-rg.ps1') rg-lz-b
  & ./scripts/ops/Stop-AvdSpendRun.ps1 -Sandbox lab @common
}

# Cloud Shell dropped G3 during its test: the spend run is open, deploy finished, the test never did.
Invoke-ScenarioStep 'g3-dropped' {
  $global:LASTEXITCODE = 0
  & ./scripts/ops/Start-AvdSpendRun.ps1 -Sandbox lab -Kind avd -Purpose "batch $batchId G3" -Hours 2 -ManualAmount 1 -ManualNote 'approved' -MonthlyCap 150 -RunCap 25 @common
  bash -c ((Get-Content (Join-Path $items 'item-4.json') -Raw | ConvertFrom-Json).deploy)
  $t = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
  [ordered]@{ schema = 'sandbox-batch-results/v1'; batchId = $batchId; group = 'G3'; approvedBy = 'operator'; startedAt = $t; finishedAt = $null; spendRunId = $null; runId = $null; outcome = 'running'
    steps = @([ordered]@{ step = 'start'; item = 0; exitCode = 0; startedAt = $t; minutes = 0.2 }, [ordered]@{ step = 'deploy'; item = 4; exitCode = 0; startedAt = $t; minutes = 9 }, [ordered]@{ step = 'test'; item = 4; exitCode = $null; startedAt = $t; minutes = $null })
    keeps = @() } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $records "queue/2026-10/$batchId/results-G3.json")
}
Invoke-ScenarioStep 'status' { & ./scripts/ops/Get-AvdSandboxBatchStatus.ps1 @common }
Invoke-ScenarioStep 'g3-start-again' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G3 @batchArgs }
Invoke-ScenarioStep 'g3-resume' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G3 -Resume @batchArgs }
$r = & $results G3
Write-Host "RESULT g3-resume outcome=$($r.outcome) deploys=$(& $count 'deploy rg-lz-c') tests=$(& $count 'test 4') teardowns=$(& $count 'teardown rg-lz-c')"
Invoke-ScenarioStep 'g3-teardown-only' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G3 -TeardownOnly @batchArgs }
Write-Host "RESULT g3-teardown-only teardowns=$(& $count 'teardown rg-lz-c')"
Invoke-ScenarioStep 'status-end' { & ./scripts/ops/Get-AvdSandboxBatchStatus.ps1 @common }

# A second batch: two recorded groups (the run recorder from a stand-in landing zone checkout at a
# pinned commit), one of which the recorder refuses, and a group that keeps output with no run store.
$lzStub = Join-Path $work 'remote/contoso/avd-landing-zone'
$null = New-Item -ItemType Directory -Path (Join-Path $lzStub 'scripts/ops') -Force
foreach ($n in 'Start-AvdRunRecorder', 'Stop-AvdRunRecorder') {
  "Add-Content -Path '$log' -Value ('$n ' + (`$args -join ' ')); if ('$n' -eq 'Start-AvdRunRecorder' -and (Test-Path '$work/refuse')) { exit 1 }; exit 0" | Set-Content (Join-Path $lzStub "scripts/ops/$n.ps1")
}
git -C $lzStub init -q -b master; git -C $lzStub config user.email t@example.invalid; git -C $lzStub config user.name t
git -C $lzStub add -A; git -C $lzStub commit -q -m recorder
$lzSha = (git -C $lzStub rev-parse HEAD).Trim()
Remove-Item (Join-Path $items '*.json')
& $item 5 'lz-d' "echo test 5 >> '$log'" (& $teardown 'rg-lz-d')
& $item 6 'lz-e' "echo test 6 >> '$log'" (& $teardown 'rg-lz-e')
& $item 7 'lz-f' "echo test 7 >> '$log'" (& $teardown 'rg-lz-f')
foreach ($n in 5, 6) { $f = Join-Path $items "item-$n.json"; $j = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable; $j.record = 'parameters/dev.bicepparam'; $j | ConvertTo-Json | Set-Content $f }
$f = Join-Path $items 'item-7.json'; $j = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable; $j.keep = @('~/lab-output'); $j | ConvertTo-Json | Set-Content $f
$batchId = 'b20261021-0200'
$batchArgs.BatchId = $batchId
Invoke-ScenarioStep 'build2' { & ./scripts/ops/New-AvdSandboxBatch.ps1 -ItemsPath $items -MonthToDate 12.5 -Now $now.AddHours(1) -BatchCap 10 -MonthlyCap 150 -RunCap 25 -RecorderRepo contoso/avd-landing-zone -RecorderSha $lzSha @common }
$batch = Get-Content (Join-Path $records "queue/2026-10/$batchId/batch.json") -Raw | ConvertFrom-Json
Write-Host "RESULT build2 recorder=$($batch.groups[0].record.repo)@$($batch.groups[0].record.sha -eq $lzSha)"
Invoke-ScenarioStep 'approve2' { & ./scripts/ops/Approve-AvdSandboxBatch.ps1 -BatchId $batchId -Phrase ("go batch {0} `${1:N2}" -f $batchId, $batch.total) @common }
Invoke-ScenarioStep 'recorded' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G1 @batchArgs }
$r = & $results G1
$order = @(Get-Content $log | Where-Object { $_ -match '^(Start-AvdRunRecorder|Stop-AvdRunRecorder .*-BeforeCleanup|Stop-AvdRunRecorder .*-Status|deploy rg-lz-d|teardown rg-lz-d|test 5)' } | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' })
Write-Host "RESULT recorded outcome=$($r.outcome) runId=$($r.runId) steps=$(($r.steps | ForEach-Object { $_.step }) -join ',')"
Write-Host "RESULT recorded order=$($order -join '|')"
'x' | Set-Content (Join-Path $work 'refuse')
Invoke-ScenarioStep 'recorder-refused' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G2 @batchArgs }
Write-Host "RESULT recorder-refused outcome=$((& $results G2).outcome) deploys=$(& $count 'deploy rg-lz-e')"
Invoke-ScenarioStep 'keep-local' { & ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -Group G3 @batchArgs }
Write-Host "RESULT keep-local deploys=$(& $count 'deploy rg-lz-f')"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
