---
name: retro
description: Turn a real-run failure or surprise into a lesson plus a guard so it never costs a second round. Use after a deployment, preflight, demo or cleanup run behaved differently from what the code or tests expected, after a CI failure that local checks missed, or when the user says "retro", "capture this", "lesson learned" or "don't let this happen again".
---

# Retro: lesson + guard

A finding is only captured when something automated would fail if it came back. Work through all steps; skip one only with a stated reason.

## 1. Pin the evidence
- A `portal-report` issue (from the deployment portal) already has the output, redacted, and what the portal made of it. Before copying any of it into the repo, check it for private values the redaction missed. If you find one, that is a finding too: add a pattern to `site/portal/report.js` and a line to `build/tests/portal/fixtures/pii-sample.txt`.
- Quote the real output: the failing line, error code, status and headers. If the output doesn't say *why*, the first fix is better diagnostics (lesson 0012), not a guess.
- Check `build/lessons/README.md` for an existing lesson in the same area. If one exists, extend it instead of adding a new one.

## 2. Fix the root cause
- Fix the code. Keep it minimal.
- If `build/tests/offline/AzMock.psm1` let the bug through, make the mock behave like Azure did.

## 3. Add the guard (pick the strongest that fits)
| Finding is in | Guard |
|---|---|
| Bicep / compiled template | `build/tests/Template.Tests.ps1`: compile the parameter files and assert on the nested deployment |
| A pure function in `AvdLandingZone.psm1` | `build/tests/AvdLandingZone.Tests.ps1` with `Mock -ModuleName AvdLandingZone` |
| A flow across scripts, or an Azure behavior | a new or extended `build/tests/offline/<Name>.Scenario.ps1` (print `RESULT <step> ...`) plus assertions in `build/tests/OfflineScenarios.Tests.ps1` |
| Something to check in the customer's subscription | a preflight check (`Add-AvdCheckResult`) with a remediation, and `-Fix` if it can be fixed safely |
| Process or operator behavior | a rule in `CLAUDE.md` |

Prove the guard works: break the fix temporarily and confirm the guard fails, then restore it.

## 4. Write the lesson
- Copy `build/lessons/TEMPLATE.md` to `build/lessons/NNNN-<slug>.md` (next number). Fill in all six sections. The Rule is one or two sentences someone can follow next time.
- Add a row to the index in `build/lessons/README.md`, with a short Guard label.
- If it changes a standing rule, add or update the line in `CLAUDE.md` and cite the lesson number.
- If it reflects a design choice, add a record in `build/decisions/`.
- If operators should know it, add it to `docs/gotchas.md` too.

## 5. Ship
- Run the checks in `CLAUDE.md` ("Validate before pushing").
- In the PR description, fill in the **Lessons** section: the lesson number and the guard.
