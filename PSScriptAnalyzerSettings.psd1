# PSScriptAnalyzer settings for this repo (used by CI and locally).
@{
  # ParseError is its own severity: without it a script that doesn't parse passes the analyzer.
  Severity     = @('Error', 'Warning', 'ParseError')
  ExcludeRules = @(
    # The ops scripts are interactive console tools; colored Write-Host output is intended.
    'PSAvoidUsingWriteHost'
  )
}
