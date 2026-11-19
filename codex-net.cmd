@echo off
rem CodexNet launcher: starts the Codex desktop app bound to the local proxy.
rem Usage: codex-net.cmd [-Restart] [-Proxy http://127.0.0.1:7890] [-DryRun]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-CodexNet.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
