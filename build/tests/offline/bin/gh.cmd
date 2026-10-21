@echo off
rem Windows sibling of the bash stand-in next to it (run recorder scenarios): AVDLZ_FAKE_GH=private^|public^|fail.
if "%AVDLZ_FAKE_GH%"=="private" (
  echo true
  exit /b 0
)
if "%AVDLZ_FAKE_GH%"=="public" (
  echo false
  exit /b 0
)
echo HTTP 404: Not Found 1>&2
exit /b 1
