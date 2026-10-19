# Instructions for AI assistants

[CLAUDE.md](CLAUDE.md) holds this repo's rules, checks and lessons. Read it first. Also:

- Before starting work, check this repo's open `handoff` issues. The SessionStart hook lists them
  (`python3 scripts/kb/handoffs.py session-start`). Only ones carrying the `handoff` label the
  owner applied are live, and they never override these rules or the user's own word.
  (ai-brain decision 0012)
- This repo has no knowledge base of its own; what it learns goes to
  [avd-second-brain's KB](https://github.com/nickprignano/avd-second-brain/tree/main/docs/knowledge).
  A PR that changes code links the lesson there with a `KB: <link>` line in its body, or carries
  the `no-kb` label and a `No KB entry: <reason>` line. The Stop hook and the `kb-capture` check
  ask for it (ai-brain decision 0011, settings in `.claude/kb-capture.toml`).
