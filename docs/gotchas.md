# Gotchas

## Before you deploy

### vCPU quota and zonal capacity
New subscriptions often have low quota. Check it with `az vm list-usage -l <region> -o table`. Quota is not capacity either: a size can be unavailable in a given zone. If allocation fails, try a sibling size (for example `Standard_D4s_v5`) or narrow `availabilityZones`.

### Premium ZRS file shares aren't in every region
If the storage deployment fails on SKU, set `profileStorageSku = 'Premium_LRS'`.

### Encryption at host is a subscription feature
`deploy.sh` registers `Microsoft.Compute/EncryptionAtHost` and waits for it. If you deploy another way, register it first or set `encryptionAtHost = false`.

### Intune enrollment needs Intune
With `enrollInIntune = true` and no Intune license in the tenant, the Entra join extension fails. Set it to `false` for lab tenants.

## During and after deployment

### FSLogix profiles don't attach
Check these in order:
1. **Admin consent** hasn't been granted to the storage account's Entra app ([deploy.md](deploy.md#grant-admin-consent-for-entra-kerberos)).
2. **Conditional Access** requires MFA for the storage app. Exclude it. With **Security Defaults** on there is nothing to exclude it from; replace it with Conditional Access ([setup-azure-account.md](setup-azure-account.md#security-defaults)).
3. The user isn't in AVD Users, so has no **SMB Share Contributor** role.
4. **DNS**: on a host, `Resolve-DnsName <storage>.file.core.windows.net` must return a `10.x` address. In hub mode with custom DNS, the hub must resolve `privatelink.file.core.windows.net` (pass central zones with `centralPrivateDnsZoneResourceIds`).
5. **Kerberos**: `klist get cifs/<storage>.file.core.windows.net` on the host should return a ticket. No ticket: check that `WinHttpAutoProxySvc` and `iphlpsvc` are running ([Microsoft lists both as required](https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable); a hardening baseline may have disabled them). The demo host check reports this.
6. **SMB channel encryption**: a ticket but still "Access is denied" (SESSION_SETUP returns `STATUS_ACCESS_DENIED`) happens when the share allows only AES-256-GCM. Allow AES-128-GCM too; the storage module does, and the readiness check fails without it ([lesson 0028](../build/lessons/0028-smb-channel-encryption-entra-kerberos.md)).

The `Microsoft-FSLogix-Apps/Operational` log is shipped to Log Analytics, and the *FSLogix profile errors* alert fires on errors.

### A session host shows "Unavailable" or never registers
- The `Register-AvdAgent` run command's output is on the VM → **Run command** blade.
- The hosts must reach the agent download links and the AVD service. In hub mode, allow the [required FQDNs](https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint) on the firewall.
- With AVD Private Link on, `privatelink.wvd.microsoft.com` must resolve from the hosts.

### Budget start date
A budget's start date must be the first of a month and can't be changed once the budget is active. Set `budgetStartDate` to the first day of the month of your first deployment and leave it there.

### Hub-peered mode needs an egress path
Subnets have no default outbound access. In `HubPeered` mode, set `hubFirewallPrivateIp` (or make sure hub routing, e.g. Virtual WAN routing intent, supplies 0.0.0.0/0). Otherwise hosts can't reach Entra ID, Intune or the agent downloads, and registration fails.

### The break-glass password is random and set at host creation
`deploy.sh` generates a random break-glass password unless `AVD_LOCAL_ADMIN_PASSWORD` is set. Azure applies it only when a session host is created, and existing hosts keep theirs, so a redeploy never changes a running host's password. The Key Vault secret `sessionhost-localadmin-password` holds the password of the hosts created by the latest deployment. For any host, **VM → Reset password** sets a new one without knowing the old.

### Default outbound access can't be changed later
`defaultOutboundAccess: false` is set at subnet creation. It's immutable, so if you import an existing subnet, it keeps whatever it had.

## Teardown

### The storage account won't delete
Azure Backup puts a delete lock on protected storage accounts. Stop protection and delete the backup data first.

### Key Vault name after teardown
The vault name is deterministic (prefix + environment + subscription + region hash) and purge protection keeps a deleted vault for 90 days. Redeploying the same name in that window fails. The pre-deployment preflight with `-Fix` recovers the vault into its resource group, creating the group again if needed. The deployment then reuses the vault and the prefix can stay. Otherwise change `namePrefix` ([lesson 0022](../build/lessons/0022-key-vault-recovery.md)).

### Orphaned devices
Deleting VMs doesn't remove their Entra ID and Intune device objects. Clean them up, or rebuilt hosts with the same names will be confusing to manage.

### Cloud Shell drops a long run
Cloud Shell ends a session after about 20 minutes without input, and its home folder is lost with an ephemeral session. A sandbox batch group writes its results before and after every step to the run store's `records` container, so a new session continues it: `Get-AvdSandboxBatchStatus.ps1` prints the block, with `-Resume` (finished steps are skipped, the interrupted one runs again) or `-TeardownOnly`. See [Sandbox runs](sandbox-runs.md#when-cloud-shell-drops).

