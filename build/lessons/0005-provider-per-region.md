# 0005. `Get-AzResourceProvider -ProviderNamespace` returns one object per region

- **Area:** Preflight
- **Found in / fixed by:** PR #9

## What happened
"AVD host pools offered in northcentralus" warned *Could not read the regions* in a real run, although the region supports host pools.

## Why
The cmdlet splits a provider into one object per location, each with only that location's resource types; the check read the first object.

## Fix
Read `GET /subscriptions/{id}/providers/{namespace}` through `Invoke-AvdArm`: one object, every region per resource type.

## Guard
Pester `Test-AvdHostPoolRegion`; offline PreDeployment scenario asserts the check passes.

## Rule
Prefer the ARM REST shape over Az cmdlet output when the cmdlet reshapes data; check what the cmdlet actually returns before indexing into it.
