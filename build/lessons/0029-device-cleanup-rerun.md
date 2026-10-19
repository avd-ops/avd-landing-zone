# 0029. A cleanup step that fails after its inputs are deleted can't be retried

- **Area:** Cleanup
- **Found in / fixed by:** PR #46

## What happened
`Remove-AvdDemo.ps1` deleted the demo resource group and its deployment record, then asked for a Microsoft Graph device code to delete the host's device objects. The sign-in timed out:

```
[WARN ] Microsoft Graph sign-in
        Authentication timed out after 120 seconds due to inactivity. Please try again.
        -> Delete the devices manually in Entra ID and Intune.
```

Running the script again only reported `rg-avdlz-dev-demo  Not present.` and never tried the devices. The Entra ID and Intune objects for `avdlzddemo-001` had to be deleted by hand through Graph.

## Why
The script read the device names from the demo's VMs, deleted the resource group, deleted the deployment record, and only then signed in to Graph. Once the first run had deleted both, nothing in Azure still named the hosts, so a second run had no device names to clean up.

## Fix
- **Names after the VMs are gone:** when the demo VMs no longer exist, the script reads the names from the demo deployment record's `sessionHostNames` output.
- **Order of steps:** the device cleanup now runs before the record is deleted.
- **Record kept on failure:** if the Graph sign-in or a device deletion fails, the record stays (a warning says why), so running the script again finishes the job and then deletes the record.
- **Readable warnings:** the warnings name the devices and carry the id `devices-left`. For that id, the deployment portal says to run the cleanup again and to open the device login page first.

## Guard
- The PostDeployment scenario's `device-retry` case: a Graph sign-in that times out must keep the record and name the device; a rerun must delete the devices and the record. It fails against the old script (`kept=False named=False rerunDeleted=False`).
- The portal test *demo cleanup whose Graph sign-in timed out*.

## Rule
Delete a step's inputs only after the step that needs them has succeeded. If it fails, keep what a rerun needs and say so.
