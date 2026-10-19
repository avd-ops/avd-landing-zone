# 0002. Call ARM and Graph REST when a cmdlet reshapes or blocks

- **Status:** Accepted

## Context
Several Az cmdlets behaved differently from their REST APIs in real runs: one object per region (lesson 0005), blocking registration (0006), invalid parameter combinations (0014).

## Decision
Ops scripts go through `Invoke-AvdArm` (`Invoke-AzRestMethod`) and `Invoke-AvdGraph` (`Invoke-MgGraphRequest`, the only Graph module needed) wherever the cmdlet's shape or behavior matters. Cmdlets stay where they are simple and verified.

## Consequences
Predictable shapes and non-blocking calls, and a single small Graph dependency. The offline mock (`build/tests/offline/AzMock.psm1`) implements the REST paths the scripts use.
