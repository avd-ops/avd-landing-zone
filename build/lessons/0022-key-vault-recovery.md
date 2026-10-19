# 0022. A purge-protected vault is recovered, not waited out, and recovery needs its resource group

- **Area:** Preflight
- **Found in / fixed by:** after #23 (first real teardown and same-prefix redeploy)

## What happened
After `Remove-AvdDemo.ps1 -IncludeLandingZone`, the Key Vault stayed soft-deleted under purge protection. The preflight failed `No soft-deleted Key Vault blocking the vault name` and suggested changing `namePrefix` or running `Undo-AzKeyVaultRemoval`. Recovering by hand took two tries. The first command block had a `<rg from ResourceId>` placeholder, and Cloud Shell rejected it:

```
New-AzResourceGroup: 'resourceGroupName' does not match expected pattern '^[-\w\._\(\)]+$'.
```

## Why
The vault name is deterministic (prefix, environment and a hash of subscription and region), so the same prefix wants the same vault. Purge protection means nobody can free the name for 90 days. Recovery puts the vault back into its **original** resource group, and the cleanup had deleted that group, so it has to be created again first. The operator had to find its name in the deleted vault's resource ID.

## Fix
`Test-AvdDeletedKeyVault` lists deleted vaults through ARM (`Microsoft.KeyVault/deletedVaults`, which carries the original `vaultId`). Under `-Fix` it:

1. creates the resource group again if it is missing;
2. recovers the vault (`PUT` with `createMode: recover`);
3. waits until the vault reports `Succeeded` before it reports Fixed.

The deployment then adopts the vault. The portal sends a soft-deleted vault to the `-Fix` rerun, and cleanup and the docs point there too.

## Guard
The PreDeployment scenario has two steps. `vault-recover` recreates the group, then recovers the vault and leaves the same prefix's vault in another region alone; `vault-recovered` then comes back ready. The mock refuses recovery into a missing resource group, as Azure does. Portal tests cover `state-predeploy-kv-fix.txt` and `state-predeploy-kv-recovered.txt`, and a failed recovery shows the script's detail instead of looping on `-Fix`.

## Rule
When a preflight failure has a safe, reversible remedy the script can apply, make it a `-Fix` action instead of advice. Never hand an operator a command with a placeholder to fill in (lesson 0015).
