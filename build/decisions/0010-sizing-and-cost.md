# 0010. Size in the portal, validate and price in the preflight

- **Status:** Accepted

## Context
Operators decide how many session hosts they need, and of what size, from the number of people and the kind of work, not from VM counts. The quota check and the region's VM availability depend on that decision. A preflight run against the parameter file's defaults said little about the deployment someone actually wanted. Cost depends on the region, the size and the hours the hosts run. The portal is a static page, and pasted output never leaves the browser (decisions 0007 and 0008). The Azure Retail Prices API is public but was not verified to be reachable from a browser. Committing a price table would go stale and would have to be invented without network access.

## Decision
- **The portal sizes** each host pool. By default it starts from the minimum viable kit (one `Standard_E4as_v5` host, as in the dev parameter file) with a host count the operator chooses. Automatic sizes it from people, peak concurrency, workload (Microsoft's users per vCPU for multi-session hosts), VM size, spare host, profile size and active hours. The result is the host count, sessions per host, vCPU quota and profile share. Sizing is kept as a list of host pools with one entry today (`MAX_HOST_POOLS = 1`), so more host pools only add entries.
- **One sizing object drives every command.** It holds `hosts`, `vmSize`, `maxSessions`, `profileQuotaGiB` and `activeHoursPerWeek`.
  - It becomes `-SessionHostCount -SessionHostVmSize -MaxSessionLimit -ProfileShareQuotaGiB -ActiveHoursPerWeek` on the preflight, `--hosts --vm-size --max-sessions --profile-quota` on `deploy.sh`, and `-SessionHostVmSize -SessionHostCount` on the post-deployment preflight.
  - The parameter files read these values from `AVD_SESSION_HOST_COUNT`, `AVD_SESSION_HOST_VM_SIZE`, `AVD_MAX_SESSION_LIMIT` and `AVD_PROFILE_QUOTA_GIB`, with `empty()` guards (lesson 0004), the same way as the region.
  - A pasted preflight's `context.sizing` (the sizing it validated) replaces the portal's, so the deploy command deploys what was checked.
- **The preflight validates and prices** the compiled plan. Quota and VM availability are checked for the sized plan, and a warning is raised above 6 sessions per vCPU. Cost comes from the Retail Prices API, called from Cloud Shell. Each line must match exactly one meter; otherwise it is reported with the meters seen and left out of the total. Usage-based charges are listed as excluded. If the API fails, the result is a warning, never a failure.
- **Memory-optimized E-series and Premium SSD by default.** Hosts shared by many users run out of memory before CPU. The template and parameter files default to `Standard_E4as_v5`, the portal suggests E-series for every workload, and OS disks are Premium SSD.
  - Warnings: below 1 GiB per session on any size, and below 1.5 GiB on D-series, where the warning names the E-series equivalent.
  - Deployed D-series hosts are not resized silently: the preflight warns first. The post-deployment quota check and the demo use the deployed size.
- **The estimate is in the state line** (`context.estimate`). The portal shows it on its own **Cost** step, after sizing.
- **Power settings belong to the cost.** The Cost step has toggles for Start VM on Connect and the scheduled auto shutdown, plus the hours people work. From them it derives the hours each host runs. The estimate uses an upper bound where the schedule, not use, decides: 168 hours without a scheduled stop, and the 07:00-to-stop weekday window without Start VM on Connect. The settings are deployed, not just priced: `AVD_START_VM_ON_CONNECT` and `AVD_AUTO_SHUTDOWN_TIME` (`none` = no stop), `deploy.sh --start-vm-on-connect --auto-shutdown`, and the preflight's `-StartVmOnConnect -AutoShutdownTime`. The preflight reports them in `context.power`.
- **The portal reprices** a preflight estimate from its unit prices when the hours, host count or profile share change. A different size or region is marked stale instead, because the unit prices would be wrong.

## Consequences
- The quota request, availability checks and deployment all follow the sizing the operator chose.
- Prices are live and region-specific, and nothing in the repo needs refreshing. The estimate appears only after the preflight runs.
- Meter names can change. An unmatched line says so and names what it saw, so the first real run shows what to adjust (lesson 0012).
- Adding host pools means more entries in the list, and templates and commands that take one entry each. The single-pool commands stay as they are.
