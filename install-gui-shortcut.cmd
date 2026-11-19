@echo off
rem Creates the CodexNet GUI shortcut (desktop by default).
rem Usage: install-gui-shortcut.cmd [-Path "D:\dir"] [-Remove]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-gui-shortcut.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
