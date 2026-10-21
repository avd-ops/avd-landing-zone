# Golden images: setup and builds

How to set up and run step 1 of the [image pipeline](../build/specs/image-pipeline-spec.md): a monthly golden image, built by Azure Image Builder (AIB) into an Azure Compute Gallery. Promotion to hosts (rotation, the QA pool, automated validation) comes in later steps; until then, landing zones keep using the marketplace image.

**Not verified against a real tenant yet.** The spec's §11 lists what to confirm on the first real build. Report what differs; it becomes a lesson and a guard (decision 0006).

## What gets built

- **Source:** Windows 11 Enterprise multi-session 24H2 with Microsoft 365 Apps, at the marketplace version that is newest on the day of the build. The build records which.
- **Customizations,** in order:
  1. the month's Windows updates, then a restart;
  2. Storage Sense off;
  3. time zone redirection on;
  4. disconnected sessions ending after 8 hours;
  5. automatic updates off for Windows and Microsoft 365 Apps;
  6. WDOT with the reviewed profile ([scripts/image/wdot/README.md](../scripts/image/wdot/README.md)), then a restart;
  7. current Defender signatures;
  8. your own step (`scripts/image/custom/Invoke-CustomImageStep.ps1`);
  9. cleanup.
- **Build-time validation:** `scripts/image/Test-GoldenImage.ps1` runs on the build VM. Any failure stops the version from being published.
- **Result:** a gallery version `YYYY.MDD.N` (for example `2026.1004.1`). It is tagged with the commit, the source image, the WDOT pin and the run, and excluded from `latest`.

Every script is inlined into the image template from the commit being built, so nothing is fetched from your repository and private forks work. WDOT is the only download, from its own repository: it's pinned to a commit and checked file by file.

## One-time setup

### 1. Build subnets in the build environment's landing zone

The build VM and AIB's build container run in two subnets of one landing zone's spoke, `dev` by default, and use its egress. Redeploy that landing zone with the subnets:

```bash
# Azure Cloud Shell (Bash)
cd ~ && { [ -d avd-landing-zone ] && git -C avd-landing-zone pull --ff-only || git clone https://github.com/avd-ops/avd-landing-zone; } && cd avd-landing-zone
export AVD_IMAGE_BUILD_SUBNETS=true
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus \
  --users-group "AVD Users" --admins-group "AVD Admins" --what-if
# Then the same command without --what-if.
```

Use the region, groups, sizing and power flags of that landing zone's last deployment: a flag left out falls back to the parameter file's value. The what-if should show only the two subnets and their NSG being added; anything else means a flag differs from the last deployment.

This adds `snet-image-build` (`10.100.2.128/27`) and `snet-image-aci` (`10.100.2.160/27`, delegated to Azure Container Instances), with an NSG and the hosts' NAT Gateway or hub route.

**Keep `AVD_IMAGE_BUILD_SUBNETS=true` for every later deployment of that environment.** The virtual network's subnet list is replaced on each deployment, so a deployment without it tries to remove the build subnets. With `deploy.yml`, set the variable `AVD_IMAGE_BUILD_SUBNETS` to `true` in that environment's GitHub Environment. In hub mode, the hub firewall must allow:
- Windows Update, the Microsoft 365 CDN and Defender updates;
- the AIB service endpoints;
- `github.com` and `codeload.github.com`, for WDOT.

### 2. Resource providers

AIB needs these registered once per subscription, by an owner:

```powershell
# Azure Cloud Shell (PowerShell)
'Microsoft.VirtualMachineImages','Microsoft.Compute','Microsoft.KeyVault','Microsoft.Storage','Microsoft.Network','Microsoft.ContainerInstance' |
  ForEach-Object { Register-AzResourceProvider -ProviderNamespace $_ | Select-Object ProviderNamespace, RegistrationState }
```

### 3. The gallery, the definition and the identities

`bicep/images/main.bicep` creates:
- `rg-<prefix>-images`, holding the gallery `gal<prefix>`, the definition `win11-avd-m365` (Generation 2, Trusted Launch, accelerated networking) and two identities;
- `rg-<prefix>-images-staging`, for AIB's temporary resources;
- two least-privilege custom roles;
- the role assignments, including AIB's right to join the two build subnets.

The deployment fails early if step 1 wasn't done. You need Owner, or User Access Administrator plus Contributor, on the subscription.

```bash
# Azure Cloud Shell (Bash)
cd ~ && { [ -d avd-landing-zone ] && git -C avd-landing-zone pull --ff-only || git clone https://github.com/avd-ops/avd-landing-zone; } && cd avd-landing-zone
export AVD_GITHUB_REPOSITORY='<owner>/<repo>'   # the repository that runs image-build.yml
az deployment sub create --name avdlz-images --location northcentralus \
  --template-file bicep/images/main.bicep --parameters parameters/images.bicepparam \
  --query properties.outputs.buildIdentityClientId.value -o tsv
```

The last line prints the build identity's client ID, needed in step 4. Use the same region as the build environment's landing zone, and set `AVD_LOCATION` if it isn't North Central US.

### 4. The GitHub Environment `images`

In the repository: **Settings → Environments → New environment → `images`**. Add these as environment **secrets**. None of them grants access (the identity uses OIDC), but the repo is public and an Actions log shows a step's inputs unmasked unless they are secrets:

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | The client ID from step 3 |
| `AZURE_TENANT_ID` | Your tenant ID |
| `AZURE_SUBSCRIPTION_ID` | The subscription of the images resource group |

The build identity is federated to this environment only (`repo:<owner>/<repo>:environment:images`). It has:
- Contributor on `rg-<prefix>-images`;
- Reader on the subscription, for source image versions, quota and providers;
- Storage Blob Data Reader on the staging group, for AIB's logs.

It can't change a landing zone.

### 5. Quota

The build VM is a `Standard_D4s_v5` by default (4 vCPUs, the DSv5 family). The build checks the quota first and stops with the request if it's short. To change the size, edit `buildVmSize` in [`parameters/images-build.bicepparam`](../parameters/images-build.bicepparam).

## Builds

- **Monthly, automatically:** `image-build.yml` runs on the third Monday of each month at 06:00 UTC, about a week after Patch Tuesday.
- **On demand:** **Actions → image-build → Run workflow**.
  - `force` builds even when the source image and the commit haven't changed, for example after an out-of-band update.
  - `emergency` marks a security build (spec §5.7).

A build takes 1–4 hours. Each one opens an issue labeled `image-build` with:
- the version and the source image;
- the validation table;
- the run's link.

The customization log is kept as the run's artifact for 90 days. A run that finds nothing new ends without an issue.

From Cloud Shell instead of GitHub Actions:

```powershell
# Azure Cloud Shell (PowerShell)
cd ~; if (Test-Path avd-landing-zone) { git -C avd-landing-zone pull --ff-only } else { git clone https://github.com/avd-ops/avd-landing-zone }; Set-Location ~/avd-landing-zone
./scripts/ops/Start-AvdImageBuild.ps1 -NamePrefix avdlz
```

Cloud Shell sessions time out on idle; the GitHub workflow is the reliable path for a multi-hour build. A build interrupted after deploying leaves a template behind, and the next build removes it after 24 hours, once it has saved the template's customization log. Deleting a template also deletes its staging account, the only copy of that log, so when the log can't be saved the template stays and the run says so; `-DiscardLastCopy` removes it anyway ([never delete the last copy](https://github.com/avd-ops/avd-second-brain/blob/main/docs/knowledge/decisions/0016-never-delete-the-last-copy.md)). The 90-day artifact doesn't count as a durable copy, since it expires.

## When a build fails

The issue and the run's summary say where:
- **Prerequisites** (providers, the gallery definition, quota): follow the remediation printed.
- **Template deployment:** ARM's error is quoted. A missing subnet means step 1 wasn't done for the build environment.
- **Run:** AIB's status, and the last 40 lines of the customization log. `RESULT <check> Fail` lines name the validation check that failed.

A version that AIB published despite a failed check is tagged `avdlz-validation=failed:build`. It is never validated or promoted, and the same commit can be built again.

## Costs

Building costs:
- the build VM for 1–4 hours a month;
- a short-lived container;
- the staging disk;
- the gallery's replica storage for each kept version.

The gallery itself and AIB are free. Price your region with the retail price API (decision 0010); the preflight's cost estimate doesn't include images yet.
