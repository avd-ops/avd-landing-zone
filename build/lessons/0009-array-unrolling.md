# 0009. PowerShell array unrolling in helpers and tests

- **Area:** PowerShell
- **Found in / fixed by:** PR #9 and earlier

## What happened
`@(Invoke-AvdGraph ...)` produced nested arrays; two new Pester tests matched nothing when piping `Get-AvdCheckResult` into `Where-Object`.

## Why
`return , $array` emits the array as one object: callers that pipe it filter the array as a whole.

## Fix
`Invoke-AvdGraph` emits items; tests assign `Get-AvdCheckResult` to a variable before piping.

## Guard
Pester `Invoke-AvdGraph` flat results.

## Rule
Emit items from functions; if a function must return one array object, assign it before piping.
