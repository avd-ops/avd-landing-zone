# Cloud-native AVD Landing Zone

An **enterprise-ready Azure Virtual Desktop landing zone for greenfield, cloud-native organizations** — Entra ID-joined, Intune-managed, private by default, and deployed end to end from one Bicep template.

> [!WARNING]
> **Personal project. Not for production. No warranty.**
>
> - This is my own personal project, built on my own time. It is **not affiliated with, endorsed by or supported by my employer**, and it does not represent my employer's views, products or guidance. It is also not an official Microsoft product.
> - It is a reference and learning project. **Do not run it in production** or against subscriptions and tenants that matter. Use a dedicated lab subscription and tenant.
> - It is provided **"as is", without warranty of any kind**, under the [MIT License](LICENSE). You are responsible for what it deploys, for the Azure charges it incurs, and for reviewing the code before you run it.

It is deliberately *not* a general-purpose accelerator. Microsoft's [AVD Landing Zone Accelerator](https://github.com/Azure/avdaccelerator) (LZA) covers every identity model and brownfield scenario through a wide option surface. This repo makes the opposite trade: **one opinionated path — no domain controllers, no line of sight to on-premises, no post-deployment scripts** — and hardens that path fully. See [`docs/design-decisions.md`](docs/design-decisions.md) for the side-by-side.

## What you get

| Area | What's deployed | Why it matters |
|------|-----------------|----------------|
| **Identity** | Session hosts Entra ID-joined and Intune-enrolled; Entra SSO; VM User/Admin Login RBAC; break-glass local admin stored in Key Vault | No AD DS or Entra Domain Services to run; devices managed like every other endpoint |
| **Profiles** | Premium Azure Files (ZRS) with **Entra Kerberos**, shared-key access disabled, SMB 3.1.1 + AES-256, private endpoint, share RBAC, soft delete, **Azure Backup** | FSLogix without storage keys, domain joins or a management VM |
| **Session hosts** | Memory-optimized E-series on Premium SSD (sized per workload in the portal), Trusted Launch (Secure Boot + vTPM), encryption at host, zone-spread, Windows 11 24H2 multi-session + M365, AMA + AVD Insights, Guest Configuration | Secure by default; registered and FSLogix-configured **declaratively** by managed Run Commands |
| **Control plane** | Pooled host pool with **AVD Private Link** for session hosts, Start VM on Connect, scheduled agent updates, hardened RDP properties, weekday/weekend autoscale | Hosts reach AVD privately; idle cost is scaled away |
| **Network** | Spoke with **no default outbound access**: NAT Gateway (standalone) or hub firewall (hub-peered, peering created both ways); NSG on the private endpoint subnet; private DNS | Egress is always explicit, which suits the retirement of Azure's default outbound access |
| **Operations** | Log Analytics, AVD Insights DCR, diagnostics on every resource, alerts (unhealthy hosts, FSLogix errors, connection errors, Service Health), activity log export | Day-2 visibility from day 1 |
| **Governance** | Azure Policy guardrails (allowed locations, tag inheritance), Defender for Cloud (Servers P2, Storage, Key Vault), subscription budget | The subscription arrives governed |
| **Auto shutdown** | An Automation runbook stops the session hosts on a schedule and locks them off when the budget is exceeded (Resume undoes it) | Spend stops when the budget runs out, not at the end of the month |
| **Delivery** | Strict Bicep linting, PSScriptAnalyzer, shellcheck, PSRule for Azure, subscription what-if on PRs, environment-gated deploy workflow (OIDC) | Changes are reviewed as code and promoted with approvals |
| **Well-Architected** | PSRule's Well-Architected rules gate every template change; `-WellArchitected` reviews the **deployed** landing zone by pillar (design checks, Advisor, Defender for Cloud, Policy, PSRule on live resources) | Know where a deployment stands against a review, and what the dev settings trade away |

Everything is built from pinned [Azure Verified Modules](https://aka.ms/avm).

## Quick start

**Easiest path: the [deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/).** It picks the closest region by measuring latency from your browser, sizes the host pool from how many people use it (and the preflight prices that at Azure list prices for the region), gives you each command to paste into Cloud Shell, and reads the output you paste back to tell you what to run next, all the way to signing in. Pasted output never leaves your browser. If you get stuck, **Report a problem** turns the output into a GitHub issue, with private details removed in your browser first.

Prerequisites (details in [`docs/deploy.md`](docs/deploy.md)):
- A **dedicated subscription** where you are Owner, plus Azure CLI ≥ 2.65.
- Two Entra ID security groups: AVD users and AVD admins.
- Intune licensing in the tenant (or set `enrollInIntune = false`).
- vCPU quota for the session host size in your region.

```bash
az login && az account set --subscription "<subscription-id>"

# Preflight first (Cloud Shell, PowerShell): repeat until clean; -Fix registers providers,
# creates the groups and the AVD service principal
# (-Location <region> checks another region than the file's default, northcentralus)
pwsh ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/dev.bicepparam \
  -UsersGroup "AVD Users" -AdminsGroup "AVD Admins"

# What-if (-l is the region the landing zone is deployed to)
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus \
  --users-group "AVD Users" --admins-group "AVD Admins" --what-if

# Deploy (≈30-45 min the first time)
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus \
  --users-group "AVD Users" --admins-group "AVD Admins"
```

Then finish the three one-time tenant steps (admin consent for the storage account's Entra app, a Conditional Access exclusion, and NTFS hardening) from Azure Cloud Shell. The preflight checks them and `-Fix` applies them:

```powershell
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix
./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -TestUserUpn you@contoso.com   # optional demo + sign-in validation
```

See [`docs/operations.md`](docs/operations.md). Users in the AVD Users group can then sign in through the Windows App.

## Repo layout

```
avd-landing-zone/
├── bicep/
│   ├── main.bicep                 # subscription-scope orchestration
│   ├── demo/main.bicep            # demo host pool inside a deployed landing zone
│   └── modules/
│       ├── governance.bicep       # policy, Defender, budget, activity log
│       ├── monitoring.bicep       # Log Analytics, AVD Insights DCR, alerts
│       ├── network.bicep          # spoke, NSGs, NAT Gateway / hub routing, peering
│       ├── privateDns.bicep       # privatelink zones (standalone)
│       ├── keyVault.bicep         # break-glass credential
│       ├── storage.bicep          # Azure Files + Entra Kerberos for FSLogix
│       ├── backup.bicep           # Azure Backup for the profile share
│       ├── controlPlane.bicep     # host pool, app group, workspace, autoscale
│       └── sessionHosts.bicep     # VMs, run commands, host RBAC
├── bicepconfig.json               # linter: security rules are errors
├── parameters/
│   ├── dev.bicepparam             # tenant values read from environment variables
│   └── prod.bicepparam
├── scripts/
│   ├── deploy/deploy.sh           # providers, features, lookups, deploy
│   ├── ops/                       # Cloud Shell: preflight (-Fix), demo deploy + validation, cleanup
│   └── sessionhost/               # embedded into Run Commands at compile time
│       ├── Set-FSLogixConfiguration.ps1
│       └── Register-AvdAgent.ps1
├── tests/                         # Pester: unit tests, offline scenarios (tests/offline), template guards
├── ps-rule.yaml                   # PSRule for Azure configuration
├── docs/
└── .github/workflows/
    ├── validate.yml               # lint, analysis, PSRule, what-if
    └── deploy.yml                 # manual, environment-gated deployment
```

## Documentation

- [`docs/design-decisions.md`](docs/design-decisions.md): the opinions this repo takes and how it compares with the LZA
- [`docs/architecture.md`](docs/architecture.md): resource layout, traffic flows, identity and RBAC model
- [`docs/deploy.md`](docs/deploy.md): prerequisites, deployment, post-deployment steps, scaling out, teardown
- [`docs/operations.md`](docs/operations.md): preflight with fix mode, Well-Architected review, demo host pool with sign-in validation, cleanup
- [`docs/rebuild-spec.md`](docs/rebuild-spec.md): one prompt to rebuild this from an empty repo, with the protocol to count the prompts it takes
- [`docs/images.md`](docs/images.md): golden images, step 1: setting up and running the monthly image build
- [`docs/image-pipeline-spec.md`](docs/image-pipeline-spec.md): proposed spec for a golden image pipeline (Azure Image Builder → Compute Gallery) and blue/green host rotation
- [avd-second-brain](https://github.com/nickprignano/avd-second-brain): the second brain for the whole AVD lifecycle, shared with avd-current-state and avd-readiness-stratusphere. Its [operations spec](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md) is this landing zone's self-healing, self-learning brain (moved there; the runtime still deploys from here). What this repo exchanges with it: [`docs/second-brain.md`](docs/second-brain.md)
- [`docs/demo.md`](docs/demo.md): a live demo in a 30-minute slot (dev built the night before, test deployed live beside it)
- [Deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/) ([how it works](docs/portal/README.md)): region by latency, then the next command from each pasted Cloud Shell output
- [`docs/ci.md`](docs/ci.md): validation and deployment pipelines, OIDC setup
- [`docs/gotchas.md`](docs/gotchas.md): the things that bite
- [`docs/lessons`](docs/lessons/README.md): what real deployments taught, each with the guard that now catches it
- [`docs/decisions`](docs/decisions/README.md): the choices that shape the repo, and why
- [`docs/out-of-scope.md`](docs/out-of-scope.md): what this repo does not do
- [`docs/setup-azure-account.md`](docs/setup-azure-account.md): starting from zero on a personal card (lab use)
- [`CHANGELOG.md`](CHANGELOG.md): what changed, from each merged PR's `Changelog:` line

## Entry points

Each links its reference page, generated from the script's help or the template's `@description`s by the second brain's [Update-BrainDocs.ps1](https://github.com/nickprignano/avd-second-brain/blob/main/scripts/Update-BrainDocs.ps1). Edit the help, not the page.

<!-- generated:entry-points begin -->
<!-- Generated by scripts/Update-BrainDocs.ps1. Do not edit between the markers; edit the source and regenerate. -->
| Script | What it does |
|---|---|
| [`scripts/automation/Invoke-AvdPowerAction.ps1`](docs/reference/scripts-automation-Invoke-AvdPowerAction.md) | Stops, locks or resumes the landing zone's session hosts (auto shutdown, decision 0011). |
| [`scripts/image/custom/Invoke-CustomImageStep.ps1`](docs/reference/scripts-image-custom-Invoke-CustomImageStep.md) | Golden image: the adopter's own step, run after WDOT and before cleanup (docs/image-pipeline-spec.md section 5.3). |
| [`scripts/image/Disable-AutomaticUpdates.ps1`](docs/reference/scripts-image-Disable-AutomaticUpdates.md) | Golden image: Windows and Microsoft 365 Apps don't update themselves on hosts (docs/image-pipeline-spec.md section 5.6). |
| [`scripts/image/Disable-StorageSense.ps1`](docs/reference/scripts-image-Disable-StorageSense.md) | Golden image: turns Storage Sense off (docs/image-pipeline-spec.md section 5.3). |
| [`scripts/image/Enable-TimeZoneRedirection.ps1`](docs/reference/scripts-image-Enable-TimeZoneRedirection.md) | Golden image: sessions use the client's time zone (docs/image-pipeline-spec.md section 5.3). |
| [`scripts/image/Invoke-ImageCleanup.ps1`](docs/reference/scripts-image-Invoke-ImageCleanup.md) | Golden image: a smaller image, cleaned narrowly (docs/image-pipeline-spec.md section 5.3). |
| [`scripts/image/Invoke-Wdot.ps1`](docs/reference/scripts-image-Invoke-Wdot.md) | Golden image: runs the Windows Desktop Optimization Tool (WDOT) with the reviewed profile (docs/image-pipeline-spec.md section 5.5, scripts/image/wdot/README.md). |
| [`scripts/image/Set-SessionTimeLimit.ps1`](docs/reference/scripts-image-Set-SessionTimeLimit.md) | Golden image: disconnected sessions end after a set time (docs/image-pipeline-spec.md section 5.7). |
| [`scripts/image/Test-GoldenImage.ps1`](docs/reference/scripts-image-Test-GoldenImage.md) | Golden image: build-time validation (docs/image-pipeline-spec.md section 5.4). |
| [`scripts/image/Update-DefenderSignature.ps1`](docs/reference/scripts-image-Update-DefenderSignature.md) | Golden image: Defender starts with current signatures (docs/image-pipeline-spec.md section 5.3). |
| [`scripts/ops/Connect-AvdLandingZone.ps1`](docs/reference/scripts-ops-Connect-AvdLandingZone.md) | Signs in to Microsoft Graph once for the whole Cloud Shell session, so the preflight, -Fix, the demo and the cleanup don't each ask for a device code. |
| [`scripts/ops/ConvertFrom-AvdTargetState.ps1`](docs/reference/scripts-ops-ConvertFrom-AvdTargetState.md) | Turns an approved target-state manifest from the migration factory into the preflight and deploy.sh commands for one host pool. |
| [`scripts/ops/Deploy-AvdDemo.ps1`](docs/reference/scripts-ops-Deploy-AvdDemo.md) | Deploys a demo host pool and session host into an existing landing zone, then validates that a user can sign in. |
| [`scripts/ops/Initialize-AvdGraphApp.ps1`](docs/reference/scripts-ops-Initialize-AvdGraphApp.md) | One-time setup of the "avd-opsbot" app registration, so operators sign in to Microsoft Graph once per Cloud Shell session with no consent prompts (decision 0016). |
| [`scripts/ops/Remove-AvdDemo.ps1`](docs/reference/scripts-ops-Remove-AvdDemo.md) | Removes the demo host pool deployed by Deploy-AvdDemo.ps1, and optionally the whole landing zone. |
| [`scripts/ops/Start-AvdImageBuild.ps1`](docs/reference/scripts-ops-Start-AvdImageBuild.md) | Builds one golden image version with Azure Image Builder (docs/image-pipeline-spec.md section 5.2). |
| [`scripts/ops/Test-AvdLandingZoneReadiness.ps1`](docs/reference/scripts-ops-Test-AvdLandingZoneReadiness.md) | Preflight for the AVD landing zone, in two stages: -PreDeployment before deploying: is this subscription and tenant ready for the landing zone described by the parameter file? (default) after deploying: is the landing zone ready for session hosts and users, including the three post-deployment tenant steps? Check mode by default; -Fix remediates what it can. |
| [`scripts/ops/Test-AvdUserConnection.ps1`](docs/reference/scripts-ops-Test-AvdUserConnection.md) | Confirms from Azure telemetry that a user's sign-in reached the landing zone's desktop: the deployment portal's Verify access step (decision 0014, docs/verify-access-spec.md). |
<!-- generated:entry-points end -->

## License and disclaimer

[MIT](LICENSE). The software is provided "as is", without warranty of any kind, and the authors are not liable for any claim, damages or other liability arising from its use, including Azure charges and changes it makes to your subscription or tenant.

This is a personal project. It is not affiliated with, endorsed by or supported by my employer, and it is not an official Microsoft product. Azure, Microsoft Entra, Intune and FSLogix are trademarks of Microsoft. It is not intended for production use.
