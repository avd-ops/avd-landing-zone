# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: turns Storage Sense off (build/specs/image-pipeline-spec.md section 5.3).
.DESCRIPTION
  Storage Sense can delete files inside FSLogix profiles; Microsoft's AVD guidance turns it off.
  Runs on the image build VM, in Windows PowerShell 5.1, as an inline Azure Image Builder customizer.
#>
$ErrorActionPreference = 'Stop'
$key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
New-ItemProperty -Path $key -Name AllowStorageSenseGlobal -PropertyType DWord -Value 0 -Force | Out-Null
Write-Output 'Storage Sense: off (AllowStorageSenseGlobal = 0).'
