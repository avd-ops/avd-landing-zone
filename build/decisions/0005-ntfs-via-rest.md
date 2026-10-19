# 0005. Set the profile share root ACL through the Azure Files REST API from a session host

- **Status:** Accepted

## Context
The share is private and SMB-only, shared keys are disabled, and Cloud Shell cannot reach it. Setting the FSLogix root ACL by hand needs an admin signed in on a host.

## Decision
The preflight grants the host's managed identity a temporary Storage File Data Privileged role, then runs a script through Run Command that reads and sets the root security descriptor with backup intent, and removes the role again. A root without a permission key is treated as the default ACL (lesson 0011).

## Consequences
Fully automated post-deployment step with no keys or user tickets. It depends on API details learned in real runs; the offline DefaultShareRoot scenario pins them.
