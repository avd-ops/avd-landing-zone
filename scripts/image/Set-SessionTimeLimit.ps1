# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: disconnected sessions end after a set time (build/specs/image-pipeline-spec.md section 5.7).
.DESCRIPTION
  A forgotten disconnected session can't hold a host rotation open indefinitely.
  Runs on the image build VM, in Windows PowerShell 5.1. build.bicep appends the call with the hours.
#>
function Set-AvdSessionTimeLimit {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][ValidateRange(1, 168)][int] $DisconnectedHours)
  $ErrorActionPreference = 'Stop'
  $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
  if (-not $PSCmdlet.ShouldProcess($key, "End disconnected sessions after $DisconnectedHours hours")) { return }
  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  New-ItemProperty -Path $key -Name MaxDisconnectionTime -PropertyType DWord -Value ($DisconnectedHours * 3600000) -Force | Out-Null
  Write-Output "Disconnected sessions end after $DisconnectedHours hours (MaxDisconnectionTime)."
}
