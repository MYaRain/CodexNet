@echo off
rem CodexNet self-check: proxy port, firewall lock, live sockets.
rem Usage: codex-net-test.cmd [-Seconds 20]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-CodexNet.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
