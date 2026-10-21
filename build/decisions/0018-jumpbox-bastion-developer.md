# 0018. An opt-in operator jumpbox, reached through Azure Bastion Developer

- **Status:** Proposed (accepted once a sandbox run confirms the connection; see "To confirm" below)

## Context
Every operator script runs from Azure Cloud Shell. That has three costs:
- a Cloud Shell session is ephemeral: it times out and disconnects mid-run (lesson 0015), and on a tablet the browser tab is the session;
- Cloud Shell is outside the landing zone's network, so it can't reach the private endpoints: the break-glass secret in the private Key Vault (red team LZ-15) and the SMB-only profile share (`docs/operations.md`, the NTFS step runs on a session host for that reason);
- long runs (a deployment, a recovery test) tie up the operator's device.

The family worked from a premise that Bastion was out: a costly, always-on service. It was never a decision of this repo (the landing zone has never deployed Bastion), but it is written down in avd-liquidware: its red team finding N-M1 says "No Bastion in the landing zone, no admin network (decision 0001)", and its deploy spec section 9 turns Bastion off by default against a landing zone because "Bastion Basic bills by the hour". On 2026-10-21 Nick said that premise was false for the Developer SKU and asked for a jumpbox reached through it.

What Microsoft Learn says about Bastion Developer (read 2026-10-21: [SKU comparison](https://learn.microsoft.com/azure/bastion/bastion-sku-comparison), [configuration settings](https://learn.microsoft.com/azure/bastion/configuration-settings), [Developer quickstart](https://learn.microsoft.com/azure/bastion/quickstart-developer), [Entra ID authentication](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication), [FAQ](https://learn.microsoft.com/azure/bastion/bastion-faq)):
- **No charge**: no hourly charge and no outbound data charge. Not a dedicated host: a shared pool, deployed in seconds.
- **No AzureBastionSubnet and no public IP.** The resource references the VNet (`properties.virtualNetwork`).
- **One VM connection at a time**, and **only VMs in the same VNet**: no peering, so it can't reach a hub or another spoke.
- **Portal connections only**: no native client (`az network bastion`), custom ports, IP connect, shareable links, file transfer or session recording.
- **No Microsoft Entra ID sign-in.** Entra sign-in in the portal needs Basic or higher (Standard for the native client). Developer offers username and password, or an SSH private key.
- **Only in some regions.** The list includes North Central US (the parameter files' default), Central US and East US 2, but not East US, South Central US (the recovery region in the DR plan) or West US 2/3.
- Not suitable for production workloads, in Microsoft's words. Basic and higher bill by the hour.

## Decision
- **Opt-in and off by default.** `deployJumpbox` (`deploy.sh --jumpbox`, `AVD_DEPLOY_JUMPBOX`) adds it; without it the compiled template deploys exactly what it did before. Once the jumpbox exists, `deploy.sh` keeps it (a deployment without it would try to delete its subnet). The landing zone stays self-contained: nothing here needs the brain, the swarm or another repo.
- **Where it lives.** A `/28` subnet `snet-jumpbox` in the spoke (`10.100.2.32/28`), because Bastion Developer only reaches its own VNet. The jumpbox VM in its own resource group `rg-<prefix>-<env>-jumpbox` (one resource group per lifecycle); the Bastion `bas-<prefix>-<env>` in the network resource group beside the VNet. Same egress as the hosts (NAT Gateway, or the hub firewall route).
- **No public IP anywhere, no new inbound rule.** The subnet's NSG denies the internet inbound and RDP and SSH outbound to the VNet (no lateral movement, like the hosts). Bastion Developer comes in over the VNet's default rule.
- **Linux, the smallest size that runs the toolchain.** Ubuntu 24.04 LTS, Trusted Launch, encryption at host as the hosts, Standard SSD, `Standard_B2als_v2` (2 vCPUs, 4 GiB; 1 GiB sizes can't load the Az modules comfortably). First boot (`scripts/jumpbox/cloud-init.yaml`, compiled into the template) installs what Cloud Shell has: pwsh, the Azure CLI, the Bicep version CI pins, git and the Az and Graph modules the scripts use. It holds no credential and checks nothing out. Linux runs the same scripts as Cloud Shell (pwsh 7 on Linux); a Windows variant is a later option.
- **Identity.** Because Bastion Developer has no Entra sign-in, the OS account (`avdoperator`) is local. Its password is random per deployment, applied only at creation and stored nowhere. `scripts/ops/Connect-AvdJumpbox.ps1` starts the VM if needed and sets a new one-time password through the VM access extension (management plane, protected settings), prints it once, and links to Connect > Bastion: nobody remembers or stores a password, and the last one is worthless after the next connect. On the box, the operator signs in to Azure and Graph as themselves with a device code. The VM's managed identity has no roles. The AVD Admins group gets Reader and Virtual Machine Contributor on the jumpbox resource group and Reader on the Bastion, what a connection and `Connect-AvdJumpbox.ps1` need.
- **Never leave the meter running** (avd-second-brain decision 0017). The jumpbox always has a daily stop (`jumpboxAutoShutdownTime`, 20:00 in the landing zone's time zone). `--jumpbox-keep-running <yyyy-MM-ddTHH:mmZ>` opts out until a time in the future, recorded on the VM's `avdlz-keep-running-until` tag; the next deployment without it restores the stop. The post-deployment preflight and `Connect-AvdJumpbox.ps1` report the meter (`jumpbox-meter`): running past the keep-running time, running with no stop, or stopped from inside (still billing) is a warning. `Connect-AvdJumpbox.ps1 -Stop` deallocates it now.
- **Cost.** The preflight prices the jumpbox's compute (Linux rate, at the same weekly hours as the hosts, or around the clock when kept running) and its disk, and lists Bastion Developer as no charge. Defender for Servers, when the landing zone turns it on (prod), covers the jumpbox too and is listed with the Defender plans as usage-based.
- **Teardown.** `Remove-AvdDemo.ps1 -IncludeJumpbox` removes the jumpbox resource group and the Bastion; `-IncludeLandingZone` removes them with everything else. The jumpbox's disk can hold the only copy of what was run there (run journals in `~/avdlz-runs`), so `-IncludeJumpbox` needs `-DiscardLastCopy` like the landing zone (avd-second-brain decision 0016). Keep run journals in the run store.
- **Region.** The preflight fails `bastion-developer-region` and `deploy.sh --jumpbox` refuses in a region without Bastion Developer, from one list kept in two places (`Get-AvdBastionDeveloperRegion` and `deploy.sh`, compared by a test). Basic or higher would work there but bills by the hour; it is not deployed by this repo.

## Consequences
- Operators can run from a machine inside the landing zone: no Cloud Shell timeouts, the private Key Vault and endpoints in reach, a session that survives closing the tablet.
- Decision 0001 still holds: no public IP, no admin network beside the spoke, no standing access path (the jumpbox is off most of the time and its password changes on every connect).
- It replaces the premise behind avd-liquidware's N-M1 and deploy spec section 9 for the Developer SKU only; those documents get a note pointing here. Liquidware's own console subnet is in its own VNet, which Bastion Developer in the spoke can't reach (no peering).
- One connection at a time, browser only: not a team bastion. A hub-peered landing zone usually has a hub Bastion (Basic or higher, which reaches peered spokes); the preflight warns that Developer in a hub-peered spoke is untested.
- Not in the recovery region (South Central US has no Bastion Developer).
- First boot downloads tools from Microsoft's feeds, the PowerShell Gallery and the pinned Bicep release on GitHub. That is a workstation's setup, not a session host's configuration (`docs/design-decisions.md` section 3 is about the hosts).

## To confirm in a sandbox run (offline-tested only so far)
The facts above are Microsoft's; these are not documented and need a real run (queued in the sandbox run queue, not run ad hoc):
1. Bastion Developer deploys from the template with only `virtualNetwork` set, and the portal's Connect > Bastion finds it.
2. The connection reaches the jumpbox through the subnet NSG as written (the source address Developer uses is not documented).
3. `Connect-AvdJumpbox.ps1`'s VM access extension sets the password and the SSH sign-in works.
4. First boot finishes (`/var/log/avdlz-jumpbox.log` ends `ready`) and the scripts run from the box, including reading the private Key Vault.
5. The daily stop deallocates it, and teardown leaves nothing billing.
