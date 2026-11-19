@echo off
rem CodexNet firewall lock: blocks every non-loopback egress of the Codex app.
rem Usage: codex-net-lock.cmd [-DryRun] [-Unlock]
rem Elevates itself through UAC when needed.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Lock-CodexNet.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
