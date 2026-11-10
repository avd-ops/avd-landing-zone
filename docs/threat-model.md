# Threat model: avd-landing-zone

> **Personal project, not for production, provided as is, and not affiliated with the author's employer, Liquidware or Microsoft.**

This document records the assets, trust boundaries, identities, and top threats for `avd-landing-zone` (tracked in [`avd-ops#49`](https://github.com/avd-ops/avd-ops/issues/49) and the family [security review map](https://avd-ops.dev/security.html)). Every mitigation points to the file or test in this repo that enforces it.

## 1. Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| **Session hosts & golden images** | `rg-avdlz-<env>-hosts`, Azure Compute Gallery (`bicep/images/`) | Multi-session or personal Windows 11 VMs where users sign in; compromise exposes active user sessions |
| **FSLogix profile share** | `rg-avdlz-<env>-storage` (`bicep/modules/storage.bicep`) | Holds roaming user profile VHDX containers over SMB 3.1.1 with Entra Kerberos |
| **Break-glass & encryption secrets** | `rg-avdlz-<env>-shared` Key Vault (`bicep/modules/keyVault.bicep`) | Holds the per-deployment random local administrator password (`build/decisions/0004-random-break-glass.md`) |
| **Entra groups, Conditional Access & Kerberos principal** | Entra ID tenant (`scripts/ops/AvdLandingZone.psm1`, `avd-entra`) | Controls who can launch desktops, administer hosts, and mount the profile share |
| **Run records, snapshots & recovery copies** | Operator's run store and Recovery Services vault (`bicep/modules/backup.bicep`) | Evidence of spend, validation, and point-in-time profile backups (`docs/recovery.md`) |
| **Operator browser session (Deployment Portal)** | `site/portal/` (static HTML/JS in the operator's browser) | Receives pasted Cloud Shell output that may contain tenant, subscription, or user identifiers before redaction |

## 2. Trust boundaries

1. **Public internet vs. private VNet data plane:** Users connect through the Azure Virtual Desktop public reverse-connect gateway (`windows.cloud.microsoft`), while session hosts, Azure Files, Key Vault, and Recovery Services communicate over private endpoints inside `bicep/modules/network.bicep`. Session hosts have no public IP and outbound RDP/SSH to the VNet is denied by NSG.
2. **Operator workstation / Cloud Shell vs. Azure & Microsoft Graph:** Operator scripts (`scripts/deploy/deploy.sh`, `scripts/ops/*.ps1`) run in the signed-in operator's Azure Cloud Shell or local PowerShell session using delegated tokens (`build/decisions/0016-graph-operator-app.md`).
3. **Browser portal vs. public GitHub issues:** The static deployment portal (`site/portal/`) processes pasted output locally in the browser under a strict Content Security Policy (`default-src 'self'`) and runs client-side redaction (`site/portal/report.js`) before generating an issue link.
4. **GitHub Actions CI/CD vs. Azure subscription:** CI workflows (`.github/workflows/deploy.yml`, `.github/workflows/image-build.yml`) authenticate via OpenID Connect federated credentials scoped to a specific GitHub Environment (`dev`, `prod`, `images`).

## 3. Identities and scopes

| Identity | Type | Scope & permissions | Evidence |
|---|---|---|---|
| **Deploying operator / CI OIDC** | User or workload identity federated per environment | `Owner` on the dedicated landing zone subscription (creates role and policy assignments); federated subject locked to `environment:<env>` | [`docs/deploy.md`](deploy.md), [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml), [`build/tests/Template.Tests.ps1`](../build/tests/Template.Tests.ps1) |
| **Graph operator app** | Public client app (delegated, assignment required, no secret) | Delegated Graph scopes for AVD group, Conditional Access, Intune, and Kerberos app setup | [`build/decisions/0016-graph-operator-app.md`](../build/decisions/0016-graph-operator-app.md), [`scripts/ops/AvdLandingZone.psm1`](../scripts/ops/AvdLandingZone.psm1) |
| **AVD first-party service principal** | Microsoft-managed service principal | `Desktop Virtualization Power On Off Contributor` on the hosts resource group only (start VM on connect) | [`bicep/modules/sessionHosts.bicep`](../bicep/modules/sessionHosts.bicep), [`build/tests/Template.Tests.ps1`](../build/tests/Template.Tests.ps1) |
| **Auto-shutdown & budget runbook** | System-assigned Automation Account managed identity | Custom/narrow built-in roles on the hosts resource group to deallocate idle session hosts and apply the budget lock tag | [`bicep/modules/governance.bicep`](../bicep/modules/governance.bicep), [`build/decisions/0011-auto-shutdown.md`](../build/decisions/0011-auto-shutdown.md) |
| **Session host system identity** | System-assigned VM managed identity | Zero RBAC roles assigned by default; used for AMA/monitoring and Entra join | [`bicep/modules/sessionHosts.bicep`](../bicep/modules/sessionHosts.bicep) |
| **Admin jumpbox** | Opt-in VM via Bastion Developer | Zero public IP, NSG denies internet and lateral RDP/SSH, managed identity with zero roles, one-time password per connection | [`build/decisions/0019-jumpbox-bastion-developer.md`](../build/decisions/0019-jumpbox-bastion-developer.md), [`build/tests/Template.Tests.ps1`](../build/tests/Template.Tests.ps1) |

## 4. Top threats and mitigations

| Threat | Impact | Mitigation | Evidence |
|---|---|---|---|
| **T1. Over-privileged or standing deployment credentials** | Unauthorized subscription or tenant changes if a stored secret leaks | No stored Azure client secrets; GitHub Actions use OIDC federated credentials per environment (`dev`, `prod`, `images`). Graph uses a public client app with delegated permissions and `appRoleAssignmentRequired` | [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml), [`build/decisions/0016-graph-operator-app.md`](../build/decisions/0016-graph-operator-app.md), [`build/tests/Template.Tests.ps1`](../build/tests/Template.Tests.ps1) |
| **T2. Public exposure of profile storage or Key Vault** | Direct internet access to user profile VHDXs or local admin secrets | Public network access is disabled on the profile Storage Account, Key Vault, and Recovery Services vault; traffic uses private endpoints. Shared key access on storage is disabled unless required by the vaulted backup tier | [`bicep/modules/storage.bicep`](../bicep/modules/storage.bicep), [`bicep/modules/keyVault.bicep`](../bicep/modules/keyVault.bicep), [`bicep/modules/backup.bicep`](../bicep/modules/backup.bicep) |
| **T3. Lateral movement from a compromised session host** | Attacker pivots over RDP/SSH to other session hosts or management VMs | Session host subnet NSG denies inbound from the internet and denies outbound TCP 3389/22 to `VirtualNetwork`; Trusted Launch (Secure Boot + vTPM) and encryption at host are enabled by default | [`bicep/modules/network.bicep`](../bicep/modules/network.bicep), [`bicep/modules/sessionHosts.bicep`](../bicep/modules/sessionHosts.bicep), [`build/tests/Template.Tests.ps1`](../build/tests/Template.Tests.ps1) |
| **T4. Unintended deletion of the last copy of profiles or evidence** | Irreversible loss of user profiles, backups, or run evidence during teardown | Teardown scripts (`Remove-AvdDemo.ps1`, `Invoke-AvdControlPlanes.ps1 -Teardown`, `Invoke-AvdSandboxBatch.ps1`) refuse to delete the last copy without explicit `-DiscardLastCopy`, which `-Force` never implies | [`scripts/ops/Remove-AvdDemo.ps1`](../scripts/ops/Remove-AvdDemo.ps1), [`build/tests/OfflineScenarios.Tests.ps1`](../build/tests/OfflineScenarios.Tests.ps1) |
| **T5. Command injection or data leak via the deployment portal** | Malicious state line injects shell/PowerShell commands, or an issue report leaks tenant IDs/names | Portal validates every parsed field against strict regexes before interpolating into commands (`portal-core.js`), enforces CSP with no third-party origins, and redacts GUIDs, emails, subscription names, and secrets (`report.js`) | [`site/portal/portal-core.js`](../site/portal/portal-core.js), [`site/portal/report.js`](../site/portal/report.js), [`build/tests/portal/portal-core.test.mjs`](../build/tests/portal/portal-core.test.mjs), [`build/tests/portal/report.test.mjs`](../build/tests/portal/report.test.mjs) |
| **T6. Supply-chain drift in templates, scripts, or CI actions** | Unreviewed upstream change alters deployed resources or CI behavior | AVM modules, Bicep, PSRule, PSScriptAnalyzer, Pester, and GitHub Actions are pinned by version/commit SHA; image build inlines all scripts and WDOT profiles at compile time with no runtime `raw.githubusercontent.com` fetches | [`.github/workflows/validate.yml`](../.github/workflows/validate.yml), [`.github/workflows/secret-scan.yml`](../.github/workflows/secret-scan.yml), [`build/tests/Template.Tests.ps1`](../build/tests/Template.Tests.ps1) |
