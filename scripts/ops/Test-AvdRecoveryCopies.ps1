#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  The monthly verify routine (build/specs/recovery-spec.md section 9): copies rot silently, so read
  every one back. Reports; never deletes, overwrites or repairs.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell), once a month. Seconds to minutes; read-only everywhere.

  1. Companion repo: for every file a run.json says was copied to your private companion repo
     (AVD_PRIVATE_REPO, the runs branch), read the copy back through the GitHub CLI and compare its
     SHA-256 with the manifest. With -IncludeReleaseAssets, also download and hash release assets.
  2. Run folders: list every file with no verified copy, with its size (the last copy, decision 0016).
  3. Profile backup: the vault's soft delete and immutability, the last backup job and the newest
     recovery point (with -NamePrefix).
  4. Writes the findings as a recorded run (use case 'recovery', kind 'verify', contract C17).

  Then run Export-AvdConfiguration.ps1 (it reports drift since the last snapshot) and
  Get-AvdRecoveryStatus.ps1.

.EXAMPLE
  ./scripts/ops/Test-AvdRecoveryCopies.ps1 -NamePrefix avdlz -Environment dev
#>
[CmdletBinding()]
param(
  [ValidateLength(2, 8)][string] $NamePrefix,
  [ValidateSet('dev', 'test', 'prod')][string] $Environment = 'dev',
  [string] $PrivateRepo = $env:AVD_PRIVATE_REPO,
  [switch] $IncludeReleaseAssets,
  [string] $LocalRoot = $(if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }),
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRecovery.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
$now = [datetime]::UtcNow
$runId = Get-AvdRunId
Write-Host "Verify copies - '$($ctx.Subscription.Name)', run $runId" -ForegroundColor White

$roots = @((Join-Path $LocalRoot 'clouddrive/avdlz-runs'), (Join-Path $LocalRoot 'avdlz-runs') | Where-Object { Test-Path -LiteralPath $_ })
$records = @(foreach ($root in $roots) {
    foreach ($f in Get-ChildItem -LiteralPath $root -Filter run.json -Recurse -Depth 1 -ErrorAction SilentlyContinue) {
      try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Host "  Skipping $($f.FullName): not JSON." -ForegroundColor DarkYellow }
    }
  })
Write-Host "  $($records.Count) run folder(s) under $($roots -join ', ')" -ForegroundColor DarkGray
$findings = [ordered]@{ ok = 0; mismatch = 0; missing = 0; nocopy = 0 }

# 1. The companion repo: each committed file read back by its blob, hashed, compared.
Write-AvdSection 'Companion repo'
$withGithub = @($records | Where-Object { @($_.files | Where-Object { @($_.copies | Where-Object { $_ -and $_.target -eq 'github' }).Count }).Count })
$withRelease = @($records | Where-Object { @($_.files | Where-Object { @($_.copies | Where-Object { $_ -and $_.target -eq 'github-release' }).Count }).Count })
if (-not ($withGithub.Count + $withRelease.Count)) {
  Add-AvdCheckResult 'Copies' 'Companion repo copies' 'Skip' -Id 'verify-github-none' -Detail 'No run.json records a copy in the companion repo.'
}
elseif (-not (Test-AvdPrivateRepoName $PrivateRepo) -or -not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Add-AvdCheckResult 'Copies' 'Companion repo copies' 'Fail' -Id 'verify-github-noaccess' -Detail 'Set AVD_PRIVATE_REPO to owner/repo and sign in with gh auth login (device code).' -Remediation 'Nothing was checked; run this again after signing in.'
}
else {
  Write-Host "  Reading the runs branch of $PrivateRepo..." -ForegroundColor DarkGray
  $tree = gh api "repos/$PrivateRepo/git/trees/runs?recursive=1" --jq '.tree[] | select(.type == "blob") | .path + " " + .sha' 2>&1
  if ($LASTEXITCODE) {
    Add-AvdCheckResult 'Copies' 'Read the runs branch' 'Fail' -Id 'verify-github-read' -Detail "gh api failed: $tree" -Remediation 'Check gh auth status and AVD_PRIVATE_REPO, then run this again.'
  }
  else {
    $blobs = @{}; foreach ($l in @($tree)) { $p, $s = "$l".Split(' ', 2); $blobs[$p] = $s }
    foreach ($r in $withGithub + $withRelease | Sort-Object { $_.runId } -Unique) {
      $held = @{}
      foreach ($f in @($r.files | Where-Object { $_ })) {
        $last = @($f.copies | Where-Object { $_ -and $_.sha256 }) | Select-Object -Last 1
        if (-not $last) { continue }
        if ($last.target -eq 'github') {
          $sha = $blobs["runs/$($r.runId)/$($f.path).gz"]
          if (-not $sha) { continue }
          $b64 = gh api "repos/$PrivateRepo/git/blobs/$sha" --jq '.content' 2>&1
          if ($LASTEXITCODE) { Add-AvdCheckResult 'Copies' "Read $($r.runId)/$($f.path)" 'Fail' -Id 'verify-github-read' -Detail "$b64"; continue }
          $bytes = [Convert]::FromBase64String((("$b64" -join '') -replace '\s', ''))
          $held[$f.path] = -join ([Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') })
        }
        elseif ($last.target -eq 'github-release' -and $IncludeReleaseAssets) {
          $dl = Join-Path ([IO.Path]::GetTempPath()) "avdlz-verify-$($r.runId)"; $null = New-Item -ItemType Directory -Path $dl -Force
          $name = ($f.path -replace '/', '__') + '.gz'
          $null = gh release download "run-$($r.runId)" --repo $PrivateRepo --pattern $name --dir $dl --clobber 2>&1
          $got = Join-Path $dl $name
          if (Test-Path -LiteralPath $got) { $held[$f.path] = (Get-FileHash -LiteralPath $got -Algorithm SHA256).Hash.ToLowerInvariant(); Remove-Item -LiteralPath $got -Force }
        }
        else { $held[$f.path] = $last.sha256 }   # a release asset not downloaded this time: not checked, not counted as bad
      }
      foreach ($c in Get-AvdCopyCheck -File @($r.files | Where-Object { @($_.copies | Where-Object { $_ }).Count }) -Held $held) {
        $findings[$c.Status]++
        if ($c.Status -ne 'ok') { Add-AvdCheckResult 'Copies' "$($r.runId)/$($c.Path)" 'Fail' -Id "verify-copy-$($c.Status)" -Detail $c.Detail -Remediation 'A finding, not a repair: copy the run again with Stop-AvdRunRecorder.ps1 -CopyTo github while the run folder still holds the original.' }
      }
    }
    Add-AvdCheckResult 'Copies' "Companion repo: $($findings.ok) file(s) read back and matched" $(if ($findings.mismatch + $findings.missing) { 'Fail' } else { 'Pass' }) -Id 'verify-github' `
      -Data @{ ok = $findings.ok; mismatch = $findings.mismatch; missing = $findings.missing }
  }
}

# 2. Files with no verified copy anywhere: the last copy.
Write-AvdSection 'Run folders'
$last = @(foreach ($r in $records) {
    foreach ($f in @($r.files | Where-Object { $_ -and -not @($_.copies | Where-Object { $_ -and $_.sha256 }).Count })) { [pscustomobject]@{ Run = $r.runId; Path = $f.path; Bytes = [long]$f.bytes; Kept = $f.keptOnlyIn } }
  })
$findings.nocopy = $last.Count
if ($last.Count) {
  $mb = [math]::Round((($last | Measure-Object Bytes -Sum).Sum) / 1MB, 1)
  foreach ($g in $last | Group-Object Run | Select-Object -First 10) { Write-Host "  $($g.Name): $($g.Count) file(s) with no verified copy" -ForegroundColor DarkYellow }
  Add-AvdCheckResult 'Copies' "$($last.Count) file(s) in $(@($last | Group-Object Run).Count) run(s) have no verified copy ($mb MB)" 'Warn' -Id 'verify-nocopy' `
    -Detail 'These are the last copy: nothing deletes them without your typed confirmation (decision 0016).' -Remediation 'Copy them: ./scripts/ops/Stop-AvdRunRecorder.ps1 -RunId <runId> -Local -CopyTo github' -Data @{ files = $last.Count; megabytes = $mb }
}
else { Add-AvdCheckResult 'Copies' 'Every file in the run folders has a verified copy' 'Pass' -Id 'verify-nocopy' }

# 3. The profile backup, as Azure Backup reports it.
if ($NamePrefix) {
  Write-AvdSection 'Profile backup'
  $lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
  if (-not $lz.RecoveryVault) { Add-AvdCheckResult 'Backup' 'Profile backup' 'Fail' -Id 'verify-backup-off' -Detail 'No Recovery Services vault: profile backup is off.' }
  else {
    $vaultId = "$($lz.ResourceGroupIds.Storage)/providers/Microsoft.RecoveryServices/vaults/$($lz.RecoveryVault.Name)"
    try {
      $vault = Invoke-AvdArm -Path "$($vaultId)?api-version=2024-04-01"
      $soft = "$($vault.properties.securitySettings.softDeleteSettings.softDeleteState)"
      $imm = "$($vault.properties.securitySettings.immutabilitySettings.state)"
      Add-AvdCheckResult 'Backup' "Vault soft delete $soft, immutability $imm" $(if ($soft -in 'Enabled', 'AlwaysON') { 'Pass' } else { 'Fail' }) -Id 'verify-vault' `
        -Remediation $(if ($soft -notin 'Enabled', 'AlwaysON') { 'Turn soft delete back on: without it a deleted recovery point is gone at once.' })
      $item = @(Get-AvdArmList -Path "$vaultId/backupProtectedItems?api-version=2024-04-01&`$filter=backupManagementType eq 'AzureStorage'") |
        Where-Object { "$($_.name)" -match ";$([regex]::Escape($lz.ProfileShareName))$" } | Select-Object -First 1
      if (-not $item) { Add-AvdCheckResult 'Backup' 'Profile share protected' 'Fail' -Id 'verify-backup-item' -Detail 'The vault does not protect the profile share.' }
      else {
        $points = @(Get-AvdArmList -Path "$($item.id)/recoveryPoints?api-version=2024-04-01")
        $newest = $points | Sort-Object { [datetime]$_.properties.recoveryPointTime } -Descending | Select-Object -First 1
        $lastStatus = "$($item.properties.lastBackupStatus)"
        $age = if ($newest) { ($now - ([datetime]$newest.properties.recoveryPointTime).ToUniversalTime()).TotalHours } else { $null }
        $ok = $lastStatus -eq 'Healthy' -or $lastStatus -eq 'Completed'
        Add-AvdCheckResult 'Backup' "Last backup $(if ($lastStatus) { $lastStatus } else { 'not reported' }); $($points.Count) recovery point(s)$(if ($null -ne $age) { ", newest $([math]::Round($age)) h old" })" `
          $(if ($ok -and $null -ne $age -and $age -le 26) { 'Pass' } else { 'Fail' }) -Id 'verify-backup' -Remediation 'Open the vault''s Backup jobs for the error; the post-deployment preflight reports the cause it knows.' `
          -Data @{ lastBackupStatus = $lastStatus; recoveryPoints = $points.Count; newestAgeHours = $(if ($null -ne $age) { [math]::Round($age, 1) }) }
      }
    }
    catch { Add-AvdCheckResult 'Backup' 'Read the profile backup' 'Fail' -Id 'verify-backup-read' -Detail "$_" }
  }
}

# 4. The verify run's own record.
$folder = (Get-AvdJournalSetting -Record on -RunId $runId -HomePath $LocalRoot -CloudDriveExists (Test-Path (Join-Path $LocalRoot 'clouddrive'))).Folder
$null = New-Item -ItemType Directory -Path $folder -Force
$all = @(Get-AvdCheckResult)
ConvertTo-Json -InputObject @($all | ForEach-Object { [ordered]@{ id = $_.Id; status = $_.Status; check = $_.Check; detail = $_.Detail } }) -Depth 5 | Set-Content -LiteralPath (Join-Path $folder 'verify.json') -Encoding utf8
$commit = '0000000'
if (Get-Command git -ErrorAction SilentlyContinue) { $h = git -C $PSScriptRoot rev-parse --short HEAD 2>$null; if (-not $LASTEXITCODE -and $h) { $commit = "$h".Trim() } }
$record = Get-AvdRunRecord -RunId $runId -UseCase 'recovery' -Commit $commit -Entry 'Test-AvdRecoveryCopies.ps1' -Started $now -Extension ([ordered]@{ kind = 'verify'; findings = $findings })
$failed = @($all | Where-Object Status -eq 'Fail').Count
$record.status = if ($failed) { 'failed' } else { 'succeeded' }
$record.ended = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$record.files = @(Get-AvdRunManifest -Folder $folder | ForEach-Object { $e = [ordered]@{}; foreach ($p in $_.PSObject.Properties) { $e[$p.Name] = $p.Value }; $e })
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'run.json') -Encoding utf8
Write-Host ''
Write-Host "Recorded as $runId ($folder). Next: Export-AvdConfiguration.ps1 (drift) and Get-AvdRecoveryStatus.ps1." -ForegroundColor White
$summary = Write-AvdSummary
exit $(if ($summary.Failed) { 1 } else { 0 })
