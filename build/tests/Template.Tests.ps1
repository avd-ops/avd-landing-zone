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
