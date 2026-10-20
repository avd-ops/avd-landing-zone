#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for same-tenant recovery (scripts/ops/AvdRecovery.psm1; build/specs/recovery-spec.md).
# Fixtures omit empty properties the way ARM does (lesson 0021).
# Run: Invoke-Pester ./build/tests

BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../../scripts/ops/AvdRecovery.psm1') -Force
  $script:now = [datetime]'2026-10-20T12:00:00Z'
  $script:sha = '0123456789abcdef0123456789abcdef01234567'
  function New-Run([string] $Kind, [double] $HoursAgo, [switch] $Copied, [switch] $Identity, [string] $Tier = 'R0', [string] $Outcome) {
    $files = @(@{ path = 'config/hostpools.json'; kind = 'config'; bytes = 10; sha256 = ('a' * 64) })
    if ($Identity) { $files += @{ path = 'config/identity.json'; kind = 'config'; bytes = 10; sha256 = ('b' * 64) } }
    if ($Copied) { foreach ($f in $files) { $f.copies = @(@{ target = 'github'; verifiedAt = '2026-10-20T00:00:00Z'; sha256 = ('c' * 64) }) } }
    $ext = @{ kind = $Kind; tier = $Tier }
    if ($Outcome) { $ext.outcome = $Outcome; $ext.measured = @{ rpoMinutes = 300; rtoMinutes = 42 } }
    @{ schema = 'avd-run-record/v1'; runId = "run-20261020-0000-$($Kind.Substring(0,1))$([int]$HoursAgo)".PadRight(22, 'x').Substring(0, 22); useCase = 'recovery'; level = 'private'
      started = $script:now.AddHours(-$HoursAgo).ToString('o'); files = $files; extensions = @{ recovery = $ext } }
  }
  function Get-Verdict([hashtable] $Extra = @{}) {
    $p = @{ Tier = 'R0'; Now = $script:now; BackupEnabled = $true; KeyVault = [pscustomobject]@{ properties = [pscustomobject]@{ enablePurgeProtection = $true } }
      BackupFinding = @([pscustomobject]@{ Id = 'profile-backup'; Check = 'Profile share backup'; Status = 'Pass'; Detail = 'ok'; Remediation = '' })
      Identity = @{ UsersGroupId = 'g1'; AdminsGroupId = 'g2' }; HostImage = @([pscustomobject]@{ publisher = 'MicrosoftWindowsDesktop'; offer = 'office-365'; sku = 'win11-24h2-avd-m365' }) }
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
    $r = Get-AvdRecoveryVerdict @p
    $m = @{}; foreach ($x in $r) { $m[$x.Id] = $x }; $m
  }
}

Describe 'Tiers and the deployed commit' {
  It 'gives each tier its RPO, RTO and test interval' {
    (Get-AvdRecoveryTarget R0).RpoHours | Should -Be 24
    (Get-AvdRecoveryTarget R2).RtoHours | Should -Be 1
    (Get-AvdRecoveryTarget R1).TestIntervalDays | Should -Be 90
  }
  It 'reads the commit deploy.sh pinned the runbook to, and treats master as not on the remote' {
    $c = Get-AvdDeployedCommit "https://raw.githubusercontent.com/contoso/avd-landing-zone/$($script:sha)/scripts/automation/Invoke-AvdPowerAction.ps1"
    $c.Commit | Should -Be $script:sha; $c.OnRemote | Should -BeTrue; $c.Repository | Should -Be 'contoso/avd-landing-zone'
    (Get-AvdDeployedCommit 'https://raw.githubusercontent.com/contoso/avd-landing-zone/master/scripts/x.ps1').OnRemote | Should -BeFalse
    (Get-AvdDeployedCommit $null).Commit | Should -BeNullOrEmpty
  }
}

Describe 'Recovery runs from run records' {
  It 'keeps only recovery runs, newest first, and counts real copies' {
    $other = @{ runId = 'run-20261020-0000-zzzz'; useCase = 'landing-zone'; started = '2026-10-20T11:00:00Z'; files = @() }
    $runs = Get-AvdRecoveryRun -Record @((New-Run snapshot 10), (New-Run snapshot 2 -Copied), $other)
    $runs.Count | Should -Be 2
    $runs[0].Verified | Should -BeTrue
    $runs[1].Verified | Should -BeFalse
  }
  It 'does not count a copy entry without a hash (an ARM-style null is not a copy)' {
    $r = New-Run snapshot 1; $r.files[0].copies = @($null)
    (Get-AvdRecoveryRun -Record @($r))[0].Verified | Should -BeFalse
  }
}

Describe 'The verdict' {
  It 'fails what is missing and never passes an item it could not read' {
    $v = Get-Verdict @{ BackupEnabled = $false; KeyVault = $null }
    $v['dr-iac'].Status | Should -Be 'Fail'
    $v['dr-config'].Status | Should -Be 'Fail'
    $v['dr-profile-backup'].Status | Should -Be 'Fail'
    $v['dr-keyvault'].Status | Should -Be 'Fail'
    $v['dr-tested'].Status | Should -Be 'Fail'
  }
  It 'asks for a copy when the newest snapshot has none' {
    $v = Get-Verdict @{ Runs = Get-AvdRecoveryRun -Record @((New-Run snapshot 2)) }
    $v['dr-config'].Status | Should -Be 'Fail'
    $v['dr-config'].Remediation | Should -Match 'CopyTo github'
  }
  It 'passes a copied snapshot within the RPO and fails one older than it' {
    (Get-Verdict @{ Runs = Get-AvdRecoveryRun -Record @((New-Run snapshot 5 -Copied)) })['dr-config'].Status | Should -Be 'Pass'
    (Get-Verdict @{ Runs = Get-AvdRecoveryRun -Record @((New-Run snapshot 30 -Copied)) })['dr-config'].Status | Should -Be 'Fail'
  }
  It 'maps the post-deployment check''s backup findings instead of judging the backup itself' {
    $f = @([pscustomobject]@{ Id = 'profile-backup'; Check = 'Profile share backup'; Status = 'Warn'; Detail = 'last backup Failed'; Remediation = 'Open the jobs' },
      [pscustomobject]@{ Id = 'profile-backup-access'; Check = 'Azure Backup can reach the profile storage account'; Status = 'Pass'; Detail = ''; Remediation = '' })
    $v = Get-Verdict @{ BackupFinding = $f }
    $v['dr-profile-backup'].Status | Should -Be 'Warn'
    $v['dr-profile-backup-access'].Status | Should -Be 'Pass'
  }
  It 'needs the vaulted tier, geo-redundancy and Cross Region Restore for R1' {
    $vault = [pscustomobject]@{ properties = [pscustomobject]@{ redundancySettings = [pscustomobject]@{ standardTierStorageRedundancy = 'GeoRedundant'; crossRegionRestore = 'Enabled' } } }
    $snapOnly = [pscustomobject]@{ properties = [pscustomobject]@{ retentionPolicy = @{} } }
    $vaulted = [pscustomobject]@{ properties = [pscustomobject]@{ vaultRetentionPolicy = @{ snapshotRetentionInDays = 7 } } }
    (Get-Verdict @{ Tier = 'R1'; Vault = $vault; ProtectedPolicy = $snapOnly })['dr-profile-offsite'].Status | Should -Be 'Fail'
    (Get-Verdict @{ Tier = 'R1'; Vault = $vault; ProtectedPolicy = $vaulted })['dr-profile-offsite'].Status | Should -Be 'Pass'
    (Get-Verdict @{ Tier = 'R0'; Vault = $vault; ProtectedPolicy = $snapOnly })['dr-profile-offsite'].Status | Should -Be 'Skip'
  }
  It 'needs a gallery replica in the recovery region for R1, and a missing region is a failure' {
    $img = @([pscustomobject]@{ id = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/images/i/versions/1.0.0' })
    $ver = @([pscustomobject]@{ name = '1.0.0'; properties = [pscustomobject]@{ publishingProfile = [pscustomobject]@{ targetRegions = @([pscustomobject]@{ name = 'North Central US' }) } } })
    (Get-Verdict @{ Tier = 'R1'; HostImage = $img; ImageVersion = $ver; RecoveryLocation = 'southcentralus' })['dr-image'].Status | Should -Be 'Fail'
    $ver[0].properties.publishingProfile.targetRegions += [pscustomobject]@{ name = 'South Central US' }
    (Get-Verdict @{ Tier = 'R1'; HostImage = $img; ImageVersion = $ver; RecoveryLocation = 'southcentralus' })['dr-image'].Status | Should -Be 'Pass'
    (Get-Verdict @{ Tier = 'R1'; HostImage = $img; ImageVersion = $ver })['dr-image'].Status | Should -Be 'Fail'
  }
  It 'always warns about capacity from R1, because quota is not capacity' { (Get-Verdict @{ Tier = 'R1' })['dr-capacity'].Status | Should -Be 'Warn' }
  It 'fails R2 because the standby is not built here' { (Get-Verdict @{ Tier = 'R2' })['dr-standby'].Status | Should -Be 'Fail' }
  It 'counts only a passed test of the same or a higher tier within 90 days' {
    (Get-Verdict @{ Runs = Get-AvdRecoveryRun -Record @((New-Run test 24 -Outcome passed)) })['dr-tested'].Status | Should -Be 'Pass'
    (Get-Verdict @{ Runs = Get-AvdRecoveryRun -Record @((New-Run test 24 -Outcome failed)) })['dr-tested'].Status | Should -Be 'Fail'
    (Get-Verdict @{ Tier = 'R1'; Runs = Get-AvdRecoveryRun -Record @((New-Run test 24 -Outcome passed)) })['dr-tested'].Status | Should -Be 'Fail'
    (Get-Verdict @{ Runs = Get-AvdRecoveryRun -Record @((New-Run test (24 * 100) -Outcome passed)) })['dr-tested'].Status | Should -Be 'Fail'
  }
  It 'sums Pass against everything that applies, Skip left out' {
    $s = Get-AvdRecoverySummary -Result @([pscustomobject]@{ Status = 'Pass' }, [pscustomobject]@{ Status = 'Skip' }, [pscustomobject]@{ Status = 'Warn' })
    $s.Met | Should -Be 1; $s.Total | Should -Be 2; $s.Status | Should -Be 'notmet'
  }
}

Describe 'The configuration snapshot' {
  It 'records secrets as present, never their value, and leaves out what changes on its own' {
    $s = Get-AvdConfigurationSnapshot ([pscustomobject]@{ name = 'hp'; etag = 'x'; properties = [pscustomobject]@{ registrationInfo = @{ token = 'abc' }; maxSessionLimit = 4; adminPassword = 'p'; lastHeartBeat = 'now' } })
    $j = $s | ConvertTo-Json -Depth 5 -Compress
    $j | Should -Not -Match 'abc|"p"|etag|lastHeartBeat'
    $s.properties.registrationInfo | Should -Be '<present>'
    $s.properties.adminPassword | Should -Be '<present>'
    $s.properties.maxSessionLimit | Should -Be 4
  }
  It 'keeps lists as lists' { $l = Get-AvdConfigurationSnapshot @(1, 2); $l.Count | Should -Be 2 }
  It 'reports drift by resource id, case-insensitively, as changed, added and removed' {
    $a = @{ value = @(@{ id = '/A'; p = 1 }, @{ id = '/B'; p = 1 }) }
    $b = @{ value = @(@{ id = '/a'; p = 2 }, @{ id = '/C'; p = 1 }) }
    $d = @(Get-AvdConfigurationDrift -Reference $a -Current $b)
    ($d | ForEach-Object { "$($_.Change) $($_.Path)" }) | Should -Be @('changed value[/a].p', 'removed value[/b]', 'added value[/c]')
  }
  It 'finds no drift between equal snapshots' { @(Get-AvdConfigurationDrift -Reference @{ x = @(1, 2) } -Current @{ x = @(1, 2) }).Count | Should -Be 0 }
}

Describe 'Copies read back' {
  It 'tells ok, mismatch, missing and no copy apart' {
    $c = @{ target = 'github'; verifiedAt = '2026-10-20T00:00:00Z'; sha256 = ('c' * 64) }
    $files = @(@{ path = 'a'; copies = @($c) }, @{ path = 'b'; copies = @($c) }, @{ path = 'c'; copies = @($c) }, @{ path = 'd' }, @{ path = 'e'; keptOnlyIn = 'azure' })
    $r = Get-AvdCopyCheck -File $files -Held @{ a = ('c' * 64); b = ('d' * 64) }
    ($r | ForEach-Object Status) | Should -Be @('ok', 'mismatch', 'missing', 'nocopy', 'nocopy')
    $r[4].Detail | Should -Match 'azure'
  }
}

Describe 'Recovery test plan and restore request' {
  It 'restores into new names in the vault''s region and subscription, and prices only what it can match' {
    $p = Get-AvdRecoveryTestPlan -NamePrefix avdlz -Environment dev -RunId 'run-20261020-1900-ab12' -VaultLocation northcentralus -SourceSubscriptionId 's1' -TargetSubscriptionId 's2' -ShareGiB 100 -Hours 2 -Price @{ premiumFilesGiBMonth = 0.2 }
    $p.ResourceGroup | Should -Be 'rg-avdlz-dev-rtest-ab12'
    $p.StorageAccount | Should -Match '^[a-z0-9]{3,24}$'
    $p.SubscriptionId | Should -Be 's1'
    $p.CrossSubscription | Should -BeTrue
    $p.Total | Should -Be 0.05
    (Get-AvdRecoveryTestPlan -NamePrefix avdlz -Environment dev -RunId 'run-20261020-1900-ab12' -VaultLocation northcentralus -SourceSubscriptionId 's1').Unpriced | Should -Be 1
  }
  It 'builds an alternate-location restore and refuses one over the source' {
    $b = Get-AvdRecoveryRestoreRequest -SourceStorageAccountId '/s/sa1' -TargetStorageAccountId '/s/sa2' -TargetShare 'profiles-restored'
    $b.properties.recoveryType | Should -Be 'AlternateLocation'
    $b.properties.copyOptions | Should -Be 'FailOnConflict'
    { Get-AvdRecoveryRestoreRequest -SourceStorageAccountId '/s/SA1' -TargetStorageAccountId '/s/sa1/' -TargetShare 'x' } | Should -Throw '*never over the source*'
  }
}
