#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Generates a read-only, zero-secret .mcp.json file for interactive AVD operator investigation in
  Azure Cloud Shell, a local workstation, or the VNet operator jumpbox.

.DESCRIPTION
  Standalone operator helper. avd-landing-zone never depends on avd-second-brain or avd-swarm, and
  automated deployments (deploy.sh, Deploy-AvdDemo.ps1) and readiness checks never call MCP so they
  stay deterministic and cost $0 in LLM tokens.

  When an operator uses a coding agent (Claude Code, Gemini CLI, VS Code) in Cloud Shell or on the
  jumpbox to inspect a deployed landing zone, this script emits a locked-down .mcp.json that:
    1. Starts Microsoft's Azure MCP Server (@azure/mcp) in `--mode all --read-only` with an explicit
       allowlist of read-only namespaces (default: virtualdesktop, monitor, kusto, advisor, pricing,
       resourcehealth, policy, role, quota).
    2. Optionally adds Microsoft's Azure CLI MCP Server (az-api-mcp) locked to `--readonly` when
       -IncludeAzCliMcp is passed, for ad-hoc CLI inspection of networking or compute resources.
    3. Writes zero secrets, keys, tokens, or tenant/subscription GUIDs into the file (authentication
       uses the operator's existing az login / Connect-AzAccount session).

.EXAMPLE
  ./scripts/ops/New-AvdMcpConfig.ps1 -OutputPath ./.mcp.json

.EXAMPLE
  ./scripts/ops/New-AvdMcpConfig.ps1 -Namespace virtualdesktop,monitor -IncludeAzCliMcp -OutputPath ~/.mcp.json
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [ValidateSet('virtualdesktop', 'monitor', 'kusto', 'advisor', 'pricing', 'resourcehealth', 'policy', 'role', 'quota')]
  [string[]] $Namespace = @('virtualdesktop', 'monitor', 'kusto', 'advisor', 'pricing', 'resourcehealth', 'policy', 'role', 'quota'),

  # Include Microsoft's Azure CLI MCP Server (Azure/azure-api-mcp) locked to --readonly.
  [switch] $IncludeAzCliMcp,

  # File path to write .mcp.json. If omitted, returns the configuration hashtable.
  [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$cleaned = @($Namespace | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Select-Object -Unique)
if (-not $cleaned.Count) {
  throw 'Specify at least one read-only Azure MCP namespace.'
}

$azMcpArgs = New-Object System.Collections.Generic.List[string]
foreach ($token in @('-y', '@azure/mcp@latest', 'server', 'start', '--mode', 'all', '--read-only')) {
  $azMcpArgs.Add($token)
}
foreach ($ns in $cleaned) {
  $azMcpArgs.Add('--namespace')
  $azMcpArgs.Add($ns)
}

$servers = [ordered]@{
  'azure-mcp' = [ordered]@{
    command = 'npx'
    args    = $azMcpArgs.ToArray()
  }
}

if ($IncludeAzCliMcp) {
  $servers['az-cli-mcp'] = [ordered]@{
    command = 'az-api-mcp'
    args    = @('--readonly')
  }
}

$config = [ordered]@{
  mcpServers = $servers
}

if ($OutputPath) {
  if ($PSCmdlet.ShouldProcess($OutputPath, 'Write read-only MCP configuration')) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      $null = New-Item -ItemType Directory -Path $parent -Force
    }
    ($config | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $OutputPath -Encoding utf8
  }
}

$config
