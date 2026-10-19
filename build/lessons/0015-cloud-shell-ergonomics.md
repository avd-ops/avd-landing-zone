# 0015. Commands for Cloud Shell must stand alone

- **Area:** Operator experience
- **Found in / fixed by:** PR #10-#16

## What happened
Runs failed because the folder, variables or Graph sign-in from an earlier session were gone; `Cmd+C` was taken for cancel; switching apps disconnected the session.

## Why
Cloud Shell sessions are ephemeral and disconnect when the tab loses focus; in the browser terminal `Cmd+C` copies.

## Fix
Every command block we give starts with clone-or-update, `Set-Location` and (when needed) `Connect-MgGraph`; `deploy.sh` and the preflight print the exact next command.

## Guard
None automated; `CLAUDE.md` states the rule.

## Rule
Give operators self-contained blocks. Long operations must survive a disconnect (ARM deployments do) and say how to check on them.
