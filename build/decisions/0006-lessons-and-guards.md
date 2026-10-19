# 0006. Every real-run finding becomes a lesson and a guard

- **Status:** Accepted

## Context
The same classes of mistake cost several rounds each (lesson 0012) and were rediscovered across sessions.

## Decision
When a real run fails for a reason the tests didn't catch: fix it, write a lesson (`build/lessons`), add a guard (a Pester test, an offline scenario in `build/tests/offline`, a template test or a preflight check), and list it in the index. `CLAUDE.md` carries the standing rules; the SessionStart hook prints the index into every Claude session; the retro skill is the routine; the PR template asks for it.

## Consequences
CI fails if a known failure returns. Lessons without an automated guard say why.
