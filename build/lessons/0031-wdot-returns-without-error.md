# 0031. WDOT returns without an error when it skips work, so its return is never proof it ran

- **Area:** Image pipeline
- **Found in / fixed by:** reading WDOT v1.1 at the pinned commit (no real build has run v1.1 yet); fixed by this PR

## What happened
`Invoke-Wdot.ps1` ran `Windows_Optimization.ps1` and recorded `WdotResult = Succeeded` whenever the call returned, and `Test-GoldenImage.ps1` trusted that marker. Nothing checked that WDOT had changed anything. Reading WDOT v1.1 (`f20d6b7`, the pinned commit) turned up three ways it returns normally while doing little or nothing.

## Why
- **Its event log is never created on Windows PowerShell 5.1.** WDOT creates its log with `New-EventLog -Source $EventSources @EVT`, and `$EVT` holds `Source` too. Overriding a splatted parameter is a PowerShell 7.1 feature ([about_Splatting](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_splatting)); WDOT requires Windows PowerShell (`#Requires -PSEdition Desktop`), where the duplicate is a parameter binding error. The same call sits in both branches (log missing or present), so no rerun fixes it. With no log, every `Write-EventLog ... -ErrorAction SilentlyContinue` is lost, and the one unsilenced call, in `Disable-WDOTService`, throws inside its `try`, so **all services are skipped with only a warning**. Under the wrapper's `$ErrorActionPreference = 'Stop'` the binding error more likely stops WDOT before any optimization, which fails the build: loud, but the image pipeline could never pass. Upstream fixed both calls on `main` (`-LogName 'WDOT'` instead of `@EVT`) after v1.1, with no release yet. Inferred from the code and the documented binding rules; not yet seen on a VM.
- **`return` in `Begin` doesn't stop the script.** A missing `-ConfigProfile` folder logs event 100 and `return`s from `Begin`, but an advanced script still runs `Process` (checked in PowerShell 7.4; it's the same in 5.1), so every category then runs from the wrong folder.
- **A missing profile file is a warning.** Each category checks `Test-Path` for its JSON file and, when it's absent, writes a warning (or an error event that may not land) and returns. WDOT itself never sets an exit code or throws.

## Fix
- The build creates the `WDOT` event log and all its sources (`Initialize-AvdWdotEventLog`, from `verify.eventSources` in the lock) before running WDOT, so v1.1's own events land, and runs WDOT with `$ErrorActionPreference = 'Continue'` so its refused `New-EventLog` call (`ParameterAlreadyBound`, listed in `verify.knownErrors`) doesn't stop it. Every error and warning WDOT produced is printed.
- `Get-AvdWdotRunProblem` (pure, in `Invoke-Wdot.ps1`) then judges what the run left behind: a fresh `LastRunTime` under `HKLM:\SOFTWARE\WDOT` (the build removes the old one first) with the lock's `toolVersion`; the start and end events; an Information event for every category the lock runs (`verify.categoryEvents`); no run-level error events (`verify.fatalEventIds`); and every service the profile disables that the machine has is `Disabled`, or WDOT reported a failure for it (a warning, an error or an error event). A WDOT source already registered to another log fails the step before WDOT runs, since its events would land elsewhere. Per-item error events (a scheduled task the SKU doesn't have) are counted and printed, not fatal.
- Any problem sets `WdotResult = Failed` with `WdotProblems` and throws, so the build step fails. `Test-GoldenImage.ps1` shows the item errors and problems in its `wdot` line.
- The pin stays at release v1.1: moving to an untagged commit is a separate choice, and the check above works on either.

## Guard
`build/tests/ImageScripts.Tests.ps1`, "WDOT run verification": a good run passes, and a missing stamp, another version, an empty event log, an early stop (event 100), a skipped category, an entry with no level, and a still-enabled service with no warning each fail. A text guard fails if the script records `Succeeded` without the check.

## Rule
Never record success from a third-party tool's return alone: check the stamp and the evidence it leaves, and that the change it was asked to make is there. Read the tool's error handling at the pinned commit before trusting it.
