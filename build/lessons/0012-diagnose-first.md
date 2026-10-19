# 0012. Surface the error before guessing a fix

- **Area:** Process
- **Found in / fixed by:** PR #13-#16

## What happened
The share ACL failure took four PRs: three changed behavior on guesses before the error said what was wrong.

## Why
The first version reported only the exception message (`(400) Bad Request`).

## Fix
Each round added diagnostics until the response headers showed the cause.

## Guard
`build/lessons` + the retro skill (`.claude/skills/retro`).

## Rule
When a real run fails in an external API, the first change is to report everything the API returned. Change behavior only once the evidence names the cause.
