# 0033. The run recorder prices the parameter file's default size unless sizing reaches the plan through -Sizing

- **Area:** Run recorder
- **Found in / fixed by:** a sandbox batch run, where the recorder refused the run before anything was deployed; fixed by PR #114

## What happened
The batch had been approved at the estimate for one `Standard_D2as_v5` session host. The batch runner set `AVD_SESSION_HOST_VM_SIZE=Standard_D2as_v5` (the size `deploy.sh --vm-size` deploys) and called `Start-AvdRunRecorder.ps1`. The recorder priced the parameter file's default instead:

```
  Session hosts (1 x Standard_E4as_v5)                        2.26 USD
  [FAIL ] Expected cost is within half the cap, every line priced
          the expected 3.04 USD is over 3.02.
```

## Why
`Get-AvdDeploymentPlan` compiles the parameter file with every sizing variable (`AVD_SESSION_HOST_VM_SIZE` and the rest) set to the value in its `-Sizing` hashtable, or to empty, then restores them. Empty means "the value in the file" (the `empty()` guard, lesson 0004). `Start-AvdRunRecorder.ps1` passed no `-Sizing`, so the size the caller had set was blanked before `bicep build-params` read it. The deployment portal's record step sets the same four variables before it calls the recorder, so it priced the default size too.

## Fix
`Start-AvdRunRecorder.ps1` reads `AVD_SESSION_HOST_COUNT`, `AVD_SESSION_HOST_VM_SIZE`, `AVD_MAX_SESSION_LIMIT` and `AVD_PROFILE_QUOTA_GIB` and passes them to `Get-AvdDeploymentPlan -Sizing`.

## Guard
The RunRecorder offline scenario's `start-sized` step sets `AVD_SESSION_HOST_VM_SIZE=Standard_D2as_v5` and asserts that the priced line reads `Session hosts (1 x Standard_D2as_v5)`. Without the fix, it reads `Standard_E4as_v5`.

## Rule
A script that compiles a parameter file passes the sizing it was given through `Get-AvdDeploymentPlan -Sizing`. The environment alone never reaches the plan.
