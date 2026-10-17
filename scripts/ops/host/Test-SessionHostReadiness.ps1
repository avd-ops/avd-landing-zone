<#
.SYNOPSIS
  Checks, from inside a session host, everything a user sign-in depends on.

.DESCRIPTION
  Runs ON a session host through Run Command (Windows PowerShell 5.1), called by
  Deploy-AvdDemo.ps1. Reports Entra join, Intune enrollment, AVD agent
  registration, FSLogix and Entra Kerberos configuration, and private DNS and
  SMB reachability of the profile share.

  Output is one JSON object between <<<AVDJSON and AVDJSON>>> markers.
#>
param(
  [Parameter(Mandatory)] [string] $StorageFqdn,
  [Parameter(Mandatory)] [string] $ProfileShareUnc
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Get-RegValue([string] $Path, [string] $Name) {
  $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
  if ($item) { return $item.$Name }
  return $null
}

function Test-ServiceRunning([string] $Name) {
  $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
  return [bool]($svc -and $svc.Status -eq 'Running')
}

$r = [ordered]@{}

# Identity and management
$dsreg = (dsregcmd /status) | Out-String
$r.entraJoined = $dsreg -match 'AzureAdJoined\s*:\s*YES'
$enrollments = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
  Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object { $_.ProviderID -eq 'MS DM Server' }
$r.intuneEnrolled = [bool]$enrollments

# AVD agent
$r.agentRegistered = (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' 'IsRegistered') -eq 1
$r.bootLoaderRunning = Test-ServiceRunning 'RDAgentBootLoader'

# FSLogix + Entra Kerberos
$r.fslogixServiceRunning = Test-ServiceRunning 'frxsvc'
$r.fslogixEnabled = (Get-RegValue 'HKLM:\SOFTWARE\FSLogix\Profiles' 'Enabled') -eq 1
$locations = @(Get-RegValue 'HKLM:\SOFTWARE\FSLogix\Profiles' 'VHDLocations')
$r.fslogixPointsAtShare = [bool]($locations | Where-Object { $_ -eq $ProfileShareUnc })
$r.cloudKerberosEnabled = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' 'CloudKerberosTicketRetrievalEnabled') -eq 1
$r.loadCredKeyFromProfile = (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount' 'LoadCredKeyFromProfile') -eq 1
# Microsoft lists both as required for Entra Kerberos: WinHttpAutoProxySvc carries the KDC proxy requests.
$r.kerberosServicesStopped = @('WinHttpAutoProxySvc', 'iphlpsvc' | Where-Object { -not (Test-ServiceRunning $_) })

# Profile share reachability
$r.storageIp = $null
$r.storageIpPrivate = $false
try {
  $ip = [System.Net.Dns]::GetHostAddresses($StorageFqdn) |
    Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
  if ($ip) {
    $r.storageIp = $ip.ToString()
    $r.storageIpPrivate = $r.storageIp -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
  }
}
catch { $r.storageIp = "resolve failed: $($_.Exception.Message)" }

$r.smbReachable = $false
try {
  $client = New-Object System.Net.Sockets.TcpClient
  $connect = $client.BeginConnect($StorageFqdn, 445, $null, $null)
  $r.smbReachable = $connect.AsyncWaitHandle.WaitOne(5000) -and $client.Connected
  $client.Close()
}
catch { $r.smbReachable = $false }

$os = Get-CimInstance Win32_OperatingSystem
$r.os = "$($os.Caption) $($os.Version)"

Write-Output ('<<<AVDJSON' + ($r | ConvertTo-Json -Compress) + 'AVDJSON>>>')
