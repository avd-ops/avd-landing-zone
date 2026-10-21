#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Guards for the golden image scripts and the WDOT profile (build/specs/image-pipeline-spec.md section 5,
# scripts/image/wdot/README.md). Runs on any OS: nothing here touches Windows.

BeforeAll {
  $script:root = Resolve-Path (Join-Path $PSScriptRoot '../..')
  . (Join-Path $root 'scripts/image/Invoke-Wdot.ps1')
  Import-Module (Join-Path $root 'scripts/ops/AvdLandingZone.psm1') -Force
  $script:lock = Get-Content (Join-Path $root 'scripts/image/wdot/wdot.lock.json') -Raw | ConvertFrom-Json
  $script:profileDir = Join-Path $root 'scripts/image/wdot/profile'
  $script:protected = (Get-Content (Join-Path $root 'scripts/image/protected-services.json') -Raw | ConvertFrom-Json).services
  function Read-WdotProfile([string] $Name) { Get-Content (Join-Path $script:profileDir $Name) -Raw | ConvertFrom-Json }
}

Describe 'Every script parses' {
  # The analyzer reports a parse error under its own severity, which a Severity filter can hide;
  # two image scripts once shipped unparseable ("$path:" reads as a drive-qualified variable).
  It 'has no parse errors in <file>' -ForEach @(
    Get-ChildItem (Join-Path $PSScriptRoot '../../scripts') -Recurse -Include '*.ps1', '*.psm1' -File |
      ForEach-Object { @{ file = [IO.Path]::GetRelativePath((Join-Path $PSScriptRoot '../..'), $_.FullName).Replace('\', '/') } }
  ) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$null, [ref]$errors)
    @($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) | Should -BeNullOrEmpty
  }
}

Describe 'WDOT lock' {
  It 'records the hash of the profile as it is' {
    $actual = Get-AvdWdotProfileHash -Path $profileDir
    $actual | Should -Be $lock.profileSha256 -Because "an intended profile change updates profileSha256 in scripts/image/wdot/wdot.lock.json to $actual"
  }
  It 'pins a commit, and the SHA-256 of the main script and of function files' {
    $lock.commit | Should -Match '^[0-9a-f]{40}$'
    $lock.archiveUrl | Should -Match "/archive/$($lock.commit)\.zip$"
    $names = @($lock.files.PSObject.Properties.Name)
    $names | Should -Contain 'Windows_Optimization.ps1'
    @($names | Where-Object { $_ -like 'Functions/*' }).Count | Should -BeGreaterThan 0
    foreach ($n in $names) { $lock.files.$n | Should -Match '^[0-9a-f]{64}$' -Because $n }
  }
  It 'never runs DiskCleanup (it deletes the build''s evidence) or All' {
    $lock.optimizations | Should -Not -Contain 'DiskCleanup'
    $lock.optimizations | Should -Not -Contain 'All'
  }
}

Describe 'WDOT profile' {
  It 'never applies to a service the landing zone depends on' {
    $applied = @(Read-WdotProfile 'Services.json' | Where-Object OptimizationState -eq 'Apply' | ForEach-Object Name)
    @($applied | Where-Object { $_ -in $protected }) | Should -BeNullOrEmpty
  }
  It 'keeps the default-user settings that conflict with the landing zone Skip' {
    $du = Read-WdotProfile 'DefaultUserSettings.json'
    foreach ($k in 'UpdatesSuppressedDurationMin', 'UpdatesSuppressedStartHour', 'UpdatesSuppressedStartMin', 'NoToastApplicationNotification', 'NoToastApplicationNotificationOnLockScreen', 'TaskbarNoNotification') {
      @($du | Where-Object { $_.KeyName -eq $k -and $_.OptimizationState -eq 'Apply' }) | Should -BeNullOrEmpty -Because $k
    }
  }
  It 'keeps the Mellanox autologger (accelerated networking adapters)' {
    @(Read-WdotProfile 'Autologgers.Json' | Where-Object { $_.KeyName -match 'Mellanox' -and $_.OptimizationState -eq 'Apply' }) | Should -BeNullOrEmpty
  }
  It 'applies nothing in a category the lock doesn''t run' {
    $files = @{ 'AppxPackages.json' = 'AppxPackages'; 'PolicyRegSettings.json' = 'LocalPolicy'; 'EdgeSettings.json' = 'Edge' }
    foreach ($f in $files.Keys) {
      if ($lock.optimizations -contains $files[$f]) { continue }
      @(Read-WdotProfile $f | Where-Object OptimizationState -eq 'Apply') | Should -BeNullOrEmpty -Because "$($files[$f]) isn't run"
    }
    if ($lock.optimizations -notcontains 'NetworkOptimizations') {
      @((Read-WdotProfile 'LanManWorkstation.json').Keys | Where-Object OptimizationState -eq 'Apply') | Should -BeNullOrEmpty
    }
  }
}

Describe 'Image version names' {
  # Spec section 4.2, red-team M1: three integers, no zero padding, compared as numbers.
  It 'names builds YYYY.MDD.N and counts the day''s builds' {
    Get-AvdImageVersionName -Date ([datetime]'2027-01-04') | Should -Be '2027.104.1'
    Get-AvdImageVersionName -Date ([datetime]'2026-10-04') -Existing '2026.1004.1', '2026.1004.3', '2026.1003.9' | Should -Be '2026.1004.4'
  }
  It 'picks the newest version as a number, not as text' {
    Get-AvdLatestVersion -Version '26100.6725.251007', '26100.10000.251104' | Should -Be '26100.10000.251104'
    Get-AvdLatestVersion -Version '2026.1004.1', '2027.104.1' | Should -Be '2027.104.1'
    Get-AvdLatestVersion -Version @() | Should -BeNullOrEmpty
  }
}
