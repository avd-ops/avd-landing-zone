#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for the target-state manifest reader (scripts/ops/AvdTargetState.psm1 and
# ConvertFrom-AvdTargetState.ps1), against the vendored avd-second-brain contracts in contracts/.
# Run: Invoke-Pester ./build/tests

BeforeAll {
  $script:root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  Import-Module (Join-Path $script:root 'scripts/ops/AvdTargetState.psm1') -Force
  $script:contracts = Join-Path $script:root 'contracts'
  $script:exampleFile = Join-Path $script:contracts 'examples/target-state.example.json'
  $script:approvalFile = Join-Path $script:contracts 'examples/target-approval.example.json'
  $script:cap = Get-Content (Join-Path $script:contracts 'target-state-capabilities.json') -Raw | ConvertFrom-Json
  $script:prodText = Get-Content (Join-Path $script:root 'parameters/prod.bicepparam') -Raw

  function Get-TestPlan {
    param([scriptblock] $Manifest = {}, [scriptblock] $Approval = {}, [string] $ParameterFileText = $script:prodText, [hashtable] $Extra = @{})
    $m = Get-Content $script:exampleFile -Raw | ConvertFrom-Json
    $a = Get-Content $script:approvalFile -Raw | ConvertFrom-Json
    & $Manifest $m
    & $Approval $a
    $sha = if ($Extra.ContainsKey('Sha')) { $Extra.Sha } else { $a.manifestSha256 }
    $p = @{ Manifest = $m; ManifestSha256 = $sha; Approval = $a; Capabilities = $script:cap; ParameterFileText = $ParameterFileText; ParameterFile = 'parameters/prod.bicepparam' }
    foreach ($k in $Extra.Keys) { if ($k -ne 'Sha') { $p[$k] = $Extra[$k] } }
    Get-AvdTargetStatePlan @p
  }
}

Describe 'Vendored contracts' {
  It '<_> is byte-identical to its source repo at the pinned commit' -ForEach @(
    (Get-Content (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'contracts/PINS.json') -Raw | ConvertFrom-Json).files.PSObject.Properties.Name
  ) {
    $pins = Get-Content (Join-Path $script:contracts 'PINS.json') -Raw | ConvertFrom-Json
    (Get-FileHash (Join-Path $script:contracts $_) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $pins.files.$_
  }
  It 'the example manifest and approval validate, and the approval pins the manifest' {
    Test-Json -Path $script:exampleFile -SchemaFile (Join-Path $script:contracts 'schemas/target-state.schema.json') | Should -BeTrue
    Test-Json -Path $script:approvalFile -SchemaFile (Join-Path $script:contracts 'schemas/target-approval.schema.json') | Should -BeTrue
    (Get-Content $script:approvalFile -Raw | ConvertFrom-Json).manifestSha256 | Should -Be (Get-FileHash $script:exampleFile -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  It 'the capabilities know the vendored fact register version' {
    (Get-Content (Join-Path $script:contracts 'fact-register.json') -Raw | ConvertFrom-Json).version | Should -BeIn $script:cap.factRegisterVersions
  }
}

Describe 'Get-AvdTargetStatePlan' {
  It 'turns the example into the preflight and deploy.sh with the sizing as flags' {
    $p = Get-TestPlan -Extra @{ AlertEmail = 'ops@example.com' }
    $p.Refusals | Should -BeNullOrEmpty
    $p.Block | Should -Match '-SessionHostCount 8 -SessionHostVmSize Standard_E8as_v5 -MaxSessionLimit 12 -ProfileShareQuotaGiB 1024 -AutoShutdownTime 20:00 -StartVmOnConnect true'
    $p.Block | Should -Match '(?m)^\./scripts/deploy/deploy\.sh -p parameters/prod\.bicepparam -l eastus2 .*--hosts 8 --vm-size Standard_E8as_v5 --max-sessions 12 --profile-quota 1024 --auto-shutdown 20:00 --start-vm-on-connect true --what-if$'
    $p.Block | Should -Match "AVD_MONTHLY_BUDGET = '4532'"
    $p.SetByHand -join ' ' | Should -Match 'ramp-up 07:00'
  }
  It 'says the budget is not armed without -AlertEmail' {
    (Get-TestPlan).Block | Should -Match 'budget lock is not armed'
  }
  It 'uses only flags deploy.sh parses and parameters the preflight has' {
    $block = (Get-TestPlan -Extra @{ AlertEmail = 'ops@example.com' }).Block
    $deploySh = Get-Content (Join-Path $script:root 'scripts/deploy/deploy.sh') -Raw
    $deployLine = ($block -split "`n" | Where-Object { $_ -like './scripts/deploy/deploy.sh*' })[0]
    foreach ($f in [regex]::Matches($deployLine, '(?<=\s)--?[a-z-]+').Value) { $deploySh | Should -Match "(?m)^\s+$([regex]::Escape($f))\)" -Because "deploy.sh must parse $f" }
    $preflight = ($block -split "`n" | Where-Object { $_ -like './scripts/ops/Test-AvdLandingZoneReadiness.ps1*' })[0]
    $params = (Get-Command (Join-Path $script:root 'scripts/ops/Test-AvdLandingZoneReadiness.ps1')).Parameters.Keys
    foreach ($n in [regex]::Matches($preflight, '(?<=\s)-([A-Za-z]+)').Groups | Where-Object Name -eq 1 | ForEach-Object Value) { $n | Should -BeIn $params }
  }
  It 'refuses <Why>' -ForEach @(
    @{ Why = 'a manifest with no approval'; Match = 'No approval file'; Approval = $null }
    @{ Why = 'a manifest changed after approval'; Match = 'SHA-256 differs'; Sha = ('0' * 64) }
    @{ Why = 'another renderer'; Match = "renderer 'avd-lza'"; Manifest = { param($m) $m.target.renderer = 'avd-lza' } }
    @{ Why = 'listed gaps'; Match = "can't express"; Manifest = { param($m) $m.target.gaps = @('hostPools/0/type.Personal') } }
    @{ Why = 'a hybrid identity lane'; Match = 'Identity lane HybridADDS'; Manifest = { param($m) $m.identity.value = 'HybridADDS' } }
    @{ Why = 'hub-peered networking'; Match = 'Network mode HubPeered'; Manifest = { param($m) $m.network.value = 'HubPeered' } }
    @{ Why = 'a personal pool'; Match = 'Personal host pool'; Manifest = { param($m) $m.hostPools[0].type.value = 'Personal' } }
    @{ Why = 'RemoteApp'; Match = 'publishes RemoteApp'; Manifest = { param($m) $m.hostPools[0].appGroup.value = 'RemoteApp' } }
    @{ Why = 'a GPU size'; Match = 'GPU sizes'; Manifest = { param($m) $m.hostPools[0].vmSize.value = 'Standard_NV36ads_A10_v5' } }
    @{ Why = 'a Liquidware product'; Match = 'avd-liquidware'; Manifest = { param($m) $m.liquidware.profileUnity = $true } }
    @{ Why = 'a low-confidence value nobody accepted'; Match = '/hostPools/0/hosts is low confidence'; Manifest = { param($m) $m.hostPools[0].hosts.confidence = 'low' } }
    @{ Why = 'a current-state snapshot older than 7 days at approval'; Match = 'current-state snapshot'; Approval = { param($a) $a.approvedUtc = '2026-12-09T16:00:00Z' } }
    @{ Why = 'a measured window older than 90 days at approval'; Match = 'measured window ended'; Manifest = { param($m) $m.evidence.forensicWindowEnd = '2026-08-01' } }
    @{ Why = 'a low-confidence measured window'; Match = "says 'low-confidence'"; Manifest = { param($m) $m.evidence.quality = 'low-confidence' } }
    @{ Why = 'a schedule in another time zone'; Match = "designed for 'Pacific Standard Time'"; Manifest = { param($m) $m.hostPools[0].scaling.timeZone = 'Pacific Standard Time' } }
    @{ Why = 'an unknown fact register version'; Match = 'fact register v2'; Manifest = { param($m) $m.pins.factRegister = 2 } }
  ) {
    $extra = @{}
    if ($Sha) { $extra.Sha = $Sha }
    $mb = if ($Manifest) { $Manifest } else { {} }
    if ($_.ContainsKey('Approval') -and $null -eq $Approval) {
      $m = Get-Content $script:exampleFile -Raw | ConvertFrom-Json
      $p = Get-AvdTargetStatePlan -Manifest $m -ManifestSha256 ('0' * 64) -Approval $null -Capabilities $script:cap -ParameterFileText $script:prodText -ParameterFile 'parameters/prod.bicepparam'
    }
    else {
      $ab = if ($Approval) { $Approval } else { {} }
      $p = Get-TestPlan -Manifest $mb -Approval $ab -Extra $extra
    }
    $p.Refusals -join "`n" | Should -Match ([regex]::Escape($Match))
    $p.Block | Should -BeNullOrEmpty
  }
  It 'deploys a low-confidence value the approval accepts' {
    $p = Get-TestPlan -Manifest { param($m) $m.hostPools[0].hosts.confidence = 'low' } -Approval { param($a) $a.acceptLowConfidence = @('/hostPools/0/hosts') }
    $p.Refusals | Should -BeNullOrEmpty
  }
  It 'asks for -HostPool when the manifest has two pools, and deploys the one named' {
    $two = { param($m) $second = $m.hostPools[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json; $second.id = 'tp-02'; $m.hostPools = @($m.hostPools[0], $second) }
    (Get-TestPlan -Manifest $two).Refusals -join ' ' | Should -Match 'Pick one with -HostPool'
    (Get-TestPlan -Manifest $two -Extra @{ HostPool = 'tp-02' }).Pool | Should -Be 'tp-02'
  }
  It 'reads the parameter file time zone the scheduled stop uses' {
    Get-AvdParameterFileTimeZone -Text "param autoShutdownTimeZone = 'Central Standard Time'" | Should -Be 'Central Standard Time'
    Get-AvdParameterFileTimeZone -Text "param scalingTimeZone = 'W. Europe Standard Time'" | Should -Be 'W. Europe Standard Time'
    Get-AvdParameterFileTimeZone -Text '' | Should -Be 'UTC'
  }
}

Describe 'ConvertFrom-AvdTargetState.ps1' {
  It 'prints the block and RESULT PASS for the approved example' {
    $out = & pwsh -NoProfile -File (Join-Path $script:root 'scripts/ops/ConvertFrom-AvdTargetState.ps1') -Path $script:exampleFile -ApprovalPath $script:approvalFile 2>&1
    $LASTEXITCODE | Should -Be 0
    ($out -join "`n") | Should -Match 'RESULT PASS tp-01: 8 x Standard_E8as_v5'
  }
  It 'refuses with exit code 1 when the approval is missing' {
    $out = & pwsh -NoProfile -File (Join-Path $script:root 'scripts/ops/ConvertFrom-AvdTargetState.ps1') -Path $script:exampleFile -ApprovalPath (Join-Path $TestDrive 'none.json') 2>&1
    $LASTEXITCODE | Should -Be 1
    ($out -join "`n") | Should -Match 'REFUSED  No approval file'
  }
}
