# Offline stand-in for the Az, ARM (Invoke-AzRestMethod) and Microsoft Graph calls the
# ops scripts make. State lives in $global:St; every state-changing call is logged in
# $global:Calls. Used by build/tests/offline/*.Scenario.ps1 (run by build/tests/OfflineScenarios.Tests.ps1).
# When a real run exposes a behavior this mock gets wrong, fix the mock AND add the case.

# ---- State ----
$global:Calls = [System.Collections.Generic.List[string]]::new()
function Log($s){ $global:Calls.Add($s) }
$sub='00000000-aaaa-bbbb-cccc-000000000001'; $S="/subscriptions/$sub"
$base='avdlz-dev'
$global:St = @{
  grants = @(); tags=@(); caExclude=@(); securityDefaults=$false; aclApplied=$false; forbiddenOnce=$true; roleAssignments=@()
  swaHost='nice-sea-0a1b2c3d4.azurestaticapps.net'; swaToken='not-a-real-swa-token'; swaTokenResets=0; webBlobs=@{}
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
function Invoke-AzRestMethod { param($Path,$Method,$Payload,$ErrorAction,$Uri)
  if ($Uri) { $Path = "$Uri" }
  Log "ARM $Method $Path"
  $ok = { param($o) [pscustomobject]@{StatusCode=200;Content=($o|ConvertTo-Json -Depth 20)} }
  # ---- Sandbox spend (AvdSpend.psm1, docs/sandbox-runs.md). Only when $global:St.spend is set:
  # inventoryFile (a JSON array of Resource Graph rows; the scenario's item scripts write it, so a
  # deploy adds resources and a teardown removes them), monthToDate (this month's cost), budgets.
  $sp = $global:St.spend
  if ($sp) {
    if ($Method -eq 'POST' -and $Path -match '^/providers/Microsoft.ResourceGraph/resources\?') {
      $rows = @(if ($sp.inventoryFile -and (Test-Path $sp.inventoryFile)) { Get-Content $sp.inventoryFile -Raw | ConvertFrom-Json | ForEach-Object { $_ } })
      return & $ok @{ totalRecords=$rows.Count; count=$rows.Count; data=@($rows) } }
    if ($Method -eq 'POST' -and $Path -match '/providers/Microsoft.CostManagement/query\?') {
      return & $ok @{ properties=@{ columns=@(@{ name='Cost'; type='Number' }, @{ name='Currency'; type='String' }); rows=@(,@([double]$sp.monthToDate, 'USD')) } } }
    if ($Path -match 'Microsoft.Consumption/budgets\?') { return & $ok @{ value=@($sp.budgets | Where-Object { $_ }) } }
    # Health before spend (Test-AvdSandboxHealth.ps1): permissions (default: everything), devices
    # (Entra devices: @{ displayName }), graphStatus (a Graph failure), runStore (the account exists).
    if ($Path -match '/providers/Microsoft.Authorization/permissions\?') { return & $ok @{ value=@($(if ($sp.ContainsKey('permissions')) { $sp.permissions } else { @{ actions=@('*') } })) } }
    if ($Path -match '^https://graph\.microsoft\.com/v1\.0/devices\?.*startswith\(displayName,''([^'']+)''\)') {
      if ($sp.graphStatus) { return [pscustomobject]@{ StatusCode=$sp.graphStatus; Content='{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation."}}' } }
      $p = $Matches[1]; return & $ok @{ value=@($sp.devices | Where-Object { $_ -and $_.displayName -like "$p*" }) } }
    # Deadline teardown (decision 0021). $sp.automation: the run store's Automation account, @{ runbook = 'Published' or $null;
    # schedules; jobSchedules; failPut }. The runbook's own calls: resource groups listed and deleted, and VMs, from the
    # same inventory file (a delete takes the group and everything in it out of the inventory).
    $aa = $sp.automation
    if ($aa -and $Path -match '/resourceGroups/avdlz-runs-rg/providers/Microsoft.Automation/automationAccounts/aa-avdlz-runs/(runbooks|schedules|jobSchedules)/([^/?]+)\?') {
      $kind = $Matches[1]; $name = $Matches[2]
      if ($kind -eq 'runbooks') { if ($aa.runbook) { return & $ok @{ name = $name; properties = @{ state = $aa.runbook } } } else { return [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"NotFound","message":"The Runbook was not found."}}' } } }
      $bag = $aa[$kind]
      if ($Method -eq 'DELETE') { if ($bag.ContainsKey($name)) { $bag.Remove($name); return & $ok @{} } else { return [pscustomobject]@{ StatusCode=404; Content='' } } }
      if ($Method -eq 'PUT') {
        if ($aa.failPut) { return [pscustomobject]@{ StatusCode=400; Content='{"error":{"code":"BadRequest","message":"The start time of the schedule must be at least 5 minutes after the time you create the schedule."}}' } }
        if ($kind -eq 'jobSchedules' -and -not $aa.schedules.ContainsKey(($Payload | ConvertFrom-Json).properties.schedule.name)) { return [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"NotFound","message":"The schedule was not found."}}' } }
        $bag[$name] = ($Payload | ConvertFrom-Json); return [pscustomobject]@{ StatusCode=201; Content=$Payload }
      }
    }
    $rows = { @(if ($sp.inventoryFile -and (Test-Path $sp.inventoryFile)) { Get-Content $sp.inventoryFile -Raw | ConvertFrom-Json | ForEach-Object { $_ } }) }
    if ($Method -eq 'GET' -and $Path -match '^/subscriptions/[^/]+/resourcegroups\?') {
      return & $ok @{ value=@(& $rows | Where-Object { $_.type -eq 'microsoft.resources/subscriptions/resourcegroups' } | ForEach-Object { @{ name = $_.name; id = "$S/resourceGroups/$($_.name)" } }) } }
    if ($Method -eq 'DELETE' -and $Path -match '^/subscriptions/[^/]+/resourceGroups/([^/?]+)\?') {
      $rg = $Matches[1]; $left = @(& $rows | Where-Object { $_.resourceGroup -ne $rg -and $_.name -ne $rg })
      ConvertTo-Json @($left) | Set-Content $sp.inventoryFile
      return [pscustomobject]@{ StatusCode=202; Content='' } }
    if ($Method -eq 'GET' -and $Path -match '^/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/Microsoft.Compute/virtualMachines\?') {
      $rg = $Matches[1]; return & $ok @{ value=@(& $rows | Where-Object { $_.type -eq 'microsoft.compute/virtualmachines' -and $_.resourceGroup -eq $rg } | ForEach-Object { @{ name = $_.name; id = "$S/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/$($_.name)" } }) } }
    if ($Method -eq 'POST' -and $Path -match '/providers/Microsoft.Compute/virtualMachines/([^/]+)/deallocate\?') { return [pscustomobject]@{ StatusCode=202; Content='' } }
    if ($Path -match '/resourceGroups/avdlz-runs-rg/providers/Microsoft.Storage/storageAccounts/([^/?]+)\?' -and $Method -eq 'GET' -and $sp.ContainsKey('runStore')) {
      if ($sp.runStore) { return & $ok @{ name=$Matches[1] } } else { return [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"ResourceGroupNotFound"}}' } } }
  }
  # ---- Host rotation (Invoke-AvdHostRotation.ps1; image pipeline spec section 6.5). Only when $global:St.rotation is
  # set: tags (the host pool's), hosts (VM name -> @{ status; sessions; allowNew; healthy; deleted }), vmsGone (VMs
  # deleted), vmsSlow (VMs whose first delete doesn't finish), excluded (VMs tagged out of the scaling plan), galleryTags (what was tagged on gallery versions),
  # deployment (the last succeeded record's parameters), runs (the rotation's own deployments by name: @{ name; state; timestamp }).
  # ARM leaves out what it doesn't have (lesson 0021): a pool with no tags has no tags property.
  $ro = $global:St.rotation
  if ($ro) {
    $hpRe = [regex]::Escape($hpId); $vmBase = "$S/resourceGroups/rg-avdlz-dev-hosts/providers/Microsoft.Compute/virtualMachines"
    if ($Method -eq 'GET' -and $Path -match "^$hpRe\?") { $o = @{ name='vdpool-avdlz-dev'; id=$hpId }; if ($ro.tags.Count) { $o.tags = $ro.tags }; return & $ok $o }
    if ($Method -eq 'PATCH' -and $Path -match "^$hpRe/providers/Microsoft.Resources/tags/default\?") {
      $b = $Payload | ConvertFrom-Json
      foreach ($t in $b.properties.tags.PSObject.Properties) {
        if ($b.operation -eq 'Merge') { $ro.tags[$t.Name] = "$($t.Value)" }
        elseif ($ro.tags[$t.Name] -eq "$($t.Value)") { $ro.tags.Remove($t.Name) }   # Delete matches name and value
      }
      # deploy.sh reads the same tags through the fake az (deploybin/az, FAKE_POOL_TAGS).
      $env:FAKE_POOL_TAGS = ([ordered]@{ 'avdlz-generation' = $ro.tags['avdlz-generation']; 'avdlz-image' = $ro.tags['avdlz-image']; 'avdlz-image-next' = $ro.tags['avdlz-image-next']
          'avdlz-image-previous' = $ro.tags['avdlz-image-previous']; 'avdlz-rotation' = $ro.tags['avdlz-rotation'] } | ConvertTo-Json)
      return & $ok @{}
    }
    if ($Method -eq 'PATCH' -and $Path -match '/versions/([^/]+)/providers/Microsoft.Resources/tags/default\?') {
      $ro.galleryTags += "$(($Payload | ConvertFrom-Json).operation) $($Matches[1])"
      $ro.galleryKey = @(($Payload | ConvertFrom-Json).properties.tags.PSObject.Properties.Name)[0]
      return & $ok @{}
    }
    if ($Method -eq 'GET' -and $Path -match "^$hpRe/sessionHosts\?") {
      return & $ok @{ value=@($ro.hosts.Keys | Sort-Object | Where-Object { -not $ro.hosts[$_].deleted } | ForEach-Object {
            $h = $ro.hosts[$_]
            $props = @{ resourceId="$vmBase/$_"; status=$h.status; sessions=$h.sessions; allowNewSession=$h.allowNew }
            # A host that hasn't reported its health checks yet: ARM leaves the property out.
            if (-not $h.noChecks) { $props.sessionHostHealthCheckResults = @(@{ healthCheckName='DomainJoinedCheck'; healthCheckResult=$(if ($h.healthy -eq $false) { 'HealthCheckFailed' } else { 'HealthCheckSucceeded' }) }) }
            @{ name="vdpool-avdlz-dev/$_.contoso.com"; id="$hpId/sessionHosts/$_.contoso.com"; properties=$props } }) }
    }
    if ($Path -match "^$hpRe/sessionHosts/([^./]+)\.contoso\.com(/userSessions)?") {
      $name = $Matches[1]; $h = $ro.hosts[$name]; $us = [bool]$Matches[2]
      if ($Path -match '/sendMessage\?') { $ro.messages++; return & $ok @{} }
      if ($us -and $Method -eq 'GET') { return & $ok @{ value=@(1..([Math]::Max(1, [int]$h.sessions)) | Where-Object { $h.sessions } | ForEach-Object { @{ name="vdpool-avdlz-dev/$name.contoso.com/$_" } }) } }
      if ($us -and $Method -eq 'DELETE') { $h.sessions = [Math]::Max(0, $h.sessions - 1); $ro.signedOut++; return & $ok @{} }
      if ($Method -eq 'PATCH') {
        $h.allowNew = ($Payload | ConvertFrom-Json).properties.allowNewSession
        # A user who connected while the host was open shows up once it drains.
        if (-not $h.allowNew -and $h.connectOnDrain) { $h.sessions++; $h.connectOnDrain = $false }
        return & $ok @{}
      }
      if ($Method -eq 'DELETE') { $h.deleted = $true; return & $ok @{} }
    }
    if ($Method -eq 'GET' -and $Path -match "^$([regex]::Escape($vmBase))\?") {
      return & $ok @{ value=@($ro.hosts.Keys | Sort-Object | Where-Object { $ro.vmsGone -notcontains $_ } | ForEach-Object { @{ name=$_; id="$vmBase/$_" } }) }
    }
    if ($Method -eq 'PATCH' -and $Path -match "^$([regex]::Escape($vmBase))/([^/?]+)/providers/Microsoft.Resources/tags/default\?") {
      # The scaling plan's exclusion tag on a drained host (excluded: VM names that carry it).
      $vm = $Matches[1]; $b = $Payload | ConvertFrom-Json
      $ro.excluded = @(@($ro.excluded | Where-Object { $_ -and $_ -ne $vm }) + @(if ($b.operation -eq 'Merge') { $vm }))
      return & $ok @{}
    }
    if ($Path -match "^$([regex]::Escape($vmBase))/([^/?]+)\?") {
      $vm = $Matches[1]
      if ($Method -eq 'DELETE') {
        if ($ro.vmsSlow -contains $vm) { $ro.vmsSlow = @($ro.vmsSlow | Where-Object { $_ -ne $vm }) } else { $ro.vmsGone += $vm }
        return [pscustomobject]@{ StatusCode=202; Content='' }
      }
      if ($ro.vmsGone -contains $vm -or -not $ro.hosts.ContainsKey($vm)) { return [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"ResourceNotFound"}}' } }
      return & $ok @{ name=$vm }
    }
    if ($Method -eq 'GET' -and $Path -match '^/subscriptions/[^/]+/providers/Microsoft\.Resources/deployments\?') {
      # The demo's record has no host pool output; another landing zone's record names another pool.
      $other = $hpId -replace 'vdpool-avdlz-dev', 'vdpool-other-dev'
      return & $ok @{ value=@(
          @{ name='avdlz-dev-20261020-120000'; properties=@{ provisioningState='Succeeded'; timestamp='2026-10-20T12:00:00Z'; parameters=$ro.deployment; outputs=@{ hostPoolResourceId=@{ type='String'; value=$hpId } } } },
          @{ name='avdlz-dev-20261020-130000'; properties=@{ provisioningState='Succeeded'; timestamp='2026-10-20T13:00:00Z'; parameters=@{ sessionHostNamePrefix=@{ value='otherdsh' } }; outputs=@{ hostPoolResourceId=@{ type='String'; value=$other } } } },
          @{ name='avdlz-demo-20261020-140000'; properties=@{ provisioningState='Succeeded'; timestamp='2026-10-20T14:00:00Z' } }
        ) }
    }
    # The rotation's own deployment, read by the name it gave deploy.sh.
    if ($Method -eq 'GET' -and $Path -match '^/subscriptions/[^/]+/providers/Microsoft\.Resources/deployments/(avdlz-[^/?]+-rot[ab]-[^/?]+)\?') {
      $run = @($ro.runs | Where-Object { $_ -and $_.name -eq $Matches[1] })[0]
      if (-not $run) { return [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"DeploymentNotFound"}}' } }
      return & $ok @{ name=$run.name; properties=@{ provisioningState=$run.state; timestamp=$run.timestamp } }
    }
  }
  # ---- Recovery (Get-AvdRecoveryStatus, Export-AvdConfiguration, Start-AvdRecoveryTest, Test-AvdRecoveryCopies;
  # build/specs/recovery-spec.md). Only when $global:St.recovery is set: vaulted (bool), points (recovery point
  # times), restoreStatus (the restore job's end state), gallery (hosts on a gallery image), replicaRegions.
  # ARM leaves out what a resource doesn't have (lesson 0021): a snapshot-tier policy has no vaultRetentionPolicy.
  $rc = $global:St.recovery
  if ($rc) {
    $vaultId = "$S/resourceGroups/rg-avdlz-dev-storage/providers/Microsoft.RecoveryServices/vaults/rsv-avdlz-dev"
    $itemId = "$vaultId/backupFabrics/Azure/protectionContainers/storagecontainer;Storage;rg-avdlz-dev-storage;$saName/protectedItems/AzureFileShare;profiles"
    $polName = if ($rc.vaulted) { 'fslogix-daily-vaulted' } else { 'fslogix-daily' }
    if ($Path -match 'vaults/rsv-avdlz-dev\?api-version') {
      $v = @{ name='rsv-avdlz-dev'; id=$vaultId; location='eastus2'; properties=@{ securitySettings=@{ softDeleteSettings=@{ softDeleteState='Enabled'; softDeleteRetentionPeriodInDays=14 }; immutabilitySettings=@{ state='Unlocked' } }
          redundancySettings=@{ standardTierStorageRedundancy='GeoRedundant'; crossRegionRestore=$(if ($rc.vaulted) { 'Enabled' } else { 'Disabled' }) } } }
      return & $ok $v
    }
    if ($Path -match 'vaults/rsv-avdlz-dev/backupProtectedItems\?') {
      $newest = @($rc.points | Sort-Object -Descending)[0]
      return & $ok @{ value=@(@{ name='AzureFileShare;profiles'; id=$itemId; properties=@{ policyId="$vaultId/backupPolicies/$polName"; protectionState='Protected'; lastBackupStatus='Healthy'; lastBackupTime=$newest } }) }
    }
    if ($Path -match "backupPolicies/$polName\?") {
      $ret = @{ retentionPolicyType='LongTermRetentionPolicy'; dailySchedule=@{ retentionDuration=@{ count=30; durationType='Days' } } }
      $p = @{ backupManagementType='AzureStorage'; workLoadType='AzureFileShare' }
      if ($rc.vaulted) { $p.vaultRetentionPolicy = @{ snapshotRetentionInDays=7; vaultRetention=$ret } } else { $p.retentionPolicy = $ret }
      return & $ok @{ name=$polName; properties=$p }
    }
    if ($Path -match 'protectedItems/AzureFileShare;profiles/recoveryPoints\?') {
      $i = 0
      return & $ok @{ value=@($rc.points | ForEach-Object { $i++; @{ name="93288113855580286$i"; id="$itemId/recoveryPoints/93288113855580286$i"; properties=@{ objectType='AzureFileShareRecoveryPoint'; recoveryPointTime=$_; recoveryPointType='FileSystemConsistent' } } }) }
    }
    if ($Method -eq 'POST' -and $Path -match '/recoveryPoints/([^/]+)/restore\?') {
      $rc.restored = @($rc.restored | Where-Object { $_ }) + @{ point=$Matches[1]; body=($Payload | ConvertFrom-Json) }
      return [pscustomobject]@{ StatusCode=202; Content='' }
    }
    if ($Path -match 'vaults/rsv-avdlz-dev/backupJobs\?') {
      if (-not @($rc.restored | Where-Object { $_ }).Count) { return & $ok @{ value=@() } }
      $rc.jobPolls++
      $st = if ($rc.jobPolls -lt 2) { 'InProgress' } else { $rc.restoreStatus }
      $j = @{ name='7e0ee41e-6e31-4728-a25c-98ff6b777641'; properties=@{ operation='Restore'; status=$st; startTime=(Get-Date).ToUniversalTime().ToString('o')
          extendedInfo=@{ propertyBag=@{ 'Number Of Restored Files'='12'; 'Number Of Failed Files'=$(if ($st -eq 'Failed') { '3' } else { '0' }) } } } }
      if ($st -eq 'Failed') { $j.properties.errorDetails = @(@{ errorCode='UserErrorStorageAccountInternetRoutingNotSupported'; errorString='The target storage account is not reachable by Azure Backup.' }) }
      return & $ok @{ value=@($j) }
    }
    if ($Path -match "storageAccounts/$saName/fileServices/default/shares/profiles\?") { return & $ok @{ name='profiles'; properties=@{ shareQuota=100; enabledProtocols='SMB' } } }
    if ($Path -match 'storageAccounts/(strt[a-z0-9]+)(/fileServices/default/shares/[^/?]+)?\?') {
      if ($Method -eq 'PUT') { $rc.created = @($rc.created | Where-Object { $_ }) + "$($Matches[1])$($Matches[2])"; $rc.createdBodies = @($rc.createdBodies | Where-Object { $_ }) + $Payload }
      return & $ok @{ name=$Matches[1]; properties=@{ provisioningState='Succeeded' } }
    }
    if ($Path -match 'rg-avdlz-dev-hosts/providers/Microsoft.Compute/virtualMachines\?') {
      $img = if ($rc.gallery) { @{ id="$S/resourceGroups/rg-avdlz-images/providers/Microsoft.Compute/galleries/galavdlz/images/win11-avd-m365/versions/2026.1020.1" } } else { @{ publisher='MicrosoftWindowsDesktop'; offer='office-365'; sku='win11-24h2-avd-m365'; version='latest' } }
      return & $ok @{ value=@(@{ name='avdlzdsh-001'; properties=@{ storageProfile=@{ imageReference=$img } } }) }
    }
    if ($Path -match 'galleries/galavdlz/images/win11-avd-m365/versions/2026\.1020\.1\?') {
      return & $ok @{ name='2026.1020.1'; properties=@{ publishingProfile=@{ targetRegions=@($rc.replicaRegions | ForEach-Object { @{ name=$_ } }) } } }
    }
    # Export-AvdConfiguration: the host pool carries a registration token, which must never reach a snapshot.
    if ($Path -match 'rg-avdlz-dev-avd/providers/Microsoft.DesktopVirtualization/hostPools\?') {
      return & $ok @{ value=@(@{ name='vdpool-avdlz-dev'; id=$hpId; etag='"e1"'; properties=@{ hostPoolType='Pooled'; maxSessionLimit=$(if ($rc.maxSessions) { $rc.maxSessions } else { 8 }); startVMOnConnect=$true
              registrationInfo=@{ token='eyJhbGciOi.secret-registration-token'; expirationTime='2026-10-21T00:00:00Z' }; customRdpProperty='drivestoredirect:s:;' } }) }
    }
    if ($Path -match '/applicationGroups/[^/]+/applications\?') { return & $ok @{ value=@() } }
    if ($Path -match 'scalingPlans/[^/]+/pooledSchedules\?') { return & $ok @{ value=@(@{ name='weekdays'; properties=@{ daysOfWeek=@('Monday','Tuesday'); rampUpStartTime=@{ hour=7; minute=0 } } }) } }
    if ($Path -match 'scalingPlans\?') { return & $ok @{ value=@(@{ name='vdscaling-avdlz-dev'; id="$S/resourceGroups/rg-avdlz-dev-avd/providers/Microsoft.DesktopVirtualization/scalingPlans/vdscaling-avdlz-dev"; properties=@{ hostPoolReferences=@(@{ hostPoolArmPath=$hpId; scalingPlanEnabled=$true }) } }) } }
    if ($Path -match '^(.+)/providers/Microsoft\.Authorization/roleAssignments\?') {
      $scope = $Matches[1]
      return & $ok @{ value=@(Get-AzRoleAssignment | Where-Object { $_.Scope -eq $scope } | ForEach-Object { @{ id="$scope/providers/Microsoft.Authorization/roleAssignments/$($_.ObjectId)-$($_.RoleDefinitionName -replace ' ')"; properties=@{ scope=$scope; roleDefinitionId="/providers/Microsoft.Authorization/roleDefinitions/$($_.RoleDefinitionName -replace ' ')"; principalId=$_.ObjectId; principalType=$_.ObjectType } } }) }
    }
  }
  # ---- Run store (Initialize-AvdRunStore.ps1, Start-AvdRunRecorder.ps1). $global:St.runStore: defender
  # ('Standard'/'Free'), deployed (bool). The single-plan pricing read returns 404 when it was never set.
  $rs = $global:St.runStore
  if ($rs -and $Path -match '/providers/Microsoft.Security/pricings/StorageAccounts\?') {
    if (-not $rs.defender) { return [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"NotFound","message":"Not found"}}' } }
    return & $ok @{ name='StorageAccounts'; properties=@{ pricingTier=$rs.defender } } }
  # Cost Management query (Stop-AvdRunRecorder.ps1): $rs.costRows as [cost, meter, currency], or $rs.costForbidden.
  if ($rs -and $Method -eq 'POST' -and $Path -match '/providers/Microsoft.CostManagement/query\?') {
    $q = $Payload | ConvertFrom-Json
    Log "COSTQUERY $($q.timePeriod.from) $(@($q.dataset.filter.dimensions.values) -join ',')"
    if ($rs.costForbidden) { return [pscustomobject]@{ StatusCode=403; Content='{"error":{"code":"RBACAccessDenied","message":"The client does not have authorization to perform action."}}' } }
    # A query without the run store is the after-teardown check: it answers with $rs.costRowsAfter.
    $rows = $rs.costRows
    if (@($q.dataset.filter.dimensions.values) -notcontains 'avdlz-runs-rg') { $rows = $rs.costRowsAfter }
    if ($null -eq $rows) { $rows = @() }
    return & $ok @{ properties=@{ columns=@(@{ name='Cost'; type='Number' }, @{ name='Meter'; type='String' }, @{ name='Currency'; type='String' }); rows=@($rows) } } }
  if ($rs -and $Path -match '/resourceGroups/avdlz-runs-rg/providers/Microsoft.Storage/storageAccounts/(avdlzruns[0-9a-f]+)\?') {
    if (-not $rs.deployed) { return [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"ResourceNotFound","message":"The Resource was not found."}}' } }
    return & $ok @{ name=$Matches[1]; properties=@{ allowSharedKeyAccess=$false; minimumTlsVersion='TLS1_2' } } }
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
  # ---- Deployment portal published into the subscription (scripts/ops/Publish-AvdPortal.ps1) ----
  if ($Path -match '/staticSites/([^/?]+)/listSecrets\?') { return & $ok @{ properties=@{ apiKey=$global:St.swaToken } } }
  if ($Path -match '/staticSites/([^/?]+)/resetapikey\?') { $global:St.swaTokenResets++; return & $ok @{} }
  if ($Path -match '/staticSites/([^/?]+)/createUserInvitation\?') { $global:St.swaInvitation = ($Payload | ConvertFrom-Json); return & $ok @{ properties=@{ invitationUrl="https://$($global:St.swaHost)/.auth/invitations/inv-123"; expiresOn='2026-10-27T00:00:00Z' } } }
  if ($Path -match '/staticSites/([^/?]+)\?') { return & $ok @{ name=$Matches[1]; sku=@{ name=$(if ($global:St.swaSku) { $global:St.swaSku } else { 'Free' }) }; properties=@{ defaultHostname=$global:St.swaHost } } }
  # The landing zone's allowed-locations guardrail allows $global:St.allowedLocations; $global:St.foreignAllowed adds an
  # assignment someone else owns (inherited from a management group, as atScope() returns it). ARM omits empty parameters.
  if ($Path -match 'policyAssignments\?') {
    $allowed = if ($global:St.allowedLocations) { $global:St.allowedLocations } else { @('eastus2', 'northcentralus') }
    $list = @(@{name='avdlz-allowed-locations';id="$S/providers/Microsoft.Authorization/policyAssignments/avdlz-allowed-locations"
        properties=@{ displayName='AVD LZ - allowed locations'; policyDefinitionId='/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'; enforcementMode='Default'; parameters=@{ listOfAllowedLocations=@{ value=@($allowed) } } } },
      @{name='avdlz-inherit-rg-tag-workload';id="$S/pa2";identity=@{principalId='44444444-0000-0000-0000-000000000000'}},@{name='someone-else';id='x'})
    if ($global:St.foreignAllowed) {
      $list += @{ name='corp-allowed-rg-locations'; id='/providers/Microsoft.Management/managementGroups/corp/providers/Microsoft.Authorization/policyAssignments/corp-allowed-rg-locations'
        properties=@{ displayName='Corp allowed RG locations'; policyDefinitionId='/providers/Microsoft.Authorization/policyDefinitions/e765b5de-1225-4ba3-bd56-1ac6695af988'; parameters=@{ listOfAllowedLocations=@{ value=@($global:St.foreignAllowed) } } } }
    }
    return & $ok @{ value=$list }
  }
  # Subscription deployment records for Get-AvdRunStatus.ps1. $global:St.deploymentRecords: @{ name; state; timestamp }.
  # ARM leaves out what a record doesn't have (lesson 0021): no outputs here.
  if ($Path -match '^/subscriptions/[^/]+/providers/Microsoft\.Resources/deployments\?' -and $Method -eq 'GET') {
    return & $ok @{ value=@($global:St.deploymentRecords | Where-Object { $_ } | ForEach-Object { $p = @{ provisioningState=$_.state; timestamp=$_.timestamp }; if ($_.parameters) { $p.parameters = $_.parameters }; @{ name=$_.name; properties=$p } }) }
  }
  if ($Path -match 'providers/Microsoft.Resources/deployments/(avdlz-demo-[^/?]+)\?' -and $Method -eq 'GET') {
    if (@($global:St.deployments) -notcontains $Matches[1]) { return [pscustomobject]@{ StatusCode=404; Content='{"error":{"code":"DeploymentNotFound"}}' } }
    return & $ok @{ name=$Matches[1]; properties=@{ provisioningState='Succeeded'; outputs=@{ sessionHostNames=@{ type='Array'; value=@('avdlzddemo-001') } } } }
  }
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
          $vm = @{ name="avdlzdsh-00$_"; id="$S/resourceGroups/rg-avdlz-dev-hosts/providers/Microsoft.Compute/virtualMachines/avdlzdsh-00$_"; properties=@{ hardwareProfile=@{ vmSize=$global:St.hostSize }; securityProfile=@{ securityType='TrustedLaunch'; encryptionAtHost=$true; uefiSettings=@{ secureBootEnabled=$true; vTpmEnabled=[bool](-not $global:St.waf.noVtpm) } }; storageProfile=@{ osDisk=@{ managedDisk=@{ storageAccountType=$(if ($global:St.waf.standardDisk) { 'StandardSSD_LRS' } else { 'Premium_LRS' }) } } } } }
          if ($g) { $vm.zones = @("$_") }
          $vm }) }
  }
  if ($Path -match 'virtualMachines/[^/]+/extensions\?') { return & $ok @{ value=@(
        @{ name='AADLogin'; properties=@{ publisher='Microsoft.Azure.ActiveDirectory'; type='AADLoginForWindows'; provisioningState='Succeeded' } },
        @{ name='AzureMonitorAgent'; properties=@{ publisher='Microsoft.Azure.Monitor'; type='AzureMonitorWindowsAgent'; provisioningState=$(if ($global:St.waf.amaFailed) { 'Failed' } else { 'Succeeded' }) } }) } }
  if ($Path -match 'Microsoft.Network/networkInterfaces\?') { return & $ok @{ value=@(@{ name='avdlzdsh-001-nic'; properties=@{ enableAcceleratedNetworking=$true } }) } }
  if ($Path -match "storageAccounts/$saName/fileServices/default\?") { return & $ok @{ properties=@{ shareDeleteRetentionPolicy=@{ enabled=$true; days=14 }; protocolSettings=@{ smb=@{ versions='SMB3.1.1;'; authenticationMethods='Kerberos;'; kerberosTicketEncryption='AES-256;'; channelEncryption=$(if ($global:St.smbChannel) { $global:St.smbChannel } else { 'AES-128-GCM;AES-256-GCM;' }) } } } } }
  if ($Path -match "storageAccounts/$saName\?api-version") { return & $ok @{ sku=@{ name=$(if ($g) { 'Premium_ZRS' } else { 'Premium_LRS' }) }; properties=@{ minimumTlsVersion='TLS1_2'; supportsHttpsTrafficOnly=$true; allowSharedKeyAccess=[bool]$global:St.sharedKey; publicNetworkAccess='Disabled' } } }
  # The profile share's protected item (AzureFileshareProtectedItem). $global:St.backup: @{ status; ageHours; state };
  # an item that never ran has no lastBackupTime (ARM omits it, lesson 0021).
  if ($Path -match 'backupProtectedItems\?') {
    $b = $global:St.backup
    if (-not $g -and -not $b) { return & $ok @{ value=@() } }
    $p = @{ friendlyName='profiles'; protectedItemType='AzureFileShareProtectedItem'; protectionState=$(if ($b.state) { $b.state } else { 'Protected' }); healthStatus='Passed'; lastBackupStatus=$(if ($b.status) { $b.status } else { 'Healthy' }) }
    if (-not $b -or $null -ne $b.ageHours) { $p.lastBackupTime = [datetime]::UtcNow.AddHours(-$(if ($b) { $b.ageHours } else { 3 })).ToString('o') }
    return & $ok @{ value=@(@{ name='AzureFileShare;profiles'; properties=$p }) }
  }
  # A vaulted-tier policy has vaultRetentionPolicy ($global:St.vaultedPolicy).
  if ($Path -match '/backupPolicies\?') { return & $ok @{ value=@(@{ name='fslogix-daily'; properties=$(if ($global:St.vaultedPolicy) { @{ backupManagementType='AzureStorage'; vaultRetentionPolicy=@{ snapshotRetentionInDays=5 } } } else { @{ backupManagementType='AzureStorage' } }) }) } }
  if ($Path -match 'Microsoft.Security/pricings\?') { return & $ok @{ value=@('VirtualMachines','StorageAccounts','KeyVaults','Containers' | ForEach-Object { @{ name=$_; properties=@{ pricingTier=$(if ($g) { 'Standard' } else { 'Free' }) } } }) } }
  if ($Path -match '/rg/kv\?api-version') { return & $ok @{ properties=@{ enablePurgeProtection=$true; enableRbacAuthorization=$true; publicNetworkAccess='Disabled' } } }
  if ($Path -match 'Microsoft.Consumption/budgets\?') { return & $ok @{ value=@(if ($g) { @{ name='budget-avdlz-prod' } }) } }
  if ($Path -match 'scalingPlans\?') { return & $ok @{ value=@(@{ name='vdscaling-avdlz-dev'; properties=@{ hostPoolReferences=@(@{ hostPoolArmPath=$hpId; scalingPlanEnabled=$true }) } }) } }
  # The host pool as bicep/main.bicep deploys it, or with drives redirected ($global:St.waf.drivesOn).
  if ($Path -match 'hostPools/vdpool-avdlz-dev\?api-version') { return & $ok @{ name='vdpool-avdlz-dev'; id=$hpId; properties=@{ customRdpProperty=$(if ($global:St.waf.drivesOn) { 'enablerdsaadauth:i:1;drivestoredirect:s:*;usbdevicestoredirect:s:;redirectcomports:i:0' } else { 'enablerdsaadauth:i:1;targetisaadjoined:i:1;drivestoredirect:s:;usbdevicestoredirect:s:;redirectcomports:i:0;redirectclipboard:i:1' }) } } }
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
# Run store uploads: $global:St.blobs holds container/blob -> the uploaded file's text.
# Uploads: the run store's containers, or the portal's static website ($web; Publish-AvdPortal.ps1 -Hosting Storage).
# $global:St.blobForbidden: $web uploads refused (403) before the role applies.
function Set-AzStorageBlobContent { param($File,$Container,$Blob,$Context,[switch]$Force,$Properties,$ErrorAction)
  if ($Container -eq '$web') {
    if ($global:St.blobForbidden -gt 0) { $global:St.blobForbidden--; throw 'This request is not authorized to perform this operation using this permission. (403) AuthorizationPermissionMismatch' }
    $global:St.webBlobs[$Blob] = @{ ContentType=$Properties.ContentType; CacheControl=$Properties.CacheControl; Text=$(if ($Blob -match '\.(js|json|html)$') { Get-Content -Raw $File }) }
    return
  }
  Log "blob put $($Context.StorageAccountName)/$Container/$Blob"
  if ($null -eq $global:St.blobs) { $global:St.blobs = @{} }
  $global:St.blobs["$Container/$Blob"] = Get-Content -LiteralPath $File -Raw
  [pscustomobject]@{ Name=$Blob } }
# The records container through the Azure.Storage.Blobs client, as Sync-AvdRunRecordStore uses it (list, download,
# upload with If-Match / If-None-Match). The SDK types it builds are stood in when Az.Storage isn't loaded.
if (-not ('Azure.ETag' -as [type])) {
  Add-Type -TypeDefinition @'
namespace Azure { public class ETag { public string V; public ETag(string v) { V = v; } public static ETag All { get { return new ETag("*"); } } public override string ToString() { return V; } } }
namespace Azure.Storage.Blobs.Models {
  public class BlobRequestConditions { public Azure.ETag IfMatch; public Azure.ETag IfNoneMatch; }
  public class BlobUploadOptions { public BlobRequestConditions Conditions; }
}
public class OfflineRequestFailedException : System.Exception { public int Status; public OfflineRequestFailedException(int s, string m) : base(m) { Status = s; } }
'@
}
function Get-AzStorageContainer { param($Name,$Context,$ErrorAction)
  if ($Name -ne 'records' -or $null -eq $global:St.records) { return $null }
  $container = [pscustomobject]@{}
  $container | Add-Member ScriptMethod GetBlobClient {
    param($blobName)
    $c = [pscustomobject]@{ Name = $blobName }
    $c | Add-Member ScriptMethod DownloadTo { param($dest) $b = $global:St.records[$this.Name]; [IO.File]::WriteAllText($dest, $b.content); [pscustomobject]@{ Headers = [pscustomobject]@{ ETag = $b.etag } } }
    $c | Add-Member ScriptMethod Upload {
      param($stream, $options)
      $have = $global:St.records[$this.Name]; $cond = $options.Conditions
      # $global:St.recordsBreakFile: while that file exists, the next upload fails once (the store busy), then it is removed.
      if ($global:St.recordsBreakFile -and (Test-Path -LiteralPath $global:St.recordsBreakFile)) { Remove-Item -LiteralPath $global:St.recordsBreakFile; throw [OfflineRequestFailedException]::new(503, 'ServerBusy: the store is busy.') }
      if (($cond.IfMatch -and (-not $have -or $have.etag -ne "$($cond.IfMatch)")) -or ($cond.IfNoneMatch -and $have)) { throw [OfflineRequestFailedException]::new(412, 'ConditionNotMet') }
      $text = (New-Object IO.StreamReader($stream)).ReadToEnd()
      $global:St.recordsEtag++; $global:St.records[$this.Name] = @{ etag = "r$($global:St.recordsEtag)"; content = $text }
      Log "BLOB SYNC records/$($this.Name)"
      [pscustomobject]@{ Value = [pscustomobject]@{ ETag = "r$($global:St.recordsEtag)" } }
    }
    $c
  }
  [pscustomobject]@{ Name = 'records'; BlobContainerClient = $container }
}
function New-AzStorageContext { param($StorageAccountName,[switch]$UseConnectedAccount) [pscustomobject]@{ StorageAccountName=$StorageAccountName } }
function Get-AzStorageBlob { param($Container,$Context,$ErrorAction)
  if ($Container -eq '$web') { return @($global:St.webBlobs.Keys | ForEach-Object { [pscustomobject]@{ Name=$_ } }) }
  if ($Container -eq 'records' -and $null -ne $global:St.records) { return @($global:St.records.Keys | ForEach-Object { [pscustomobject]@{ Name=$_; BlobProperties=[pscustomobject]@{ ETag=$global:St.records[$_].etag } } }) }
  if ($global:St.images.logUnreadable) { throw 'This request is not authorized to perform this operation using this permission. (403)' }
  [pscustomobject]@{ Name='0b1c/customization.log'; LastModified=(Get-Date) } }
# The portal's static website ($web container; Publish-AvdPortal.ps1 -Hosting Storage).
function Enable-AzStorageStaticWebsite { param($Context,$IndexDocument,$ErrorDocument404Path) Log "static website on $($Context.StorageAccountName) index=$IndexDocument 404=$ErrorDocument404Path"; $global:St.staticWebsite = $true }
function Remove-AzStorageBlob { param($Context,$Container,$Blob,[switch]$Force) Log "del blob $Blob"; $global:St.webBlobs.Remove($Blob) }
# The Static Web Apps CLI (npx @azure/static-web-apps-cli deploy <dir> ...): records what it was given. $global:St.swaFail: the upload fails.
function npx {
  $dir = $args[3]
  Log "npx $($args[0..2] -join ' ') tokenSet=$($env:SWA_CLI_DEPLOYMENT_TOKEN -eq $global:St.swaToken)"
  $global:St.swaUpload = @{
    Files = @(Get-ChildItem -Recurse -File $dir | ForEach-Object { [IO.Path]::GetRelativePath($dir, $_.FullName).Replace('\', '/') })
    Config = Get-Content -Raw (Join-Path $dir 'portal/portal-config.js')
    SwaConfig = $(if (Test-Path (Join-Path $dir 'staticwebapp.config.json')) { Get-Content -Raw (Join-Path $dir 'staticwebapp.config.json') })
    Args = @($args)
  }
  if ($global:St.swaFail) { 'Deploying project...'; 'Error: the content server rejected the upload.'; $global:LASTEXITCODE = 1 }
  else { 'Deploying project...'; 'Project deployed to https://example/'; $global:LASTEXITCODE = 0 }
}
function Get-AzStorageBlobContent { param($Container,$Blob,$Destination,$Context,[switch]$Force) Set-Content -Path $Destination -Value $global:St.images.log; [pscustomobject]@{ Name=$Blob } }
function Get-AzVM { param($ResourceGroupName,$Name,[switch]$Status,$ErrorAction)
  $n = if ($ResourceGroupName -like '*demo') {'avdlzddemo-001'} else {'avdlzdsh-001'}
  $vm=[pscustomobject]@{Name=$n;HardwareProfile=[pscustomobject]@{VmSize=$global:St.hostSize};Id="$S/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$n";Identity=[pscustomobject]@{PrincipalId="mi-$n"};PowerState='VM running';OSProfile=[pscustomobject]@{ComputerName=$n}}
  if ($global:St.rgs -contains $ResourceGroupName) { if (-not $Name -or $Name -eq $n) { $vm } }
}
function Start-AzVM { param($ResourceGroupName,$Name) Log "start $Name" }
function Stop-AzVM { param($ResourceGroupName,$Name,[switch]$Force) Log "stop $Name" }
function Invoke-AzVMRunCommand { param($ResourceGroupName,$VMName,$CommandId,$ScriptString,$Parameter,$ErrorAction)
  Log "runcmd $VMName $(if ($ScriptString -match 'filepermission') {'acl'} elseif ($ScriptString -match 'Win32_DeviceGuard') {'security'} else {'diag'}) apply=$($Parameter.Apply)"
  if ($ScriptString -match 'Win32_DeviceGuard') {
    # Get-SessionHostSecurity.ps1 on a fresh Trusted Launch host: the landing zone's controls on, the
    # organization's left at Windows defaults, and no RunAsPPL value (left out, as the host script
    # leaves it out until something sets it; not yet confirmed by a real run, decision 0018).
    # $global:St.hostSecurity overrides values; a $null leaves one out.
    $o=[ordered]@{vbsStatus=2;securityServicesRunning=@(1,2);codeIntegrityEnforcement=0;defenderRealTime=$true;defenderTamperProtected=$false;smb1Enabled=$false;maxIdleTimeMs=0;inactivityTimeoutSecs=0;screenCaptureProtection=0;extraLocalAdmins=0;readErrors=@()}
    if ($global:St.hostSecurity) { foreach ($k in @($global:St.hostSecurity.Keys)) { if ($null -eq $global:St.hostSecurity[$k]) { $o.Remove($k) } else { $o[$k]=$global:St.hostSecurity[$k] } } }
  }
  elseif ($ScriptString -match 'filepermission') {
    if ($global:St.forbiddenOnce) { $global:St.forbiddenOnce=$false; $o=@{status='Forbidden';httpStatus=403} }
    elseif ($Parameter.Apply -eq 'true') { $global:St.aclApplied=$true; $sddl=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Parameter.DesiredSddlBase64)); $o=@{status='ok';before='x';after=$sddl} }
    elseif ($global:St.aclApplied) { $o=@{status='ok';before=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Parameter.DesiredSddlBase64))} }
    elseif ($global:St.defaultRoot) { $o=@{status='ok';before=$null;defaultAcl=$true} }
    else { $o=@{status='ok';before='O:SYG:SYD:(A;OICIIO;GA;;;CO)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1301bf;;;AU)(A;OICI;0x1200a9;;;BU)'} }
  } else { $o=@{entraJoined=$true;intuneEnrolled=$true;agentRegistered=$true;bootLoaderRunning=$true;fslogixServiceRunning=$true;fslogixEnabled=$true;fslogixPointsAtShare=$true;cloudKerberosEnabled=$true;loadCredKeyFromProfile=$true;kerberosServicesStopped=@($global:St.kerberosServicesStopped | Where-Object { $_ });storageIp='10.100.2.4';storageIpPrivate=$true;smbReachable=$true} }
  [pscustomobject]@{ Value=@([pscustomobject]@{Code='ComponentStatus/StdOut/succeeded';Message=('<<<AVDJSON'+($o|ConvertTo-Json -Compress)+'AVDJSON>>>')},[pscustomobject]@{Code='ComponentStatus/StdErr/succeeded';Message=''}) }
}
function New-AzSubscriptionDeployment { param($Name,$Location,$TemplateFile,$TemplateParameterObject,$ErrorAction)
  if ($TemplateFile -like '*recorder*main.bicep') {
    Log "deploy $Name runstore=$($TemplateParameterObject.storageAccountName) teardownLogs=$($TemplateParameterObject.teardownLogs) repo=$($TemplateParameterObject.privateRepo) activityLog=$($TemplateParameterObject.exportActivityLog)"
    foreach ($k in 'location','storageAccountName','operatorPrincipalId') { if (-not $TemplateParameterObject[$k]) { throw "missing $k" } }
    $global:St.runStore.deployed = $true
    return [pscustomobject]@{ ProvisioningState='Succeeded'; Outputs=@{} }
  }
  if ($TemplateFile -match 'portal') {
    # bicep/portal/main.bicep (Publish-AvdPortal.ps1)
    $p = $TemplateParameterObject; $global:St.portalDeploy = $p
    Log "deploy $Name hosting=$($p.hosting) location=$Location swaLocation=$($p.staticWebAppLocation) uploader=$($p.uploaderObjectId)"
    $rg = "rg-$($p.namePrefix)-$($p.environmentName)-portal"; if ($global:St.rgs -notcontains $rg) { $global:St.rgs += $rg }
    $v = { param($x) [pscustomobject]@{Value=$x} }
    $out = if ($p.hosting -eq 'StaticWebApp') { @{ resourceName=(& $v "stapp-$($p.namePrefix)-$($p.environmentName)-portal"); portalUrl=(& $v "https://$($global:St.swaHost)/") } }
      else { @{ resourceName=(& $v 'stavdlzdevwebabc123'); portalUrl=(& $v 'https://stavdlzdevwebabc123.z13.web.core.windows.net/') } }
    return [pscustomobject]@{ ProvisioningState='Succeeded'; Outputs=($out + @{ resourceGroupName=(& $v $rg); hosting=(& $v $p.hosting) }) }
  }
  Log "deploy $Name pwType=$($TemplateParameterObject.localAdminPassword.GetType().Name) dns=$($TemplateParameterObject.avdPrivateDnsZoneResourceId -split '/' | select -last 1)"
  foreach ($k in 'sessionHostSubnetResourceId','usersGroupObjectId','avdServicePrincipalObjectId','profileShareUncPath') { if (-not $TemplateParameterObject[$k]) { throw "missing $k" } }
  $global:St.rgs += 'rg-avdlz-dev-demo'
  if ($null -eq $global:St.deployments) { $global:St.deployments = @('avdlz-governance-avdlz-dev-eastus2', 'avdlz-dev-20260929-101500') }
  if ($global:St.deployments -notcontains $Name) { $global:St.deployments += $Name }
  $v = { param($x) [pscustomobject]@{Value=$x} }
  [pscustomobject]@{ProvisioningState='Succeeded';Outputs=@{resourceGroupName=(& $v 'rg-avdlz-dev-demo');hostPoolResourceId=(& $v "$S/resourceGroups/rg-avdlz-dev-demo/providers/Microsoft.DesktopVirtualization/hostPools/vdpool-avdlz-dev-demo");hostPoolName=(& $v 'vdpool-avdlz-dev-demo');appGroupResourceId=(& $v "$S/resourceGroups/rg-avdlz-dev-demo/providers/Microsoft.DesktopVirtualization/applicationGroups/vdag-avdlz-dev-demo-desktop");workspaceResourceId=(& $v 'ws');sessionHostNames=(& $v @('avdlzddemo-001'))}}
}
# Subscription deployment records ($global:St.deployments; default: one landing zone's).
function Get-AzDeployment { param($Name,$ErrorAction)
  $names = if ($null -ne $global:St.deployments) { $global:St.deployments } else { @('avdlz-governance-avdlz-dev-eastus2', 'avdlz-dev-20260929-101500') }
  if ($Name) { if ($names -contains $Name -or $Name -notlike 'avdlz-demo-*') { [pscustomobject]@{DeploymentName=$Name} } } else { @($names | ForEach-Object { [pscustomobject]@{DeploymentName=$_} }) } }
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
  # ---- The run store's records container over Blob REST, as the deadline runbook reads and writes it. Same
  # blobs as the record sync below ($global:St.records: name -> @{ etag; content }).
  if ($Uri -match '^https://avdlzruns[0-9a-f]{12}\.blob\.core\.windows\.net/records/(.+)$') {
    $name = $Matches[1]
    if ($Headers.Authorization -notin 'Bearer mi-token', 'Bearer cs-token' -or -not $Headers['x-ms-version']) { throw "no bearer token or x-ms-version for $Uri" }
    if ($null -eq $global:St.records) { $global:St.records = @{} }
    $have = $global:St.records[$name]
    if ($Method -eq 'Put') {
      Log "BLOB PUT records/$name"
      if ($have -and $Headers['If-None-Match'] -eq '*') { throw 'Response status code does not indicate success: 409 (The specified blob already exists.).' }
      $text = if ($Body -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($Body) } else { "$Body" }
      $global:St.recordsEtag++; $global:St.records[$name] = @{ etag = "r$($global:St.recordsEtag)"; content = $text }; return
    }
    if (-not $have) { throw 'Response status code does not indicate success: 404 (The specified blob does not exist.).' }
    return $have.content
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
# Microsoft's default app (Microsoft Graph Command Line Tools) when no -ClientId is given, as the SDK does.
function Connect-MgGraph { param($Scopes,$TenantId,$ClientId,[switch]$NoWelcome,[switch]$UseDeviceCode,$ErrorAction)
  if ($global:St.graphTimeout) { Log "graph connect timeout"; throw 'Authentication timed out after 120 seconds due to inactivity. Please try again.' }
  $client = if ($ClientId) { $ClientId } else { '14d82eec-204b-4c2f-b7e8-296a70dab67e' }
  $global:MgCtx=[pscustomobject]@{TenantId=$TenantId;Scopes=$Scopes;ClientId=$client}; Log "graph connect client=$(if ($ClientId) { $ClientId } else { 'default' }) $($Scopes -join ' ')"; if ($UseDeviceCode) { Write-Output 'To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code ABCD-1234 to authenticate.' } }
function Invoke-MgGraphRequest { param($Method,$Uri,$Body,$ContentType,$OutputType,$ErrorAction)
  $u=[uri]::UnescapeDataString($Uri); Log "GRAPH $Method $u"
  $b = if ($Body) { $Body | ConvertFrom-Json } else { $null }
  $appId='55555555-5555-5555-5555-555555555555'
  # The operator app (Initialize-AvdGraphApp.ps1): $global:St.opApp, .opSp and .opAssigned once created.
  $opAppId='77777777-7777-7777-7777-777777777777'
  if ($Method -eq 'POST' -and $u -match 'v1.0/applications$') { $global:St.opApp=[pscustomobject]@{id='op-app';appId=$opAppId;displayName=$b.displayName;isFallbackPublicClient=$b.isFallbackPublicClient;publicClient=$b.publicClient;requiredResourceAccess=$b.requiredResourceAccess}; return $global:St.opApp }
  if ($Method -eq 'PATCH' -and $u -match 'applications/op-app$') { foreach ($k in $b.PSObject.Properties.Name) { $global:St.opApp.$k = $b.$k }; return $null }
  # As Entra does: a new service principal takes the app's display name, and keeps its own afterwards.
  if ($Method -eq 'POST' -and $u -match 'v1.0/servicePrincipals$' -and $b.appId -eq $opAppId) { $global:St.opSp=[pscustomobject]@{id='op-sp';appId=$opAppId;displayName=$global:St.opApp.displayName;appRoleAssignmentRequired=$b.appRoleAssignmentRequired}; return $global:St.opSp }
  if ($Method -eq 'PATCH' -and $u -match 'servicePrincipals/op-sp$') { foreach ($k in $b.PSObject.Properties.Name) { $global:St.opSp.$k = $b.$k }; return $null }
  if ($Method -eq 'POST' -and $u -match 'servicePrincipals/op-sp/appRoleAssignedTo$') { $global:St.opAssigned = @(@($global:St.opAssigned) | ? { $_ }) + $b.principalId; return $b }
  if ($Method -eq 'PATCH' -and $u -match 'oauth2PermissionGrants/(.+)$') { $gid=$Matches[1]; foreach ($g in @($global:St.grants)) { if ($g.id -eq $gid) { $g.scope=$b.scope } }; return $null }
  if ($Method -eq 'POST' -and $u -match 'oauth2PermissionGrants$') { $b | Add-Member -NotePropertyName id -NotePropertyValue "grant-$(@($global:St.grants).Count + 1)" -Force; $global:St.grants += $b; return $b }
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
    "applications\?.*displayName eq '(avd-opsbot|AVD Landing Zone Operator)'" { $n=$Matches[1]; @{value=@($global:St.opApp | ? { $_ -and $_.displayName -eq $n })}; break }
    "servicePrincipals\?.*appId eq '$opAppId'" { @{value=@($global:St.opSp | ? { $_ })}; break }
    'servicePrincipals/op-sp/appRoleAssignedTo' { @{value=@(@($global:St.opAssigned) | ? { $_ } | % { @{principalId=$_} })}; break }
    "oauth2PermissionGrants\?.*clientId eq '([^']+)'" { $c=$Matches[1]; @{value=@(@($global:St.grants) | ? { -not $_.clientId -or $_.clientId -eq $c })}; break }
    '^v1.0/me\?' { @{id='me-1';userPrincipalName='nick@contoso.com'}; break }
    'groups/[0-9a-f-]+/members' { @{value=@(@{id='u1'})} }
    # Owners of a group found by name ($global:St.groupOwners; none unless a scenario sets them), and the
    # directory roles whose members may own the landing zone's groups: only Global Administrator is activated.
    'groups/[0-9a-f-]+/owners' { @{value=@(@($global:St.groupOwners) | ? { $_ })} }
    "directoryRoles\?.*roleTemplateId eq '([0-9a-f-]+)'" { @{value=@(if ($Matches[1] -like '62e90394*') { @{id='role-ga'} })} }
    'directoryRoles/role-ga/members' { @{value=@(@{id='admin-1'})} }
    # The storage account's Entra app has no owners, as the one Azure creates never has. A scenario can add a
    # user-registered app of the same name beside it ($global:St.storageAppImposter = 'beside') or in its place ('only').
    'applications/app-obj/owners' { @{value=@()} }
    'applications/app-fake/owners' { @{value=@(@{id='u-eve'})} }
    "groups\?.*displayName eq '([^']+)'" { $n=$Matches[1]; @{value=@($global:St.groups | ? { $_.displayName -eq $n })} }
    "servicePrincipals\?.*appId eq '9cdead84" { @{value=@(if ($global:St.avdSp) { @{id='33333333-3333-3333-3333-333333333333';appId='9cdead84-a844-4324-93f2-b2e6bb768d07'} })} }
    'me/memberOf' { @{value=@(@{displayName='Global Administrator'})} }
    'groups/(\w{8}-[\w-]+)\?' { @{id=$Matches[1];displayName="grp-$($Matches[1].Substring(0,4))";onPremisesSecurityIdentifier=$null} }
    'subscribedSkus' { @{value=@(@{servicePlans=@(@{servicePlanName='INTUNE_A';provisioningStatus='Success'})})} }
    '^v1.0/applications\?' { @{value=@(
        $(if ($global:St.storageAppImposter -ne 'only') { @{id='app-obj';appId=$appId;displayName='[Storage Account] x';createdDateTime='2026-09-30T00:00:00Z';tags=$global:St.tags;requiredResourceAccess=@(@{resourceAppId='00000003-0000-0000-c000-000000000000';resourceAccess=@(@{id='s1';type='Scope'},@{id='s2';type='Scope'},@{id='s3';type='Scope'})})} })
        $(if ($global:St.storageAppImposter) { @{id='app-fake';appId='66666666-6666-6666-6666-666666666666';displayName='[Storage Account] x';createdDateTime='2026-09-29T00:00:00Z';tags=@();requiredResourceAccess=@()} })
      )} }
    # As in a real tenant (lesson 0030): Device.ReadWrite.All is issued in tokens but not listed here.
    "servicePrincipals\?.*appId eq '00000003" { @{value=@(@{id='graph-sp';oauth2PermissionScopes=@(@{id='s1';value='openid'},@{id='s2';value='profile'},@{id='s3';value='User.Read'},@{id='s4';value='offline_access'},
      @{id='s5';value='Application.ReadWrite.All'},@{id='s6';value='DelegatedPermissionGrant.ReadWrite.All'},@{id='s7';value='Policy.Read.All'},@{id='s8';value='Policy.ReadWrite.ConditionalAccess'},
      @{id='s9';value='Group.ReadWrite.All'},@{id='s10';value='Directory.Read.All'},@{id='s12';value='DeviceManagementManagedDevices.ReadWrite.All'})})} }
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
