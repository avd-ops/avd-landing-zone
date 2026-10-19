# The auto-shutdown runbook (scripts/automation/Invoke-AvdPowerAction.ps1) against the mocked
# landing zone: host 001 has two user sessions, 002 is idle. First as Automation runs it (managed
# identity endpoint), then from Cloud Shell (Get-AzAccessToken).
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$global:St.unregistered = @()   # providers are covered by the other scenarios
$env:IDENTITY_ENDPOINT = 'http://127.0.0.1:42/msi/token'; $env:IDENTITY_HEADER = 'test-header'
$p = @{ NamePrefix = 'avdlz'; Environment = 'dev'; SubscriptionId = '00000000-aaaa-bbbb-cccc-000000000001' }
$pw = $global:St.power
function Show-Power([string] $Step) {
  Write-Host ("RESULT $Step-state startVMOnConnect={0} locked={1} allowNew={2},{3} state={4},{5} excluded={6},{7} deallocateCalls={8} messages={9} changes={10}" -f `
      $pw.startVMOnConnect, [bool]$pw.hpTags.'avdlz-power-lock', $pw.allowNew['avdlzdsh-001'], $pw.allowNew['avdlzdsh-002'], $pw.state['avdlzdsh-001'], $pw.state['avdlzdsh-002'],
      (@($pw.vmTags['avdlzdsh-001']) -contains 'avd-scaling-exclude'), (@($pw.vmTags['avdlzdsh-002']) -contains 'avd-scaling-exclude'),
      @($global:Calls | Where-Object { $_ -match 'POST .*/deallocate' }).Count, @($global:Calls | Where-Object { $_ -match 'sendMessage' }).Count,
      @($global:Calls | Where-Object { $_ -match '^ARM (PATCH|POST)' }).Count)
  $global:Calls.Clear()
}

Invoke-ScenarioStep 'stop' { & ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Stop @p -Reason schedule }
Show-Power 'stop'
Invoke-ScenarioStep 'lock-whatif' { & ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Lock @p -Reason budget -WhatIf }
Show-Power 'lock-whatif'
Invoke-ScenarioStep 'lock' { & ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Lock @p -Reason budget }
Show-Power 'lock'
Write-Host "RESULT lock-reason $($pw.hpTags.'avdlz-power-lock' -replace ' .*$', '') keptTags=$([bool]$pw.hpTags.workload)"

# While locked, the post-deployment check says so and gives the resume command.
Invoke-ScenarioStep 'check-locked' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -SkipTenant -SkipNtfs }
$global:Calls.Clear()

# Cloud Shell: no managed identity endpoint; the operator's own token.
Remove-Item env:IDENTITY_ENDPOINT, env:IDENTITY_HEADER
Invoke-ScenarioStep 'resume' { & ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Resume @p }
Show-Power 'resume'
Invoke-ScenarioStep 'check-resumed' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -SkipTenant -SkipNtfs }
$global:Calls.Clear()

# Deployed with Start VM on Connect off (the portal's Cost step): the template tags the host pool,
# and Resume clears the lock without turning Start VM on Connect on.
$pw.hpTags['avdlz-start-vm-on-connect'] = 'false'; $pw.startVMOnConnect = $false
Invoke-ScenarioStep 'lock-svmoc-off' { & ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Lock @p -Reason budget }
Invoke-ScenarioStep 'resume-svmoc-off' { & ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Resume @p }
Show-Power 'resume-svmoc-off'
$pw.hpTags.Remove('avdlz-start-vm-on-connect')

# A failed call reports what ARM returned (build/lessons/0012).
$pw.failHostPoolPatch = $true
try { & ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Lock @p -Reason budget; Write-Host 'RESULT error none' }
catch { Write-Host "RESULT error $($_.Exception.Message)" }
