# WDOT profile for the golden image

The image build runs the [Windows Desktop Optimization Tool](https://github.com/The-Virtual-Desktop-Team/Windows-Desktop-Optimization-Tool) (WDOT, MIT License, by The Virtual Desktop Team) with this profile. See `build/specs/image-pipeline-spec.md` §5.5.

WDOT is the family's one image optimization tool: avd-current-state reads the pin back from the image version's tags, and avd-assess judges images against this reviewed profile. Its repository's `LICENSE` is MIT, while its README and `EULA.txt` describe Microsoft's sample code terms (illustration only, as is, test before production). The build passes `-AcceptEULA`, so running the image pipeline accepts those terms; read them before your first build.

- **`wdot.lock.json`** pins WDOT to a commit (release `v1.1`) and records the SHA-256 of every WDOT file the build runs. `Invoke-Wdot.ps1` downloads the commit's archive and refuses to run if any file's hash differs. A newer WDOT is a PR that updates the lock. The archive itself isn't pinned by hash, because GitHub doesn't promise stable archive bytes; the files are what run.
- **`profile/`** holds the JSON files WDOT reads, generated from WDOT's `Configurations/Templates` at that commit (each item's `OptimizationState` set as below, written as indented JSON with ASCII escapes; lesson 0027 records how they were rebuilt). Every item's `OptimizationState` was reviewed. `profileSha256` in the lock covers them: a profile change without a lock update fails CI (`build/tests/ImageScripts.Tests.ps1`).

## What runs

`Windows_Optimization.ps1 -ConfigProfile avdlz -Optimizations Services,ScheduledTasks,Autologgers,DefaultUserSettings -AcceptEULA`

| Category | Run | Items applied | Kept `Skip`, and why |
|---|---|---|---|
| Services | Yes | 19 of 23 | `InstallService` (Store and MSIX installs), `DiagTrack` (Defender for Endpoint's sensor uses it), `VSS` (backup and restore tooling), `WerSvc` (crash reports are evidence for diagnosis) |
| ScheduledTasks | Yes | 26 of 29 | `NotificationTask`, `VerifyWinRE`, `Restore` |
| Autologgers | Yes | 6 of 7 | `Mellanox-Kernel`: Azure accelerated networking uses Mellanox adapters |
| DefaultUserSettings | Yes | 53 of 60 | Edge update suppression (Edge keeps updating, spec §5.6); toast notification blocks and hidden tray icons (Teams and Outlook need them); Copilot (an organization's policy choice, not a performance setting) |
| LocalPolicy (`PolicyRegSettings.json`) | **No** | 0 of 147 | Not reviewed yet: 147 policy settings, each an organization-level choice |
| NetworkOptimizations (`LanManWorkstation.json`) | **No** | 0 | Besides the SMB client settings, WDOT also changes the network adapter's send buffer, which on Azure is the accelerated networking adapter. Not verified |
| DiskCleanup | **No** | — | It deletes every `*.log`, `*.etl` and `*.evtx` on `C:` and empties `C:\Windows\Temp`: the build's own evidence, before `Test-GoldenImage.ps1` reads it. `Invoke-ImageCleanup.ps1` cleans up instead, narrowly |
| AppxPackages | **No** | 0 of 56 | Removing Appx packages is the classic sysprep breaker (spec §5.5, Q6) |
| WindowsMediaPlayer, Edge, RemoveLegacyIE, RemoveOneDrive | **No** | — | Spec §5.5 |

None of the services the landing zone depends on (spec §5.5: `dmwappushservice`, Defender, `wuauserv`, `BITS`, `WSearch`, `LanmanWorkstation`, `KeyIso`, `TokenBroker`, `AppXSvc`, `ClipSVC`, Edge Update and the RDP stack) is in WDOT's `Services.json` at this commit. A test keeps it that way, and `Test-GoldenImage.ps1` checks them again on the built image.

## How a run is verified

WDOT returns without an error when it skips work, so the build never takes its return as success ([lesson 0031](../../../build/lessons/0031-wdot-returns-without-error.md)). `Invoke-Wdot.ps1` creates WDOT's event log first (v1.1 can't on Windows PowerShell 5.1), runs WDOT, prints every warning and error, and then requires, from the `verify` block of the lock:

- a fresh `LastRunTime` and the lock's `toolVersion` under `HKLM:\SOFTWARE\WDOT`;
- WDOT's start and end events, an Information event for each category it runs (`categoryEvents`), and no run-level error event (`fatalEventIds`);
- every service `Services.json` applies, where the machine has it, set to `Disabled`, unless WDOT reported it couldn't change it. A WDOT event source already registered to another log fails the step before WDOT runs.

Anything missing fails the build's `wdot` step with the list of problems. A newer WDOT updates `toolVersion` and the `verify` block in the same PR as the files, and drops `knownErrors` entries it fixes.

## Changing the profile

1. Edit the JSON (`Apply` or `Skip`), and say why in the table above.
2. Update `profileSha256` in `wdot.lock.json`. The test prints the expected value when it fails.
3. Raising capability, such as running a new category, is a guardrail change (second brain spec §9.2): in solo mode it waits for the time-lock.
