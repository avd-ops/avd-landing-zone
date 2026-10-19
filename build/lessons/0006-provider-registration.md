# 0006. Provider registration: blocking cmdlets and EncryptionAtHost

- **Area:** Preflight
- **Found in / fixed by:** PR #9 #10 #12

## What happened
`-Fix` hung silently for minutes after "Caller can create the policy guardrail assignments"; earlier it reported Ready while EncryptionAtHost was still registering.

## Why
`Register-AzResourceProvider` can block until registration completes (minutes for Microsoft.Compute) and prints nothing. `EncryptionAtHost` only takes effect after Microsoft.Compute is re-registered, and registering the feature takes about 15 minutes.

## Fix
Register with the ARM `register` API (returns at once), wait with visible progress up to 15 minutes, then re-register Compute. `deploy.sh` re-registers Compute on every run. The provider check prints a progress line first and reads all providers in one call.

## Guard
Pester `Test-AvdResourceProvider -Fix` and `Get-AvdProviderState`.

## Rule
Anything that can take more than a few seconds prints a line before it starts. "Fixed" means done, not started.
