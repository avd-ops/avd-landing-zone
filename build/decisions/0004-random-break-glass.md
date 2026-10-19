# 0004. Random break-glass password, applied at host creation

- **Status:** Accepted

## Context
A required, stable password was forgotten after the first run (lesson 0002).

## Decision
`deploy.sh` generates a random password unless one is supplied. It is stored in Key Vault for the hosts created by that deployment; VM > Reset password is the recovery path for any host.

## Consequences
Nothing to remember. The Key Vault secret describes the newest hosts only, which the docs state.
