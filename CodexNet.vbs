' CodexNet GUI launcher (no console window).
' Double-click this file, or use the desktop shortcut it is meant for.
Option Explicit
Dim fso, sh, baseDir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & baseDir & "\CodexNet-GUI.ps1"""
sh.Run cmd, 0, False
