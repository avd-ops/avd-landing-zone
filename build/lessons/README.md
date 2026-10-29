# Lessons from real runs

Each lesson records something a real deployment or Cloud Shell run taught, why it happened, what fixed it, and **the guard that now catches it**. Read the relevant lesson before changing that area.

Add a lesson whenever a real run fails for a reason the tests didn't catch. The retro skill (`.claude/skills/retro/SKILL.md`) is the routine: lesson, guard (a test, scenario or check), then this index.

| # | Lesson | Area | PR | Guard |
|---|---|---|---|---|
| 0001 | [AVM NAT Gateway public IP defaults to zones 1-3](0001-nat-gateway-pip-zones.md) | Bicep | #12 | Template test: NAT IP zones |
| 0002 | [The break-glass password only matters at VM creation](0002-break-glass-password.md) | deploy.sh | #12 | Docs |
| 0003 | [Latency measured from Cloud Shell says nothing about users](0003-region-latency.md) | Region choice | #8 | — |
| 0004 | [`readEnvironmentVariable` returns an empty string, not the default, when the variable is set but empty](0004-empty-env-var.md) | Bicep parameters | #8 | Template test: region override |
| 0005 | [`Get-AzResourceProvider -ProviderNamespace` returns one object per region](0005-provider-per-region.md) | Preflight | #9 | Pester + PreDeployment scenario |
| 0006 | [Provider registration: blocking cmdlets and EncryptionAtHost](0006-provider-registration.md) | Preflight | #9 #10 #12 | Pester: provider registration |
| 0007 | [Microsoft Graph sign-in in Cloud Shell](0007-graph-sign-in.md) | Ops scripts | #6 #10 #11 | Pester: Graph token |
| 0008 | [A non-terminating error inside a loop can loop forever](0008-non-terminating-loops.md) | PowerShell | #11 | Pester: paging throws |
| 0009 | [PowerShell array unrolling in helpers and tests](0009-array-unrolling.md) | PowerShell | #9 and earlier | Pester: flat results |
| 0010 | [Private endpoints live in their target's resource group](0010-private-endpoint-rg.md) | Preflight | #13 | Pester + PostDeployment scenario |
| 0011 | [Azure Files REST with OAuth: x-ms-date and the share root](0011-azure-files-rest.md) | NTFS step | #13 #14 #15 #16 | DefaultShareRoot scenario + Pester |
| 0012 | [Surface the error before guessing a fix](0012-diagnose-first.md) | Process | #13-#16 | Retro skill |
| 0013 | [New subscriptions have no quota for most VM families](0013-vcpu-quota.md) | Preflight | n/a | Preflight quota check + scenario |
| 0014 | [Validate cmdlet parameter sets](0014-cmdlet-parameter-sets.md) | Ops scripts | #5 | — (manual) |
| 0015 | [Commands for Cloud Shell must stand alone](0015-cloud-shell-ergonomics.md) | Operator experience | #10-#16 | CLAUDE.md rule |
| 0016 | [CI's PSScriptAnalyzer is newer than yours](0016-analyzer-version.md) | CI | #14 | CI analyzer + session hook |
| 0017 | [Don't reset the shared branch over an unmerged PR](0017-shared-branch-reset.md) | Git | #12 #13 | CLAUDE.md rule |
| 0018 | [PSRule for Azure specifics](0018-psrule.md) | CI | #3 | CI PSRule gate |
| 0019 | [Bicep authoring traps](0019-bicep-authoring.md) | Bicep | #2 | CI Bicep lint |
| 0020 | [The offline harness must not depend on the machine's tools](0020-hermetic-harness.md) | Tests | portal PR | Hermetic scenarios in CI |
| 0021 | [ARM leaves out empty properties, and `@($null).Count` is 1](0021-arm-omits-empty-properties.md) | Preflight | after #19 | WellArchitected scenario (no-zones region) |
| 0022 | [A purge-protected vault is recovered, not waited out, and recovery needs its resource group](0022-key-vault-recovery.md) | Preflight | after #23 | PreDeployment scenario (vault-recover) |
| 0023 | [Deleting a resource group only soft-deletes its Log Analytics workspace](0023-log-analytics-soft-delete.md) | Cleanup | after #29 | PostDeployment scenario (remove-lz-workspace) + portal fixture |
| 0024 | [A deployed host's vCPUs are already in "used"; the quota check must not count them twice](0024-quota-counts-deployed-hosts.md) | Preflight | after #29 | PostDeployQuota scenario |
| 0025 | [The price list gains lookalike meters; match the product, not just the SKU](0025-retail-price-lookalike-meters.md) | Preflight | after #32 | PreDeployment scenario (lookalike meters; Private Link and NAT Gateway under Global) |
| 0026 | [A redeploy needs the session hosts running; power management keeps them stopped](0026-redeploy-stopped-hosts.md) | deploy.sh | #36 | Deploy scenario (fake az) |
| 0027 | [A repo-wide `*.json` ignore rule kept the image pipeline's data files out of git](0027-gitignore-json-data-files.md) | CI | #37 #39 | Template test: files the templates load are committed |
| 0028 | [Azure Files denies Entra Kerberos sessions when AES-256-GCM is the only channel encryption](0028-smb-channel-encryption-entra-kerberos.md) | Bicep | #45 | Template test: SMB channel encryption; readiness check |
| 0029 | [A cleanup step that fails after its inputs are deleted can't be retried](0029-device-cleanup-rerun.md) | Cleanup | #46 | Offline scenario: device-retry; portal test |
| 0030 | [Microsoft Graph's service principal doesn't list every delegated permission it issues](0030-graph-unlisted-delegated-scope.md) | Ops scripts | #47 | Offline scenario: GraphSignIn (setup, default-to-operator) |
| 0031 | [WDOT returns without an error when it skips work, so its return is never proof it ran](0031-wdot-returns-without-error.md) | Image pipeline | #98 | Pester: WDOT run verification |
| 0032 | [Every field of a pasted state line is input, not only its settings](0032-pasted-state-line-fields.md) | Deployment portal | #111 | Portal test: crafted paste (every field of every state fixture) |
| 0033 | [An unattended teardown must delete device objects with the app's own Graph token](0033-app-identity-graph-cleanup.md) | Ops scripts | #91 | Unit test: Test-AvdAppIdentity |
| 0034 | [A read of a resource in a missing resource group fails with ResourceGroupNotFound, not ResourceNotFound](0034-vm-show-missing-group.md) | deploy.sh | #117 | Offline scenario: Deploy (jumpbox-new, jumpbox-rg-only) |
| 0035 | [The run recorder prices the parameter file's default size unless sizing reaches the plan through -Sizing](0035-recorder-prices-deploy-size.md) | Run recorder | #114 | Offline scenario: RunRecorder `start-sized` |
| 0036 | [A teardown that waits for a second block, run by hand, isn't part of the batch](0036-teardown-needs-no-second-block.md) | Sandbox runs | decision 0021 | Offline scenario: SandboxDeadline; Pester: deadline teardown |
| 0037 | [A second Bicep module reference to the AVM virtual-machine module pushes the subscription template past ARM's 4 MB request limit](0037-subscription-template-4mb-limit.md) | Bicep | — | Template test: 4 MB limit and VM module count |
| 0038 | [When an operator deploys the storage account with Entra Kerberos, Entra sets that operator as the storage app's owner](0038-storage-kerberos-app-operator-owner.md) | Preflight | — | PostDeployment scenario (`storage-app-imposter`) + Pester (`Get-AvdStorageKerberosApp`) |
| 0039 | [A scheduled workflow that needs secrets nobody has set yet must skip, not fail and open issues](0039-scheduled-workflow-unconfigured-secrets.md) | CI | #51 | node --test build/tests/workflows (image build issue step) |

## Template

Copy [`TEMPLATE.md`](TEMPLATE.md), number it next, and add a row above.
