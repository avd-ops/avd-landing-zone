# 0042. Referencing a module loop `.outputs` inside a `var` comprehension fails `BCP182`

- **Area:** Bicep
- **Found in / fixed by:** `cm-resource-parent` tag wiring (`bicep/main.bicep`)

## What happened
While wiring `hostPoolResourceId: additionalControlPlanePools[i].outputs.hostPoolResourceId` into `var extraPoolHostSpecs` in `bicep/main.bicep` so `registerPoolHosts.bicep` could stamp `cm-resource-parent` on additional-pool run commands, `bicep lint bicep/main.bicep` failed with `Error BCP182: This expression is being used in an assignment to the "extraPoolHostSpecs" variable, which requires a value that can be calculated at the start of the deployment. Properties of additionalControlPlanePools which can be calculated at the start include "name".`

## Why
Bicep variables (`var`) compile into the ARM template `variables` section, which Azure Resource Manager evaluates at deployment start before any nested `Microsoft.Resources/deployments` module runs. While a `module` `params` block can reference `additionalControlPlanePools[i].outputs.*` (producing an ARM `[reference(...)]` expression and implicit `dependsOn`), a `var` comprehension cannot reference runtime module `.outputs`.

## Fix
Construct the deterministic `hostPoolResourceId` inside `var extraPoolHostSpecs` from `subscription().subscriptionId`, `names.rgControlPlane`, and the same host pool name expression used by `additionalControlPlanePools[i]`, while keeping `dependsOn: [sessionHosts, additionalControlPlanePools]` on `registerAdditionalPoolHosts`.

## Guard
`bicep lint bicep/main.bicep` in CI and `build/tests/Template.Tests.ps1` (`stamps cm-resource-parent with the parent host pool resource ID on session host VMs and run commands`).

## Rule
Never reference `module.outputs.*` inside a Bicep `var` declaration; either pass `module.outputs.*` directly in a downstream `module` `params` block or compute deterministic ARM resource IDs from subscription, resource group, and resource name expressions.
