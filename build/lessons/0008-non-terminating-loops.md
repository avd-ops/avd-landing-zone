# 0008. A non-terminating error inside a loop can loop forever

- **Area:** PowerShell
- **Found in / fixed by:** PR #11

## What happened
The preflight printed the same two errors endlessly.

## Why
`Invoke-MgGraphRequest` returned nothing without a terminating error (module scope does not inherit the script's `ErrorActionPreference`), and the paging loop requested the same page again.

## Fix
`Invoke-AvdGraph` throws on any error record or empty response.

## Guard
Pester `Invoke-AvdGraph` (throws instead of looping).

## Rule
Every loop over remote calls must end on error: check `-ErrorVariable` and `$null` results, not only exceptions.
