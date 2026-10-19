# Dot-sourced by every *.Scenario.ps1: loads the mock in place of Az/Graph and moves to the
# repo root. Each scenario runs the real ops scripts and prints "RESULT <step> ..." lines that
# build/tests/OfflineScenarios.Tests.ps1 asserts on.
$ErrorActionPreference = 'Stop'
$env:PSModulePath = (Join-Path $PSScriptRoot 'modules') + [IO.Path]::PathSeparator + $env:PSModulePath
$env:ACC_CLOUD = '1'   # the scripts then behave as they do in Azure Cloud Shell
# Hermetic: the tooling check looks for az; don't depend on the machine having it.
$env:PATH = (Join-Path $PSScriptRoot 'bin') + [IO.Path]::PathSeparator + $env:PATH
Import-Module (Join-Path $PSScriptRoot 'AzMock.psm1') -Global -Force
Set-Location (Join-Path $PSScriptRoot '../../..')

function Invoke-ScenarioStep {
  param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][scriptblock] $Run)
  Write-Host "`n######## $Name" -ForegroundColor Magenta
  $global:LASTEXITCODE = 0
  & $Run
  Write-Host "RESULT $Name EXIT=$LASTEXITCODE"
}
