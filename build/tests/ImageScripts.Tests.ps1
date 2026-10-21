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

Describe 'WDOT run verification' {
  # WDOT returns without an error when it skips work, so a run passes only on what it left behind
  # (lesson 0031). Fixtures omit properties the way the registry and Get-WinEvent do.
  BeforeAll {
    function New-WdotEvent([int] $Id, [string] $Message, [int] $Level = 4) { [pscustomobject]@{ Id = $Id; Level = $Level; Message = $Message } }
    $script:goodLog = @(
      New-WdotEvent 1 "Starting WDOT by user 'SYSTEM', for WDOT build 'avdlz', with the following options:"
      New-WdotEvent 1 'EULA Accepted by Parameter'
      New-WdotEvent 30 '[Windows Optimize] Disable Scheduled Tasks'
      New-WdotEvent 40 'Set Default User Settings'
      New-WdotEvent 50 'Disable AutoLoggers'
      New-WdotEvent 60 'Disable Services'
      New-WdotEvent 130 'Unable to find Scheduled Task: XblGameSaveTask' 2
      New-WdotEvent 1 'WDOT Total Run Time: 0 Hours 2 Minutes 10 Seconds'
    )
    $script:goodStamp = [pscustomobject]@{ Version = $lock.toolVersion; LastRunTime = '10/21/2026 4:20:00 PM' }
    $script:applied = @('autotimesvc', 'MapsBroker')
    $script:disabled = @([pscustomobject]@{ Name = 'autotimesvc'; StartType = 'Disabled' }, [pscustomobject]@{ Name = 'MapsBroker'; StartType = 'Disabled' })
    function Get-Problem {
      param($Stamp = $goodStamp, $LogEntry = $goodLog, $Service = $disabled, [string[]] $Reported = @())
      Get-AvdWdotRunProblem -Lock $lock -Stamp $Stamp -LogEntry $LogEntry -Service $Service -AppliedService $applied -Reported $Reported
    }
  }

  It 'passes a run that stamped, logged every category and disabled the services (item errors are reported, not fatal)' {
    Get-Problem | Should -BeNullOrEmpty
  }
  It 'fails when WDOT never stamped HKLM:\SOFTWARE\WDOT' {
    Get-Problem -Stamp $null | Should -Match 'never started'
    Get-Problem -Stamp ([pscustomobject]@{ Version = $lock.toolVersion }) | Should -Match 'never started'
  }
  It 'fails when the stamp is from another WDOT version' {
    Get-Problem -Stamp ([pscustomobject]@{ Version = '1.0.0.0'; LastRunTime = 'x' }) | Should -Match 'version 1.0.0.0'
    Get-Problem -Stamp ([pscustomobject]@{ LastRunTime = 'x' }) | Should -Match 'version none'
  }
  It 'fails when the event log is empty (v1.1 on Windows PowerShell 5.1 never creates it)' {
    Get-Problem -LogEntry @() | Should -Match 'no entries from this run'
  }
  It 'fails when WDOT stopped early, even though it returned normally' {
    $log = @(New-WdotEvent 1 'Starting WDOT by user' ; New-WdotEvent 100 "Invalid configuration path:`n C:\x" 2)
    $p = Get-Problem -LogEntry $log
    ($p -join "`n") | Should -Match 'stopped early \(event 100\): Invalid configuration path: C:\\x'
    ($p -join "`n") | Should -Match "didn't finish"
    @($p | Where-Object { $_ -match '^WDOT skipped' }).Count | Should -Be $lock.optimizations.Count
  }
  It 'fails when a category was skipped because its file was missing' {
    $log = @($goodLog | Where-Object { $_.Id -ne 60 }) + (New-WdotEvent 160 'File not found: .\Services.json' 2)
    Get-Problem -LogEntry $log | Should -Be "WDOT skipped Services: no event 60, usually because its profile file wasn't found."
  }
  It 'counts only Information entries as evidence, and an entry without a level as none' {
    $log = @($goodLog | Where-Object { $_.Id -ne 40 }) + (New-WdotEvent 40 'File not found: .\DefaultUserSettings.json' 3) + [pscustomobject]@{ Id = 40; Message = 'Set Default User Settings' }
    Get-Problem -LogEntry $log | Should -Match 'skipped DefaultUserSettings'
  }
  It 'fails when a service the profile disables is still enabled and WDOT said nothing' {
    $svc = @([pscustomobject]@{ Name = 'autotimesvc'; StartType = 'Manual' }, $disabled[1])
    Get-Problem -Service $svc | Should -Be 'Service autotimesvc is still Manual and WDOT reported nothing about it.'
  }
  It 'accepts a service WDOT reported it could not change, and ignores services the machine lacks' {
    $svc = @([pscustomobject]@{ Name = 'autotimesvc'; StartType = 'Manual' })
    Get-Problem -Service $svc -Reported 'Failed to change startup type of autotimesvc because Access is denied' | Should -BeNullOrEmpty
    Get-Problem -Service $svc -Reported 'Failed to change startup type of autotimesvcX' | Should -Match 'autotimesvc is still Manual'
  }
  It 'keeps every problem on one line, so the RESULT line stays whole' {
    $log = @(New-WdotEvent 101 "Script execution failed:`r`n ConfigProfile missing" 2)
    foreach ($p in (Get-Problem -LogEntry $log)) { $p | Should -Not -Match "[`r`n]" }
  }
  It 'names an event for every category the lock runs, and the sources WDOT writes with' {
    foreach ($c in $lock.optimizations) { "$($lock.verify.categoryEvents.$c)" | Should -Match '^\d+$' -Because $c }
    foreach ($s in 'WDOT', 'Services', 'ScheduledTasks', 'DefaultUserSettings', 'Autologgers', 'AdvancedOptimizations') { $lock.verify.eventSources | Should -Contain $s }
    $lock.toolVersion | Should -Match '^\d+\.\d+\.\d+\.\d+$'
  }
  It 'records success only after the verification' {
    $text = Get-Content (Join-Path $root 'scripts/image/Invoke-Wdot.ps1') -Raw
    $text | Should -Not -Match "WdotResult\s*=\s*'Succeeded'"
    $check = $text.IndexOf('$problems = Get-AvdWdotRunProblem')
    $marker = $text.IndexOf('Set-AvdImageMarker -Value')
    $check | Should -BeGreaterThan 0
    $marker | Should -BeGreaterThan $check
    $text | Should -Match 'Initialize-AvdWdotEventLog -Source'
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
