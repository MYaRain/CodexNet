#Requires -Version 5.1
<#
.SYNOPSIS
    Verify that the Codex desktop app is really confined to the local proxy.

.DESCRIPTION
    Checks three things:

      1. The proxy port (default 127.0.0.1:7890) is listening.
      2. The CodexNet firewall lock rules are present (optional layer).
      3. Live TCP connections of every ChatGPT/Codex process, sampled for a few
         seconds: anything that is not loopback / not the proxy port is reported
         as a LEAK.

    Use it after launching Codex with Start-CodexNet.ps1 and while Codex is
    actually doing something (sending a prompt), because idle apps show no sockets.

.PARAMETER Proxy
    Proxy URL, default http://127.0.0.1:7890

.PARAMETER Seconds
    Sampling window, default 12.

.EXAMPLE
    .\Test-CodexNet.ps1
#>
[CmdletBinding()]
param(
    [string] $Proxy = 'http://127.0.0.1:7890',
    [int] $Seconds = 12
)

$ErrorActionPreference = 'Continue'

function Resolve-ProxyUri {
    param([string] $Value)
    $v = $Value.Trim()
    if ($v -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $v = 'http://' + $v }
    $u = $null
    if (-not [uri]::TryCreate($v, [UriKind]::Absolute, [ref] $u)) { throw "Bad proxy URI: $Value" }
    return $u
}

function Test-TcpPort {
    param([string] $TargetHost, [int] $Port, [int] $TimeoutMs = 1200)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async); return $true
    } catch { return $false } finally { $client.Dispose() }
}

function Get-CodexConnections {
    $targets = @(Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue)
    $pids = @($targets | ForEach-Object { $_.Id })
    $rows = @()
    if (-not $pids) { return @{ Processes = $targets; Rows = $rows } }

    foreach ($line in (netstat -ano -p tcp)) {
        $parts = ($line -split '\s+') | Where-Object { $_ }
        if ($parts.Count -lt 5) { continue }
        if ($parts[0] -ne 'TCP') { continue }
        $owner = 0
        if (-not [int]::TryParse($parts[4], [ref] $owner)) { continue }
        if ($pids -notcontains $owner) { continue }
        $rows += [pscustomobject]@{
            PID     = $owner
            Local   = $parts[1]
            Foreign = $parts[2]
            State   = $parts[3]
        }
    }
    return @{ Processes = $targets; Rows = $rows }
}

# ---------------------------------------------------------------- main
$uri = Resolve-ProxyUri $Proxy
$proxyHost = $uri.Host
$proxyPort = $uri.Port

Write-Host ''
Write-Host '  CodexNet - 连通性/泄漏自检' -ForegroundColor Cyan

# 1) proxy port
$up = Test-TcpPort -TargetHost $proxyHost -Port $proxyPort
if ($up) {
    Write-Host ('  [OK]   proxy {0}:{1} is LISTENING' -f $proxyHost, $proxyPort) -ForegroundColor Green
} else {
    Write-Host ('  [FAIL] proxy {0}:{1} is CLOSED -> Codex has no internet by design.' -f $proxyHost, $proxyPort) -ForegroundColor Red
}

# 2) firewall lock rules
$rules = @(Get-NetFirewallRule -DisplayName 'CodexNet-Block-*' -ErrorAction SilentlyContinue)
if ($rules.Count -gt 0) {
    Write-Host ('  [OK]   firewall lock active ({0} rules)' -f $rules.Count) -ForegroundColor Green
    foreach ($r in $rules) { Write-Host ('         {0} / enabled={1}' -f $r.DisplayName, $r.Enabled) -ForegroundColor DarkGray }
} else {
    Write-Host '  [INFO] firewall lock not installed (env + Chromium flag only)' -ForegroundColor Yellow
}

# 3) live connections
Write-Host ''
Write-Host ('  sampling Codex connections for {0}s ...' -f $Seconds) -ForegroundColor DarkGray
$seen = @{}
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    $snap = Get-CodexConnections
    if (-not $snap.Processes -or $snap.Processes.Count -eq 0) { break }
    foreach ($row in $snap.Rows) {
        $key = '{0}|{1}|{2}' -f $row.PID, $row.Local, $row.Foreign
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $row }
    }
    Start-Sleep -Milliseconds 700
}

$snap = Get-CodexConnections
if (-not $snap.Processes -or $snap.Processes.Count -eq 0) {
    Write-Host '  [WARN] Codex 应用没有在运行，先执行 .\Start-CodexNet.ps1 -Restart' -ForegroundColor Yellow
    exit 2
}

$total = 0
$leaks = 0
$viaProxy = 0
foreach ($row in ($seen.Values | Sort-Object Foreign)) {
    $total++
    $foreign = $row.Foreign
    $isLoop = $foreign -match '^(127\.|\[::1\]|0\.0\.0\.0)'
    $isProxyPort = $foreign -match (':{0}$' -f $proxyPort)
    if ($isLoop -and $isProxyPort) {
        $viaProxy++
        Write-Host ('  [PROXY] {0,-22} -> {1,-22} {2}' -f $row.Local, $foreign, $row.State) -ForegroundColor Green
    } elseif ($isLoop) {
        Write-Host ('  [LOCAL] {0,-22} -> {1,-22} {2}' -f $row.Local, $foreign, $row.State) -ForegroundColor DarkGray
    } else {
        $leaks++
        Write-Host ('  [LEAK!] {0,-22} -> {1,-22} {2}' -f $row.Local, $foreign, $row.State) -ForegroundColor Red
    }
}

Write-Host ''
if ($total -eq 0) {
    Write-Host '  [INFO] 采样期间没有任何连接。让 Codex 实际发一条消息后再测一次。' -ForegroundColor Yellow
    exit 0
}
Write-Host ('  summary: {0} sockets, {1} via proxy, {2} leaks' -f $total, $viaProxy, $leaks)
if ($leaks -gt 0) {
    Write-Host '  [FAIL] 检测到绕过代理的直连。建议启用防火墙锁定：Lock-CodexNet.ps1' -ForegroundColor Red
    exit 2
}
Write-Host '  [PASS] Codex 的全部外发流量都只经过本地代理。' -ForegroundColor Green
exit 0
