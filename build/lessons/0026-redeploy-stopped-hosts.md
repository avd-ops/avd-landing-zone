# 0026. A redeploy needs the session hosts running; power management keeps them stopped

- **Area:** deploy.sh
- **Found in / fixed by:** #36 (redeploying dev to add the image build subnets, 2026-10-05)

## What happened
The first deployment of dev succeeded. A redeploy a few hours later failed in the session hosts deployment:

```
"target": ".../resourceGroups/rg-avdlz-dev-hosts/providers/Microsoft.Resources/deployments/avdlz-session-hosts"
{"code":"OperationNotAllowed","message":"Cannot modify extensions in the VM when the VM is not running."}
```

The rest of the deployment had gone through: the new subnets were there. Starting the host with `az vm start` and running the same command again succeeded.

## Why
Every deployment updates the hosts' run commands: `Register-AvdAgent` gets a new registration token each time, so its protected parameter always changes. Azure only lets a run command change on a running VM.

The landing zone is built to keep hosts stopped: the scaling plan deallocates idle hosts, the scheduled stop runs at 20:00, and Start VM on Connect starts them on demand. So a redeploy outside working hours, or of an idle pool, finds them deallocated. Earlier real runs were first deployments, or redeploys while a host happened to be running.

## Fix
`deploy.sh` checks the power state of the hosts in `rg-<prefix>-<env>-hosts` before deploying:
- **Deploy:** it starts any host that isn't running, saying so, and deallocates the same hosts after the deployment, whether it succeeded or failed (`--no-wait`). The power state and the cost stay as they were.
- **What-if:** it only reports them.
- **First deployment:** there is no hosts resource group yet, so it does nothing.

## Guard
The `Deploy` offline scenario runs the real `deploy.sh` against a fake `az` (`build/tests/offline/deploybin/az`) that logs each call. `build/tests/OfflineScenarios.Tests.ps1` asserts the order: power state, start, deployment, deallocate. It also covers a failed deployment, a what-if, all hosts running, and a first deployment. Removing the start, or the deallocation after a failure, fails the tests.

## Rule
Anything a deployment changes inside a VM (extensions, run commands) needs the VM running. With power management on, assume hosts are stopped and start them for the change; then put them back as they were.
