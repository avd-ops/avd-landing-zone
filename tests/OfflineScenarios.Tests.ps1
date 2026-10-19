#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# End-to-end runs of the ops scripts against the offline Azure/Graph mock in tests/offline.
# Each scenario runs in its own pwsh process (the mock replaces Az and Graph globally) and
# prints "RESULT <step> ..." lines. Needs the Bicep CLI on PATH (pre-deployment compiles
# the parameter files).
# Every scenario encodes something a real run taught us; see docs/lessons.

BeforeAll {
  $script:pwsh = (Get-Process -Id $PID).Path
  function Invoke-OfflineScenario([string] $Name) {
    $file = Join-Path $PSScriptRoot "offline/$Name.Scenario.ps1"
    $out = & $script:pwsh -NoProfile -NonInteractive -File $file 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Scenario $Name crashed (exit $LASTEXITCODE):`n$out" }
    $out
  }
  # The machine-readable state lines the deployment portal reads (docs/portal/README.md).
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
  It 'fails the demo host check by name when a Kerberos client service is stopped' { $out | Should -Match 'RESULT kerberos-services failed=True named=True' }
  It 'deploys and validates the demo, then removes it' {
    Get-StepExit $out 'demo' | Should -Be 0
    Get-StepExit $out 'remove-demo' | Should -Be 0
  }
  It 'keeps the demo record when the device cleanup fails, so a rerun finishes it (lesson 0029)' { $out | Should -Match 'RESULT device-retry kept=True named=True rerunDeleted=True recordGone=True' }
  It 'changes nothing when removing the landing zone with -WhatIf' { $out | Should -Match 'RESULT remove-lz-whatif changes=0' }
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
  It 'reads the AVD host pool regions from the provider API' { $out | Should -Match '\[PASS \] AVD host pools offered in northcentralus' }
  It 'blocks prod on a soft-deleted, purge-protected Key Vault' {
    Get-StepExit $out 'prod-zone-and-vault' | Should -Be 1
    $out | Should -Match '\[FAIL \] No soft-deleted Key Vault blocking the vault name'
  }
  It 'gives the portal the context and structured failures it needs' {
    $s = Get-PortalState $out
    ($s | ForEach-Object { "$($_.stage):$($_.status)" }) -join ' ' | Should -Be 'predeploy:notready predeploy:ready predeploy:ready predeploy:notready predeploy:notready predeploy:ready predeploy:ready predeploy:ready predeploy:ready predeploy:ready predeploy:ready'
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
  It 'makes no az call the fake does not know' {
    foreach ($s in 'stopped', 'stopped-fails', 'whatif', 'running', 'first', 'locked', 'locked-whatif', 'locked-unlock') { Get-Result "$s-unmocked" | Should -Be 'False' }
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

Describe 'Golden image build' {
  # docs/image-pipeline-spec.md section 5; red-team M1, M2, M3, M5, M7.
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
  It 'reports a failed run even when the customization log can''t be read' {
    Get-StepExit $out 'log-unreadable' | Should -Be 1
    Get-BuildLine 'log-unreadable' | Should -Match 'status=failed .* runState=Failed .* log=False'
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
