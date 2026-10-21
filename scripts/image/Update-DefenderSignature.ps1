# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: Defender starts with current signatures (build/specs/image-pipeline-spec.md section 5.3).
.DESCRIPTION
  Tries Microsoft Update, then the Malware Protection Center, three times each, and fails when the
  signatures are still more than a day old. Runs on the image build VM, in Windows PowerShell 5.1.
#>
$ErrorActionPreference = 'Stop'
$errors = @()
foreach ($source in 'MicrosoftUpdateServer', 'MMPC') {
  for ($i = 1; $i -le 3; $i++) {
    try { Update-MpSignature -UpdateSource $source; $errors = @(); break }
    catch { $errors += "$source attempt ${i}: $($_.Exception.Message)"; Start-Sleep -Seconds (15 * $i) }
  }
  if (-not $errors.Count) { break }
}
$status = Get-MpComputerStatus
Write-Output ("Defender: signatures {0}, age {1} day(s), engine {2}, platform {3}." -f $status.AntivirusSignatureVersion, $status.AntivirusSignatureAge, $status.AMEngineVersion, $status.AMProductVersion)
if ($status.AntivirusSignatureAge -gt 1) {
  throw "Defender signatures are $($status.AntivirusSignatureAge) days old after updating. Errors: $($errors -join ' | ')"
}
