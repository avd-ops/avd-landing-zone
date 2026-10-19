# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: Windows and Microsoft 365 Apps don't update themselves on hosts (build/specs/image-pipeline-spec.md section 5.6).
.DESCRIPTION
  The image is the single source of patches; hosts are replaced monthly. The Windows Update
  service stays available: Defender signatures and Intune use it. Intune update rings that
  target these devices override this policy (spec section 5.6).
  Runs on the image build VM, in Windows PowerShell 5.1, as an inline Azure Image Builder customizer.
#>
$ErrorActionPreference = 'Stop'
foreach ($p in @(
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; Value = 1 },
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; Name = 'enableautomaticupdates'; Value = 0 })) {
  if (-not (Test-Path $p.Key)) { New-Item -Path $p.Key -Force | Out-Null }
  New-ItemProperty -Path $p.Key -Name $p.Name -PropertyType DWord -Value $p.Value -Force | Out-Null
  Write-Output "$($p.Key)\$($p.Name) = $($p.Value)"
}
Write-Output 'Automatic updates: off for Windows and Microsoft 365 Apps.'
