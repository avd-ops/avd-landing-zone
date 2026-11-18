# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../../../scripts/ops/AvdLandingZone.psm1') -Force
}

Describe 'Get-AvdRetailPrice' {
  BeforeEach {
    & (Get-Module AvdLandingZone) { $script:RetailPriceCache = @{} }
    $script:TempCache = Join-Path $TestDrive 'retail-price-cache.json'
    $script:FallbackSnap = Join-Path $PSScriptRoot '../../../contracts/retail-prices.snapshot.json'
  }

  It 'retries transient 429 Too many requests with exponential backoff and caches in-session + on disk' {
    $script:calls = 0
    $sleeps = [System.Collections.Generic.List[int]]::new()
    $invoker = {
      param($u)
      $script:calls++
      if ($script:calls -lt 3) {
        throw 'Too many requests at this point. Please retry after some time.'
      }
      [pscustomobject]@{
        Items        = @([pscustomobject]@{ armSkuName = 'Standard_D2as_v5'; retailPrice = 0.096 })
        NextPageLink = $null
      }
    }
    $sleep = { param($s) $sleeps.Add($s) }

    $items1 = @(Get-AvdRetailPrice -Filter "armSkuName eq 'Standard_D2as_v5'" -DiskCachePath $script:TempCache -FallbackSnapshotPath '' -Invoker $invoker -Sleep $sleep)
    & (Get-Module AvdLandingZone) { $script:RetailPriceCache = @{} }
    $items2 = @(Get-AvdRetailPrice -Filter "armSkuName eq 'Standard_D2as_v5'" -DiskCachePath $script:TempCache -FallbackSnapshotPath '' -Invoker $invoker -Sleep $sleep)

    $items1.Count | Should -Be 1
    $items1[0].retailPrice | Should -Be 0.096
    $items2.Count | Should -Be 1
    $script:calls | Should -Be 3
    @($sleeps) | Should -Be @(2, 4)
    Test-Path -LiteralPath $script:TempCache | Should -BeTrue
  }

  It 'refreshes when the disk cache entry is older than 24 hours' {
    $ttlCache = Join-Path $TestDrive 'retail-price-cache-ttl.json'
    $now = [datetime]'2026-11-18T00:00:00Z'
    $counter = @{ n = 0 }
    $invoker = {
      param($u)
      $counter.n++
      [pscustomobject]@{
        Items        = @([pscustomobject]@{ armSkuName = 'Standard_D2as_v5'; retailPrice = 0.096 })
        NextPageLink = $null
      }
    }

    $null = @(Get-AvdRetailPrice -Filter "armSkuName eq 'Standard_D2as_v5'" -DiskCachePath $ttlCache -FallbackSnapshotPath '' -Now $now -Invoker $invoker)
    & (Get-Module AvdLandingZone) { $script:RetailPriceCache = @{} }
    $null = @(Get-AvdRetailPrice -Filter "armSkuName eq 'Standard_D2as_v5'" -DiskCachePath $ttlCache -FallbackSnapshotPath '' -Now ($now.AddHours(25)) -Invoker $invoker)

    $counter.n | Should -Be 2
  }

  It 'falls back to pinned snapshot when 429 persists after MaxRetries' {
    $script:calls = 0
    $sleeps = [System.Collections.Generic.List[int]]::new()
    $invoker = {
      param($u)
      $script:calls++
      throw 'Too many requests at this point. Please retry after some time.'
    }

    $items = @(Get-AvdRetailPrice -Filter "armRegionName eq 'centralus' and armSkuName eq 'Standard_D2as_v5'" -MaxRetries 2 -DiskCachePath $script:TempCache -FallbackSnapshotPath $script:FallbackSnap -Invoker $invoker -Sleep { param($s) $sleeps.Add($s) } -WarningAction SilentlyContinue)

    $script:calls | Should -Be 3
    @($sleeps) | Should -Be @(2, 4)
    $items.Count | Should -Be 1
    $items[0].retailPrice | Should -Be 0.096
  }

  It 'fails fast on non-transient errors without retrying' {
    $script:calls = 0
    $sleeps = [System.Collections.Generic.List[int]]::new()
    $invoker = {
      param($u)
      $script:calls++
      throw 'BadRequest: invalid OData filter'
    }

    { Get-AvdRetailPrice -Filter "invalid" -DiskCachePath $script:TempCache -FallbackSnapshotPath $script:FallbackSnap -Invoker $invoker -Sleep { param($s) $sleeps.Add($s) } } | Should -Throw '*BadRequest*'
    $script:calls | Should -Be 1
    $sleeps.Count | Should -Be 0
  }
}
