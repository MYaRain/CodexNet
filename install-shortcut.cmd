@echo off
rem Creates the CodexNet shortcut (desktop by default).
rem Usage: install-shortcut.cmd [-Name "MyName"] [-Path "D:\dir"] [-Remove]
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-shortcut.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
