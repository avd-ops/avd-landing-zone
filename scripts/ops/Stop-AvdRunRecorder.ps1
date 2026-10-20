#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Closes, updates or copies a recorded run (build/specs/run-recorder-spec.md sections 8.1, 9.2, 9.3
  and 9.3a). Deletes nothing.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Every mode writes the run folder's manifest into run.json
  (avd-second-brain contract C17) and copies the folder to the run store's runs/<runId>/.

  -BeforeCleanup   Before the landing zone's cleanup: exports the AVD diagnostics tables (WVDConnections,
                   WVDErrors, WVDCheckpoints, WVDAgentHealthStatus) for the run's window from the landing
                   zone's Log Analytics workspace into logs/, because cleanup deletes the workspace and
                   with it the only copy. Checks every table's row count against what it wrote.
  (no switch)      At the end of the run: the run's status and end time, and the first actual cost
                   reading (Cost Management), marked not settled.
  -UpdateCost      Later: another actual cost reading, appended; settled once unchanged for 72 hours.
  -CopyTo github   A copy in the private companion repo (AVD_PRIVATE_REPO): each file gzip-compressed,
                   committed to the 'runs' branch under 50 MiB or uploaded as a release asset run-<runId>
                   under 2 GiB, then read back and checked. Larger files stay in Azure only. Refuses a
                   public repo. Sign in once with gh auth login (device code).

  Nothing here deletes a file; deleting a run's logs is teardown's job, by the -TeardownLogs preference.

.EXAMPLE
  ./scripts/ops/Stop-AvdRunRecorder.ps1 -BeforeCleanup -NamePrefix avdlz -Environment dev

.EXAMPLE
  ./scripts/ops/Stop-AvdRunRecorder.ps1 -NamePrefix avdlz -Environment dev -CopyTo github

.EXAMPLE
  ./scripts/ops/Stop-AvdRunRecorder.ps1 -UpdateCost -NamePrefix avdlz -Environment dev
#>
[CmdletBinding()]
param(
  [string] $RunId = $env:AVDLZ_RUN_ID,
  [ValidateLength(2, 8)][string] $NamePrefix,
  [ValidateSet('dev', 'test', 'prod')][string] $Environment = 'dev',
  [switch] $BeforeCleanup,
  [switch] $UpdateCost,
  [ValidateSet('github')][string] $CopyTo,
  [ValidateSet('succeeded', 'failed', 'abandoned', 'torn-down')][string] $Status = 'succeeded',
  [string] $PrivateRepo = $env:AVD_PRIVATE_REPO,
  [switch] $Local,
  [string] $LocalRoot = $(if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }),
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
if ($RunId -cnotmatch '^run-\d{8}-\d{4}-[a-z0-9]{4}$') { throw 'Pass -RunId, or set AVDLZ_RUN_ID, to the run ID Start-AvdRunRecorder.ps1 printed.' }
$folder = (Get-AvdJournalSetting -Record on -RunId $RunId -HomePath $LocalRoot -CloudDriveExists (Test-Path (Join-Path $LocalRoot 'clouddrive'))).Folder
$runPath = Join-Path $folder 'run.json'
if (-not (Test-Path -LiteralPath $runPath)) { throw "No run.json in $folder. Open the run with Start-AvdRunRecorder.ps1 first." }
$run = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json -AsHashtable
$storeName = Get-AvdRunStoreName -SubscriptionId $ctx.Subscription.Id
$lz = if ($NamePrefix) { Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment } else { $null }
Write-Host "Run recorder - $RunId in '$($ctx.Subscription.Name)'" -ForegroundColor White
$utc = { param($d) ([datetime]$d).ToUniversalTime() }
$now = [datetime]::UtcNow

if ($BeforeCleanup) {
  Write-AvdSection 'Landing zone logs, before cleanup'
  if (-not $lz) { throw 'Pass -NamePrefix and -Environment: the logs are read from that landing zone''s workspace.' }
  if (-not $lz.LogAnalyticsId) {
    Add-AvdCheckResult 'Run' 'Log Analytics workspace' 'Skip' -Id 'run-logs-noworkspace' -Detail 'The landing zone has no workspace (already removed?): nothing to export.'
  }
  else {
    $customerId = (Invoke-AvdArm -Path "$($lz.LogAnalyticsId)?api-version=2023-09-01").properties.customerId
    $null = New-Item -ItemType Directory -Path (Join-Path $folder 'logs') -Force
    foreach ($t in 'WVDConnections', 'WVDErrors', 'WVDCheckpoints', 'WVDAgentHealthStatus') {
      Write-Host "  Exporting $t for the run's window..." -ForegroundColor DarkGray
      $q = Get-AvdRunLogQuery -Table $t -From (& $utc $run.started) -To $now
      try { $rows = @(Invoke-AvdLogQuery -WorkspaceCustomerId $customerId -Query $q) }
      catch { Add-AvdCheckResult 'Run' "Export $t" 'Fail' -Id 'run-logs-export' -Detail "$_" -Remediation 'Do not run cleanup until the export succeeds: the workspace holds the only copy.'; continue }
      $file = Join-Path (Join-Path $folder 'logs') "$t.json"
      ConvertTo-Json -InputObject $rows -Depth 10 | Set-Content -LiteralPath $file -Encoding utf8
      $back = @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
      if ($back.Count -ne $rows.Count) {
        Add-AvdCheckResult 'Run' "Export $t" 'Fail' -Id 'run-logs-export' -Detail "Read $($rows.Count) rows, the file holds $($back.Count)." -Remediation 'Run this again before cleanup.'
      }
      else {
        Add-AvdCheckResult 'Run' "Exported $t ($($rows.Count) rows)" 'Pass' -Id 'run-logs-export' -Data @{ table = $t; rows = $rows.Count }
      }
    }
  }
}

if (-not $BeforeCleanup -and -not $UpdateCost -and -not $CopyTo) {
  $run.status = $Status
  $run.ended = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# Actual cost: at the end of the run and with -UpdateCost (spec section 9.3a).
if (($UpdateCost -or (-not $BeforeCleanup -and -not $CopyTo)) -and -not $Local) {
  Write-AvdSection 'Actual cost'
  $costPath = Join-Path $folder 'cost.json'
  $cost = Get-Content -LiteralPath $costPath -Raw | ConvertFrom-Json -AsHashtable
  $rgs = @('avdlz-runs-rg') + $(if ($lz) { @($lz.ResourceGroups.Values) } else { @() })
  $body = Get-AvdCostQueryBody -From (& $utc $run.started) -To $now -ResourceGroup $rgs
  Write-Host '  Reading actual cost from Cost Management...' -ForegroundColor DarkGray
  $resp = Invoke-AzRestMethod -Path "/subscriptions/$($ctx.Subscription.Id)/providers/Microsoft.CostManagement/query?api-version=2023-11-01" -Method POST -Payload ($body | ConvertTo-Json -Depth 10 -Compress)
  $after = $run.status -eq 'torn-down'
  if ($resp.StatusCode -eq 403) {
    $cost = Add-AvdRunCostReading -Cost $cost -ReadAt $now -Unavailable 'no access: needs Cost Management Reader or Reader on the subscription'
    Add-AvdCheckResult 'Run' 'Actual cost' 'Warn' -Id 'run-cost-actual' -Detail 'No access to Cost Management.' -Remediation 'Ask for Cost Management Reader on the subscription, then run -UpdateCost.'
  }
  elseif ($resp.StatusCode -ge 400) {
    $cost = Add-AvdRunCostReading -Cost $cost -ReadAt $now -Unavailable "Cost Management returned $($resp.StatusCode)"
    Add-AvdCheckResult 'Run' 'Actual cost' 'Warn' -Id 'run-cost-actual' -Detail "Cost Management returned $($resp.StatusCode): $($resp.Content)" -Remediation 'Run -UpdateCost later.'
  }
  else {
    $reading = Get-AvdCostQueryReading -Response ($resp.Content | ConvertFrom-Json -Depth 20)
    $cost = Add-AvdRunCostReading -Cost $cost -ReadAt $now -Total $reading.Total -ByMeter $reading.ByMeter -BillingAfterTeardown:($after -and $reading.Total -gt 0)
    $last = @($cost.actuals)[-1]
    $unexpected = @($cost.comparison.unexpectedMeters)
    Add-AvdCheckResult 'Run' "Actual cost so far $($reading.Total) $($cost.currency) (expected $($cost.expected.total))" $(if ($unexpected.Count) { 'Warn' } else { 'Pass' }) -Id 'run-cost-actual' `
      -Detail "$(if ($last.settled) { 'Settled.' } else { 'Not settled yet: Cost Management can take a day or more; run -UpdateCost later.' })$(if ($unexpected.Count) { " Billed but not in the estimate: $($unexpected -join ', ')." })" `
      -Data @{ actual = $reading.Total; expected = $cost.expected.total; settled = $last.settled; unexpectedMeters = $unexpected }
  }
  $cost | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $costPath -Encoding utf8
}

# The manifest, with the copies already verified for unchanged files.
$files = @(Get-AvdRunManifest -Folder $folder -Previous @($run.files | ForEach-Object { [pscustomobject]$_ }))

if ($CopyTo -eq 'github') {
  Write-AvdSection "Copy to $PrivateRepo"
  if (-not (Test-AvdPrivateRepoName $PrivateRepo)) { throw 'Set AVD_PRIVATE_REPO (or -PrivateRepo) to your private companion repo, owner/repo (spec section 9.3).' }
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is needed; it is in Azure Cloud Shell.' }
  $private = gh api "repos/$PrivateRepo" --jq '.private' 2>&1
  if ($LASTEXITCODE) { throw "gh api repos/$PrivateRepo failed: $private. Sign in with gh auth login (device code)." }
  if ("$private".Trim() -ne 'true') {
    Add-AvdCheckResult 'Run' 'Private companion repo is private' 'Fail' -Id 'run-copy-public' -Detail "$PrivateRepo is public: nothing was copied." `
      -Remediation 'Run records hold tenant names and IDs: use a private repository.'
  }
  else {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "avdlz-copy-$RunId"
    $null = New-Item -ItemType Directory -Path $tmp -Force
    # gzip each file; the manifest keeps both hashes.
    foreach ($f in $files) {
      $src = Join-Path $folder $f.path
      $gz = Join-Path $tmp (($f.path -replace '/', '__') + '.gz')
      $in = [IO.File]::OpenRead($src); $out = [IO.File]::Create($gz)
      try { $z = [IO.Compression.GZipStream]::new($out, [IO.Compression.CompressionLevel]::Optimal); $in.CopyTo($z); $z.Dispose() } finally { $in.Dispose(); $out.Dispose() }
      $f | Add-Member -NotePropertyName gzPath -NotePropertyValue $gz -Force
      $f | Add-Member -NotePropertyName gzBytes -NotePropertyValue (Get-Item -LiteralPath $gz).Length -Force
      $f | Add-Member -NotePropertyName gzSha256 -NotePropertyValue (Get-FileHash -LiteralPath $gz -Algorithm SHA256).Hash.ToLowerInvariant() -Force
    }
    $routes = @(Get-AvdRunFileRoute -File $files)
    $readBack = @{}

    # Commits: one commit per run on the orphan 'runs' branch, built through the Git data API.
    $commitFiles = @($files | Where-Object { ($routes | Where-Object Path -eq $_.path).Route -eq 'github' })
    if ($commitFiles.Count) {
      Write-Host "  Committing $($commitFiles.Count) file(s) to the runs branch..." -ForegroundColor DarkGray
      $parent = $null; $baseTree = $null
      $ref = gh api "repos/$PrivateRepo/git/ref/heads/runs" --jq '.object.sha' 2>$null
      if (-not $LASTEXITCODE -and $ref) { $parent = "$ref".Trim(); $baseTree = (gh api "repos/$PrivateRepo/git/commits/$parent" --jq '.tree.sha').Trim() }
      $entries = foreach ($f in $commitFiles) {
        $req = Join-Path $tmp 'blob.json'
        @{ content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.gzPath)); encoding = 'base64' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $req -Encoding utf8
        $sha = (gh api "repos/$PrivateRepo/git/blobs" --method POST --input $req --jq '.sha').Trim()
        if ($LASTEXITCODE) { throw "Uploading $($f.path) failed: $sha" }
        @{ path = "runs/$RunId/$($f.path).gz"; mode = '100644'; type = 'blob'; sha = $sha }
      }
      $treeReq = Join-Path $tmp 'tree.json'
      $t = @{ tree = @($entries) }; if ($baseTree) { $t.base_tree = $baseTree }
      $t | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $treeReq -Encoding utf8
      $tree = (gh api "repos/$PrivateRepo/git/trees" --method POST --input $treeReq --jq '.sha').Trim()
      $commitReq = Join-Path $tmp 'commit.json'
      $c = @{ message = "Run $RunId"; tree = $tree; parents = @($(if ($parent) { $parent })) }
      $c | ConvertTo-Json -Compress | Set-Content -LiteralPath $commitReq -Encoding utf8
      $commit = (gh api "repos/$PrivateRepo/git/commits" --method POST --input $commitReq --jq '.sha').Trim()
      if ($parent) { $null = gh api "repos/$PrivateRepo/git/refs/heads/runs" --method PATCH -f sha=$commit }
      else { $null = gh api "repos/$PrivateRepo/git/refs" --method POST -f ref='refs/heads/runs' -f sha=$commit }
      if ($LASTEXITCODE) { throw "Moving the runs branch to $commit failed." }
      # Read back: the tree GitHub now holds, against each file's own Git hash.
      $held = gh api "repos/$PrivateRepo/git/trees/$($commit)?recursive=1" --jq '.tree[] | select(.type == "blob") | .path + " " + .sha'
      $map = @{}; foreach ($l in @($held)) { $p, $s = "$l".Split(' ', 2); $map[$p] = $s }
      foreach ($f in $commitFiles) {
        if ($map["runs/$RunId/$($f.path).gz"] -eq (Get-AvdGitBlobSha -Bytes ([IO.File]::ReadAllBytes($f.gzPath)))) { $readBack[$f.path] = $f.gzSha256 }
      }
    }

    # Release assets: 50 MiB to 2 GiB, downloaded again and hashed.
    $assetFiles = @($files | Where-Object { ($routes | Where-Object Path -eq $_.path).Route -eq 'github-release' })
    if ($assetFiles.Count) {
      Write-Host "  Uploading $($assetFiles.Count) large file(s) as release assets (this can take minutes)..." -ForegroundColor DarkGray
      $tag = "run-$RunId"
      $null = gh release view $tag --repo $PrivateRepo 2>$null
      if ($LASTEXITCODE) { $null = gh release create $tag --repo $PrivateRepo --target runs --title "Run $RunId" --notes 'Run record files from 50 MiB to 2 GiB (gzip).' }
      $dl = Join-Path $tmp 'download'; $null = New-Item -ItemType Directory -Path $dl -Force
      foreach ($f in $assetFiles) {
        $null = gh release upload $tag $f.gzPath --repo $PrivateRepo --clobber
        $name = Split-Path $f.gzPath -Leaf
        $null = gh release download $tag --repo $PrivateRepo --pattern $name --dir $dl --clobber
        $got = Join-Path $dl $name
        if (Test-Path -LiteralPath $got) { $readBack[$f.path] = (Get-FileHash -LiteralPath $got -Algorithm SHA256).Hash.ToLowerInvariant() }
      }
    }

    foreach ($r in Test-AvdCopyReceipt -File @($files | Where-Object { ($routes | Where-Object Path -eq $_.path).Route -ne 'kept-in-azure' }) -ReadBack $readBack) {
      $f = $files | Where-Object path -eq $r.Path
      if ($r.Verified) {
        $target = ($routes | Where-Object Path -eq $r.Path).Route
        $f | Add-Member -NotePropertyName copies -NotePropertyValue (@(@($f.copies | Where-Object { $_ -and $_.target -ne $target }) + [pscustomobject]@{ target = $target; verifiedAt = $now.ToString('yyyy-MM-ddTHH:mm:ssZ'); sha256 = $f.gzSha256 })) -Force
      }
      else {
        Add-AvdCheckResult 'Run' "Copy of $($r.Path)" 'Fail' -Id 'run-copy-mismatch' -Detail "$($r.Reason)." -Remediation 'Run -CopyTo github again; nothing counts as copied until it is read back.'
      }
    }
    foreach ($k in @($routes | Where-Object Route -eq 'kept-in-azure')) {
      ($files | Where-Object path -eq $k.Path) | Add-Member -NotePropertyName keptOnlyIn -NotePropertyValue 'azure' -Force
      Add-AvdCheckResult 'Run' "$($k.Path) is 2 GiB or more compressed: kept in Azure only" 'Warn' -Id 'run-copy-kept' -Detail 'Beyond what free GitHub features hold (spec section 9.2).'
    }
    $copied = @($files | Where-Object { @($_.copies | Where-Object { $_ }).Count }).Count
    Add-AvdCheckResult 'Run' "Verified copies in $PrivateRepo for $copied of $($files.Count) file(s)" $(if ($copied -eq $files.Count) { 'Pass' } else { 'Warn' }) -Id 'run-copy'
    Remove-Item -Recurse -Force -LiteralPath $tmp
  }
}

# run.json last, with the manifest; then the store.
$run.files = @($files | ForEach-Object {
    $e = [ordered]@{}; foreach ($p in 'path', 'kind', 'level', 'bytes', 'sha256', 'gzSha256', 'copies', 'keptOnlyIn') { if ($null -ne $_.$p) { $e[$p] = $_.$p } }; $e
  })
$run | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $runPath -Encoding utf8
if ($Local) {
  Add-AvdCheckResult 'Run' "Run folder $folder" 'Pass' -Id 'run-folder' -Detail 'Local only (-Local).'
}
else {
  Write-Host "  Writing the run folder to $storeName/runs/$RunId/..." -ForegroundColor DarkGray
  $sc = New-AzStorageContext -StorageAccountName $storeName -UseConnectedAccount
  foreach ($p in @($files | ForEach-Object path) + 'run.json') {
    $null = Set-AzStorageBlobContent -File (Join-Path $folder $p) -Container 'runs' -Blob "$RunId/$p" -Context $sc -Force -ErrorAction Stop
  }
  Add-AvdCheckResult 'Run' "Run folder runs/$RunId in $storeName ($($files.Count + 1) files)" 'Pass' -Id 'run-folder'
}

$summary = Write-AvdSummary
exit $(if ($summary.Failed) { 1 } else { 0 })
