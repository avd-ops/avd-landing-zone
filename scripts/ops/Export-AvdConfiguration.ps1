#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Snapshots the landing zone's configuration that the Bicep doesn't hold, as a recorded run, so a
  rebuild can put it back (build/specs/recovery-spec.md section 7).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Read-only in Azure. Reads through ARM REST:
    host pools, application groups and their applications, workspaces, scaling plans and their
    schedules, session hosts' drain state, role assignments at the landing zone's resource groups
    and application groups, diagnostic settings, budgets, resource group tags, and the deployment's
    parameters as deployed (secure ones recorded as present, never their value).
  With -IncludeIdentity, also the AVD-scoped Entra objects through Microsoft Graph: the AVD user and
  admin groups with their member IDs, the operator app's registration (no credentials; it has none),
  and the Conditional Access policies that name those groups or the Azure Virtual Desktop app.
  Tenant-wide settings are out of scope.

  Writes them to config/*.json in a new run folder (use case 'recovery', kind 'snapshot', contract
  C17), with run.json and its manifest, and lists what changed since the previous snapshot. Secrets
  are never copied: secret-looking properties are recorded as '<present>' (spec D4).

  The snapshot holds object IDs and names: private level. Copy it to your private companion repo with
  the recorder, which reads the copy back before it counts (spec D3):
    ./scripts/ops/Stop-AvdRunRecorder.ps1 -RunId <runId> -Local -CopyTo github

.EXAMPLE
  ./scripts/ops/Export-AvdConfiguration.ps1 -NamePrefix avdlz -Environment dev

.EXAMPLE
  ./scripts/ops/Connect-AvdLandingZone.ps1
  ./scripts/ops/Export-AvdConfiguration.ps1 -NamePrefix avdlz -Environment dev -IncludeIdentity
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [ValidateSet('dev', 'test', 'prod')][string] $Environment = 'dev',
  [ValidateSet('R0', 'R1', 'R2')][string] $RecoveryTier = 'R0',
  [switch] $IncludeIdentity,
  [string] $LocalRoot = $(if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }),
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRecovery.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
$runId = Get-AvdRunId
$started = [datetime]::UtcNow
Write-Host "Configuration snapshot - $NamePrefix-$Environment in '$($ctx.Subscription.Name)', run $runId" -ForegroundColor White

$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
if (-not $lz.RgExists.ControlPlane) { throw "No landing zone $NamePrefix-$Environment in this subscription (rg-$($lz.BaseName)-avd not found)." }
$sub = "/subscriptions/$($ctx.Subscription.Id)"
$avd = '2024-04-03'
$folder = (Get-AvdJournalSetting -Record on -RunId $runId -HomePath $LocalRoot -CloudDriveExists (Test-Path (Join-Path $LocalRoot 'clouddrive'))).Folder
$configDir = Join-Path $folder 'config'
$null = New-Item -ItemType Directory -Path $configDir -Force
$written = [ordered]@{}
# Lists are always written as JSON arrays, even with one item, so snapshots compare the same way.
$save = {
  param([string] $Name, $Data, [switch] $Object)
  $clean = if ($Object) { Get-AvdConfigurationSnapshot -InputObject $Data } else { , @(@($Data | Where-Object { $null -ne $_ }) | ForEach-Object { Get-AvdConfigurationSnapshot -InputObject $_ }) }
  ConvertTo-Json -InputObject $clean -Depth 30 | Set-Content -LiteralPath (Join-Path $configDir "$Name.json") -Encoding utf8
  $n = if ($Object) { 1 } else { $clean.Count }
  $written[$Name] = $n
  Add-AvdCheckResult 'Snapshot' "$Name ($n)" 'Pass' -Id "config-$Name"
}
$read = {
  param([string] $What, [scriptblock] $Do)
  try { @(& $Do) }
  catch { Add-AvdCheckResult 'Snapshot' "Read $What" 'Fail' -Id 'config-read' -Detail "$_" -Remediation 'Nothing was guessed: check your role (Reader on the landing zone) and run this again.' -Data @{ what = $What }; @() }
}

Write-AvdSection 'Azure Virtual Desktop'
Write-Host '  Reading host pools, application groups, workspaces and scaling plans...' -ForegroundColor DarkGray
$cp = $lz.ResourceGroupIds.ControlPlane
$hostPools = & $read 'host pools' { Get-AvdArmList -Path "$cp/providers/Microsoft.DesktopVirtualization/hostPools?api-version=$avd" }
& $save 'hostpools' $hostPools
$appGroups = & $read 'application groups' { Get-AvdArmList -Path "$cp/providers/Microsoft.DesktopVirtualization/applicationGroups?api-version=$avd" }
& $save 'applicationgroups' $appGroups
$apps = foreach ($ag in $appGroups) {
  & $read "applications of $($ag.name)" { Get-AvdArmList -Path "$($ag.id)/applications?api-version=$avd" }
}
& $save 'applications' @($apps)
& $save 'workspaces' (& $read 'workspaces' { Get-AvdArmList -Path "$cp/providers/Microsoft.DesktopVirtualization/workspaces?api-version=$avd" })
$plans = & $read 'scaling plans' { Get-AvdArmList -Path "$cp/providers/Microsoft.DesktopVirtualization/scalingPlans?api-version=$avd" }
& $save 'scalingplans' $plans
$schedules = foreach ($p in $plans) {
  & $read "schedules of $($p.name)" { Get-AvdArmList -Path "$($p.id)/pooledSchedules?api-version=$avd" }
}
& $save 'scalingplanschedules' @($schedules)
# Only what a rebuild re-applies: which hosts were drained. Everything else about a host is rebuilt.
$hosts = foreach ($hp in $hostPools) {
  & $read "session hosts of $($hp.name)" { Get-AvdArmList -Path "$($hp.id)/sessionHosts?api-version=$avd" } |
    ForEach-Object { [ordered]@{ name = $_.name; allowNewSession = $_.properties.allowNewSession; assignedUser = $_.properties.assignedUser } }
}
& $save 'sessionhosts' @($hosts)

Write-AvdSection 'Access, diagnostics and cost controls'
Write-Host '  Reading role assignments, diagnostic settings, budgets and tags...' -ForegroundColor DarkGray
$scopes = @($lz.ResourceGroupIds.Keys | Where-Object { $lz.RgExists[$_] } | ForEach-Object { $lz.ResourceGroupIds[$_] }) + @($appGroups | ForEach-Object id)
$assignments = foreach ($s in $scopes) {
  # atScope(): only what is assigned at this scope, not what it inherits from the subscription.
  & $read "role assignments at $s" { Get-AvdArmList -Path "$s/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" } |
    ForEach-Object { [ordered]@{ id = $_.id; scope = $_.properties.scope; roleDefinitionId = $_.properties.roleDefinitionId; principalId = $_.properties.principalId; principalType = $_.properties.principalType } }
}
& $save 'roleassignments' @($assignments | Sort-Object { $_.id } -Unique)
$diag = foreach ($r in @($hostPools) + @($appGroups) + @(& $read 'workspaces' { Get-AvdArmList -Path "$cp/providers/Microsoft.DesktopVirtualization/workspaces?api-version=$avd" })) {
  & $read "diagnostic settings of $($r.name)" { Get-AvdArmList -Path "$($r.id)/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" } |
    ForEach-Object { [ordered]@{ resource = $r.id; name = $_.name; properties = $_.properties } }
}
& $save 'diagnosticsettings' @($diag)
& $save 'budgets' @(& $read 'budgets' { Get-AvdArmList -Path "$sub/providers/Microsoft.Consumption/budgets?api-version=2023-05-01" } | Where-Object { "$($_.name)" -like "*$($lz.BaseName)*" })
& $save 'resourcegroups' @(Get-AzResourceGroup -ErrorAction SilentlyContinue | Where-Object { $_.ResourceGroupName -like "rg-$($lz.BaseName)-*" } |
    ForEach-Object { [ordered]@{ name = $_.ResourceGroupName; location = $_.Location; tags = $_.Tags } })

Write-AvdSection 'Deployment'
$deployment = & $read 'the deployment records' {
  @(Get-AvdArmList -Path "$sub/providers/Microsoft.Resources/deployments?api-version=2021-04-01" |
      Where-Object { $_.name -match "^avdlz-$([regex]::Escape($Environment))-\d{8}-\d{6}$" -and "$($_.properties.provisioningState)" -eq 'Succeeded' }) |
    Sort-Object { [datetime]$_.properties.timestamp } -Descending | Select-Object -First 1
}
$commit = $null
if ($deployment) {
  $dep = $deployment | Select-Object -First 1
  $commit = (Get-AvdDeployedCommit -RunbookUri "$($dep.properties.parameters.autoShutdownRunbookUri.value)").Commit
  & $save 'deployment' -Object ([ordered]@{ name = $dep.name; timestamp = $dep.properties.timestamp; commit = $commit; parameters = $dep.properties.parameters })
}
else { Add-AvdCheckResult 'Snapshot' 'Deployment record' 'Warn' -Id 'config-deployment' -Detail 'No succeeded deploy.sh record: the snapshot has no parameters to rebuild with.' }

if ($IncludeIdentity) {
  Write-AvdSection 'Identity (AVD-scoped)'
  Connect-AvdGraph -Purpose Read
  Write-Host '  Reading the AVD groups, the operator app and the Conditional Access policies that name them...' -ForegroundColor DarkGray
  $groupIds = @($lz.UsersGroupId, $lz.AdminsGroupId | Where-Object { $_ })
  $groups = foreach ($g in $groupIds) {
    $o = & $read "group $g" { Invoke-AvdGraph -Uri "v1.0/groups/$($g)?`$select=id,displayName,description,securityEnabled,mailEnabled,groupTypes,membershipRule,membershipRuleProcessingState,isAssignableToRole" }
    $members = & $read "members of $g" { Invoke-AvdGraph -Uri "v1.0/groups/$g/members?`$select=id" }
    if ($o) { [ordered]@{ group = $o | Select-Object -First 1; memberIds = @($members | ForEach-Object id | Sort-Object) } }
  }
  $app = $null
  if ($env:AVD_GRAPH_CLIENT_ID) {
    $app = & $read 'the operator app' { Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection 'applications' -Filter "appId eq '$($env:AVD_GRAPH_CLIENT_ID.Trim())'" -Select 'id,appId,displayName,signInAudience,requiredResourceAccess,publicClient,isFallbackPublicClient') }
  }
  # Policies whose users or applications name the AVD groups or the Azure Virtual Desktop app.
  $avdAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'
  $names = @($groupIds) + $avdAppId
  $policies = @(& $read 'Conditional Access policies' { Invoke-AvdGraph -Uri 'v1.0/identity/conditionalAccess/policies' }) | Where-Object {
    $c = $_.conditions
    $refs = @($c.users.includeGroups) + @($c.users.excludeGroups) + @($c.applications.includeApplications) + @($c.applications.excludeApplications)
    @($refs | Where-Object { $_ -in $names }).Count
  }
  $identity = [ordered]@{ groups = @($groups); operatorApp = $(if ($app) { $app | Select-Object -First 1 }); conditionalAccessPolicies = @($policies) }
  & $save 'identity' $identity -Object
}

# What changed since the previous snapshot, file by file. Reported, never applied.
Write-AvdSection 'Drift since the previous snapshot'
$roots = @((Join-Path $LocalRoot 'clouddrive/avdlz-runs'), (Join-Path $LocalRoot 'avdlz-runs') | Where-Object { Test-Path -LiteralPath $_ })
$previous = @(foreach ($root in $roots) {
    foreach ($f in Get-ChildItem -LiteralPath $root -Filter run.json -Recurse -Depth 1 -ErrorAction SilentlyContinue) {
      try { $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable; if ($r.runId -ne $runId) { $r['folder'] = $f.DirectoryName; $r } } catch { Write-Verbose "Not a run record: $($f.FullName)" }
    }
  }) | Where-Object { $_.useCase -eq 'recovery' -and $_.extensions.recovery.kind -eq 'snapshot' } | Sort-Object { [datetime]$_.started } -Descending | Select-Object -First 1
$drift = @()
if (-not $previous) { Add-AvdCheckResult 'Snapshot' 'Drift' 'Skip' -Id 'config-drift' -Detail 'No earlier snapshot to compare with.' }
else {
  foreach ($name in $written.Keys) {
    $old = Join-Path $previous.folder "config/$name.json"
    if (-not (Test-Path -LiteralPath $old)) { continue }
    $a = Get-Content -LiteralPath $old -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    $b = Get-Content -LiteralPath (Join-Path $configDir "$name.json") -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    $drift += @(Get-AvdConfigurationDrift -Reference $a -Current $b -Path $name)
  }
  if ($drift.Count) {
    ConvertTo-Json -InputObject @($drift) -Depth 5 | Set-Content -LiteralPath (Join-Path $configDir 'drift.json') -Encoding utf8
    foreach ($d in $drift | Select-Object -First 10) { Write-Host "  $($d.Change): $($d.Path)" -ForegroundColor DarkYellow }
  }
  Add-AvdCheckResult 'Snapshot' "Drift since $($previous.runId): $($drift.Count) change(s)" $(if ($drift.Count) { 'Warn' } else { 'Pass' }) -Id 'config-drift' `
    -Detail $(if ($drift.Count) { 'Listed in config/drift.json. Expected after a change you made; otherwise, find out who changed what.' } else { 'Nothing changed.' }) -Data @{ previous = $previous.runId; changes = $drift.Count }
}

# run.json last: the C17 envelope with the manifest of every file.
$items = @(
  [ordered]@{ id = 'P1'; source = 'git'; copy = $(if ($commit) { "commit $commit" } else { 'unknown' }) }
  [ordered]@{ id = 'P2'; source = "$NamePrefix-$Environment"; copy = 'config/' }
)
if ($IncludeIdentity) { $items += [ordered]@{ id = 'P6'; source = 'Entra ID (AVD-scoped)'; copy = 'config/identity.json' } }
$recordCommit = '0000000'
if (Get-Command git -ErrorAction SilentlyContinue) { $h = git -C $PSScriptRoot rev-parse --short HEAD 2>$null; if (-not $LASTEXITCODE -and $h) { $recordCommit = "$h".Trim() } }
$record = Get-AvdRunRecord -RunId $runId -UseCase 'recovery' -Commit $recordCommit -Entry 'Export-AvdConfiguration.ps1' -Region $lz.Location -Started $started `
  -Extension ([ordered]@{ kind = 'snapshot'; tier = $RecoveryTier; items = $items; landingZone = $lz.BaseName })
$failed = @(Get-AvdCheckResult | Where-Object Status -eq 'Fail').Count
$record.status = if ($failed) { 'failed' } else { 'succeeded' }
$record.ended = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$record.files = @(Get-AvdRunManifest -Folder $folder | ForEach-Object {
    $e = [ordered]@{}; foreach ($p in $_.PSObject.Properties) { $e[$p.Name] = $p.Value }
    if ($e.path -like 'config/*') { $e.kind = 'config' }
    $e
  })
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'run.json') -Encoding utf8

Write-AvdSection 'Copy'
Add-AvdCheckResult 'Snapshot' "Run folder $folder ($(@($record.files).Count) files)" $(if ($failed) { 'Warn' } else { 'Pass' }) -Id 'config-run' `
  -Detail 'Private level: object IDs and names, no secrets. It counts for recovery once a copy is read back.' `
  -Remediation "Copy it: ./scripts/ops/Stop-AvdRunRecorder.ps1 -RunId $runId -Local -CopyTo github" -Data @{ runId = $runId }
Write-Host ''
Write-Host 'Next: copy the snapshot to your private companion repo (read back and checked before it counts):' -ForegroundColor White
Write-Host "  ./scripts/ops/Stop-AvdRunRecorder.ps1 -RunId $runId -Local -CopyTo github"
$summary = Write-AvdSummary
exit $(if ($summary.Failed) { 1 } else { 0 })
