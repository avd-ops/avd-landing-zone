# 0028. Azure Files denies Entra Kerberos sessions when AES-256-GCM is the only channel encryption

- **Area:** Bicep
- **Found in / fixed by:** PR #45

## What happened
FSLogix failed for every cloud-only user on the demo host pool with "Access is denied" (Status 0x1B, Reason 0x5, Error 0x5). `klist get cifs/<storage>.file.core.windows.net` returned a valid AES-256 ticket from `KERBEROS.MICROSOFTONLINE.COM`, admin consent, the `kdc_enable_cloud_group_sids` tag, the Conditional Access exclusion and the SMB Share Contributor roles were all in place, and `net use` still failed. A packet capture showed NEGOTIATE succeeding on SMB 3.1.1 and the SESSION_SETUP response coming back `STATUS_ACCESS_DENIED (0xC0000022)` with an empty security blob. Turning Security Defaults off made no difference.

## Why
The storage module hardened SMB to `channelEncryption: 'AES-256-GCM;'`. A bisect on the live account, one setting relaxed at a time, from the session host:

| Setting relaxed | SESSION_SETUP |
|---|---|
| Ticket encryption RC4 + AES-256 | 0xC0000022 |
| Channel encryption AES-128-CCM, AES-128-GCM, AES-256-GCM | 0x00000000, share listed |
| Authentication Kerberos + NTLMv2 | 0xC0000022 |
| Versions SMB 2.1, 3.0, 3.1.1 | 0xC0000022 |

Only the channel encryption change let the users in. Ticket encryption, authentication method and SMB versions are not the cause.

## Fix
`bicep/modules/storage.bicep` allows `AES-128-GCM;AES-256-GCM;`. CCM stays off, so channel encryption is still GCM only. Ticket encryption stays AES-256 and authentication stays Kerberos only. The readiness check reads the file service through REST and fails when AES-128-GCM is missing, so a landing zone deployed before this fix is caught.

## Guard
- Template test *Profile share SMB channel encryption*: the compiled template allows AES-128-GCM and AES-256-GCM, and no CCM. Fails against the old value.
- Readiness check *Profile share allows AES-128-GCM channel encryption*, with the PostDeployment scenario's `smb-channel` case (AES-256-GCM only must fail and leave the state `notready`).

## Rule
Hardening an SMB setting on an Entra Kerberos share needs a real sign-in from a cloud-only user before it ships. When the ticket is good and SESSION_SETUP is denied, bisect the share's SMB settings one at a time before chasing identity.
