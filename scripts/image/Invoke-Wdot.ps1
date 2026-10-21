# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Golden image: runs the Windows Desktop Optimization Tool (WDOT) with the reviewed profile
  (build/specs/image-pipeline-spec.md section 5.5, scripts/image/wdot/README.md).
.DESCRIPTION
  Downloads WDOT at the commit pinned in wdot.lock.json and refuses to run when any file's
  SHA-256 differs from the lock, or when the archive holds a function file the lock doesn't
  list (WDOT dot-sources every Functions\*-WDOT*.ps1). Writes the profile, checks its hash
  against the lock, runs the categories the lock names, then verifies the run and records the
  result under HKLM:\SOFTWARE\avdlz\Image for Test-GoldenImage.ps1.
  WDOT returns without an error when it skips work (a missing profile, a missing file, a broken
  event log), so its return is never taken as success: the run must have stamped
  HKLM:\SOFTWARE\WDOT afresh, logged the start, every category and the end in its event log, and
  disabled the services the profile applies (lesson 0031). Anything else fails the build.
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

function Get-AvdWdotRunProblem {
  # What a WDOT run left behind, judged against the lock. Pure: the caller reads the registry stamp
  # (HKLM:\SOFTWARE\WDOT, $null when absent), the WDOT event log entries since the run started,
  # the services present on the machine and everything WDOT reported (its warnings and error
  # messages). Returns the problems found, one line each; none
  # means the run did what the lock asked. Properties may be missing, the way the registry and
  # Get-WinEvent omit them.
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)] $Lock,
    [AllowNull()] $Stamp,
    [AllowEmptyCollection()][object[]] $LogEntry = @(),
    [AllowEmptyCollection()][object[]] $Service = @(),
    [AllowEmptyCollection()][string[]] $AppliedService = @(),
    [AllowEmptyCollection()][string[]] $Reported = @()
  )
  $problems = @()
  $v = $Lock.verify
  if (-not $Stamp -or -not $Stamp.PSObject.Properties['LastRunTime'] -or -not $Stamp.LastRunTime) {
    $problems += 'WDOT left no LastRunTime under HKLM:\SOFTWARE\WDOT: it never started.'
  }
  elseif (-not $Stamp.PSObject.Properties['Version'] -or $Stamp.Version -ne $Lock.toolVersion) {
    $found = if ($Stamp.PSObject.Properties['Version']) { $Stamp.Version } else { 'none' }
    $problems += "WDOT reports version $found under HKLM:\SOFTWARE\WDOT; the lock pins $($Lock.toolVersion)."
  }
  $entries = @($LogEntry | Where-Object { $_ })
  # Classic event log entries read back as level 4 (Information), or 0 on some builds.
  $info = @($entries | Where-Object { $_.PSObject.Properties['Level'] -and @(0, 4) -contains $_.Level })
  if ($entries.Count -eq 0) {
    $problems += 'The WDOT event log has no entries from this run, so nothing it did can be confirmed.'
  }
  else {
    foreach ($e in @($entries | Where-Object { $v.fatalEventIds -contains $_.Id })) { $problems += "WDOT stopped early (event $($e.Id)): $("$($e.Message)" -replace '\s+', ' ')" }
    foreach ($edge in @(@('start', $v.startEvent), @('end', $v.endEvent))) {
      if (-not @($info | Where-Object { $_.Id -eq $edge[1].id -and "$($_.Message)" -like $edge[1].message }).Count) {
        $problems += "WDOT logged no $($edge[0]) event (event $($edge[1].id), '$($edge[1].message)'): the run didn't $(if ($edge[0] -eq 'start') { 'start' } else { 'finish' })."
      }
    }
    foreach ($category in $Lock.optimizations) {
      $id = $v.categoryEvents.$category
      if ($null -eq $id) { $problems += "The lock runs $category but names no event to confirm it (verify.categoryEvents)."; continue }
      if (-not @($info | Where-Object { $_.Id -eq $id }).Count) { $problems += "WDOT skipped ${category}: no event $id, usually because its profile file wasn't found." }
    }
  }
  # A service the profile disables and the machine has must end up Disabled, or WDOT must have said why.
  foreach ($s in @($Service | Where-Object { $_ -and $AppliedService -contains $_.Name })) {
    if ("$($s.StartType)" -eq 'Disabled') { continue }
    $name = [regex]::Escape($s.Name)
    if (-not @($Reported | Where-Object { $_ -match "\b$name\b" }).Count) {
      $problems += "Service $($s.Name) is still $($s.StartType) and WDOT reported nothing about it."
    }
  }
  , $problems
}

function Initialize-AvdWdotEventLog {
  # WDOT v1.1 creates its event log with -Source passed twice, which Windows PowerShell 5.1 refuses,
  # so its own events (the evidence Get-AvdWdotRunProblem reads) never get written. The build
  # creates the log and every source first; WDOT then finds it and only repeats the refused call.
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string[]] $Source)
  if (-not $PSCmdlet.ShouldProcess('WDOT event log', 'Create')) { return }
  $missing = @(); $elsewhere = @()
  foreach ($s in $Source) {
    if (-not [System.Diagnostics.EventLog]::SourceExists($s)) { $missing += $s; continue }
    $log = [System.Diagnostics.EventLog]::LogNameFromSourceName($s, '.')
    if ($log -ne 'WDOT') { $elsewhere += "$s ($log)" }
  }
  # A source registered to another log would send WDOT's events there and fail the verification.
  if ($elsewhere.Count) { throw "WDOT's event sources are registered to other logs, so its run can't be verified: $($elsewhere -join ', ')." }
  if ($missing.Count) { New-EventLog -LogName 'WDOT' -Source $missing }
  Limit-EventLog -LogName 'WDOT' -OverflowAction OverWriteAsNeeded -MaximumSize 4MB
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

  # 3. Run it with the profile. WDOT's own errors are reported, not thrown: it handles most of them
  # itself, and step 4 decides whether the run worked.
  $config = Join-Path $root 'Configurations\avdlz'
  New-Item -ItemType Directory -Path $config -Force | Out-Null
  Copy-Item -Path (Join-Path $profileDir '*') -Destination $config -Force
  Initialize-AvdWdotEventLog -Source ([string[]]$lock.verify.eventSources)
  $stampKey = 'HKLM:\SOFTWARE\WDOT'
  if (Test-Path $stampKey) { Remove-ItemProperty -Path $stampKey -Name 'LastRunTime' -ErrorAction SilentlyContinue }
  $started = (Get-Date).AddSeconds(-5)
  Write-Output 'Running WDOT: this takes a few minutes.'
  $warnings = @(); $errors = @()
  $ErrorActionPreference = 'Continue'
  try { & (Join-Path $root 'Windows_Optimization.ps1') -ConfigProfile 'avdlz' -Optimizations ([string[]]$lock.optimizations) -AcceptEULA -WarningVariable +warnings -ErrorVariable +errors 2>$null }
  catch { $errors += $_ }
  finally { $ErrorActionPreference = 'Stop' }
  foreach ($w in $warnings) { Write-Output "WDOT warning: $w" }
  foreach ($e in @($errors | Where-Object { $_ -and $_.FullyQualifiedErrorId })) {
    $known = $lock.verify.knownErrors.($e.FullyQualifiedErrorId)
    if ($known) { Write-Output "WDOT error (known: $known): $($e.Exception.Message)" }
    else { Write-Output "WDOT error ($($e.FullyQualifiedErrorId)): $($e.Exception.Message)" }
  }

  # 4. Verify what it did: its stamp, its event log, and the services it was asked to disable.
  $stamp = Get-ItemProperty -Path $stampKey -ErrorAction SilentlyContinue
  $log = @(Get-WinEvent -FilterHashtable @{ LogName = 'WDOT'; StartTime = $started } -ErrorAction SilentlyContinue)
  $itemErrors = @($log | Where-Object { $_.Level -eq 2 -and $lock.verify.fatalEventIds -notcontains $_.Id })
  foreach ($e in $itemErrors) { Write-Output "WDOT logged error $($e.Id): $($e.Message)" }
  $applied = @(Get-Content -LiteralPath (Join-Path $profileDir 'Services.json') -Raw | ConvertFrom-Json | Where-Object OptimizationState -eq 'Apply' | ForEach-Object Name)
  $services = @(Get-Service | Where-Object { $applied -contains $_.Name } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; StartType = "$($_.StartType)" } })
  $reported = [string[]]@(@($warnings) + @($errors | Where-Object { $_ } | ForEach-Object { $_.Exception.Message }) + @($itemErrors | ForEach-Object { $_.Message }) | ForEach-Object { "$_" })
  $problems = Get-AvdWdotRunProblem -Lock $lock -Stamp $stamp -LogEntry $log -Service $services -AppliedService $applied -Reported $reported
  Write-Output "WDOT verification: $($log.Count) event(s) since the start, $($itemErrors.Count) item error(s), $($services.Count) of $($applied.Count) applied service(s) present."

  Set-AvdImageMarker -Value @{
    WdotVersion       = $lock.version
    WdotCommit        = $lock.commit
    WdotProfileSha256 = $profileHash
    WdotOptimizations = ($lock.optimizations -join ',')
    WdotWarnings      = $warnings.Count
    WdotItemErrors    = $itemErrors.Count
    WdotResult        = $(if ($problems.Count) { 'Failed' } else { 'Succeeded' })
    WdotProblems      = ($problems -join ' | ')
  }
  if ($problems.Count) { throw "WDOT didn't do what the lock asked; the image is not optimized:`n  $($problems -join "`n  ")" }
  Write-Output "WDOT finished and verified, with $($warnings.Count) warning(s) and $($itemErrors.Count) item error(s)."
}
