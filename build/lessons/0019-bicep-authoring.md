# 0019. Bicep authoring traps

- **Area:** Bicep
- **Found in / fixed by:** PR #2

## What happened
Build and lint errors while writing the template.

## Why
A for-loop cannot use runtime values for resource names (BCP178); `backupFabrics` has no Bicep types; the `use-resource-id-functions` linter rejects built-in policy IDs as strings; `readEnvironmentVariable` defaults can break `minLength` on secrets.

## Fix
Direct references; full-name child resources; `existing` policy definitions; no defaults for secret variables (fail fast).

## Guard
CI Bicep lint + build (security rules are errors).

## Rule
Keep `bicepconfig.json` strict and fix the cause rather than suppressing a rule.
