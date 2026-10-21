@echo off
rem Windows sibling of the bash fake next to it, for PowerShell scripts that call az (host rotation):
rem it runs the same fake in the bash under test (Git Bash in CI). Bash itself finds the extensionless az first.
if defined AVDLZ_TEST_BASH (
  "%AVDLZ_TEST_BASH%" "%~dp0az" %*
) else (
  bash "%~dp0az" %*
)
exit /b %ERRORLEVEL%
