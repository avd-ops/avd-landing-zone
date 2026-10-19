# 0014. Validate cmdlet parameter sets

- **Area:** Ops scripts
- **Found in / fixed by:** PR #5

## What happened
`Get-AzRoleAssignment -Scope ... -ExpandPrincipalGroups` failed in Cloud Shell: the combination is not a valid parameter set.

## Why
Parameter sets were assumed, not checked; the mock accepted any parameters.

## Fix
Filter by scope after `-ExpandPrincipalGroups`; all call sites were checked against the Az help.

## Guard
None automated (the one-off validator was not committed).

## Rule
Check every new Az/Graph cmdlet call against its documented parameter sets; mocks must not be more permissive than the real cmdlet.
