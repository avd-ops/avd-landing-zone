# 0040. `int(readEnvironmentVariable(...))` in `.bicepparam` widens to `int` and fails `BCP033` against `@allowed`

- **Area:** Bicep parameters
- **Found in / fixed by:** PR #132

## What happened
With `AVD_TRIPWIRE_ALERT_MINUTES=15` set in the environment, `bicep build-params parameters/dev.bicepparam --stdout` failed in CI:

```text
parameters/dev.bicepparam(90,30) : Error BCP033: Expected a value of type "0 | 15 | 30 | 5" but the provided value is of type "int". [https://aka.ms/bicep/core-diagnostics#BCP033]
```

## Why
In Bicep parameter files, `empty(readEnvironmentVariable('AVD_TRIPWIRE_ALERT_MINUTES', '')) ? 0 : int(readEnvironmentVariable('AVD_TRIPWIRE_ALERT_MINUTES', ''))` compiles when the environment variable is unset or empty because the false branch is not selected, or narrows to `0`. When the environment variable is non-empty, `int(readEnvironmentVariable(...))` has static type `int` rather than the literal union required by `@allowed([0, 5, 15, 30])` in `bicep/main.bicep`.

## Fix
Map the environment variable string to literal integers in the `.bicepparam` expression so every branch of the ternary belongs to the `@allowed` union:

```bicep
param tripwireAlertMinutes = readEnvironmentVariable('AVD_TRIPWIRE_ALERT_MINUTES', '') == '5' ? 5 : (readEnvironmentVariable('AVD_TRIPWIRE_ALERT_MINUTES', '') == '15' ? 15 : (readEnvironmentVariable('AVD_TRIPWIRE_ALERT_MINUTES', '') == '30' ? 30 : 0))
```

## Guard
`build/tests/Template.Tests.ps1`: `Estate tripwires (avd-swarm/docs/tripwires.md)` sets `AVD_DEPLOY_TRIPWIRES='true'`, `AVD_TRIPWIRE_SECRET_NAME='svc-legacy-sql-ro'`, and `AVD_TRIPWIRE_ALERT_MINUTES='15'` and compiles `parameters/dev.bicepparam`, `parameters/test.bicepparam`, and `parameters/prod.bicepparam`.

## Rule
When a `.bicepparam` reads an environment variable for an integer parameter constrained by `@allowed([...])`, return literal integers from a comparison ternary instead of calling `int(readEnvironmentVariable(...))`.
