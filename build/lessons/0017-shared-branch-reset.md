# 0017. Don't reset the shared branch over an unmerged PR

- **Area:** Git
- **Found in / fixed by:** PR #12 #13

## What happened
Twice, restarting the working branch from `master` would have dropped an open PR's commit (caught before pushing).

## Why
Every PR comes from the same branch; resetting it to `master` discards commits not yet merged.

## Fix
Rebuilt the change on top of the open PR's commit and updated that PR.

## Guard
`CLAUDE.md` rule.

## Rule
Before `git checkout -B <branch> origin/master`, run `git merge-base --is-ancestor origin/<branch> origin/master`; if it fails, the branch has unmerged work: build on it.
