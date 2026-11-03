#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for scripts/ops/New-AvdMcpConfig.ps1.

BeforeAll {
  $script:scriptPath = Join-Path $PSScriptRoot '../../scripts/ops/New-AvdMcpConfig.ps1'
}

Describe 'New-AvdMcpConfig.ps1' {
  It 'builds a read-only zero-secret azure-mcp configuration by default' {
    $cfg = & $script:scriptPath
    $cfg.mcpServers.Keys | Should -Be @('azure-mcp')
    $cfg.mcpServers['azure-mcp'].command | Should -Be 'npx'
    $cfg.mcpServers['azure-mcp'].args | Should -Contain '--read-only'
    $cfg.mcpServers['azure-mcp'].args | Should -Contain 'virtualdesktop'
  }

  It 'adds az-cli-mcp with --readonly when -IncludeAzCliMcp is passed' {
    $cfg = & $script:scriptPath -Namespace @('virtualdesktop', 'monitor') -IncludeAzCliMcp
    $cfg.mcpServers.Keys | Should -Be @('azure-mcp', 'az-cli-mcp')
    $cfg.mcpServers['az-cli-mcp'].command | Should -Be 'az-api-mcp'
    $cfg.mcpServers['az-cli-mcp'].args | Should -Be @('--readonly')
  }

  It 'rejects namespaces outside the ValidateSet allowlist' {
    { & $script:scriptPath -Namespace @('keyvault') } | Should -Throw
  }

  It 'writes valid JSON with no GUIDs or secrets when -OutputPath is given' {
    $out = Join-Path $TestDrive '.mcp.json'
    $null = & $script:scriptPath -Namespace @('virtualdesktop') -IncludeAzCliMcp -OutputPath $out
    Test-Path -LiteralPath $out | Should -BeTrue
    $raw = Get-Content -LiteralPath $out -Raw
    $raw | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $raw | Should -Not -Match '(?i)(secret|password|token|api_key)'
    $parsed = $raw | ConvertFrom-Json
    $parsed.mcpServers.'azure-mcp'.args | Should -Contain '--read-only'
    $parsed.mcpServers.'az-cli-mcp'.args | Should -Contain '--readonly'
  }
}
