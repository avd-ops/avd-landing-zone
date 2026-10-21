# Red-team review: image pipeline spec

- **Reviewed:** [image-pipeline-spec.md](image-pipeline-spec.md) as of 2026-10-04 (decision 0013, Proposed), including WDOT, the QA pool and automated validation
- **Method:** trace each flow end to end (build, validate, promote, rotate, clean up) against the identities and state it actually has. Look for places where two parts of the spec, or this spec and the [second brain spec](https://github.com/avd-ops/avd-second-brain/blob/main/docs/operations-spec.md), contradict each other. Every finding has a scenario and a fix. Nothing here has been tried against a real tenant.

## Verdict

The shape is right. A generic image, a QA ring, automated validation and a person promoting to production is the standard golden-image pattern, and the spec keeps the repo's habits: pinning, resumable phases, positive evidence.

But four findings would stop the pipeline from working as written:
- automated validation can't deploy the QA host with the identity it's given (C1);
- the image version and generation live in too many places, so an ordinary redeploy can break production (C2);
- the nightly Stop deallocates the QA host the hourly checks need (C3);
- the adopters' private forks can't serve the scripts that the build downloads (C4).

The high findings are mostly about patch latency, cleanup, and evidence that's weaker than it looks. Fix the critical findings in the spec before decision 0013 moves to Accepted.

| Severity | Count |
|---|---|
| Critical: the pipeline doesn't work, or production breaks | 4 |
| High: wrong in a likely case, or the safety claim doesn't hold | 9 |
| Medium: gaps and inconsistencies | 8 |
| Strategic | 2 |

## Critical

### C1. Automated validation can't deploy a QA host with the rights it has
**Where:** §6.3 stages 1 and 3 "Rotate the QA pool (§6.5, `-HostPool qa`)"; §6.5 Deploy phase "Deploys the landing zone"; §6.3 "Who can do what".
**Scenario:** rotation's Deploy phase deploys `main.bicep` at subscription scope, which touches every landing zone resource group. The `image-validate` identity holds Contributor on the QA resource groups only, so the deployment fails with an authorization error at stage 1, every month. The obvious workaround is to give the identity rights to deploy `main.bicep`. That lets an unattended workflow change production, which is exactly what EX-0005 promises can't happen.
**Fix:**
- QA hosts get their own template, `bicep/qa/main.bicep`, at the QA resource group's scope.
  - It references the landing zone's subnet, data collection rule, host pool settings and share path as existing resources or parameters.
  - It deploys only the QA host, its run commands and a registration token for the QA host pool.
  - It creates no role assignments; the landing zone deployment creates the QA pool's role assignments once.
- Rotation with `-HostPool qa` uses this template.
- A template test fails if `bicep/qa` references a resource outside the QA resource group with anything but a read.

### C2. The image version and generation live in four places, and a normal redeploy breaks production
**Where:** §6.1 (`AVD_SESSION_HOST_IMAGE_ID`, `AVD_SESSION_HOST_GENERATION` as environment variables), §6.4 (promotion sets the GitHub variable), §6.5 (rotation state in a host pool tag).
**Scenario:** the version and generation are held separately in GitHub environment variables, a Cloud Shell session's environment, the rotation tag and template defaults.
- **Promotion sets prod's variable before rotation runs.** If anyone deploys prod for any other reason, the template now gives the **current** generation's VMs a new `imageReference`. ARM rejects a change to an existing VM's image reference, so the deployment fails. A routine change becomes a failed production deployment.
- **After a rotation from `a` to `b`, the variable still says `a`.** The next routine deploy recreates generation `a` beside `b`. That doubles the hosts, spends quota and money, and puts users on both.
**Fix:** one source of truth. The host pool carries `avdlz-image` and `avdlz-generation` tags, which only the rotation script writes, when Deploy succeeds and when Remove completes.
- `deploy.sh` and `deploy.yml` read both tags before deploying, and pass them unless the rotation script itself is deploying.
- They refuse to deploy while `avdlz-rotation` is set.
- Promotion records the **target** version on the host pool (`avdlz-image-next`) and starts the rotation; it doesn't change what a normal deploy uses.
- The environment variables become inputs to the rotation script only.
- An offline scenario covers a routine redeploy before, during and after a rotation.

### C3. The nightly Stop deallocates the QA host that the hourly checks need
**Where:** §6.2 Power "Start VM on Connect, and covered by the scheduled Stop (EX-0002)"; §6.3 soak "Every hourly run passes".
**Scenario:** at the scheduled time, EX-0002 deallocates the QA host. The next hourly check finds it not Available and fails the version, and so does every soak that crosses a night. No version ever validates. If checks skip a deallocated host instead, the soak passes on a host that was off for most of it, which is weaker evidence than it claims.
**Fix:**
- During a soak, the validation workflow tags the QA host with the scheduled Stop's exclusion and starts it if it's deallocated. Decision 0011's runbook already honors exclusion tags; verify it does for EX-0002.
- The tag is removed when validation ends or fails.
- The soak's pass rule counts **runs with the host running**, at least 20 of 24, rather than wall-clock hours.
- The cost of keeping one host up for two days a month is shown in the build issue.

### C4. Adopters' private forks can't serve the customizer scripts
**Where:** §5.2 step 3 "each script by `scriptUri` at the commit"; §8 "AIB downloads each customizer from the commit's raw URL"; the second brain spec §9.1, which requires private repositories.
**Scenario:** an adopter runs the second brain, as designed, from a private fork. `raw.githubusercontent.com` URLs for a private repository need a token. AIB fetches scripts anonymously, so every build fails at the first customizer. The same applies to WDOT's profile, which lives in the repo.
**Fix:**
- The build workflow uploads the scripts and the WDOT archive and profile, at the commit, to a private container, `image-build`, in a storage account in the images resource group.
  - Public network access is off, with a private endpoint in the build spoke.
  - Each file keeps its SHA-256 checked as before.
- AIB downloads them with the image template's identity, which has Storage Blob Data Reader on that container.
- `raw.githubusercontent.com` is no longer needed in hub firewalls. The WDOT archive is mirrored there after its hash is verified (see M4).

## High

### H1. Patch latency has no ceiling
**Where:** §5.1 schedule, §5.2 step 1 "nothing changed → stop", §6.3 soaks, §6.5 Wait "Without it, it only reports", §7 `image-age` at 45 days.
**Scenario:** with automatic updates off (§5.6), a host has no patches except the image's. Here is the path from Patch Tuesday to patched hosts:
- the build, about 6 days later;
- validation, at least 2 days;
- a person promoting;
- rotation, whose Wait phase never ends while one user keeps a disconnected session, because log-off is opt-in.

An out-of-band security update makes it worse: a `workflow_dispatch` rebuild stops at step 1 when the source image and the commit haven't changed, even though Windows Update would bring the fix.
**Fix:**
- **Set a target:** patched hosts within 14 days of Patch Tuesday, and within 72 hours of a critical out-of-band release.
- **Build input `force`:** skips the "nothing changed" stop.
- **Emergency mode** (`-Emergency`), for a build marked security: soaks shorten to 2 hours each, and the main pool's rotation defaults to log-off at a 24-hour deadline, with messages at the start, 4 hours before and 15 minutes before.
- **Disconnected sessions** get a time limit in the image, 8 hours by default as a generic policy. Wait can't be held open indefinitely.
- **`image-age`** drops to 35 days, plus a `patch-sla` detection.

### H2. One failed hourly check fails the month's image
**Where:** §6.3 "Every hourly run passes"; the checks include the whole landing zone's post-deployment preflight.
**Scenario:** each soak is 24 runs, each with about twenty checks, so roughly 500 checks per soak and 1,000 per version. A single transient failure fails the version for good, and the next build is a month away. So is one unrelated production problem the preflight reports, such as a quota warning turned failure or a budget Lock. The image is blamed for the landing zone. This is the M10 problem from the second brain review, in another place.
**Fix:**
- **Classify checks:**
  - image-attributable: the host's health checks, the in-host function checks, the version;
  - landing-zone-wide: the preflight.

  Only image-attributable checks can fail a version. Landing-zone failures **pause** validation, notify, and resume when they clear.
- **A check fails the version** only when it fails twice in a row, or in more than 2 of the soak's runs.
- **A failed version** can be retried once with `workflow_dispatch` after the cause is fixed, without a new build.

### H3. QA users default to the admins, whose share rights hide the users' failure modes
**Where:** §6.2 Users "When that's empty, the AVD Admins group".
**Scenario:** the AVD Admins group holds Storage File Data SMB Share **Elevated** Contributor on the profile share (architecture.md). Sign-ins by admins can succeed where a regular user's profile access fails: share-level and NTFS permissions, and the Kerberos path behind the open issue in rebuild-spec.md. Validation then reports "profiles attached" for a version that breaks every regular user.
**Fix:**
- `AVD_QA_GROUP_ID` is **required** when the QA pool is on, and must be a group of regular users, not admins.
- The preflight fails if it's empty, or if the group holds an elevated share role.
- The promotion page reports sign-ins by members of the users group separately from any others.

### H4. Teardown doesn't know the new resource groups
**Where:** §4.1 (`rg-<prefix>-images`, `rg-<prefix>-images-staging`), §6.2 (`rg-<prefix>-<env>-qa`), and `Remove-AvdDemo.ps1 -IncludeLandingZone`, which removes the five landing zone groups.
**Scenario:**
- Cleanup leaves the QA group behind: a host, a host pool, an app group in a workspace that no longer exists, and Entra ID and Intune device objects. Their deterministic names collide on the next deployment (the lesson 0023 pattern).
- Removing the **build** environment (dev) deletes `snet-image-build` and `snet-image-aci`, and every later build fails at the network.
- The gallery keeps billing for replicas.
**Fix:**
- `-IncludeLandingZone` removes the environment's QA group and its device objects.
- A new `-IncludeImages` removes the images and staging groups and the gallery. It refuses while any landing zone's host runs a version from that gallery.
- Removing the build environment warns that builds will stop, and names the parameter to move them (`AVD_IMAGE_BUILD_ENVIRONMENT`).
- PostDeployment scenario cases cover each of these.

### H5. Retention deletes versions it can't see in use
**Where:** §4.2 "never one that a host still runs: it checks every landing zone's hosts first", against §5.1 "Its identity can deploy into the images resource group ... and nothing else".
**Scenario:** the build identity can't read any landing zone, so the check either fails or is skipped. A version still pinned by an environment gets deleted. Running hosts keep working, but the next redeploy, scale-out, `replace-host` or QA rollback to "the previous validated version" fails, at the moment it's needed.
**Fix:**
- Reference counting on the version itself. The rotation script, which runs with the landing zone's rights, sets `avdlz-in-use-<env>-<pool>=true` on the version when Deploy succeeds, and clears it on the version it removes.
- Retention never deletes a version with any `avdlz-in-use-*` tag, and always keeps the last validated version **not** in use, as the rollback target.

### H6. Device objects matched by name, names reused every other month
**Where:** §6.5 Remove (device cleanup shared with `Remove-AvdDemo.ps1`, which matches by `displayName`); generations alternate `a ↔ b`; §6.3 the validation identity has no Graph access, by design (second brain H8). §6.3 also lists "Entra ID joined and Intune enrolled" as a check run from Azure.
**Scenario:**
- Automated QA rotations remove hosts without cleaning their device objects. With two environments, two stale objects pile up every month.
- Two months later, a new QA host with the same name joins Entra ID beside a stale one.
- Any later cleanup by name (the next manual run, or `Remove-AvdDemo`) deletes **both**, including the live host's. That host loses its join, and sign-ins fail.
- Separately, "Intune enrolled" can't be checked from Azure without Graph, so as written that check can't run.
**Fix:**
- At Deploy, the in-host function check records each host's Entra **device ID** (`dsregcmd /status`) and Intune enrollment ID, from inside the host. Both are stored as tags on the VM.
- Cleanup deletes by those IDs only, never by name.
- The "Entra ID joined and Intune enrolled" check moves to the in-host check.
- Stale QA device objects are listed at promotion, where a person with a Graph sign-in removes them by ID.

### H7. "Hosts don't update" and the protected service list both miss things that matter
**Where:** §5.5 protected items; §5.6.
**Scenario:**
- **Protected services.** The list misses services the landing zone depends on:
  - `LanmanWorkstation`, the SMB client FSLogix needs;
  - `KeyIso` and `VaultSvc`, credential isolation and Kerberos;
  - `TokenBroker`, Web Account Manager, used by Entra ID single sign-on and Microsoft 365 Apps;
  - `AppXSvc` and `ClipSVC`, which MSIX apps such as the new Teams and the new Outlook need;
  - the Edge Update services.

  If WDOT's profile applies any of these, the build passes and users fail.
- **Self-updating apps.** Edge, WebView2, the new Teams and OneDrive update themselves regardless of `NoAutoUpdate`, so hosts **do** drift between images.
- **Defender platform updates** (not signatures) normally arrive through Windows Update and may stall with automatic updates off.
**Fix:**
- Extend the protected list with those services. Better: derive it from function, so that §6.3's in-host check exercises SMB to the share, Kerberos ticket retrieval for the host, Web Account Manager and an MSIX app launch.
- In §5.6, list every self-updating component and decide each one explicitly. Recommended: Edge, WebView2 and Teams keep updating, because they are security-critical clients. They are recorded, not called drift.
- Add the Defender platform version to `image-age`'s evidence, and verify how platform updates arrive at build time.

### H8. One gallery, one region, one subscription, but adopters have several
**Where:** §4.1 "one per name prefix", §4.2 "one replica in the landing zone's region"; decision 0003 allows each environment its own region (`AVD_LOCATION`); environments are often separate subscriptions.
**Scenario:**
- Prod sits in another subscription and region. Its deployment can't read the gallery version (`galleries/images/versions/read` across subscriptions), and the version isn't replicated to prod's region. The deployment fails at VM creation.
- A region without zones, but with ZRS chosen for it, fails replication.
**Fix:**
- `parameters/images.bicepparam` lists every target region, from each environment's location. The ZRS or LRS rule applies per region.
- The images deployment grants Reader on the gallery to each environment's deploy identity and the AVD service principal, where required.
- The preflight's `-SessionHostImageId` check (§6.1) verifies replication to **its** region and read access from **its** identity.

### H9. Clashes with the second brain spec and the QA pool's own users
**Where:** second brain spec §4.5 (an Activity Log alert on `runCommands/write` by anyone but the deploy identity or an executor) and §4.5.1 (the kill switch doesn't stop external exceptions); §6.3 (an hourly Run Command); §6.5 Wait (no forced log-off by default).
**Scenario:**
- The hourly in-host check is a Run Command by the `image-validate` identity, so the brain alerts every hour.
- EX-0005 can't be stopped by the kill switch, and the only off switch is a GitHub variable.
- Automated QA rotations wait, with no deadline, for a QA user's disconnected session, so the state machine stalls at stage 1 or 3.
**Fix:**
- The brain's Run Command alert allowlists the `image-validate` identity **on the QA resource groups only**. Anywhere else, the alert still fires.
- EX-0005 states its own stop: `AVD_IMAGE_VALIDATION=manual`, also settable from the kill-switch workflow.
- QA pool rotations always log off at a 1-hour deadline, with messages. QA users are told this is what the QA desktop is for. Production pools keep the opt-in default.

## Medium

| # | Finding | Fix |
|---|---|---|
| M1 | **Version names with leading zeros:** `2027.0104.1`. A gallery version is three integers, and zero-padded parts are invalid or get normalized, which breaks comparing names as strings | `YYYY.MDD.N` with no padding (`2027.104.1`, `2026.1004.1`). Compare versions numerically. Template test with January and October dates |
| M2 | **Concurrent builds:** a manual build during a scheduled one, or a new build while the last is still soaking, has two versions fighting over the QA pool | Concurrency groups on both workflows. One version validates at a time, and a newer version **supersedes** a version still in validation, which is tagged `superseded` |
| M3 | **Build VM size and timeout:** AIB's default size is small. A cumulative update for Windows 11 multi-session with Microsoft 365 Apps, then WDOT and two restarts, can exceed 240 minutes. The build VM family needs quota in the build region | A pinned size in `images.bicepparam` (4 vCPUs, D-series v5 or later), a timeout of 360 minutes, and a quota check for the build family before running |
| M4 | **WDOT archive stability:** GitHub's auto-generated source archives aren't guaranteed byte-stable, so a pinned hash can break a build with no change upstream. A deleted release or a GitHub outage blocks every build | Pin by **commit SHA** as well. When a lock change is merged, the workflow fetches and verifies the archive once, then mirrors it into the private `image-build` container (C4). Builds use the mirror |
| M5 | **Build-time validation runs before sysprep:** AIB validates the customized, not yet generalized, VM. Sysprep failures and changes it makes aren't seen until the QA host | Say so in §5.4. Add "generalization succeeded" from the AIB run status and logs. The QA host's first check is the first post-sysprep evidence |
| M6 | **One replica during a surge:** rotating a large pool creates every new host from one replica at once, which is slow and can be throttled | Replica count from pool size: one per 20 hosts created at once, at least 1. Deploy batches above that |
| M7 | **Orphaned templates and staging resources** when a workflow run dies after the build starts | `image-build.yml` first deletes `it-<prefix>-*` templates older than 24 hours, saving their logs, and reports what it removed |
| M8 | **The hourly preflight under a read-only identity:** some checks need data-plane access or Graph, so with Reader they fail or warn, which reads as an image failure (H2) | Validation runs the preflight with `-SkipTenant -SkipNtfs`, never `-Fix`, and with a defined check list. Checks it can't run are reported as skipped, not failed. The in-host check covers what Reader can't see |

## Strategic

### S1. Azure Virtual Desktop has a native session host update, and the spec doesn't mention it
Microsoft now offers **session host configuration** with **session host update**. It updates a host pool's image and configuration by draining, deleting or deallocating, and recreating hosts, under a management policy ([session host update](https://learn.microsoft.com/en-us/azure/virtual-desktop/session-host-update), [configure it](https://learn.microsoft.com/en-us/azure/virtual-desktop/session-host-update-configure), [management approaches](https://learn.microsoft.com/en-us/azure/virtual-desktop/host-pool-management-approaches)). That overlaps most of §6.5.

Published guidance at the time of writing says session host configuration requires Active Directory domain-joined hosts and doesn't support Microsoft Entra ID join, and it appears to apply only to host pools created with it. Both would rule it out for this landing zone, which is Entra ID-only (decision 0001). The documentation couldn't be fetched from this session, so treat that as **to verify**.

**Fix:** record the comparison in decision 0013: "custom rotation, because session host configuration doesn't support Entra ID-joined hosts", with the source. Add a revisit trigger: when Entra ID join is supported, migrate rotation to the native feature, and keep the image build and validation.

### S2. The real-sign-in evidence depends on people who won't sign in
In a lab, or an adopter's small deployment, nobody signs in to the QA desktop every day. So:
- `qa-pool-unused` warns permanently;
- every promotion needs the "no sign-in" acknowledgment, which becomes a routine click (approval fatigue, second brain spec §12);
- the gap automation can't close, Kerberos plus FSLogix as a real user, stays open in exactly the deployments least able to absorb a broken image.

**Fix:**
- Keep the acknowledgment, but make the sign-in cheap: the promotion issue asks the approver to sign in to the QA desktop once and waits for that connection in `WVDConnections`. That's one sign-in, by the person already approving, as a member of the users group (H3).
- Move Q8 (synthetic sign-in) from "not yet" to "research in step 4", now that it carries the evidence for small adopters.

## Status

| Finding | Status |
|---|---|
| C1 QA host deploy needs landing zone rights | **Resolved in spec**: `bicep/qa/main.bicep` at the QA group's scope, no role assignments (§6.2, §6.5) |
| C2 Image and generation in four places | **Resolved in spec**: the host pool's `avdlz-image` and `avdlz-generation` tags, written only by rotation; deploys read them and refuse during a rotation; promotion sets `avdlz-image-next` (§6.1) |
| C3 Nightly Stop vs hourly checks | **Resolved in spec**: exclusion tag and start during stages; at least 20 of 24 runs with the host running (§6.3) |
| C4 Private forks can't serve scripts | **Resolved, as built**: every script is inlined into the template from the commit, so there is no container and no fetch from the repository (§5.2). That replaced the planned private container |
| H1 Patch latency | **Resolved in spec**: 14-day and 72-hour targets, `force`, emergency mode, an 8-hour limit on disconnected sessions, `patch-sla` (§5.7) |
| H2 One failure kills the image | **Resolved in spec**: classified checks, pause on landing-zone failures, the 2-in-a-row or 2-of-soak rule, one retry (§6.3) |
| H3 Admins as QA users | **Resolved in spec**: a regular-user QA group required, checked by the preflight; sign-ins reported by group (§6.2, §6.3) |
| H4 Teardown | **Resolved in spec**: §6.6 |
| H5 Retention blind to use | **Resolved in spec**: `avdlz-in-use-*` tags written by rotation (§4.2) |
| H6 Device cleanup by name | **Resolved in spec**: IDs recorded from inside the host; cleanup by ID; the enrollment check moved in-host (§6.3, §6.5) |
| H7 Protected list and self-updating apps | **Resolved in spec**: an extended list plus functional checks; self-updating components listed; Defender platform to verify (§5.5, §5.6) |
| H8 Regions and subscriptions | **Resolved in spec**: a replica per environment region, a Reader grant per identity, a preflight check (§4.2) |
| H9 Clashes with the second brain | **Resolved in spec**: allowlisted on QA groups only (second brain spec §4.5); a stop through `manual` and the kill-switch workflow; QA log-off at 1 hour (§6.3, §6.5) |
| M1 Version names with leading zeros | **Resolved in spec**: `YYYY.MDD.N`, no padding, numeric comparison (§4.2) |
| M2 Concurrent builds | **Resolved in spec**: concurrency groups; one version validates at a time; newer supersedes (§5.1) |
| M3 Build VM size and timeout | **Resolved in spec**: a pinned 4-vCPU D-series size, 360 minutes, a quota check first (§5.2) |
| M4 WDOT archive stability | **Resolved, as built**: pinned by commit, with the SHA-256 of every file the build runs, so archive bytes don't matter. A function file not in the lock fails the build (§5.5) |
| M5 Validation before sysprep | **Resolved in spec**: generalization success checked from the run; the QA host named as the first post-sysprep evidence (§5.4) |
| M6 One replica during a surge | **Resolved in spec**: replicas per 20 hosts created at once; Deploy in batches (§4.2, §6.5) |
| M7 Orphaned templates | **Resolved in spec**: a sweep at the start of each build (§5.2 step 0) |
| M8 Read-only preflight | **Resolved in spec**: `-Profile ImageValidation`; checks it can't run are skipped, not failed (§6.3) |
| S1 Native session host update | **Resolved in spec**: the comparison and a revisit trigger in decision 0013; a note in §6.5; verified at each build phase (§11) |
| S2 Sign-in evidence in small deployments | **Resolved in spec**: the approver signs in to the QA desktop once and promotion waits for it; overrides recorded and counted; Q8 moved to build step 4 (§6.3, §6.4) |

## Next step

Every finding is resolved in the spec. What remains is verification: nothing here has run against a real tenant, and §11 of the spec lists what to confirm at build. Build step 1, then run a second red-team pass on the design as built, before rotation (step 3).
