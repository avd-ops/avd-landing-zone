# The golden image build (scripts/ops/Start-AvdImageBuild.ps1) against the mocked images resource
# group: a leftover template from a run that died, one published version, three marketplace versions
# whose newest only wins when compared as numbers. Compiles parameters/images-build.bicepparam, so it
# needs the Bicep CLI (CI and the session hook install it).
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$global:St.unregistered = @()
$im = $global:St.images
$summaryFile = Join-Path ([IO.Path]::GetTempPath()) "avdlz-image-summary-$PID.json"
$p = @{ NamePrefix = 'avdlz'; Commit = 'abc1234'; RunUrl = 'https://github.com/o/r/actions/runs/1'; PollSeconds = 0; SummaryPath = $summaryFile }
function Show-Build([string] $Step) {
  $s = Get-Content $summaryFile -Raw | ConvertFrom-Json
  $deploys = @($global:Calls | Where-Object { $_ -match 'ARM PUT .*/deployments/' }).Count
  Write-Host ("RESULT $Step-summary status={0} version={1} source={2} runState={3} validation={4} failedChecks={5} orphans={6} deploys={7} templatesLeft={8} log={9}" -f `
      $s.status, $s.version, $s.sourceImageVersion, $s.runState, @($s.validation).Count, @($s.validation | Where-Object status -eq 'Fail').Count,
      (@($s.removedOrphans) -join ','), $deploys, $im.templates.Count, [bool]$s.logPath)
  $global:Calls.Clear(); Remove-Item $summaryFile -ErrorAction SilentlyContinue
}
$today = Get-Date -AsUTC
$day = '{0}.{1}' -f $today.Year, ($today.Month * 100 + $today.Day)
Write-Host "RESULT today $day"

# A new commit: builds from the newest source version, after removing the leftover template.
Invoke-ScenarioStep 'build' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p }
Show-Build 'build'

# Nothing changed: same source, same commit.
Invoke-ScenarioStep 'unchanged' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p }
Show-Build 'unchanged'

# -Force builds anyway (an out-of-band update arrives through Windows Update), as the day's second build.
Invoke-ScenarioStep 'force' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p -Force -Emergency }
Show-Build 'force'
Write-Host "RESULT force-emergency-tag $(($im.versions | Where-Object name -eq "$day.2").tags.'avdlz-emergency')"

# The build-time validation fails: the run fails, the log's RESULT lines say why, the template goes.
$im.runOutcome = 'Failed'
$im.log = @('[PowerShell] golden-image: RESULT os-release Pass DisplayVersion=24H2', '[PowerShell] golden-image: RESULT protected-services Fail disabled=dmwappushservice absent= checked=20', 'Golden image validation: 1 failure(s).')
Invoke-ScenarioStep 'failed-run' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p -Commit 'def5678' }
Show-Build 'failed-run'

# The log can't be read (no access to the staging storage): still reports the run status, no crash.
$im.logUnreadable = $true
Invoke-ScenarioStep 'log-unreadable' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p -Commit 'def5678' }
Show-Build 'log-unreadable'
$im.logUnreadable = $false; $im.runOutcome = 'Succeeded'

# AIB reports success, but the log has a failed validation line: inconsistent evidence fails safe.
Invoke-ScenarioStep 'inconsistent' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p -Commit 'eee5555' }
Show-Build 'inconsistent'
Write-Host "RESULT inconsistent-tag $(($im.versions | Where-Object name -eq "$day.3").tags.'avdlz-validation')"
$im.log = @('[PowerShell] golden-image: RESULT os-release Pass DisplayVersion=24H2')
# The same commit again: the version marked failed doesn't count as built, so it isn't 'unchanged'.
Invoke-ScenarioStep 'retry-after-inconsistent' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p -Commit 'eee5555' }
Show-Build 'retry-after-inconsistent'

# bicep/images/main.bicep not deployed yet.
$im.definition = $false
Invoke-ScenarioStep 'no-definition' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p -Commit 'aaa1111' }
Show-Build 'no-definition'
$im.definition = $true

# No quota for the build VM's family: stops before deploying anything (lessons 0013, 0024).
$global:St.dsLimit = 0
Invoke-ScenarioStep 'quota' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p -Commit 'bbb2222' }
Show-Build 'quota'
$global:St.dsLimit = $null

# The template deployment fails (for example, the build subnets were never deployed): ARM's error is reported.
$im.deployFails = $true
Invoke-ScenarioStep 'deploy-fails' { & ./scripts/ops/Start-AvdImageBuild.ps1 @p -Commit 'ccc3333' }
Show-Build 'deploy-fails'
