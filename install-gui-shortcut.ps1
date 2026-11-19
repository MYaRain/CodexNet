#Requires -Version 5.1
<#
.SYNOPSIS
    Create the "CodexNet 应用代理器" shortcut (desktop by default) that starts the
    GUI without a console window.

.PARAMETER Path
    Target folder for the .lnk. Defaults to the current user's Desktop.

.PARAMETER Remove
    Delete the shortcut instead.
#>
[CmdletBinding()]
param(
    [string] $Name = 'CodexNet 应用代理器',
    [string] $Path,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$vbs = Join-Path $root 'CodexNet.vbs'
$targetDir = if ($Path) { $Path } else { [Environment]::GetFolderPath('Desktop') }
$lnkPath = Join-Path $targetDir ($Name + '.lnk')

if ($Remove) {
    if (Test-Path -LiteralPath $lnkPath) {
        Remove-Item -LiteralPath $lnkPath -Force
        Write-Host ('removed: {0}' -f $lnkPath) -ForegroundColor Green
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $vbs)) { throw "launcher not found: $vbs" }

$iconCandidates = @()
$repo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
if (Test-Path -LiteralPath $repo) {
    Get-ChildItem -LiteralPath $repo -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'OpenAI.Codex_*' } |
        ForEach-Object {
            $r = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).PackageRootFolder
            if ($r) { $iconCandidates += (Join-Path $r 'app\ChatGPT.exe') }
        }
}
$appIcon = Join-Path $root 'assets\codexnet.ico'
if (Test-Path -LiteralPath $appIcon) {
    $icon = $appIcon
} else {
    $icon = $iconCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$shortcut.Arguments = ('"{0}"' -f $vbs)
$shortcut.WorkingDirectory = $root
$shortcut.Description = 'CodexNet - 让指定应用只通过指定代理访问外网'
$shortcut.WindowStyle = 7
if ($icon) { $shortcut.IconLocation = ('{0},0' -f $icon) }
$shortcut.Save()

Write-Host ('created: {0}' -f $lnkPath) -ForegroundColor Green
