#Requires -Version 5.1
<#
.SYNOPSIS
    Hard network lockdown for the Codex desktop app: block every outbound
    connection except loopback, so the ONLY way out is the local proxy.

.DESCRIPTION
    Creates Windows Firewall outbound rules for the Codex executables:

        app\ChatGPT.exe                     (Electron main + renderers)
        app\Codex.exe                       (app launcher stub)
        resources\codex.exe                 (Rust model transport core)
        resources\codex-code-mode-host.exe
        resources\codex-command-runner.exe
        resources\codex-windows-sandbox-*.exe

    Each rule blocks remote addresses outside 127.0.0.0/8 for every protocol,
    which also kills QUIC/UDP bypass attempts. Windows Firewall never filters
    loopback traffic, so 127.0.0.1:7890 (your proxy) keeps working.

    This is the layer that makes the binding real: even if Codex ignores the
    proxy settings, it has no other route off the machine. Local LAN
    (192.168.x.x, 10.x.x.x, 172.16-31.x.x) is blocked as well.

    USE THIS ONLY AFTER .\Start-CodexNet.ps1 has been proven to work
    (see README, step 4). Requires an elevated PowerShell.

.PARAMETER Unlock
    Remove every rule created by this script.

.PARAMETER DryRun
    Show the commands without changing the firewall.

.EXAMPLE
    # elevated PowerShell
    .\Lock-CodexNet.ps1 -DryRun
    .\Lock-CodexNet.ps1

.EXAMPLE
    .\Lock-CodexNet.ps1 -Unlock
#>
[CmdletBinding()]
param(
    [switch] $Unlock,
    [switch] $DryRun,
    [switch] $Force,
    [switch] $NoElevate
)

$ErrorActionPreference = 'Stop'
$RulePrefix = 'CodexNet-Block-'
# Every IPv4 address except 127.0.0.0/8 -> loopback stays reachable, everything else dies.
$IPv4OutsideLoopback = @('0.0.0.1-126.255.255.255', '128.0.0.0-255.255.255.255')

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CodexExeList {
    $repo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    $appDirs = @()
    if (Test-Path -LiteralPath $repo) {
        Get-ChildItem -LiteralPath $repo -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'OpenAI.Codex_*' } |
            ForEach-Object {
                $root = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).PackageRootFolder
                if ($root) { $appDirs += (Join-Path $root 'app') }
            }
    }
    Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path } |
        ForEach-Object { $appDirs += (Split-Path -Parent $_.Path) }

    $appDirs = $appDirs | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ }
    if (-not $appDirs) { throw 'Codex desktop app not found (registry AppModel repository is empty).' }

    $relatives = @(
        'ChatGPT.exe',
        'Codex.exe',
        'resources\codex.exe',
        'resources\codex-code-mode-host.exe',
        'resources\codex-command-runner.exe',
        'resources\codex-windows-sandbox-setup.exe',
        'resources\codex-windows-sandbox-service.exe'
    )

    $found = @()
    foreach ($dir in $appDirs) {
        foreach ($rel in $relatives) {
            $p = Join-Path $dir $rel
            if (Test-Path -LiteralPath $p) { $found += (Resolve-Path -LiteralPath $p).Path }
        }
    }
    return ($found | Sort-Object -Unique)
}

# ---------------------------------------------------------------- main
if (-not (Test-Admin)) {
    if ($NoElevate) {
        Write-Host ''
        Write-Host '  [ERROR] 需要管理员权限：请以管理员身份运行 PowerShell 后重试。' -ForegroundColor Red
        exit 5
    }
    Write-Host '  requesting administrator elevation (UAC) ...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($Unlock) { $argList += '-Unlock' }
    if ($DryRun) { $argList += '-DryRun' }
    if ($Force) { $argList += '-Force' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    exit 0
}

if ($Unlock) {
    $rules = Get-NetFirewallRule -DisplayName ($RulePrefix + '*') -ErrorAction SilentlyContinue
    if (-not $rules) {
        Write-Host '  nothing to remove (no CodexNet rules found).' -ForegroundColor DarkGray
        exit 0
    }
    foreach ($r in $rules) {
        Write-Host ('  remove rule {0}' -f $r.DisplayName) -ForegroundColor DarkGray
        if (-not $DryRun) { Remove-NetFirewallRule -Name $r.Name }
    }
    Write-Host '  unlocked: Codex can reach the network directly again.' -ForegroundColor Green
    exit 0
}

$exes = Get-CodexExeList
Write-Host ''
Write-Host '  CodexNet - 防火墙级锁定（只允许回环，即只允许本地代理）' -ForegroundColor Cyan
Write-Host ('  target exes: {0}' -f $exes.Count)
$exes | ForEach-Object { Write-Host ('    {0}' -f $_) -ForegroundColor DarkGray }

if (-not $Force) {
    Write-Host ''
    Write-Host '  警告：执行后 Codex 只能通过 127.0.0.1 上的代理联网；' -ForegroundColor Yellow
    Write-Host '        若 Codex 不读代理设置，应用会完全断网（可用 -Unlock 立即恢复）。' -ForegroundColor Yellow
    $answer = Read-Host '  继续？输入 yes 确认'
    if ($answer -ne 'yes') { Write-Host '  cancelled.'; exit 0 }
}

foreach ($exe in $exes) {
    $leaf = [IO.Path]::GetFileName($exe)
    $display = $RulePrefix + $leaf
    $existing = Get-NetFirewallRule -DisplayName $display -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host ('  exists : {0}' -f $display) -ForegroundColor DarkGray
        continue
    }
    Write-Host ('  create : {0}' -f $display) -ForegroundColor Green
    if ($DryRun) {
        Write-Host ('           New-NetFirewallRule -DisplayName "{0}" -Direction Outbound -Program "{1}" -Action Block -RemoteAddress {2}' -f $display, $exe, ($IPv4OutsideLoopback -join ',')) -ForegroundColor DarkGray
        continue
    }
    try {
        New-NetFirewallRule -DisplayName $display `
            -Direction Outbound `
            -Program $exe `
            -Action Block `
            -Profile Any `
            -RemoteAddress $IPv4OutsideLoopback `
            -Enabled True | Out-Null
    } catch {
        Write-Host ('  FAILED : {0} -> {1}' -f $display, $_.Exception.Message) -ForegroundColor Red
        Write-Host '           回滚：.\codex-net-lock.cmd -Unlock' -ForegroundColor Red
        throw
    }
}

Write-Host ''
Write-Host '  done. 若 Codex 异常，运行：.\Lock-CodexNet.ps1 -Unlock' -ForegroundColor Green
