#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Syncs sandbox-run/v1 test items from an initiating repository's open issues (or a folder of item
  files) into the private companion repository's sandbox queue (docs/sandbox-runs.md).

.DESCRIPTION
  Stage 1 of the three-stage sandbox batch pipeline:
    1. Sync-AvdSandboxQueue.ps1: extracts sandbox-run/v1 items from open issues in -SourceRepo (or
       JSON files in -ItemsPath), resolves @HEAD to the current 40-hex commit SHA, validates every
       item against Get-AvdBatchItem and Test-AvdSpendPrivateValue, and creates or updates the
       corresponding sandbox-run + queue:ready issues in -PrivateRepo ($env:AVD_PRIVATE_REPO).
    2. New-AvdSandboxBatch.ps1 / Approve-AvdSandboxBatch.ps1 / Invoke-AvdSandboxBatch.ps1: pulls
       ready queue items from -PrivateRepo, groups shared deploymentKeys, waits for the owner's
       go phrase, runs the deployment and tests, and copies the recorded run to -PrivateRepo.
    3. Publish-AvdSandboxResult.ps1: updates the queue issues in -PrivateRepo and posts a redacted,
       leak-checked verification report back to the initiating repository's issues.

  Refuses any non-private target repository, any item with validation errors, or any item holding
  GUIDs, emails, or tenant domains.

.EXAMPLE
  ./scripts/ops/Sync-AvdSandboxQueue.ps1 -SourceRepo avd-ops/avd-landing-zone -PrivateRepo $env:AVD_PRIVATE_REPO

.EXAMPLE
  ./scripts/ops/Sync-AvdSandboxQueue.ps1 -ItemsPath ~/clouddrive/queue -PrivateRepo $env:AVD_PRIVATE_REPO -DryRun
#>
[CmdletBinding()]
param(
  # Initiating repository (owner/repo) whose open issues carry sandbox-run/v1 blocks.
  [string] $SourceRepo,
  # Folder of sandbox-run/v1 JSON files.
  [string] $ItemsPath,
  # Offline JSON file of initiating issues (gh issue list --json number,title,body,comments,labels).
  [string] $IssuesPath,
  # Optional filter to sync only specific item or issue numbers.
  [int[]] $IssueNumber,
  # Private companion repository (owner/repo) where sandbox-run queue issues live.
  [string] $PrivateRepo = $env:AVD_PRIVATE_REPO,
  # 40-hex commit SHA to resolve @HEAD in item sources; defaults to HEAD of this checkout or -SourceRepo.
  [string] $HeadSha,
  # Default sandbox region; items in another region must include regionReason.
  [string] $DefaultRegion = $env:SPEND_DEFAULT_REGION,
  # Optional file path to write the rendered queue issues as JSON.
  [string] $OutPath,
  # Validate and print the queue issues without calling GitHub.
  [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSandboxBatch.psm1') -Force

if (-not ($SourceRepo -or $ItemsPath -or $IssuesPath)) {
  throw 'Specify where queue items come from: -SourceRepo (owner/repo with open issues), -ItemsPath (folder of sandbox-run/v1 JSON files), or -IssuesPath (offline issues JSON).'
}
if ($IssuesPath -and -not $SourceRepo) {
  throw '-IssuesPath requires -SourceRepo (owner/repo) so initiating issue references can be stamped as owner/repo#N.'
}

if (-not $HeadSha) {
  $root = Join-Path $PSScriptRoot '../..'
  $sha = "$(git -C $root rev-parse HEAD 2>$null)".Trim()
  if ($sha -match '^[0-9a-f]{40}$') { $HeadSha = $sha }
}

# ---- Read raw items ----
$rawItems = if ($ItemsPath) {
  Write-Host "Reading sandbox-run/v1 item files from $ItemsPath ..." -ForegroundColor DarkGray
  @(Get-ChildItem -LiteralPath $ItemsPath -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
      Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
    })
}
elseif ($IssuesPath) {
  Write-Host "Reading initiating issues from $IssuesPath for $SourceRepo ..." -ForegroundColor DarkGray
  $list = @(Get-Content -LiteralPath $IssuesPath -Raw | ConvertFrom-Json -Depth 20)
  @($list | ForEach-Object { ConvertFrom-AvdBatchInitiatingIssue -Repo $SourceRepo -Issue $_ -HeadSha $HeadSha } | Where-Object { $null -ne $_ })
}
else {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is required to read issues from -SourceRepo.' }
  if ($SourceRepo -match '^[\w.-]+/[\w.-]+$' -and -not $HeadSha) {
    $remoteSha = "$(gh api "repos/$SourceRepo/commits/HEAD" --jq '.sha' 2>$null)".Trim()
    if ($remoteSha -match '^[0-9a-f]{40}$') { $HeadSha = $remoteSha }
  }
  Write-Host "Reading open issues from $SourceRepo ..." -ForegroundColor DarkGray
  $json = gh issue list -R $SourceRepo --state open --limit 100 --json 'number,title,body,comments,labels'
  if ($LASTEXITCODE) { throw "gh issue list on $SourceRepo failed (exit $LASTEXITCODE)." }
  $list = @($json | ConvertFrom-Json -Depth 20)
  @($list | ForEach-Object { ConvertFrom-AvdBatchInitiatingIssue -Repo $SourceRepo -Issue $_ -HeadSha $HeadSha } | Where-Object { $null -ne $_ })
}

if ($IssueNumber -and $IssueNumber.Count) {
  $rawItems = @($rawItems | Where-Object { [int]$_.number -in $IssueNumber })
}
if (-not $rawItems.Count) {
  Write-Host 'No sandbox-run/v1 queue items found.' -ForegroundColor Yellow
  exit 0
}

# ---- Build & validate queue issues ----
$queueIssues = @($rawItems | ForEach-Object {
    Get-AvdBatchQueueIssue -Item $_ -HeadSha $HeadSha -DefaultRegion $DefaultRegion
  })
$bad = @($queueIssues | Where-Object { @($_.problems).Count -gt 0 })
if ($bad.Count) {
  foreach ($b in $bad) {
    Write-Host "  [FAIL] #$($b.number) ($($b.title)): $($b.problems -join '; ')" -ForegroundColor Red
  }
  throw "$($bad.Count) queue item(s) failed validation. Fix the problems above before syncing to the queue."
}

if ($OutPath) {
  New-Item -ItemType Directory -Force -Path (Split-Path $OutPath) | Out-Null
  $queueIssues | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutPath -Encoding utf8NoBOM
  Write-Host "Wrote $($queueIssues.Count) validated queue issue(s) to $OutPath." -ForegroundColor DarkGray
}

foreach ($q in $queueIssues) {
  $keyText = if ($q.deploymentKey) { "key=$($q.deploymentKey)" } else { 'standalone' }
  Write-Host "  [READY] #$($q.number) $($q.title) ($keyText)" -ForegroundColor Green
}

if ($DryRun) {
  Write-Host ''
  Write-Host "Dry run: $($queueIssues.Count) item(s) validated and ready for the sandbox queue." -ForegroundColor Cyan
  exit 0
}

# ---- Sync to PrivateRepo ----
if (-not (Test-AvdPrivateRepoName $PrivateRepo)) {
  throw 'Set AVD_PRIVATE_REPO (or pass -PrivateRepo owner/repo) to your private companion repository.'
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is required to sync queue issues to -PrivateRepo.' }
$isPrivate = "$(gh api "repos/$PrivateRepo" --jq '.private' 2>&1)".Trim()
if ($LASTEXITCODE) { throw "gh api repos/$PrivateRepo failed: $isPrivate" }
if ($isPrivate -ne 'true') { throw "Refusing: $PrivateRepo is not a private repository. The sandbox queue lives in your private companion repo." }

foreach ($lbl in @(
    @{ name = 'sandbox-run'; color = '1D76DB'; desc = 'Sandbox run queue item (sandbox-run/v1)' },
    @{ name = 'queue:ready'; color = '0E8A16'; desc = 'Ready to be grouped into a sandbox batch' },
    @{ name = 'queue:done'; color = '5319E7'; desc = 'Sandbox batch run passed and closed clean' },
    @{ name = 'queue:failed'; color = 'D93F0B'; desc = 'Sandbox batch run failed' }
  )) {
  $null = gh label create $lbl.name -R $PrivateRepo --color $lbl.color --description $lbl.desc --force 2>$null
}

$existingRaw = gh issue list -R $PrivateRepo --label sandbox-run --state open --limit 100 --json 'number,title,labels'
if ($LASTEXITCODE) { throw "gh issue list on $PrivateRepo failed (exit $LASTEXITCODE)." }
$existing = @($existingRaw | ConvertFrom-Json -Depth 10)

$tmpBody = Join-Path ([IO.Path]::GetTempPath()) "avdlz-queue-$([guid]::NewGuid().ToString('N')).md"
try {
  foreach ($q in $queueIssues) {
    $q.body | Set-Content -LiteralPath $tmpBody -Encoding utf8NoBOM
    $marker = if ($q.initiatingIssue) { "[$($q.initiatingIssue)]" } else { "[item #$($q.number)]" }
    $match = @($existing | Where-Object { "$($_.title)".Contains($marker) }) | Select-Object -First 1
    if ($match) {
      Write-Host "  Updating queue issue #$($match.number) in $PrivateRepo ($marker) ..." -ForegroundColor DarkGray
      $null = gh issue edit $match.number -R $PrivateRepo --title $q.title --body-file $tmpBody --add-label 'sandbox-run,queue:ready'
      if ($LASTEXITCODE) { throw "gh issue edit #$($match.number) in $PrivateRepo failed." }
    }
    else {
      Write-Host "  Creating queue issue in $PrivateRepo ($marker) ..." -ForegroundColor DarkGray
      $null = gh issue create -R $PrivateRepo --title $q.title --body-file $tmpBody --label 'sandbox-run,queue:ready'
      if ($LASTEXITCODE) { throw "gh issue create in $PrivateRepo failed." }
    }
  }
}
finally {
  Remove-Item -LiteralPath $tmpBody -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Synced $($queueIssues.Count) item(s) to $PrivateRepo. Build and price the batch in Cloud Shell:" -ForegroundColor Cyan
Write-Host "pwsh -NoLogo -Command 'if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/avd-ops/avd-landing-zone.git `$HOME/avd-landing-zone }; Set-Location ~/avd-landing-zone; git pull -q --ff-only; ./scripts/ops/New-AvdSandboxBatch.ps1 -Repo `$env:AVD_PRIVATE_REPO -MonthlyCap 150 -RunCap 25 -PostIssue'"
