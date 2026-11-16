# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: the adopter's own step, run after WDOT and before cleanup (build/specs/image-pipeline-spec.md section 5.3).
.DESCRIPTION
  Install your applications and apply your settings here. Keep it generic: nothing tenant- or
  landing-zone-specific, no secrets (spec section 1). Windows PowerShell 5.1, runs as SYSTEM on
  the build VM. Throw to fail the build. Empty in this repository.

  To install evergreen core apps (e.g., EUCPilots Evergreen and VcRedist, MIT-licensed):
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module -Name Evergreen, VcRedist -Scope AllUsers -Force -AllowClobber
    Import-Module Evergreen, VcRedist -ErrorAction Stop
    # Example: $webrtc = Get-EvergreenApp -Name MicrosoftRdcwebrtcredirdor | Where-Object { $_.Architecture -eq 'x64' } | Select-Object -First 1
    # Example: Get-VcList -Release 2022 -Architecture x64 | Save-VcRedist -Path "$env:TEMP\vc" | Install-VcRedist -Silent
#>
$ErrorActionPreference = 'Stop'
Write-Output 'Custom image step: nothing to do (scripts/image/custom/Invoke-CustomImageStep.ps1 is empty).'
