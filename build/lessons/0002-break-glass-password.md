# 0002. The break-glass password only matters at VM creation

- **Area:** deploy.sh
- **Found in / fixed by:** PR #12

## What happened
`deploy.sh` prompted for a password that had to be reused on every deployment; the operator forgot it after the first (failed) run.

## Why
Azure applies `osProfile.adminPassword` only when a VM is created; existing hosts keep theirs, so a stable value was never needed.

## Fix
`deploy.sh` generates a random password unless `AVD_LOCAL_ADMIN_PASSWORD` is set; recovery is VM > Reset password.

## Guard
Docs (`deploy.md`, `gotchas.md`) and the parameter description.

## Rule
Never make a human remember a secret the platform can generate and reset.
