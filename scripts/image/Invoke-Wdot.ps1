# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: runs the Windows Desktop Optimization Tool (WDOT) with the reviewed profile
  (build/specs/image-pipeline-spec.md section 5.5, scripts/image/wdot/README.md).
.DESCRIPTION
  Downloads WDOT at the commit pinned in wdot.lock.json and refuses to run when any file's
  SHA-256 differs from the lock, or when the archive holds a function file the lock doesn't
  list (WDOT dot-sources every Functions\*-WDOT*.ps1). Writes the profile, checks its hash
  against the lock, runs the categories the lock names, and records what ran under
  HKLM:\SOFTWARE\avdlz\Image for Test-GoldenImage.ps1.
  Runs on the image build VM, in Windows PowerShell 5.1, elevated. build.bicep inlines this file
  and appends the call, with the lock and the profile as base64.
#>

function Get-AvdWdotProfileHash {
  # SHA-256 over each *.json file in ordinal name order: "<name>`n" followed by the file's bytes.
  # The lock's profileSha256 is this value; build/tests/ImageScripts.Tests.ps1 recomputes it.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string] $Path)
  [string[]] $names = @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Name -like '*.json' } | ForEach-Object { $_.Name })
  [Array]::Sort($names, [StringComparer]::Ordinal)
  $stream = New-Object System.IO.MemoryStream
  foreach ($n in $names) {
    $head = [System.Text.Encoding]::UTF8.GetBytes("$n`n")
    $stream.Write($head, 0, $head.Length)
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Path $n))
    $stream.Write($bytes, 0, $bytes.Length)
  }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  (($sha.ComputeHash($stream.ToArray())) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Test-AvdWdotFile {
  # Every file the lock lists must exist with its hash, and no other function file may exist.
  # Returns the problems found; none means the extracted WDOT is exactly the pinned commit.
  [CmdletBinding()]
  [OutputType([string[]])]
  param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)] $Files)
  $problems = @()
  $expected = @($Files.PSObject.Properties | ForEach-Object { $_.Name })
  foreach ($rel in $expected) {
    $path = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $path)) { $problems += "missing: $rel"; continue }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Files.$rel) { $problems += "hash mismatch: $rel (expected $($Files.$rel), got $actual)" }
  }
  $functions = Join-Path $Root 'Functions'
  if (Test-Path -LiteralPath $functions) {
    foreach ($f in Get-ChildItem -LiteralPath $functions -File) {
      if ($expected -notcontains "Functions/$($f.Name)") { $problems += "not in the lock: Functions/$($f.Name)" }
    }
  }
  , $problems
}

function Set-AvdImageMarker {
  # What the build did, for Test-GoldenImage.ps1 and for anyone inspecting a host.
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][hashtable] $Value)
  $key = 'HKLM:\SOFTWARE\avdlz\Image'
  if (-not $PSCmdlet.ShouldProcess($key, 'Record image build markers')) { return }
  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  foreach ($k in $Value.Keys) { New-ItemProperty -Path $key -Name $k -PropertyType String -Value ([string]$Value[$k]) -Force | Out-Null }
}

function Invoke-AvdWdot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $LockBase64,
    [Parameter(Mandatory)][hashtable] $ProfileBase64,
    [string] $WorkRoot = (Join-Path $env:ProgramData 'avdlz\wdot')
  )
  $ErrorActionPreference = 'Stop'
  $lock = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LockBase64)) | ConvertFrom-Json
  Write-Output "WDOT $($lock.version) at $($lock.commit): $($lock.optimizations -join ', ')."

  # 1. The profile, checked against the lock before anything runs.
  $profileDir = Join-Path $WorkRoot 'profile'
  if (Test-Path $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
  New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
  foreach ($name in $ProfileBase64.Keys) {
    [System.IO.File]::WriteAllBytes((Join-Path $profileDir $name), [Convert]::FromBase64String($ProfileBase64[$name]))
  }
  $profileHash = Get-AvdWdotProfileHash -Path $profileDir
  if ($profileHash -ne $lock.profileSha256) { throw "WDOT profile hash $profileHash doesn't match the lock ($($lock.profileSha256))." }

  # 2. WDOT at the pinned commit, every file verified.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $zip = Join-Path $WorkRoot 'wdot.zip'
  Write-Output "Downloading $($lock.archiveUrl)"
  $attempt = 0
  while ($true) {
    $attempt++
    try { Invoke-WebRequest -Uri $lock.archiveUrl -OutFile $zip -UseBasicParsing; break }
    catch {
      if ($attempt -ge 3) { throw "Downloading WDOT failed after $attempt attempts: $($_.Exception.Message)" }
      Write-Output "Download attempt $attempt failed ($($_.Exception.Message)); retrying."
      Start-Sleep -Seconds (20 * $attempt)
    }
  }
  Expand-Archive -LiteralPath $zip -DestinationPath $WorkRoot -Force
  $root = Join-Path $WorkRoot $lock.archiveRoot
  $problems = Test-AvdWdotFile -Root $root -Files $lock.files
  if ($problems.Count) { throw "WDOT doesn't match the lock; nothing was run:`n  $($problems -join "`n  ")" }
  Write-Output "WDOT verified: $(@($lock.files.PSObject.Properties).Count) file(s) match the lock."

  # 3. Run it with the profile.
  $config = Join-Path $root 'Configurations\avdlz'
  New-Item -ItemType Directory -Path $config -Force | Out-Null
  Copy-Item -Path (Join-Path $profileDir '*') -Destination $config -Force
  Write-Output 'Running WDOT: this takes a few minutes.'
  $warnings = @()
  & (Join-Path $root 'Windows_Optimization.ps1') -ConfigProfile 'avdlz' -Optimizations ([string[]]$lock.optimizations) -AcceptEULA -WarningVariable +warnings
  foreach ($w in $warnings) { Write-Output "WDOT warning: $w" }

  Set-AvdImageMarker -Value @{
    WdotVersion       = $lock.version
    WdotCommit        = $lock.commit
    WdotProfileSha256 = $profileHash
    WdotOptimizations = ($lock.optimizations -join ',')
    WdotWarnings      = $warnings.Count
    WdotResult        = 'Succeeded'
  }
  Write-Output "WDOT finished with $($warnings.Count) warning(s)."
}
