# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  First boot of the Windows operator jumpbox (build/decisions/0019-jumpbox-bastion-developer.md):
  installs the Cloud Shell toolchain, the same tools scripts/jumpbox/cloud-init.yaml installs on Linux.

.DESCRIPTION
  Embedded in a Run Command by bicep/modules/jumpbox.bicep at compile time and run once, when the VM is
  created. Windows PowerShell 5.1 (lesson 0011). Downloads from Microsoft, the PowerShell Gallery and the
  pinned GitHub releases of PowerShell, Git for Windows and Bicep (the version CI pins in validate.yml).
  Installs tools only: no credentials, no repository checkout. The operator signs in as themselves
  (device code) in each session. Progress goes to C:\avdlz\jumpbox.log, which ends with 'ready'.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = 'C:\avdlz'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$log = Join-Path $root 'jumpbox.log'
function Write-Step([string] $Text) { Add-Content -Path $log -Value "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) $Text" }

# Downloads one file, retrying, and fails with what the server said.
function Get-Download([string] $Uri, [string] $Path) {
  for ($i = 1; $i -le 3; $i++) {
    try { Invoke-WebRequest -Uri $Uri -OutFile $Path -UseBasicParsing; return }
    catch { Write-Step "download $Uri attempt $i failed: $($_.Exception.Message)"; if ($i -eq 3) { throw }; Start-Sleep -Seconds 10 }
  }
}

# Runs an installer and fails on a non-zero exit code.
function Invoke-Installer([string] $File, [string[]] $Arguments) {
  $p = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "$File exited $($p.ExitCode)" }
}

try {
  $tmp = Join-Path $root 'downloads'
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null

  Write-Step 'installing PowerShell 7'
  $msi = Join-Path $tmp 'PowerShell.msi'
  Get-Download 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi' $msi
  Invoke-Installer 'msiexec.exe' @('/i', $msi, '/qn', '/norestart', 'ADD_PATH=1')

  Write-Step 'installing the Azure CLI'
  $msi = Join-Path $tmp 'AzureCLI.msi'
  Get-Download 'https://aka.ms/installazurecliwindowsx64' $msi
  Invoke-Installer 'msiexec.exe' @('/i', $msi, '/qn', '/norestart')

  Write-Step 'installing Git for Windows'
  $exe = Join-Path $tmp 'Git.exe'
  Get-Download 'https://github.com/git-for-windows/git/releases/download/v2.47.0.windows.1/Git-2.47.0-64-bit.exe' $exe
  Invoke-Installer $exe @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-')

  Write-Step 'installing Bicep'
  $bicepDir = 'C:\Program Files\Bicep'
  New-Item -ItemType Directory -Force -Path $bicepDir | Out-Null
  Get-Download 'https://github.com/Azure/bicep/releases/download/v0.48.1/bicep-win-x64.exe' (Join-Path $bicepDir 'bicep.exe')
  # Append to the machine Path in the registry as it is stored (unexpanded, REG_EXPAND_SZ), so the
  # %SystemRoot%-style entries keep expanding.
  $envKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
  $machinePath = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  if ($machinePath -notlike "*$bicepDir*") { $envKey.SetValue('Path', "$($machinePath.TrimEnd(';'));$bicepDir", [Microsoft.Win32.RegistryValueKind]::ExpandString) }
  $envKey.Close()

  Write-Step 'installing the Az and Microsoft Graph PowerShell modules the scripts use'
  $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
  Invoke-Installer $pwsh @('-NoProfile', '-NonInteractive', '-Command', 'Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module -Scope AllUsers -Force -Name Az.Accounts, Az.Resources, Az.Compute, Az.Storage, Az.KeyVault, Az.RecoveryServices, Az.DesktopVirtualization, Microsoft.Graph.Authentication')

  Remove-Item -Recurse -Force $tmp
  Set-Content -Path (Join-Path $root 'README.txt') -Value @(
    'AVD landing zone jumpbox. Tools: pwsh, az, bicep, git (C:\avdlz\jumpbox.log ends with ready when first boot is done).'
    'Sign in as yourself: az login --use-device-code ; pwsh -c Connect-AzAccount -UseDeviceAuthentication'
    'Keep run journals in the run store, not here: this disk is deleted with the jumpbox.'
    'Stops daily on its own schedule; ./scripts/ops/Connect-AvdJumpbox.ps1 -Stop stops it now.'
  )
  Write-Step 'ready'
}
catch {
  Write-Step "failed: $($_.Exception.Message)"
  throw
}
