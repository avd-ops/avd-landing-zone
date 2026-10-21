# Live demo: a working desktop in a 30-minute slot

A fresh landing zone takes 30–45 minutes to deploy ([deploy.md](deploy.md#4-deploy)). The post-deployment setup and the first sign-in come after that. That is too long, and too uncertain, to fit a 30-minute slot. So the demo works like a cooking show:

- **Dev is built the night before and is the working desktop.** You sign in to it during the demo.
- **Test is deployed live beside it** from [`parameters/test.bicepparam`](../parameters/test.bicepparam). It is the dev footprint under its own names (`avdlz-test`, session hosts `avdlztsh-*`). It leaves the subscription-wide pieces (policy guardrails, activity log export) to dev, so nothing collides.

Every block below is self-contained. Paste it into a fresh [Cloud Shell (PowerShell)](https://shell.azure.com/powershell) and paste the output into the [deployment portal](https://avd-ops.github.io/avd-landing-zone/portal/). The portal tells you what to run next.

## The night before (about 1.5 hours, mostly waiting)

**1. Pre-deployment preflight for dev, with `-Fix`, until it says Ready.** This registers the providers and the EncryptionAtHost feature (about 15 minutes, once per subscription), creates the groups, and recovers a soft-deleted Key Vault.

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }
Set-Location ~/avd-landing-zone; git fetch -q --tags origin; $t = @(git tag -l 'v*' --sort=-v:refname | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })[0]; if ($t) { git checkout -q $t } else { git checkout -q master; git pull -q --ff-only }
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/dev.bicepparam -Location northcentralus -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins' -Fix
```

**2. Deploy dev.** Note the start and end times.

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }
Set-Location ~/avd-landing-zone; git fetch -q --tags origin; $t = @(git tag -l 'v*' --sort=-v:refname | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })[0]; if ($t) { git checkout -q $t } else { git checkout -q master; git pull -q --ff-only }
bash ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus --users-group 'AVD Users' --admins-group 'AVD Admins'
```

**3. Post-deployment setup for dev, with `-Fix`.** It covers admin consent for the storage app, the Conditional Access exclusion and the profile share permissions. It asks for a Microsoft Graph device code.

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }
Set-Location ~/avd-landing-zone; git fetch -q --tags origin; $t = @(git tag -l 'v*' --sort=-v:refname | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })[0]; if ($t) { git checkout -q $t } else { git checkout -q master; git pull -q --ff-only }
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix -AllowHostStart
```

**4. Sign in once as the demo user.** Use the [Windows App](https://windows.cloud.microsoft) and open the desktop. This proves the whole path and creates the FSLogix profile, so tomorrow's sign-in is quick. Sign out when you're done.

**5. Where did the minutes go?** Keep this output: it shows the long pole, usually the session host and its extensions.

```powershell
$name = az deployment sub list --query "sort_by([?starts_with(name,'avdlz-dev-')], &properties.timestamp)[-1].name" -o tsv
az deployment operation sub list -n $name --query "[].{step:properties.targetResource.resourceName, state:properties.provisioningState, took:properties.duration}" -o table
```

**6. Pre-deployment preflight for test.** It confirms there is quota for a second host: two `Standard_E4as_v5` hosts need 8 vCPUs of the *Standard EASv5 Family*. If quota is short, the portal builds the increase request, and small increases are usually approved in minutes. Don't deploy test tonight.

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }
Set-Location ~/avd-landing-zone; git fetch -q --tags origin; $t = @(git tag -l 'v*' --sort=-v:refname | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })[0]; if ($t) { git checkout -q $t } else { git checkout -q master; git pull -q --ff-only }
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/test.bicepparam -Location northcentralus -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins' -Fix
```

Dev's scheduled stop deallocates the host at 20:00 Central. That is expected: Start VM on Connect starts it again at the next sign-in.

## 20–30 minutes before the demo

- **Warm the desktop.** Sign in once in the Windows App. Start VM on Connect takes a few minutes to boot the host. Then sign out, or leave the session disconnected.
- **Open these tabs:**
  - the portal, with Deployment settings set to `parameters/test.bicepparam`;
  - a signed-in Cloud Shell;
  - the Windows App;
  - the Azure portal on the `rg-avdlz-dev-*` resource groups.
- **Check that the pre-deployment preflight for test still says Ready.**

## The 30 minutes

| Time | Show |
|---|---|
| 0–5 | **The portal.** The latency check ranks regions from the room. Size the host pool (one E4as_v5 host). On the **Cost** step, flip Start VM on Connect and the scheduled stop, and watch the hours and the price change. |
| 5–8 | **Deploy test live.** Paste the portal's pre-deployment preflight (Ready), then its `deploy.sh` command for `parameters/test.bicepparam`. Explain what it builds while it runs: private networking, FSLogix on Azure Files over Private Link, Entra join, Intune, the scaling plan and auto shutdown. |
| 8–20 | **The working desktop.** Sign in to dev in the Windows App. Show the FSLogix profile, the private endpoints and the NAT Gateway in the Azure portal. Optionally show the Well-Architected review in the portal (Sign in step, then Well-Architected review). |
| 20–28 | **Back to the live deployment.** Paste the portal's "check on it" command, which shows each finished resource. It will likely still be running, which is expected: it keeps going in Azure if Cloud Shell disconnects. |
| 28–30 | Questions. |

## If something goes wrong

- **The live deployment fails.** Paste the output into the portal. It names known errors and gives the command that lists the failed resources. The dev desktop is unaffected: test has its own resource groups.
- **The desktop doesn't connect.** The host may still be starting (Start VM on Connect). Wait a minute and retry. Or run the post-deployment check for dev: its *Host pool* section says whether the host is Available.
- **Cloud Shell disconnects.** The deployment carries on in Azure. The portal's Deploy step has "Already started? Check on it".

## Afterwards

Remove test and keep dev:

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }
Set-Location ~/avd-landing-zone; git fetch -q --tags origin; $t = @(git tag -l 'v*' --sort=-v:refname | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' })[0]; if ($t) { git checkout -q $t } else { git checkout -q master; git pull -q --ff-only }
./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment test -IncludeLandingZone -WhatIf
```

Read the `-WhatIf` output, then run it again without `-WhatIf` and with `-DiscardLastCopy`: test's profiles, their backups and its Log Analytics workspace have no other copy, so the script refuses without it. Copy anything you want to keep first. With dev still there, the cleanup keeps what dev uses: the policy assignments, the activity log export to dev's workspace and dev's deployment records. It removes test's resource groups, budget and deployment records. Test's Key Vault stays soft-deleted for 90 days. The next test deployment's preflight with `-Fix` recovers it.
