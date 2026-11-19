@echo off
rem CodexNet GUI - console variant (useful when debugging startup errors).
rem Normally you should double-click CodexNet.vbs instead (no console window).
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexNet-GUI.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
