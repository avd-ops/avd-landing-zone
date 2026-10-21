# Compatibility rules for the operator scripts in scripts/ops (CI, after the main analyzer pass).
# They run in Cloud Shell, on Windows, macOS and Linux with PowerShell 7.2 or later
# (avd-ops docs/run-anywhere.md); the bundled 7.0 profiles stand in for 7.2.
@{
  IncludeRules = @('PSUseCompatibleSyntax', 'PSUseCompatibleCommands', 'PSUseCompatibleTypes')
  Rules        = @{
    PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('7.0') }
    PSUseCompatibleCommands = @{
      Enable         = $true
      TargetProfiles = @('ubuntu_x64_18.04_7.0.0_x64_3.1.2_core', 'win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core')
      # Test-Json -SchemaFile is 7.2, newer than the bundled profiles.
      IgnoreCommands = @('Test-Json')
    }
    PSUseCompatibleTypes    = @{
      Enable         = $true
      TargetProfiles = @('ubuntu_x64_18.04_7.0.0_x64_3.1.2_core', 'win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core')
    }
  }
}
