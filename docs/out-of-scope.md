# Out of scope

What this landing zone deliberately doesn't do, and where to go instead.

## By design (use the AVD LZA or another pattern)

- **AD DS or Entra Domain Services-joined session hosts**, Group Policy, OU placement, storage-account domain join. This repo is Entra ID only. See [design-decisions.md](design-decisions.md).
- **Brownfield deployment** into existing resource groups, VNets or storage.
- **Personal (persistent) host pools** and RemoteApp application groups. The control-plane module is where you'd add them.

## Your platform's job

- **The hub**: firewall, gateways, DNS resolver, central private DNS zones. Hub-peered mode consumes them; it doesn't create them.
- **Management-group hierarchy and subscription vending.** This deploys into a subscription it's given.
- **Conditional Access policies** for AVD sign-in (recommended: require MFA and a compliant device for the Azure Virtual Desktop and Windows Cloud Login apps).
- **Intune configuration**: compliance policies, security baselines, Windows Update rings, app deployment. Hosts enroll, but the policies are yours.

## Another project's lane

These belong to a sibling project; refer the work there and read its knowledge base before researching it here. The list is kept in avd-second-brain's [family.yaml](https://github.com/avd-ops/avd-second-brain/blob/main/docs/knowledge/family.yaml) (`not_here`, its decision 0012).

- **Terraform, Packer, OpenTofu or any other HCL**: [nerdio-hcl](https://github.com/nickprignano/nerdio-hcl). This repo is Bicep and PowerShell only, and CI fails on an HCL file (`.github/workflows/lanes.yml`).
- **Nerdio Manager** and its scripted actions: [nerdio-hcl](https://github.com/nickprignano/nerdio-hcl). Nothing here depends on Nerdio.
- **Liquidware products**: the tier is built in [avd-liquidware](https://github.com/nickprignano/avd-liquidware), never in this repo.
- **General Claude API and model research**: outside this project and the AVD family; not researched here.

## Next layers to build

- **Image pipeline** (Azure Image Builder → Azure Compute Gallery; decision 0013) and host rotation on new image versions. Planned next, before the second brain: see [image-pipeline-spec.md](../build/specs/image-pipeline-spec.md) and [second-brain-spec.md](https://github.com/avd-ops/avd-second-brain/blob/main/docs/operations-spec.md) Q6.
- **App delivery**: App Attach, Intune apps, or baked into the image. An optional Liquidware tier (ProfileUnity, FlexApp through app attach, CommandCTRL) that runs against a landing zone from this repo lives in [avd-liquidware](https://github.com/nickprignano/avd-liquidware).
- **Profile storage sizing**: provisioned size and IOPS for your user count; Azure NetApp Files for very large pools.
- **Disaster recovery**: a secondary region and cross-region profile replication. Backup here is in-region.
- **Customer-managed keys** for disks and storage, if your compliance regime requires them.
- **Sentinel / SIEM** connection for the Log Analytics workspace.
- **Additional Azure Policy** baselines (e.g. Microsoft cloud security benchmark enforcement).
