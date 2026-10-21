#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Where your sandbox batches stand: approved or not, each group's outcome, open spend runs, and the
  Cloud Shell block to continue anything that stopped part way (docs/sandbox-runs.md).

.DESCRIPTION
  Read-only. Pulls your records from the run store first (or reads -RecordsPath with -Local), so a
  new Cloud Shell session sees what the last one wrote.

.EXAMPLE
  ./scripts/ops/Get-AvdSandboxBatchStatus.ps1

.EXAMPLE
  ./scripts/ops/Get-AvdSandboxBatchStatus.ps1 -BatchId b20261021-1700
#>
[CmdletBinding()]
param(
  [ValidatePattern('^b\d{8}-\d{4}$')][string] $BatchId,
  [string] $SubscriptionId,
  [string] $RecordsPath,
  [switch] $Local
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSandboxBatch.psm1') -Force
if (-not $RecordsPath) { $RecordsPath = Get-AvdRecordsDefaultPath }

if (-not $Local) {
  $subId = (Initialize-AvdAzContext -SubscriptionId $SubscriptionId).Subscription.Id
  $null = Open-AvdRunRecordStore -RecordsPath $RecordsPath -SubscriptionId $subId
}
$batches = @(Get-ChildItem -Path (Join-Path $RecordsPath 'queue') -Recurse -Filter 'batch.json' -ErrorAction SilentlyContinue |
    Where-Object { -not $BatchId -or $_.Directory.Name -eq $BatchId } | Sort-Object { $_.Directory.Name })
if (-not $batches.Count) { Write-Host "No batches in $RecordsPath$(if ($BatchId) { " named $BatchId" })."; return }

$read = { param($p) if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -Depth 30 -AsHashtable } else { $null } }
$todo = [System.Collections.Generic.List[string]]::new()
foreach ($f in $batches) {
  $batch = & $read $f.FullName
  $dir = $f.DirectoryName
  $approval = & $read (Join-Path $dir 'approval.json')
  $check = Test-AvdBatchApproval -Batch $batch -Approval $approval
  $state = if ($check.valid) { "approved by $($approval.approvedBy) via $($approval.via)" } elseif ($approval) { "approval void: $($check.reasons -join ' ')" } else { 'waiting for a go' }
  Write-Host ''
  Write-Host ('Batch {0}: {1} group(s), {2}. {3}' -f $batch.batchId, @($batch.groups).Count, (Format-AvdBatchMoney $batch.total), $state) -ForegroundColor Cyan
  if (-not $approval) { $todo.Add("./scripts/ops/Approve-AvdSandboxBatch.ps1 -BatchId $($batch.batchId)") }
  $blocked = $false
  foreach ($g in @($batch.groups)) {
    $r = & $read (Join-Path $dir "results-$($g.id).json")
    $line = if (-not $r -or -not @(@($r.steps) | Where-Object { $_ }).Count) { 'not started' }
    elseif ($r.finishedAt) { "$($r.outcome) at $(Format-AvdBatchTime $r.finishedAt)" }
    else {
      $last = @($r.steps | Where-Object { $_ }) | Select-Object -Last 1
      "stopped part way: last step $($last.step)$(if ($last.item) { " (#$($last.item))" }) $(if ($null -eq $last.exitCode) { 'was interrupted' } else { "exited $($last.exitCode)" })"
    }
    Write-Host ('  {0}  {1,-28} {2,10}  {3}' -f $g.id, (($g.items | ForEach-Object { "#$_" }) -join ' '), (Format-AvdBatchMoney $g.estimate), $line)
    # A group that stopped part way may still be billing: always say how to finish or clean it up.
    if ($r -and -not $r.finishedAt -and @(@($r.steps) | Where-Object { $_ }).Count) {
      $todo.Add("./scripts/ops/Invoke-AvdSandboxBatch.ps1 -BatchId $($batch.batchId) -Group $($g.id) -Resume   # or -TeardownOnly to stop and clean up")
      $blocked = $true
    }
    elseif ($blocked -or -not $check.valid) { continue }
    elseif ($r -and $r.outcome -eq 'stop-batch') { $blocked = $true }
    elseif (-not $r -or -not @(@($r.steps) | Where-Object { $_ }).Count) {
      $todo.Add("./scripts/ops/Invoke-AvdSandboxBatch.ps1 -BatchId $($batch.batchId) -Group $($g.id)")
      $blocked = $true
    }
  }
}
$sandboxes = @(Get-ChildItem -LiteralPath $RecordsPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'queue' })
$open = @($sandboxes | ForEach-Object { Get-AvdSpendRun -RecordsPath $RecordsPath -Sandbox $_.Name } | Where-Object { $_.status -in 'open', 'leftovers' })
if ($open.Count) {
  Write-Host ''
  Write-Host 'Spend runs not closed clean (these may still be billing):' -ForegroundColor Yellow
  foreach ($s in $open) { Write-Host "  $($s.sandbox) / $($s.runId): $($s.status), started $(Format-AvdBatchTime $s.startedAt), $($s.purpose)" }
}
if ($todo.Count) {
  Write-Host ''
  Write-Host "Next (add -MonthlyCap and -RunCap$(if ($Local) { ' and -Local' })):" -ForegroundColor Green
  # One line each that runs the same from Cloud Shell's PowerShell or Bash prompt.
  $todo | ForEach-Object { $c, $note = $_ -split '   # '; Write-Host "  pwsh -NoLogo -Command 'Set-Location ~/avd-landing-zone; $c'$(if ($note) { "   # $note" })" }
}
