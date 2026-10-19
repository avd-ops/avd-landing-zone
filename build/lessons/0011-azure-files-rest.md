# 0011. Azure Files REST with OAuth: x-ms-date and the share root

- **Area:** NTFS step
- **Found in / fixed by:** PR #13 #14 #15 #16

## What happened
The profile share ACL step failed with `400 Bad Request`, then `MissingRequiredHeader`, then "no x-ms-file-permission-key".

## Why
Get/Create Permission require `x-ms-date`. The root of a new share has never had an ACL set, so Get Directory Properties returns SMB properties but no permission key; the empty key was then dropped from the next request. Windows PowerShell 5.1 keeps the error XML on the response stream; PowerShell 7 puts tag-stripped text in `ErrorDetails`.

## Fix
Send `x-ms-date` on every request; a missing key means the default ACL (a finding, fixed by `-Fix`); errors report step, status, error code, message, header name and resolved IP.

## Guard
Offline DefaultShareRoot scenario; Pester error-reporting tests.

## Rule
For host-side REST calls, capture the full error (status, `x-ms-error-code`, body, which step) from the first version. See 0012.
