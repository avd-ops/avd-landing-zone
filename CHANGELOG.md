# Changelog

All notable changes, in the format of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). New lines come from the `Changelog:` line in each merged pull request's body; earlier history is in the merged pull requests and `build/lessons`.

## Unreleased

### Added

- Same-tenant recovery (`build/specs/recovery-spec.md`): `Get-AvdRecoveryStatus.ps1` (tiers R0 and R1, the portal's Recovery stage), `Export-AvdConfiguration.ps1` (configuration snapshot with drift), `Start-AvdRecoveryTest.ps1` (profile restore into a new storage account, plan first, cleanup with evidence), `Test-AvdRecoveryCopies.ps1` (monthly read-back of copies), and an opt-in vaulted profile backup tier (`profileBackupTier = 'Vaulted'`: geo-redundant vault with Cross Region Restore). Offline-tested only.
- The second brain's docs consistency check on every PR (`.github/workflows/docs.yml`, pinned), reference pages for the entry points and Bicep templates in `docs/reference/`, and the README's entry point table.

### Changed

- The vendored contracts (`contracts/`) move to avd-second-brain commit `fccd644`: the fact register gains the group-behavior privacy class and its facts.
