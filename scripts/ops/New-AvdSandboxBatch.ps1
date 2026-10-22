#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Builds a sandbox batch from the ready queue items: pins sources to commits, groups items that can
  share a deployment, prices the groups, checks the caps, and writes batch.json and batch.md to
  your records (docs/sandbox-runs.md).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Read-only in Azure: it reads month-to-date cost from Cost
  Management. Nothing runs until a person approves the batch at its exact total
  (Approve-AvdSandboxBatch.ps1).

  Where the items come from, one of:
    -ItemsPath  a folder of sandbox-run/v1 JSON files (no GitHub needed; docs/sandbox-runs.md)
    -Repo       owner/repo whose open issues labeled sandbox-run and queue:ready are the queue
                (the GitHub CLI, signed in)
    -IssuesPath that issue list as JSON (gh issue list --json number,title,body,labels), offline
  Sources pinned as owner/repo@<40-hex commit> need nothing else. owner/repo#PR, short commits and
  Depends on need the GitHub CLI signed in (gh auth login), or -PinsPath offline.

  The run recorder comes from this checkout's own commit, so the approval covers it too.

.EXAMPLE
  ./scripts/ops/New-AvdSandboxBatch.ps1 -ItemsPath ~/clouddrive/queue -MonthlyCap 150 -RunCap 25

.EXAMPLE
  ./scripts/ops/New-AvdSandboxBatch.ps1 -Repo contoso/lab-ops -MonthlyCap 150 -RunCap 25 -DefaultRegion northcentralus
#>
[CmdletBinding()]
param(
  [string] $ItemsPath,
  [string] $Repo,
  [string] $IssuesPath,
  [string] $PinsPath,
  # An item in another region must say why. Empty: any region.
  [string] $DefaultRegion = $env:SPEND_DEFAULT_REGION,
  [double] $BatchCap = $(if ($env:QUEUE_BATCH_CAP) { [double]$env:QUEUE_BATCH_CAP } else { 10 }),
  [double] $MonthlyCap = $(if ($env:SPEND_MONTHLY_CAP) { [double]$env:SPEND_MONTHLY_CAP } else { 0 }),
  [double] $RunCap = $(if ($env:SPEND_RUN_CAP) { [double]$env:SPEND_RUN_CAP } else { 0 }),
  # Month-to-date cost; read from Cost Management when not given.
  [double] $MonthToDate = -1,
  [string] $SubscriptionId,
  [string] $RecordsPath,
  [switch] $Local,
  [datetime] $Now = (Get-Date),
  # Where the run recorder comes from; default: this checkout (its origin and HEAD).
  [string] $RecorderRepo,
  [string] $RecorderSha,
  # Also open a batch issue in -Repo (the GitHub CLI, signed in).
  [switch] $PostIssue
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSandboxBatch.psm1') -Force
if (-not $RecordsPath) { $RecordsPath = Get-AvdRecordsDefaultPath }
if (-not ($ItemsPath -or $Repo -or $IssuesPath)) { throw 'Give the queue: -ItemsPath (a folder of sandbox-run/v1 item files), -Repo (owner/repo with sandbox-run issues) or -IssuesPath.' }
if ($PostIssue -and -not $Repo) { throw '-PostIssue needs -Repo.' }

# ---- Items ----
$issues = if ($ItemsPath) {
  Write-Host "Reading queue items from $ItemsPath ..." -ForegroundColor DarkGray
  @(Get-ChildItem -LiteralPath $ItemsPath -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
      $i = ConvertFrom-AvdBatchItemFile -Item (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable)
      $i | Add-Member -NotePropertyName labels -NotePropertyValue @([pscustomobject]@{ name = 'queue:ready' }) -PassThru
    })
}
elseif ($IssuesPath) { Get-Content -LiteralPath $IssuesPath -Raw | ConvertFrom-Json -Depth 20 }
else {
  Write-Host "Reading open sandbox-run issues from $Repo ..." -ForegroundColor DarkGray
  gh issue list -R $Repo --label sandbox-run --state open --limit 100 --json 'number,title,body,labels' | ConvertFrom-Json -Depth 20
  if ($LASTEXITCODE) { throw "gh issue list failed (exit $LASTEXITCODE). Sign in with gh auth login, or use -ItemsPath." }
}
$numbers = @($issues | ForEach-Object { [int]$_.number })
if (@($numbers | Sort-Object -Unique).Count -ne $numbers.Count) { throw 'Two queue items share a number. Each item needs its own.' }
$ready = @($issues | Where-Object { @($_.labels | ForEach-Object { $_.name }) -contains 'queue:ready' })
$items = @($ready | ForEach-Object { Get-AvdBatchItem -Issue $_ -DefaultRegion $DefaultRegion })

# ---- Pins and dependencies ----
$offline = if ($PinsPath) { Get-Content -LiteralPath $PinsPath -Raw | ConvertFrom-Json -Depth 10 -AsHashtable } else { $null }
$resolve = {
  param([string] $Ref)
  if ($offline) { if ($offline.ContainsKey($Ref)) { return $offline[$Ref] } ; throw "No pin for $Ref in $PinsPath." }
  # A full commit needs no lookup: the runner checks it out and fails if it isn't there.
  if ($Ref -match '^([\w.-]+/[\w.-]+)@([0-9a-f]{40})$') { return @{ repo = $Matches[1]; sha = $Matches[2]; merged = $true } }
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "Resolving $Ref needs the GitHub CLI. Pin the full commit (owner/repo@<40 hex>) instead." }
  if ($Ref -match '^([\w.-]+/[\w.-]+)#(\d+)$') {
    $j = gh api "repos/$($Matches[1])/pulls/$($Matches[2])" --jq '{sha: .head.sha, merged: .merged}'
    if ($LASTEXITCODE) { throw "gh api could not read $Ref (exit $LASTEXITCODE). Sign in with gh auth login, or pin the full commit." }
    $o = $j | ConvertFrom-Json -AsHashtable; $o.repo = $Matches[1]; return $o
  }
  if ($Ref -match '^([\w.-]+/[\w.-]+)@([0-9a-fA-F]{7,39})$') {
    $sha = gh api "repos/$($Matches[1])/commits/$($Matches[2])" --jq .sha
    if ($LASTEXITCODE) { throw "gh api could not find commit $Ref (exit $LASTEXITCODE). Sign in with gh auth login, or pin the full commit." }
    return @{ repo = $Matches[1]; sha = $sha.Trim(); merged = $true }
  }
  throw "Not a source: $Ref"
}
$pins = @{}
foreach ($i in $items | Where-Object { -not $_.problems.Count }) {
  Write-Host "Pinning $($i.source) and checking what #$($i.number) depends on ..." -ForegroundColor DarkGray
  $p = & $resolve $i.source
  if (-not $p.sha -or $p.sha -notmatch '^[0-9a-f]{40}$') { $i.problems += "Could not pin $($i.source) to a commit" } else { $pins[$i.source] = $p }
  foreach ($d in $i.dependsOn) { if (-not (& $resolve $d).merged) { $i.problems += "Waits for $d to be merged" } }
}
$blocked = @($items | Where-Object { $_.problems.Count })
$usable = @($items | Where-Object { -not $_.problems.Count })

# ---- The run recorder: this checkout ----
$recorder = $null
if (@($usable | Where-Object { $_.record }).Count) {
  if ($offline -and $offline.ContainsKey('recorder')) { $recorder = $offline['recorder'] }
  else {
    $root = Join-Path $PSScriptRoot '../..'
    $own = -not $RecorderSha
    if ($own) { $RecorderSha = "$(git -C $root rev-parse HEAD 2>$null)".Trim() }
    if (-not $RecorderRepo) { $RecorderRepo = "$(git -C $root remote get-url origin 2>$null)".Trim() -replace '^https://github\.com/', '' -replace '^git@github\.com:', '' -replace '\.git$', '' }
    if ($RecorderSha -notmatch '^[0-9a-f]{40}$' -or $RecorderRepo -notmatch '^[\w.-]+/[\w.-]+$') { throw 'Could not read this checkout''s origin and commit for the run recorder. Pass -RecorderRepo and -RecorderSha.' }
    $dirty = "$(git -C $root status --porcelain -- scripts 2>$null)".Trim()
    if ($own -and $dirty) { throw 'This checkout has local changes under scripts/: the run recorder must be a commit the approval can name. Commit or discard them first.' }
    $recorder = @{ repo = $RecorderRepo; sha = $RecorderSha }
  }
  Write-Host "Run recorder: $($recorder.repo)@$($recorder.sha.Substring(0, 12))" -ForegroundColor DarkGray
}

# ---- Records and month to date ----
$subId = $SubscriptionId
if (-not ($Local -and $MonthToDate -ge 0)) { $subId = (Initialize-AvdAzContext -SubscriptionId $SubscriptionId).Subscription.Id }
$store = Open-AvdRunRecordStore -RecordsPath $RecordsPath -SubscriptionId $subId -Local:$Local
if ($MonthToDate -lt 0) {
  Write-Host 'Reading month-to-date cost from Cost Management ...' -ForegroundColor DarkGray
  $MonthToDate = Get-AvdSpendMonthToDate -SubscriptionId $subId -Now $Now
}

# ---- Plan ----
$plan = Get-AvdBatchPlan -Groups @(Get-AvdBatchGroup -Items $usable) -BatchCap $BatchCap -RunCap $RunCap -MonthlyCap $MonthlyCap -MonthToDate $MonthToDate
$batchArgs = @{ Plan = $plan; Items = $usable; Pins = $pins; Now = $Now; Recorder = $recorder }
if ($recorder) { $batchArgs.RecorderRepo = $recorder.repo }
$batch = Get-AvdBatch @batchArgs

$md = @("## Sandbox batch $($batch.batchId)", '')
if (-not $batch.groups.Count) { $md += 'Nothing to run: no ready item fits.', '' }
else {
  $md += "**Total $(Format-AvdBatchMoney $batch.total)** (batch cap $(Format-AvdBatchMoney $BatchCap); month to date $(Format-AvdBatchMoney $MonthToDate)$(if ($MonthlyCap -gt 0) { " of $(Format-AvdBatchMoney $MonthlyCap)" }))", ''
  $md += '| Group | Items | Region | Hours (deadline) | Estimate | Alone it would be | Runs |', '|---|---|---|---|---:|---:|---|'
  foreach ($g in $batch.groups) {
    $names = ($g.members | ForEach-Object { "#$($_.number) $($_.purpose)" }) -join '<br>'
    $region = if ($g.regionReason) { "$($g.region) ($($g.regionReason))" } else { $g.region }
    $md += "| $($g.id) | $names | $region | $($g.hours) ($($g.deadlineHours)) | $(Format-AvdBatchMoney $g.estimate) | $(Format-AvdBatchMoney $g.estimateIfAlone) | $(if ($g.unattended) { 'unattended' } else { 'Cloud Shell' }) |"
  }
  $md += '', 'Pinned commits:', ''
  foreach ($m in @($batch.groups | ForEach-Object { $_.members })) { $md += "- #$($m.number): $($m.repo)@$($m.sha.Substring(0, 12)) ($($m.role))" }
  foreach ($g in @($batch.groups | Where-Object { $_.record })) {
    $md += "- $($g.id) is recorded by the run recorder, $($g.record.repo)@$($g.record.sha.Substring(0, 12)), from $($g.record.parameterFile): it refuses to start if its own estimate is more than 10% over $(Format-AvdBatchMoney $g.estimate)"
  }
  $md += '', '### Approve', '', 'A person approves this batch at this total by running this in Cloud Shell (PowerShell or Bash) and typing the phrase:', ''
  $lz = if ($recorder) { $recorder } else { $null }
  $clone = if ($lz) { "https://github.com/$($lz.repo).git" } else { 'https://github.com/avd-ops/avd-landing-zone.git' }
  $checkout = if ($lz) { "git checkout -q $($lz.sha)" } else { 'git checkout -q master; git pull -q --ff-only' }
  $pre = @("if (-not (Test-Path ~/avd-landing-zone)) { git clone $clone `$HOME/avd-landing-zone }", "Set-Location ~/avd-landing-zone; git fetch -q origin; $checkout")
  $localFlag = if ($Local) { ' -Local' } else { '' }
  # One line that runs the same from Cloud Shell's PowerShell or Bash prompt.
  $block = { param($cmd) "pwsh -NoLogo -Command '$((@($pre) + $cmd) -join '; ')'" }
  $md += '```shell'
  $md += & $block "./scripts/ops/Approve-AvdSandboxBatch.ps1 -BatchId $($batch.batchId)$localFlag"
  $md += '```', '', "It asks for the phrase, which must be exactly ``go batch $($batch.batchId) `$$('{0:N2}' -f $batch.total)``.", ''
  $md += 'If anything changes (an item, a commit, an estimate), the batch has to be rebuilt and approved again. Each group runs once on this approval.', ''
  $md += '### Run (after the go), one Cloud Shell block per group', ''
  $caps = "-MonthlyCap $MonthlyCap -RunCap $RunCap"
  foreach ($g in $batch.groups) {
    $md += "**$($g.id)**", '', '```shell'
    # -Local records can't arm the deadline teardown (it reads results from the run store): say so in the block.
    $md += & $block "./scripts/ops/Invoke-AvdSandboxBatch.ps1 -BatchId $($batch.batchId) -Group $($g.id) $caps$(if ($Local) { ' -Local -NoDeadlineTeardown' })"
    $md += '```', ''
  }
  if ($Local) { $md += 'These records are on this disk only (`-Local`), so no deadline teardown can be armed: if Cloud Shell dies during a group, it keeps billing until the next block (or `-TeardownOnly`) tears it down.', '' }
  else { $md += 'Teardown is part of each block. A group arms its deadline teardown before it starts: if Cloud Shell dies, the run store''s Automation account tears the group down at its deadline, and the next block closes it (decision 0021).', '' }
  $md += 'If Cloud Shell drops or times out partway and you are still there, run the same block with `-Resume` added: finished steps are skipped and the interrupted one runs again. `./scripts/ops/Get-AvdSandboxBatchStatus.ps1` shows where each group stands.', ''
}
if ($plan.leftOut.Count) {
  $md += '### Left out of this batch', ''
  foreach ($l in $plan.leftOut) { $md += "- $(($l.group.items | ForEach-Object { "#$_" }) -join ', '): $($l.reasons -join '; ')" }
  $md += ''
}
if ($blocked.Count) {
  $md += '### Not ready', ''
  foreach ($b in $blocked) { $md += "- #$($b.number) $($b.purpose): $($b.problems -join '; ')" }
}

# ---- Write ----
$dir = Join-Path $RecordsPath 'queue' $Now.ToUniversalTime().ToString('yyyy-MM') $batch.batchId
if ($batch.groups.Count) {
  # The approval is tied to the file's hash, so a private value can't be masked after the fact: refuse it.
  $json = $batch | ConvertTo-Json -Depth 30
  $private = @(Test-AvdSpendPrivateValue $json)
  if ($private.Count) { throw "An item holds $($private -join ' and ') (in its commands or text). Replace it with a variable the command reads at run time, then rebuild." }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $json | Set-Content -Path (Join-Path $dir 'batch.json') -Encoding utf8NoBOM
  Hide-AvdSpendId ($md -join "`n") | Set-Content -Path (Join-Path $dir 'batch.md') -Encoding utf8NoBOM
  Save-AvdRunRecordStore -Store $store
}
Write-AvdSpendSummary $md
if ($env:GITHUB_OUTPUT -and $batch.groups.Count) { Add-Content -Path $env:GITHUB_OUTPUT -Value "batch_id=$($batch.batchId)" }
if ($PostIssue -and $batch.groups.Count) {
  Write-Host "Opening the batch issue in $Repo ..." -ForegroundColor DarkGray
  # gh issue create fails on a label the repo doesn't have yet; create it once.
  gh label create sandbox-batch -R $Repo --color 5319E7 --description 'A sandbox batch waiting for a go' 2>$null
  if ($LASTEXITCODE) { Write-Host '  Label sandbox-batch already exists.' -ForegroundColor DarkGray }
  gh issue create -R $Repo --title "Sandbox batch $($batch.batchId): $(Format-AvdBatchMoney $batch.total)" --label sandbox-batch --body-file (Join-Path $dir 'batch.md')
  if ($LASTEXITCODE) { throw "gh issue create failed (exit $LASTEXITCODE). The batch is written to $dir." }
}
