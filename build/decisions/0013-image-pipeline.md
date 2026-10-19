# 0013. A generic golden image built by Azure Image Builder, promoted by a person, rotated blue/green

- **Status:** Proposed

## Context
Session hosts come from the marketplace image at `latest`, so two hosts deployed a week apart can differ, and nobody can say which build a host runs. Replacing hosts is a manual procedure. The second brain's `replace-host` playbook, its detections and its baselines need a known image, and the owner decided to build the image pipeline before the second brain (second brain spec Q6).

## Decision
As specified in [image-pipeline-spec.md](../specs/image-pipeline-spec.md):
- **Azure Image Builder, not Packer.** It is Azure-native, defined in Bicep, and runs with a managed identity. That keeps the project to one language.
- **The image is generic.** Updates and a few settings go in. Nothing tenant- or landing-zone-specific does: share paths, tokens, joins and the AVD agent stay with the existing Run Commands. One version serves every environment and adopter.
- **Built monthly and validated automatically; a person promotes to production pools.**
  - A version stays excluded from `latest` until automated validation passes in `test`'s and then `prod`'s QA pools, each with a 24-hour soak. The checks need no user credentials: the preflight, the readiness checks, in-host function checks, and posture as warnings.
  - A failure rolls the QA pool back automatically.
  - Real sign-ins come from QA users and are shown at promotion. Promotion without any needs an acknowledgment.
  - The automation's identity reaches only the QA resource groups. It is registered as pre-approved exception EX-0005.
  - Each host pool records the image version and host generation it runs in its own tags. Only the rotation script writes them, and every deployment reads them, so a routine redeploy can't change a running pool's image or recreate removed hosts. The marketplace image stays the default.
  - QA hosts come from their own template, scoped to the QA resource group. QA users must be regular users, not admins.
  - Builds read their scripts from a private storage container, so adopters' private forks work.
  - Patch targets: 14 days after Patch Tuesday, and 72 hours for critical out-of-band fixes, with an emergency mode that shortens the soaks.
- **WDOT on every build:** pinned by version and SHA-256, with a reviewed profile in Git. Services the landing zone needs (Intune push, Defender, Windows Update, search, the RDP stack) are protected by a test and by a build-time check. Appx removal and WDOT's advanced optimizations are off by default.
- **Hosts don't update themselves:** Windows and Microsoft 365 Apps automatic updates are off, per Microsoft's golden image guidance. Patches come through the monthly image. Defender signatures and the AVD agent keep updating.
- **A one-host QA pool in every landing zone** (`AVD_QA_POOL`, on by default). It is a validation environment with an earlier agent update window, the canary for each new image in each environment, and the place for maintenance work. It is a production twin, so it doesn't update itself either.
- **Blue/green rotation** through alternating name generations, by a resumable Cloud Shell script. Its state lives in a host pool tag. It never logs users off unless the operator opts in, and it removes old VMs, session host objects and device objects.
- **Builds run in the build environment's spoke,** reusing its egress, with no public IP. Customizer scripts are pinned by commit and SHA-256.

## Alternatives considered
- **Packer instead of Azure Image Builder:** a second language and toolchain to maintain, for a project with one maintainer.
- **Azure Virtual Desktop session host update (session host configuration) instead of the rotation script.** It is Microsoft's native way to replace hosts with a new image, and it overlaps the rotation script. Published guidance at the time of writing says it doesn't support Microsoft Entra ID-joined hosts, which this landing zone uses exclusively (decision 0001), and that it applies to host pools created with it. **Revisit trigger:** when Microsoft documents support for Entra ID-joined hosts and for adopting an existing host pool, migrate rotation to the native feature and keep the image build, validation, QA pools and promotion. The spec checks this at every build phase.
- **An acknowledgment instead of a sign-in at promotion:** in small deployments it would become a routine click. The approver signs in to the QA desktop once instead, and skipping that is a recorded, counted override.

## Consequences
- Every host's software traces to a commit, a source image version and a build run. Patching becomes a monthly, reviewable promotion.
- One more host per landing zone for the QA pool, counted by the quota and price checks. It only helps if a couple of people sign in to it every day, so the preflight warns when nobody has. When nobody has, promotion waits for one sign-in by the approver.
- Rotation needs vCPU quota for a second set of hosts while it runs. Without it, rotation stops at its first check instead of shrinking capacity.
- A gallery, replicas and a build VM per month to pay for, priced at deploy (decision 0010).
- Not verified against a real deployment yet; the spec lists what to confirm at build.
