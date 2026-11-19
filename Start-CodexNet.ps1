#Requires -Version 5.1
<#
.SYNOPSIS
    Launch the Codex desktop app so that ALL of its internet traffic goes through
    the local proxy app (e.g. Clash / mihomo / v2rayN on 127.0.0.1:7890).

.DESCRIPTION
    This is the "local network zone" for Codex. Two independent lock layers are applied:

      1. Chromium layer  -> --proxy-server switch, so the Electron/Chromium network
                            stack (renderers, websockets, updater) uses the proxy and
                            resolves DNS remotely (no local DNS leak).
      2. Rust core layer -> HTTP_PROXY / HTTPS_PROXY / ALL_PROXY environment variables
                            inherited by resources\codex.exe (the model transport).

    Nothing else on the machine is touched: your browser and other apps keep their
    own settings, so you can browse directly (via your other IP / line) while Codex
    is forced through the proxy.

    If the proxy port is closed, the launcher refuses to start Codex. That is the
    "bound to proxy on/off" behaviour you asked for: proxy off => Codex offline.

.PARAMETER Proxy
    Proxy URL. Default http://127.0.0.1:7890

.PARAMETER Restart
    Kill an already running Codex/ChatGPT instance first. Required when the app is
    open, because Electron single-instance activation would otherwise re-use the
    old process that has no proxy binding.

.PARAMETER NoProxyCheck
    Start even when the proxy port is closed (Codex will simply have no internet).

.PARAMETER DryRun
    Print what would happen, do not start anything.

.EXAMPLE
    .\codex-net.cmd -Restart

.EXAMPLE
    .\codex-net.cmd -Proxy http://127.0.0.1:7897 -Restart
#>
[CmdletBinding()]
param(
    [string] $Proxy = 'http://127.0.0.1:7890',
    [switch] $Restart,
    [switch] $NoProxyCheck,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$AppModelRepo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'

function Resolve-ProxyUri {
    param([string] $Value)
    $v = $Value.Trim()
    if ($v -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $v = 'http://' + $v }
    $u = $null
    if (-not [uri]::TryCreate($v, [UriKind]::Absolute, [ref] $u)) {
        throw "Proxy value is not a valid URI: '$Value'"
    }
    if ([string]::IsNullOrWhiteSpace($u.Host) -or $u.Port -le 0) {
        throw "Proxy URI needs host and port, got: '$Value'"
    }
    return $u
}

function Test-TcpPort {
    param([string] $TargetHost, [int] $Port, [int] $TimeoutMs = 1200)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Get-CodexAppDirs {
    $candidates = @()
    if ($env:CODEXNET_APP_EXE) {
        $candidates += Split-Path -Parent $env:CODEXNET_APP_EXE
    }
    if (Test-Path -LiteralPath $AppModelRepo) {
        Get-ChildItem -LiteralPath $AppModelRepo -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'OpenAI.Codex_*' } |
            ForEach-Object {
                $root = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).PackageRootFolder
                if ($root) { $candidates += (Join-Path $root 'app') }
            }
    }
    Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path } |
        ForEach-Object { $candidates += (Split-Path -Parent $_.Path) }

    $valid = @()
    foreach ($dir in ($candidates | Sort-Object -Unique -Descending)) {
        if (Test-Path -LiteralPath (Join-Path $dir 'ChatGPT.exe')) { $valid += $dir }
    }
    return $valid
}

function Test-ProxyTunnel {
    # Port LISTENING alone is not proof the proxy works: a system service can keep
    # the core alive long after the client UI says "stopped". So push real bytes.
    param([string] $TargetHost = '127.0.0.1', [int] $Port = 7890, [string] $ProbeHost = 'example.com', [int] $ProbePort = 80, [int] $TimeoutMs = 6000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not ($iar.AsyncWaitHandle.WaitOne(1500) -and $c.Connected)) { return [pscustomobject]@{ Ok = $false; Detail = 'port closed' } }
        $s = $c.GetStream(); $s.ReadTimeout = $TimeoutMs
        $req = "CONNECT {0}:{1} HTTP/1.1`r`nHost: {0}:{1}`r`n`r`n" -f $ProbeHost, $ProbePort
        $b = [Text.Encoding]::ASCII.GetBytes($req); $s.Write($b, 0, $b.Length); $s.Flush()
        $buf = New-Object byte[] 512
        $n = $s.Read($buf, 0, 512)
        if ($n -le 0) { return [pscustomobject]@{ Ok = $false; Detail = 'no CONNECT reply' } }
        $status = (([Text.Encoding]::ASCII.GetString($buf, 0, $n)) -split "`r`n")[0]
        if ($status -notmatch '200') { return [pscustomobject]@{ Ok = $false; Detail = $status } }
        $g = "GET / HTTP/1.0`r`nHost: {0}`r`n`r`n" -f $ProbeHost
        $gb = [Text.Encoding]::ASCII.GetBytes($g); $s.Write($gb, 0, $gb.Length); $s.Flush()
        Start-Sleep -Milliseconds 700
        $buf2 = New-Object byte[] 512
        $n2 = $s.Read($buf2, 0, 512)
        if ($n2 -le 0) { return [pscustomobject]@{ Ok = $false; Detail = 'tunnel open but target silent' } }
        return [pscustomobject]@{ Ok = $true; Detail = (([Text.Encoding]::ASCII.GetString($buf2, 0, $n2)) -split "`r`n")[0] }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    } finally {
        $c.Close()
    }
}

function Resolve-CodexAppExe {
    $dirs = @(Get-CodexAppDirs)
    if ($dirs.Count -eq 0) {
        throw "Codex desktop app not found. Is the ChatGPT/Codex app installed for this user? Set CODEXNET_APP_EXE to ...\app\ChatGPT.exe"
    }
    return (Join-Path $dirs[0] 'ChatGPT.exe')
}

# ---------------------------------------------------------------- main
$uri = Resolve-ProxyUri $Proxy
$proxyUrl = '{0}://{1}:{2}' -f $uri.Scheme, $uri.Host, $uri.Port
$exe = Resolve-CodexAppExe

Write-Host ''
Write-Host '  CodexNet - Codex 只走代理网络区' -ForegroundColor Cyan
Write-Host ('  proxy   : {0}' -f $proxyUrl)
Write-Host ('  app     : {0}' -f $exe)

$proxyUp = Test-TcpPort -TargetHost $uri.Host -Port $uri.Port
if ($proxyUp) {
    Write-Host '  status  : proxy port OPEN' -ForegroundColor Green
    $tunnel = Test-ProxyTunnel -TargetHost $uri.Host -Port $uri.Port
    if ($tunnel.Ok) {
        Write-Host ('  tunnel  : OK ({0})' -f $tunnel.Detail) -ForegroundColor Green
    } else {
        Write-Host ('  tunnel  : FAILED ({0})' -f $tunnel.Detail) -ForegroundColor Yellow
        if (-not $NoProxyCheck) {
            Write-Host ''
            Write-Host '  [BLOCKED] 端口在监听，但经代理连不通：代理客户端没连上节点，或订阅已失效。' -ForegroundColor Red
            Write-Host '            -NoProxyCheck 可强制启动。' -ForegroundColor Red
            exit 3
        }
    }
} else {
    Write-Host '  status  : proxy port CLOSED' -ForegroundColor Yellow
    if (-not $NoProxyCheck) {
        Write-Host ''
        Write-Host '  [BLOCKED] 代理没有开启，Codex 无法联网（这是设计行为）。' -ForegroundColor Red
        Write-Host '            先启动代理客户端并确认端口可通，或加 -NoProxyCheck 强制启动。' -ForegroundColor Red
        exit 3
    }
}

$chromiumArgs = @(
    ('--proxy-server={0}' -f $proxyUrl)
)
Write-Host ('  args    : {0}' -f ($chromiumArgs -join ' '))

if ($DryRun) {
    Write-Host ''
    Write-Host '  DryRun: nothing was started.' -ForegroundColor DarkGray
    exit 0
}

if ($Restart) {
    $running = @(Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host ('  restart : stopping {0} process(es)' -f $running.Count) -ForegroundColor DarkGray
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1500
    }
} elseif (Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue) {
    Write-Host ''
    Write-Host '  [WARN] Codex 已经在运行：单实例机制会复用旧进程，代理绑定不会生效。' -ForegroundColor Yellow
    Write-Host '         请先完全退出应用，或使用 -Restart 参数。' -ForegroundColor Yellow
}

# Proxy environment for the Rust core (resources\codex.exe) and any child process.
$noProxy = 'localhost,127.0.0.1,::1'
foreach ($name in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy') {
    Set-Item -Path ("env:" + $name) -Value $proxyUrl
}
foreach ($name in 'NO_PROXY', 'no_proxy') {
    Set-Item -Path ("env:" + $name) -Value $noProxy
}
$env:CODEXNET_PROXY = $proxyUrl

Start-Process -FilePath $exe -ArgumentList $chromiumArgs | Out-Null
Start-Sleep -Milliseconds 1800
$procs = @(Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
    Write-Host ''
    Write-Host '  [WARN] 没有检测到 Codex 进程：应用可能拒绝从命令行启动（MSIX 限制）。' -ForegroundColor Yellow
    Write-Host '         回退办法：正常从开始菜单启动 Codex，改用代理客户端的 TUN + PROCESS-NAME 规则（README 方案 B）。' -ForegroundColor Yellow
    exit 4
}
Write-Host ('  processes: {0} running' -f $procs.Count) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  started. 验证：.\codex-net-test.cmd' -ForegroundColor Green
