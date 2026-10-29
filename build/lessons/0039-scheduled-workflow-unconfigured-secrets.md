# 0039. A scheduled workflow that needs secrets nobody has set yet must skip, not fail and open issues

- **Area:** CI
- **Found in / fixed by:** image-build run of 2026-10-19 (issue #51) / this PR

## What happened
The monthly golden image build ran on its schedule before the **images** environment had its Azure identity. `azure/login` stopped with:

```text
Login failed with Error: Using auth-type: SERVICE_PRINCIPAL. Not all values are present. Ensure 'client-id' and 'tenant-id' are supplied.
```

The issue step then opened "Image build: failed before a summary". Nothing could act on it: the issue was not a build failure, no later run would close it, and every third Monday until the setup was done would have opened another copy.

## Why
- Empty secrets expand to empty strings, so the workflow had no way to tell "not set up yet" from "broken".
- The issue step only ever created issues. It never looked for an open one with the same title, and a later good run never closed an earlier failure.

## Fix
- A first step checks the three secrets. When any is empty, a scheduled run skips the Azure steps, writes the setup steps to the run's summary and closes an open "failed before a summary" issue with a pointer to `docs/images.md`. A run started by hand fails, so a forced or emergency build that didn't happen never looks green.
- The issue logic moved to `scripts/ops/image-build-issue.cjs`. One failure issue stays open at a time: a later failure adds its full report as a comment, and a succeeded build closes it. "Unchanged" closes only the "failed before a summary" issue, since it proves the sign-in works but not that a failed version was fixed. Result issues for a built version stay open for the person who promotes it.

## Guard
`node --test "build/tests/workflows/*.test.mjs"`: the issue step against a fake GitHub API (open, comment instead of a duplicate, close on success, what unchanged and unconfigured runs may close), and the workflow's step conditions.

## Rule
A scheduled workflow that depends on optional setup checks for it first and skips cleanly, with the setup steps in the step summary. Every workflow that opens an issue on a schedule also has the path that closes it.
