@echo off
setlocal
set "SCRIPT=%~dp0find-deformed-uassets.ps1"
if not exist "%SCRIPT%" (
    echo Script not found: %SCRIPT%
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
