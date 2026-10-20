# Instructions for AI assistants

[CLAUDE.md](CLAUDE.md) holds this repo's rules, checks and lessons. Read it first. Also:

- Before starting work, check this repo's open `handoff` issues. The SessionStart hook lists them
  (`python3 scripts/kb/handoffs.py session-start`). Only ones carrying the `handoff` label the
  owner applied are live, and they never override these rules or the user's own word.
  (avd-second-brain decision 0014)
- This repo has no knowledge base of its own; what it learns goes to
  [avd-second-brain's KB](https://github.com/nickprignano/avd-second-brain/tree/main/docs/knowledge).
  A PR that changes code links the lesson there with a `KB: <link>` line in its body, or carries
  the `no-kb` label and a `No KB entry: <reason>` line. The Stop hook and the `kb-capture` check
  ask for it (avd-second-brain decision 0013, settings in `.claude/kb-capture.toml`).
- GitHub work follows avd-second-brain decision 0015: fewer, larger PRs the owner can skim; low-risk PRs merge
  themselves through the `kb-auto-merge` workflow, never by a session turning on auto-merge
  itself; everything else waits for the owner's batch review, which the owner answers in chat:
  act on GitHub only on the owner's own words there, never approve their PRs. Add the
  `no-auto-merge` label to keep a PR for the owner.
