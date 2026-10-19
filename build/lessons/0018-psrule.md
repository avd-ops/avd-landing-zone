# 0018. PSRule for Azure specifics

- **Area:** CI
- **Found in / fixed by:** PR #3

## What happened
PSRule reported 31 findings and some suppressions did not apply.

## Why
`Azure.Storage.FileShareSoftDelete` wants exactly 7 days; suppressions must match on `field: type`; `az bicep install` does not put Bicep where PSRule looks.

## Fix
Suppressions in `.ps-rule/`; standalone Bicep with `PSRULE_AZURE_BICEP_PATH`.

## Guard
CI PSRule job (a gate).

## Rule
Suppress with a reason and a narrow selector; point PSRule at an explicit Bicep binary.
