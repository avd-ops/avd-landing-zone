#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# End-to-end runs of the ops scripts against the offline Azure/Graph mock in build/tests/offline.
# Each scenario runs in its own pwsh process (the mock replaces Az and Graph globally) and
# prints "RESULT <step> ..." lines. Needs the Bicep CLI on PATH (pre-deployment compiles
# the parameter files).
# Every scenario encodes something a real run taught us; see build/lessons.

BeforeAll {
  $script:pwsh = (Get-Process -Id $PID).Path
  function Invoke-OfflineScenario([string] $Name) {
    $file = Join-Path $PSScriptRoot "offline/$Name.Scenario.ps1"
    $out = & $script:pwsh -NoProfile -NonInteractive -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Scenario $Name crashed (exit $LASTEXITCODE):`n$out" }
    $out
  }
  # The machine-readable state lines the deployment portal reads (site/portal/README.md).
  function Get-PortalState([string] $Output) {
    @([regex]::Matches($Output, '<<<AVDLZ-STATE (.*?) AVDLZ-STATE>>>') | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
  }
  function Get-StepExit([string] $Output, [string] $Step) {
    $m = [regex]::Match($Output, "RESULT $([regex]::Escape($Step)) EXIT=(\d+)")
    if (-not $m.Success) { throw "No RESULT line for step '$Step'." }
    [int]$m.Groups[1].Value
  }
}

Describe 'Post-deployment: preflight, demo and cleanup' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'PostDeployment' }

  It 'fails the check while the tenant steps are not done' { Get-StepExit $out 'check' | Should -Be 1 }
  It '-Fix completes all three tenant steps' { Get-StepExit $out 'fix' | Should -Be 0 }
  It '-Fix grants consent, tags the app, excludes it from CA and applies the ACL' {
    $out | Should -Match 'RESULT fix-state consent=True tagged=True caExcluded=True aclApplied=True'
  }
  It '-Fix removes the temporary storage role it granted the host' { $out | Should -Match 'leftoverRoles=0' }
  It 'is clean when checked again' { Get-StepExit $out 'recheck' | Should -Be 0 }
  It 'warns when Security Defaults is on, without blocking' { $out | Should -Match 'RESULT security-defaults warned=True stillReady=True' }
  It 'fails when the profile share allows only AES-256-GCM channel encryption (lesson 0028)' { $out | Should -Match 'RESULT smb-channel failed=True notReady=True' }
  It 'checks the recovery region against every allowed-locations policy and its quota, as warnings' {
    $out | Should -Match 'RESULT recovery-region skipped=True ownWarned=True ownSaysRedeploy=True foreignNamed=True quotaWarned=True allowedPassed=True stillReady=True'
  }
  It 'reports the profile backup''s access, last status and age, as warnings' {
    $out | Should -Match 'RESULT profile-backup healthy=True access=True failedWarned=True keyHint=True stale=True never=True stillReady=True'
  }
  It 'tells the storage app Azure created from a user-registered one of the same name by its owners' { $out | Should -Match 'RESULT storage-app-imposter besideReady=True besideApp=True onlyFailed=True onlyExcluded=0' }
  It 'fails the demo host check by name when a Kerberos client service is stopped' { $out | Should -Match 'RESULT kerberos-services failed=True named=True' }
  It 'deploys and validates the demo, then removes it' {
    Get-StepExit $out 'demo' | Should -Be 0
    Get-StepExit $out 'remove-demo' | Should -Be 0
  }
  It 'checks the demo hosts against the host security baseline, as warnings (decision 0018)' {
    $demo = (Get-PortalState $out)[3]
    (@($demo.warnings | Where-Object { $_.id -like 'host-baseline-*' }) | ForEach-Object { "$($_.id)=$($_.data.outcome)" } | Sort-Object) -join ',' |
      Should -Be 'host-baseline-app-control=departure,host-baseline-defender-tamper=departure,host-baseline-idle-limit=departure,host-baseline-lsa-protection=unknown,host-baseline-screen-capture-protection=departure,host-baseline-screen-lock=departure'
    $out | Should -Match '\[PASS \] avdlzddemo-001 Credential Guard running'
    $out | Should -Match 'RESULT host-baseline-drift host-baseline-local-admins=unknown,host-baseline-vbs-running=gap named=True failures=0'
  }
  It 'keeps the demo record when the device cleanup fails, so a rerun finishes it (lesson 0029)' { $out | Should -Match 'RESULT device-retry kept=True named=True rerunDeleted=True recordGone=True' }
  It 'changes nothing when removing the landing zone with -WhatIf' { $out | Should -Match 'RESULT remove-lz-whatif changes=0' }
  It 'refuses to remove the landing zone, the last copy of its profiles and logs, without -DiscardLastCopy, even with -Force (decision 0016)' { $out | Should -Match 'RESULT remove-lz-refused named=True changes=0' }
  It 'says the Key Vault will be soft-deleted under -WhatIf, and is soft-deleted after the real run' {
    $whatIf = $out.Substring($out.IndexOf('######## remove-lz-whatif'), $out.IndexOf('RESULT remove-lz-whatif EXIT') - $out.IndexOf('######## remove-lz-whatif'))
    $whatIf | Should -Match 'Key Vault kvavdlzdevabc will be soft-deleted with purge protection'
    $whatIf | Should -Not -Match 'is soft-deleted'
    $real = $out.Substring($out.IndexOf('######## remove-lz'+"`n"))
    $real | Should -Match 'Key Vault kvavdlzdevabc is soft-deleted with purge protection'
  }
  It 'reports each deployment record it deletes' {
    $out.Substring($out.IndexOf('######## remove-lz'+"`n")) | Should -Match '\[FIXED\] Deployment record avdlz-governance-avdlz-dev-eastus2'
  }
  It 'removing a landing zone beside another keeps what the other one uses' {
    Get-StepExit $out 'remove-test-beside-dev' | Should -Be 0
    $out | Should -Match 'RESULT remove-test-beside-dev devRgs=5 testRgs=0 policyDeletes=0 activityLogDeleted=False records=avdlz-dev-20260929-101500,avdlz-governance-avdlz-dev-northcentralus'
    $out | Should -Match 'Kept: landing zone avdlz-dev still uses it'
  }
  It 'deletes the Log Analytics workspace permanently before its resource group (lesson 0023)' {
    $out | Should -Match 'RESULT remove-lz-workspace forceDeletes=1 beforeResourceGroup=True'
    $out | Should -Match '\[FIXED\] Log Analytics workspace log-avdlz-dev'
  }
  It 'purges the storage account''s Entra app from deleted items after deleting the storage (rule 26)' {
    $out | Should -Match 'RESULT remove-lz-storage-app deleteCalls=2 leftInDeletedItems=0 afterStorageRg=True'
    $out | Should -Match "\[FIXED\] Storage app '\[Storage Account\] stavdlzdevabc123\.file\.core\.windows\.net' in Entra deleted items"
    $whatIf = $out.Substring($out.IndexOf('######## remove-lz-whatif'), $out.IndexOf('RESULT remove-lz-whatif EXIT') - $out.IndexOf('######## remove-lz-whatif'))
    $whatIf | Should -Match 'Purge from Entra deleted items'
  }
  It 'removes every landing zone resource group' {
    Get-StepExit $out 'remove-lz' | Should -Be 0
    $out | Should -Match 'RESULT remove-lz remainingRgs=0'
  }
  It 'ends every run with a portal state line (none under -WhatIf)' {
    $s = Get-PortalState $out
    ($s | ForEach-Object { "$($_.stage):$($_.status):$($_.fix)" }) -join ' ' |
      Should -Be 'postdeploy:notready:False postdeploy:ready:True postdeploy:ready:False demo:ready:False cleanup:ready:False cleanup:ready:False cleanup:ready:False'
    $s[0].context.namePrefix | Should -Be 'avdlz'
    $s[0].failures.Count | Should -Be $s[0].counts.fail
    $s[5].context.includeLandingZone | Should -BeTrue
    $s[6].context.environment | Should -Be 'test'   # remove-test-beside-dev
  }
  It 'reports the launch link IDs for the landing zone desktop and the demo desktop (decision 0014)' {
    $s = Get-PortalState $out
    $s[1].context.launch.workspaceObjectId | Should -Be 'a0a0a0a0-0000-4000-8000-000000000001'
    $s[1].context.launch.desktopObjectId | Should -Be 'b0b0b0b0-0000-4000-8000-000000000001'
    $s[1].context.launch.tenantId | Should -Be '55555555-5555-5555-5555-555555555555'
    $s[1].context.launch.workspace | Should -Be 'vdws-avdlz-dev'
    $s[3].context.launch.workspaceObjectId | Should -Be 'a0a0a0a0-0000-4000-8000-00000000d0d0'
    $s[3].context.launch.workspace | Should -Be 'vdws-avdlz-dev-demo'
  }
  It 'leaves the launch link out when ARM returns no objectId' { $out | Should -Match 'RESULT launch-missing hasLaunch=False' }
}

Describe 'Pre-deployment: empty subscription, then a blocked prod deployment' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'PreDeployment' }

  It 'fails on missing groups, service principal and providers' { Get-StepExit $out 'check' | Should -Be 1 }
  It '-Fix creates and registers everything it can' { Get-StepExit $out 'fix' | Should -Be 0 }
  It 'is clean when checked again, and prints the deploy command' {
    Get-StepExit $out 'recheck' | Should -Be 0
    $out | Should -Match 'deploy\.sh -p parameters/dev\.bicepparam -l northcentralus'
  }
  It 'passes a recovery region this deployment adds to its own guardrail, and warns on one a management group blocks' {
    $planned = $out.Substring($out.IndexOf('######## recovery-planned'))
    $planned | Should -Match '\[PASS \] Recovery region southcentralus allowed by Azure Policy\s+This deployment adds it'
    $foreign = $out.Substring($out.IndexOf('######## recovery-foreign'))
    $foreign | Should -Match '\[WARN \] Recovery region southcentralus allowed by Azure Policy\s+Blocked by: Corp allowed RG locations \(allows northcentralus\)'
    Get-StepExit $out 'recovery-foreign' | Should -Be 0
    $out | Should -Match '\[SKIP \] Recovery region\s+None set'
  }
  It 'reads the AVD host pool regions from the provider API' { $out | Should -Match '\[PASS \] AVD host pools offered in northcentralus' }
  It 'warns when a dev landing zone has no budget backstop (avd-second-brain decision 0017)' { $out | Should -Match '\[WARN\s*\] Budget backstop' }
  It 'blocks prod on a soft-deleted, purge-protected Key Vault' {
    Get-StepExit $out 'prod-zone-and-vault' | Should -Be 1
    $out | Should -Match '\[FAIL \] No soft-deleted Key Vault blocking the vault name'
  }
  It 'gives the portal the context and structured failures it needs' {
    $s = Get-PortalState $out
    ($s | ForEach-Object { "$($_.stage):$($_.status)" }) -join ' ' | Should -Be 'predeploy:notready predeploy:ready predeploy:ready predeploy:notready predeploy:notready predeploy:ready predeploy:ready predeploy:ready predeploy:ready predeploy:ready predeploy:ready predeploy:notready predeploy:ready predeploy:ready predeploy:ready'
    $s[1].context.parameterFile | Should -Be 'parameters/dev.bicepparam'
    $s[1].context.location | Should -Be 'northcentralus'
    $s[1].context.usersGroup | Should -Be 'AVD Users'
    $quota = $s[3].failures | Where-Object id -eq 'quota'
    $quota.data.quotaName | Should -Be 'standardEASv5Family'   # memory-optimized default (E4as_v5)
    $quota.data.needed | Should -Be 16
    ($s[3].failures | Where-Object id -eq 'kv-softdeleted').data.vaults | Should -Contain 'kvavdlzprodabc123'
  }
  It '-Fix recovers the soft-deleted vault into its resource group, created again first' {
    Get-StepExit $out 'vault-recover' | Should -Be 0
    $out | Should -Match '\[FIXED\] No soft-deleted Key Vault blocking the vault name'
    $out | Should -Match 'Recovered kvavdlzdevs7abc123 into rg-avdlz-dev-management'
    $calls = [regex]::Match($out, 'RESULT vault-recover-calls (.*)').Groups[1].Value
    $calls | Should -Match 'PUT /subscriptions/[^/]+/resourcegroups/rg-avdlz-dev-management\?.*\| ARM PUT .*/vaults/kvavdlzdevs7abc123\?'
    $calls | Should -Not -Match 'kvavdlzdevq9xyz789'   # same prefix, another region
    Get-StepExit $out 'vault-recovered' | Should -Be 0
  }
  It 'prices the power settings from the portal''s Cost step and reports them to the portal' {
    Get-StepExit $out 'power-off' | Should -Be 0
    $s = (Get-PortalState $out)[10]
    $s.context.power.autoShutdownTime | Should -Be 'none'
    $s.context.power.startVmOnConnect | Should -BeFalse
    $s.context.sizing | Should -BeNullOrEmpty                   # power alone is not a sizing
    $c = $s.context.estimate.lines | Where-Object key -eq 'compute'
    $c.quantity | Should -Be 728                                 # 1 host x 168 h x 52 / 12
    $c.note | Should -Be '168 h/week each (no Start VM on Connect: hosts stay up through the working day; no scheduled stop)'
    ((Get-PortalState $out)[1].context.estimate.lines | Where-Object key -eq 'compute').note | Should -Match 'Start VM on Connect starts hosts on demand; stopped daily at 20:00'
  }
  It 'refuses a group found by name whose owner is not an administrator, and accepts one owned by administrators' {
    Get-StepExit $out 'owned-group' | Should -Be 1
    $out | Should -Match '\[FAIL \] AVD Users group ''AVD Users'' is owned by administrators'
    $out | Should -Match 'owned by eve@contoso\.com'
    ((Get-PortalState $out)[11].failures | Where-Object id -eq 'group-owner').Count | Should -Be 2
    Get-StepExit $out 'admin-owned-group' | Should -Be 0
  }
  It 'check mode points at -Fix for the vault' {
    ((Get-PortalState $out)[3].failures | Where-Object id -eq 'kv-softdeleted').remediation | Should -Match 'Rerun with -Fix to recover it into rg-avdlz-prod-management'
  }
}

Describe 'Pre-deployment: sizing from the deployment portal, and its cost' {
  BeforeAll {
    $script:out = Invoke-OfflineScenario 'PreDeployment'
    $script:sized = (Get-PortalState $out)[4]
  }

  It 'validates the desired sizing, not the parameter file''s: quota for 3 x 8 vCPUs' {
    Get-StepExit $out 'sized' | Should -Be 1
    $out | Should -Match '3 x Standard_D8as_v5'
    ($sized.failures | Where-Object id -eq 'quota' | Select-Object -First 1).data.needed | Should -Be 24
  }
  It 'warns above 6 sessions per vCPU' { $out | Should -Match '60 sessions on 8 vCPUs is 7\.5 per vCPU' }
  It 'warns when memory per session is too low, and suggests the E-series size' {
    ($sized.warnings | Where-Object id -eq 'sizing-memory').remediation | Should -Match 'Standard_E8as_v5'
  }
  It 'warns before redeploying resizes the hosts (D4as_v5 deployed, E4as_v5 default)' {
    Get-StepExit $out 'redeploy-resize' | Should -Be 0
    $r = (Get-PortalState $out)[6].warnings | Where-Object id -eq 'resize'
    $r.data.from | Should -Be 'Standard_D4as_v5'
    $r.data.to | Should -Be 'Standard_E4as_v5'
    $r.remediation | Should -Match '--vm-size Standard_D4as_v5'
  }
  It 'tells the portal the sizing it validated' {
    $sized.context.sizing.hosts | Should -Be 3
    $sized.context.sizing.vmSize | Should -Be 'Standard_D8as_v5'
    $sized.context.sizing.maxSessions | Should -Be 60
    $sized.context.sizing.profileQuotaGiB | Should -Be 600
    $sized.context.sizing.activeHoursPerWeek | Should -Be 60
  }
  It 'prices each line from one meter, at the base compute rate, across pages' {
    $e = $sized.context.estimate
    ($e.lines | Where-Object key -eq 'compute').unitPrice | Should -Be 0.8      # Linux/base rate, not Windows, CloudServices, Spot or Low Priority (page 2)
    ($e.lines | Where-Object key -eq 'compute').meter | Should -Match '^Virtual Machines '
    ($e.lines | Where-Object key -eq 'osdisk').meter | Should -Be 'Premium SSD Managed Disks / P10 LRS Disk'   # not 'Premium Page Blob'
    ($e.lines | Where-Object key -eq 'compute').quantity | Should -Be 780        # 3 hosts x 60 h/week x 52 / 12
    ($e.lines | Where-Object key -eq 'osdisk').unitPrice | Should -Be 20         # 'P10 LRS Disk', not 'P10 LRS Disk Mount'
    ($e.lines | Where-Object key -eq 'profiles').monthly | Should -Be 120
    # Listed under 'Global', not the region, beside lookalike hourly meters (lesson 0025).
    ($e.lines | Where-Object key -eq 'privateendpoints').meter | Should -Be 'Virtual Network Private Link / Standard Private Endpoint'
    ($e.lines | Where-Object key -eq 'privateendpoints').unitPrice | Should -Be 0.01
    ($e.lines | Where-Object key -eq 'natgateway').meter | Should -Be 'NAT Gateway / Standard Gateway'
    $e.total | Should -Be 862.4
    $e.alwaysOnTotal | Should -Be 1990.4
  }
  It 'reports a line it cannot price, with the meters it saw, instead of guessing' {
    $u = @($sized.context.estimate.unpriced)
    $u.key | Should -Be 'publicip'
    $u.seen | Should -Match 'IP Addresses: Standard / Standard IPv4 Public Address'   # the product is named too
    ($sized.warnings | Where-Object id -eq 'cost-unpriced') | Should -Not -BeNullOrEmpty
  }
  It 'prints the deploy command with the validated sizing once it passes' {
    Get-StepExit $out 'sized-ready' | Should -Be 0
    $out | Should -Match "deploy\.sh -p parameters/dev\.bicepparam -l northcentralus --users-group 'AVD Users' --admins-group 'AVD Admins' --hosts 3 --vm-size Standard_D8as_v5 --max-sessions 32 --profile-quota 600"
    @((Get-PortalState $out)[5].context.estimate.unpriced).Count | Should -Be 0
  }
  It 'still finishes (and is ready) when the price API is down' {
    Get-StepExit $out 'prices-down' | Should -Be 0
    ((Get-PortalState $out)[7].warnings | Where-Object id -eq 'cost-unavailable') | Should -Not -BeNullOrEmpty
  }
}

Describe 'deploy.sh with session hosts that are not running (real run, 2026-10-05)' {
  # Lesson 0026: Azure refuses to update the run commands of a host that isn't running.
  BeforeAll {
    $script:out = Invoke-OfflineScenario 'Deploy'
    function Get-Result([string] $Key) { $m = [regex]::Match($out, "RESULT $([regex]::Escape($Key)) (.*)"); if (-not $m.Success) { throw "No RESULT line for '$Key'." }; $m.Groups[1].Value.Trim() }
  }
  It 'starts a deallocated host before the deployment and deallocates it after' {
    Get-StepExit $out 'stopped' | Should -Be 0
    Get-Result 'stopped-calls' | Should -Be 'group-exists,vm-list,vm-start,deployment-create,vm-deallocate'
    Get-Result 'stopped-ids' | Should -Be 'avdlzdsh-001,avdlzdsh-001'
  }
  It 'deallocates it again when the deployment fails, and still fails' {
    Get-StepExit $out 'stopped-fails' | Should -Be 1
    Get-Result 'stopped-fails-calls' | Should -Be 'group-exists,vm-list,vm-start,deployment-create,vm-deallocate'
  }
  It 'only reports it on a what-if' {
    Get-StepExit $out 'whatif' | Should -Be 0
    Get-Result 'whatif-calls' | Should -Be 'group-exists,vm-list,deployment-what-if'
    $out | Should -Match 'Not running: avdlzdsh-001'
  }
  It 'touches no host when all are running, or on a first deployment' {
    Get-Result 'running-calls' | Should -Be 'group-exists,vm-list,deployment-create'
    Get-Result 'first-calls' | Should -Be 'group-exists,deployment-create'
  }
  It 'refuses to deploy while auto shutdown has the hosts locked, before touching a host' {
    Get-StepExit $out 'locked' | Should -Be 1
    Get-Result 'locked-calls' | Should -Be 'group-exists'
    $out | Should -Match 'locked by auto shutdown \(budget 2026-10-19T03:00:00Z\)\. Not deploying'
    $out | Should -Match 'Invoke-AvdPowerAction\.ps1 -Action Resume -NamePrefix avdlz -Environment dev'
    Get-StepExit $out 'locked-whatif' | Should -Be 0   # a what-if changes nothing, so it only says so
    Get-Result 'locked-whatif-calls' | Should -Be 'group-exists,vm-list,deployment-what-if'
    $out | Should -Match 'The deployment itself is refused until Resume runs'
  }
  It 'deploys over the lock with --unlock and says the hosts stay drained' {
    Get-StepExit $out 'locked-unlock' | Should -Be 0
    Get-Result 'locked-unlock-calls' | Should -Be 'group-exists,vm-list,vm-start,deployment-create,vm-deallocate'
    $out | Should -Match 'deploying anyway \(--unlock\)'
  }
  It 'refuses a group found by name whose owner is not an administrator, before touching anything' {
    Get-StepExit $out 'owned-group' | Should -Be 1
    Get-Result 'owned-group-calls' | Should -Be ''
    $out | Should -Match "Entra group 'AVD Users' \(00000000-0000-0000-0000-0000000000a1\) has an owner who is not an administrator"
    Get-StepExit $out 'admin-owned-group' | Should -Be 0
    Get-Result 'admin-owned-group-calls' | Should -Be 'group-exists,vm-list,deployment-create'
    Get-StepExit $out 'group-by-id' | Should -Be 0
  }
  It 'keeps the image and generation the host pool records, and passes its rotation tags back (image pipeline spec 6.1)' {
    Get-StepExit $out 'pool-tags' | Should -Be 0
    Get-Result 'pool-tags-env' | Should -Match 'image=\S+/versions/2026\.1004\.1 gen=a tags=\{"avdlz-image":"\S+/versions/2026\.1004\.1","avdlz-generation":"a"\}$'
    Get-StepExit $out 'first-image' | Should -Be 0
    # A new pool records its first image and generation, so the next routine deployment keeps them.
    Get-Result 'first-image-env' | Should -Match 'image=\S+/versions/2026\.1004\.1 gen=a tags=\{"avdlz-image":"\S+/versions/2026\.1004\.1","avdlz-generation":"a"\}$'
    Get-Result 'running-env' | Should -Be 'deploy-env image= gen= tags='
  }
  It 'refuses a different image or generation, and any deployment during a rotation, except from the rotation script' {
    Get-StepExit $out 'pool-tags-new-generation' | Should -Be 1
    Get-Result 'pool-tags-new-generation-calls' | Should -Be ''
    $out | Should -Match "Not deploying a different one"
    Get-StepExit $out 'pool-rotating' | Should -Be 1
    Get-Result 'pool-rotating-calls' | Should -Be ''
    $out | Should -Match 'A host rotation is in progress on vdpool-avdlz-dev'
    Get-StepExit $out 'pool-rotation-deploy' | Should -Be 0
    Get-Result 'pool-rotation-deploy-env' | Should -Match 'image=\S+/versions/2026\.1101\.1 gen=b tags=.*"avdlz-rotation":"\{\\"phase\\":\\"Deploy\\"\}"'
  }
  It 'adds, keeps and never re-sends the operator jumpbox (decision 0019)' {
    Get-StepExit $out 'jumpbox-new' | Should -Be 0
    Get-Result 'jumpbox-new-jumpbox' | Should -Be 'jumpbox-env deploy=true exists= until= os='
    Get-StepExit $out 'jumpbox-keep-alone' | Should -Be 1
    $out | Should -Match '--jumpbox-keep-running needs --jumpbox'
    Get-StepExit $out 'jumpbox-past' | Should -Be 1
    $out | Should -Match '--jumpbox-keep-running is in the past'
    Get-StepExit $out 'jumpbox-kept' | Should -Be 0
    Get-Result 'jumpbox-kept-jumpbox' | Should -Be 'jumpbox-env deploy=true exists=true until= os=Linux'
    Get-StepExit $out 'jumpbox-kept-running' | Should -Be 0
    Get-Result 'jumpbox-kept-running-jumpbox' | Should -Match '^jumpbox-env deploy=true exists=true until=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z os=Linux$'
    Get-StepExit $out 'jumpbox-region' | Should -Be 1
    $out | Should -Match "Azure Bastion Developer isn't offered in eastus"
    Get-Result 'running-jumpbox' | Should -Be 'jumpbox-env deploy= exists= until= os='
  }
  It 'builds a Windows jumpbox with --jumpbox-os windows, and never changes the OS of one that exists' {
    Get-StepExit $out 'jumpbox-windows' | Should -Be 0
    Get-Result 'jumpbox-windows-jumpbox' | Should -Be 'jumpbox-env deploy=true exists= until= os=Windows'
    Get-StepExit $out 'jumpbox-os-bad' | Should -Be 1
    $out | Should -Match "--jumpbox-os takes linux or windows: 'macos'"
    Get-StepExit $out 'jumpbox-os-alone' | Should -Be 1
    $out | Should -Match '--jumpbox-os needs --jumpbox'
    Get-StepExit $out 'jumpbox-os-change' | Should -Be 1
    Get-Result 'jumpbox-os-change-jumpbox' | Should -Be ''
    $out | Should -Match "The jumpbox runs Linux; --jumpbox-os can't change it"
    Get-StepExit $out 'jumpbox-os-env' | Should -Be 0
    Get-Result 'jumpbox-os-env-jumpbox' | Should -Be 'jumpbox-env deploy=true exists= until= os=Windows'
    Get-StepExit $out 'jumpbox-unreadable' | Should -Be 1
    Get-Result 'jumpbox-unreadable-jumpbox' | Should -Be ''
    $out | Should -Match "Can't read the jumpbox VM"
    Get-StepExit $out 'jumpbox-kept-windows' | Should -Be 0
    Get-Result 'jumpbox-kept-windows-jumpbox' | Should -Be 'jumpbox-env deploy=true exists=true until= os=Windows'
  }
  It 'starts and deallocates only the new generation during a rotation' {
    Get-StepExit $out 'pool-rotation-stopped' | Should -Be 0
    Get-Result 'pool-rotation-stopped-calls' | Should -Be 'group-exists,vm-list,vm-start,deployment-create,vm-deallocate'
    Get-Result 'pool-rotation-stopped-ids' | Should -Be 'avdlzdshb-001,avdlzdshb-001'
    $out | Should -Match 'Leaving avdlzdsh-001 as it is'
  }
  It 'reads the host pool even when its hosts resource group is gone' {
    Get-StepExit $out 'pool-no-hosts-rg' | Should -Be 1
    Get-Result 'pool-no-hosts-rg-calls' | Should -Be ''
    Get-StepExit $out 'pool-no-hosts-rg-keeps' | Should -Be 0
    Get-Result 'pool-no-hosts-rg-keeps-env' | Should -Match 'image=\S+/versions/2026\.1004\.1 gen=a tags=\{"avdlz-image":"\S+/versions/2026\.1004\.1","avdlz-generation":"a"\}$'
  }
  It 'stops when the host pool cannot be read, rather than treating it as missing' {
    Get-StepExit $out 'pool-unreadable' | Should -Be 1
    Get-Result 'pool-unreadable-calls' | Should -Be ''
    $out | Should -Match 'Could not read the host pool vdpool-avdlz-dev .* Not deploying\.'
    $out | Should -Match 'AuthorizationFailed'
  }
  It 'takes only a gallery image version as the image' {
    Get-StepExit $out 'bad-image' | Should -Be 1
    $out | Should -Match '--image-id takes a Compute Gallery image version resource ID'
  }
  It 'makes no az call the fake does not know' {
    foreach ($s in 'stopped', 'stopped-fails', 'whatif', 'running', 'first', 'locked', 'locked-whatif', 'locked-unlock', 'owned-group', 'admin-owned-group', 'group-by-id', 'subscription', 'subscription-whatif', 'no-subscription') { Get-Result "$s-unmocked" | Should -Be 'False' }
  }
  It 'deploys to the subscription -s names, without changing the one az has selected' {
    foreach ($s in 'subscription', 'subscription-whatif') {
      Get-StepExit $out $s | Should -Be 0
      Get-Result "$s-arm-without-s" | Should -Be '0' -Because "${s}: every Resource Manager call names the subscription"
      [int](Get-Result "$s-arm-with-s") | Should -BeGreaterThan 5
      Get-Result "$s-graph-with-s" | Should -Be '0' -Because 'az ad and az rest read the tenant, and reject --subscription'
      Get-Result "$s-account-set" | Should -Be '0'
    }
    Get-Result 'subscription-calls' | Should -Be 'group-exists,vm-list,vm-start,deployment-create,vm-deallocate'
    $out | Should -Match 'Subscription: Fake other subscription \(00000000-aaaa-bbbb-cccc-000000000002\)'
    $out | Should -Match '-SubscriptionId 00000000-aaaa-bbbb-cccc-000000000002 -Fix'
  }
  It 'says which subscription it uses without -s' {
    Get-StepExit $out 'no-subscription' | Should -Be 0
    Get-Result 'no-subscription-arm-with-s' | Should -Be '0'
    $out | Should -Match 'Subscription: Fake subscription \(00000000-aaaa-bbbb-cccc-000000000001\)\s+\(the one az has selected; pass -s to choose\)'
  }
  It 'refuses a subscription it cannot find, or one in another tenant, before reading or changing anything' {
    Get-StepExit $out 'subscription-missing' | Should -Be 1
    Get-Result 'subscription-missing-calls' | Should -Be ''
    $out | Should -Match 'Subscription not found, or not one this account can use: other-sub'
    Get-StepExit $out 'subscription-other-tenant' | Should -Be 1
    Get-Result 'subscription-other-tenant-calls' | Should -Be ''
    $out | Should -Match "Run 'az login --tenant 00000000-0000-0000-0000-0000000000f2' first"
  }
}

Describe 'Post-deployment quota on a deployed landing zone (real run, 2026-09-30)' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'PostDeployQuota' }

  It 'does not count the deployed host twice: 4 of 4 Easv5 vCPUs used by the host itself passes' {
    Get-StepExit $out 'deployed-host' | Should -Be 0
    $out | Should -Match '\[PASS \] standardEASv5Family vCPU quota\s+0 free, 4 needed \(4 already used by this landing zone''s hosts, so 0 more\)'
  }
  It 'still fails a scale-out beyond the quota, and asks only for the difference' {
    Get-StepExit $out 'scale-out' | Should -Be 1
    $q = (Get-PortalState $out)[1].failures | Where-Object id -eq 'quota'
    $q.data.needed | Should -Be 4
    $q.data.deployed | Should -Be 4
    $q.detail | Should -Be '0 free, 8 needed (4 already used by this landing zone''s hosts, so 4 more)'
  }
}

Describe 'Where did I leave off' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'RunStatus' }

  It 'waits for a running deployment and never deploys again' {
    Get-StepExit $out 'running' | Should -Be 0
    $s = (Get-PortalState $out)[0]
    $s.stage | Should -Be 'resume'
    $s.context.lastStatus | Should -Be 'running'
    $s.context.nextStage | Should -Be 'deploy'
    $s.context.deploymentName | Should -Be 'avdlz-dev-20261020-171800'
  }
  It 'finds the only landing zone and moves on to the post-deployment setup' {
    $s = (Get-PortalState $out)[1]
    $s.context.namePrefix | Should -Be 'avdlz'
    $s.context.nextStage | Should -Be 'postdeploy'
  }
  It 'starts again from the preflight after cleanup' {
    $s = (Get-PortalState $out)[2]
    $s.context.lastStage | Should -Be 'cleanup'
    $s.context.nextStage | Should -Be 'predeploy'
  }
}

Describe 'No landing zone in the subscription' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'NoLandingZone' }

  It 'fails once with a pointer to what is there, not once per missing resource' {
    Get-StepExit $out 'check' | Should -Be 1
    $out | Should -Match '-NamePrefix contoso -Environment prod'
    $out | Should -Match 'Nothing to check until the landing zone exists'
  }
  It 'tells the portal which landing zones do exist' {
    $f = (Get-PortalState $out)[0].failures | Where-Object id -eq 'lz-missing'
    $f.data.found[0].namePrefix | Should -Be 'contoso'
  }
}

Describe 'Profile share root that never had an ACL set' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'DefaultShareRoot' }

  It 'reports the default ACL in check mode' {
    Get-StepExit $out 'check' | Should -Be 1
    $out | Should -Match 'still has the default ACL'
  }
  It 'applies the FSLogix ACL with -Fix' {
    Get-StepExit $out 'fix' | Should -Be 0
    $out | Should -Match '\[FIXED\] Profile share root ACL follows FSLogix guidance'
  }
}

Describe 'Well-Architected review of the deployed landing zone' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'WellArchitected' }

  It 'reports findings as warnings, so a dev landing zone is still ready' {
    foreach ($step in 'dev', 'skip-psrule', 'production-grade', 'ama-failed', 'without-switch') { Get-StepExit $out $step | Should -Be 0 }
  }
  It 'marks the dev parameter file''s trade-offs as expected' {
    $s = (Get-PortalState $out)[0]
    $s.context.wellArchitected | Should -BeTrue
    $waf = @($s.warnings | Where-Object { $_.id -like 'waf-*' })
    ($waf | Where-Object { $_.data.accepted } | ForEach-Object id | Sort-Object) -join ',' |
      Should -Be 'waf-budget,waf-defender-plans,waf-host-count,waf-log-retention,waf-profile-backup,waf-storage-redundancy,waf-zones'
    ($waf | Where-Object { -not $_.data.accepted } | ForEach-Object id | Sort-Object) -join ',' |
      Should -Be 'waf-advisor-highavailability,waf-defender-recommendations,waf-policy-compliance,waf-psrule-cost-optimization,waf-psrule-reliability'
  }
  It 'keeps only recommendations for the landing zone (any case), across pages' {
    $out | Should -Match 'Use availability zones for better resiliency'
    $out | Should -Match 'Machines should have vulnerability findings resolved'
    $out | Should -Not -Match 'Right-size underused VM|Other workload'
    $out | Should -Match 'assessmentPages=2'
  }
  It 'reads a region without zones as having none (ARM omits the property; lesson 0021)' {
    $out | Should -Match 'eastus2 has no availability zones'
    $out | Should -Not -Match 'Zones: \r?\n'
  }
  It 'summarizes PSRule export warnings and shows why a rule failed' {
    $out | Should -Not -Match 'WARNING: Failed to get'
    $out | Should -Match 'PSRule could not read 1 optional setting'
    $out | Should -Match "Azure.VM.UseHybridUseBenefit on avdlzdsh-001 \(The field 'properties.licenseType' does not exist.\)"
  }
  It 'runs PSRule on the landing zone resource groups with the repo suppressions, unless skipped' {
    $out | Should -Match 'RESULT dev-calls psruleExport=1 suppressions=1'
    $out | Should -Match 'RESULT skip-psrule-calls psrule=0'
  }
  It 'passes every pillar for a production-grade landing zone' {
    $s = Get-PortalState $out
    @($s[2].warnings).Count | Should -Be 0
    $out | Should -Match 'Reliability\s+7 of 7 pass'
  }
  It 'checks the Azure Monitor Agent directly, and drops PSRule''s AMA finding only where the agent is confirmed' {
    $s = Get-PortalState $out
    ($s[0].warnings | Where-Object { $_.detail -match 'Azure.VM.AMA' }) | Should -BeNullOrEmpty
    ($s[3].warnings | Where-Object id -eq 'waf-monitor-agent').detail | Should -Match 'avdlzdsh-001'
    ($s[3].warnings | Where-Object id -eq 'waf-psrule-operational-excellence').detail | Should -Match 'Azure.VM.AMA on avdlzdsh-001'
  }
  It 'flags a host without vTPM and a host pool that redirects drives' {
    $s = Get-PortalState $out
    ($s[3].warnings | Where-Object id -eq 'waf-host-security').detail | Should -Match 'avdlzdsh-001'
    ($s[3].warnings | Where-Object id -eq 'waf-redirection').detail | Should -Be 'Not turned off: drives'
    ($s[0].warnings | Where-Object id -eq 'waf-redirection') | Should -BeNullOrEmpty
  }
  It 'flags a session host whose OS disk is not Premium SSD' {
    $s = Get-PortalState $out
    ($s[0].warnings | Where-Object id -eq 'waf-os-disk') | Should -BeNullOrEmpty
    ($s[3].warnings | Where-Object id -eq 'waf-os-disk').detail | Should -Match 'avdlzdsh-001'
  }
  It 'adds nothing without -WellArchitected' {
    $s = Get-PortalState $out
    $s[4].context.wellArchitected | Should -BeFalse
    $out.Substring($out.IndexOf('######## without-switch')) | Should -Not -Match 'Well-Architected'
  }
}

Describe 'Auto shutdown runbook' {
  # decision 0011: scripts/automation/Invoke-AvdPowerAction.ps1, host 001 with two user sessions, 002 idle.
  BeforeAll {
    $script:out = Invoke-OfflineScenario 'AutoShutdown'
    function Get-PowerLine([string] $Step) { [regex]::Match($out, "RESULT $Step-state (.*)").Groups[1].Value }
  }

  It 'Stop deallocates idle hosts and leaves hosts with users running' {
    Get-StepExit $out 'stop' | Should -Be 0
    Get-PowerLine 'stop' | Should -Match 'startVMOnConnect=True locked=False allowNew=True,True state=running,deallocating excluded=False,False deallocateCalls=1'
  }
  It 'changes nothing with -WhatIf' { Get-PowerLine 'lock-whatif' | Should -Match 'deallocateCalls=0 messages=0 changes=0$' }
  It 'Lock drains, excludes from the scaling plan, turns off Start VM on Connect, warns users and deallocates' {
    Get-PowerLine 'lock' | Should -Match 'startVMOnConnect=False locked=True allowNew=False,False state=deallocating,deallocating excluded=True,True deallocateCalls=1 messages=2'
    $out | Should -Match 'RESULT lock-reason budget keptTags=True'   # other host pool tags survive
  }
  It 'the post-deployment check reports the lock with the resume command, and not after Resume' {
    $s = Get-PortalState $out
    $locked = ($s | Where-Object { $_.stage -eq 'postdeploy' })[0]
    ($locked.warnings | Where-Object id -eq 'power-locked').remediation | Should -Match 'Invoke-AvdPowerAction\.ps1 -Action Resume -NamePrefix avdlz -Environment dev'
    ($s | Where-Object { $_.stage -eq 'postdeploy' })[1].warnings | Where-Object id -eq 'power-locked' | Should -BeNullOrEmpty
  }
  It 'Resume (from Cloud Shell, with the operator''s token) undoes the lock without starting hosts' {
    Get-PowerLine 'resume' | Should -Match 'startVMOnConnect=True locked=False allowNew=True,True state=deallocating,deallocating excluded=False,False deallocateCalls=0'
  }
  It 'Resume keeps Start VM on Connect off when the deployment turned it off (host pool tag)' {
    Get-PowerLine 'resume-svmoc-off' | Should -Match 'startVMOnConnect=False locked=False'
    $out | Should -Match 'Clear the lock \(Start VM on Connect stays off, as deployed\)'
  }
  It 'reports what ARM returned when a call fails' { $out | Should -Match 'RESULT error ARM PATCH .*vdpool-avdlz-dev.* failed: .*AuthorizationFailed' }
  It 'prints a portal state line for each action' {
    ((Get-PortalState $out | Where-Object stage -eq 'power') | ForEach-Object status) -join ' ' | Should -Be 'stopped locked locked resumed locked resumed'
  }
}

Describe 'Blue/green host rotation (image pipeline spec section 6.5)' {
  # scripts/ops/Invoke-AvdHostRotation.ps1: two hosts on version 2026.1004.1 (001 with a session) move to 2026.1101.1
  # as generation a, one run at a time, then back to the previous version; then a rotation rolled back before Remove.
  BeforeAll {
    $script:out = Invoke-OfflineScenario 'Rotation'
    function Get-RotationLine([string] $Step, [string] $Kind = 'state') { [regex]::Match($out, "RESULT $Step-$Kind (.*)").Groups[1].Value }
    $script:states = @(Get-PortalState $out | Where-Object stage -eq 'rotation')
  }

  It 'refuses the version the pool already runs, and too little quota for both generations, changing nothing' {
    Get-StepExit $out 'same-image' | Should -Be 1
    $states[0].status | Should -Be 'refused'
    @($states[0].failures.id) | Should -Contain 'rotation-image'
    Get-StepExit $out 'no-quota' | Should -Be 1
    @($states[1].failures.id) | Should -Be @('rotation-quota')
    $states[1].failures[0].data.needed | Should -Be 8
    Get-RotationLine 'no-quota' | Should -Match '^phase= image=2026\.1004\.1 gen= next= previous= hosts=avdlzdsh-001:open,avdlzdsh-002:open vmsGone= '
  }
  It 'refuses a parameter file for another landing zone, and Azure CLI on another subscription' {
    Get-StepExit $out 'wrong-file' | Should -Be 1
    @($states[2].failures.id) | Should -Be @('rotation-parameter-file')
    $states[2].failures[0].detail | Should -Match "deploys 'avdlz-test', not 'avdlz-dev'"
    Get-StepExit $out 'cli-sub' | Should -Be 1
    @($states[3].failures.id) | Should -Be @('rotation-cli-subscription')
    Get-RotationLine 'cli-sub' | Should -Match '^phase= image=2026\.1004\.1 gen= next= previous= '
  }
  It 'takes the settings from this pool''s last deployment, not another landing zone''s or the demo''s' {
    $out | Should -Not -Match 'otherdsh'
    Get-RotationLine 'deploy' 'deploy' | Should -Match '^create;deploy-env image=2026\.1101\.1 gen=a '
  }
  It 'deploys generation a beside the old hosts with the target image, through deploy.sh --rotation, keeping the pool tags' {
    Get-RotationLine 'deploy' | Should -Match '^phase=Deploy image=2026\.1004\.1 gen= next=2026\.1101\.1 previous=2026\.1004\.1 hosts=avdlzdsh-001:open,avdlzdsh-002:open'
    Get-RotationLine 'deploy' 'deploy' | Should -Match 'tags=\{"avdlz-image":"2026\.1004\.1","avdlz-image-next":"2026\.1101\.1","avdlz-image-previous":"2026\.1004\.1","avdlz-rotation":.*avdlz-dev-rota-\d{8}-\d{6}'
    $out | Should -Match 'Hosts: image .*/versions/2026\.1101\.1, generation a'
  }
  It 'waits for a deployment still running after a disconnect, and deploys again after a failed one' {
    Get-RotationLine 'deploy-running' 'deploy' | Should -BeNullOrEmpty
    $states[5].warnings[0].detail | Should -Match 'still running in Azure'
    Get-RotationLine 'deploy-retry' 'deploy' | Should -Match '^create;'
    $out | Should -Match '1 of 2 new host\(s\) registered and the deployment failed; deploying again'
  }
  It 'waits for every new host to be Available and healthy, without deploying again' {
    Get-RotationLine 'hosts-wait' 'deploy' | Should -BeNullOrEmpty
    $states[7].warnings[0].detail | Should -Match '0 of 2 new host'
  }
  It 'records the new image on the pool only once the new hosts are ready, then drains the old ones with a message' {
    Get-RotationLine 'drain' | Should -Match '^phase=Wait image=2026\.1101\.1 gen=a .* hosts=avdlzdsh-001:drain,avdlzdsh-002:drain,avdlzdsha-001:open,avdlzdsha-002:open vmsGone= messages=1 signedOut=0 gallery=Merge 2026\.1101\.1$'
    # Out of the scaling plan too, or its ramp-up would reopen them.
    Get-RotationLine 'drain' 'excluded' | Should -Be 'avdlzdsh-001,avdlzdsh-002'
    $d = [regex]::Match($out, 'RESULT drain-deadline (\S+)').Groups[1].Value
    ([datetime]::Parse($d, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) - [datetime]::UtcNow).TotalHours | Should -BeLessThan 24.1
    # One in-use marker per pool, so a same-named landing zone in another subscription never clears this one's.
    $out | Should -Match 'RESULT gallery-key avdlz-in-use-dev-avdlz-00000000-aaaa-bbbb-cccc-000000000001'
  }
  It 'waits for Resume after a budget lock, then drains and excludes the retiring hosts again' {
    $states[10].status | Should -Be 'refused'
    @($states[10].failures.id) | Should -Be @('rotation-locked')
    Get-RotationLine 'locked' | Should -Match 'hosts=avdlzdsh-001:drain,avdlzdsh-002:drain,avdlzdsha-001:open,avdlzdsha-002:open'
    Get-RotationLine 'resumed' | Should -Match '^phase=Wait .* hosts=avdlzdsh-001:drain,avdlzdsh-002:drain,avdlzdsha-001:open,avdlzdsha-002:open .*messages=1 '
    Get-RotationLine 'resumed' 'excluded' | Should -Be 'avdlzdsh-001,avdlzdsh-002'
  }
  It 'signs nobody out after the deadline unless asked, then gives 15 minutes'' notice first' {
    Get-RotationLine 'deadline' | Should -Match 'messages=1 signedOut=0'
    $out | Should -Match 'left after the deadline\. Run again with -LogOffAtDeadline'
    Get-RotationLine 'notice' | Should -Match 'messages=2 signedOut=0'
    Get-RotationLine 'logoff' | Should -Match 'messages=2 signedOut=1'
  }
  It 'drains a reopened host before choosing the next step, so a user who connected meanwhile is never removed' {
    $states[14].status | Should -Be 'waiting'
    $states[14].context.sessionsLeft | Should -Be 1
    Get-RotationLine 'reopened' | Should -Match '^phase=Wait .* hosts=avdlzdsh-001:drain,avdlzdsh-002:drain,avdlzdsha-001:open,avdlzdsha-002:open vmsGone= '
  }
  It 'keeps the session gates in Remove: a user on a reopened host gets a fresh notice, not deletion' {
    $states[15].status | Should -Be 'waiting'
    $states[15].warnings[0].id | Should -Be 'rotation-waiting'
    $states[15].context.phase | Should -Be 'Remove'
    Get-RotationLine 'remove-occupied' | Should -Match '^phase=Remove .* hosts=avdlzdsh-001:drain,avdlzdsh-002:drain,avdlzdsha-001:open,avdlzdsha-002:open vmsGone= messages=3 '
  }
  It 'finishes an interrupted removal, finding the VM whose session host is already gone, and lists every device' {
    Get-RotationLine 'remove' | Should -Match '^phase=Remove .* hosts=avdlzdsha-001:open,avdlzdsha-002:open vmsGone=avdlzdsh-001 '
    $states[16].status | Should -Be 'waiting'
    @($states[16].warnings | Where-Object id -eq 'devices-left')[0].data.devices | Should -Be @('avdlzdsh-001')
    Get-RotationLine 'remove-resume' | Should -Match '^phase= image=2026\.1101\.1 gen=a next= previous=2026\.1004\.1 hosts=avdlzdsha-001:open,avdlzdsha-002:open vmsGone=avdlzdsh-001,avdlzdsh-002 .* gallery=Merge 2026\.1101\.1,Delete 2026\.1004\.1$'
    @($states[17].warnings | Where-Object id -eq 'devices-left')[0].data.devices | Should -Be @('avdlzdsh-002')
  }
  It 'after Remove, rolls back by rotating to the previous version and frees the version it leaves' {
    Get-RotationLine 'back-finish' | Should -Match '^phase= image=2026\.1004\.1 gen=b next= previous=2026\.1101\.1 hosts=avdlzdshb-001:open,avdlzdshb-002:open .* gallery=Merge 2026\.1004\.1,Delete 2026\.1101\.1$'
  }
  It 'rolls back before Remove: the original hosts take sessions again and the new ones are removed; a preview writes nothing' {
    # Paused before Drain by the pause the first run recorded: the new hosts are ready, the pool's image and
    # generation are unchanged, nothing drains, and the pause is spent.
    $states[22].warnings[0].id | Should -Be 'rotation-paused'
    $states[22].context.stopBefore | Should -Be 'Drain'
    Get-RotationLine 'rb-paused' | Should -Match '^phase=Deploy image=2026\.1004\.1 gen= .*hosts=avdlzdsh-001:open,avdlzdsh-002:open,avdlzdsha-001:open,avdlzdsha-002:open vmsGone= '
    Get-RotationLine 'rb-paused' 'stop' | Should -BeNullOrEmpty
    # Paused before Remove: drained and empty, but kept for a rollback.
    $states[23].warnings[-1].id | Should -Be 'rotation-paused'
    $states[23].context.phase | Should -Be 'Wait'
    $states[23].warnings[-1].remediation | Should -Match 'or with -Rollback to undo'
    Get-RotationLine 'rb-drain' | Should -Match '^phase=Wait .*hosts=avdlzdsh-001:drain,avdlzdsh-002:drain,avdlzdsha-001:open,avdlzdsha-002:open vmsGone= '
    @($states[24].failures.id) | Should -Be @('rotation-stop')
    Get-RotationLine 'rb-drain' | Should -Match 'hosts=avdlzdsh-001:drain,avdlzdsh-002:drain,avdlzdsha-001:open,avdlzdsha-002:open'
    Get-RotationLine 'rb-drain' 'excluded' | Should -Be 'avdlzdsh-001,avdlzdsh-002'
    Get-RotationLine 'rollback' 'excluded' | Should -Be 'avdlzdsha-001,avdlzdsha-002'
    $out | Should -Match 'RESULT rollback-whatif-writes 0'
    # Not while an original host is stopped: the new ones keep serving.
    $states[-3].status | Should -Be 'waiting'
    $states[-3].warnings[0].detail | Should -Match 'Not Available with every health check passing: avdlzdsh-001\. The new hosts keep taking sessions'
    Get-RotationLine 'rollback-stopped' | Should -Match '^phase=Drain .* hosts=avdlzdsh-001:open,avdlzdsh-002:open,avdlzdsha-001:open,avdlzdsha-002:open '
    Get-RotationLine 'rollback' | Should -Match '^phase= image=2026\.1004\.1 gen= next= previous=2026\.1004\.1 hosts=avdlzdsh-001:open,avdlzdsh-002:open vmsGone=avdlzdsha-001,avdlzdsha-002 .*Delete 2026\.1101\.1$'
    $states[-2].status | Should -Be 'done'
    $states[-2].context.version | Should -Be 'rollback'
  }
  It 'does not roll back while the deployment still runs, nor to the version the pool runs again' {
    $states[21].status | Should -Be 'waiting'
    $states[21].warnings[0].detail | Should -Match 'avdlz-dev-rota-\d{8}-\d{6} of generation a is still running'
    Get-RotationLine 'rb-running' | Should -Match '^phase=Deploy image=2026\.1004\.1 gen= next=2026\.1101\.1 '
    $states[-1].status | Should -Be 'refused'
    @($states[-1].failures.id) | Should -Be @('rotation-image')
    $states[-1].failures[0].remediation | Should -Match 'Nothing to roll back to'
  }
  It 'prints a portal state line for every run, with the parameter file' {
    ($states | ForEach-Object status) -join ' ' | Should -Be 'refused refused refused refused waiting waiting waiting waiting waiting waiting refused waiting waiting waiting waiting waiting waiting done waiting done waiting waiting waiting waiting refused waiting waiting done refused'
    @($states | Where-Object { $_.context.parameterFile -ne 'parameters/dev.bicepparam' }).context.parameterFile | Should -Be 'parameters/test.bicepparam'
  }
}

Describe 'Golden image build' {
  # build/specs/image-pipeline-spec.md section 5; red-team M1, M2, M3, M5, M7.
  BeforeAll {
    $script:out = Invoke-OfflineScenario 'ImageBuild'
    $script:day = [regex]::Escape([regex]::Match($out, 'RESULT today (\S+)').Groups[1].Value)
    function Get-BuildLine([string] $Step) { [regex]::Match($out, "RESULT $Step-summary (.*)").Groups[1].Value }
  }

  It 'removes a leftover template, builds from the newest source version compared as numbers, and removes its own template' {
    Get-StepExit $out 'build' | Should -Be 0
    Get-BuildLine 'build' | Should -Match "status=succeeded version=$day\.1 source=26100\.10000\.251104 runState=Succeeded validation=3 failedChecks=0 orphans=it-avdlz-2026-901-1 deploys=1 templatesLeft=0 log=True"
  }
  It 'stops when the source image and the commit are unchanged, and -Force builds the day''s next version' {
    Get-StepExit $out 'unchanged' | Should -Be 0
    Get-BuildLine 'unchanged' | Should -Match 'status=unchanged .* deploys=0'
    Get-BuildLine 'force' | Should -Match "status=succeeded version=$day\.2 "
    $out | Should -Match 'RESULT force-emergency-tag True'
  }
  It 'fails with the log''s validation evidence when the build-time validation fails, and still removes the template' {
    Get-StepExit $out 'failed-run' | Should -Be 1
    Get-BuildLine 'failed-run' | Should -Match 'status=failed .* runState=Failed validation=2 failedChecks=1 .* templatesLeft=0 log=True'
  }
  It 'reports a failed run even when the customization log can''t be read, and keeps the template, which holds the only copy of the log' {
    Get-StepExit $out 'log-unreadable' | Should -Be 1
    Get-BuildLine 'log-unreadable' | Should -Match 'status=failed .* runState=Failed .* templatesLeft=1 log=False'
    Get-BuildLine 'inconsistent' | Should -Match 'orphans=it-avdlz-\S+ .* templatesLeft=0'
  }
  It 'removes the template without its log only with -DiscardLastCopy' {
    Get-BuildLine 'discard-last-copy' | Should -Match 'templatesLeft=0 log=False'
  }
  It 'fails safe when AIB reports success but a validation line failed, marks that version, and lets the same inputs be retried' {
    Get-StepExit $out 'inconsistent' | Should -Be 1
    Get-BuildLine 'inconsistent' | Should -Match 'status=failed .* runState=Inconsistent'
    $out | Should -Match 'RESULT inconsistent-tag failed:build'
    Get-BuildLine 'retry-after-inconsistent' | Should -Match 'status=succeeded '
  }
  It 'stops before deploying anything when the gallery is missing or the build VM has no quota' {
    Get-BuildLine 'no-definition' | Should -Match 'status=failed .* deploys=0'
    Get-BuildLine 'quota' | Should -Match 'status=failed .* deploys=0'
  }
  It 'reports ARM''s error when the template deployment fails, and leaves no template behind' {
    Get-StepExit $out 'deploy-fails' | Should -Be 1
    Get-BuildLine 'deploy-fails' | Should -Match 'status=failed .* deploys=1 templatesLeft=0'
    $out | Should -Match 'InvalidTemplateDeployment'
  }
}

Describe 'Verify access: the connection check fails closed (decision 0014)' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'VerifyConnection' }
  It 'verifies a connection that reached Connected, after waiting for it to arrive' {
    Get-StepExit $out 'verified' | Should -Be 0
    $out | Should -Match 'RESULT verified-calls queries=3 first=LAQUERY 66666666-6666-6666-6666-666666666666 admin@contoso\.com /subscriptions/[^ ]+/resourceGroups/rg-avdlz-dev-avd'
    $out | Should -Match 'Connection setup \(Started to Connected\): 12\.4 s'
  }
  It 'reports errors without a connection as failed, after a second look' {
    Get-StepExit $out 'failed' | Should -Be 1
    $out | Should -Match 'RESULT failed-calls queries=2 '
  }
  It 'never passes on no rows, a connection still in progress or a failed query' {
    foreach ($case in 'none', 'inprogress', 'forbidden') { Get-StepExit $out $case | Should -Be 1 -Because $case }
    $out | Should -Match 'RESULT none-calls queries=3 '
    $out | Should -Match 'RESULT forbidden-calls queries=1 '
    $out | Should -Match 'Log Analytics query failed \(403\)'
  }
  It 'checks the demo desktop for another user' {
    Get-StepExit $out 'demo' | Should -Be 0
    $out | Should -Match 'RESULT demo-calls queries=1 first=LAQUERY \S+ alex@contoso\.com /subscriptions/[^ ]+/resourceGroups/rg-avdlz-dev-demo'
  }
  It 'ends every run with a verify state line the portal reads' {
    $s = Get-PortalState $out
    ($s | ForEach-Object { "$($_.stage):$($_.status)" }) -join ' ' |
      Should -Be 'verify:verified verify:failed verify:notverified verify:notverified verify:notverified verify:verified'
    $s[0].context.connections[0].connectionSetupSeconds | Should -Be 12.4
    $s[0].warnings[0].id | Should -Be 'connect-errors'
    $s[1].failures[0].id | Should -Be 'connect-errors'
    $s[2].failures[0].id | Should -Be 'no-connection'
    $s[3].failures[0].id | Should -Be 'in-progress'
    $s[4].failures[0].id | Should -Be 'query-failed'
    $s[4].failures[0].data.status | Should -Be 403
  }
}

Describe 'One Microsoft Graph sign-in per session (decision 0016)' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'GraphSignIn' }

  It 'creates the operator app: public client, every scope consented, assignment required, you and the group assigned' {
    Get-StepExit $out 'setup' | Should -Be 0
    $out | Should -Match 'RESULT setup-state publicClient=True scopes=10 assignmentRequired=True consent=AllPrincipals grantScopes=11 assigned=me-1,22222222-2222-2222-2222-222222222222 clientIdSet=True setupClient=client=default deviceGranted=True'
  }
  It "grants a scope Graph's service principal doesn't list, by name, instead of failing (lesson 0030)" {
    $out | Should -Match 'granted by name only and not shown under the app''s API permissions: Device\.ReadWrite\.All'
  }
  It 'switches from a default-app sign-in to the operator app once its client ID is set' {
    $out | Should -Match 'RESULT default-to-operator connects=1 client=client=77777777-7777-7777-7777-777777777777 named=True'
  }
  It 'changes nothing when the setup runs again' {
    Get-StepExit $out 'setup-again' | Should -Be 0
    $out | Should -Match 'RESULT setup-again writes=0'
  }
  It 'renames an app created under its earlier name instead of creating a second one' {
    $out | Should -Match 'RESULT setup-rename exit=0 writes=2 app=avd-opsbot sp=avd-opsbot sameClient=True created=0'
  }
  It 'turns assignment required back on when it was turned off' { $out | Should -Match 'RESULT setup-drift writes=1 assignmentRequired=True' }
  It 'signs in once, through the operator app, for the sign-in, preflight, -Fix, demo and cleanup' {
    Get-StepExit $out 'op-signin' | Should -Be 0
    foreach ($s in 'op-fix', 'op-demo', 'op-remove') { Get-StepExit $out $s | Should -Be 0 -Because $s }
    $out | Should -Match 'RESULT op-session connects=1 client=client=77777777-7777-7777-7777-777777777777'
  }
  It "signs in once through Microsoft's default app without AVD_GRAPH_CLIENT_ID" {
    foreach ($s in 'default-fix', 'default-demo', 'default-remove') { Get-StepExit $out $s | Should -Be 0 -Because $s }
    $out | Should -Match 'RESULT default-session connects=1 client=client=default'
  }
  It 'names a client ID that is not a GUID and how to clear it' { $out | Should -Match 'RESULT bad-client-id exit=1 named=True wayOut=True' }
}

Describe 'Run recorder: run store and the cost gate' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'RunRecorder' }

  It 'refuses to open a run in Azure without a run store' { Get-StepExit $out 'start-no-store' | Should -Be 1 }
  It 'refuses the run store while Defender for Storage would bill it, and deploys nothing' {
    Get-StepExit $out 'store-defender-on' | Should -Be 1
    $out | Should -Match 'RESULT defender-on deploys=0'
  }
  It 'refuses a public companion repo' {
    Get-StepExit $out 'store-public-repo' | Should -Be 1
    $out | Should -Match 'RESULT public-repo deploys=0'
  }
  It 'deploys nothing with -WhatIf' {
    Get-StepExit $out 'store-whatif' | Should -Be 0
    $out | Should -Match 'RESULT whatif deploys=0'
  }
  It 'deploys the run store with the teardown preference and the private repo' {
    Get-StepExit $out 'store' | Should -Be 0
    $out | Should -Match 'RESULT store deploys=1 runstore=avdlzruns[0-9a-f]{12} teardownLogs=Ask repo=contoso/run-records activityLog=True'
  }
  It 'writes run.json and cost.json that match contract C17, and uploads them to the run folder' {
    Get-StepExit $out 'start' | Should -Be 0
    $out | Should -Match 'RESULT start-files valid=True gate=True limit=5 unpriced=0 totalUnderLimit=True useCase=landing-zone teardown=not-started uploaded=runs/run-20261020-1800-t3st/cost.json,runs/run-20261020-1800-t3st/run.json'
  }
  It 'exports the four AVD tables before cleanup and stores them with the run' {
    Get-StepExit $out 'stop-before-cleanup' | Should -Be 0
    $out | Should -Match 'RESULT before-cleanup tables=4 queries=4 rows=2 uploaded=4'
  }
  It 'closes the run with the first actual cost reading, not settled, naming a meter the estimate missed' {
    Get-StepExit $out 'stop-end' | Should -Be 0
    $out | Should -Match 'RESULT stop-end valid=True status=torn-down files=5 readings=1 total=3.5 settled=False unexpected=Standard Static IP afterTeardown=True runStoreInScope=True lzInScope=True'
  }
  It 'keeps earlier readings and records why there is no figure when Cost Management refuses' {
    Get-StepExit $out 'stop-update-forbidden' | Should -Be 0
    $out | Should -Match 'RESULT update-forbidden readings=2 kept=3.5 why=True'
  }
  It 'copies nothing to a public repo' {
    Get-StepExit $out 'copy-public' | Should -Be 1
    $out | Should -Match 'RESULT copy-public copies=0'
  }
  It 'fails the gate when a line cannot be priced, without guessing a price' {
    Get-StepExit $out 'start-unpriced' | Should -Be 1
    $out | Should -Match 'RESULT start-unpriced gate=False unpriced=1 match=none noGuess=True localOnly=True'
  }
}

Describe 'Same-tenant recovery (build/specs/recovery-spec.md)' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'Recovery' }

  It 'reports a fresh landing zone as not met, item by item, with a recovery state line' {
    Get-StepExit $out 'status-fresh' | Should -Be 1
    $out | Should -Match 'RESULT status-fresh stage=recovery status=notmet met=4/8 ids=dr-config,dr-identity,dr-tested,dr-iac'
  }
  It 'writes the configuration snapshot as a C17 run and never copies the host pool registration token' {
    Get-StepExit $out 'export' | Should -Be 0
    $out | Should -Match 'RESULT export valid=True useCase=recovery kind=snapshot configFiles=12 tokenLeaked=False tokenPresent=True roleAssignments=3'
  }
  It 'reports drift since the previous snapshot by resource and property' {
    $out | Should -Match 'RESULT drift changes=1 path=hostpools\[/subscriptions/.+/hostpools/vdpool-avdlz-dev\]\.properties\.maxSessionLimit before=8 after=10'
  }
  It 'counts a snapshot only once its copy has been read back' { $out | Should -Match 'RESULT status-copied met=5/8 ids=dr-identity,dr-tested,dr-iac' }
  It 'catches a corrupted copy in the companion repo, and repairs nothing' {
    Get-StepExit $out 'verify' | Should -Be 0
    Get-StepExit $out 'verify-corrupted' | Should -Be 1
    $out | Should -Match 'RESULT verify-corrupted mismatch=True'
  }
  It 'plans a recovery test with an estimate and writes nothing' {
    Get-StepExit $out 'test-plan' | Should -Be 0
    $out | Should -Match 'RESULT test-plan writes=0 status=ready estimate=True'
  }
  It 'restores into a new storage account, never over the source, and records the measured RPO' {
    Get-StepExit $out 'test-go' | Should -Be 0
    $out | Should -Match 'RESULT test-go status=passed outcome=passed valid=True recoveryType=AlternateLocation intoNew=True rpoMinutes=True created=2'
  }
  It 'counts a passed test toward the tier' { $out | Should -Match 'RESULT status-tested met=6/8 ids=dr-identity,dr-iac' }
  It 'removes the test resources and records a clean teardown, leaving the source alone' {
    Get-StepExit $out 'test-cleanup' | Should -Be 0
    $out | Should -Match 'RESULT test-cleanup rgGone=True teardown=clean sourceKept=True'
  }
  It 'shows the restore job''s own error when a test fails' {
    Get-StepExit $out 'test-go-failed' | Should -Be 1
    $out | Should -Match 'RESULT test-go-failed errorShown=True'
  }
  It 'fails R1 on a snapshot-only backup and passes it with the vaulted tier and an image replica, warning about capacity' {
    $out | Should -Match 'RESULT status-r1-snapshot ids=dr-profile-offsite,dr-identity,dr-tested,dr-iac,dr-capacity'
    $out | Should -Match 'RESULT status-r1-vaulted ids=dr-identity,dr-tested,dr-iac,dr-capacity'
  }
  It 'is met for R0 with a pushed commit, a copied identity snapshot and a passed test' {
    $out | Should -Match 'RESULT export-identity groups=2 members=1 commit=True'
    Get-StepExit $out 'status-met' | Should -Be 0
    $out | Should -Match 'RESULT status-met status=met met=8/8 ids=$'
  }
}

Describe 'Deployment portal published into the subscription (decision 0017)' {
  BeforeAll { $script:out = Invoke-OfflineScenario 'Portal' }

  It "stops before creating anything when an allowed-locations policy blocks every Static Web Apps region, and names the storage option (red team PH-6)" {
    $out | Should -Match 'RESULT swa-blocked exit=1 deploys=0 storageNamed=True policyNamed=True'
  }
  It 'publishes to Static Web Apps with the pinned CLI; the token is passed in the environment, cleared, reset after the upload and never printed (PH-2)' {
    $out | Should -Match 'RESULT swa exit=0 deploy=hosting=StaticWebApp location=eastus2 swaLocation=eastus2 uploader= pinned=True tokenPassed=1 tokenCleared=True resetAfterUpload=True tokenPrinted=False '
  }
  It 'pins the repo and ref the commands run in portal-config.js (PH-3)' {
    $out | Should -Match 'repo=https://github.com/contoso/avd-landing-zone ref=v1.2.0 hosting=StaticWebApp '
  }
  It 'with -RequireSignIn, lets only invited operators in, turns GitHub sign-in off and invites the operator (PH-1)' {
    $out | Should -Match 'routes=/.auth/login/github=404,/.auth/\*=anonymous,/denied.html=anonymous,/\*=operator '
    $out | Should -Match 'invited=operator/aad/admin@contoso.com files=6'
  }
  It 'sends the headers GitHub Pages cannot (PH-9)' { $out | Should -Match 'csp=True frames=DENY' }
  It 'prints the AVD_PORTAL_URL line for the published copy' { $out | Should -Match 'RESULT swa-url printed=True portalUrl=https://nice-sea-0a1b2c3d4.azurestaticapps.net/portal/' }
  It "without sign-in sets no routes, and by default pins this checkout's GitHub origin and commit" {
    Get-StepExit $out 'swa-open' | Should -Be 0
    $out | Should -Match 'RESULT swa-open-state routes=0 commitRef=True githubRepo=True invitations=0'
  }
  It 'reports a paid plan without changing it, shows a failed upload and still resets the token (PH-7)' {
    $out | Should -Match 'RESULT swa-fail exit=1 resets=1 paidWarned=True errorShown=True planChanged=0'
  }
  It 'publishes a storage static website with content types, waits out the upload role, removes old files, and uses no npm or token' {
    $out | Should -Match 'RESULT storage exit=0 deploy=hosting=Storage location=northcentralus swaLocation=centralus uploader=me website=True html=text/html; charset=utf-8 js=text/javascript; charset=utf-8 font=font/woff2 svg=image/svg\+xml oldRemoved=True retried=True npx=0 secrets=0 ref=v1.2.0 anyoneNote=True'
  }
  It 'refuses a repo URL or ref that is not plain, and sign-in on storage, before deploying (PH-4)' { $out | Should -Match 'RESULT bad-input refused,refused,refused deploys=0' }
  It '-Remove deletes the resource group, and is clean the second time' {
    Get-StepExit $out 'remove' | Should -Be 0
    Get-StepExit $out 'remove-again' | Should -Be 0
    $out | Should -Match 'RESULT remove deleted=1'
  }
  It 'the scripts name the GitHub Pages portal unless AVD_PORTAL_URL is an https URL, and spell out an override (PH-5)' {
    $out | Should -Match 'RESULT portal-url default=True hostNamed=True override=True httpIgnored=True'
  }
}
