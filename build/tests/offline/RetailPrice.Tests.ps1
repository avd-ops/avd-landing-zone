# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../../../scripts/ops/AvdLandingZone.psm1') -Force
}

Describe 'Get-AvdRetailPrice' {
  BeforeEach {
    & (Get-Module AvdLandingZone) { $script:RetailPriceCache = @{} }
  }

  It 'retries transient 429 Too many requests with exponential backoff and caches the page' {
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

    $items1 = @(Get-AvdRetailPrice -Filter "armSkuName eq 'Standard_D2as_v5'" -Invoker $invoker -Sleep $sleep)
    $items2 = @(Get-AvdRetailPrice -Filter "armSkuName eq 'Standard_D2as_v5'" -Invoker $invoker -Sleep $sleep)

    $items1.Count | Should -Be 1
    $items1[0].retailPrice | Should -Be 0.096
    $items2.Count | Should -Be 1
    $script:calls | Should -Be 3
    @($sleeps) | Should -Be @(2, 4)
  }

  It 'fails fast on non-transient errors without retrying' {
    $script:calls = 0
    $sleeps = [System.Collections.Generic.List[int]]::new()
    $invoker = {
      param($u)
      $script:calls++
      throw 'BadRequest: invalid OData filter'
    }

    { Get-AvdRetailPrice -Filter "invalid" -Invoker $invoker -Sleep { param($s) $sleeps.Add($s) } } | Should -Throw '*BadRequest*'
    $script:calls | Should -Be 1
    $sleeps.Count | Should -Be 0
  }
}
