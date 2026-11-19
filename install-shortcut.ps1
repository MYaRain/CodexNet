#Requires -Version 5.1
<#
.SYNOPSIS
    Create (or remove) a desktop shortcut that starts Codex through the proxy launcher.

.DESCRIPTION
    The shortcut runs:  codex-net.cmd -Restart
    so every double-click restarts Codex with the proxy binding applied.

.PARAMETER Remove
    Delete the shortcut instead of creating it.

.EXAMPLE
    .\install-shortcut.ps1

.EXAMPLE
    .\install-shortcut.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string] $Name = 'Codex 代理版',
    [string] $Path,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$cmd = Join-Path $root 'codex-net.cmd'
$targetDir = if ($Path) { $Path } else { [Environment]::GetFolderPath('Desktop') }
$lnkPath = Join-Path $targetDir ($Name + '.lnk')

$shell = New-Object -ComObject WScript.Shell
if ($Remove) {
    if (Test-Path -LiteralPath $lnkPath) {
        Remove-Item -LiteralPath $lnkPath -Force
        Write-Host ('  removed: {0}' -f $lnkPath) -ForegroundColor Green
    } else {
        Write-Host '  shortcut not found, nothing to do.' -ForegroundColor DarkGray
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $cmd)) { throw "launcher not found: $cmd" }

$icon = $null
$repo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
$iconCandidates = @()
if (Test-Path -LiteralPath $repo) {
    Get-ChildItem -LiteralPath $repo -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'OpenAI.Codex_*' } |
        ForEach-Object {
            $r = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).PackageRootFolder
            if ($r) { $iconCandidates += (Join-Path $r 'app\ChatGPT.exe') }
        }
}
$iconCandidates += 'C:\Program Files\WindowsApps\OpenAI.Codex_26.1103.4239.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
$icon = $iconCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath = $cmd
$shortcut.Arguments = '-Restart'
$shortcut.WorkingDirectory = $root
$shortcut.Description = 'Start the Codex desktop app bound to the local proxy (127.0.0.1:7890)'
$shortcut.WindowStyle = 1
if ($icon) { $shortcut.IconLocation = ('{0},0' -f $icon) }
$shortcut.Save()

Write-Host ''
Write-Host ('  created: {0}' -f $lnkPath) -ForegroundColor Green
Write-Host '  double-click it to start Codex with the proxy binding.' -ForegroundColor DarkGray
