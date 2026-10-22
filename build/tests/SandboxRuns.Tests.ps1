#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Sandbox runs (docs/sandbox-runs.md, decision 0020): the spend gate, teardown evidence, the records
# store and sandbox batches, as pure functions. The scripts run end to end in the SandboxBatch
# offline scenario. Values are contoso and neutral; nothing here names a real sandbox.
# Run: Invoke-Pester ./build/tests

BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../../scripts/ops/AvdSpend.psm1') -Force
  Import-Module (Join-Path $PSScriptRoot '../../scripts/ops/AvdSandboxBatch.psm1') -Force
  $script:Now = [datetime]::new(2026, 10, 21, 1, 0, 0, [DateTimeKind]::Utc)
  $script:Sub = '00000000-0000-0000-0000-000000000000'

  # An issue body the way GitHub writes one from the Sandbox run form.
  function script:New-Body([hashtable] $Over = @{}, [string[]] $Drop = @()) {
    $f = [ordered]@{
      'Purpose' = 'Rebuild round trip'; 'Source' = 'contoso/lab-tests#15'; 'Tests' = 'Rebuild map matches'
      'Kind' = 'avd'; 'Sandbox' = 'lab'; 'Region' = 'northcentralus'; 'Region reason' = '_No response_'
      'Shape' = 'dev LZ, 1 x D2as_v5'; 'Deployment key' = 'lz-dev-1xD2as'; 'Rate per hour' = '0.43'; 'Fixed cost' = '0'
      'Hours' = '3'; 'Hours when sharing' = '1'; 'Estimate note' = 'Retail prices, 2026-10-20'; 'Unattended' = 'No'
      'Deploy' = "``````bash`necho deploy`n``````"; 'Test' = "``````bash`necho test`n``````"; 'Teardown' = "``````bash`necho teardown`n``````"
      'Evidence' = 'Spend record'; 'Depends on' = '_No response_'
    }
    foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
    (@($f.Keys | Where-Object { $_ -notin $Drop } | ForEach-Object { "### $_`n`n$($f[$_])`n" })) -join "`n"
  }
  function script:New-Issue([int] $Number, [hashtable] $Over = @{}, [string[]] $Labels = @('sandbox-run', 'queue:ready'), [string[]] $Drop = @()) {
    [pscustomobject]@{ number = $Number; title = "Sandbox run: $Number"; body = (New-Body $Over $Drop); labels = @($Labels | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
  }

  # The shape of Get-AvdCostEstimate's output (decision 0010).
  $script:Monthly = @{
    currency = 'USD'; location = 'northcentralus'; activeHoursPerWeek = 50; total = 180.0; alwaysOnTotal = 300.0
    lines = @(
      @{ key = 'compute'; item = 'Session hosts (2 x Standard_E4as_v5)'; quantity = 433.3; unit = 'host-hours'; unitPrice = 0.226; monthly = 97.93; meter = 'Virtual Machines Easv5 Series / E4as v5' }
      @{ key = 'osdisk'; item = 'OS disks (2 x Premium SSD P10)'; quantity = 2; unit = 'disks'; unitPrice = 19.71; monthly = 39.42; meter = 'Premium SSD Managed Disks / P10 LRS Disk' }
      @{ key = 'natgateway'; item = 'NAT Gateway'; quantity = 730; unit = 'hours'; unitPrice = 0.045; monthly = 32.85; meter = 'NAT Gateway / Standard Gateway' }
    )
    unpriced = @(); excluded = @('Log Analytics ingestion and retention (per GB)')
  }
  function script:New-Row($id, $type, $rg, $name) { [pscustomobject]@{ id = $id.ToLower(); type = $type; resourceGroup = $rg; name = $name } }
  function script:Get-Inventory([string[]] $Groups, [string[]] $Vms) {
    @($Groups | ForEach-Object { New-Row "/subscriptions/$Sub/resourceGroups/$_" 'microsoft.resources/subscriptions/resourcegroups' $_ $_ }) +
    @($Vms | ForEach-Object { $rg, $n = $_ -split '/'; New-Row "/subscriptions/$Sub/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/$n" 'microsoft.compute/virtualmachines' $rg $n })
  }
}

Describe 'Spend estimates' {
  It 'reads the estimate from the preflight state line' {
    $line = "noise`n<<<AVDLZ-STATE $(@{ v = 1; stage = 'predeploy'; context = @{ estimate = $Monthly } } | ConvertTo-Json -Depth 10 -Compress) AVDLZ-STATE>>>`nmore"
    (Get-AvdSpendPreflightEstimate -Text $line).total | Should -Be 180
  }
  It 'says what is missing when the preflight had no sizing' {
    { Get-AvdSpendPreflightEstimate -Text '<<<AVDLZ-STATE {"v":1,"context":{}} AVDLZ-STATE>>>' } | Should -Throw '*no cost estimate*'
  }
  It 'prices hosts for every run hour and prorates the rest' {
    $e = Get-AvdSpendRunEstimate -Monthly $Monthly -RunHours 10 -Hosts 2 -UsageAllowancePercent 20
    ($e.lines | Where-Object key -eq 'compute').cost | Should -Be 4.52        # 0.226 x 2 x 10
    ($e.lines | Where-Object key -eq 'osdisk').cost | Should -Be 0.54         # 39.42 x 10 / 730
    ($e.lines | Where-Object key -eq 'natgateway').cost | Should -Be 0.45
    $e.subtotal | Should -Be 5.51
    $e.total | Should -Be ([math]::Round(5.51 * 1.2, 2))
    $e.costPerDayIfLeftUp | Should -Be ([math]::Round(300 * 24 / 730 * 1.2, 2))
  }
}

Describe 'Spend gate' {
  BeforeAll { $script:E = @{ total = 10.0; unpriced = @() } }
  It 'allows a run inside both caps' { (Get-AvdSpendGateDecision -Estimate $E -MonthlyCap 100 -RunCap 25 -MonthToDate 50).decision | Should -Be 'allowed' }
  It 'refuses a run over the per-run cap' { (Get-AvdSpendGateDecision -Estimate $E -MonthlyCap 100 -RunCap 5).reasons | Should -BeLike '*per-run cap*' }
  It 'refuses a run over what is left this month' {
    $g = Get-AvdSpendGateDecision -Estimate $E -MonthlyCap 100 -RunCap 25 -MonthToDate 95
    $g.decision | Should -Be 'refused'; $g.remaining | Should -Be 5
  }
  It 'refuses unpriced lines unless allowed' {
    $u = @{ total = 1.0; unpriced = @('Private endpoints (3)') }
    (Get-AvdSpendGateDecision -Estimate $u -RunCap 25).decision | Should -Be 'refused'
    (Get-AvdSpendGateDecision -Estimate $u -RunCap 25 -AllowUnpriced).decision | Should -Be 'allowed'
  }
  It 'counts no unpriced lines when ARM-style data leaves the list empty or out' {
    (Get-AvdSpendGateDecision -Estimate @{ total = 1.0; unpriced = @($null) } -RunCap 25).decision | Should -Be 'allowed'
    (Get-AvdSpendGateDecision -Estimate @{ total = 1.0 } -RunCap 25).decision | Should -Be 'allowed'
  }
  It 'refuses when no cap is set' { (Get-AvdSpendGateDecision -Estimate $E).decision | Should -Be 'refused' }
  It 'checks the calibrated cost when past runs cost more than estimated' {
    $runs = 1..3 | ForEach-Object { @{ kind = 'avd'; status = 'settled'; startedAt = "2026-10-0$($_)T00:00:00Z"; estimate = @{ total = 10.0 }; actual = @{ runCost = 15.0 } } }
    $c = Get-AvdSpendCalibration -Runs $runs -Kind 'avd'
    $c.medianActualToEstimate | Should -Be 1.5
    $g = Get-AvdSpendGateDecision -Estimate $E -RunCap 12 -Calibration $c
    $g.checkedCost | Should -Be 15; $g.decision | Should -Be 'refused'
  }
}

Describe 'Baseline, leftovers and run records' {
  It 'flags only what is new, and stores no IDs' {
    $before = Get-AvdSpendBaseline -Inventory (Get-Inventory @('standing') @('standing/jump')) -Now $Now
    ($before | ConvertTo-Json -Depth 5) | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-'
    $left = @(Get-AvdSpendLeftover -Baseline $before -Inventory (Get-Inventory @('standing', 'rg-avdlz') @('standing/jump', 'rg-avdlz/host-0')))
    $left.Count | Should -Be 2
    $left.name | Should -Contain 'host-0'
    $left.resourceGroup | Should -Contain 'rg-avdlz'
  }
  It 'splits cost into run, standing and subscription level, and finds charges after the close day' {
    $run = @{ baseline = @{ resourceGroups = @('standing') }; closedAt = '2026-10-02T18:00:00Z' }
    $rows = @(
      [pscustomobject]@{ date = '2026-10-01'; key = 'rg-avdlz'; cost = 3.0; currency = 'USD' }
      [pscustomobject]@{ date = '2026-10-02'; key = 'rg-avdlz'; cost = 2.0; currency = 'USD' }
      [pscustomobject]@{ date = '2026-10-03'; key = 'rg-avdlz'; cost = 0.5; currency = 'USD' }
      [pscustomobject]@{ date = '2026-10-01'; key = 'standing'; cost = 1.0; currency = 'USD' }
      [pscustomobject]@{ date = '2026-10-01'; key = ''; cost = 0.25; currency = 'USD' }
    )
    $a = Get-AvdSpendRunCost -Run $run -Rows $rows
    $a.runCost | Should -Be 5.5
    $a.chargesAfterCloseDay | Should -Be 0.5
    $a.standingCostSameDays | Should -Be 1
    $a.subscriptionLevelCost | Should -Be 0.25
  }
  It 'hides IDs' { Hide-AvdSpendId "/subscriptions/$Sub/x" | Should -Be '/subscriptions/<id>/x' }
  It 'finds what an approved batch must not freeze: GUIDs, emails and tenant domains' {
    Test-AvdSpendPrivateValue 'echo hello' | Should -BeNullOrEmpty
    Test-AvdSpendPrivateValue "az account set -s $Sub" | Should -Contain 'a GUID'
    Test-AvdSpendPrivateValue 'notify admin@contoso.com' | Should -Contain 'an email address'
    Test-AvdSpendPrivateValue 'login contoso.onmicrosoft.com' | Should -Contain 'a tenant domain'
  }
  It 'never reuses a run ID, so a second run in the same minute never overwrites the first record' {
    Get-AvdSpendRunId -Now $Now -Kind avd | Should -Be '20261021-0100-avd'
    Get-AvdSpendRunId -Now $Now -Kind avd -Existing '20261021-0100-avd' | Should -Be '20261021-0100b-avd'
    Get-AvdSpendRunId -Now $Now -Kind avd -Existing '20261021-0100-avd', '20261021-0100b-avd' | Should -Be '20261021-0100c-avd'
  }
  It 'reads runs oldest first by start time, and skips statements and files that are not runs' {
    $dir = Join-Path $TestDrive 'records'
    $mk = { param($id, $start) $null = Save-AvdSpendRun -RecordsPath $dir -Run ([ordered]@{ schema = 'spend-run/v1'; runId = $id; sandbox = 'lab'; startedAt = $start; status = 'closed' }) }
    & $mk '20261021-0100b-liquidware' '2026-10-21T01:00:30Z'
    & $mk '20261021-0100-liquidware' '2026-10-21T01:00:10Z'
    '{"schema":"spend-statement/v1"}' | Set-Content (Join-Path $dir 'lab/2026-10/statement.json')
    '{"note":"not a run"}' | Set-Content (Join-Path $dir 'lab/2026-10/other.json')
    @(Get-AvdSpendRun -RecordsPath $dir -Sandbox lab | ForEach-Object { $_.runId }) | Should -Be @('20261021-0100-liquidware', '20261021-0100b-liquidware')
  }
}

Describe 'Records store sync' {
  BeforeAll {
    # An in-memory 'records' container behind the three seams: list, read, conditional write.
    $script:Blobs = @{}
    $script:Etag = 0
    Mock -ModuleName AvdSpend Get-AvdRecordStoreBlob { foreach ($k in $script:Blobs.Keys) { [pscustomobject]@{ name = $k; etag = $script:Blobs[$k].etag } } }
    Mock -ModuleName AvdSpend Read-AvdRecordStoreBlob {
      New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null
      Set-Content -LiteralPath $Destination -Value $script:Blobs[$Name].content -NoNewline
      $script:Blobs[$Name].etag
    }
    Mock -ModuleName AvdSpend Write-AvdRecordStoreBlob {
      $have = $script:Blobs[$Name]
      if (($ETag -and (-not $have -or $have.etag -ne $ETag)) -or (-not $ETag -and $have)) { throw "conflict: $Name changed in the run store since this machine last read it." }
      $script:Etag++
      $script:Blobs[$Name] = @{ etag = "e$($script:Etag)"; content = (Get-Content -LiteralPath $Path -Raw) }
      "e$($script:Etag)"
    }
  }
  BeforeEach { $script:Blobs.Clear(); $script:A = Join-Path $TestDrive "a-$([guid]::NewGuid().ToString('N'))"; $script:B = Join-Path $TestDrive "b-$([guid]::NewGuid().ToString('N'))" }

  It 'pushes new and changed files, and pulls them into a second machine' {
    New-Item -ItemType Directory -Force -Path (Join-Path $A 'lab') | Out-Null
    'one' | Set-Content (Join-Path $A 'lab/run.json') -NoNewline
    @(Sync-AvdRunRecordStore -Direction Push -RecordsPath $A -Context 'x').action | Should -Be 'pushed'
    @(Sync-AvdRunRecordStore -Direction Push -RecordsPath $A -Context 'x').Count | Should -Be 0 -Because 'nothing changed'
    @(Sync-AvdRunRecordStore -Direction Pull -RecordsPath $B -Context 'x').action | Should -Be 'pulled'
    Get-Content (Join-Path $B 'lab/run.json') -Raw | Should -Be 'one'
  }
  It 'refuses to overwrite what another machine wrote first, and never deletes' {
    New-Item -ItemType Directory -Force -Path (Join-Path $A 'q'), (Join-Path $B 'q') | Out-Null
    'from a' | Set-Content (Join-Path $A 'q/results-G1.json') -NoNewline
    'from b' | Set-Content (Join-Path $B 'q/results-G1.json') -NoNewline
    $null = Sync-AvdRunRecordStore -Direction Push -RecordsPath $A -Context 'x'
    { Sync-AvdRunRecordStore -Direction Push -RecordsPath $B -Context 'x' } | Should -Throw 'conflict*'
    $script:Blobs['q/results-G1.json'].content | Should -Be 'from a'
    Remove-Item (Join-Path $A 'q/results-G1.json')
    $null = Sync-AvdRunRecordStore -Direction Push -RecordsPath $A -Context 'x'
    $script:Blobs.ContainsKey('q/results-G1.json') | Should -BeTrue -Because 'a push never deletes'
  }
  It 'keeps a local change that was not pushed when the store changed too' {
    New-Item -ItemType Directory -Force -Path (Join-Path $A 'lab') | Out-Null
    'v1' | Set-Content (Join-Path $A 'lab/run.json') -NoNewline
    $null = Sync-AvdRunRecordStore -Direction Push -RecordsPath $A -Context 'x'
    $null = Sync-AvdRunRecordStore -Direction Pull -RecordsPath $B -Context 'x'
    'v2 from b' | Set-Content (Join-Path $B 'lab/run.json') -NoNewline
    $null = Sync-AvdRunRecordStore -Direction Push -RecordsPath $B -Context 'x'
    'v2 from a' | Set-Content (Join-Path $A 'lab/run.json') -NoNewline
    @(Sync-AvdRunRecordStore -Direction Pull -RecordsPath $A -Context 'x').action | Should -Be 'kept-local'
    Get-Content (Join-Path $A 'lab/run.json') -Raw | Should -Be 'v2 from a'
  }
  It 'pushes only the files named, so a group claims its results file alone' {
    New-Item -ItemType Directory -Force -Path (Join-Path $A 'q') | Out-Null
    'x' | Set-Content (Join-Path $A 'q/results-G1.json'); 'y' | Set-Content (Join-Path $A 'q/other.json')
    @(Sync-AvdRunRecordStore -Direction Push -RecordsPath $A -Context 'x' -Only 'q/results-G1.json').name | Should -Be 'q/results-G1.json'
  }
  It 'does nothing in -Local mode' {
    { Save-AvdRunRecordStore -Store ([pscustomobject]@{ path = $A; context = $null; local = $true }) } | Should -Not -Throw
    $script:Blobs.Count | Should -Be 0
  }
}

Describe 'Items' {
  It 'reads the form fields, unwraps code blocks and parses numbers' {
    $i = Get-AvdBatchItem -Issue (New-Issue 7)
    $i.problems | Should -BeNullOrEmpty
    $i.rate | Should -Be 0.43
    $i.hours | Should -Be 3
    $i.sharedHours | Should -Be 1
    $i.deploy | Should -Be 'echo deploy'
    $i.regionReason | Should -Be ''
    $i.unattended | Should -BeFalse
  }
  It 'ends the last field at a footer rule, in every form an API edit leaves (docs/sandbox-runs.md)' {
    $footers = @(
      "`n`n---`n_Generated by [Claude Code](https://claude.ai/code)_`n",
      "`r`n`r`n---`r`n_Generated by [Claude Code](https://claude.ai/code)_",
      "`n`n---`n$([char]::ConvertFromUtf32(0x1F916)) Generated with [Claude Code](https://claude.com/claude-code)`n`nhttps://claude.ai/code/session_x`n",
      "`n`n---`n_Generated by [Claude Code](https://claude.ai/code)_`n`n---`n_Generated by [Claude Code](https://claude.ai/code)_`n"
    )
    foreach ($f in $footers) {
      $issue = New-Issue 7 @{ 'Depends on' = 'contoso/lab-tests#38' }
      $issue.body += $f
      $i = Get-AvdBatchItem -Issue $issue
      $i.problems | Should -BeNullOrEmpty
      $i.dependsOn | Should -Be @('contoso/lab-tests#38')
      $empty = New-Issue 7
      $empty.body += $f
      (Get-AvdBatchItem -Issue $empty).problems | Should -BeNullOrEmpty
    }
  }
  It 'keeps a "---" line inside a code block' {
    (Get-AvdBatchItem -Issue (New-Issue 7 @{ Deploy = "``````bash`necho a`n---`necho b`n``````" })).deploy | Should -Be "echo a`n---`necho b"
  }
  It 'defaults Hours when sharing to Hours' {
    (Get-AvdBatchItem -Issue (New-Issue 7 @{ 'Hours when sharing' = '_No response_' })).sharedHours | Should -Be 3
  }
  It 'lists what is missing or malformed' {
    $i = Get-AvdBatchItem -Issue (New-Issue 7 @{ 'Rate per hour' = 'cheap'; 'Source' = 'avd-current-state 15'; 'Depends on' = 'LZ 73' } -Drop 'Evidence')
    $i.problems | Should -Contain 'Missing: Evidence'
    $i.problems | Should -Contain 'Not a number: Rate per hour'
    ($i.problems -join ';') | Should -Match 'Source must be'
    ($i.problems -join ';') | Should -Match 'Depends on must list'
  }
  It 'allows another region only with a reason' {
    (Get-AvdBatchItem -Issue (New-Issue 7 @{ Region = 'eastus2' }) -DefaultRegion northcentralus).problems -join ';' | Should -Match 'needs a reason'
    (Get-AvdBatchItem -Issue (New-Issue 7 @{ Region = 'eastus2'; 'Region reason' = 'model quota' }) -DefaultRegion northcentralus).problems | Should -BeNullOrEmpty
    (Get-AvdBatchItem -Issue (New-Issue 7 @{ Region = 'eastus2' })).problems | Should -BeNullOrEmpty -Because 'with no usual region set, any region will do'
  }
}

Describe 'Groups and the batch plan' {
  BeforeAll {
    $script:A = Get-AvdBatchItem -Issue (New-Issue 15)
    $script:B = Get-AvdBatchItem -Issue (New-Issue 16 @{ Purpose = 'Last copy T1-T8'; Source = 'avd-ops/avd-landing-zone#73'; Hours = '4'; 'Hours when sharing' = '2'; 'Rate per hour' = '0.50' })
    $script:C = Get-AvdBatchItem -Issue (New-Issue 17 @{ Purpose = 'Spike'; 'Deployment key' = '_No response_'; Region = 'eastus2'; 'Region reason' = 'model quota'; 'Rate per hour' = '1'; Hours = '2'; 'Fixed cost' = '0.5' })
  }
  It 'shares one deployment between items with the same key' {
    $g = @(Get-AvdBatchGroup -Items @($A, $B, $C))
    $g.Count | Should -Be 2
    $g[0].lead | Should -Be 16          # most hours leads
    $g[0].items | Should -Be @(16, 15)
    $g[0].hours | Should -Be 5          # 4 + 1 shared
    $g[0].estimate | Should -Be 2.5     # 0.50 x 5
    $g[0].estimateIfAlone | Should -Be 3.29
    $g[0].deadlineHours | Should -Be 7.5
    $g[1].estimate | Should -Be 2.5     # 1 x 2 + 0.5
    $g[1].regionReason | Should -Be 'model quota'
  }
  It 'refuses a deployment no item can deploy and tear down' {
    $x = Get-AvdBatchItem -Issue (New-Issue 20 @{ Deploy = '_No response_' })
    (@(Get-AvdBatchGroup -Items @($x))[0]).problems | Should -Not -BeNullOrEmpty
  }
  It 'takes groups in order and leaves out what breaks a cap' {
    $g = @(Get-AvdBatchGroup -Items @($A, $B, $C))
    $p = Get-AvdBatchPlan -Groups $g -BatchCap 4
    $p.groups.Count | Should -Be 1
    $p.total | Should -Be 2.5
    $p.leftOut[0].reasons -join ';' | Should -Match 'batch cap'
    (Get-AvdBatchPlan -Groups $g -BatchCap 10 -MonthlyCap 100 -MonthToDate 98).groups.Count | Should -Be 0
    (Get-AvdBatchPlan -Groups $g -BatchCap 10 -RunCap 2).leftOut.Count | Should -Be 2
    (Get-AvdBatchPlan -Groups $g -BatchCap 10).total | Should -Be 5
  }
}

Describe 'Approval' {
  BeforeAll {
    $items = @((Get-AvdBatchItem -Issue (New-Issue 15)))
    $plan = Get-AvdBatchPlan -Groups @(Get-AvdBatchGroup -Items $items) -BatchCap 10
    $pins = @{ 'contoso/lab-tests#15' = @{ repo = 'contoso/lab-tests'; sha = ('a' * 40) } }
    $script:Batch = Get-AvdBatch -Plan $plan -Items $items -Pins $pins -Now $Now
  }
  It 'builds a hashed batch with pinned commits' {
    $Batch.batchId | Should -Be 'b20261021-0100'
    $Batch.total | Should -Be 1.29
    $Batch.groups[0].members[0].sha | Should -Be ('a' * 40)
    $Batch.hash | Should -Be (Get-AvdBatchHash -Batch $Batch)
  }
  It 'takes only this batch at this total' {
    $a = Get-AvdBatchApproval -Batch $Batch -Phrase 'Go batch b20261021-0100 $1.29' -ApprovedBy operator -Via cloudshell -Now $Now
    $a.hash | Should -Be $Batch.hash
    (Test-AvdBatchApproval -Batch $Batch -Approval $a).valid | Should -BeTrue
    { Get-AvdBatchApproval -Batch $Batch -Phrase 'go batch b20261021-0100 $1.00' -ApprovedBy operator -Via cloudshell -Now $Now } | Should -Throw '*totals 1.29*'
    { Get-AvdBatchApproval -Batch $Batch -Phrase 'go batch b1 $1.29' -ApprovedBy operator -Via cloudshell -Now $Now } | Should -Throw '*not b20261021-0100*'
    { Get-AvdBatchApproval -Batch $Batch -Phrase 'looks good' -ApprovedBy operator -Via cloudshell -Now $Now } | Should -Throw 'Not an approval*'
  }
  It 'is void once the batch changes' {
    $a = Get-AvdBatchApproval -Batch $Batch -Phrase 'go batch b20261021-0100 $1.29' -ApprovedBy operator -Via cloudshell -Now $Now
    $changed = $Batch | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -AsHashtable
    $changed.groups[0].members[0].sha = 'b' * 40
    (Test-AvdBatchApproval -Batch $changed -Approval $a).valid | Should -BeFalse
    (Test-AvdBatchApproval -Batch $Batch -Approval $null).valid | Should -BeFalse
  }
}

Describe 'Stop rules' {
  It 'never starts when the spend run does not open' { (Get-AvdBatchNextStep -Step start -ExitCode 1).action | Should -Be 'stop-batch' }
  It 'tears down after a failed deploy and goes on' { (Get-AvdBatchNextStep -Step deploy -ExitCode 1).action | Should -Be 'teardown' }
  It 'carries on after a failed test' { (Get-AvdBatchNextStep -Step test -ExitCode 1 -MoreTests $true).action | Should -Be 'next-test' }
  It 'tears down and stops the batch past the deadline' {
    $n = Get-AvdBatchNextStep -Step test -ExitCode 0 -MoreTests $true -ElapsedHours 8 -DeadlineHours 7.5
    $n.action | Should -Be 'teardown'
    $n.stopBatchAfter | Should -BeTrue
  }
  It 'always closes after teardown, even when it errors' { (Get-AvdBatchNextStep -Step teardown -ExitCode 1).action | Should -Be 'close' }
  It 'stops the batch on leftovers' { (Get-AvdBatchNextStep -Step close -ExitCode 1).action | Should -Be 'stop-batch' }
}

Describe 'Recorded groups' {
  It 'reads the Record field, with defaults, and never turns recording off on a typo' {
    ConvertFrom-AvdBatchRecordField '' | Should -BeNullOrEmpty
    ConvertFrom-AvdBatchRecordField 'none' | Should -BeNullOrEmpty
    $r = ConvertFrom-AvdBatchRecordField 'parameters/dev.bicepparam'
    $r.parameterFile | Should -Be 'parameters/dev.bicepparam'
    "$($r.namePrefix)/$($r.environment)/$($r.demoHostCount)" | Should -Be 'avdlz/dev/0'
    $r = ConvertFrom-AvdBatchRecordField 'parameters/test.bicepparam -NamePrefix lab1 -Environment test -DemoHostCount 1'
    "$($r.namePrefix)/$($r.environment)/$($r.demoHostCount)" | Should -Be 'lab1/test/1'
    (ConvertFrom-AvdBatchRecordField 'parameters/dev.bicepparam -SessionHostVmSize Standard_D2as_v5').sessionHostVmSize | Should -Be 'Standard_D2as_v5'
    { ConvertFrom-AvdBatchRecordField 'parameters/dev.bicepparam -SessionHostVmSize D2as' } | Should -Throw '*VM size*'
    { ConvertFrom-AvdBatchRecordField 'yes' } | Should -Throw '*bicepparam*'
    { ConvertFrom-AvdBatchRecordField 'parameters/dev.bicepparam -Force' } | Should -Throw '*only*'
    (Get-AvdBatchItem -Issue (New-Issue 7 @{ Record = 'dev' })).problems -join ';' | Should -Match 'Record'
    (Get-AvdBatchItem -Issue (New-Issue 7)).record | Should -BeNullOrEmpty
  }
  It 'pins the recorder: the lead''s own commit when it is avd-landing-zone, otherwise the recorder pin' {
    $cs = Get-AvdBatchItem -Issue (New-Issue 15 @{ Record = 'parameters/dev.bicepparam' })
    $plan = Get-AvdBatchPlan -Groups @(Get-AvdBatchGroup -Items @($cs)) -BatchCap 10
    $pins = @{ 'contoso/lab-tests#15' = @{ repo = 'contoso/lab-tests'; sha = ('a' * 40) } }
    { Get-AvdBatch -Plan $plan -Items @($cs) -Pins $pins -Now $Now } | Should -Throw '*pinned*'
    $b = Get-AvdBatch -Plan $plan -Items @($cs) -Pins $pins -Now $Now -Recorder @{ repo = 'avd-ops/avd-landing-zone'; sha = ('d' * 40) }
    $b.groups[0].record.sha | Should -Be ('d' * 40)
    $b.groups[0].record.parameterFile | Should -Be 'parameters/dev.bicepparam'
    $lz = Get-AvdBatchItem -Issue (New-Issue 16 @{ Source = 'avd-ops/avd-landing-zone#73'; Record = 'parameters/dev.bicepparam' })
    $plan = Get-AvdBatchPlan -Groups @(Get-AvdBatchGroup -Items @($lz)) -BatchCap 10
    $b = Get-AvdBatch -Plan $plan -Items @($lz) -Pins @{ 'avd-ops/avd-landing-zone#73' = @{ repo = 'avd-ops/avd-landing-zone'; sha = ('e' * 40) } } -Now $Now
    $b.groups[0].record.sha | Should -Be ('e' * 40)
    $b.hash | Should -Be (Get-AvdBatchHash -Batch $b)
  }
  It 'gates the recorder at the approved estimate plus 10%, and names the landing zone for the log export' {
    $g = @{ id = 'G1'; estimate = 1.29; hours = 3; region = 'northcentralus'; record = @{ parameterFile = 'parameters/dev.bicepparam'; namePrefix = 'avdlz'; environment = 'dev'; demoHostCount = 0 } }
    $id = Get-AvdBatchRunId -Now $Now -Group G1
    $id | Should -Be 'run-20261021-0100-q001'
    $id | Should -Match '^run-[0-9]{8}-[0-9]{4}-[a-z0-9]{4}$'   # the C17 run ID shape
    $open = Get-AvdBatchRecorderCall -Group $g -RunId $id -Step open
    $open.script | Should -Be 'scripts/ops/Start-AvdRunRecorder.ps1'
    ($open.args -join ' ') | Should -Be "-RunId $id -ParameterFile parameters/dev.bicepparam -Hours 3 -Cap 2.84 -DemoHostCount 0 -Location northcentralus"
    $open.env.Count | Should -Be 0
    $g.record.sessionHostVmSize = 'Standard_D2as_v5'
    (Get-AvdBatchRecorderCall -Group $g -RunId $id -Step open).env.AVD_SESSION_HOST_VM_SIZE | Should -Be 'Standard_D2as_v5'   # priced at the size the item deploys
    (Get-AvdBatchRecorderCall -Group $g -RunId $id -Step export).env.Count | Should -Be 0
    ((Get-AvdBatchRecorderCall -Group $g -RunId $id -Step export).args -join ' ') | Should -Be "-RunId $id -BeforeCleanup -NamePrefix avdlz -Environment dev"
    ((Get-AvdBatchRecorderCall -Group $g -RunId $id -Step close -Status failed).args -join ' ') | Should -Be "-RunId $id -Status failed -NamePrefix avdlz -Environment dev"
    ((Get-AvdBatchRecorderCall -Group $g -RunId $id -Step copy).args -join ' ') | Should -Match '-CopyTo github'
    $g.hours = 2.5
    ((Get-AvdBatchRecorderCall -Group $g -RunId $id -Step open).args -join ' ') | Should -Match '-Hours 2.5 '   # never rounded to a whole number
    $g.estimate = 0.1
    ((Get-AvdBatchRecorderCall -Group $g -RunId $id -Step open).args -join ' ') | Should -Match '-Cap 1 '   # the script's minimum
  }
}


Describe 'Item files (no GitHub needed)' {
  It 'reads a sandbox-run/v1 file as the form would have it' {
    $f = [ordered]@{ schema = 'sandbox-run/v1'; number = 7; purpose = 'Rebuild round trip'; source = "contoso/lab-tests@$('a' * 40)"; tests = 'Map matches'
      kind = 'avd'; sandbox = 'lab'; region = 'northcentralus'; shape = 'dev LZ'; ratePerHour = 0.43; hours = 3; estimateNote = 'Retail prices'
      unattended = $true; test = 'echo test'; evidence = 'Spend record'; keep = @('~/out', '~/logs'); dependsOn = @('contoso/lab-tests#1', 'contoso/lab-tests#2') }
    $i = Get-AvdBatchItem -Issue (ConvertFrom-AvdBatchItemFile -Item $f)
    $i.problems | Should -BeNullOrEmpty
    $i.number | Should -Be 7
    $i.unattended | Should -BeTrue
    $i.keep | Should -Be @('~/out', '~/logs')
    $i.dependsOn | Should -Be @('contoso/lab-tests#1', 'contoso/lab-tests#2')
  }
  It 'refuses a file that is not an item, has no number, or has a field it does not know' {
    { ConvertFrom-AvdBatchItemFile -Item @{ number = 1 } } | Should -Throw '*schema*'
    { ConvertFrom-AvdBatchItemFile -Item @{ schema = 'sandbox-run/v1' } } | Should -Throw '*number*'
    { ConvertFrom-AvdBatchItemFile -Item @{ schema = 'sandbox-run/v1'; number = 1; deplyo = 'x' } } | Should -Throw '*deplyo*'
  }
}

Describe 'Batch hash (frozen: approvals already given depend on it)' {
  It 'hashes a v1 batch exactly as it did before the move into the landing zone' {
    $b = [ordered]@{
      schema = 'sandbox-batch/v1'; batchId = 'b20261021-0100'; createdAt = '2026-10-21T01:00:00.0000000Z'; total = 1.29; batchCap = 10
      groups = @([ordered]@{
          id = 'G1'; key = 'lz-dev-1xD2as'; lead = 15; items = @(15); kind = 'avd'; sandbox = 'lab'; region = 'northcentralus'; regionReason = ''
          rate = 0.43; fixed = 0; hours = 3; estimate = 1.29; estimateIfAlone = 1.29; deadlineHours = 4.5; unattended = $false
          members = @([ordered]@{ number = 15; purpose = 'Rebuild round trip'; source = 'contoso/lab-tests#15'; repo = 'contoso/lab-tests'; sha = ('a' * 40)
              role = 'lead'; deploy = 'echo deploy'; test = 'echo test'; teardown = 'echo teardown'; keep = @() })
          record = $null
        })
      hash = $null
    }
    $golden = '70c336a1db8792e33320ed8a00dad5d6c29777f54d7adb051671c08ef35bcbb2'
    Get-AvdBatchHash -Batch $b | Should -Be $golden
    Get-AvdBatchHash -Batch ($b | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -AsHashtable) | Should -Be $golden -Because 'a batch read back from batch.json hashes the same'
  }
}

Describe 'Resuming after Cloud Shell drops' {
  BeforeAll {
    $script:R = @{ startedAt = '2026-10-21T01:00:00Z'; finishedAt = $null; outcome = 'running'; steps = @(
        @{ step = 'start'; item = 0; exitCode = 0 }, @{ step = 'deploy'; item = 4; exitCode = 2 }, @{ step = 'test'; item = 4; exitCode = $null }) }
  }
  It 'knows each step: done with its exit code, interrupted, or new' {
    (Get-AvdBatchStepState -Results $R -Step start).state | Should -Be 'done'
    $d = Get-AvdBatchStepState -Results $R -Step deploy -Item 4
    "$($d.state)/$($d.exitCode)" | Should -Be 'done/2'
    (Get-AvdBatchStepState -Results $R -Step test -Item 4).state | Should -Be 'interrupted'
    (Get-AvdBatchStepState -Results $R -Step teardown -Item 4).state | Should -Be 'new'
    (Get-AvdBatchStepState -Results $null -Step start).state | Should -Be 'new'
  }
  It 'starts a group once per approval, resumes only what started and did not finish, and always allows the safety net' {
    (Test-AvdBatchGroupStart -Results $null).allowed | Should -BeTrue
    (Test-AvdBatchGroupStart -Results @{ steps = @() }).allowed | Should -BeTrue -Because 'a claim with no steps spent nothing'
    (Test-AvdBatchGroupStart -Results $R).allowed | Should -BeFalse
    (Test-AvdBatchGroupStart -Results $R -Mode resume).allowed | Should -BeTrue
    (Test-AvdBatchGroupStart -Results $null -Mode resume).allowed | Should -BeFalse
    (Test-AvdBatchGroupStart -Results ($R + @{} | ForEach-Object { $_.finishedAt = '2026-10-21T03:00:00Z'; $_ }) -Mode resume).allowed | Should -BeFalse
    (Test-AvdBatchGroupStart -Results $R -Mode teardown-only).allowed | Should -BeTrue
  }
  It 'prints record times the same however JSON read them' {
    Format-AvdBatchTime '2026-10-21T01:05:00Z' | Should -Be '2026-10-21 01:05 UTC'
    Format-AvdBatchTime ([datetime]::new(2026, 10, 21, 1, 5, 0, [DateTimeKind]::Utc)) | Should -Be '2026-10-21 01:05 UTC'
  }
}

Describe 'Deadline teardown (decision 0021)' {
  BeforeAll {
    $script:Batch = @{ batchId = 'b20261021-0100' }
    $script:Down = { param([string] $Teardown, $Record = $null) @{ id = 'G2'; hours = 2; deadlineHours = 3; record = $Record; members = @(@{ role = 'lead'; teardown = $Teardown }, @{ role = 'shares'; teardown = '' }) } }
    $script:Common = @{ Batch = $Batch; Now = $Now; SubscriptionId = $Sub; StorageAccount = 'avdlzruns0123456789ab'; ResultsBlob = 'queue/2026-10/b20261021-0100/results-G2.json' }
  }
  It 'fires after the deadline, the teardown budget and a grace period, so a live runner always finishes first' {
    $d = Get-AvdBatchDeadline -Group (& $Down 'x -DiscardLastCopy') @Common
    $d.fireAt | Should -Be '2026-10-21T05:30:00Z' -Because '3 h deadline + 60 min teardown + 30 min grace'
    $d.scheduleName | Should -Be 'deadline-b20261021-0100-G2'
    Get-AvdBatchTeardownBudget -Group @{ hours = 4 } | Should -Be 120
  }
  It 'deletes only when the approved teardown discards the last copy, and otherwise only deallocates' {
    (Get-AvdBatchDeadline -Group (& $Down 'pwsh -File ./scripts/ops/Remove-AvdDemo.ps1 -IncludeLandingZone -Force -DiscardLastCopy') @Common).action | Should -Be 'Delete'
    (Get-AvdBatchDeadline -Group (& $Down 'pwsh -File ./scripts/ops/Remove-AvdDemo.ps1 -Force') @Common).action | Should -Be 'Deallocate'
    (Get-AvdBatchDeadline -Group (& $Down 'echo -DiscardLastCopyLater') @Common).action | Should -Be 'Deallocate'
  }
  It 'scopes it to the group''s landing zone by name, the defaults or the recorded group''s own' {
    $d = Get-AvdBatchDeadline -Group (& $Down 'x') @Common
    $d.resourceGroupPrefix | Should -Be 'rg-avdlz-dev-'
    $d.parameters.ResourceGroupPrefix | Should -Be 'rg-avdlz-dev-'
    $d.parameters.ResultsBlob | Should -Be 'queue/2026-10/b20261021-0100/results-G2.json'
    (Get-AvdBatchDeadline -Group (& $Down 'x' @{ namePrefix = 'Lab-1'; environment = 'test' }) @Common).resourceGroupPrefix | Should -Be 'rg-lab1-test-'
  }
  It 'refuses to arm a scope the runbook would reject, so a firing never fails on its parameters' {
    { Get-AvdBatchDeadline -Group (& $Down 'x' @{ namePrefix = 'avd-sandbox1'; environment = 'dev' }) @Common } | Should -Throw '*runbook takes*'
    { Get-AvdBatchDeadline -Group (& $Down 'x' @{ namePrefix = 'lab'; environment = 'qa' }) @Common } | Should -Throw '*runbook takes*'
  }
  It 'treats an unfinished group as gone once its last step is older than its deadline and teardown budget' {
    $g = @{ hours = 2; deadlineHours = 3 }
    $r = { param($ago) @{ steps = @(@{ step = 'start'; startedAt = $Now.AddHours(-10).ToString('o') }, @{ step = 'test'; startedAt = $Now.AddMinutes(-$ago).ToString('o') }) } }
    Test-AvdBatchGroupMayBeRunning -Group $g -Results (& $r 30) -Now $Now | Should -BeTrue
    Test-AvdBatchGroupMayBeRunning -Group $g -Results (& $r 239) -Now $Now | Should -BeTrue
    Test-AvdBatchGroupMayBeRunning -Group $g -Results (& $r 241) -Now $Now | Should -BeFalse
    Test-AvdBatchGroupMayBeRunning -Group $g -Results $null -Now $Now | Should -BeFalse
  }
}

Describe 'Health before spend' {
  BeforeAll {
    $script:Healthy = @{ signedIn = $true; subscriptionName = 'Sandbox'; namePrefix = 'avdlz'; environment = 'dev'
      permissions = @(@{ actions = @('*') }); graphStatus = 200; staleDevices = @(); leftoverGroups = @(); monthlyCap = 150; runCap = 25; estimate = 2.75 }
    function script:Get-Failed([hashtable] $Over = @{}) { $f = $Healthy.Clone(); foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }; @(Get-AvdSandboxHealthResult -Facts $f | Where-Object { -not $_.ok }) }
  }
  It 'passes a healthy sandbox' {
    @(Get-Failed).Count | Should -Be 0
  }
  It 'stops at the sign-in when there is none' {
    $r = @(Get-AvdSandboxHealthResult -Facts @{ signedIn = $false; signInError = 'Not signed in' })
    $r.Count | Should -Be 1
    $r[0].fix | Should -Match 'Connect-AzAccount'
  }
  It 'reads ARM permissions with notActions, which ARM leaves out when empty' {
    Test-AvdArmAction @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write') }) 'Microsoft.Authorization/roleAssignments/write' | Should -BeFalse
    Test-AvdArmAction @([pscustomobject]@{ actions = @('*') }) 'Microsoft.Resources/deployments/write' | Should -BeTrue
    Test-AvdArmAction @() 'Microsoft.Resources/deployments/write' | Should -BeFalse
    (Get-Failed @{ permissions = @(@{ actions = @('*/read') }) }).check | Should -Be @('Can deploy', 'Can assign roles')
  }
  It 'never reads a failed list as nothing there' {
    (Get-Failed @{ permissions = @(); permissionsError = 'GET failed (403)' })[0].detail | Should -Match 'Could not read your permissions: GET failed \(403\)'
    (Get-Failed @{ groupsError = 'POST failed (500)' }).detail | Should -Match 'Could not list resource groups'
    (Get-Failed @{ graphStatus = 403; graphError = 'denied' }).detail | Should -Match 'returned 403'
    (Get-Failed @{ vmError = 'POST failed (429)' }).detail | Should -Match 'Could not look up VMs .*POST failed \(429\)'
  }
  It 'names leftover devices and groups, and deletes nothing' {
    $f = Get-Failed @{ staleDevices = @(@{ displayName = 'avdlzdsh-001' }); leftoverGroups = @('rg-avdlz-dev-hosts') }
    $f.check | Should -Be @('Devices from earlier runs', 'Resource groups from earlier runs')
    $f[0].fix | Should -Match 'Nothing here deletes them'
    $f[1].fix | Should -Match 'Remove-AvdDemo\.ps1 -NamePrefix avdlz -Environment dev -IncludeLandingZone'
  }
  It 'checks the caps, the estimate and the run store only when asked' {
    (Get-Failed @{ runCap = 0 }).check | Should -Be 'Spend caps'
    (Get-Failed @{ estimate = 30 }).check | Should -Be 'Estimate within the run cap'
    (Get-Failed @{ needsRunStore = $true; runStore = '' }).check | Should -Be 'Run store'
  }
  It 'names host devices the way the templates do' {
    Get-AvdHostDevicePrefix | Should -Be @('avdlzdsh', 'avdlzddemo')
    Get-AvdHostDevicePrefix -NamePrefix 'contoso-lab' -Environment test | Should -Be @('contosolabt', 'contosolabt')
  }
  It 'calls a device stale only when its name is exactly a host name and no VM carries it' {
    $d = @(@{ id = '1'; displayName = 'avdlzdsh-001' }, @{ id = '2'; displayName = 'avdlzdsh-002' }, @{ id = '3'; displayName = 'AVDLZDDEMO-001' }, @{ id = '4'; displayName = 'avdlzdsh-001-old' }, @{ id = '5'; displayName = 'avdlzdshx-001' }, @{ id = '6'; displayName = 'avdlzdsha-002' })
    @(Get-AvdStaleHostDevice -Devices $d -Prefix (Get-AvdHostDevicePrefix) -VmName @('AVDLZDSH-002') | ForEach-Object id) | Should -Be @('1', '3', '6')
  }
}
