# 0001. Entra ID-only, greenfield, private by default

- **Status:** Accepted

## Context
Microsoft's AVD Landing Zone Accelerator covers every identity model and brownfield case through a large option surface.

## Decision
This repo takes one path: Entra ID-joined, Intune-managed session hosts, Azure Files with Entra Kerberos, Private Link, no domain controllers and no line of sight to on-premises. Options that would reintroduce AD DS or hybrid networking are out of scope.

## Consequences
A smaller surface that can be hardened and tested end to end. Organizations that need AD DS use the accelerator. Details: [design-decisions.md](../../docs/design-decisions.md), [out-of-scope.md](../../docs/out-of-scope.md).
