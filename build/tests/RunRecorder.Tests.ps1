#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for the run recorder's rules (scripts/ops/AvdRunRecorder.psm1; build/specs/run-recorder-spec.md).
# The files they build are checked against avd-second-brain contract C17, vendored in contracts/.
# Run: Invoke-Pester ./build/tests

BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../../scripts/ops/AvdRunRecorder.psm1') -Force
  $script:schemas = Join-Path $PSScriptRoot '../../contracts/schemas'
  $script:runId = 'run-20261020-1652-k3p9'
  # The shape Get-AvdCostEstimate returns (monthly lines, unpriced lines with the meters seen).
  $script:estimate = [ordered]@{
    currency = 'USD'
    lines    = @(
      [ordered]@{ key = 'compute'; item = 'Session hosts (1 x Standard_E4as_v5)'; quantity = 216.7; unit = 'host-hours'; unitPrice = 0.25; unitOfMeasure = '1 Hour'; monthly = 54.17; meter = 'Virtual Machines Easv5 Series / E4as v5' }
      [ordered]@{ key = 'osdisk'; item = 'OS disks (1 x Premium SSD P10)'; quantity = 1; unit = 'disks'; unitPrice = 19.71; unitOfMeasure = '1/Month'; monthly = 19.71; meter = 'Premium SSD Managed Disks / P10 LRS Disk' }
      [ordered]@{ key = 'profiles'; item = 'Profile share (Premium_LRS, 100 GiB provisioned)'; quantity = 100; unit = 'GiB'; unitPrice = 0.16; unitOfMeasure = '1 GiB/Month'; monthly = 16; meter = 'Premium Files / LRS Provisioned' }
    )
    unpriced = @()
  }
  function Copy-Estimate { $script:estimate | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable }
}

Describe 'Run IDs and the run store name' {
  It 'builds the run ID shape the journal accepts' {
    Get-AvdRunId -Now ([datetime]'2026-10-20T16:52:00Z') -Suffix 'k3p9' | Should -Be $script:runId
    Get-AvdRunId | Should -Match '^run-\d{8}-\d{4}-[a-z0-9]{4}$'
  }
  It 'refuses a suffix that would break the shape' { { Get-AvdRunId -Suffix 'K3P9' } | Should -Throw }
  It 'names the store the same way every time, within 24 characters' {
    $sub = '00000000-aaaa-bbbb-cccc-000000000001'
    $a = Get-AvdRunStoreName -SubscriptionId $sub
    $a | Should -Be (Get-AvdRunStoreName -SubscriptionId $sub.ToUpperInvariant())
    $a | Should -Match '^avdlzruns[0-9a-f]{12}$'
    $a.Length | Should -BeLessOrEqual 24
  }
}

Describe 'run.json' {
  It 'matches contract C17 when a run starts' {
    $r = Get-AvdRunRecord -RunId $script:runId -Commit 'fc374c4' -Entry 'Start-AvdRunRecorder.ps1' -Region 'northcentralus' -Started ([datetime]'2026-10-20T16:52:00Z') -Extension @{ sessionHostCount = 2 }
    $r.level | Should -Be 'private'
    $r.teardown.logs | Should -Be 'Keep'
    $r.extensions['landing-zone'].sessionHostCount | Should -Be 2
    Test-Json -Json ($r | ConvertTo-Json -Depth 8) -SchemaFile (Join-Path $script:schemas 'run-record.schema.json') | Should -BeTrue
  }
}

Describe 'Expected cost (cost.json)' {
  It 'prices the hosts for the run hours and prorates the monthly lines' {
    $c = Get-AvdRunCostExpected -Estimate (Copy-Estimate) -Hours 3 -HostCount 2 -RunId $script:runId -PricedAt ([datetime]'2026-10-20T16:50:00Z')
    $compute = $c.expected.lines | Where-Object { $_.meter -like '*E4as v5' }
    $compute.quantity | Should -Be 6
    $compute.cost | Should -Be 1.5
    ($c.expected.lines | Where-Object { $_.meter -like '*P10 LRS Disk' }).quantity | Should -Be ([math]::Round(2 * 3 / 730, 4))
    $c.expected.total | Should -Be 1.73
    $c.gate.limit | Should -Be 5
    $c.gate.passed | Should -BeTrue
    Test-Json -Json ($c | ConvertTo-Json -Depth 8) -SchemaFile (Join-Path $script:schemas 'run-cost.schema.json') | Should -BeTrue
  }
  It 'fails the gate above half the cap' {
    (Get-AvdRunCostExpected -Estimate (Copy-Estimate) -Hours 24 -HostCount 2 -RunId $script:runId -Cap 10).gate.passed | Should -BeFalse
  }
  It 'keeps a line it could not price as unpriced, never guessed, and fails the gate' {
    $e = Copy-Estimate
    $e.unpriced = @(@{ key = 'publicip'; item = 'NAT Gateway public IP'; seen = @('IP Addresses: Standard / Standard IPv4 Public Address (1 Hour)') })
    $c = Get-AvdRunCostExpected -Estimate $e -Hours 3 -HostCount 2 -RunId $script:runId
    $u = $c.expected.lines | Where-Object { $_.item -eq 'NAT Gateway public IP' }
    $u.match | Should -Be 'none'
    $u.cost | Should -BeNullOrEmpty
    $c.expected.unpriced | Should -Be 1
    $c.gate.passed | Should -BeFalse
    Test-Json -Json ($c | ConvertTo-Json -Depth 8) -SchemaFile (Join-Path $script:schemas 'run-cost.schema.json') | Should -BeTrue
  }
}

Describe 'Actual cost readings' {
  BeforeEach { $script:c = Get-AvdRunCostExpected -Estimate (Copy-Estimate) -Hours 3 -HostCount 2 -RunId $script:runId }

  It 'appends readings and settles only after 72 hours without change' {
    $t = [datetime]'2026-10-21T08:00:00Z'
    $byMeter = @(@{ meter = 'E4as v5'; cost = 1.52 }, @{ meter = 'P10 LRS Disk'; cost = 0.17 })
    $c = Add-AvdRunCostReading -Cost $script:c -ReadAt $t -Total 1.69 -ByMeter $byMeter
    $c = Add-AvdRunCostReading -Cost $c -ReadAt $t.AddHours(24) -Total 1.81 -ByMeter $byMeter
    $c = Add-AvdRunCostReading -Cost $c -ReadAt $t.AddHours(48) -Total 1.81 -ByMeter $byMeter
    $c.actuals[-1].settled | Should -BeFalse
    $c = Add-AvdRunCostReading -Cost $c -ReadAt $t.AddHours(96) -Total 1.81 -ByMeter $byMeter
    @($c.actuals).Count | Should -Be 4
    $c.actuals[0].total | Should -Be 1.69
    $c.actuals[-1].settled | Should -BeTrue
    $c.comparison.difference | Should -Be 0.08
    $c.comparison.unexpectedMeters.Count | Should -Be 0
    Test-Json -Json ($c | ConvertTo-Json -Depth 8) -SchemaFile (Join-Path $script:schemas 'run-cost.schema.json') | Should -BeTrue
  }
  It 'names a meter the estimate did not know about' {
    $c = Add-AvdRunCostReading -Cost $script:c -ReadAt ([datetime]'2026-10-21T08:00:00Z') -Total 2.1 -ByMeter @(@{ meter = 'E4as v5'; cost = 1.5 }, @{ meter = 'Standard Static IP'; cost = 0.6 })
    $c.comparison.unexpectedMeters | Should -Be @('Standard Static IP')
  }
  It 'records why there is no figure instead of failing' {
    $c = Add-AvdRunCostReading -Cost $script:c -ReadAt ([datetime]'2026-10-21T08:00:00Z') -Unavailable 'no access'
    $c.actuals[0].total | Should -BeNullOrEmpty
    $c.actuals[0].unavailable | Should -Be 'no access'
    $c.actuals[0].settled | Should -BeFalse
  }
  It 'works on a cost.json read back from disk' {
    $disk = $script:c | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $c = Add-AvdRunCostReading -Cost $disk -ReadAt ([datetime]'2026-10-21T08:00:00Z') -Total 1.7
    $c.comparison.difference | Should -Be -0.03
  }
}

Describe 'Free copies and the last copy (spec section 9.2, R9)' {
  BeforeAll {
    $h = { param($c) -join (1..64 | ForEach-Object { $c }) }
    $script:files = @(
      [pscustomobject]@{ path = 'journal.jsonl'; bytes = 48213; sha256 = (& $h 'a'); copies = @([pscustomobject]@{ target = 'github'; sha256 = (& $h 'a') }) }
      [pscustomobject]@{ path = 'logs/WVDConnections.json'; bytes = 900MB; gzBytes = 120MB; sha256 = (& $h 'b'); gzSha256 = (& $h 'c'); copies = @([pscustomobject]@{ target = 'github-release'; sha256 = (& $h 'c') }) }
      [pscustomobject]@{ path = 'logs/huge.json'; bytes = 9GB; gzBytes = 3GB; sha256 = (& $h 'd') }
      [pscustomobject]@{ path = 'cost.json'; bytes = 2210; sha256 = (& $h 'e'); copies = @([pscustomobject]@{ target = 'github'; sha256 = (& $h 'f') }) }
    )
  }
  It 'commits small files, releases large ones, and keeps 2 GiB or more in Azure' {
    $r = Get-AvdRunFileRoute -File $script:files
    ($r | Where-Object Path -eq 'journal.jsonl').Route | Should -Be 'github'
    ($r | Where-Object Path -eq 'logs/WVDConnections.json').Route | Should -Be 'github-release'
    ($r | Where-Object Path -eq 'logs/huge.json').Route | Should -Be 'kept-in-azure'
  }
  It 'verifies a copy only when the hash read back matches' {
    $r = Test-AvdCopyReceipt -File $script:files -ReadBack @{ 'journal.jsonl' = $script:files[0].sha256; 'cost.json' = 'f' * 64 }
    ($r | Where-Object Path -eq 'journal.jsonl').Verified | Should -BeTrue
    ($r | Where-Object Path -eq 'cost.json').Reason | Should -Be 'hash mismatch'
    ($r | Where-Object Path -eq 'logs/huge.json').Reason | Should -Be 'not read back'
  }
  It 'Keep deletes nothing' {
    $p = Get-AvdTeardownLogPlan -File $script:files -Preference Keep
    $p.Delete.Count | Should -Be 0
    $p.NeedsTypedRunId.Count | Should -Be 0
    $p.Keep.Count | Should -Be 4
  }
  It 'Delete deletes only verified copies; the last copies need the typed run ID' {
    $p = Get-AvdTeardownLogPlan -File $script:files -Preference Delete
    $p.Delete | Should -Be @('journal.jsonl', 'logs/WVDConnections.json')
    $p.NeedsTypedRunId | Should -Be @('logs/huge.json', 'cost.json')
    $p.NeedsYes | Should -BeFalse
  }
  It 'Ask asks before anything is deleted' { (Get-AvdTeardownLogPlan -File $script:files -Preference Ask).NeedsYes | Should -BeTrue }
}

Describe 'The private companion repo name' {
  It 'accepts owner/repo and refuses anything else' {
    Test-AvdPrivateRepoName 'contoso/run-records' | Should -BeTrue
    Test-AvdPrivateRepoName 'run-records' | Should -BeFalse
    Test-AvdPrivateRepoName 'https://github.com/contoso/run-records' | Should -BeFalse
    Test-AvdPrivateRepoName '' | Should -BeFalse
  }
}
