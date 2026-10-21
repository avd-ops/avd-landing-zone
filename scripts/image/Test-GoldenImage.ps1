# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: build-time validation (build/specs/image-pipeline-spec.md section 5.4).
.DESCRIPTION
  Runs as Azure Image Builder's validate step, on the customized build VM, before AIB
  generalizes it: sysprep's own result comes from the AIB run status, and the QA host is the
  first evidence from a generalized image (spec section 5.4, red-team M5).
  Prints one "RESULT <check> <Pass|Fail> <detail>" line per check; any Fail stops distribution.
  Windows PowerShell 5.1. build.bicep inlines this file and appends the call with the expected values.
#>

function Write-AvdImageCheck {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][bool] $Pass, [string] $Detail = '')
  $state = if ($Pass) { 'Pass' } else { 'Fail' }
  Write-Output "RESULT $Name $state $Detail"
  if (-not $Pass) { $script:AvdImageFailures++ }
}

function Get-AvdRegistryValue {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Key, [Parameter(Mandatory)][string] $Name)
  $item = Get-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue
  if ($item) { $item.$Name }
}

function Test-AvdGoldenImage {
  # Sets $script:AvdImageFailures; the appended call exits 1 when it isn't 0.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $ExpectedRelease,
    [Parameter(Mandatory)][int] $MinimumUbr,
    [Parameter(Mandatory)][version] $MinimumFslogixVersion,
    [Parameter(Mandatory)][string] $WdotCommit,
    [Parameter(Mandatory)][string] $WdotProfileSha256,
    [Parameter(Mandatory)][int] $DisconnectedHours,
    [Parameter(Mandatory)][string[]] $ProtectedService,
    [switch] $AllowAgent
  )
  $script:AvdImageFailures = 0
  $nt = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'

  # Release and patch level: at least the source image's build, plus what Windows Update added.
  $release = Get-AvdRegistryValue $nt 'DisplayVersion'
  $ubr = [int](Get-AvdRegistryValue $nt 'UBR')
  Write-AvdImageCheck 'os-release' ($release -eq $ExpectedRelease) "DisplayVersion=$release expected=$ExpectedRelease build=$(Get-AvdRegistryValue $nt 'CurrentBuild').$ubr"
  Write-AvdImageCheck 'os-patch-level' ($ubr -ge $MinimumUbr) "UBR=$ubr minimum=$MinimumUbr (the source image's)"

  # FSLogix ships in the marketplace image; Configure-FSLogix configures it per landing zone.
  $frx = Join-Path $env:ProgramFiles 'FSLogix\Apps\frx.exe'
  $frxVersion = if (Test-Path $frx) { [version](Get-Item $frx).VersionInfo.ProductVersion } else { $null }
  Write-AvdImageCheck 'fslogix' ($null -ne $frxVersion -and $frxVersion -ge $MinimumFslogixVersion) "version=$frxVersion minimum=$MinimumFslogixVersion"

  $sca = Get-AvdRegistryValue 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'SharedComputerLicensing'
  Write-AvdImageCheck 'm365-shared-activation' ($sca -eq '1') "SharedComputerLicensing=$sca"

  $storageSense = Get-AvdRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' 'AllowStorageSenseGlobal'
  Write-AvdImageCheck 'storage-sense-off' ($storageSense -eq 0) "AllowStorageSenseGlobal=$storageSense"
  $tz = Get-AvdRegistryValue $ts 'fEnableTimeZoneRedirection'
  Write-AvdImageCheck 'time-zone-redirection' ($tz -eq 1) "fEnableTimeZoneRedirection=$tz"
  $limit = Get-AvdRegistryValue $ts 'MaxDisconnectionTime'
  Write-AvdImageCheck 'disconnected-session-limit' ($limit -eq ($DisconnectedHours * 3600000)) "MaxDisconnectionTime=$limit expected=$($DisconnectedHours * 3600000)"

  # Updates come through the image (spec section 5.6).
  $noAuto = Get-AvdRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate'
  $officeAuto = Get-AvdRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' 'enableautomaticupdates'
  Write-AvdImageCheck 'automatic-updates-off' ($noAuto -eq 1 -and $officeAuto -eq 0) "NoAutoUpdate=$noAuto enableautomaticupdates=$officeAuto"

  # The AVD agent is installed per landing zone by Register-AvdAgent (spec Q1).
  $agent = [bool](Get-Service -Name RDAgentBootLoader -ErrorAction SilentlyContinue) -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent')
  Write-AvdImageCheck 'no-avd-agent' ($AllowAgent -or -not $agent) "agentPresent=$agent allowed=$([bool]$AllowAgent)"

  # Patching finished: no reboot pending, no update failed in the last 12 hours.
  $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
  Write-AvdImageCheck 'no-reboot-pending' (-not $pending) "pending=$pending"
  try {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $count = $searcher.GetTotalHistoryCount()
    $since = (Get-Date).ToUniversalTime().AddHours(-12)
    # ResultCode 4 = failed, 5 = aborted.
    $failed = @($searcher.QueryHistory(0, [Math]::Min($count, 200)) | Where-Object { $_.Date -ge $since -and ($_.ResultCode -eq 4 -or $_.ResultCode -eq 5) } | ForEach-Object { $_.Title })
    Write-AvdImageCheck 'no-failed-updates' ($failed.Count -eq 0) "failed=$($failed.Count) $($failed -join '; ')"
  }
  catch { Write-AvdImageCheck 'no-failed-updates' $false "Windows Update history unreadable: $($_.Exception.Message)" }

  # Only built-in accounts and the build's own account (Azure Image Builder's) are enabled.
  $builtIn = @('Administrator', 'DefaultAccount', 'Guest', 'WDAGUtilityAccount', $env:USERNAME)
  $extra = @(Get-LocalUser | Where-Object { $_.Enabled -and $builtIn -notcontains $_.Name } | ForEach-Object { $_.Name })
  Write-AvdImageCheck 'no-extra-local-accounts' ($extra.Count -eq 0) "extra=$($extra -join ',') buildAccount=$env:USERNAME"

  $mp = Get-MpComputerStatus
  Write-AvdImageCheck 'defender' ($mp.AntivirusEnabled -and $mp.AntivirusSignatureAge -le 1) "enabled=$($mp.AntivirusEnabled) signatureAge=$($mp.AntivirusSignatureAge) platform=$($mp.AMProductVersion)"

  # WDOT ran, as pinned, with the reviewed profile, and left the protected services alone.
  $marker = 'HKLM:\SOFTWARE\avdlz\Image'
  $wdotCommit = Get-AvdRegistryValue $marker 'WdotCommit'
  $wdotProfile = Get-AvdRegistryValue $marker 'WdotProfileSha256'
  $wdotResult = Get-AvdRegistryValue $marker 'WdotResult'
  Write-AvdImageCheck 'wdot' ($wdotResult -eq 'Succeeded' -and $wdotCommit -eq $WdotCommit -and $wdotProfile -eq $WdotProfileSha256) "result=$wdotResult commit=$wdotCommit profile=$wdotProfile warnings=$(Get-AvdRegistryValue $marker 'WdotWarnings') itemErrors=$(Get-AvdRegistryValue $marker 'WdotItemErrors') problems=$(Get-AvdRegistryValue $marker 'WdotProblems')"
  $disabled = @(); $absent = @()
  foreach ($name in $ProtectedService) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { $absent += $name }
    elseif ($svc.StartType -eq 'Disabled') { $disabled += $name }
  }
  Write-AvdImageCheck 'protected-services' ($disabled.Count -eq 0) "disabled=$($disabled -join ',') absent=$($absent -join ',') checked=$($ProtectedService.Count)"

  Write-Output "Golden image validation: $script:AvdImageFailures failure(s)."
}
