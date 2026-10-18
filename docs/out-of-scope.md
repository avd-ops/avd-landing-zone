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

## Next layers to build

- **Image pipeline** (Azure Image Builder or Packer → Azure Compute Gallery) and host rotation on new image versions. Planned next, before the second brain: see [image-pipeline-spec.md](image-pipeline-spec.md) and [second-brain-spec.md](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md) Q6.
- **App delivery**: App Attach, Intune apps, or baked into the image. An optional Liquidware tier (ProfileUnity, FlexApp, CommandCTRL) is specced in [liquidware-spec.md](liquidware-spec.md).
- **Profile storage sizing**: provisioned size and IOPS for your user count; Azure NetApp Files for very large pools.
- **Disaster recovery**: a secondary region and cross-region profile replication. Backup here is in-region.
- **Customer-managed keys** for disks and storage, if your compliance regime requires them.
- **Sentinel / SIEM** connection for the Log Analytics workspace.
- **Additional Azure Policy** baselines (e.g. Microsoft cloud security benchmark enforcement).
