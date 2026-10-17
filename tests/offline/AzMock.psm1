# Offline stand-in for the Az, ARM (Invoke-AzRestMethod) and Microsoft Graph calls the
# ops scripts make. State lives in $global:St; every state-changing call is logged in
# $global:Calls. Used by tests/offline/*.Scenario.ps1 (run by tests/OfflineScenarios.Tests.ps1).
# When a real run exposes a behavior this mock gets wrong, fix the mock AND add the case.

# ---- State ----
$global:Calls = [System.Collections.Generic.List[string]]::new()
function Log($s){ $global:Calls.Add($s) }
$sub='00000000-aaaa-bbbb-cccc-000000000001'; $S="/subscriptions/$sub"
$base='avdlz-dev'
$global:St = @{
  grants = @(); tags=@(); caExclude=@(); securityDefaults=$false; aclApplied=$false; forbiddenOnce=$true; roleAssignments=@()
  rgs = @('rg-avdlz-dev-network','rg-avdlz-dev-management','rg-avdlz-dev-storage','rg-avdlz-dev-avd','rg-avdlz-dev-hosts')
}
$users='11111111-1111-1111-1111-111111111111'; $admins='22222222-2222-2222-2222-222222222222'; $avdsp='33333333-3333-3333-3333-333333333333'
$saName='stavdlzdevabc123'; $saId="$S/resourceGroups/rg-avdlz-dev-storage/providers/Microsoft.Storage/storageAccounts/$saName"
$hpId="$S/resourceGroups/rg-avdlz-dev-avd/providers/Microsoft.DesktopVirtualization/hostPools/vdpool-avdlz-dev"
$agId="$S/resourceGroups/rg-avdlz-dev-avd/providers/Microsoft.DesktopVirtualization/applicationGroups/vdag-avdlz-dev-desktop"
$vnetId="$S/resourceGroups/rg-avdlz-dev-network/providers/Microsoft.Network/virtualNetworks/vnet-avdlz-dev"
$lawId="$S/resourceGroups/rg-avdlz-dev-management/providers/Microsoft.OperationalInsights/workspaces/log-avdlz-dev"

function Get-AzContext { [pscustomobject]@{ Subscription=[pscustomobject]@{Id=$sub;Name='AVD LZ Dev'}; Tenant=[pscustomobject]@{Id='55555555-5555-5555-5555-555555555555'}; Environment=[pscustomobject]@{StorageEndpointSuffix='core.windows.net'} } }
function Set-AzContext { param($SubscriptionId,$ErrorAction) Get-AzContext }
# Resource groups are in eastus2 unless created in the scenario with a location ($global:St.rgLocations).
function Get-AzResourceGroup { param($Name,$ErrorAction) $list = $global:St.rgs | % { [pscustomobject]@{ResourceGroupName=$_;Location=$(if ($global:St.rgLocations -and $global:St.rgLocations[$_]) { $global:St.rgLocations[$_] } else { 'eastus2' })} }; if ($Name) { $list | ? ResourceGroupName -eq $Name } else { $list } }
function Get-AzResource {
  param($ResourceGroupName,$ResourceType,$Name,$ResourceId,[switch]$ExpandProperties,$ErrorAction)
  if ($ResourceId) { return [pscustomobject]@{ Tags=$global:St.power.hpTags; Properties=[pscustomobject]@{publicNetworkAccess='EnabledForClientsOnly'} } }
  $r = switch ($ResourceType) {
    'Microsoft.Network/virtualNetworks' { [pscustomobject]@{Name='vnet-avdlz-dev';ResourceId=$vnetId;Location='eastus2'} }
    'Microsoft.KeyVault/vaults' { [pscustomobject]@{Name='kvavdlzdevabc';ResourceId="$S/rg/kv";ResourceGroupName=$ResourceGroupName} }
    'Microsoft.OperationalInsights/workspaces' { [pscustomobject]@{Name='log-avdlz-dev';ResourceId=$lawId} }
    'Microsoft.Insights/dataCollectionRules' { [pscustomobject]@{Name='microsoft-avdi-avdlz-dev';ResourceId="$S/rg/dcr"} }
    'Microsoft.DesktopVirtualization/hostPools' { [pscustomobject]@{Name='vdpool-avdlz-dev';ResourceId=$hpId} }
    'Microsoft.DesktopVirtualization/applicationGroups' { [pscustomobject]@{Name='vdag';ResourceId=$agId} }
    'Microsoft.RecoveryServices/vaults' { [pscustomobject]@{Name='rsv-avdlz-dev';ResourceGroupName='rg-avdlz-dev-storage'} }
  }
  if ($global:St.rgs -contains $ResourceGroupName) { $r }
}
function Get-AzStorageAccount { param($ResourceGroupName,$ErrorAction)
  [pscustomobject]@{StorageAccountName=$saName;Id=$saId;Kind='FileStorage';PublicNetworkAccess='Disabled';AzureFilesIdentityBasedAuth=[pscustomobject]@{DirectoryServiceOptions='AADKERB'}} }
function Invoke-AzRestMethod { param($Path,$Method,$Payload,$ErrorAction)
  Log "ARM $Method $Path"
  $ok = { param($o) [pscustomobject]@{StatusCode=200;Content=($o|ConvertTo-Json -Depth 20)} }
  # ---- Golden image pipeline (scripts/ops/Start-AvdImageBuild.ps1): rg-avdlz-images, its gallery,
  # per-build image templates, and the marketplace versions. $global:St.images holds the state.
  $im = $global:St.images
  if ($Path -match 'rg-avdlz-images|/publishers/MicrosoftWindowsDesktop/') {
    $notFound = [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"ResourceNotFound","message":"The Resource was not found."}}' }
    # The marketplace versions API returns a bare JSON array, even for one version.
    if ($Path -match '/skus/win11-24h2-avd-m365/versions\?') {
      return [pscustomobject]@{ StatusCode=200; Content=(ConvertTo-Json -InputObject @($im.sourceVersions | ForEach-Object { @{ name=$_; location='northcentralus' } }) -Depth 5) }
    }
    if ($Path -match 'galleries/galavdlz/images/win11-avd-m365/versions/([^/?]+)\?') {
      $v = $im.versions | Where-Object { $_.name -eq $Matches[1] } | Select-Object -First 1
      if (-not $v) { return $notFound }
      if ($Method -eq 'PATCH') { foreach ($t in ($Payload | ConvertFrom-Json).tags.PSObject.Properties) { $v.tags[$t.Name] = $t.Value }; return & $ok @{ name=$v.name; tags=$v.tags } }
      return & $ok @{ name=$v.name; tags=$v.tags; properties=@{ provisioningState=$v.state; publishingProfile=@{ excludeFromLatest=$true; targetRegions=@(@{ name='North Central US'; regionalReplicaCount=1; storageAccountType='Standard_LRS' }) } } }
    }
    if ($Path -match 'galleries/galavdlz/images/win11-avd-m365/versions\?') { return & $ok @{ value=@($im.versions | ForEach-Object { @{ name=$_.name; tags=$_.tags; properties=@{ provisioningState=$_.state } } }) } }
    if ($Path -match 'galleries/galavdlz/images/win11-avd-m365\?') {
      if (-not $im.definition) { return $notFound }
      return & $ok @{ name='win11-avd-m365'; location='northcentralus'; properties=@{ osType='Windows'; hyperVGeneration='V2' } }
    }
    if ($Path -match 'rg-avdlz-images-staging/providers/Microsoft.Storage/storageAccounts\?') { return & $ok @{ value=@(@{ name='stagingavdlzabc' }) } }
    if ($Path -match 'rg-avdlz-images/providers/Microsoft.Resources/deployments/([^/?]+)\?') {
      if ($Method -eq 'PUT') {
        $p = ($Payload | ConvertFrom-Json).properties.parameters
        $name = 'it-avdlz-' + $p.version.value.Replace('.', '-')
        $im.templates[$name] = @{ created=(Get-Date).ToUniversalTime().ToString('o'); state=$null; polls=0; version=$p.version.value; source=$p.sourceImageVersion.value; commit=$p.commit.value; emergency=$p.emergency.value }
        $im.deployed += $name
        return & $ok @{ properties=@{ provisioningState='Accepted' } }
      }
      if ($im.deployFails) { return & $ok @{ properties=@{ provisioningState='Failed'; error=@{ code='InvalidTemplateDeployment'; message='The template deployment failed: subnet snet-image-build not found.' } } } }
      return & $ok @{ properties=@{ provisioningState='Succeeded' } }
    }
    if ($Path -match 'imageTemplates/([^/?]+)/run\?') { $im.templates[$Matches[1]].state = 'Running'; return [pscustomobject]@{ StatusCode=202; Content='' } }
    if ($Path -match 'imageTemplates/([^/?]+)\?') {
      $name = $Matches[1]; $t = $im.templates[$name]
      if ($Method -eq 'DELETE') { if ($t) { $im.templates.Remove($name); $im.deleted += $name }; return [pscustomobject]@{ StatusCode=202; Content='' } }
      if (-not $t) { return $notFound }
      $o = @{ name=$name; tags=@{ 'avdlz-created'=$t.created }; properties=@{ provisioningState='Succeeded' } }
      if ($t.state -eq 'Running') {
        $t.polls++
        if ($t.polls -ge 3) {
          $t.state = $im.runOutcome
          if ($t.state -eq 'Succeeded') { $im.versions += @{ name=$t.version; state='Succeeded'; tags=@{ 'avdlz-source-image'="MicrosoftWindowsDesktop/office-365/win11-24h2-avd-m365/$($t.source)"; 'avdlz-commit'=$t.commit; 'avdlz-emergency'="$($t.emergency)" } } }
        }
      }
      # ARM leaves lastRunStatus out until the template has been run (lesson 0021).
      if ($t.state) {
        $o.properties.lastRunStatus = @{ runState=$t.state; runSubState=$(if ($t.state -eq 'Running') { 'Customizing' } else { '' }) }
        if ($t.state -eq 'Failed') { $o.properties.lastRunStatus.message = 'Validation failed: inVMValidations step golden-image exited with code 1.' }
      }
      return & $ok $o
    }
    if ($Path -match 'rg-avdlz-images/providers/Microsoft.VirtualMachineImages/imageTemplates\?') {
      return & $ok @{ value=@($im.templates.Keys | ForEach-Object { @{ name=$_; tags=@{ 'avdlz-created'=$im.templates[$_].created } } }) }
    }
  }
  if ($Method -eq 'POST' -and $Path -match '/providers/([^/?]+)/register') { $global:St.registered += $Matches[1]; return & $ok @{} }
  # Soft-deleted Key Vaults ($global:St.deletedVaults: VaultName, Location, ResourceGroup) and their
  # recovery, which (as in Azure) needs the original resource group to exist.
  if ($Path -match '/providers/Microsoft.KeyVault/deletedVaults\?') {
    return & $ok @{ value = @($global:St.deletedVaults | ForEach-Object { @{ name = $_.VaultName; properties = @{ location = $_.Location; purgeProtectionEnabled = $true
            vaultId = "$S/resourceGroups/$($_.ResourceGroup)/providers/Microsoft.KeyVault/vaults/$($_.VaultName)" } } }) }
  }
  if ($Method -eq 'PUT' -and $Path -match '^/subscriptions/[^/]+/resourcegroups/([^/?]+)\?') {
    if (-not $global:St.rgLocations) { $global:St.rgLocations = @{} }
    $global:St.rgs = @($global:St.rgs) + $Matches[1]; $global:St.rgLocations[$Matches[1]] = ($Payload | ConvertFrom-Json).location; return & $ok @{ name = $Matches[1] }
  }
  if ($Path -match '/resourceGroups/([^/]+)/providers/Microsoft.KeyVault/vaults/([^/?]+)\?') {
    $rg = $Matches[1]; $name = $Matches[2]
    if ($Method -eq 'PUT') {
      $d = @($global:St.deletedVaults | Where-Object VaultName -eq $name)
      if (($Payload | ConvertFrom-Json).properties.createMode -ne 'recover' -or -not $d.Count) { return [pscustomobject]@{ StatusCode=409; Content='{"error":{"code":"ConflictError","message":"A vault with the same name already exists in deleted state."}}' } }
      if ($global:St.rgs -notcontains $rg) { return [pscustomobject]@{ StatusCode=404; Content="{""error"":{""code"":""ResourceGroupNotFound"",""message"":""Resource group '$rg' could not be found.""}}" } }
      $global:St.deletedVaults = @($global:St.deletedVaults | Where-Object VaultName -ne $name); $global:St.recoveredVaults = @($global:St.recoveredVaults) + $name
      return & $ok @{ name = $name; properties = @{ provisioningState = 'RegisteringDns' } }
    }
    if (@($global:St.recoveredVaults) -contains $name) { return & $ok @{ name = $name; properties = @{ provisioningState = 'Succeeded' } } }
    return [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"ResourceNotFound"}}' }
  }
  # Resource provider list (Get-AvdProviderState) and the AVD provider's regions (Test-AvdHostPoolRegion).
  if ($Path -match '/providers\?api-version') {
    $ns = 'Microsoft.DesktopVirtualization','Microsoft.Compute','Microsoft.Storage','Microsoft.Network','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.KeyVault','Microsoft.RecoveryServices','Microsoft.Security','Microsoft.PolicyInsights','Microsoft.GuestConfiguration','Microsoft.Consumption'
    return & $ok @{ value = @($ns | ForEach-Object { @{ namespace = $_; registrationState = $(if ($global:St.unregistered -contains $_ -and $global:St.registered -notcontains $_) { 'NotRegistered' } else { 'Registered' }) } }) }
  }
  if ($Path -match '/providers/Microsoft.DesktopVirtualization\?api-version') {
    return & $ok @{ resourceTypes = @(@{ resourceType = 'workspaces'; locations = @('North Central US') }, @{ resourceType = 'hostpools'; locations = @('North Central US', 'East US 2', 'West US 2') }) }
  }
  if ($Path -match 'Microsoft.Storage/skus') { return & $ok @{ value=@(@{name='Premium_ZRS';kind='FileStorage';locations=@('eastus2');restrictions=@()},@{name='Premium_LRS';kind='FileStorage';locations=@('eastus2','northcentralus');restrictions=@()}) } }
  if ($Path -match 'privateEndpoints\?') { return & $ok @{ value=@(
      @{ id="$S/pe-st"; properties=@{ privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$saId}}); manualPrivateLinkServiceConnections=@() } },
      @{ id="$S/pe-hp"; properties=@{ privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$hpId}}); manualPrivateLinkServiceConnections=@() } }) } }
  if ($Path -match 'pe-st/privateDnsZoneGroups') { return & $ok @{ value=@(@{properties=@{privateDnsZoneConfigs=@(@{properties=@{privateDnsZoneId="$S/zones/privatelink.file.core.windows.net"}})}}) } }
  if ($Path -match 'pe-hp/privateDnsZoneGroups') { return & $ok @{ value=@(@{properties=@{privateDnsZoneConfigs=@(@{properties=@{privateDnsZoneId="$S/zones/privatelink.wvd.microsoft.com"}})}}) } }
  # ---- Launch link (Get-AvdLaunchTarget, decision 0014): the desktop app group, its desktop and the
  # workspace, in the landing zone's avd group and in the demo group. ARM leaves out empty properties
  # (lesson 0021): $global:St.launchNoObjectId drops objectId the way an unexpected response would.
  if ($Path -match '/resourceGroups/rg-avdlz-dev-(avd|demo)/providers/Microsoft.DesktopVirtualization/(applicationGroups|workspaces)\?') {
    $suffix = if ($Matches[1] -eq 'demo') { '-demo' } else { '' }; $rgName = "rg-avdlz-dev-$($Matches[1])"
    $ag = "$S/resourceGroups/$rgName/providers/Microsoft.DesktopVirtualization/applicationGroups/vdag-avdlz-dev$suffix-desktop"
    if ($Matches[2] -eq 'applicationGroups') { return & $ok @{ value=@(@{ name="vdag-avdlz-dev$suffix-desktop"; id=$ag; properties=@{ applicationGroupType='Desktop' } }) } }
    $ws = @{ name="vdws-avdlz-dev$suffix"; id="$S/resourceGroups/$rgName/providers/Microsoft.DesktopVirtualization/workspaces/vdws-avdlz-dev$suffix"; properties=@{ applicationGroupReferences=@($ag.ToLower()) } }
    if (-not $global:St.launchNoObjectId) { $ws.properties.objectId = $(if ($suffix) { 'a0a0a0a0-0000-4000-8000-00000000d0d0' } else { 'a0a0a0a0-0000-4000-8000-000000000001' }) }
    return & $ok @{ value=@($ws) }
  }
  if ($Path -match '/applicationGroups/vdag-avdlz-dev(-demo)?-desktop/desktops\?') {
    $d = @{ name="vdag-avdlz-dev$($Matches[1])-desktop/SessionDesktop"; properties=@{} }
    if (-not $global:St.launchNoObjectId) { $d.properties.objectId = $(if ($Matches[1]) { 'b0b0b0b0-0000-4000-8000-00000000d0d0' } else { 'b0b0b0b0-0000-4000-8000-000000000001' }) }
    return & $ok @{ value=@($d) }
  }
  # ---- Power runbook (scripts/automation/Invoke-AvdPowerAction.ps1): the landing zone host pool,
  # two hosts (001 with two user sessions, 002 idle), their VMs' power state and tags.
  $pw = $global:St.power
  $hpRe = [regex]::Escape($hpId)   # not -like: '?' is a wildcard there
  if ($Method -eq 'PATCH' -and $pw.failHostPoolPatch -and $Path -match "^$hpRe\?") {
    return [pscustomobject]@{ StatusCode=403; Content='{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization to perform action Microsoft.DesktopVirtualization/hostpools/write."}}' }
  }
  if ($Path -match 'rg-avdlz-dev-avd/providers/Microsoft.DesktopVirtualization/hostPools\?') { return & $ok @{ value=@(@{ name='vdpool-avdlz-dev'; id=$hpId; tags=$pw.hpTags; properties=@{ startVMOnConnect=$pw.startVMOnConnect } }) } }
  if ($Method -eq 'PATCH' -and $Path -match "^$hpRe\?") {
    # Kept as a hashtable: Get-AzResource returns Tags that way.
    $b = $Payload | ConvertFrom-Json; $pw.startVMOnConnect = $b.properties.startVMOnConnect
    $pw.hpTags = @{}; foreach ($t in $b.tags.PSObject.Properties) { $pw.hpTags[$t.Name] = $t.Value }
    return & $ok @{}
  }
  if ($Path -match "^$hpRe/sessionHosts\?") {
    return & $ok @{ value=@('avdlzdsh-001', 'avdlzdsh-002' | ForEach-Object { @{ name="vdpool-avdlz-dev/$_"; properties=@{ resourceId="$S/resourceGroups/rg-avdlz-dev-hosts/providers/Microsoft.Compute/virtualMachines/$_"; sessions=$pw.sessions[$_]; allowNewSession=$pw.allowNew[$_] } } }) }
  }
  if ($Method -eq 'PATCH' -and $Path -match "^$hpRe/sessionHosts/([^/?]+)\?") { $pw.allowNew[$Matches[1]] = ($Payload | ConvertFrom-Json).properties.allowNewSession; return & $ok @{} }
  if ($Path -match "/sessionHosts/([^/]+)/userSessions\?") { $h = $Matches[1]; return & $ok @{ value=@(1..([int]$pw.sessions[$h]) | Where-Object { $_ } | ForEach-Object { @{ name="vdpool-avdlz-dev/$h/$_" } }) } }
  if ($Path -match '/sendMessage\?') { return & $ok @{} }
  if ($Path -match 'virtualMachines/([^/]+)/providers/Microsoft.Resources/tags/default') {
    $b = $Payload | ConvertFrom-Json; $h = $Matches[1]
    if ($b.operation -eq 'Merge') { $pw.vmTags[$h] = @($pw.vmTags[$h]) + @($b.properties.tags.PSObject.Properties.Name) | Where-Object { $_ } | Select-Object -Unique }
    else { $pw.vmTags[$h] = @($pw.vmTags[$h] | Where-Object { $_ -notin $b.properties.tags.PSObject.Properties.Name }) }
    return & $ok @{}
  }
  if ($Path -match 'virtualMachines/([^/]+)/instanceView\?') { return & $ok @{ statuses=@(@{ code='ProvisioningState/succeeded' }, @{ code="PowerState/$($pw.state[$Matches[1]])" }) } }
  if ($Method -eq 'POST' -and $Path -match 'virtualMachines/([^/]+)/deallocate\?') { $pw.state[$Matches[1]] = 'deallocating'; return [pscustomobject]@{ StatusCode=202; Content='' } }
  if ($Path -match '/sessionHosts\?') { return & $ok @{ value=@(@{ name='vdpool-avdlz-dev-demo/avdlzddemo-001'; properties=@{status='Available';allowNewSession=$true;agentVersion='1.0.9999';sessionHostHealthCheckResults=@(@{healthCheckName='DomainJoinedCheck';healthCheckResult='HealthCheckSucceeded'})} }) } }
  if ($Path -match '/runCommands/') { return & $ok @{ properties=@{ instanceView=@{executionState='Succeeded';exitCode=0} } } }
  if ($Path -match 'policyAssignments\?') { return & $ok @{ value=@(@{name='avdlz-allowed-locations';id="$S/providers/Microsoft.Authorization/policyAssignments/avdlz-allowed-locations"},@{name='avdlz-inherit-rg-tag-workload';id="$S/pa2";identity=@{principalId='44444444-0000-0000-0000-000000000000'}},@{name='someone-else';id='x'}) } }
  if ($Path -match 'budgets/' -and $Method -eq 'GET') { return [pscustomobject]@{StatusCode=404;Content=''} }
  if ($Path -match 'diagnosticSettings/' -and $Method -eq 'GET') { return & $ok @{ name='avdlz-activity-log'; properties=@{ workspaceId=$(if ($global:St.activityLogWorkspace) { $global:St.activityLogWorkspace } else { "$S/resourceGroups/rg-avdlz-dev-management/providers/Microsoft.OperationalInsights/workspaces/log-avdlz-dev" }) } } }
  # ---- Well-Architected review (Test-AvdWellArchitected). $global:St.waf.good: a production-grade
  # landing zone; otherwise the dev parameter file's trade-offs in a region without zones.
  $g = [bool]$global:St.waf.good
  # ARM leaves out empty properties: a region without zones has no availabilityZoneMappings and a
  # regional VM has no zones property (real run, lesson 0021). Don't return empty arrays here.
  if ($Path -match '^/subscriptions/[^/]+/locations\?api-version') {
    $l = @{ name='eastus2'; displayName='East US 2' }
    if ($global:St.waf.regionZones) { $l.availabilityZoneMappings = @(@{ logicalZone='1'; physicalZone='eastus2-az1' }) }
    return & $ok @{ value=@($l) }
  }
  if ($Path -match 'Microsoft.Compute/virtualMachines\?api-version') {
    $n = if ($g) { 2 } else { 1 }
    return & $ok @{ value=@(1..$n | ForEach-Object {
          $vm = @{ name="avdlzdsh-00$_"; id="$S/resourceGroups/rg-avdlz-dev-hosts/providers/Microsoft.Compute/virtualMachines/avdlzdsh-00$_"; properties=@{ hardwareProfile=@{ vmSize=$global:St.hostSize }; securityProfile=@{ securityType='TrustedLaunch'; encryptionAtHost=$true }; storageProfile=@{ osDisk=@{ managedDisk=@{ storageAccountType=$(if ($global:St.waf.standardDisk) { 'StandardSSD_LRS' } else { 'Premium_LRS' }) } } } } }
          if ($g) { $vm.zones = @("$_") }
          $vm }) }
  }
  if ($Path -match 'virtualMachines/[^/]+/extensions\?') { return & $ok @{ value=@(
        @{ name='AADLogin'; properties=@{ publisher='Microsoft.Azure.ActiveDirectory'; type='AADLoginForWindows'; provisioningState='Succeeded' } },
        @{ name='AzureMonitorAgent'; properties=@{ publisher='Microsoft.Azure.Monitor'; type='AzureMonitorWindowsAgent'; provisioningState=$(if ($global:St.waf.amaFailed) { 'Failed' } else { 'Succeeded' }) } }) } }
  if ($Path -match 'Microsoft.Network/networkInterfaces\?') { return & $ok @{ value=@(@{ name='avdlzdsh-001-nic'; properties=@{ enableAcceleratedNetworking=$true } }) } }
  if ($Path -match "storageAccounts/$saName/fileServices/default\?") { return & $ok @{ properties=@{ shareDeleteRetentionPolicy=@{ enabled=$true; days=14 } } } }
  if ($Path -match "storageAccounts/$saName\?api-version") { return & $ok @{ sku=@{ name=$(if ($g) { 'Premium_ZRS' } else { 'Premium_LRS' }) }; properties=@{ minimumTlsVersion='TLS1_2'; supportsHttpsTrafficOnly=$true; allowSharedKeyAccess=$false } } }
  if ($Path -match 'backupProtectedItems\?') { return & $ok @{ value=@(if ($g) { @{ name='AzureFileShare;profiles' } }) } }
  if ($Path -match 'Microsoft.Security/pricings\?') { return & $ok @{ value=@('VirtualMachines','StorageAccounts','KeyVaults','Containers' | ForEach-Object { @{ name=$_; properties=@{ pricingTier=$(if ($g) { 'Standard' } else { 'Free' }) } } }) } }
  if ($Path -match '/rg/kv\?api-version') { return & $ok @{ properties=@{ enablePurgeProtection=$true; enableRbacAuthorization=$true; publicNetworkAccess='Disabled' } } }
  if ($Path -match 'Microsoft.Consumption/budgets\?') { return & $ok @{ value=@(if ($g) { @{ name='budget-avdlz-prod' } }) } }
  if ($Path -match 'scalingPlans\?') { return & $ok @{ value=@(@{ name='vdscaling-avdlz-dev'; properties=@{ hostPoolReferences=@(@{ hostPoolArmPath=$hpId; scalingPlanEnabled=$true }) } }) } }
  if ($Path -match 'hostPools/vdpool-avdlz-dev/providers/Microsoft.Insights/diagnosticSettings\?') { return & $ok @{ value=@(@{ name='diag-vdpool'; properties=@{ workspaceId=$lawId } }) } }
  if ($Path -match 'workspaces/log-avdlz-dev\?api-version') { return & $ok @{ properties=@{ customerId='66666666-6666-6666-6666-666666666666'; retentionInDays=$(if ($g) { 90 } else { 30 }) } } }
  if ($Path -match 'policyStates/latest/summarize') {
    $nc = if (-not $g -and $Path -match 'rg-avdlz-dev-hosts') { 1 } else { 0 }
    return & $ok @{ value=@(@{ results=@{ nonCompliantResources=$nc }; policyAssignments=@(@{ policyAssignmentId="$S/providers/Microsoft.Authorization/policyAssignments/avdlz-guest-attestation"; results=@{ nonCompliantResources=$nc } }) }) }
  }
  # Two pages (nextLink), and an unhealthy assessment outside the landing zone that must be ignored.
  if ($Path -match 'Microsoft.Security/assessments\?') {
    if ($Path -notmatch 'skipToken') {
      return & $ok @{ nextLink="https://management.azure.com$S/providers/Microsoft.Security/assessments?api-version=2021-06-01&`$skipToken=page2"; value=@(
          @{ id="$S/resourceGroups/rg-other/providers/Microsoft.Compute/virtualMachines/vm1/providers/Microsoft.Security/assessments/a1"; properties=@{ displayName='Other workload'; status=@{ code='Unhealthy' }; metadata=@{ severity='High' } } },
          @{ id="$saId/providers/Microsoft.Security/assessments/a2"; properties=@{ displayName='Storage healthy'; status=@{ code='Healthy' }; metadata=@{ severity='Low' } } }) }
    }
    return & $ok @{ value=@(if (-not $g) { @{ id="$S/resourceGroups/rg-avdlz-dev-hosts/providers/Microsoft.Compute/virtualMachines/avdlzdsh-001/providers/Microsoft.Security/assessments/a3"; properties=@{ displayName='Machines should have vulnerability findings resolved'; status=@{ code='Unhealthy' }; metadata=@{ severity='Medium' } } } }) }
  }
  # Advisor returns resource IDs in any case; one recommendation is for another workload.
  if ($Path -match 'Microsoft.Advisor/recommendations\?') {
    return & $ok @{ value=@(
        @{ id='r1'; properties=@{ category='Cost'; impact='High'; shortDescription=@{ problem='Right-size underused VM' }; resourceMetadata=@{ resourceId="/subscriptions/$sub/resourcegroups/rg-other/providers/microsoft.compute/virtualmachines/vm1" } } }
        if (-not $g) { @{ id='r2'; properties=@{ category='HighAvailability'; impact='Medium'; shortDescription=@{ problem='Use availability zones for better resiliency' }; resourceMetadata=@{ resourceId="/subscriptions/$sub/resourcegroups/RG-AVDLZ-DEV-HOSTS/providers/Microsoft.Compute/virtualMachines/avdlzdsh-001" } } } }) }
  }
  return & $ok @{}
}
function Get-AzRoleAssignment { param($Scope,$RoleDefinitionName,$ObjectId,$ObjectType,[switch]$ExpandPrincipalGroups,$ErrorAction)
  if ($Scope -and $ExpandPrincipalGroups) { throw 'Parameter set cannot be resolved using the specified named parameters. One or more parameters issued cannot be used together or an insufficient number of parameters were provided.' }
  $all = @(
    [pscustomobject]@{Scope=$agId;RoleDefinitionName='Desktop Virtualization User';ObjectId=$users;ObjectType='Group'}
    [pscustomobject]@{Scope="$S/resourceGroups/rg-avdlz-dev-avd";RoleDefinitionName='Desktop Virtualization Power On Off Contributor';ObjectId=$avdsp;ObjectType='ServicePrincipal'}
    [pscustomobject]@{Scope="$S/resourceGroups/rg-avdlz-dev-hosts";RoleDefinitionName='Virtual Machine Administrator Login';ObjectId=$admins;ObjectType='Group'}
    [pscustomobject]@{Scope=$saId;RoleDefinitionName='Storage File Data SMB Share Contributor';ObjectId=$users;ObjectType='Group'}
    [pscustomobject]@{Scope=$S;RoleDefinitionName='Owner';ObjectId='me';ObjectType='User'}
    [pscustomobject]@{Scope="$S/resourceGroups/rg-avdlz-dev-demo/providers/Microsoft.DesktopVirtualization/applicationGroups/vdag-avdlz-dev-demo-desktop";RoleDefinitionName='Desktop Virtualization User';ObjectId=$users;ObjectType='Group'}
    [pscustomobject]@{Scope="$S/resourceGroups/rg-avdlz-dev-demo";RoleDefinitionName='Virtual Machine User Login';ObjectId=$users;ObjectType='Group'}
  ) + $global:St.roleAssignments
  $all | ? { (-not $RoleDefinitionName -or $_.RoleDefinitionName -eq $RoleDefinitionName) -and (-not $ObjectId -or $_.ObjectId -eq $ObjectId) -and (-not $Scope -or $Scope.StartsWith($_.Scope) -or $_.Scope -eq $Scope) }
}
function New-AzRoleAssignment { param($ObjectId,$ObjectType,$RoleDefinitionName,$Scope,$ErrorAction) Log "RBAC + $RoleDefinitionName $ObjectId"; $global:St.roleAssignments += [pscustomobject]@{Scope=$Scope;RoleDefinitionName=$RoleDefinitionName;ObjectId=$ObjectId;ObjectType=$ObjectType} }
function Remove-AzRoleAssignment { param($ObjectId,$RoleDefinitionName,$Scope,$InputObject,$ErrorAction) Log "RBAC - $RoleDefinitionName $ObjectId $($InputObject.ObjectId)"; $global:St.roleAssignments = @($global:St.roleAssignments | ? { $_.ObjectId -ne $ObjectId }) }
function Get-AzAccessToken { param($ResourceUrl,$ErrorAction) [pscustomobject]@{ Token = (ConvertTo-SecureString 'cs-token' -AsPlainText -Force) } }
function Get-AzADUser { param([switch]$SignedIn,$ErrorAction) [pscustomobject]@{Id='me';UserPrincipalName='admin@contoso.com'} }
$global:St.registered = @()
$global:St.unregistered = @('Microsoft.GuestConfiguration')
$global:St.skuZones = @('1','2','3')
$global:St.hostSize = 'Standard_D4as_v5'
$global:St.power = @{ startVMOnConnect = $true; hpTags = @{ workload = 'avd' }; sessions = @{ 'avdlzdsh-001' = 2; 'avdlzdsh-002' = 0 }
  allowNew = @{ 'avdlzdsh-001' = $true; 'avdlzdsh-002' = $true }; state = @{ 'avdlzdsh-001' = 'running'; 'avdlzdsh-002' = 'running' }; vmTags = @{}; failHostPoolPatch = $false }
$global:St.deletedVaults = @()
$global:St.images = @{ definition = $true; runOutcome = 'Succeeded'; deployFails = $false; logUnreadable = $false; deployed = @(); deleted = @()
  # Compared as numbers, 26100.10000 is newer than 26100.6725; as strings it isn't.
  sourceVersions = @('26100.6584.250910', '26100.10000.251104', '26100.6725.251007')
  versions = @(@{ name = '2026.915.1'; state = 'Succeeded'; tags = @{ 'avdlz-source-image' = 'MicrosoftWindowsDesktop/office-365/win11-24h2-avd-m365/26100.6584.250910'; 'avdlz-commit' = 'c0ffee1' } })
  templates = @{ 'it-avdlz-2026-901-1' = @{ created = (Get-Date).ToUniversalTime().AddDays(-2).ToString('o'); state = $null; polls = 0 } }
  log = @('[PowerShell] golden-image: RESULT os-release Pass DisplayVersion=24H2', '[PowerShell] golden-image: RESULT wdot Pass result=Succeeded', '[PowerShell] golden-image: RESULT protected-services Pass disabled= absent= checked=20') }
$global:St.groups = @(@{id='11111111-1111-1111-1111-111111111111';displayName='AVD Users';securityEnabled=$true},@{id='22222222-2222-2222-2222-222222222222';displayName='AVD Admins';securityEnabled=$true})
$global:St.avdSp = $true
function Get-AzResourceProvider { param($ProviderNamespace,$ErrorAction) [pscustomobject]@{RegistrationState=$(if ($global:St.unregistered -contains $ProviderNamespace -and $global:St.registered -notcontains $ProviderNamespace) {'NotRegistered'} else {'Registered'})} }
function Register-AzResourceProvider { param($ProviderNamespace) Log "register $ProviderNamespace"; $global:St.registered += $ProviderNamespace }
function Get-AzProviderFeature { param($ProviderNamespace,$FeatureName,$ErrorAction) [pscustomobject]@{RegistrationState='Registered'} }
function Register-AzProviderFeature { param($ProviderNamespace,$FeatureName) }
function Get-AzComputeResourceSku { param($Location,$ErrorAction)
  foreach ($series in @(@('D', 'standardDASv5Family', 4), @('E', 'standardEASv5Family', 8))) {
    foreach ($v in 4, 8, 16) {
      [pscustomobject]@{ResourceType='virtualMachines';Name="Standard_$($series[0])$($v)as_v5";Family=$series[1];Restrictions=@();LocationInfo=@([pscustomobject]@{Location=$Location;Zones=$global:St.skuZones})
        Capabilities=@([pscustomobject]@{Name='vCPUs';Value="$v"},[pscustomobject]@{Name='MemoryGB';Value="$($v * $series[2])"})}
    }
  }
  # The golden image build VM (bicep/images/build.bicep).
  [pscustomobject]@{ResourceType='virtualMachines';Name='Standard_D4s_v5';Family='standardDSv5Family';Restrictions=@();LocationInfo=@([pscustomobject]@{Location=$Location;Zones=$global:St.skuZones})
    Capabilities=@([pscustomobject]@{Name='vCPUs';Value='4'},[pscustomobject]@{Name='MemoryGB';Value='16'})} }
$global:St.quotaLimit = $null   # set to raise both limits (a subscription after a quota increase)
# The deployed dev host is a D4as_v5 (as in the first real deployment); the Easv5 family is unused.
function Get-AzVMUsage { param($Location) $l = $global:St.quotaLimit; @(
    [pscustomobject]@{Name=[pscustomobject]@{Value='standardDASv5Family'};Limit=$(if ($l) { $l } else { 10 });CurrentValue=4},
    [pscustomobject]@{Name=[pscustomobject]@{Value='standardEASv5Family'};Limit=$(if ($global:St.eLimit) { $global:St.eLimit } elseif ($l) { $l } else { 10 });CurrentValue=$(if ($global:St.eUsed) { $global:St.eUsed } else { 0 })},
    [pscustomobject]@{Name=[pscustomobject]@{Value='standardDSv5Family'};Limit=$(if ($null -ne $global:St.dsLimit) { $global:St.dsLimit } else { 10 });CurrentValue=0},
    [pscustomobject]@{Name=[pscustomobject]@{Value='cores'};Limit=$(if ($l) { $l } else { 20 });CurrentValue=4}) }
# Az.Storage, as Start-AvdImageBuild.ps1 reads AIB's customization log with the signed-in identity.
function New-AzStorageContext { param($StorageAccountName,[switch]$UseConnectedAccount) [pscustomobject]@{ StorageAccountName=$StorageAccountName } }
function Get-AzStorageBlob { param($Container,$Context,$ErrorAction)
  if ($global:St.images.logUnreadable) { throw 'This request is not authorized to perform this operation using this permission. (403)' }
  [pscustomobject]@{ Name='0b1c/customization.log'; LastModified=(Get-Date) } }
function Get-AzStorageBlobContent { param($Container,$Blob,$Destination,$Context,[switch]$Force) Set-Content -Path $Destination -Value $global:St.images.log; [pscustomobject]@{ Name=$Blob } }
function Get-AzVM { param($ResourceGroupName,$Name,[switch]$Status,$ErrorAction)
  $n = if ($ResourceGroupName -like '*demo') {'avdlzddemo-001'} else {'avdlzdsh-001'}
  $vm=[pscustomobject]@{Name=$n;HardwareProfile=[pscustomobject]@{VmSize=$global:St.hostSize};Id="$S/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$n";Identity=[pscustomobject]@{PrincipalId="mi-$n"};PowerState='VM running';OSProfile=[pscustomobject]@{ComputerName=$n}}
  if ($global:St.rgs -contains $ResourceGroupName) { if (-not $Name -or $Name -eq $n) { $vm } }
}
function Start-AzVM { param($ResourceGroupName,$Name) Log "start $Name" }
function Stop-AzVM { param($ResourceGroupName,$Name,[switch]$Force) Log "stop $Name" }
function Invoke-AzVMRunCommand { param($ResourceGroupName,$VMName,$CommandId,$ScriptString,$Parameter,$ErrorAction)
  Log "runcmd $VMName $(if ($ScriptString -match 'filepermission') {'acl'} else {'diag'}) apply=$($Parameter.Apply)"
  if ($ScriptString -match 'filepermission') {
    if ($global:St.forbiddenOnce) { $global:St.forbiddenOnce=$false; $o=@{status='Forbidden';httpStatus=403} }
    elseif ($Parameter.Apply -eq 'true') { $global:St.aclApplied=$true; $sddl=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Parameter.DesiredSddlBase64)); $o=@{status='ok';before='x';after=$sddl} }
    elseif ($global:St.aclApplied) { $o=@{status='ok';before=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Parameter.DesiredSddlBase64))} }
    elseif ($global:St.defaultRoot) { $o=@{status='ok';before=$null;defaultAcl=$true} }
    else { $o=@{status='ok';before='O:SYG:SYD:(A;OICIIO;GA;;;CO)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1301bf;;;AU)(A;OICI;0x1200a9;;;BU)'} }
  } else { $o=@{entraJoined=$true;intuneEnrolled=$true;agentRegistered=$true;bootLoaderRunning=$true;fslogixServiceRunning=$true;fslogixEnabled=$true;fslogixPointsAtShare=$true;cloudKerberosEnabled=$true;loadCredKeyFromProfile=$true;storageIp='10.100.2.4';storageIpPrivate=$true;smbReachable=$true} }
  [pscustomobject]@{ Value=@([pscustomobject]@{Code='ComponentStatus/StdOut/succeeded';Message=('<<<AVDJSON'+($o|ConvertTo-Json -Compress)+'AVDJSON>>>')},[pscustomobject]@{Code='ComponentStatus/StdErr/succeeded';Message=''}) }
}
function New-AzSubscriptionDeployment { param($Name,$Location,$TemplateFile,$TemplateParameterObject,$ErrorAction)
  Log "deploy $Name pwType=$($TemplateParameterObject.localAdminPassword.GetType().Name) dns=$($TemplateParameterObject.avdPrivateDnsZoneResourceId -split '/' | select -last 1)"
  foreach ($k in 'sessionHostSubnetResourceId','usersGroupObjectId','avdServicePrincipalObjectId','profileShareUncPath') { if (-not $TemplateParameterObject[$k]) { throw "missing $k" } }
  $global:St.rgs += 'rg-avdlz-dev-demo'
  $v = { param($x) [pscustomobject]@{Value=$x} }
  [pscustomobject]@{ProvisioningState='Succeeded';Outputs=@{resourceGroupName=(& $v 'rg-avdlz-dev-demo');hostPoolResourceId=(& $v "$S/resourceGroups/rg-avdlz-dev-demo/providers/Microsoft.DesktopVirtualization/hostPools/vdpool-avdlz-dev-demo");hostPoolName=(& $v 'vdpool-avdlz-dev-demo');appGroupResourceId=(& $v "$S/resourceGroups/rg-avdlz-dev-demo/providers/Microsoft.DesktopVirtualization/applicationGroups/vdag-avdlz-dev-demo-desktop");workspaceResourceId=(& $v 'ws');sessionHostNames=(& $v @('avdlzddemo-001'))}}
}
# Subscription deployment records ($global:St.deployments; default: one landing zone's).
function Get-AzDeployment { param($Name,$ErrorAction)
  $names = if ($null -ne $global:St.deployments) { $global:St.deployments } else { @('avdlz-governance-avdlz-dev-eastus2', 'avdlz-dev-20260929-101500') }
  if ($Name) { [pscustomobject]@{DeploymentName=$Name} } else { @($names | ForEach-Object { [pscustomobject]@{DeploymentName=$_} }) } }
function Remove-AzDeployment { param($Name) Log "del deployment $Name"; if ($null -ne $global:St.deployments) { $global:St.deployments = @($global:St.deployments | Where-Object { $_ -ne $Name }) } }
# Deleting the storage resource group deletes the storage account, which moves its Entra Kerberos app
# and service principal to Entra's deleted items (as on 2026-09-29/30), still named after the account.
function Remove-AzResourceGroup { param($Name,[switch]$Force) Log "del rg $Name"; $global:St.rgs = @($global:St.rgs | ? { $_ -ne $Name })
  if ($Name -like 'rg-*-storage') {
    $n = "[Storage Account] $saName.file.core.windows.net"
    $global:St.deletedItems = @($global:St.deletedItems) + @(@{ id = "del-app-$Name"; type = 'application'; displayName = $n }, @{ id = "del-sp-$Name"; type = 'servicePrincipal'; displayName = $n }) | Where-Object { $_ }
  } }
function Get-AzRecoveryServicesVault { param($ResourceGroupName,$Name) [pscustomobject]@{Name=$Name;ResourceGroupName=$ResourceGroupName;ID="$S/rsv"} }
function Update-AzRecoveryServicesVault { param($ResourceGroupName,$Name,$ImmutabilityState) Log "rsv immutability $ImmutabilityState" }
function Set-AzRecoveryServicesVaultProperty { param($VaultId,$SoftDeleteFeatureState) Log "rsv softdelete $SoftDeleteFeatureState" }
function Get-AzRecoveryServicesBackupItem { param($BackupManagementType,$WorkloadType,$VaultId) @([pscustomobject]@{Name='AzureFileShare;profiles'}) }
function Disable-AzRecoveryServicesBackupProtection { param($Item,[switch]$RemoveRecoveryPoints,$VaultId,[switch]$Force) Log "backup disable $($Item.Name) remove=$RemoveRecoveryPoints" }
function Get-AzRecoveryServicesBackupContainer { param($ContainerType,$VaultId) @([pscustomobject]@{Name='storagecontainer'}) }
function Unregister-AzRecoveryServicesBackupContainer { param($Container,$VaultId,[switch]$Force) Log 'backup unregister' }
function Get-AzResourceLock { param($Scope,$ErrorAction) @([pscustomobject]@{Name='AzureBackupProtectionLock';LockId='lock1'}) }
function Remove-AzResourceLock { param($LockId,[switch]$Force) Log "unlock $LockId" }
function Start-Sleep { param($Seconds) }
# PSRule for Azure (Get-AvdPSRuleFinding). Record shape: RuleName, TargetName, Tag['Azure.WAF/pillar'].
$global:St.waf = @{ good = $false; regionZones = $false }
function Export-AzRuleData { [CmdletBinding()] param([string[]]$ResourceGroupName,$OutputPath)
  Log "psrule export $($ResourceGroupName -join ',')"; New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
  # As in a real run: optional lookups fail with warnings.
  Write-Warning "Failed to get 'https://management.azure.com//subscriptions/x/providers/Microsoft.Authorization/classicAdministrators?api-version=2015-07-01': status=404" }
function Invoke-PSRule { param($InputPath,$Module,$Outcome,$Path,$WarningAction,$ErrorAction)
  Log "psrule invoke outcome=$Outcome suppressions=$([bool]$Path)"
  if ($global:St.waf.good) { return }
  [pscustomobject]@{ RuleName='Azure.VM.UseHybridUseBenefit'; TargetName='avdlzdsh-001'; Tag=@{ 'Azure.WAF/pillar'='Cost Optimization' }; Reason=@('The field ''properties.licenseType'' does not exist.') }
  [pscustomobject]@{ RuleName='Azure.Storage.ContainerSoftDelete'; TargetName=$saName; Tag=@{ 'Azure.WAF/pillar'='Reliability' }; Reason=$null }
  # Live run: PSRule's export doesn't attach VM extensions, so this fails although the agent is installed.
  [pscustomobject]@{ RuleName='Azure.VM.AMA'; TargetName='avdlzdsh-001'; Tag=@{ 'Azure.WAF/pillar'='Operational Excellence' }; Reason=@('The virtual machine does not have Azure Monitor Agent installed.') }
}

# ---- Azure Retail Prices API (Get-AvdRetailPrice). Prices here are placeholders for tests, not real
# list prices. Shapes follow the public API: Items, NextPageLink; one VM query spans two pages.
$global:St.pricesDown = $false
function Invoke-RestMethod { param($Uri,$Method,$Headers,$Body,$ContentType,$ErrorAction)
  # The Automation managed identity endpoint (IDENTITY_ENDPOINT) and ARM, as the power runbook calls them.
  if ($Uri -like 'http://127.0.0.1:42/msi/token*') { if ($Headers['X-IDENTITY-HEADER'] -ne 'test-header') { throw 'missing X-IDENTITY-HEADER' }; return [pscustomobject]@{ access_token='mi-token' } }
  if ($Uri -match '^https://management\.azure\.com(/.*)$') {
    $armPath = $Matches[1]
    if ($Headers.Authorization -notin 'Bearer mi-token', 'Bearer cs-token') { throw "no bearer token for $Uri" }
    $r = Invoke-AzRestMethod -Path $armPath -Method $Method -Payload $Body
    if ($r.StatusCode -ge 400) {
      # As Invoke-RestMethod in PowerShell 7: the body in ErrorDetails.
      $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new("Response status code does not indicate success: $($r.StatusCode)."), 'HttpError', 'InvalidOperation', $null)
      $e.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($r.Content); throw $e
    }
    if ($r.Content) { return ($r.Content | ConvertFrom-Json) } else { return }
  }
  # ---- Log Analytics query API (Invoke-AvdLogQuery, Test-AvdUserConnection.ps1). Each call takes the
  # next response from $global:St.logPolls (the last one repeats): rows of user-connection.kql, or
  # @{ status = 403 } for an error. Shape from the API spec: tables[].columns[{name,type}], rows[[...]];
  # dynamic columns (Errors, Checkpoints) come back as JSON strings, and ARM-style empty values as null.
  if ($Uri -match '^https://api\.loganalytics\.io/v1/workspaces/([^/]+)/query$') {
    if ($Headers.Authorization -ne 'Bearer cs-token') { throw "no bearer token for $Uri" }
    $q = ($Body | ConvertFrom-Json).query
    Log "LAQUERY $($Matches[1]) $(if ($q -match "let upn = '([^']+)'") { $Matches[1] }) $(if ($q -match "let rg = '([^']+)'") { $Matches[1] })"
    $global:St.logQueries++
    $polls = @($global:St.logPolls)
    $resp = if ($polls.Count) { $polls[[math]::Min($global:St.logQueries, $polls.Count) - 1] } else { @() }
    if ($resp -is [hashtable] -and $resp.status) {
      $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new("Response status code does not indicate success: $($resp.status) (Forbidden)."), 'HttpError', 'InvalidOperation', $null)
      $e.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"message":"The provided credentials have insufficient access to perform the requested operation","code":"InsufficientAccessError"}}'); throw $e
    }
    $cols = 'CorrelationId','StartedAt','ConnectedAt','CompletedAt','ConnectionSetupSeconds','SessionHost','ClientType','ClientOS','GatewayRegion','TransportType','Errors','Checkpoints','FirstErrorAt'
    $rows = @(@($resp) | Where-Object { $_ } | ForEach-Object { $r = $_; ,@($cols | ForEach-Object { $v = $r[$_]; if ($_ -in 'Errors','Checkpoints' -and $null -ne $v) { ConvertTo-Json -InputObject @($v) -Compress -Depth 5 } else { $v } }) })
    return [pscustomobject]@{ tables = @([pscustomobject]@{ name = 'PrimaryResult'; columns = @($cols | ForEach-Object { [pscustomobject]@{ name = $_; type = 'string' } }); rows = $rows }) }
  }
  if ($Uri -notmatch '^https://prices\.azure\.com/api/retail/prices') { throw "unmocked REST $Uri" }
  Log "PRICE $Uri"
  if ($global:St.pricesDown) { throw 'Response status code does not indicate success: 503 (Service Unavailable).' }
  $f = [uri]::UnescapeDataString(($Uri -split '\$filter=')[1])
  $it = { param($product,$sku,$meter,$unit,$price,$tier=0) [pscustomobject]@{currencyCode='USD';productName=$product;skuName=$sku;meterName=$meter;unitOfMeasure=$unit;retailPrice=$price;tierMinimumUnits=$tier;type='Consumption'} }
  $items = switch -Regex ($f) {
    "serviceName eq 'Virtual Machines'.*armSkuName eq '(Standard_([DE])(\d+)as_v5)'" {
      $v = [int]$Matches[3] * $(if ($Matches[2] -eq 'E') { 1.3 } else { 1 }); $n = $Matches[1] -replace 'Standard_' -replace '_', ' '
      if ($Uri -notmatch 'page=2') {
        return [pscustomobject]@{ Items=@((& $it "Virtual Machines Asv5 Series Windows" $n $n '1 Hour' (0.2 * $v)), (& $it "Virtual Machines Asv5 Series" "$n Spot" "$n Spot" '1 Hour' (0.01 * $v))); NextPageLink="$Uri&page=2" }
      }
      # As the real API returns since 2026: a CloudServices product with the same SKU name at the Windows rate.
      @((& $it "Virtual Machines Asv5 Series" $n $n '1 Hour' (0.1 * $v)), (& $it "Virtual Machines Asv5 Series" "$n Low Priority" "$n Low Priority" '1 Hour' (0.02 * $v)),
        (& $it "Asv5 Series CloudServices" $n $n '1 Hour' (0.2 * $v)))
    }
    # The real API also returns a 'Premium Page Blob' meter named 'P10 LRS Disk' (priced differently here to tell them apart).
    "skuName eq 'P10 LRS'" { @((& $it 'Premium SSD Managed Disks' 'P10 LRS' 'P10 LRS Disk' '1/Month' 20), (& $it 'Premium SSD Managed Disks' 'P10 LRS' 'P10 LRS Disk Mount' '1/Month' 1), (& $it 'Premium Page Blob' 'P10 LRS' 'P10 LRS Disk' '1/Month' 25)) }
    "productName eq 'Premium Files'" { @((& $it 'Premium Files' 'Premium LRS' 'LRS Provisioned' '1 GiB/Month' 0.2), (& $it 'Premium Files' 'Premium ZRS' 'ZRS Provisioned' '1 GiB/Month' 0.25), (& $it 'Premium Files' 'Premium LRS' 'LRS Snapshots' '1 GiB/Month' 0.1)) }
    # As the real API lists them (2026-10-05): only under armRegionName 'Global', never per region, next to lookalike hourly meters.
    "productName eq 'Virtual Network Private Link' and armRegionName eq 'Global'" { @((& $it 'Virtual Network Private Link' 'Standard' 'Standard Private Endpoint' '1 Hour' 0.01), (& $it 'Virtual Network Private Link' 'Fixed Private Endpoint T1' 'Fixed Private Endpoint T1' '1 Hour' 14), (& $it 'Virtual Network Private Link' 'Standard Service Endpoint' 'Standard Service Endpoint Virtual Network' '1 Hour' 0.1), (& $it 'Virtual Network Private Link' 'Standard' 'Standard Data Processed - Ingress' '1 GB' 0.01)) }
    "productName eq 'NAT Gateway' and armRegionName eq 'Global'" { @((& $it 'NAT Gateway' 'Standard' 'Standard Gateway' '1 Hour' 0.05), (& $it 'NAT Gateway' 'Standard' 'Standard Data Processed' '1 GB' 0.05), (& $it 'NAT Gateway' 'StandardV2' 'StandardV2 Log Enabled' '1/Month' 4)) }
    # As if the API named the meter differently: the estimate must say so, not guess.
    "productName eq 'IP Addresses'" { if ($global:St.ipMeterRenamed) { @((& $it 'IP Addresses' 'Standard' 'Standard IPv4 Public Address' '1 Hour' 0.005)) } else { @((& $it 'IP Addresses' 'Standard' 'Standard IPv4 Static Public IP' '1 Hour' 0.005)) } }
    default { @() }
  }
  [pscustomobject]@{ Items=@($items); NextPageLink=$null }
}

# ---- Graph ----
function Get-MgContext { $global:MgCtx }
function Connect-MgGraph { param($Scopes,$TenantId,[switch]$NoWelcome,[switch]$UseDeviceCode,$ErrorAction) $global:MgCtx=[pscustomobject]@{TenantId=$TenantId;Scopes=$Scopes}; Log "graph connect $($Scopes -join ' ')"; if ($UseDeviceCode) { Write-Output 'To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code ABCD-1234 to authenticate.' } }
function Invoke-MgGraphRequest { param($Method,$Uri,$Body,$ContentType,$OutputType,$ErrorAction)
  $u=[uri]::UnescapeDataString($Uri); Log "GRAPH $Method $u"
  $b = if ($Body) { $Body | ConvertFrom-Json } else { $null }
  $appId='55555555-5555-5555-5555-555555555555'
  if ($Method -eq 'POST' -and $u -match 'oauth2PermissionGrants$') { $global:St.grants += $b; return $b }
  if ($Method -eq 'PATCH' -and $u -match 'applications/') { $global:St.tags=$b.tags; return $null }
  if ($Method -eq 'PATCH' -and $u -match 'conditionalAccess/policies/') { $global:St.caExclude=$b.conditions.applications.excludeApplications; return $null }
  if ($Method -eq 'POST' -and $u -match 'v1.0/groups$') { $g=@{id=[guid]::NewGuid().ToString();displayName=$b.displayName;securityEnabled=$true}; $global:St.groups += $g; return [pscustomobject]$g }
  if ($Method -eq 'POST' -and $u -match 'v1.0/servicePrincipals$') { $global:St.avdSp=$true; return [pscustomobject]@{id='33333333-3333-3333-3333-333333333333';appId=$b.appId} }
  if ($Method -eq 'POST' -and $u -match 'checkMemberGroups') { return [pscustomobject]@{value=@($users)} }
  if ($Method -eq 'DELETE' -and $u -match 'directory/deletedItems/(.+)$') {
    $id = $Matches[1]; $item = @($global:St.deletedItems) | Where-Object { $_.id -eq $id }
    if (-not $item) { throw "Response status code does not indicate success: 404 (Not Found). Request_ResourceNotFound: $id does not exist." }
    # Purging an app takes its service principal with it, as Entra does.
    $global:St.deletedItems = @(@($global:St.deletedItems) | Where-Object { $_.id -ne $id -and -not ($item.type -eq 'application' -and $_.type -eq 'servicePrincipal' -and $_.displayName -eq $item.displayName) })
    return $null
  }
  if ($Method -eq 'DELETE') { return $null }
  $r = switch -Regex ($u) {
    'groups/[0-9a-f-]+/members' { @{value=@(@{id='u1'})} }
    "groups\?.*displayName eq '([^']+)'" { $n=$Matches[1]; @{value=@($global:St.groups | ? { $_.displayName -eq $n })} }
    "servicePrincipals\?.*appId eq '9cdead84" { @{value=@(if ($global:St.avdSp) { @{id='33333333-3333-3333-3333-333333333333';appId='9cdead84-a844-4324-93f2-b2e6bb768d07'} })} }
    'me/memberOf' { @{value=@(@{displayName='Global Administrator'})} }
    'groups/(\w{8}-[\w-]+)\?' { @{id=$Matches[1];displayName="grp-$($Matches[1].Substring(0,4))";onPremisesSecurityIdentifier=$null} }
    'subscribedSkus' { @{value=@(@{servicePlans=@(@{servicePlanName='INTUNE_A';provisioningStatus='Success'})})} }
    '^v1.0/applications\?' { @{value=@(@{id='app-obj';appId=$appId;displayName='[Storage Account] x';tags=$global:St.tags;requiredResourceAccess=@(@{resourceAppId='00000003-0000-0000-c000-000000000000';resourceAccess=@(@{id='s1';type='Scope'},@{id='s2';type='Scope'},@{id='s3';type='Scope'})})})} }
    "servicePrincipals\?.*appId eq '00000003" { @{value=@(@{id='graph-sp';oauth2PermissionScopes=@(@{id='s1';value='openid'},@{id='s2';value='profile'},@{id='s3';value='User.Read'})})} }
    "servicePrincipals\?(?!.*(9cdead84|00000003))" { @{value=@(@{id='storage-sp';appId=$appId})} }
    'oauth2PermissionGrants\?' { @{value=@($global:St.grants)} }
    'policies/identitySecurityDefaultsEnforcementPolicy' { @{isEnabled=[bool]$global:St.securityDefaults} }
    'conditionalAccess/policies' { @{value=@(
        @{id='p1';displayName='Require MFA for all users';state='enabled';conditions=@{applications=@{includeApplications=@('All');excludeApplications=@($global:St.caExclude)};users=@{includeUsers=@('All');includeGroups=@()}};grantControls=@{builtInControls=@('mfa')}},
        @{id='p2';displayName='Block legacy auth';state='enabled';conditions=@{applications=@{includeApplications=@('All');excludeApplications=@()};users=@{includeUsers=@('All')}};grantControls=@{builtInControls=@('block')}},
        @{id='p3';displayName='Admins MFA';state='enabled';conditions=@{applications=@{includeApplications=@('All');excludeApplications=@()};users=@{includeUsers=@();includeRoles=@('62e90394')}};grantControls=@{builtInControls=@('mfa')}}
      )} }
    'users/' { @{id='u1';accountEnabled=$true;assignedLicenses=@(@{skuId='x'});userPrincipalName='alex@contoso.com'} }
    "directory/deletedItems/microsoft\.graph\.(application|servicePrincipal)\?.*displayName eq '([^']+)'" { $t=$Matches[1]; $n=$Matches[2]; @{value=@(@($global:St.deletedItems) | ? { $_.type -eq $t -and $_.displayName -eq $n } | % { @{id=$_.id;displayName=$_.displayName} })} }
    'managedDevices\?' { @{value=@(@{id='md1';deviceName='x'})} }
    'devices\?' { @{value=@(@{id='d1';displayName='x'})} }
    default { throw "unmocked graph $u" }
  }
  return ($r | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}
Export-ModuleMember -Function *
