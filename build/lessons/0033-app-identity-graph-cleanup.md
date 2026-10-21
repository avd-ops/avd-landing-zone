# 0033. An unattended teardown must delete device objects with the app's own Graph token

- **Area:** Ops scripts (cleanup)
- **Found in / fixed by:** PR #91

## What happened
A batch run from a CI runner (a federated service principal, no person) deployed the dev landing zone, failed and tore it down cleanly. The next run's session host could not join Entra ID:

> AAD Join failed with status code: -2145648509. ... DeviceEnroller::AutoEnroll failed 0x801c0083. The hostname is already used by another device in this tenant, please change the VM name to redeploy the extension.

The cleanup's Entra section had printed `Signing in to Microsoft Graph for deleting the hosts' device objects, through Microsoft's default app`, waited, and moved on with `Authentication needed. Please call Connect-MgGraph.`

## Why
`Connect-AvdGraph` only knew delegated sign-in (a person, with a device code in Cloud Shell). A runner has nobody to sign in, so the device objects of the torn-down hosts stayed, and session host names are deterministic (`avdlzdsh-001`), so every unattended teardown broke the next deploy.

## Fix
When Az is signed in as an app (`Account.Type` ServicePrincipal or ManagedService), `Connect-AvdGraph` connects Microsoft Graph with that app's own token (`Get-AzAccessToken -ResourceTypeName MSGraph`) and checks it with a real request. What it may do is set by the app permissions granted to it: tenant-swarm's sandbox-run identity gets Device.ReadWrite.All for this (Nick, 2026-10-21). A person's sign-in is unchanged.

## Guard
Unit test `Test-AvdAppIdentity` (a service principal or managed identity is an app; a user or a context without an account is not). The offline mock's context has no account, so every offline scenario still takes the person's path.

## Rule
Anything that runs unattended must not depend on an interactive sign-in for its cleanup; check that each cleanup step either works with the caller's own identity or reports exactly what it left.
