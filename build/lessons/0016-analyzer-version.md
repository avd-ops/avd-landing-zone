# 0016. CI's PSScriptAnalyzer is newer than yours

- **Area:** CI
- **Found in / fixed by:** PR #14

## What happened
CI failed on `PSUseShouldProcessForStateChangingFunctions` and `PSUseSingularNouns` for a helper that passed locally.

## Why
CI installs the latest analyzer; the local copy was older and did not enforce those rules for script-level functions.

## Fix
Renamed the helper (`Get-FileRequestHeader`); the session hook installs the same analyzer version as CI.

## Guard
CI PSScriptAnalyzer; `.claude/hooks/session-start.sh`.

## Rule
Use approved verbs (`Get-` for anything that only builds data) and singular nouns; lint with the CI version.
