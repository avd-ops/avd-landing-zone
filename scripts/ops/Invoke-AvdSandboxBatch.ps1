#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Runs one group of an approved sandbox batch: opens the spend run, deploys at the pinned commit,
  runs each item's test, keeps what must survive, tears down, and closes the spend run with
  teardown evidence (docs/sandbox-runs.md).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Refuses to start without an approval that still matches
  the batch, and runs each group once on that approval. Every path that deployed anything goes
  through keep, teardown and the spend close, a script error or Ctrl+C included.

  Teardown doesn't depend on this shell staying alive (decision 0021). Before a group claims
  anything it arms its deadline teardown: a one-time schedule on the run store's Automation
  account (Initialize-AvdRunStore.ps1 sets it up) that fires after the group's deadline and
  teardown budget. If the group hasn't closed clean by then, the runbook deletes its landing zone
  resource groups (or, when the approved teardown doesn't pass -DiscardLastCopy, deallocates their
  VMs). A group that closes clean disarms it. -NoDeadlineTeardown runs without one, and says so.

  Cloud Shell ends a session after about 20 minutes without input, and a group can take hours.
  Results are written to your records before and after every step, so:
    -Resume        continues where it stopped: finished steps are replayed from the results, and
                   the interrupted step runs again (item steps must be safe to run twice)
    -TeardownOnly  keep, tear down and close, unless the group already closed clean
  You rarely need either: the next group's block tears down an earlier group whose runner is gone
  (past its deadline and teardown budget) before it starts, and the deadline teardown covers the
  time in between. A group doesn't start while an earlier group of the batch may still be running,
  or stopped the batch (until you pass -ContinueAfterStop), or while Test-AvdSandboxHealth.ps1
  finds a problem (a missing permission, a leftover from an earlier run, a cap not set;
  -SkipHealth skips it).
  Get-AvdSandboxBatchStatus.ps1 shows where each group stands and prints the block to continue.

  Exit codes: 0 the group closed clean and every test passed; 3 closed clean with a failed test or
  a failed deploy (the next group may run); 2 stop the batch (the spend run didn't open, the close
  found leftovers, the deadline passed, output couldn't be kept, or it refused to start).

.EXAMPLE
  ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -BatchId b20261021-1700 -Group G1 -MonthlyCap 150 -RunCap 25

.EXAMPLE
  ./scripts/ops/Invoke-AvdSandboxBatch.ps1 -BatchId b20261021-1700 -Group G1 -MonthlyCap 150 -RunCap 25 -Resume
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, ParameterSetName = 'Id')][ValidatePattern('^b\d{8}-\d{4}$')][string] $BatchId,
  [Parameter(Mandatory, ParameterSetName = 'Path')][string] $BatchPath,
  # Where the approval is read from. Default: approval.json next to batch.json. An unattended
  # runner should read it from a place its own identity can't write (docs/sandbox-runs.md).
  [string] $ApprovalPath,
  [Parameter(Mandatory)][ValidatePattern('^G\d+$')][string] $Group,
  [double] $MonthlyCap = $(if ($env:SPEND_MONTHLY_CAP) { [double]$env:SPEND_MONTHLY_CAP } else { 0 }),
  [double] $RunCap = $(if ($env:SPEND_RUN_CAP) { [double]$env:SPEND_RUN_CAP } else { 0 }),
  [string] $SubscriptionId,
  [string] $RecordsPath,
  [switch] $Local,
  # Where sources are checked out. Default: ~/avd-batch-src.
  [string] $WorkRoot,
  [string] $CloneBase = 'https://github.com',
  # A CI runner: refuse a group with any step that needs a person.
  [switch] $RequireUnattended,
  [switch] $Resume,
  [switch] $TeardownOnly,
  # Start this group although an earlier group stopped the batch, once you have dealt with why.
  [switch] $ContinueAfterStop,
  # Skip the read-only health check (Test-AvdSandboxHealth.ps1) a new group starts with.
  [switch] $SkipHealth,
  # Run without the deadline teardown (decision 0021): a group whose shell dies keeps billing until
  # someone tears it down. Needed with -Local, or a run store set up with -NoDeadlineTeardown.
  [switch] $NoDeadlineTeardown,
  # Recorded groups: the private companion repo the run recorder copies the run to after the close.
  # Empty: the run stays in the run store only, and can be copied later.
  [string] $PrivateRepo = $env:AVD_PRIVATE_REPO
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSandboxBatch.psm1') -Force
if (-not $RecordsPath) { $RecordsPath = Get-AvdRecordsDefaultPath }
if ($Resume -and $TeardownOnly) { throw 'Use -Resume or -TeardownOnly, not both.' }

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
$subId = $ctx.Subscription.Id
$store = Open-AvdRunRecordStore -RecordsPath $RecordsPath -SubscriptionId $subId -Local:$Local
if ($PSCmdlet.ParameterSetName -eq 'Id') {
  $BatchPath = Get-ChildItem -Path (Join-Path $RecordsPath 'queue') -Recurse -Filter 'batch.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq $BatchId } | Select-Object -First 1 -ExpandProperty FullName
  if (-not $BatchPath) { throw "No batch $BatchId in $RecordsPath. Build it with New-AvdSandboxBatch.ps1." }
}
$batch = Get-Content -LiteralPath $BatchPath -Raw | ConvertFrom-Json -Depth 30 -AsHashtable
if (-not $ApprovalPath) { $ApprovalPath = Join-Path (Split-Path $BatchPath) 'approval.json' }
$approval = if (Test-Path -LiteralPath $ApprovalPath) { Get-Content -LiteralPath $ApprovalPath -Raw | ConvertFrom-Json -Depth 5 -AsHashtable } else { $null }
$check = Test-AvdBatchApproval -Batch $batch -Approval $approval
if (-not $check.valid) { Write-Host "Not starting: $($check.reasons -join ' ')" -ForegroundColor Red; exit 2 }
$g = @($batch.groups | Where-Object { $_.id -eq $Group }) | Select-Object -First 1
if (-not $g) { throw "Batch $($batch.batchId) has no group $Group." }
if ($RequireUnattended -and -not $g.unattended) { Write-Host "Not starting: group $Group has steps that need a person. Run it from Cloud Shell." -ForegroundColor Red; exit 2 }
$keepers = @($g.members | Where-Object { @($_.keep | Where-Object { $_ }).Count })
$runStore = Get-AvdRunStoreName -SubscriptionId $subId
if ($keepers.Count -and $store.local) {
  Write-Host "Not starting: $(($keepers | ForEach-Object { "#$($_.number)" }) -join ', ') keep private output, which goes to the run store, and this run is -Local. Set up the run store with Initialize-AvdRunStore.ps1." -ForegroundColor Red
  exit 2
}

$outDir = Split-Path $BatchPath
$resultsPath = Join-Path $outDir "results-$Group.json"
$resultsName = [IO.Path]::GetRelativePath($RecordsPath, $resultsPath) -replace '\\', '/'
$prior = if (Test-Path -LiteralPath $resultsPath) { Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json -Depth 10 -AsHashtable } else { $null }
$mode = if ($Resume) { 'resume' } elseif ($TeardownOnly) { 'teardown-only' } else { 'start' }
if ($mode -eq 'start') {
  # Health before spending: groups run in order, and a stop means stop.
  $readResults = { param($id) $f = Join-Path $outDir "results-$id.json"; if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -Depth 10 -AsHashtable } }
  $earlier = @($batch.groups | Where-Object { $_.id -ne $Group } | Select-Object -First ([array]::IndexOf(@($batch.groups.id), $Group)))
  # First the meter: an earlier group that may still be billing is finished or torn down before anything else is decided.
  foreach ($e in $earlier) {
    $er = & $readResults $e.id
    if ($er -and @(@($er.steps) | Where-Object { $_ }).Count -and -not $er.finishedAt) {
      if (Test-AvdBatchGroupMayBeRunning -Group $e -Results $er -Now (Get-Date)) {
        $when = if ($er.Contains('deadline') -and $er.deadline -and $er.deadline.armed) { " If its shell is gone, its deadline teardown runs at $(Format-AvdBatchTime $er.deadline.fireAt)." } else { '' }
        Write-Host "Not starting: group $($e.id) stopped part way and may still be running in another shell.$when Finish it with -Group $($e.id) -Resume, or stop it with -Group $($e.id) -TeardownOnly." -ForegroundColor Red; exit 2
      }
      # Its runner is gone (past its deadline and teardown budget): tear it down now, as part of this block.
      Write-Host "Group $($e.id) stopped part way and its runner is gone: tearing it down and closing its spend run before $Group ..." -ForegroundColor Yellow
      $forward = @{}; foreach ($k in $PSBoundParameters.Keys) { if ($k -notin 'BatchId', 'BatchPath', 'Group', 'Resume', 'TeardownOnly', 'ContinueAfterStop', 'SkipHealth') { $forward[$k] = $PSBoundParameters[$k] } }
      $global:LASTEXITCODE = 0
      & $PSCommandPath -BatchPath $BatchPath -Group $e.id -TeardownOnly @forward
      $er = & $readResults $e.id
      if (-not $er -or -not $er.finishedAt -or -not @($er.steps | Where-Object { $_ -and $_.step -eq 'close' -and $_.exitCode -eq 0 }).Count) {
        Write-Host "Not starting: group $($e.id) could not be closed clean (above). Clean up what it left, then run this block again." -ForegroundColor Red; exit 2
      }
      Write-Host "Group $($e.id) is closed: nothing of it is left billing." -ForegroundColor DarkGray
    }
  }
  foreach ($e in $earlier) {
    $er = & $readResults $e.id
    if ($er -and $er.outcome -eq 'stop-batch' -and -not $ContinueAfterStop) {
      Write-Host "Not starting: group $($e.id) stopped the batch. Deal with the reason in its output (Get-AvdSandboxBatchStatus.ps1 shows it), then run this group with -ContinueAfterStop." -ForegroundColor Red; exit 2
    }
  }
}
$may = Test-AvdBatchGroupStart -Results $prior -Mode $mode
if (-not $may.allowed) { Write-Host "Not starting: $($may.reason)" -ForegroundColor Red; exit 2 }
if ($mode -eq 'start' -and -not $SkipHealth) {
  # Read-only, before the claim: a failure here claims, deploys and spends nothing, so the same block runs again once it's fixed.
  $lzName = if ($g.record) { @{ NamePrefix = $g.record.namePrefix; Environment = $g.record.environment } } else { @{} }
  $global:LASTEXITCODE = 0
  & (Join-Path $PSScriptRoot 'Test-AvdSandboxHealth.ps1') @lzName -MonthlyCap $MonthlyCap -RunCap $RunCap -Estimate ([double]$g.estimate) -NeedsRunStore:(-not $store.local) -SubscriptionId $subId | Out-Host
  if ($LASTEXITCODE) { Write-Host "Not starting: the sandbox isn't healthy (above). Fix what failed and run the same block again; nothing was claimed, deployed or spent." -ForegroundColor Red; exit 2 }
}
# The deadline teardown's record, written by the runbook when it fired (pulled with the records).
$deadlinePath = Join-Path $outDir "deadline-$Group.json"
$fired = if (Test-Path -LiteralPath $deadlinePath) { Get-Content -LiteralPath $deadlinePath -Raw | ConvertFrom-Json -Depth 10 -AsHashtable } else { $null }
if ($Resume -and $fired -and $fired.outcome -ne 'not-needed') {
  # The landing zone is gone (or its VMs are off): nothing to resume. Finish the teardown and close instead.
  Write-Host "The deadline teardown already ran for $Group at $(Format-AvdBatchTime $fired.firedAt) ($($fired.outcome)): finishing with teardown and close instead of resuming." -ForegroundColor Yellow
  $Resume = $false; $TeardownOnly = $true; $mode = 'teardown-only'
}
$aa = "/subscriptions/$subId/resourceGroups/avdlz-runs-rg/providers/Microsoft.Automation/automationAccounts/aa-avdlz-runs"
$apiAa = '2023-11-01'
$deadline = [ordered]@{ armed = $false }
if ($mode -eq 'start') {
  if ($NoDeadlineTeardown) {
    $deadline.reason = 'Run with -NoDeadlineTeardown.'
    Write-Host 'No deadline teardown (-NoDeadlineTeardown): if this shell dies, the group keeps billing until someone tears it down.' -ForegroundColor Yellow
  }
  elseif ($store.local) {
    Write-Host 'Not starting: the deadline teardown reads the group''s results from the run store, and this run is -Local. Set up the run store with Initialize-AvdRunStore.ps1, or pass -NoDeadlineTeardown to run without one. Nothing was claimed, deployed or spent.' -ForegroundColor Red; exit 2
  }
  else {
    # Armed before the claim: a failure here claims, deploys and spends nothing, so the same block runs again once it's fixed.
    $book = Invoke-AvdSpendArm -Path "$aa/runbooks/Invoke-AvdSandboxDeadline?api-version=$apiAa" -AllowNotFound
    if (-not $book -or $book.properties.state -ne 'Published') {
      Write-Host "Not starting: no deadline teardown in this subscription (aa-avdlz-runs in avdlz-runs-rg, runbook Invoke-AvdSandboxDeadline$(if ($book) { " is $($book.properties.state)" })). Run Initialize-AvdRunStore.ps1 again to add it (no cost while idle), or pass -NoDeadlineTeardown. Nothing was claimed, deployed or spent." -ForegroundColor Red; exit 2
    }
    $jobSchedule = [guid]::NewGuid().ToString()
    try {
      $plan = Get-AvdBatchDeadline -Batch $batch -Group $g -Now (Get-Date) -SubscriptionId $subId -StorageAccount $runStore -ResultsBlob $resultsName
      $schedule = "$aa/schedules/$($plan.scheduleName)?api-version=$apiAa"
      # A schedule left by an earlier attempt goes first, with its link to the runbook.
      $null = Invoke-AvdSpendArm -Method DELETE -Path $schedule -AllowNotFound
      $null = Invoke-AvdSpendArm -Method PUT -Path $schedule -Body @{ name = $plan.scheduleName; properties = @{ description = "Deadline teardown of batch $($batch.batchId) $Group"; startTime = $plan.fireAt; frequency = 'OneTime'; timeZone = 'UTC' } }
      $null = Invoke-AvdSpendArm -Method PUT -Path "$aa/jobSchedules/$($jobSchedule)?api-version=$apiAa" -Body @{ properties = @{ schedule = @{ name = $plan.scheduleName }; runbook = @{ name = 'Invoke-AvdSandboxDeadline' }; parameters = $plan.parameters } }
    }
    catch {
      Write-Host "Not starting: the deadline teardown could not be armed: $($_.Exception.Message) Nothing was claimed, deployed or spent." -ForegroundColor Red; exit 2
    }
    $deadline = [ordered]@{ armed = $true; fireAt = $plan.fireAt; action = $plan.action; resourceGroupPrefix = $plan.resourceGroupPrefix; schedule = $plan.scheduleName; jobSchedule = $jobSchedule }
    $what = if ($plan.action -eq 'Delete') { "deletes $($plan.resourceGroupPrefix)*" } else { "deallocates the VMs in $($plan.resourceGroupPrefix)* (the approved teardown keeps the last copy)" }
    Write-Host "Deadline teardown armed: at $(Format-AvdBatchTime $plan.fireAt) it $what, unless this group has closed clean." -ForegroundColor DarkGray
  }
}
if ($TeardownOnly) {
  if (-not $prior -or -not @($prior.steps | Where-Object { $_ -and $_.step -eq 'start' -and $_.exitCode -eq 0 }).Count) { Write-Host "Group $Group never opened a spend run; nothing to tear down."; exit 0 }
  if (@($prior.steps | Where-Object { $_ -and $_.step -eq 'close' -and $_.exitCode -eq 0 }).Count) { Write-Host "Group $Group already closed clean; nothing to tear down."; exit 0 }
}
if (-not $WorkRoot) { $WorkRoot = Join-Path $HOME 'avd-batch-src' }
$cloneBase = $CloneBase.TrimEnd('/')
$caps = @{ MonthlyCap = $MonthlyCap; RunCap = $RunCap }
$privateRepo = $PrivateRepo

$results = if ($prior -and $mode -ne 'start') { $prior } else {
  [ordered]@{
    schema = 'sandbox-batch-results/v1'; batchId = $batch.batchId; group = $Group; approvedBy = $approval.approvedBy
    startedAt = (Get-Date).ToUniversalTime().ToString('o'); finishedAt = $null; spendRunId = $null; runId = $null; outcome = 'running'; steps = @(); keeps = @()
    deadline = $deadline
  }
}
$started = ([datetime]$results.startedAt).ToUniversalTime()
$replay = $mode -ne 'start'
$save = {
  $results | ConvertTo-Json -Depth 10 | Set-Content -Path $resultsPath -Encoding utf8NoBOM
  Save-AvdRunRecordStore -Store $store -Only $resultsName
}
# Claim the group before anything is spent: the first write of the results is conditional on the
# file being new in the run store, so a second shell starting the same group stops here.
& $save

function Invoke-Step([string] $Name, [int] $Item, [scriptblock] $Body) {
  $label = "$Name$(if ($Item) { " (#$Item)" })"
  if ($script:replay) {
    $s = Get-AvdBatchStepState -Results $script:results -Step $Name -Item $Item
    if ($s.state -eq 'done') { Write-Host "==> $label already done (exit $($s.exitCode)); skipping" -ForegroundColor DarkGray; return $s.exitCode }
    if ($s.state -eq 'interrupted') { Write-Host "==> $label was interrupted; running it again" -ForegroundColor Yellow }
  }
  Write-Host "==> $label ..." -ForegroundColor Cyan
  $t0 = Get-Date
  $entry = [ordered]@{ step = $Name; item = $Item; exitCode = $null; startedAt = $t0.ToUniversalTime().ToString('o'); minutes = $null }
  $script:results.steps = @($script:results.steps) + @($entry)
  & $script:save
  $code = 0
  try { $code = & $Body; if ($null -eq $code) { $code = 0 } }
  catch { Write-Host "    $($_.Exception.Message)" -ForegroundColor Red; $code = 1 }
  $code = [int]@($code)[-1]
  $entry.exitCode = $code
  $entry.minutes = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
  & $script:save
  Write-Host "    exit $code" -ForegroundColor $(if ($code) { 'Yellow' } else { 'DarkGray' })
  $code
}
function Invoke-Bash([string] $Dir, [string] $Script, [double] $TimeoutMinutes = 0) {
  if (-not $Script.Trim()) { return 0 }
  # Its own process on the same terminal, so device code sign-ins and typed confirmations work.
  # A step past its time limit (a prompt nobody will answer on a runner, a hung sign-in) is
  # killed with everything it started, and fails with 124 like timeout(1).
  $file = Join-Path ([IO.Path]::GetTempPath()) "batch-step-$([guid]::NewGuid().ToString('N')).sh"
  Set-Content -Path $file -Value $Script -Encoding utf8NoBOM
  try {
    $p = Start-Process -FilePath bash -ArgumentList '-e', $file -WorkingDirectory $Dir -NoNewWindow -PassThru
    $ms = if ($TimeoutMinutes -gt 0) { [int][math]::Min([int]::MaxValue, $TimeoutMinutes * 60000) } else { -1 }
    if (-not $p.WaitForExit($ms)) {
      Write-Host ("    Step passed its limit of {0:N0} minutes; stopping it." -f $TimeoutMinutes) -ForegroundColor Red
      $p.Kill($true); $p.WaitForExit()
      return 124
    }
    $p.WaitForExit()
    $p.ExitCode
  }
  finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
}
function Save-Keep {
  <#
    Copies each item's Keep paths to the run store before teardown: tar.gz, upload, download again,
    compare SHA-256. Records names, sizes and hashes only. Never deletes anything, and never puts the
    output anywhere but the run store. Returns 1 when any existing path couldn't be kept.
  #>
  $bad = 0
  $sc = New-AzStorageContext -StorageAccountName $runStore -UseConnectedAccount
  foreach ($m in $keepers) {
    foreach ($path in @($m.keep | Where-Object { $_ })) {
      if (@($script:results.keeps | Where-Object { $_ -and $_.item -eq $m.number -and $_.path -eq $path -and $_.verified }).Count) { continue }
      $full = if ($path -like '~*') { Join-Path $HOME $path.Substring(1).TrimStart('/') } else { $path }
      $entry = [ordered]@{ item = $m.number; path = $path; blob = $null; bytes = $null; sha256 = $null; verified = $false; status = 'missing' }
      if (Test-Path -LiteralPath $full) {
        $leaf = Split-Path $full -Leaf
        $blob = "queue/$($batch.batchId)/$Group/$($m.number)/$leaf.tar.gz"
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "keep-$([guid]::NewGuid().ToString('N')).tar.gz"
        $back = "$tmp.back"
        Write-Host "    keeping $path for #$($m.number) in the run store ..." -ForegroundColor DarkGray
        tar -czf $tmp -C (Split-Path $full) $leaf
        $entry.blob = $blob; $entry.bytes = (Get-Item $tmp).Length
        $entry.sha256 = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
        try {
          $null = Set-AzStorageBlobContent -File $tmp -Container 'runs' -Blob $blob -Context $sc -Force -ErrorAction Stop
          $null = Get-AzStorageBlobContent -Container 'runs' -Blob $blob -Destination $back -Context $sc -Force -ErrorAction Stop
          if ((Test-Path $back) -and (Get-FileHash -LiteralPath $back -Algorithm SHA256).Hash.ToLower() -eq $entry.sha256) { $entry.verified = $true; $entry.status = 'kept' }
          else { $entry.status = 'failed'; Write-Host "    read-back of $path did not match" -ForegroundColor Red; $bad++ }
        }
        catch { $entry.status = 'failed'; Write-Host "    keeping ${path} failed: $($_.Exception.Message)" -ForegroundColor Red; $bad++ }
        Remove-Item -LiteralPath $tmp, $back -ErrorAction SilentlyContinue
      }
      $script:results.keeps = @($script:results.keeps | Where-Object { $_ -and -not ($_.item -eq $m.number -and $_.path -eq $path) }) + @($entry)
      & $script:save
    }
  }
  [int]($bad -gt 0)
}
function Get-Checkout($Member) {
  $dir = Join-Path $WorkRoot ($Member.repo -replace '/', '_')
  if (-not (Test-Path (Join-Path $dir '.git'))) {
    Write-Host "    cloning $($Member.repo) ..." -ForegroundColor DarkGray
    git clone -q "$cloneBase/$($Member.repo)" $dir | Out-Host
    if ($LASTEXITCODE) { throw "git clone of $($Member.repo) failed (exit $LASTEXITCODE)." }
  }
  git -C $dir fetch -q origin $Member.sha 2>$null | Out-Host
  git -C $dir checkout -q --detach $Member.sha | Out-Host
  if ($LASTEXITCODE) { throw "$($Member.repo) has no commit $($Member.sha)." }
  if ((git -C $dir rev-parse HEAD).Trim() -ne $Member.sha) { throw "$($Member.repo) is not at the pinned commit." }
  $dir
}
function Invoke-Recorder([string] $Step, [string] $Status = 'torn-down') {
  # The run recorder at the pinned commit, as its own process, so its modules never replace these.
  $call = Get-AvdBatchRecorderCall -Group $g -RunId $script:results.runId -Step $Step -Status $Status -SubscriptionId $subId
  $dir = Get-Checkout $g.record
  $saved = @{}; foreach ($k in $call.env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $call.env[$k]) }
  try { & pwsh -NoProfile -File (Join-Path $dir $call.script) @($call.args) | Out-Host; $LASTEXITCODE }
  finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
}
function Test-StepPassed([string] $Name) { [bool]@($script:results.steps | Where-Object { $_ -and $_.step -eq $Name -and $_.exitCode -eq 0 }).Count }
function Close-Record([int] $CloseCode) {
  # After the spend close: status and the first actual cost reading, then the copy to the private
  # repo. Neither changes the group's outcome: the run folder is already in the run store, and
  # both can be run again later (Stop-AvdRunRecorder.ps1 -UpdateCost, -CopyTo github).
  $null = Invoke-Step 'record-close' 0 { Invoke-Recorder close $(if ($CloseCode) { 'failed' } else { 'torn-down' }) }
  if ($privateRepo) { $env:AVD_PRIVATE_REPO = $privateRepo; $null = Invoke-Step 'record-copy' 0 { Invoke-Recorder copy } }
  else { Write-Host "    Run $($script:results.runId) stays in the run store; no private repo set (AVD_PRIVATE_REPO), so nothing was copied." -ForegroundColor DarkGray }
}
$spendArgs = @{ Sandbox = $g.sandbox; RecordsPath = $RecordsPath; SubscriptionId = $subId; Local = [bool]$store.local }
function Invoke-Spend([string] $Script, [hashtable] $More = @{}) {
  # In this process: the spend scripts share this sign-in and records folder.
  $a = $spendArgs + $More
  $global:LASTEXITCODE = 0
  & (Join-Path $PSScriptRoot $Script) @a | Out-Host
  $LASTEXITCODE
}
$elapsed = { ((Get-Date).ToUniversalTime() - $started).TotalHours }
# Deploy and tests get what is left before the deadline (at least 10 minutes); teardown always gets its own budget.
$left = { [math]::Max(10, ($g.deadlineHours - (& $elapsed)) * 60) }
$teardownMinutes = Get-AvdBatchTeardownBudget -Group $g

# ---- Start ----
$lead = @($g.members | Where-Object { $_.role -eq 'lead' })[0]
$recorded = [bool]$g.record
if ($recorded -and -not $TeardownOnly) {
  # The run recorder opens the run first: read-only in Azure but for the run folder, so a refusal
  # spends nothing. It prices the run itself and refuses past the approved estimate plus 10%.
  if (-not $results.runId) { $results.runId = Get-AvdBatchRunId -Now $started -Group $Group }
  $code = Invoke-Step 'record-open' 0 { Invoke-Recorder open }
  if ($code) {
    $results.outcome = 'stop-batch'; $results.finishedAt = (Get-Date).ToUniversalTime().ToString('o'); & $save
    Write-Host "Not starting: the run recorder refused run $($results.runId) (above): its estimate is more than 10% over the approved $($g.estimate), a line has no price, or there is no run store. Nothing was deployed or spent." -ForegroundColor Red
    exit 2
  }
}
$recorded = $recorded -and [bool]$results.runId -and (Test-StepPassed 'record-open')
# Every step the group runs (the items' bash and the landing zone scripts they call) writes to the run's journal.
# Put back afterwards, so landing zone scripts run later in this shell don't write to a closed run.
$envBefore = @{ AVDLZ_RECORD = $env:AVDLZ_RECORD; AVDLZ_RUN_ID = $env:AVDLZ_RUN_ID }
if ($recorded) { $env:AVDLZ_RECORD = 'azure'; $env:AVDLZ_RUN_ID = $results.runId }
$stopAfter = $false; $testsFailed = $false; $deployFailed = $false
$keepFailed = $false; $exportFailed = $false
function Invoke-TeardownPath([string] $Reason) {
  # Keep, export, tear down and close. Everything here is safe to run again, so nothing is replayed.
  $script:replay = $false
  if ($keepers.Count) { $script:keepFailed = [bool](Invoke-Step 'keep' 0 { Save-Keep }) }
  if ($recorded -and -not (Test-StepPassed 'record-export')) { $null = Invoke-Step 'record-export' 0 { Invoke-Recorder export } }
  $null = Invoke-Step 'teardown' $lead.number { Invoke-Bash (Get-Checkout $lead) $lead.teardown $teardownMinutes }
  $code = Invoke-Step 'close' 0 { Invoke-Spend 'Stop-AvdSpendRun.ps1' }
  if ($recorded) { Close-Record $code }
  [ordered]@{ action = 'stop-batch'; reason = $Reason; stopBatchAfter = $true }
}
# Whatever stops this script from here (a script error, Ctrl+C), a group that opened a spend run
# and hasn't closed it is torn down before the script ends. A shell that dies outright runs no
# finally block: the deadline teardown is for that.
$settled = $false
try {
  if ($TeardownOnly) { $next = [ordered]@{ action = 'teardown-only'; reason = 'Tearing down after an interrupted run.'; stopBatchAfter = $true } }
  else {
    $code = Invoke-Step 'start' 0 {
      $null = Get-Checkout $lead
      Invoke-Spend 'Start-AvdSpendRun.ps1' (@{ Kind = $g.kind; Purpose = "batch $($batch.batchId) $Group"; Hours = [math]::Max(0.5, $g.hours)
        ManualAmount = $g.estimate; ManualNote = "Approved batch estimate ($($g.rate)/h x $($g.hours) h + fixed), items $(($g.items | ForEach-Object { "#$_" }) -join ' ')" } + $caps)
    }
    $next = Get-AvdBatchNextStep -Step start -ExitCode $code
  }
  if ($next.action -eq 'teardown-only') { $next = Invoke-TeardownPath 'Interrupted run, torn down.' }
  elseif ($next.action -eq 'deploy') {
    $code = Invoke-Step 'deploy' $lead.number { Invoke-Bash (Get-Checkout $lead) $lead.deploy (& $left) }
    $next = Get-AvdBatchNextStep -Step deploy -ExitCode $code -ElapsedHours (& $elapsed) -DeadlineHours $g.deadlineHours
    $deployFailed = [bool]$code
    if ($next.stopBatchAfter) { $stopAfter = $true }
    if ($next.action -eq 'run-tests') {
      $members = @($g.members)
      for ($k = 0; $k -lt $members.Count; $k++) {
        $m = $members[$k]
        $code = Invoke-Step 'test' $m.number { Invoke-Bash (Get-Checkout $m) $m.test (& $left) }
        if ($code) { $testsFailed = $true }
        $next = Get-AvdBatchNextStep -Step test -ExitCode $code -ElapsedHours (& $elapsed) -DeadlineHours $g.deadlineHours -MoreTests ($k -lt $members.Count - 1)
        if ($next.stopBatchAfter) { $stopAfter = $true }
        if ($next.action -ne 'next-test') { break }
      }
    }
    Write-Host "    $($next.reason)" -ForegroundColor DarkGray
    if ($keepers.Count) { $keepFailed = [bool](Invoke-Step 'keep' 0 { Save-Keep }) }
    # Teardown deletes the landing zone's Log Analytics workspace, the only copy of its AVD logs:
    # export them first. Like a failed keep, a failed export never holds up teardown (the meter
    # rule), but after a good deploy it stops the batch so the operator sees it first.
    if ($recorded -and (Invoke-Step 'record-export' 0 { Invoke-Recorder export }) -and -not $deployFailed) { $exportFailed = $true }
    $code = Invoke-Step 'teardown' $lead.number { Invoke-Bash (Get-Checkout $lead) $lead.teardown $teardownMinutes }
    $code = Invoke-Step 'close' 0 { Invoke-Spend 'Stop-AvdSpendRun.ps1' }
    if ($recorded) { Close-Record $code }
    $next = Get-AvdBatchNextStep -Step close -ExitCode $code
  }
  $settled = $true
}
catch {
  Write-Host "The runner stopped on an error: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage -replace '\s+', ' '))" -ForegroundColor Red
}
finally {
  if (-not $settled) {
    if ((Test-StepPassed 'start') -and -not (Test-StepPassed 'close')) {
      Write-Host 'Tearing down now, so nothing is left billing ...' -ForegroundColor Yellow
      try { $next = Invoke-TeardownPath 'The runner stopped on an error; torn down.' }
      catch { Write-Host "The teardown stopped too: $($_.Exception.Message)$(if ($results.deadline.armed) { " The deadline teardown still runs at $(Format-AvdBatchTime $results.deadline.fireAt)." })" -ForegroundColor Red }
    }
    if (-not $next -or $next.action -ne 'stop-batch') { $next = [ordered]@{ action = 'stop-batch'; reason = 'The runner stopped on an error.'; stopBatchAfter = $true } }
    # Written here too: after Ctrl+C nothing below this block runs.
    $results.outcome = 'stop-batch'; $results.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
    try { & $save } catch { Write-Host "    Saving the results failed: $($_.Exception.Message)" -ForegroundColor Red }
  }
}
# Closed clean: the deadline teardown has nothing to do, so take its schedule down (it would only find the group closed).
if ($results.Contains('deadline') -and $results.deadline -and $results.deadline.armed -and (Test-StepPassed 'close')) {
  try {
    $null = Invoke-AvdSpendArm -Method DELETE -Path "$aa/jobSchedules/$($results.deadline.jobSchedule)?api-version=$apiAa" -AllowNotFound
    $null = Invoke-AvdSpendArm -Method DELETE -Path "$aa/schedules/$($results.deadline.schedule)?api-version=$apiAa" -AllowNotFound
    $results.deadline.armed = $false; $results.deadline.disarmedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-Host '    Deadline teardown disarmed.' -ForegroundColor DarkGray
  }
  catch { Write-Host "    The deadline teardown's schedule could not be removed ($($_.Exception.Message)); when it fires it finds the group closed and does nothing." -ForegroundColor DarkGray }
}
$spendRun = @(Get-AvdSpendRun -RecordsPath $RecordsPath -Sandbox $g.sandbox | Where-Object { $_.purpose -eq "batch $($batch.batchId) $Group" }) | Select-Object -Last 1
if ($spendRun) { $results.spendRunId = $spendRun.runId }

# A failed keep never holds up teardown (the meter rule), but it stops the batch so the operator sees it first.
if ($keepFailed) { $stopAfter = $true; Write-Host 'Private output could not be kept in the run store: see keeps in the results.' -ForegroundColor Red }
if ($exportFailed) { $stopAfter = $true; Write-Host "The AVD logs could not be exported before teardown: see run $($results.runId) and the record-export step." -ForegroundColor Red }
if ($recorded) { Write-Host "Recorded as run $($results.runId) (run store runs/$($results.runId)/)." -ForegroundColor DarkGray }
$results.outcome = if ($next.action -eq 'stop-batch' -or $stopAfter) { 'stop-batch' } elseif ($deployFailed) { 'deploy-failed' } elseif ($testsFailed) { 'tests-failed' } else { 'passed' }
$results.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
& $save
foreach ($k in $envBefore.Keys) { [Environment]::SetEnvironmentVariable($k, $envBefore[$k]) }
Write-Host ''
Write-Host "Group $Group of batch $($batch.batchId): $($results.outcome). Results: $resultsPath" -ForegroundColor $(if ($results.outcome -eq 'passed') { 'Green' } else { 'Yellow' })
if ($results.outcome -eq 'stop-batch') { Write-Host 'Stop here: do not run the next group until the reason above is dealt with.' -ForegroundColor Red; exit 2 }
if ($results.outcome -ne 'passed') { exit 3 }
exit 0
