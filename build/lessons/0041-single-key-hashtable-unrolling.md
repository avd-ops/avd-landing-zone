# 0041. Single-key hashtable unrolling and `[OrderedDictionary]` key wrapping in PowerShell

- **Area:** PowerShell
- **Found in / fixed by:** PR #132

## What happened
While testing `Get-AvdConfigurationSnapshot` and `Compare-AvdConfigurationSnapshot` in `scripts/ops/AvdRecovery.psm1`, a single-key dictionary (`@{ maxSessionLimit = 8 }`) serialized with a trailing `null` key (`{"":null,"maxSessionLimit":null}`), and `Compare-AvdConfigurationSnapshot` reported existing keys on `[ordered]@{ ... }` dictionaries as `added` and `removed`.

## Why
Two PowerShell pipeline behaviors interacted:
1. `@($InputObject.Keys | ForEach-Object { , @($_, $InputObject[$_]) })` unrolls the single emitted 2-element array into two scalar elements when `$InputObject.Keys` has only one item, even with the unary comma operator inside `ForEach-Object` wrapped by `@(...)`.
2. Piping `$a.Keys + $b.Keys | Select-Object -Unique` when `$a` or `$b` is an `[System.Collections.Specialized.OrderedDictionary]` emits keys wrapped in `PSObject`. Indexing `$a[$k]` with a `PSObject`-wrapped key on `OrderedDictionary` treats it as an integer or unmatched object key instead of a string key.

## Fix
Iterate and sort string-coerced keys directly (`@($InputObject.Keys | ForEach-Object { "$_" } | Sort-Object -Culture '' -CaseSensitive)`) and index dictionaries with `"$k"` in both `ConvertTo-CanonicalJson` and `Compare-Node`.

## Guard
`build/tests/Recovery.Tests.ps1` (`Get-AvdConfigurationSnapshot and Compare-AvdConfigurationSnapshot`) and `build/tests/offline/Recovery.Scenario.ps1` (`T-config` snapshot and drift detection).

## Rule
Never emit `, @($key, $val)` pairs through `ForEach-Object` inside `@(...)` when a dictionary can have a single key; sort stringified keys (`"$_"`) and index dictionaries with `"$k"`.
