<#
.SYNOPSIS
  Reads, from inside a session host, the values the host security baseline profile checks.

.DESCRIPTION
  Runs ON a session host through Run Command (Windows PowerShell 5.1), called by
  Deploy-AvdDemo.ps1. Read-only: it reports raw values and judges nothing; the
  comparison with scripts/security/host-baseline.json is Get-AvdHostBaselineResult.
  A value that can't be read is left out (null), so it reports as unknown.

  Output is one JSON object between <<<AVDJSON and AVDJSON>>> markers.
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Get-RegValue([string] $Path, [string] $Name) {
  $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
  if ($item) { return $item.$Name }
  return $null
}

$r = [ordered]@{}
$readErrors = New-Object System.Collections.Generic.List[string]

# Virtualization-based security, Credential Guard (1) and memory integrity (2)
try {
  $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
  $r.vbsStatus = [int]$dg.VirtualizationBasedSecurityStatus
  $r.securityServicesRunning = @($dg.SecurityServicesRunning | ForEach-Object { [int]$_ })
  $r.codeIntegrityEnforcement = [int]$dg.CodeIntegrityPolicyEnforcementStatus
}
catch { $readErrors.Add("Win32_DeviceGuard: $($_.Exception.Message)") }

# Microsoft Defender Antivirus
try {
  $mp = Get-MpComputerStatus -ErrorAction Stop
  $r.defenderRealTime = [bool]$mp.RealTimeProtectionEnabled
  $r.defenderTamperProtected = [bool]$mp.IsTamperProtected
}
catch { $readErrors.Add("Get-MpComputerStatus: $($_.Exception.Message)") }

# LSA protection: RunAsPPL is left out when nothing set it, which reports as unknown, not as off.
$r.lsaRunAsPpl = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
try { $r.smb1Enabled = [bool](Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol }
catch { $readErrors.Add("Get-SmbServerConfiguration: $($_.Exception.Message)") }

# Session limits and screen lock: not set means not limited (0).
$ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$idle = Get-RegValue $ts 'MaxIdleTime'
$r.maxIdleTimeMs = if ($null -ne $idle) { [int64]$idle } else { 0 }
$lock = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'InactivityTimeoutSecs'
$r.inactivityTimeoutSecs = if ($null -ne $lock) { [int64]$lock } else { 0 }
$scp = Get-RegValue $ts 'fEnableScreenCaptureProtect'
$r.screenCaptureProtection = if ($null -ne $scp) { [int]$scp } else { 0 }

# Local Administrators (by its well-known SID, so a localized name works) beyond the built-in
# account (-500) and Entra SIDs (S-1-12-1-*). ADSI, because Get-LocalGroupMember fails on
# unresolvable Entra SIDs. Only a count leaves the host.
try {
  $name = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
  $group = [ADSI]"WinNT://./$name,group"
  $sids = @($group.psbase.Invoke('Members') | ForEach-Object {
      $bytes = $_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null)
      (New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value
    })
  $r.extraLocalAdmins = @($sids | Where-Object { $_ -notmatch '^S-1-5-21-.*-500$' -and $_ -notmatch '^S-1-12-1-' }).Count
}
catch { $readErrors.Add("Administrators group: $($_.Exception.Message)") }

$r.readErrors = @($readErrors)

Write-Output ('<<<AVDJSON' + ($r | ConvertTo-Json -Compress) + 'AVDJSON>>>')
