#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Publishes the results of a finished sandbox batch group to the private companion queue and back
  to the initiating repository issues (docs/sandbox-runs.md).

.DESCRIPTION
  Stage 3 of the three-stage sandbox batch pipeline:
    - Reads batch.json and results-<Group>.json from the run store (or local cache).
    - Builds the closeout report via Get-AvdBatchResultReport (AvdSandboxBatch.psm1).
    - Updates each member's queue issue in -PrivateRepo ($env:AVD_PRIVATE_REPO): swaps queue:ready
      for queue:done (or queue:failed), posts the run summary, and closes passed queue issues.
    - Posts a leak-checked, redacted verification comment back on each initiating repository issue
      (owner/repo#N) naming the batch ID, group, pinned commit SHA, deploy/test/teardown/close
      outcomes, C17 recorded run ID, and kept artifact hashes.

  Idempotent: records reportedAt in results-<Group>.json once published so a second invocation skips
  already-reported groups unless -Force is passed.

.EXAMPLE
  ./scripts/ops/Publish-AvdSandboxResult.ps1 -BatchId b20261021-1700 -Group G1 -PrivateRepo $env:AVD_PRIVATE_REPO

.EXAMPLE
  ./scripts/ops/Publish-AvdSandboxResult.ps1 -BatchId b20261021-1700 -Group G1 -Local -DryRun
#>
[CmdletBinding()]
param(
  # Batch ID to report (for example, b20261021-1700).
  [Parameter(Mandatory)][string] $BatchId,
  # Group ID within the batch (for example, G1).
  [Parameter(Mandatory)][ValidatePattern('^G\d+$')][string] $Group,
  # Local records cache folder; defaults to ~/clouddrive/avd-runs or ~/avd-runs.
  [string] $RecordsPath,
  # Sandbox subscription ID for the run store.
  [string] $SubscriptionId,
  # Private companion repository (owner/repo) holding the sandbox-run queue issues.
  [string] $PrivateRepo = $env:AVD_PRIVATE_REPO,
  # Read and write records on this disk only without syncing the Azure run store.
  [switch] $Local,
  # Also close the initiating repository issue when its verification test passed.
  [switch] $CloseInitiatingIssue,
  # Optional file path to write the generated result report JSON.
  [string] $OutPath,
  # Publish again even if results-<Group>.json already records reportedAt.
  [switch] $Force,
  # Build and print the report without calling GitHub.
  [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSandboxBatch.psm1') -Force

if (-not $RecordsPath) { $RecordsPath = Get-AvdRecordsDefaultPath }
$subId = $SubscriptionId
if (-not $Local -and -not $subId) { $subId = (Initialize-AvdAzContext -SubscriptionId $SubscriptionId).Subscription.Id }
$store = Open-AvdRunRecordStore -RecordsPath $RecordsPath -SubscriptionId $subId -Local:$Local

$qDir = Join-Path $RecordsPath 'queue'
$batchFile = if (Test-Path -LiteralPath $qDir) {
  Get-ChildItem -LiteralPath $qDir -Recurse -Filter 'batch.json' -File | Where-Object { $_.Directory.Name -eq $BatchId } | Select-Object -First 1
} else { $null }
if (-not $batchFile) { throw "No batch $BatchId in $RecordsPath." }
$dir = $batchFile.Directory.FullName
$resultsPath = Join-Path $dir "results-$Group.json"
if (-not (Test-Path -LiteralPath $resultsPath)) { throw "Group $Group of batch $BatchId has no results file ($resultsPath)." }

$batch = Get-Content -LiteralPath $batchFile.FullName -Raw | ConvertFrom-Json -Depth 30 -AsHashtable
$results = Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json -Depth 30 -AsHashtable
$report = Get-AvdBatchResultReport -Batch $batch -Group $Group -Results $results

if ($OutPath) {
  New-Item -ItemType Directory -Force -Path (Split-Path $OutPath) | Out-Null
  $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutPath -Encoding utf8NoBOM
  Write-Host "Wrote batch result report to $OutPath." -ForegroundColor DarkGray
}

foreach ($u in $report.queueUpdates) {
  Write-Host "  [QUEUE #$($u.number)] passed=$($u.passed) label=$($u.addLabel) close=$($u.closeIssue)" -ForegroundColor $(if ($u.passed) { 'Green' } else { 'Yellow' })
}
foreach ($r in $report.initiatingReports) {
  Write-Host "  [ISSUE $($r.ref)] passed=$($r.passed) (from item #$($r.itemNumber))" -ForegroundColor $(if ($r.passed) { 'Green' } else { 'Yellow' })
}

if ($DryRun) {
  Write-Host ''
  foreach ($r in $report.initiatingReports) {
    Write-Host "--- $($r.ref) ---" -ForegroundColor Cyan
    Write-Host $r.comment
  }
  exit 0
}

if ($results.ContainsKey('reportedAt') -and $results['reportedAt'] -and -not $Force) {
  Write-Host "Group $Group of batch $BatchId was already reported at $($results['reportedAt']). Pass -Force to post again." -ForegroundColor DarkGray
  exit 0
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is required to publish results to GitHub issues.' }

$tmpComment = Join-Path ([IO.Path]::GetTempPath()) "avdlz-report-$([guid]::NewGuid().ToString('N')).md"
try {
  if ($PrivateRepo) {
    if (-not (Test-AvdPrivateRepoName $PrivateRepo)) { throw 'Set AVD_PRIVATE_REPO (or -PrivateRepo) to owner/repo.' }
    $isPrivate = "$(gh api "repos/$PrivateRepo" --jq '.private' 2>&1)".Trim()
    if ($LASTEXITCODE) { throw "gh api repos/$PrivateRepo failed: $isPrivate" }
    if ($isPrivate -ne 'true') { throw "Refusing: $PrivateRepo is not a private repository." }

    foreach ($u in $report.queueUpdates) {
      Write-Host "  Updating queue issue #$($u.number) in $PrivateRepo ..." -ForegroundColor DarkGray
      $u.comment | Set-Content -LiteralPath $tmpComment -Encoding utf8NoBOM
      $null = gh issue comment $u.number -R $PrivateRepo --body-file $tmpComment
      if ($LASTEXITCODE) { throw "gh issue comment on $PrivateRepo#$($u.number) failed." }
      $null = gh issue edit $u.number -R $PrivateRepo --add-label $u.addLabel --remove-label $u.removeLabel
      if ($u.closeIssue) {
        $null = gh issue close $u.number -R $PrivateRepo
      }
    }
  }

  foreach ($r in $report.initiatingReports) {
    if ($PrivateRepo -and $r.comment -match ([regex]::Escape($PrivateRepo))) {
      throw "Refusing to post on $($r.ref): comment mentions private repository name."
    }
    Write-Host "  Posting redacted verification result on $($r.ref) ..." -ForegroundColor DarkGray
    $r.comment | Set-Content -LiteralPath $tmpComment -Encoding utf8NoBOM
    $null = gh issue comment $r.issueNumber -R $r.repo --body-file $tmpComment
    if ($LASTEXITCODE) { throw "gh issue comment on $($r.ref) failed." }
    if ($CloseInitiatingIssue -and $r.passed) {
      $null = gh issue close $r.issueNumber -R $r.repo
    }
  }
}
finally {
  Remove-Item -LiteralPath $tmpComment -ErrorAction SilentlyContinue
}

$results['reportedAt'] = (Get-Date).ToUniversalTime().ToString('o')
$relResults = [IO.Path]::GetRelativePath($RecordsPath, $resultsPath) -replace '\\', '/'
$results | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultsPath -Encoding utf8NoBOM
Save-AvdRunRecordStore -Store $store -Only $relResults
Write-Host "Published results for batch $BatchId group $Group." -ForegroundColor Green
