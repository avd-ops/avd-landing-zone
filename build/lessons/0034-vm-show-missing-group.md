# 0034. A read of a resource in a missing resource group fails with ResourceGroupNotFound, not ResourceNotFound

- **Area:** deploy.sh
- **Found in / fixed by:** the first real jumpbox run (sandbox batch, 2026-10-22) / PR #<this PR>

## What happened
The first real `deploy.sh --jumpbox` on a fresh subscription stopped before deploying anything:

```
Can't read the jumpbox VM:
ERROR: (ResourceGroupNotFound) Resource group 'rg-avdlz-dev-jumpbox' could not be found.
```

## Why
deploy.sh asks `az vm show` whether the jumpbox VM exists, so that an existing VM is never re-sent (decision 0019). It counted only `ResourceNotFound` as "no jumpbox" and stopped on any other error, so that a permissions or network error never reads as absent.

But on a first deployment the jumpbox's resource group doesn't exist either. Azure Resource Manager then answers `ResourceGroupNotFound`, and the error code never contains the string `ResourceNotFound`. The offline fake `az` answered `ResourceNotFound` in both cases, so it was more permissive than Azure (lesson 0020).

## Fix
deploy.sh counts both `ResourceNotFound` and `ResourceGroupNotFound` as "no jumpbox", the same pair the host pool read already accepts. Every other error still stops the run.

## Guard
The fake `az vm show` now answers the way Azure does:
- no group: `ResourceGroupNotFound`;
- a group without the VM: `ResourceNotFound`.

The offline deploy scenario covers both: `jumpbox-new` and `jumpbox-windows` cover the missing group, and `jumpbox-rg-only` covers the group without the VM. Before the fix, `jumpbox-new` and `jumpbox-windows` failed.

## Rule
When code reads one resource to learn whether it exists, treat both `ResourceNotFound` and `ResourceGroupNotFound` as absent. Make the offline fake return the code Azure returns for each missing level.
