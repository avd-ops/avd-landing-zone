#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Deploys a demo host pool and session host into an existing landing zone,
  then validates that a user can sign in.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell) at the repo root or anywhere with the
  repo checked out.

  1. Discovers the landing zone (network, profile storage, Log Analytics, DCR,
     private DNS, Entra groups, AVD service principal) from its naming and RBAC.
  2. Runs the preflight checks (not NTFS, which needs a host) unless -SkipPreflight.
  3. Deploys bicep/demo/main.bicep: rg-<prefix>-<env>-demo with a pooled host
     pool, desktop app group, workspace and session host(s), built by the
     landing zone's own modules. No scaling plan, so the host stays up.
  4. Validates login readiness:
       - session host Available in the pool, all AVD health checks passing
       - FSLogix and agent-registration run commands succeeded
       - on the host: Entra joined, Intune enrolled, agent registered, FSLogix
         and Entra Kerberos configured, profile share resolves privately and
         answers on 445
       - RBAC: app group, VM User Login, SMB share role
       - tenant steps 1-3 (admin consent, CA exclusion, NTFS from the demo host)
       - optional -TestUserUpn: enabled, in the AVD Users group, licensed

  The demo host's break-glass password is random and not stored. Use
  VM > Reset password if you ever need it.

.EXAMPLE
  ./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -TestUserUpn alex@contoso.com

.EXAMPLE
  ./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -FixNtfs -EnrollInIntune:$false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string] $Environment,
  [string] $SubscriptionId,

  # Empty: the same size as the landing zone's session hosts (memory-optimized E-series by default).
  [string] $SessionHostVmSize,
  [ValidateRange(1, 5)][int] $SessionHostCount = 1,
  [int[]] $AvailabilityZones = @(),
  [bool] $EnrollInIntune = $true,
  [bool] $EncryptionAtHost = $true,

  # A user who should be able to sign in; validated for group membership and licensing.
  [string] $TestUserUpn,

  # Apply the FSLogix-recommended NTFS ACL if the check fails.
  [switch] $FixNtfs,

  [switch] $SkipPreflight,
  # Deploy even if the preflight reports failures.
  [switch] $Force,

  [ValidateRange(5, 120)][int] $TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
$template = Join-Path $PSScriptRoot '../../bicep/demo/main.bicep' | Resolve-Path

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Write-Host "AVD demo deployment - $NamePrefix/$Environment in '$($ctx.Subscription.Name)'" -ForegroundColor White
Clear-AvdCheckResult
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment

# ---------------------------------------------------------------------
# 1. Inputs the demo needs from the landing zone
# ---------------------------------------------------------------------
$required = [ordered]@{
  'session host subnet'       = $lz.SessionHostSubnetId
  'private endpoint subnet'   = $lz.PrivateEndpointSubnetId
  'Log Analytics workspace'   = $lz.LogAnalyticsId
  'AVD Insights DCR'          = $lz.DataCollectionRuleId
  'profile share'             = $lz.ProfileShareUnc
  'AVD Users group'           = $lz.UsersGroupId
  'AVD Admins group'          = $lz.AdminsGroupId
  'AVD service principal'     = $lz.AvdServicePrincipalId
}
$missing = @($required.Keys | Where-Object { -not $required[$_] })
if ($missing.Count) {
  throw "Landing zone '$($lz.BaseName)' is incomplete; could not find: $($missing -join ', '). Run Test-AvdLandingZoneReadiness.ps1 for details."
}

# ---------------------------------------------------------------------
# 2. Preflight
# ---------------------------------------------------------------------
if (-not $SessionHostVmSize) {
  $SessionHostVmSize = Get-AvdHostVmSize -Lz $lz
  if (-not $SessionHostVmSize) { $SessionHostVmSize = 'Standard_E4as_v5' }
}
if (-not $SkipPreflight) {
  Invoke-AvdReadinessCheck -Lz $lz -VmSize $SessionHostVmSize -VmCount $SessionHostCount -SkipNtfs
  $pre = Write-AvdSummary
  if ($pre.Failed -and -not $Force) {
    throw "Preflight reported $($pre.Failed) failure(s). Fix them (Test-AvdLandingZoneReadiness.ps1 -Fix) or rerun with -Force."
  }
  Clear-AvdCheckResult
}

# ---------------------------------------------------------------------
# 3. Deploy
# ---------------------------------------------------------------------
Write-AvdSection 'Deploying demo host pool'
$deploymentName = "avdlz-demo-$($lz.BaseName)"
$templateParams = @{
  namePrefix                      = $lz.NamePrefix
  environmentName                 = $lz.Environment
  location                        = $lz.Location
  sessionHostSubnetResourceId     = $lz.SessionHostSubnetId
  privateEndpointSubnetResourceId = $lz.PrivateEndpointSubnetId
  avdPrivateDnsZoneResourceId     = [string]$lz.AvdDnsZoneId
  logAnalyticsWorkspaceResourceId = $lz.LogAnalyticsId
  dataCollectionRuleResourceId    = $lz.DataCollectionRuleId
  profileShareUncPath             = $lz.ProfileShareUnc
  usersGroupObjectId              = $lz.UsersGroupId
  adminsGroupObjectId             = $lz.AdminsGroupId
  avdServicePrincipalObjectId     = $lz.AvdServicePrincipalId
  sessionHostCount                = $SessionHostCount
  sessionHostVmSize               = $SessionHostVmSize
  availabilityZones               = $AvailabilityZones
  enrollInIntune                  = $EnrollInIntune
  encryptionAtHost                = $EncryptionAtHost
  localAdminPassword              = Get-AvdRandomPassword
}
if (-not $PSCmdlet.ShouldProcess("rg-$($lz.BaseName)-demo", 'Deploy demo host pool and session host(s)')) { return }

Write-Host "  $deploymentName -> rg-$($lz.BaseName)-demo ($SessionHostCount x $SessionHostVmSize). This takes 15-25 minutes." -ForegroundColor DarkGray
$deployment = New-AzSubscriptionDeployment -Name $deploymentName -Location $lz.Location `
  -TemplateFile $template -TemplateParameterObject $templateParams -ErrorAction Stop
if ($deployment.ProvisioningState -ne 'Succeeded') { throw "Deployment $deploymentName ended $($deployment.ProvisioningState)." }

$out = $deployment.Outputs
$demoRg = $out.resourceGroupName.Value
$hostPoolId = $out.hostPoolResourceId.Value
$appGroupId = $out.appGroupResourceId.Value
$hostNames = @($out.sessionHostNames.Value | ForEach-Object { [string]$_ })
Add-AvdCheckResult 'Deployment' "Deployed $($out.hostPoolName.Value) with $($hostNames -join ', ')" 'Pass'

# ---------------------------------------------------------------------
# 4. Login readiness
# ---------------------------------------------------------------------
Write-AvdSection 'Session hosts in the pool'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
  $status = Get-AvdSessionHost -HostPoolResourceId $hostPoolId
  $available = @($status | Where-Object { $_.properties.status -eq 'Available' })
  if ($available.Count -ge $hostNames.Count) { break }
  Write-Host "  waiting for hosts to report Available ($($available.Count)/$($hostNames.Count))" -ForegroundColor DarkGray
  Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)

foreach ($vmName in $hostNames) {
  $sh = $status | Where-Object { ($_.name -split '/')[-1] -like "$vmName*" } | Select-Object -First 1
  if (-not $sh) { Add-AvdCheckResult 'Host pool' "$vmName registered in the host pool" 'Fail' -Remediation 'Check the Register-AvdAgent run command output on the VM.'; continue }
  $p = $sh.properties
  if ($p.status -eq 'Available') { Add-AvdCheckResult 'Host pool' "$vmName Available" 'Pass' -Detail "Agent $($p.agentVersion)" }
  else { Add-AvdCheckResult 'Host pool' "$vmName Available" 'Fail' -Detail "Status: $($p.status)" -Remediation 'See docs/gotchas.md (session host Unavailable).' }
  if ($p.allowNewSession) { Add-AvdCheckResult 'Host pool' "$vmName accepts new sessions" 'Pass' }
  else { Add-AvdCheckResult 'Host pool' "$vmName accepts new sessions" 'Fail' -Remediation 'Turn drain mode off.' }
  $failedHealth = @($p.sessionHostHealthCheckResults | Where-Object { $_.healthCheckResult -ne 'HealthCheckSucceeded' })
  if ($p.sessionHostHealthCheckResults -and -not $failedHealth.Count) { Add-AvdCheckResult 'Host pool' "$vmName AVD health checks" 'Pass' }
  elseif ($failedHealth.Count) { Add-AvdCheckResult 'Host pool' "$vmName AVD health checks" 'Fail' -Detail (($failedHealth | ForEach-Object { "$($_.healthCheckName): $($_.healthCheckResult)" }) -join '; ') }
}

Write-AvdSection 'Session host configuration'
foreach ($vmName in $hostNames) {
  $vm = Get-AzVM -ResourceGroupName $demoRg -Name $vmName
  foreach ($rc in 'Configure-FSLogix', 'Register-AvdAgent') {
    $iv = Get-AvdRunCommandState -VmResourceId $vm.Id -Name $rc
    if ($iv -and $iv.executionState -eq 'Succeeded' -and $iv.exitCode -eq 0) { Add-AvdCheckResult 'Host config' "$vmName $rc run command" 'Pass' }
    else { Add-AvdCheckResult 'Host config' "$vmName $rc run command" 'Fail' -Detail "State: $($iv.executionState) exit $($iv.exitCode) $($iv.error)" }
  }

  $h = Invoke-AvdHostScript -ResourceGroupName $demoRg -VMName $vmName -ScriptName 'Test-SessionHostReadiness.ps1' -Parameter @{
    StorageFqdn = $lz.StorageFqdn; ProfileShareUnc = $lz.ProfileShareUnc
  }
  $checks = [ordered]@{
    'Entra ID joined'                             = @($h.entraJoined, 'AADLoginForWindows extension; check the VM extension status.')
    'AVD agent registered and boot loader running' = @(($h.agentRegistered -and $h.bootLoaderRunning), 'Check the Register-AvdAgent run command output.')
    'FSLogix running and pointed at the profile share' = @(($h.fslogixServiceRunning -and $h.fslogixEnabled -and $h.fslogixPointsAtShare), 'Check the Configure-FSLogix run command output.')
    'Entra Kerberos ticket retrieval enabled'     = @(($h.cloudKerberosEnabled -and $h.loadCredKeyFromProfile), 'Check the Configure-FSLogix run command output.')
    'Entra Kerberos services running (WinHttpAutoProxySvc, iphlpsvc)' = @((-not @($h.kerberosServicesStopped | Where-Object { $_ }).Count), "Not running: $(@($h.kerberosServicesStopped) -join ', '). Start them and set them to start automatically; a hardening baseline or image optimization may have disabled them.")
    'Profile share resolves to a private IP'      = @($h.storageIpPrivate, "Resolved to $($h.storageIp). Check private DNS for $($lz.StorageFqdn).")
    'Profile share reachable on TCP 445'          = @($h.smbReachable, 'Check the private endpoint subnet NSG and routing.')
  }
  foreach ($k in $checks.Keys) {
    if ($checks[$k][0]) { Add-AvdCheckResult 'Host config' "$vmName $k" 'Pass' }
    else { Add-AvdCheckResult 'Host config' "$vmName $k" 'Fail' -Remediation $checks[$k][1] }
  }
  if ($EnrollInIntune) {
    if ($h.intuneEnrolled) { Add-AvdCheckResult 'Host config' "$vmName Intune enrolled" 'Pass' }
    else { Add-AvdCheckResult 'Host config' "$vmName Intune enrolled" 'Warn' -Detail 'Enrollment can lag the join by several minutes.' -Remediation 'Recheck in Intune; confirm the tenant is licensed for Intune.' }
  }
}

Write-AvdSection 'Access (RBAC)'
$rbac = @(
  @($appGroupId, 'Desktop Virtualization User', 'AVD Users can see the demo desktop'),
  @($lz.ResourceGroupIds.Demo, 'Virtual Machine User Login', 'AVD Users can sign in to the demo hosts'),
  @($lz.StorageAccount.Id, 'Storage File Data SMB Share Contributor', 'AVD Users can mount the profile share')
)
foreach ($r in $rbac) {
  $ok = Get-AzRoleAssignment -Scope $r[0] -RoleDefinitionName $r[1] -ObjectId $lz.UsersGroupId -ErrorAction SilentlyContinue
  if ($ok) { Add-AvdCheckResult 'RBAC' $r[2] 'Pass' } else { Add-AvdCheckResult 'RBAC' $r[2] 'Fail' -Detail "Missing $($r[1])" }
}

Write-AvdSection 'Tenant steps'
Connect-AvdGraph -Purpose ($(if ($FixNtfs) { 'Fix' } else { 'Read' }))
$storageApp = Get-AvdStorageKerberosApp -Lz $lz
if ($storageApp) {
  Test-AvdStorageAdminConsent -StorageApp $storageApp
  Test-AvdCloudGroupSidTag -StorageApp $storageApp
  Test-AvdConditionalAccessExclusion -Lz $lz -StorageApp $storageApp
}
else {
  Add-AvdCheckResult 'Step 1: admin consent' 'Storage account Entra app exists' 'Fail'
}
Test-AvdProfileShareAcl -Lz $lz -ResourceGroupName $demoRg -VMName $hostNames[0] -Fix:$FixNtfs

if ($TestUserUpn) {
  Write-AvdSection "Test user $TestUserUpn"
  try {
    $u = Invoke-AvdGraph -Uri "v1.0/users/$([uri]::EscapeDataString($TestUserUpn))`?`$select=id,accountEnabled,assignedLicenses,userPrincipalName"
    if ($u.accountEnabled) { Add-AvdCheckResult 'Test user' 'Account enabled' 'Pass' } else { Add-AvdCheckResult 'Test user' 'Account enabled' 'Fail' }
    $member = Invoke-AvdGraph -Method POST -Uri "v1.0/users/$($u.id)/checkMemberGroups" -Body @{ groupIds = @($lz.UsersGroupId) }
    if (@($member.value) -contains $lz.UsersGroupId) { Add-AvdCheckResult 'Test user' 'Member of the AVD Users group' 'Pass' }
    else { Add-AvdCheckResult 'Test user' 'Member of the AVD Users group' 'Fail' -Remediation 'Add the user (or a group they are in) to the AVD Users group.' }
    if (@($u.assignedLicenses).Count) { Add-AvdCheckResult 'Test user' 'Has licenses assigned' 'Pass' }
    else { Add-AvdCheckResult 'Test user' 'Has licenses assigned' 'Warn' -Remediation 'AVD needs an eligible license (e.g. Microsoft 365 E3/E5/Business Premium, Windows Enterprise E3/E5).' }
  }
  catch { Add-AvdCheckResult 'Test user' "Look up $TestUserUpn" 'Fail' -Detail $_.Exception.Message }
}

$summary = Write-AvdSummary
$demoContext = @{ namePrefix = $NamePrefix; environment = $Environment; testUserUpn = $TestUserUpn; workspace = "vdws-$($lz.BaseName)-demo" }
# The demo desktop's direct launch link for the portal's Verify access step (decision 0014).
$launch = Get-AvdLaunchTarget -ResourceGroupId $lz.ResourceGroupIds.Demo -TenantId $lz.TenantId
if ($launch) { $demoContext.launch = $launch }
$portalState = Get-AvdPortalState -Stage demo -Context $demoContext
if ($summary.Failed) {
  Write-Host "Demo deployed, but $($summary.Failed) readiness check(s) failed; fix them before testing sign-in." -ForegroundColor Red
  Write-AvdPortalState $portalState
  exit 1
}
Write-Host ''
Write-Host 'Ready to sign in:' -ForegroundColor Green
Write-Host "  1. As a member of the AVD Users group, open https://windows.cloud.microsoft (or the Windows App)."
Write-Host "  2. Open 'Desktop' in the 'vdws-$($lz.BaseName)-demo' workspace."
Write-Host "  3. Remove the demo afterwards: ./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix $NamePrefix -Environment $Environment"
Write-AvdPortalState $portalState
exit 0
