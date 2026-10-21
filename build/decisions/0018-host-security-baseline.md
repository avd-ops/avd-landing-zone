# 0018. Check session hosts against a reviewed security baseline profile, as warnings

- **Status:** Proposed

## Context
avd-assess's security method (`methods/security.md`) says what a secure AVD estate looks like, and
its gap `host-baseline-profile` found no published baseline for Windows multi-session hosts:
Microsoft's security baselines target single-user devices, and the AVD guidance names the features
to turn on but no profile. The gap gives the landing zone the job of owning the profile it builds,
the way it owns its WDOT profile (`scripts/image/wdot`). Until now the landing zone checked host
security only from the outside: Trusted Launch and encryption at host in the Well-Architected
review, nothing from inside the host, and nothing about Secure Boot, vTPM or device redirection.

## Decision
- **`scripts/security/host-baseline.json`** is the reviewed profile: twelve controls, each with the
  value it reads, the expected test, who sets it (`windows`, `image` or `organization`), the
  avd-assess claims it rests on, and a remediation. Every control the landing zone leaves to the
  organization carries a `departure` saying why; a test refuses one without it.
- **`scripts/ops/host/Get-SessionHostSecurity.ps1`** reads the values on a host through Run
  Command (Windows PowerShell 5.1). It is read-only, judges nothing, and only counts local
  administrators, never names them.
- **`Get-AvdHostBaselineResult`** compares the two: pass, departure (recorded), gap (drift nobody
  recorded) or unknown (not reported), as the avd-assess gap defines them.
- **`Deploy-AvdDemo.ps1`** checks every demo host and reports anything but a pass as a warning
  (`host-baseline-<id>`, `data.outcome`), never a failure: the demo still works, and a host
  baseline is the organization's to finish.
- **The Well-Architected review** also requires Secure Boot and vTPM in `waf-host-security`, and a
  new `waf-redirection` warns when the host pool doesn't turn drive and USB redirection off, the
  same rule as avd-assess check `asm-drive-usb-redirection-off`.

## Consequences
- The profile is small on purpose: the controls the landing zone can read and explain. The full
  baseline comparison stays with the Intune or Security Compliance Toolkit baseline the
  organization applies.
- The values the controls expect on a fresh Trusted Launch host (VBS, Credential Guard and memory
  integrity on by default) come from Microsoft's documentation, not a run. LSA protection can be on
  without a `RunAsPPL` value, so the host script reports a missing value as unknown, not off, and
  the offline mock leaves it out the same way. The next sandbox run of the demo confirms all of
  them; a control that disagrees gets a fix and a lesson.
- A value the host can't read comes back with the host's error (`readErrors`), and a Run Command
  that fails is one warning for that host; neither stops the demo's other checks.
- Local administrators that are Entra SIDs (`S-1-12-1-*`) aren't counted: role-based admins and a
  directly added Entra user look the same from the host.
- avd-current-state doesn't read inside hosts, so these values aren't C11 facts yet. Adding them is
  a contract change that starts in avd-assess.
