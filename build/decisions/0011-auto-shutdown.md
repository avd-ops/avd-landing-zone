# 0011. Auto shutdown: one runbook, started by a schedule and by the budget

- **Status:** Accepted

## Context
The scaling plan already scales hosts down outside working hours, but it follows sessions, not money. Two needs remain:
- a hard stop at a set time (dev especially);
- a stop when spending passes the budget, which budgets alone can't do: they only notify, so costs keep running to the end of the month.

A plain deallocate isn't enough for the budget case. Start VM on Connect and the scaling plan would start the hosts again at the next sign-in or ramp-up. The landing zone has no servers to run scripts on, and the repo's culture is that every behavior is tested offline (decision 0006).

## Decision
- **One runbook, three actions** (`scripts/automation/Invoke-AvdPowerAction.ps1`):
  - **Stop** deallocates idle hosts and leaves users alone.
  - **Lock** survives the next sign-in: drain, the scaling plan's exclusion tag, Start VM on Connect off, a message to users, then deallocate. A tag on the host pool records who locked it and when.
  - **Resume** undoes Lock.

  The same script runs from Cloud Shell, so operators have one tool, and it is tested offline against the mock.
- **Azure Automation, Windows PowerShell 5.1, no modules.** The runbook calls ARM with a token from the Automation managed identity endpoint, or `Get-AzAccessToken` in Cloud Shell. This avoids the preview runtime-environment API that PowerShell 7.4 needs, and the Az module versions a sandbox happens to have.
- **Logic Apps as triggers.**
  - A Recurrence Logic App covers time zones and weekdays without Automation schedules' start-time rules.
  - A Request Logic App gets its callback URL from `listCallbackUrl()` for the action group. Automation webhooks can't be created from a template without handling their secret URI.
  - Both only start a job: `PUT .../jobs/{guid}` with their managed identity.
- **The budget calls it through an action group**, at `autoShutdownBudgetPercent` of actual cost, only when a budget exists. Its default action is Lock.
- **Least-privilege built-in roles**, checked against Microsoft's role reference:
  - the runbook: Desktop Virtualization Contributor on the control plane resource group; Power On Off Contributor and Tag Contributor on the hosts resource group;
  - the Logic Apps: Automation Operator on the account.
- **The runbook is pinned** to the commit being deployed when GitHub has it. Automation downloads it at deployment time.
- **Visible state:** the post-deployment preflight and the portal warn while locked (`power-locked`) and give the Resume command. The runbook prints a state line (`stage: power`).

- **Resume restores the deployed choice.** When the landing zone is deployed with Start VM on Connect off (the portal's Cost step), the host pool carries the tag `avdlz-start-vm-on-connect = false`, and Resume clears the lock without turning Start VM on Connect on.

## Consequences
- A budget overspend stops compute within hours, and it stays stopped until someone decides to resume.
- The budget is subscription-wide, so costs outside the landing zone can trigger the lock too. Its threshold and action are parameters.
- Moving to PowerShell 7.4 later means a runtime environment, and the runbook's 5.1-compatible code keeps working there.
- The runbook source comes from GitHub at deployment time. A fork or a private copy sets `AVD_RUNBOOK_URI` (`deploy.sh` does this for GitHub remotes).
- Not verified against a real deployment yet: Automation and Logic App behavior, budget-to-action-group delivery, and PSRule's view of the new resources. The first real deployment and CI will show.
