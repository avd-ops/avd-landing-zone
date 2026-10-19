# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: the adopter's own step, run after WDOT and before cleanup (build/specs/image-pipeline-spec.md section 5.3).
.DESCRIPTION
  Install your applications and apply your settings here. Keep it generic: nothing tenant- or
  landing-zone-specific, no secrets (spec section 1). Windows PowerShell 5.1, runs as SYSTEM on
  the build VM. Throw to fail the build. Empty in this repository.
#>
$ErrorActionPreference = 'Stop'
Write-Output 'Custom image step: nothing to do (scripts/image/custom/Invoke-CustomImageStep.ps1 is empty).'
