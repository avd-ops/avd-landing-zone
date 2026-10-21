# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: a smaller image, cleaned narrowly (build/specs/image-pipeline-spec.md section 5.3).
.DESCRIPTION
  Component store cleanup, the Windows Update download cache, and the WDOT working folder.
  Logs and event logs stay: Test-GoldenImage.ps1 reads them (that's why WDOT's DiskCleanup
  category isn't run; see scripts/image/wdot/README.md).
  Runs on the image build VM, in Windows PowerShell 5.1, as an inline Azure Image Builder customizer.
#>
$ErrorActionPreference = 'Stop'
Write-Output 'Component store cleanup (DISM /StartComponentCleanup): this can take several minutes.'
$dism = Start-Process -FilePath "$env:SystemRoot\System32\Dism.exe" -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup' -Wait -PassThru -NoNewWindow
if ($dism.ExitCode -ne 0) { throw "DISM /StartComponentCleanup failed with exit code $($dism.ExitCode)." }
foreach ($path in "$env:SystemRoot\SoftwareDistribution\Download", "$env:ProgramData\avdlz\wdot") {
  if (Test-Path $path) {
    $before = @(Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue).Count
    Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $after = @(Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue).Count
    Write-Output "${path}: removed $($before - $after) of $before item(s); items in use are left."
  }
}
