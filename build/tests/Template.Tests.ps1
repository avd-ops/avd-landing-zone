#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Guards on the compiled Bicep template for failures seen in real deployments.
# Needs the Bicep CLI on PATH.

BeforeAll {
  $script:bicep = (Get-Command bicep -ErrorAction Stop).Source
  $env:AVD_USERS_GROUP_ID = '00000000-0000-0000-0000-000000000001'
  $env:AVD_ADMINS_GROUP_ID = '00000000-0000-0000-0000-000000000002'
  $env:AVD_SERVICE_PRINCIPAL_ID = '00000000-0000-0000-0000-000000000003'
  $env:AVD_LOCAL_ADMIN_PASSWORD = 'Placeholder-only-for-build-1!'
  function Get-CompiledTemplate([string] $ParameterFile) {
    $raw = & $script:bicep build-params $ParameterFile --stdout 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bicep build-params failed: $raw" }
    (($raw -join "`n") | ConvertFrom-Json -Depth 100).templateJson | ConvertFrom-Json -Depth 100 -AsHashtable
  }
  function Find-Deployment($Template, [string] $Name) {
    foreach ($r in @($Template.resources.Values) + @($Template.resources)) {
      if ($r -is [System.Collections.IDictionary] -and $r['type'] -eq 'Microsoft.Resources/deployments') {
        if ($r['name'] -eq $Name) { return $r }
        $inner = $r['properties']['template']
        if ($inner) { $hit = Find-Deployment $inner $Name; if ($hit) { return $hit } }
      }
    }
  }
}

Describe 'NAT Gateway public IP zones' {
  # build/lessons/0001: the AVM nat-gateway module defaults its public IP to zones 1-3,
  # which fails in regions without availability zones (North Central US).
  It 'follows the landing zone availabilityZones instead of the module default' {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $network = Find-Deployment $t 'avdlz-network'
    $network['properties']['parameters']['availabilityZones'] | Should -Not -BeNullOrEmpty
    $nat = Find-Deployment $network['properties']['template'] 'nat-gateway'
    $pip = $nat['properties']['parameters']['publicIPAddresses']['value'][0]
    $pip['availabilityZones'] | Should -Match "empty\(parameters\('availabilityZones'\)\)"
  }
}

Describe 'Region override' {
  It 'takes the region from AVD_LOCATION and defaults when it is empty' {
    $env:AVD_LOCATION = 'westus2'
    try { (& $script:bicep build-params 'parameters/dev.bicepparam' --stdout | ConvertFrom-Json).parametersJson | Should -Match '"location":\s*\{\s*"value":\s*"westus2"' }
    finally { $env:AVD_LOCATION = '' }
    (& $script:bicep build-params 'parameters/dev.bicepparam' --stdout | ConvertFrom-Json).parametersJson | Should -Match '"location":\s*\{\s*"value":\s*"northcentralus"'
  }
}

Describe 'Sizing overrides' {
  # The deployment portal's sizing step passes these through deploy.sh and the preflight.
  # Set-but-empty must fall back to the file's value (build/lessons/0004).
  It 'takes host count, size, sessions and profile quota from the environment, and defaults when empty' {
    foreach ($file in 'parameters/dev.bicepparam', 'parameters/test.bicepparam', 'parameters/prod.bicepparam') {
      $env:AVD_SESSION_HOST_COUNT = '3'; $env:AVD_SESSION_HOST_VM_SIZE = 'Standard_D8as_v5'; $env:AVD_MAX_SESSION_LIMIT = '16'; $env:AVD_PROFILE_QUOTA_GIB = '600'
      try { $p = ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters }
      finally { $env:AVD_SESSION_HOST_COUNT = ''; $env:AVD_SESSION_HOST_VM_SIZE = ''; $env:AVD_MAX_SESSION_LIMIT = ''; $env:AVD_PROFILE_QUOTA_GIB = '' }
      $p.sessionHostCount.value | Should -Be 3
      $p.sessionHostVmSize.value | Should -Be 'Standard_D8as_v5'
      $p.maxSessionLimit.value | Should -Be 16
      $p.profileShareQuotaGiB.value | Should -Be 600
      $d = ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters
      $d.sessionHostVmSize.value | Should -Be 'Standard_E4as_v5'   # memory-optimized default for multi-session
      $d.maxSessionLimit.value | Should -Be 8
    }
  }

  # The portal's Cost step passes these through deploy.sh (--auto-shutdown, --start-vm-on-connect).
  It 'takes the scheduled stop and Start VM on Connect from the environment; none = no scheduled stop' {
    $read = { param($file) ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters }
    foreach ($case in @(
        @{ file = 'parameters/dev.bicepparam'; time = ''; svmoc = ''; expectTime = '20:00'; expectSvmoc = $true },
        @{ file = 'parameters/prod.bicepparam'; time = ''; svmoc = ''; expectTime = ''; expectSvmoc = $true },
        @{ file = 'parameters/dev.bicepparam'; time = 'none'; svmoc = 'false'; expectTime = ''; expectSvmoc = $false },
        @{ file = 'parameters/prod.bicepparam'; time = '18:30'; svmoc = 'true'; expectTime = '18:30'; expectSvmoc = $true })) {
      $env:AVD_AUTO_SHUTDOWN_TIME = $case.time; $env:AVD_START_VM_ON_CONNECT = $case.svmoc
      try { $p = & $read $case.file } finally { $env:AVD_AUTO_SHUTDOWN_TIME = ''; $env:AVD_START_VM_ON_CONNECT = '' }
      $p.autoShutdownTime.value | Should -Be $case.expectTime -Because "$($case.file) time='$($case.time)'"
      $p.startVmOnConnect.value | Should -Be $case.expectSvmoc -Because "$($case.file) svmoc='$($case.svmoc)'"
    }
  }
}

Describe 'Auto shutdown' {
  # decision 0011: a runbook started by a schedule and by the budget's action group.
  It 'deploys the runbook, the dev schedule and the runbook identity''s roles' {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $auto = Find-Deployment $t 'avdlz-auto-shutdown'
    $auto | Should -Not -BeNullOrEmpty
    $inner = $auto['properties']['template']
    $res = @($inner['resources'].Values) + @($inner['resources']) | Where-Object { $_ -is [System.Collections.IDictionary] }
    ($res | Where-Object type -eq 'Microsoft.Automation/automationAccounts/runbooks')['properties']['runbookType'] | Should -Be 'PowerShell'
    ($res | Where-Object type -eq 'Microsoft.Automation/automationAccounts')['properties']['disableLocalAuth'] | Should -BeTrue
    $wf = @($res | Where-Object type -eq 'Microsoft.Logic/workflows')
    $wf.Count | Should -Be 2
    ($wf | ForEach-Object { $_['properties']['definition']['triggers'] | ConvertTo-Json -Depth 10 }) -join ' ' | Should -Match 'Recurrence'
    # format() escapes the braces: '@{{guid()}}' becomes the Logic Apps expression '@{guid()}'.
    ($inner['functions'] | ConvertTo-Json -Depth 20) | Should -Match 'jobs/@\{\{guid\(\)\}\}'
    ($inner['functions'] | ConvertTo-Json -Depth 20) | Should -Match 'ManagedServiceIdentity'
    $p = ((& $script:bicep build-params 'parameters/dev.bicepparam' --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters
    $p.autoShutdownTime.value | Should -Be '20:00'
    $p.autoShutdownRunbookUri.value | Should -Match '^https://raw\.githubusercontent\.com/.+/scripts/automation/Invoke-AvdPowerAction\.ps1$'
    ($t['variables']['roleIds'] | ConvertTo-Json) | Should -Match '082f0a83-3be5-4ba1-904c-961cca79b387'
    (Find-Deployment $t 'avdlz-auto-shutdown-rbac-hosts') | Should -Not -BeNullOrEmpty
    (Find-Deployment $t 'avdlz-auto-shutdown-rbac-avd') | Should -Not -BeNullOrEmpty
  }
  It 'has the budget call the auto-shutdown action group' {
    $t = Get-CompiledTemplate 'parameters/prod.bicepparam'
    $gov = @($t['resources'].Values) + @($t['resources']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -match 'avdlz-governance' }
    ($gov['properties']['parameters']['budgetActionGroupId'] | ConvertTo-Json) | Should -Match "budgetActionGroupId"
    $budget = @($gov['properties']['template']['resources'].Values) + @($gov['properties']['template']['resources']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['type'] -eq 'Microsoft.Consumption/budgets' }
    ($budget['properties']['notifications'] | ConvertTo-Json) | Should -Match 'contactGroups'
  }
  It 'takes an empty AVD_MONTHLY_BUDGET as no budget (build/lessons/0004)' {
    foreach ($file in 'parameters/dev.bicepparam', 'parameters/prod.bicepparam') {
      $env:AVD_MONTHLY_BUDGET = ''
      ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters.monthlyBudgetAmount.value | Should -Be 0
    }
  }
}

Describe 'A second landing zone beside dev (parameters/test.bicepparam, docs/demo.md)' {
  It 'is dev''s footprint under its own names, and leaves the subscription-wide pieces to dev' {
    $read = { param($file) ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters }
    $dev = & $read 'parameters/dev.bicepparam'; $test = & $read 'parameters/test.bicepparam'
    $test.environmentName.value | Should -Be 'test'
    $test.deploySubscriptionSettings.value | Should -BeFalse
    $dev.PSObject.Properties.Name | Should -Not -Contain 'deploySubscriptionSettings'   # dev owns them (default true)
    foreach ($p in 'namePrefix', 'sessionHostCount', 'sessionHostVmSize', 'profileShareQuotaGiB', 'enableProfileBackup', 'enableDefenderForCloud', 'autoShutdownTime') {
      ($test.$p.value | ConvertTo-Json -Compress) | Should -Be ($dev.$p.value | ConvertTo-Json -Compress) -Because $p
    }
  }
  It 'turns off the policy guardrails and the activity log export when deploySubscriptionSettings is false' {
    $t = Get-CompiledTemplate 'parameters/test.bicepparam'
    $gov = Find-Deployment $t "[take(format('avdlz-governance-{0}-{1}', variables('baseName'), parameters('location')), 64)]"
    $gov.properties.parameters.enablePolicyGuardrails.value | Should -Be "[and(parameters('enablePolicyGuardrails'), parameters('deploySubscriptionSettings'))]"
    $gov.properties.parameters.deployActivityLog.value | Should -Be "[parameters('deploySubscriptionSettings')]"
  }
}


Describe 'Golden image pipeline templates' {
  # build/specs/image-pipeline-spec.md. The landing zone only changes when the build subnets are asked for.
  It 'adds the build subnets only with AVD_IMAGE_BUILD_SUBNETS=true (set-but-empty = off, lesson 0004)' {
    $read = { param($v) $env:AVD_IMAGE_BUILD_SUBNETS = $v; try { ((& $script:bicep build-params 'parameters/dev.bicepparam' --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters.deployImageBuildSubnets.value } finally { $env:AVD_IMAGE_BUILD_SUBNETS = '' } }
    & $read '' | Should -BeFalse
    & $read 'true' | Should -BeTrue
    $network = Find-Deployment (Get-CompiledTemplate 'parameters/prod.bicepparam') 'avdlz-network'
    $network['properties']['parameters']['deployImageBuildSubnets'] | Should -Not -BeNullOrEmpty
  }

  It 'gives both build subnets an NSG and the hosts'' egress, and delegates the container subnet to ACI' {
    $raw = (& $script:bicep build 'bicep/modules/network.bicep' --stdout) -join "`n"
    $raw | Should -Match "'snet-image-build'"
    $raw | Should -Match "'snet-image-aci'"
    $raw | Should -Match 'Microsoft.ContainerInstance/containerGroups'
    $raw | Should -Match 'nsg-image-build'
  }

  It 'defines a Generation 2, Trusted Launch image with accelerated networking, and federates the build identity to the images environment only' {
    $t = Get-CompiledTemplate 'parameters/images.bicepparam'
    $g = Find-Deployment $t 'avdlz-images-gallery'
    $res = $g['properties']['template']['resources']; if ($res -is [System.Collections.IDictionary]) { $res = @($res.Values) }
    $def = @($res | Where-Object { $_['type'] -eq 'Microsoft.Compute/galleries/images' })[0]
    $def['properties']['hyperVGeneration'] | Should -Be 'V2'
    $f = @{}; foreach ($x in $def['properties']['features']) { $f[$x['name']] = $x['value'] }
    $f['SecurityType'] | Should -Be 'TrustedLaunch'
    $f['IsAcceleratedNetworkSupported'] | Should -Be 'True'
    $fed = @($res | Where-Object { $_['type'] -eq 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials' })[0]
    $fed['properties']['subject'] | Should -Match 'environment:images'
  }

  It 'inlines every image script and the WDOT profile, fetches nothing from this repo, and never publishes to latest' {
    $o = (& $script:bicep build-params 'parameters/images-build.bicepparam' --stdout) -join "`n" | ConvertFrom-Json
    $raw = $o.templateJson
    $raw | Should -Not -Match 'scriptUri'
    $raw | Should -Not -Match 'raw\.githubusercontent\.com'
    foreach ($f in Get-ChildItem 'scripts/image/wdot/profile' -File) {
      $raw.Contains([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))) | Should -BeTrue -Because "$($f.Name) must be inlined as it is in the repo"
    }
    $src = Get-Content 'bicep/images/build.bicep' -Raw
    foreach ($s in Get-ChildItem 'scripts/image' -Filter '*.ps1' -Recurse) {
      $rel = [IO.Path]::GetRelativePath((Resolve-Path 'scripts/image'), $s.FullName).Replace('\', '/')
      $src | Should -Match ([regex]::Escape("scripts/image/$rel")) -Because "$rel must be a build step"
    }
    $t = $raw | ConvertFrom-Json -Depth 100 -AsHashtable
    $it = @(@($t['resources'].Values) | Where-Object { $_['type'] -eq 'Microsoft.VirtualMachineImages/imageTemplates' })[0]
    $it['properties']['distribute'][0]['excludeFromLatest'] | Should -BeTrue
    $it['properties']['validate']['continueDistributeOnFailure'] | Should -BeFalse
    $it['properties']['vmProfile']['vnetConfig']['containerInstanceSubnetId'] | Should -Not -BeNullOrEmpty
    (($o.parametersJson | ConvertFrom-Json).parameters.buildTimeoutInMinutes.value) | Should -Be 360
  }
}

Describe 'Connection logs for Verify access (decision 0014)' {
  # Test-AvdUserConnection.ps1 reads WVDConnections (host pool), WVDErrors and WVDCheckpoints (host pool,
  # app group, workspace). They arrive only while each diagnostic setting sends allLogs: the AVM default
  # when logCategoriesAndGroups is left out.
  BeforeAll {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $script:cp = Find-Deployment $t 'avdlz-control-plane'
  }
  It 'sends every log category of the host pool, app group and workspace to Log Analytics' {
    $diag = @($cp['properties']['template']['variables']['diagnostics'])
    $diag.Count | Should -Be 1
    $diag[0].Keys | Should -Contain 'workspaceResourceId'
    $diag[0].Keys | Should -Not -Contain 'logCategoriesAndGroups'
    foreach ($name in 'host-pool', 'app-group', 'workspace') {
      $d = Find-Deployment $cp['properties']['template'] $name
      $d['properties']['parameters']['diagnosticSettings']['value'] | Should -Be "[variables('diagnostics')]" -Because $name
      $setting = @($d['properties']['template']['resources'].Values + $d['properties']['template']['resources'] |
          Where-Object { $_ -is [System.Collections.IDictionary] -and "$($_['type'])" -like '*/diagnosticSettings' })[0]
      # The logs are a copy loop over logCategoriesAndGroups, defaulting to allLogs.
      ($setting['properties'] | ConvertTo-Json -Depth 20 -Compress) | Should -Match "logCategoriesAndGroups'\), createArray\(createObject\('categoryGroup', 'allLogs'\)\)" -Because $name
    }
  }
}

Describe 'Files the templates load are committed (build/lessons/0027)' {
  # A file a template reads at compile time (loadTextContent, loadJsonContent, loadFileAsBase64,
  # loadYamlContent) builds locally even when .gitignore keeps it out of git, then fails in CI and
  # for everyone else. A repo-wide *.json rule did exactly that to the image pipeline's data files.
  It 'tracks every file a Bicep template loads' {
    $tracked = @(git ls-files --full-name | ForEach-Object { $_ })
    $tracked.Count | Should -BeGreaterThan 0 -Because 'the test needs a git checkout'
    $missing = foreach ($file in Get-ChildItem 'bicep' -Filter '*.bicep' -Recurse) {
      $src = Get-Content $file.FullName -Raw
      foreach ($m in [regex]::Matches($src, "load(?:TextContent|JsonContent|FileAsBase64|YamlContent)\('([^']+)'")) {
        $full = [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $m.Groups[1].Value))
        $rel = [IO.Path]::GetRelativePath((Get-Location).Path, $full).Replace('\', '/')
        if ($tracked -notcontains $rel) { "$rel (loaded by $([IO.Path]::GetRelativePath((Get-Location).Path, $file.FullName)))" }
      }
    }
    @($missing) | Should -BeNullOrEmpty -Because 'git add the file; if .gitignore hides it, narrow the rule'
  }
}

Describe 'Profile share SMB channel encryption (build/lessons/0028)' {
  # With AES-256-GCM as the only channel encryption, Azure Files rejects an Entra Kerberos
  # SESSION_SETUP from a cloud-only user with STATUS_ACCESS_DENIED and FSLogix cannot attach.
  It 'allows AES-128-GCM beside AES-256-GCM, and no CCM' {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $storage = Find-Deployment $t 'avdlz-storage'
    $account = Find-Deployment $storage['properties']['template'] 'storage-account'
    $channel = $account['properties']['parameters']['fileServices']['value']['protocolSettings']['smb']['channelEncryption']
    $channel | Should -Match 'AES-128-GCM'
    $channel | Should -Match 'AES-256-GCM'
    $channel | Should -Not -Match 'CCM'
  }
}

Describe 'Demo hosts stop on their own (avd-second-brain decision 0017)' {
  # The landing zone auto shutdown runbook covers only vdpool-<base>; the demo pool needs its own schedule.
  It 'gives the demo hosts a daily shutdown by default, and the landing zone hosts none of their own' {
    $raw = & $script:bicep build bicep/demo/main.bicep --stdout 2>&1
    $LASTEXITCODE | Should -Be 0 -Because "$raw"
    $t = ($raw -join "`n") | ConvertFrom-Json -Depth 100 -AsHashtable
    $t['parameters']['autoShutdownTime']['defaultValue'] | Should -Be '2000'
    $hosts = Find-Deployment $t 'avdlz-demo-session-hosts'
    $hosts['properties']['parameters']['autoShutdownTime']['value'] | Should -Be "[parameters('autoShutdownTime')]"
    $lz = Find-Deployment (Get-CompiledTemplate 'parameters/dev.bicepparam') 'avdlz-session-hosts'
    if ($lz) { $lz['properties']['parameters'].Keys | Should -Not -Contain 'autoShutdownTime' }
  }
}

Describe 'Recovery region and profile backup tier (build/specs/recovery-spec.md)' {
  It 'allows only location by default, and adds AVD_RECOVERY_LOCATION when set (set-but-empty = none, lesson 0004)' {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $t.parameters.recoveryLocation.defaultValue | Should -Be ''
    $t.parameters.allowedLocations.defaultValue | Should -Be "[union(createArray(parameters('location')), if(empty(parameters('recoveryLocation')), createArray(), createArray(parameters('recoveryLocation'))))]"
    foreach ($file in 'parameters/dev.bicepparam', 'parameters/test.bicepparam', 'parameters/prod.bicepparam') {
      $read = { param($v) $env:AVD_RECOVERY_LOCATION = $v; try { ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters.recoveryLocation.value } finally { $env:AVD_RECOVERY_LOCATION = '' } }
      & $read '' | Should -Be '' -Because $file
      & $read 'southcentralus' | Should -Be 'southcentralus' -Because $file
    }
  }
  It 'keeps storage key access off unless the vaulted backup tier needs it' {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $t.parameters.profileBackupTier.defaultValue | Should -Be 'Snapshot'
    $storage = Find-Deployment $t 'avdlz-storage'
    $storage.properties.parameters.allowSharedKeyAccess.value | Should -Be "[and(parameters('enableProfileBackup'), equals(parameters('profileBackupTier'), 'Vaulted'))]"
    $account = Find-Deployment $storage['properties']['template'] 'storage-account'
    $account.properties.parameters.allowSharedKeyAccess.value | Should -Be "[parameters('allowSharedKeyAccess')]"
    $account.properties.parameters.publicNetworkAccess.value | Should -Be 'Disabled'
    $account.properties.parameters.fileServices.value.protocolSettings.smb.authenticationMethods | Should -Be 'Kerberos;'
  }
}

Describe 'Profile backup tier (build/specs/recovery-spec.md section 4)' {
  BeforeAll {
    $t = Get-CompiledTemplate 'parameters/prod.bicepparam'
    $script:backup = Find-Deployment $t 'avdlz-backup'
    $inner = $script:backup['properties']['template']
    $res = @($inner['resources'].Values) + @($inner['resources']) | Where-Object { $_ -is [System.Collections.IDictionary] }
    $script:vault = $res | Where-Object { $_['type'] -eq 'Microsoft.RecoveryServices/vaults' }
    $script:policy = $res | Where-Object { $_['type'] -eq 'Microsoft.RecoveryServices/vaults/backupPolicies' }
    $script:main = $t
  }
  It 'passes profileBackupTier from main.bicep, defaulting to Snapshot' {
    $script:backup['properties']['parameters']['profileBackupTier']['value'] | Should -Be "[parameters('profileBackupTier')]"
    $script:main['parameters']['profileBackupTier']['defaultValue'] | Should -Be 'Snapshot'
  }
  It 'changes the vault''s redundancy only for the vaulted tier, so the default deployment is unchanged' {
    $script:vault['properties'] | Should -Match "if\(variables\('vaulted'\), createObject\('redundancySettings', createObject\('standardTierStorageRedundancy', 'GeoRedundant', 'crossRegionRestore', 'Enabled'\)\), createObject\(\)\)"
  }
  It 'keeps the snapshot policy name for the default tier and adds a vault retention policy only for Vaulted' {
    $script:policy['name'] | Should -Match "if\(variables\('vaulted'\), 'fslogix-daily-vaulted', 'fslogix-daily'\)"
    $script:policy['properties'] | Should -Match "if\(variables\('vaulted'\), createObject\('vaultRetentionPolicy'"
  }
}

Describe 'Host resource alerts read only what AVD Insights collects' {
  # The disk, memory and CPU alerts query Perf. They fire only for counters the AVD Insights data
  # collection rule sends, so a counter dropped from the rule would silence its alert without an error.
  BeforeAll {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $script:mon = Find-Deployment $t 'avdlz-monitoring'
    $dcr = Find-Deployment $mon['properties']['template'] 'dcr-avd-insights'
    $script:counters = @($dcr['properties']['parameters']['dataCollectionRuleProperties']['value']['dataSources']['performanceCounters'] |
        ForEach-Object { $_['counterSpecifiers'] })
    $script:alerts = @($mon['properties']['template']['variables']['logAlerts'])
  }
  It 'has the low disk, low memory and high CPU alerts' {
    $alerts.name | Should -Contain 'host-low-disk'
    $alerts.name | Should -Contain 'host-low-memory'
    $alerts.name | Should -Contain 'host-high-cpu'
  }
  It 'collects every counter a Perf alert reads' {
    foreach ($a in @($alerts | Where-Object { $_.query -match '^\s*Perf\b' })) {
      $object = [regex]::Match($a.query, 'ObjectName == "([^"]+)"').Groups[1].Value
      $counter = [regex]::Match($a.query, 'CounterName (?:==|=~) "([^"]+)"').Groups[1].Value
      $object | Should -Not -BeNullOrEmpty -Because $a.name
      $hit = @($counters | Where-Object { $_ -like "\$object(*\$counter" -or $_ -like "\$object\$counter" })
      $hit.Count | Should -BeGreaterThan 0 -Because "$($a.name) reads $object\$counter"
    }
  }
}

Describe 'Image and generation for host rotation (build/specs/image-pipeline-spec.md section 6.1)' {
  BeforeAll {
    $script:t = Get-CompiledTemplate 'parameters/dev.bicepparam'
  }
  It 'takes the image, generation and rotation tags from the environment, and defaults to none when empty (lesson 0004)' {
    foreach ($file in 'parameters/dev.bicepparam', 'parameters/test.bicepparam', 'parameters/prod.bicepparam') {
      $env:AVD_SESSION_HOST_IMAGE_ID = '/subscriptions/x/resourceGroups/r/providers/Microsoft.Compute/galleries/g/images/d/versions/2026.1004.1'
      $env:AVD_SESSION_HOST_GENERATION = 'b'
      $env:AVD_HOST_POOL_STATE_TAGS = '{"avdlz-image":"/v/1","avdlz-generation":"a"}'
      try { $p = ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters }
      finally { $env:AVD_SESSION_HOST_IMAGE_ID = ''; $env:AVD_SESSION_HOST_GENERATION = ''; $env:AVD_HOST_POOL_STATE_TAGS = '' }
      $p.sessionHostImageId.value | Should -Match '/versions/2026\.1004\.1$'
      $p.sessionHostGeneration.value | Should -Be 'b'
      $p.hostPoolStateTags.value.'avdlz-generation' | Should -Be 'a'
      $p = ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters
      $p.sessionHostImageId.value | Should -BeNullOrEmpty
      $p.sessionHostGeneration.value | Should -BeNullOrEmpty
      @($p.hostPoolStateTags.value.PSObject.Properties).Count | Should -Be 0
    }
  }
  It 'keeps the marketplace image and the original host names by default' {
    $t.variables['hostImageReference'] | Should -Match "if\(empty\(parameters\('sessionHostImageId'\)\), parameters\('sessionHostImage'\), createObject\('id', parameters\('sessionHostImageId'\)\)\)"
    $t.variables['hostNamePrefix'] | Should -Match "if\(empty\(parameters\('sessionHostGeneration'\)\), parameters\('sessionHostNamePrefix'\), format\('\{0\}\{1\}', take\(parameters\('sessionHostNamePrefix'\), 10\), parameters\('sessionHostGeneration'\)\)\)"
    $t.parameters['sessionHostGeneration']['allowedValues'] | Should -Be @('', 'a', 'b')
    $hosts = Find-Deployment $t 'avdlz-session-hosts'
    $hosts['properties']['parameters']['namePrefix']['value'] | Should -Be "[variables('hostNamePrefix')]"
    $hosts['properties']['parameters']['imageReference']['value'] | Should -Be "[variables('hostImageReference')]"
  }
  It 'gives each generation valid, distinct names of 15 characters at most' {
    foreach ($prefix in 'avdlzdsh', 'contosoprsh') {
      $names = foreach ($gen in '', 'a', 'b') {
        $p = if ($gen) { $prefix.Substring(0, [Math]::Min(10, $prefix.Length)) + $gen } else { $prefix }
        "$p-001"
      }
      @($names | Sort-Object -Unique).Count | Should -Be 3
      $names | ForEach-Object { $_.Length | Should -BeLessOrEqual 15 }
    }
  }
  It 'keeps only the rotation tags on the host pool, and only when set' {
    $t.variables['rotationTagNames'] | Should -Be @('avdlz-image', 'avdlz-generation', 'avdlz-image-next', 'avdlz-image-previous', 'avdlz-rotation')
    $t.variables['keptHostPoolStateTags'] | Should -Match "contains\(variables\('rotationTagNames'\)"
    $t.variables['keptHostPoolStateTags'] | Should -Match 'not\(empty\('
    $cp = Find-Deployment $t 'avdlz-control-plane'
    $cp['properties']['parameters']['hostPoolStateTags']['value'] | Should -Be "[variables('keptHostPoolStateTags')]"
    $pool = Find-Deployment $cp['properties']['template'] 'host-pool'
    $pool['properties']['parameters']['tags']['value'] | Should -Match "parameters\('hostPoolStateTags'\)"
  }
}

Describe 'Pinned tool versions' {
  # The checks only mean the same everywhere if they run the same tools: CI, the session hook,
  # and the live -WellArchitected review (PSRule) read one set of versions from validate.yml.
  BeforeAll {
    $root = Join-Path $PSScriptRoot '../..'
    $workflow = Get-Content (Join-Path $root '.github/workflows/validate.yml') -Raw
    $script:pin = @{}
    foreach ($m in [regex]::Matches($workflow, '(?m)^  ([A-Z_]+_VERSION): (\S+)$')) { $script:pin[$m.Groups[1].Value] = $m.Groups[2].Value }
    $script:hook = Get-Content (Join-Path $root '.claude/hooks/session-start.sh') -Raw
    $script:module = Get-Content (Join-Path $root 'scripts/ops/AvdLandingZone.psm1') -Raw
  }
  It 'pins every tool in validate.yml and fetches no latest release' {
    foreach ($k in 'BICEP_VERSION', 'PSRULE_VERSION', 'PSRULE_AZURE_VERSION', 'PSSCRIPTANALYZER_VERSION', 'PESTER_VERSION') { $script:pin[$k] | Should -Not -BeNullOrEmpty -Because $k }
    Get-Content (Join-Path $PSScriptRoot '../../.github/workflows/validate.yml') -Raw | Should -Not -Match 'releases/latest|MinimumVersion'
    $script:hook | Should -Not -Match 'releases/latest|MinimumVersion'
  }
  It 'uses the same versions in the session hook' {
    $script:hook | Should -Match ([regex]::Escape("bicep/releases/download/$($script:pin.BICEP_VERSION)/"))
    $script:hook | Should -Match ([regex]::Escape("PSScriptAnalyzer/releases/download/$($script:pin.PSSCRIPTANALYZER_VERSION)/"))
    $script:hook | Should -Match ([regex]::Escape("Save-Module Pester -RequiredVersion $($script:pin.PESTER_VERSION) "))
    # An older cached copy is replaced, not kept.
    $script:hook | Should -Match ([regex]::Escape("grep -q 'version $($script:pin.BICEP_VERSION.TrimStart('v')) '"))
    $script:hook | Should -Match ([regex]::Escape("modules/Pester/$($script:pin.PESTER_VERSION)"))
  }
  It 'reads IDs and emails from secrets, never variables (Actions logs of a public repo print variables unmasked)' {
    foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '../../.github/workflows') -Filter '*.yml') {
      Get-Content $f.FullName -Raw | Should -Not -Match 'vars\.[A-Z_]*(_ID|EMAIL)\b' -Because $f.Name
    }
  }
  It 'builds images with the Bicep version CI checks' {
    Get-Content (Join-Path $PSScriptRoot '../../.github/workflows/image-build.yml') -Raw | Should -Match ([regex]::Escape("bicep/releases/download/$($script:pin.BICEP_VERSION)/"))
  }
  It 'runs the live PSRule review on the rules version CI uses' {
    $script:module | Should -Match ([regex]::Escape("`$script:PSRuleAzureVersion = '$($script:pin.PSRULE_AZURE_VERSION)'"))
    $script:module | Should -Match ([regex]::Escape("`$script:PSRuleVersion = '$($script:pin.PSRULE_VERSION)'"))
    $rules = Get-Content (Join-Path $PSScriptRoot '../../ps-rule.yaml') -Raw
    $rules | Should -Match ([regex]::Escape("PSRule: '$($script:pin.PSRULE_VERSION)'"))
    $rules | Should -Match ([regex]::Escape("PSRule.Rules.Azure: '$($script:pin.PSRULE_AZURE_VERSION)'"))
  }
}

Describe 'Operator jumpbox through Bastion Developer (decision 0019)' {
  # Off by default, so the landing zone's default deployment is unchanged; on, it stops daily unless
  # kept running until a time (avd-second-brain decision 0017), and has no public IP anywhere.
  It 'is off unless AVD_DEPLOY_JUMPBOX=true (set-but-empty = off, lesson 0004), in every parameter file' {
    foreach ($file in 'parameters/dev.bicepparam', 'parameters/test.bicepparam', 'parameters/prod.bicepparam') {
      $read = { param($v, $until, $exists, $os) $env:AVD_DEPLOY_JUMPBOX = $v; $env:AVD_JUMPBOX_KEEP_RUNNING_UNTIL = $until; $env:AVD_JUMPBOX_EXISTS = $exists; $env:AVD_JUMPBOX_OS = $os
        try { ((& $script:bicep build-params $file --stdout | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters }
        finally { $env:AVD_DEPLOY_JUMPBOX = ''; $env:AVD_JUMPBOX_KEEP_RUNNING_UNTIL = ''; $env:AVD_JUMPBOX_EXISTS = ''; $env:AVD_JUMPBOX_OS = '' } }
      $off = & $read '' '' '' ''
      $off.deployJumpbox.value | Should -BeFalse -Because $file
      $off.jumpboxKeepRunningUntil.value | Should -Be '' -Because $file
      $off.jumpboxExists.value | Should -BeFalse -Because $file
      $off.jumpboxOs.value | Should -Be 'Linux' -Because $file
      $on = & $read 'true' '2026-10-22T02:00Z' 'true' 'Windows'
      $on.jumpboxOs.value | Should -Be 'Windows' -Because $file
      $on.deployJumpbox.value | Should -BeTrue -Because $file
      $on.jumpboxKeepRunningUntil.value | Should -Be '2026-10-22T02:00Z' -Because $file
      $on.jumpboxExists.value | Should -BeTrue -Because $file
    }
  }

  It 'deploys the jumpbox, its resource group, subnet and Bastion only when deployJumpbox is true' {
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    foreach ($name in 'avdlz-bastion', 'avdlz-jumpbox') {
      (Find-Deployment $t $name)['condition'] | Should -Be "[parameters('deployJumpbox')]" -Because $name
    }
    $rg = @($t['resources'].Values | Where-Object { $_['type'] -eq 'Microsoft.Resources/resourceGroups' -and $_['name'] -eq "[variables('names').rgJumpbox]" })
    $rg.Count | Should -Be 1
    $rg[0]['condition'] | Should -Be "[parameters('deployJumpbox')]"
    (Find-Deployment $t 'avdlz-network')['properties']['parameters']['deployJumpboxSubnet']['value'] | Should -Be "[parameters('deployJumpbox')]"
    $t['parameters']['deployJumpbox']['defaultValue'] | Should -BeFalse
  }

  It 'uses the Developer SKU, attached to the VNet, with no subnet and no public IP' {
    $raw = (& $script:bicep build 'bicep/modules/bastionDeveloper.bicep' --stdout) -join "`n"
    $m = $raw | ConvertFrom-Json -Depth 50 -AsHashtable
    $all = if ($m['resources'] -is [System.Collections.IDictionary]) { @($m['resources'].Values) } else { @($m['resources']) }
    $b = @($all | Where-Object { $_['type'] -eq 'Microsoft.Network/bastionHosts' })[0]
    $b['sku']['name'] | Should -Be 'Developer'
    $b['properties']['virtualNetwork']['id'] | Should -Be "[parameters('vnetResourceId')]"
    $b['properties'].Keys | Should -Not -Contain 'ipConfigurations'
    $raw | Should -Not -Match 'Microsoft.Network/publicIPAddresses'
  }

  It 'builds a Linux Trusted Launch jumpbox with no public IP, a daily stop, and the stop off only when kept running' {
    $raw = (& $script:bicep build 'bicep/modules/jumpbox.bicep' --stdout) -join "`n"
    $m = $raw | ConvertFrom-Json -Depth 100 -AsHashtable
    $all = if ($m['resources'] -is [System.Collections.IDictionary]) { @($m['resources'].Values) } else { @($m['resources']) }
    $deployment = @($all | Where-Object { $_['type'] -eq 'Microsoft.Resources/deployments' })[0]
    # An existing VM is never re-sent: Azure refuses a change to its custom data and admin password.
    $deployment['condition'] | Should -Be "[not(parameters('vmExists'))]"
    $vm = $deployment['properties']['parameters']
    $vm['osType']['value'] | Should -Be "[parameters('osType')]"
    $m['parameters']['osType']['defaultValue'] | Should -Be 'Linux'
    $vm['securityType']['value'] | Should -Be 'TrustedLaunch'
    $vm.Keys | Should -Not -Contain 'autoShutdownConfig'
    # The daily stop is its own resource, always deployed: Disabled (not absent) while kept running,
    # so a redeploy turns off a stop that exists.
    $stop = @($all | Where-Object { $_['type'] -eq 'Microsoft.DevTestLab/schedules' })
    $stop.Count | Should -Be 1
    $stop[0].Keys | Should -Not -Contain 'condition'
    $stop[0]['name'] | Should -Be "[format('shutdown-computevm-{0}', parameters('vmName'))]"
    $stop[0]['properties']['status'] | Should -Be "[if(variables('keepRunning'), 'Disabled', 'Enabled')]"
    $tags = @($all | Where-Object { $_['type'] -eq 'Microsoft.Resources/tags' })
    $tags[0]['condition'] | Should -Be "[parameters('vmExists')]"
    ($vm['nicConfigurations'] | ConvertTo-Json -Depth 20) | Should -Not -Match 'pipConfiguration|publicIP'
    $m['variables']['vmTags'] | Should -Match 'avdlz-keep-running-until'
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $t['parameters']['jumpboxAutoShutdownTime']['defaultValue'] | Should -Be '2000'
    $t['parameters']['jumpboxVmSize']['defaultValue'] | Should -Be ''
    $t['parameters']['jumpboxOs']['defaultValue'] | Should -Be 'Linux'
    (Find-Deployment $t 'avdlz-jumpbox')['properties']['parameters']['vmSize'] | Should -Be "[if(not(empty(parameters('jumpboxVmSize'))), createObject('value', parameters('jumpboxVmSize')), if(equals(parameters('jumpboxOs'), 'Windows'), createObject('value', 'Standard_B2as_v2'), createObject('value', 'Standard_B2als_v2')))]"
  }

  It 'builds the Windows jumpbox from Windows Server 2025, with its first boot as a Run Command only when it is created' {
    $raw = (& $script:bicep build 'bicep/modules/jumpbox.bicep' --stdout) -join "`n"
    $m = $raw | ConvertFrom-Json -Depth 100 -AsHashtable
    $m['variables']['images']['Windows']['sku'] | Should -Be '2025-datacenter-azure-edition'
    $m['variables']['images']['Linux']['offer'] | Should -Be 'ubuntu-24_04-lts'
    $all = if ($m['resources'] -is [System.Collections.IDictionary]) { @($m['resources'].Values) } else { @($m['resources']) }
    $vm = @($all | Where-Object { $_['type'] -eq 'Microsoft.Resources/deployments' })[0]['properties']['parameters']
    $vm['customData'] | Should -Match "^\[if\(variables\('windows'\), createObject\('value', ''\), "
    $run = @($all | Where-Object { $_['type'] -eq 'Microsoft.Compute/virtualMachines/runCommands' })
    $run.Count | Should -Be 1
    $run[0]['condition'] | Should -Be "[and(variables('windows'), not(parameters('vmExists')))]"
    $run[0]['properties']['asyncExecution'] | Should -BeTrue
    $script = Get-Content 'scripts/jumpbox/Install-JumpboxTools.ps1' -Raw
    $ref = [regex]::Match($run[0]['properties']['source']['script'], "^\[variables\('(.+)'\)\]$").Groups[1].Value
    $m['variables'][$ref] | Should -Be $script
    $pin = [regex]::Match((Get-Content '.github/workflows/validate.yml' -Raw), '(?m)^  BICEP_VERSION: (\S+)$').Groups[1].Value
    $script | Should -Match ([regex]::Escape("bicep/releases/download/$pin/bicep-win-x64.exe"))
    $script | Should -Not -Match 'releases/latest|(?i)git clone'
    $script | Should -Match "Write-Step 'ready'"
    # A 15-character computer name, the platform's patching without a customer schedule, no legacy antimalware extension.
    $vm['computerName'] | Should -Be "[if(variables('windows'), createObject('value', 'jumpbox'), createObject('value', parameters('vmName')))]"
    $vm['bypassPlatformSafetyChecksOnUserSchedule']['value'] | Should -BeFalse
    $vm['extensionAntiMalwareConfig']['value']['enabled'] | Should -BeFalse
  }

  It 'keeps the per-OS size and disk the preflight prices in step with the template' {
    Import-Module (Join-Path $PSScriptRoot '../../scripts/ops/AvdLandingZone.psm1') -Force
    $t = Get-CompiledTemplate 'parameters/dev.bicepparam'
    $size = (Find-Deployment $t 'avdlz-jumpbox')['properties']['parameters']['vmSize']
    $m = (& $script:bicep build 'bicep/modules/jumpbox.bicep' --stdout) -join "`n" | ConvertFrom-Json -Depth 100 -AsHashtable
    $all = if ($m['resources'] -is [System.Collections.IDictionary]) { @($m['resources'].Values) } else { @($m['resources']) }
    $disk = @($all | Where-Object { $_['type'] -eq 'Microsoft.Resources/deployments' })[0]['properties']['parameters']['osDisk']['value']['diskSizeGB']
    $tiers = @{ E4 = 32; E10 = 128 }
    foreach ($os in 'Linux', 'Windows') {
      $spec = Get-AvdJumpboxSpec -Plan @{ jumpboxOs = $os; jumpboxVmSize = '' }
      $size | Should -Match ([regex]::Escape("'$($spec.VmSize)'")) -Because $os
      $disk | Should -Match "$($tiers[$spec.Disk])" -Because $os
    }
    $disk | Should -Be "[if(variables('windows'), 128, 32)]"
    $size | Should -Match "if\(equals\(parameters\('jumpboxOs'\), 'Windows'\), createObject\('value', 'Standard_B2as_v2'\), createObject\('value', 'Standard_B2als_v2'\)\)"
  }

  It 'gives the jumpbox subnet an NSG that denies the internet and onward RDP and SSH, and the hosts'' egress' {
    $raw = (& $script:bicep build 'bicep/modules/network.bicep' --stdout) -join "`n"
    $raw | Should -Match "'snet-jumpbox'"
    $m = $raw | ConvertFrom-Json -Depth 100 -AsHashtable
    $nsg = $m['resources']['jumpboxNsg']
    $nsg['condition'] | Should -Be "[parameters('deployJumpboxSubnet')]"
    $rules = $nsg['properties']['parameters']['securityRules']['value']
    @($rules | Where-Object { $_['properties']['access'] -eq 'Allow' }).Count | Should -Be 0
    ($rules | ForEach-Object { $_['name'] }) | Should -Be @('Deny-Internet-Inbound', 'Deny-VirtualNetwork-RDP-SSH-Outbound')
    $m['parameters']['jumpboxSubnetPrefix']['defaultValue'] | Should -Be '10.100.2.32/28'
  }

  It 'installs the Bicep version CI pins, and no credentials, at first boot' {
    $workflow = Get-Content '.github/workflows/validate.yml' -Raw
    $pin = [regex]::Match($workflow, '(?m)^  BICEP_VERSION: (\S+)$').Groups[1].Value
    $init = Get-Content 'scripts/jumpbox/cloud-init.yaml' -Raw
    $init | Should -Match ([regex]::Escape("bicep/releases/download/$pin/"))
    $init | Should -Not -Match 'releases/latest'
    $init | Should -Not -Match '(?i)password|secret|token|git clone'
    $init | Should -Match '^#cloud-config'
  }
}

Describe 'Deadline teardown for sandbox batches (decision 0021)' {
  BeforeAll {
    $raw = & $script:bicep build bicep/recorder/main.bicep --stdout 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bicep build failed: $raw" }
    $script:t = ($raw -join "`n") | ConvertFrom-Json -Depth 100 -AsHashtable
    $script:role = @($t.resources.Values + @($t.resources) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['type'] -eq 'Microsoft.Authorization/roleDefinitions' })[0]
  }
  It 'is on unless the operator leaves it out, and needs a pinned runbook' {
    $t.parameters.deadlineRunbookUri.defaultValue | Should -Be ''
    "$($role['condition'])" | Should -Be "[variables('hasDeadline')]"
    $t.variables.hasDeadline | Should -Match 'deadlineRunbookUri'
  }
  It 'lets its identity read and delete resource groups and deallocate VMs, and nothing else' {
    $p = $role['properties']['permissions'][0]
    @($p['actions'] | Sort-Object) | Should -Be @(
      'Microsoft.Compute/virtualMachines/deallocate/action', 'Microsoft.Compute/virtualMachines/read',
      'Microsoft.Resources/subscriptions/resourceGroups/delete', 'Microsoft.Resources/subscriptions/resourceGroups/read')
    @($p['dataActions']) | Where-Object { $_ } | Should -BeNullOrEmpty
  }
  It 'reaches only the records container of the run store' {
    $src = Get-Content bicep/recorder/deadline.bicep -Raw
    $src | Should -Match "scope: records"
    ([regex]::Matches($src, "Microsoft.Authorization/roleAssignments")).Count | Should -Be 1
  }
}
