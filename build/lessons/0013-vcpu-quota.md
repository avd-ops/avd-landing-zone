# 0013. New subscriptions have no quota for most VM families

- **Area:** Preflight
- **Found in / fixed by:** PR n/a

## What happened
The first pre-deployment run in North Central US: standardDASv5Family quota 0 (regional quota 10).

## Why
Family quota starts at 0 on new subscriptions; the regional limit is separate.

## Fix
Requested through the Microsoft.Quota API (approved in minutes); the preflight checks family and regional quota.

## Guard
Preflight quota check; offline PreDeployment scenario (prod needs 16 vCPUs, the mock allows 10).

## Rule
Check family and regional quota per region before deploying; request small increases through `Microsoft.Quota` (not automated yet).
