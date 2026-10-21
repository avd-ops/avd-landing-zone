# Compatibility rules for the scripts that run inside Azure on Windows: the image build, session
# hosts, host-side checks, the Automation runbook and the jumpbox's first boot. They run in Windows
# PowerShell 5.1 (lesson 0011), so no PowerShell 7 syntax, commands or types.
@{
  IncludeRules = @('PSUseCompatibleSyntax', 'PSUseCompatibleCommands', 'PSUseCompatibleTypes')
  Rules        = @{
    PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1') }
    PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework') }
    PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework') }
  }
}
