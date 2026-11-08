# Architecture

## Layout

```
Subscription (dedicated AVD landing zone)
│  Policy: allowed locations, tag inheritance · Defender for Cloud · Budget · Activity log → LAW
│
├── rg-<prefix>-<env>-network
│     vnet-<prefix>-<env>            10.100.0.0/22
│       snet-session-hosts           10.100.0.0/23   NSG · NAT GW (standalone) or UDR→hub FW · no default outbound
│       snet-private-endpoints       10.100.2.0/27   NSG enforced on PEs (445 from hosts, 443 from VNet)
│       snet-jumpbox (opt-in)        10.100.2.32/28  NSG · same egress as the hosts · no public IP
│     Bastion Developer bas-<prefix>-<env> (opt-in, no charge, decision 0019)
│     private endpoints: file, vault, host pool (connection)
│     privatelink zones: file, vaultcore, wvd       (standalone; hub mode can use central zones)
│
├── rg-<prefix>-<env>-management
│     Log Analytics · AVD Insights DCR (microsoft-avdi-*) · action group · alerts
│     Key Vault (private, RBAC): break-glass local admin
│
├── rg-<prefix>-<env>-storage
│     Premium FileStorage (ZRS): share "profiles" · Entra Kerberos · shared key off
│     Recovery Services vault: daily share backup
│
├── rg-<prefix>-<env>-avd
│     Host pool (pooled, Private Link) · Desktop app group · Workspace · Scaling plan
│
├── rg-<prefix>-<env>-hosts
│     Session hosts ×N (zones 1/2/3, Trusted Launch, encryption at host)
│       extensions: AADLoginForWindows (+Intune), AzureMonitorWindowsAgent, GuestConfiguration
│       run commands: Configure-FSLogix → Register-AvdAgent
│
└── rg-<prefix>-<env>-jumpbox (opt-in, deploy.sh --jumpbox)
      Operator jumpbox: Ubuntu (B2als_v2) or Windows Server 2025 (B2as_v2), Trusted Launch, daily stop, Cloud Shell's tools
```

```mermaid
flowchart LR
  subgraph Sub["Subscription: Dedicated AVD Landing Zone (Policy, Defender, Budget, Activity Log -> LAW)"]
    subgraph RGNet["rg-<prefix>-<env>-network · vnet-<prefix>-<env> (10.100.0.0/22)"]
      subgraph SnetHosts["snet-session-hosts (10.100.0.0/23 · NSG: Deny Inbound)"]
        SH1["Session Host 1 (Zone 1)"]
        SH2["Session Host 2 (Zone 2)"]
        SHN["Session Host N (Zone 3)"]
      end
      Egress["NAT Gateway (Standalone)\nor UDR 0.0.0.0/0 -> Hub FW"]
      subgraph SnetPE["snet-private-endpoints (10.100.2.0/27 · Network Policies Enabled)"]
        PEFile["PE: Storage (file)\nSMB 445"]
        PEVault["PE: Key Vault (vault)\nHTTPS 443"]
        PEWvd["PE: AVD (connection/feed)\nHTTPS 443"]
      end
      subgraph SnetJump["snet-jumpbox (10.100.2.32/28 · Opt-in) & Private DNS Zones"]
        Jump["Operator Jumpbox + Bastion Developer"]
        DNS["privatelink.file.core.windows.net\nprivatelink.vaultcore.azure.net\nprivatelink.wvd.microsoft.com"]
      end
    end

    subgraph RGAvd["rg-<prefix>-<env>-avd & rg-hosts"]
      Pool["Host Pools (Pooled / Personal)\nApp Groups · Workspaces · Scaling Plan"]
    end

    subgraph RGStorage["rg-<prefix>-<env>-storage"]
      Files["Premium FileStorage (ZRS)\nShare: profiles · Entra Kerberos\nDaily RSV Backup"]
    end

    subgraph RGMgmt["rg-<prefix>-<env>-management"]
      LAW["Log Analytics + AVD Insights DCR\nAction Group & Alerts"]
      KV["Key Vault (Private Link · RBAC)\nBreak-Glass Secret"]
    end
  end

  SnetHosts -->|Outbound 443| Egress
  SnetHosts -->|SMB 445| PEFile
  SnetHosts -->|HTTPS 443| PEWvd
  PEFile -.->|Private Link| Files
  PEVault -.->|Private Link| KV
  PEWvd -.->|Private Link| Pool
```

## Traffic flows

| Flow | Path |
|---|---|
| User → desktop | Windows App → AVD gateway (public, reverse connect; RDP Shortpath where available). Session hosts accept no inbound connections |
| Session host → AVD service (host pool) | Private endpoint `connection` sub-resource via `privatelink.wvd.microsoft.com` |
| Session host → FSLogix share | SMB 445 → storage private endpoint; Kerberos ticket from Entra ID |
| Session host → Entra ID, Intune, Windows Update, M365, AVD agent downloads | Egress through the NAT Gateway (standalone) or the hub firewall (hub-peered) |
| Session host → Log Analytics | Azure Monitor Agent over egress |
| Operator → Key Vault | Private endpoint, reachable from the VNet or peered networks only |

```mermaid
flowchart LR
  User["End-User Device\nWindows App / Web Client\n+ avd-linecheck probe"]
  Entra["Microsoft Entra ID & Intune\nConditional Access, MFA,\nEntra Kerberos TGT, MDM"]
  Gateway["AVD Control Plane\nWorkspace Feed, Gateway\n& Connection Broker"]
  Egress["NAT Gateway (Standalone)\nor Hub Firewall (Peered)\nOutbound 443 & UDP 3478"]
  Host["Session Host VM\nsnet-session-hosts (10.100.0.0/23)\nNo Public IP · Reverse Connect"]
  PEs["Private Endpoints\nsnet-private-endpoints (10.100.2.0/27)\nStorage (445), WVD (443), Key Vault (443)"]

  User -->|1. OIDC + MFA| Entra
  User -->|2. Feed & TLS 443| Gateway
  Host -->|3. Reverse Connect TLS 443| Gateway
  Host -->|4. SMB 445 FSLogix + WVD PE 443| PEs
  Host -->|5. Outbound 443 / UDP 3478| Egress
  Egress -->|6. Kerberos TGT / Intune MDM| Entra
```

In **hub-peered** mode your firewall must allow the [AVD required FQDNs](https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint) plus Entra ID, Intune and Windows Update endpoints.

## Identity and access (RBAC)

| Principal | Role | Scope |
|---|---|---|
| AVD Users group | Desktop Virtualization User | Desktop application group |
| AVD Users group | Virtual Machine User Login | `hosts` RG |
| AVD Users group | Storage File Data SMB Share Contributor | Storage account |
| AVD Admins group | Virtual Machine Administrator Login | `hosts` RG |
| AVD Admins group | Storage File Data SMB Share Elevated Contributor | Storage account |
| AVD Admins group | Key Vault Secrets User | Key Vault |
| Azure Virtual Desktop SP | Desktop Virtualization Power On Off Contributor | `avd` and `hosts` RGs |
| Tag-inheritance policy identities | Tag Contributor | Subscription |

## Agent updates

The host pool takes AVD agent updates in one window, Saturday 02:00 in each host's local time (`controlPlane.bicep`). [Scheduled Agent Updates](https://learn.microsoft.com/azure/virtual-desktop/scheduled-agent-updates) (git_commit_id 4dcb5ff, 2025-06-25) asks that every host be on during the window: an update fails on a host that is off, the broker tries again in the next windows and installs by force after the fourth, and a critical update is always forced. The scaling plan's weekend minimum is 0% and the optional auto shutdown deallocates hosts at night, so in this landing zone most hosts are off in that window and take updates when the broker forces them. That is fine for the one-host demo. For a real pool, choose one of these before relying on the window: start the hosts for the window and exclude them from scaling while it runs, or add the optional second window at a time your hosts are on. Either one changes the scaling and power design and needs a mock path and a scenario assertion.

## Deployment order

`monitoring` → `network` → `privateDns` → `keyVault`, `storage` (→ `backup`), `controlPlane` → `sessionHosts` (VMs → FSLogix run command → agent run command). `governance` runs as soon as the workspace exists.
Dependencies come from outputs, so ARM parallelizes everything else.

```mermaid
flowchart LR
  Mon["monitoring\nLAW + AVD Insights DCR + Alerts"]
  Gov["governance\nPolicy, Defender, Budget"]
  Net["network\nVNet, Subnets, NSGs, NAT GW"]
  DNS["privateDns\nfile, vaultcore, wvd zones"]
  KV["keyVault\nVault + PE + RBAC"]
  Stg["storage (+backup)\nPremium Files + PE + RSV"]
  CP["controlPlane\nHost Pools, App Groups, Workspaces, PEs"]
  Hosts["sessionHosts (xN)\n1. VMs (Trusted Launch, Zones 1-3)\n2. AADLogin + AMA Extensions\n3. RunCmd: Configure-FSLogix\n4. RunCmd: Register-AvdAgent"]

  Mon --> Gov
  Mon --> Net
  Net --> DNS
  DNS --> KV
  DNS --> Stg
  DNS --> CP
  KV --> Hosts
  Stg --> Hosts
  CP --> Hosts
```

## Why AVM

Resources come from pinned [Azure Verified Modules](https://aka.ms/avm). Native resources are used only where no module exists or the module adds nothing: Run Commands, backup protection, role assignments at resource group scope, policy, Defender pricings, budget and alerts.
