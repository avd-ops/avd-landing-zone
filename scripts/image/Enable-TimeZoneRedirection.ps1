# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: sessions use the client's time zone (build/specs/image-pipeline-spec.md section 5.3).
.DESCRIPTION
  Runs on the image build VM, in Windows PowerShell 5.1, as an inline Azure Image Builder customizer.
#>
$ErrorActionPreference = 'Stop'
$key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
New-ItemProperty -Path $key -Name fEnableTimeZoneRedirection -PropertyType DWord -Value 1 -Force | Out-Null
Write-Output 'Time zone redirection: on.'
