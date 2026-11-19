#Requires -Version 5.1
<#
.SYNOPSIS
    CodexNet GUI - a small desktop app that lets any Windows application reach the
    internet ONLY through a chosen local proxy.

.DESCRIPTION
    Each profile stores: app path, proxy URL, extra arguments, whether the app is a
    Chromium/Electron app (gets --proxy-server), whether to restart it first, and
    which executables the firewall lock should cover.

    Actions:
      * 启动应用   - injects proxy env vars (+ Chromium flag) and starts the app
      * 测试代理   - TCP reachability of the proxy port
      * 防火墙锁定 - elevated: blocks every non-loopback egress of the listed exes
      * 解锁       - removes those rules
      * 网络自检   - samples the app's live sockets and flags non-proxy connections

.PARAMETER SmokeTest
    Build the window, verify every control resolves, then exit without showing it.
#>
[CmdletBinding()]
param(
    [switch] $SmokeTest,
    [string] $RenderPng,
    [string] $ResolvePath,
    [switch] $ScanProxies,
    [string] $AddPath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$script:Root       = $PSScriptRoot
if ($env:CODEXNET_DATA) {
    if (-not (Test-Path -LiteralPath $env:CODEXNET_DATA)) {
        New-Item -ItemType Directory -Path $env:CODEXNET_DATA -Force | Out-Null
    }
    $script:DataFile = Join-Path $env:CODEXNET_DATA 'profiles.json'
} else {
    $script:DataFile = Join-Path $script:Root 'profiles.json'
}
$script:LockScript = Join-Path $script:Root 'Lock-AppNet.ps1'
$script:Profiles   = @()
$script:Current    = -1
$script:Win        = $null

# ------------------------------------------------------------------ helpers
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

function Test-HttpTunnel {
    <#
      The port being LISTENING is NOT proof that "the proxy is on":
      a system-service hosted core can keep listening long after the client UI
      says it is stopped. So we open a real CONNECT tunnel through the proxy and
      push actual bytes through it. Returns Ok + Detail.
    #>
    param(
        [string] $ProxyHost = '127.0.0.1',
        [int]    $ProxyPort = 7890,
        [string] $ProbeHost = 'example.com',
        [int]    $ProbePort = 80,
        [int]    $TimeoutMs = 6000
    )
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($ProxyHost, $ProxyPort, $null, $null)
        if (-not ($iar.AsyncWaitHandle.WaitOne(1500) -and $c.Connected)) {
            return [pscustomobject]@{ Ok = $false; Detail = '端口未监听' }
        }
        $s = $c.GetStream()
        $s.ReadTimeout = $TimeoutMs
        $req = "CONNECT {0}:{1} HTTP/1.1`r`nHost: {0}:{1}`r`n`r`n" -f $ProbeHost, $ProbePort
        $b = [Text.Encoding]::ASCII.GetBytes($req)
        $s.Write($b, 0, $b.Length); $s.Flush()
        $buf = New-Object byte[] 512
        $n = $s.Read($buf, 0, 512)
        if ($n -le 0) { return [pscustomobject]@{ Ok = $false; Detail = 'CONNECT 无响应' } }
        $status = (([Text.Encoding]::ASCII.GetString($buf, 0, $n)) -split "`r`n")[0]
        if ($status -notmatch '200') {
            return [pscustomobject]@{ Ok = $false; Detail = ('CONNECT ' + $status) }
        }
        $g = "GET / HTTP/1.0`r`nHost: {0}`r`n`r`n" -f $ProbeHost
        $gb = [Text.Encoding]::ASCII.GetBytes($g)
        $s.Write($gb, 0, $gb.Length); $s.Flush()
        Start-Sleep -Milliseconds 700
        $buf2 = New-Object byte[] 512
        $n2 = $s.Read($buf2, 0, 512)
        if ($n2 -le 0) { return [pscustomobject]@{ Ok = $false; Detail = '隧道建立了但目标无响应' } }
        $line = (([Text.Encoding]::ASCII.GetString($buf2, 0, $n2)) -split "`r`n")[0]
        return [pscustomobject]@{ Ok = $true; Detail = ('隧道连通：{0} -> {1}' -f $ProbeHost, $line) }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = ('隧道异常：' + $_.Exception.Message) }
    } finally {
        $c.Close()
    }
}

function Test-Socks5Tunnel {
    # SOCKS5 (v2rayN / Clash SOCKS port / ssh -D): handshake, CONNECT by domain,
    # then a plain HTTP request through the socket.
    param(
        [string] $ProxyHost = '127.0.0.1',
        [int]    $ProxyPort = 7891,
        [string] $ProbeHost = 'example.com',
        [int]    $ProbePort = 80,
        [int]    $TimeoutMs = 6000
    )
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($ProxyHost, $ProxyPort, $null, $null)
        if (-not ($iar.AsyncWaitHandle.WaitOne(1500) -and $c.Connected)) {
            return [pscustomobject]@{ Ok = $false; Detail = '端口未监听' }
        }
        $s = $c.GetStream()
        $s.ReadTimeout = $TimeoutMs
        $s.WriteTimeout = $TimeoutMs

        # greeting: version 5, one method, no auth
        $s.Write([byte[]](5, 1, 0), 0, 3); $s.Flush()
        $hello = New-Object byte[] 2
        if ($s.Read($hello, 0, 2) -lt 2) { return [pscustomobject]@{ Ok = $false; Detail = 'SOCKS5 无响应' } }
        if ($hello[0] -ne 5) { return [pscustomobject]@{ Ok = $false; Detail = '不是 SOCKS5（可能是 HTTP 代理）' } }
        if ($hello[1] -ne 0) { return [pscustomobject]@{ Ok = $false; Detail = 'SOCKS5 需要认证' } }

        $h = [Text.Encoding]::ASCII.GetBytes($ProbeHost)
        $req = New-Object byte[] (7 + $h.Length)
        $req[0] = 5; $req[1] = 1; $req[2] = 0; $req[3] = 3; $req[4] = [byte]$h.Length
        [Array]::Copy($h, 0, $req, 5, $h.Length)
        $req[5 + $h.Length] = [byte][math]::Floor($ProbePort / 256)
        $req[6 + $h.Length] = [byte]($ProbePort -band 0xFF)
        $s.Write($req, 0, $req.Length); $s.Flush()

        $rep = New-Object byte[] 16
        $m = $s.Read($rep, 0, 16)
        if ($m -lt 2) { return [pscustomobject]@{ Ok = $false; Detail = 'SOCKS5 连接无响应' } }
        if ($rep[1] -ne 0) { return [pscustomobject]@{ Ok = $false; Detail = ('SOCKS5 拒绝，代码 ' + $rep[1]) } }

        $g = "GET / HTTP/1.0`r`nHost: {0}`r`n`r`n" -f $ProbeHost
        $gb = [Text.Encoding]::ASCII.GetBytes($g)
        $s.Write($gb, 0, $gb.Length); $s.Flush()
        Start-Sleep -Milliseconds 700
        $buf2 = New-Object byte[] 512
        $n2 = $s.Read($buf2, 0, 512)
        if ($n2 -le 0) { return [pscustomobject]@{ Ok = $false; Detail = 'SOCKS5 隧道建立但目标无响应' } }
        $line = (([Text.Encoding]::ASCII.GetString($buf2, 0, $n2)) -split "`r`n")[0]
        return [pscustomobject]@{ Ok = $true; Detail = ('SOCKS5 隧道连通：{0} -> {1}' -f $ProbeHost, $line) }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = ('SOCKS5 异常：' + $_.Exception.Message) }
    } finally {
        $c.Close()
    }
}

function Test-ProxyTunnel {
    # Dispatch on scheme: socks5:// -> SOCKS5 handshake, anything else -> HTTP CONNECT.
    param(
        [uri]    $ProxyUri,
        [string] $ProbeHost = 'example.com',
        [int]    $ProbePort = 80,
        [int]    $TimeoutMs = 6000
    )
    $isSocks = $ProxyUri.Scheme -match '^socks'
    if ($isSocks) {
        return Test-Socks5Tunnel -ProxyHost $ProxyUri.Host -ProxyPort $ProxyUri.Port `
            -ProbeHost $ProbeHost -ProbePort $ProbePort -TimeoutMs $TimeoutMs
    }
    return Test-HttpTunnel -ProxyHost $ProxyUri.Host -ProxyPort $ProxyUri.Port `
        -ProbeHost $ProbeHost -ProbePort $ProbePort -TimeoutMs $TimeoutMs
}
function Convert-ProxyUrl {
    param([string] $Value)
    $v = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { throw '代理地址不能为空' }
    if ($v -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $v = 'http://' + $v }
    $u = $null
    if (-not [uri]::TryCreate($v, [UriKind]::Absolute, [ref] $u)) { throw ('代理地址无效：' + $Value) }
    if ([string]::IsNullOrWhiteSpace($u.Host) -or $u.Port -le 0) { throw ('代理地址需要主机和端口：' + $Value) }
    return $u
}

function Find-LocalProxies {
    <#
      Different clients bind different ports and speak different dialects:
      Clash/mihomo 7890 HTTP + 7891 SOCKS, Clash Verge 7897, v2rayN 10808/10809,
      Nekoray 2080/2081, plain 1080/8080/8888. Probe each and classify, then add
      whatever the Windows system proxy points at.
    #>
    $map = @(
        @{ Port = 7890;  Label = 'Clash / mihomo (HTTP)' },
        @{ Port = 7891;  Label = 'Clash / mihomo (SOCKS5)' },
        @{ Port = 7897;  Label = 'Clash Verge (HTTP)' },
        @{ Port = 7898;  Label = 'Clash Verge (SOCKS5)' },
        @{ Port = 1080;  Label = '通用 SOCKS5' },
        @{ Port = 10808; Label = 'v2rayN (SOCKS5)' },
        @{ Port = 10809; Label = 'v2rayN (HTTP)' },
        @{ Port = 20171; Label = 'v2rayN (混合)' },
        @{ Port = 2080;  Label = 'Nekoray (SOCKS5)' },
        @{ Port = 2081;  Label = 'Nekoray (HTTP)' },
        @{ Port = 1087;  Label = '通用 HTTP' },
        @{ Port = 8080;  Label = '通用 HTTP' },
        @{ Port = 8888;  Label = '通用 HTTP' }
    )

    $found = @()
    foreach ($m in $map) {
        if (-not (Test-TcpPort -TargetHost '127.0.0.1' -Port $m.Port -TimeoutMs 300)) { continue }
        $kind = 'unknown'

        # 1) try HTTP first: Clash-style "mixed" ports answer both dialects, and HTTP
        #    is the safer default for env vars and Chromium.
        $cl = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $cl.BeginConnect('127.0.0.1', $m.Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(500) -and $cl.Connected) {
                $st = $cl.GetStream(); $st.ReadTimeout = 800; $st.WriteTimeout = 800
                $req = [Text.Encoding]::ASCII.GetBytes("CONNECT example.com:80 HTTP/1.1`r`nHost: example.com:80`r`n`r`n")
                $st.Write($req, 0, $req.Length); $st.Flush()
                $buf = New-Object byte[] 128
                $n = 0
                try { $n = $st.Read($buf, 0, 128) } catch { }
                if ($n -gt 0 -and ([Text.Encoding]::ASCII.GetString($buf, 0, $n)) -match '^HTTP/') { $kind = 'http' }
            }
        } catch { } finally { $cl.Close() }

        # 2) otherwise probe SOCKS5 on a fresh connection
        if ($kind -eq 'unknown') {
            $cl2 = New-Object System.Net.Sockets.TcpClient
            try {
                $iar2 = $cl2.BeginConnect('127.0.0.1', $m.Port, $null, $null)
                if ($iar2.AsyncWaitHandle.WaitOne(500) -and $cl2.Connected) {
                    $st2 = $cl2.GetStream(); $st2.ReadTimeout = 700; $st2.WriteTimeout = 700
                    $st2.Write([byte[]](5, 1, 0), 0, 3); $st2.Flush()
                    $hello = New-Object byte[] 2
                    $n2 = 0
                    try { $n2 = $st2.Read($hello, 0, 2) } catch { }
                    if ($n2 -ge 1 -and $hello[0] -eq 5) { $kind = 'socks5' }
                }
            } catch { } finally { $cl2.Close() }
        }

        $scheme = if ($kind -eq 'socks5') { 'socks5' } else { 'http' }
        $found += [pscustomobject]@{
            Url   = '{0}://127.0.0.1:{1}' -f $scheme, $m.Port
            Label = '{0}  ·  {1}{2}' -f $m.Port, $m.Label, $(if ($kind -eq 'unknown') { '（未识别）' } else { '' })
            Kind  = $kind
        }
    }

    try {
        $ie = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
            $srv = [string]$ie.ProxyServer
            if ($srv -match '=') {
                $srv = ($srv -split ';' | Where-Object { $_ -match '^https?=' } | Select-Object -First 1)
                $srv = $srv -replace '^[^=]+=', ''
            }
            if ($srv -match '^\d+$') { $srv = '127.0.0.1:' + $srv }
            if ($srv -and $srv -notmatch '://') { $srv = 'http://' + $srv }
            if ($srv -and -not ($found | Where-Object { $_.Url -eq $srv })) {
                $found += [pscustomobject]@{ Url = $srv; Label = ('{0}  ·  系统代理' -f $srv); Kind = 'system' }
            }
        }
    } catch { }

    return $found
}
function Resolve-CodexAppExe {
    $repo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    $found = @()
    if (Test-Path -LiteralPath $repo) {
        Get-ChildItem -LiteralPath $repo -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'OpenAI.Codex_*' } |
            ForEach-Object {
                $r = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).PackageRootFolder
                if ($r) { $found += (Join-Path $r 'app\ChatGPT.exe') }
            }
    }
    Get-Process -Name 'ChatGPT', 'Codex' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path } |
        ForEach-Object { $found += $_.Path }
    $hit = $found | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($hit) { return $hit }
    return ''
}

function Test-ChromiumDir {
    # Electron / Chromium payloads carry these next to the executable.
    param([string] $Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $false }
    foreach ($f in 'icudtl.dat', 'resources.pak', 'chrome_elf.dll', 'chrome.dll',
                   'v8_context_snapshot.bin', 'resources\app.asar', 'resources\app\package.json') {
        if (Test-Path -LiteralPath (Join-Path $Dir $f)) { return $true }
    }
    return $false
}

function Find-ChromiumPayload {
    # Edge and VS Code ship a tiny stub next to a versioned payload folder
    # (Edge: Application\157.0.x\msedge.exe). Return the real binary when present.
    param([string] $ExePath)
    $dir = Split-Path -Parent $ExePath
    $leaf = Split-Path -Leaf $ExePath
    $subs = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Select-Object -First 20)
    foreach ($s in $subs) {
        if (-not (Test-ChromiumDir $s.FullName)) { continue }
        $cand = Join-Path $s.FullName $leaf
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return $null
}

function Test-ChromiumApp {
    param([string] $ExePath)
    $dir = Split-Path -Parent $ExePath
    if (Test-ChromiumDir $dir) { return $true }
    foreach ($s in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Select-Object -First 20)) {
        if (Test-ChromiumDir $s.FullName) { return $true }
    }
    return $false
}

function Resolve-AumidExe {
    # shell:AppsFolder\<PackageFamilyName>!<AppId> -> executable from AppxManifest.xml
    # PackageFamilyName = <Name>_<PublisherId>; the registry key is the PackageFullName
    # <Name>_<Version>_<Arch>_<ResourceId>_<PublisherId>, so match by prefix and suffix.
    param([string] $Aumid)
    $parts = $Aumid -split '!'
    $pfn = $parts[0]
    $appId = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    if ([string]::IsNullOrWhiteSpace($pfn)) { return $null }

    $segments = $pfn -split '_'
    if ($segments.Count -lt 2) { return $null }
    $publisher = $segments[-1]
    $pkgName = ($segments[0..($segments.Count - 2)] -join '_')

    $repo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    if (-not (Test-Path -LiteralPath $repo)) { return $null }
    $key = Get-ChildItem -LiteralPath $repo -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like ($pkgName + '_*') -and $_.PSChildName -like ('*_' + $publisher) } |
        Select-Object -First 1
    if (-not $key) { return $null }
    $root = (Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue).PackageRootFolder
    if (-not $root) { return $null }
    $manifest = Join-Path $root 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }

    $xml = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8
    foreach ($m in [regex]::Matches($xml, '<Application\b[^>]*>')) {
        $tag = $m.Value
        $exM = [regex]::Match($tag, 'Executable="([^"]+)"')
        if (-not $exM.Success) { continue }
        $idM = [regex]::Match($tag, 'Id="([^"]+)"')
        if ($appId -and $idM.Success -and $idM.Groups[1].Value -ne $appId) { continue }
        $rel = $exM.Groups[1].Value -replace '/', '\'
        $cand = Join-Path $root $rel
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return $null
}

function Resolve-AppTarget {
    <#
      Accepts a .exe or a desktop .lnk and returns the real executable to launch.
      Handles: plain exe, Electron app, Store app (.lnk -> explorer shell:AppsFolder),
      launcher trampolines (Codex.exe -> ChatGPT.exe), wrapper tools that carry the
      real exe in their arguments (RunAsDate.exe "...\FindIt.exe").
    #>
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw '路径为空' }
    if (-not (Test-Path -LiteralPath $Path)) { throw ('路径不存在：' + $Path) }

    $item = Get-Item -LiteralPath $Path
    $source = $null
    $exe = $null
    $note = ''

    if ($item.Extension -ieq '.exe') {
        $exe = $item.FullName
    } elseif ($item.Extension -ieq '.lnk') {
        $source = $item.FullName
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($item.FullName)
        $target = $sc.TargetPath
        $args = [string]$sc.Arguments

        if ($target -match '\\explorer\.exe$' -and $args -match 'shell:AppsFolder\\([^"\s]+)') {
            $exe = Resolve-AumidExe $Matches[1]
            $note = 'Store 应用（按包清单解析）'
        } elseif ($target -and $target -match '\.exe$' -and (Test-Path -LiteralPath $target)) {
            $wrapperNames = 'RunAsDate.exe', 'nircmd.exe', 'cmd.exe', 'powershell.exe',
                            'wscript.exe', 'cscript.exe', 'start.exe', 'conhost.exe'
            $leafTarget = [IO.Path]::GetFileName($target)
            $innerExe = $null
            if ($wrapperNames -contains $leafTarget) {
                $m = [regex]::Match($args, '"([^"]+\.exe)"')
                if (-not $m.Success) { $m = [regex]::Match($args, '(\S+\.exe)') }
                if ($m.Success -and (Test-Path -LiteralPath $m.Groups[1].Value)) { $innerExe = $m.Groups[1].Value }
            }
            # trampoline: Codex.exe only activates the packaged app; ChatGPT.exe is the real one
            $sibling = Join-Path (Split-Path -Parent $target) 'ChatGPT.exe'
            if ($innerExe) {
                $exe = (Resolve-Path -LiteralPath $innerExe).Path
                $note = '从启动参数中解析（包装器）'
            } elseif ([IO.Path]::GetFileName($target) -ieq 'Codex.exe' -and (Test-Path -LiteralPath $sibling)) {
                $exe = $sibling
                $note = '启动占位程序 -> 真实应用'
            } else {
                $exe = $target
            }
        } else {
            # wrapper tools: the real exe usually sits in the arguments
            $m = [regex]::Match($args, '"([^"]+\.exe)"')
            if (-not $m.Success) { $m = [regex]::Match($args, '(\S+\.exe)') }
            if ($m.Success -and (Test-Path -LiteralPath $m.Groups[1].Value)) {
                $exe = (Resolve-Path -LiteralPath $m.Groups[1].Value).Path
                $note = '从启动参数中解析'
            }
        }

        if (-not $exe) {
            $leaf = Split-Path -Leaf $target
            throw ('这个快捷方式指向的不是可直接启动的程序（{0}）。请选择它真正的 exe。' -f $leaf)
        }
    } else {
        throw ('只支持 .exe 或 .lnk，收到的是 {0}' -f $item.Extension)
    }

    if ($exe -match '\\Windows\\Installer\\') {
        throw '这是安装器/引导程序，不能作为应用加入。'
    }
    if (-not (Test-Path -LiteralPath $exe)) { throw ('解析到的程序不存在：' + $exe) }

    # Edge / VS Code keep a stub at the root and the real binary in a versioned folder.
    try {
        $payload = Find-ChromiumPayload $exe
        if ($payload) {
            $exe = $payload
            $note = (@($note, '已定位到版本子目录') | Where-Object { $_ }) -join '；'
        }
    } catch { }

    return [pscustomobject]@{
        Exe      = $exe
        Source   = $source
        Note     = $note
        Chromium = (Test-ChromiumApp $exe)
    }
}

function New-DefaultProfiles {
    $exe = Resolve-CodexAppExe
    $lockExes = @()
    if ($exe) {
        $appDir = Split-Path -Parent $exe
        $lockExes += $exe
        foreach ($rel in 'resources\codex.exe', 'resources\codex-code-mode-host.exe', 'resources\codex-command-runner.exe', 'codex.exe') {
            $p = Join-Path $appDir $rel
            if (Test-Path -LiteralPath $p) { $lockExes += $p }
        }
    }
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return @(
        [pscustomobject]@{
            id        = $id
            name      = 'Codex 桌面版'
            exe       = $exe
            proxy     = 'http://127.0.0.1:7890'
            extraArgs = ''
            chromium  = $true
            killFirst = $true
            allowProxyDown = $false
            lockExes  = $lockExes
            source    = ''
        }
    )
}

function Import-Profiles {
    if (Test-Path -LiteralPath $script:DataFile) {
        try {
            $raw = Get-Content -LiteralPath $script:DataFile -Raw -Encoding UTF8
            $obj = $raw | ConvertFrom-Json
            $list = @()
            foreach ($p in @($obj.profiles)) {
                if (-not $p) { continue }
                $pidValue = if ([string]::IsNullOrWhiteSpace([string]$p.id)) { [guid]::NewGuid().ToString('N').Substring(0, 8) } else { [string]$p.id }
                $list += [pscustomobject]@{
                    id        = $pidValue
                    name      = [string]$p.name
                    exe       = [string]$p.exe
                    proxy     = if ($p.proxy) { [string]$p.proxy } else { 'http://127.0.0.1:7890' }
                    extraArgs = [string]$p.extraArgs
                    chromium  = [bool]$p.chromium
                    killFirst = [bool]$p.killFirst
                    allowProxyDown = [bool]$p.allowProxyDown
                    source    = [string]$p.source
                    lockExes  = @($p.lockExes)
                }
            }
            if ($list.Count -gt 0) { $script:Profiles = $list; return }
        } catch {
            # fall through to defaults on a broken file
        }
    }
    $script:Profiles = @(New-DefaultProfiles)
    Save-Profiles
}

function Save-Profiles {
    $payload = [pscustomobject]@{ version = 1; profiles = @($script:Profiles) }
    $json = $payload | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($script:DataFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-Log {
    param([string] $Text, [string] $Color = '#333333')
    if (-not $script:Win) { Write-Host $Text; return }
    $box = $script:Win.FindName('logBox')
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $run = New-Object Windows.Documents.Run(('[{0}] {1}' -f $stamp, $Text))
    $run.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString($Color)
    $para = New-Object Windows.Documents.Paragraph
    $para.Margin = New-Object Windows.Thickness(0, 1, 0, 1)
    $para.Inlines.Add($run)
    $box.Document.Blocks.Add($para)
    $box.ScrollToEnd()
}

function Set-LockBoxText {
    param([string] $Text)
    $box = $script:Win.FindName('txtLockExes')
    $box.Document.Blocks.Clear()
    $para = New-Object Windows.Documents.Paragraph
    $para.Inlines.Add((New-Object Windows.Documents.Run($Text)))
    $box.Document.Blocks.Add($para)
}

function Get-Tag {
    param($Profile)
    $t = ($Profile.id -replace '[^A-Za-z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($t)) { $t = 'app' }
    return $t.ToLower()
}

function Repair-Profiles {
    <#
      Store apps move to a new folder on every update
      (OpenAI.Codex_26.1103.4239.0 -> OpenAI.Codex_26.1111.2228.0), which leaves the
      saved profiles pointing at a path that no longer exists. Detect that here and
      rewrite exe + lockExes to the currently installed package.
    #>
    $appExe = Resolve-CodexAppExe
    if (-not $appExe) { return }
    $appDir = Split-Path -Parent $appExe
    $changed = $false
    foreach ($p in $script:Profiles) {
        if (Test-Path -LiteralPath $p.exe) { continue }
        $oldDir = Split-Path -Parent $p.exe
        if ($oldDir -notlike '*\WindowsApps\OpenAI.Codex_*') { continue }
        if ((Split-Path -Leaf $p.exe) -notin @('ChatGPT.exe', 'Codex.exe')) { continue }

        $p.exe = $appExe
        $newLocks = @()
        foreach ($l in @($p.lockExes)) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            $idx = $l.ToLower().IndexOf('\app\')
            if ($idx -ge 0) {
                $tail = $l.Substring($idx + 5)          # resources\codex.exe ...
                $candidate = Join-Path $appDir $tail
                if (Test-Path -LiteralPath $candidate) { $newLocks += $candidate }
            } elseif (Test-Path -LiteralPath (Join-Path $appDir (Split-Path -Leaf $l))) {
                $newLocks += (Join-Path $appDir (Split-Path -Leaf $l))
            }
        }
        if ($newLocks.Count -eq 0) { $newLocks = @($appExe) }
        $p.lockExes = @($newLocks | Sort-Object -Unique)
        $changed = $true
        Add-Log ('检测到应用已升级，已自动更新路径：{0}' -f (Split-Path -Leaf $appDir)) '#2F6FEB'
    }
    if ($changed) { Save-Profiles }
}

function New-ProfileFromTarget {
    param([string] $Path, [string] $Proxy)
    $r = Resolve-AppTarget $Path
    $name = if ($Path -match '\.lnk$') {
        [IO.Path]::GetFileNameWithoutExtension($Path)
    } else {
        [IO.Path]::GetFileNameWithoutExtension($r.Exe)
    }

    # keep the multi-exe lock list for packaged Electron apps such as Codex
    $lockExes = @($r.Exe)
    $appDir = Split-Path -Parent $r.Exe
    if (Test-Path -LiteralPath (Join-Path $appDir 'resources\codex.exe')) {
        foreach ($rel in 'resources\codex.exe', 'resources\codex-code-mode-host.exe', 'resources\codex-command-runner.exe', 'codex.exe') {
            $p = Join-Path $appDir $rel
            if (Test-Path -LiteralPath $p) { $lockExes += $p }
        }
    }

    return [pscustomobject]@{
        id             = [guid]::NewGuid().ToString('N').Substring(0, 8)
        name           = $name
        exe            = $r.Exe
        proxy          = $Proxy
        extraArgs      = ''
        chromium       = [bool]$r.Chromium
        killFirst      = $true
        allowProxyDown = $false
        lockExes       = @($lockExes | Sort-Object -Unique)
        source         = $r.Source
    }
}

function Add-ProfileFromTarget {
    param([string] $Path)
    $proxy = 'http://127.0.0.1:7890'
    if ($script:Current -ge 0 -and $script:Current -lt $script:Profiles.Count) {
        $proxy = $script:Profiles[$script:Current].proxy
    }
    $p = New-ProfileFromTarget -Path $Path -Proxy $proxy
    $script:Profiles += $p
    $script:Current = $script:Profiles.Count - 1
    Save-Profiles
    Update-List
    $script:Win.FindName('listProfiles').SelectedIndex = $script:Current
    Add-Log ('已添加：{0}' -f $p.name) '#27AE60'
    Add-Log ('  程序：{0}' -f $p.exe) '#555555'
    if ($p.source) { Add-Log ('  来源：{0}' -f (Split-Path -Leaf $p.source)) '#555555' }
    Add-Log ('  Chromium：{0}   锁定进程：{1} 个' -f $p.chromium, $p.lockExes.Count) '#555555'
}

function Get-LockCount {
    param($Profile)
    $prefix = 'AppNet-{0}-Block-' -f (Get-Tag $Profile)
    return @(Get-NetFirewallRule -DisplayName ($prefix + '*') -ErrorAction SilentlyContinue).Count
}

# ------------------------------------------------------------------ data <-> form
function Update-List {
    $lb = $script:Win.FindName('listProfiles')
    $lb.Items.Clear()
    foreach ($p in $script:Profiles) { $lb.Items.Add($p.name) | Out-Null }
    if ($script:Profiles.Count -gt 0) {
        $idx = [Math]::Min([Math]::Max($script:Current, 0), $script:Profiles.Count - 1)
        $lb.SelectedIndex = $idx
        $script:Current = $idx
    }
}

function Show-Profile {
    param($Profile)
    $w = $script:Win
    $w.FindName('txtName').Text      = [string]$Profile.name
    $w.FindName('txtExe').Text       = [string]$Profile.exe
    $w.FindName('txtProxy').Text     = [string]$Profile.proxy
    $w.FindName('txtArgs').Text      = [string]$Profile.extraArgs
    $w.FindName('chkChromium').IsChecked = [bool]$Profile.chromium
    $w.FindName('chkKill').IsChecked     = [bool]$Profile.killFirst
    $w.FindName('chkAllowDown').IsChecked = [bool]$Profile.allowProxyDown
    $lockBox = $w.FindName('txtLockExes')
    Set-LockBoxText ([string](@($Profile.lockExes) -join "`r`n"))
    $count = Get-LockCount $Profile
    $w.FindName('txtLockState').Text = if ($count -gt 0) { ('防火墙：已锁定（{0} 条规则）' -f $count) } else { '防火墙：未锁定' }
}

function Read-Form {
    $w = $script:Win
    $lockText = (New-Object Windows.Documents.TextRange($w.FindName('txtLockExes').Document.ContentStart, $w.FindName('txtLockExes').Document.ContentEnd)).Text
    $lockExes = @($lockText -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return [pscustomobject]@{
        name      = $w.FindName('txtName').Text.Trim()
        exe       = $w.FindName('txtExe').Text.Trim()
        proxy     = $w.FindName('txtProxy').Text.Trim()
        extraArgs = $w.FindName('txtArgs').Text.Trim()
        chromium  = [bool]$w.FindName('chkChromium').IsChecked
        killFirst = [bool]$w.FindName('chkKill').IsChecked
        allowProxyDown = [bool]$w.FindName('chkAllowDown').IsChecked
        lockExes  = $lockExes
    }
}

function Commit-Form {
    param([switch] $Quiet)
    $form = Read-Form
    if ([string]::IsNullOrWhiteSpace($form.name)) { throw '请填写应用名称' }
    if ([string]::IsNullOrWhiteSpace($form.exe)) { throw '请选择程序路径' }
    $null = Convert-ProxyUrl $form.proxy
    if ($script:Current -ge 0 -and $script:Current -lt $script:Profiles.Count) {
        $p = $script:Profiles[$script:Current]
        if ($p.exe -and ($p.exe -ine $form.exe)) { $p.source = '' }   # manual edit invalidates the shortcut hint
        $p.name = $form.name; $p.exe = $form.exe; $p.proxy = $form.proxy
        $p.extraArgs = $form.extraArgs; $p.chromium = $form.chromium
        $p.killFirst = $form.killFirst; $p.lockExes = $form.lockExes
        $p.allowProxyDown = $form.allowProxyDown
    } else {
        $script:Profiles += [pscustomobject]@{
            id = [guid]::NewGuid().ToString('N').Substring(0, 8)
            name = $form.name; exe = $form.exe; proxy = $form.proxy
            extraArgs = $form.extraArgs; chromium = $form.chromium
            killFirst = $form.killFirst; lockExes = $form.lockExes
            allowProxyDown = $form.allowProxyDown
            source = ''
        }
        $script:Current = $script:Profiles.Count - 1
    }
    Save-Profiles
    Update-List
    if (-not $Quiet) { Add-Log ('已保存配置：{0}' -f $form.name) '#2F6FEB' }
}

# ------------------------------------------------------------------ actions
function Start-Profile {
    $form = Read-Form
    if (-not (Test-Path -LiteralPath $form.exe) -and $script:Current -ge 0 -and $script:Current -lt $script:Profiles.Count) {
        $src = $script:Profiles[$script:Current].source
        if ($src -and (Test-Path -LiteralPath $src)) {
            try {
                $r = Resolve-AppTarget $src
                $script:Win.FindName('txtExe').Text = $r.Exe
                $script:Profiles[$script:Current].exe = $r.Exe
                Save-Profiles
                $form = Read-Form
                Add-Log ('原路径已失效，已按快捷方式重新解析：{0}' -f $r.Exe) '#E67E22'
            } catch { }
        }
    }
    $uri = Convert-ProxyUrl $form.proxy
    $proxyUrl = '{0}://{1}:{2}' -f $uri.Scheme, $uri.Host, $uri.Port
    if (-not (Test-TcpPort -TargetHost $uri.Host -Port $uri.Port)) {
        Add-Log ('代理端口未监听（{0}:{1}），已阻止启动。' -f $uri.Host, $uri.Port) '#C0392B'
        return
    }
    Add-Log ('端口 {0}:{1} 在监听，正在验证经代理能否真正连通…' -f $uri.Host, $uri.Port) '#888888'
    $tunnel = Test-ProxyTunnel -ProxyUri $uri
    if (-not $tunnel.Ok) {
        Add-Log ('经代理连不通：{0}' -f $tunnel.Detail) '#C0392B'
        if (-not $form.allowProxyDown) {
            Add-Log '已阻止启动：端口在听不等于代理可用。确需强制启动请勾选“代理不可达时仍允许启动”。' '#C0392B'
            return
        }
        Add-Log '按配置强制启动（代理当前不可用）。' '#E67E22'
    } else {
        Add-Log $tunnel.Detail '#27AE60'
    }
    if (-not (Test-Path -LiteralPath $form.exe)) { Add-Log ('程序不存在：{0}' -f $form.exe) '#C0392B'; return }

    if ($form.killFirst) {
        $procName = [IO.Path]::GetFileNameWithoutExtension($form.exe)
        $targets = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and ($_.Path -ieq $form.exe -or $_.ProcessName -ieq $procName)
        })
        if ($targets.Count -gt 0) {
            Add-Log ('结束已运行的进程：{0} 个' -f $targets.Count) '#888888'
            $targets | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 1500
        }
    }

    $noProxy = 'localhost,127.0.0.1,::1'
    foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy') {
        Set-Item -Path ('env:' + $n) -Value $proxyUrl
    }
    foreach ($n in 'NO_PROXY', 'no_proxy') {
        Set-Item -Path ('env:' + $n) -Value $noProxy
    }

    $argList = @()
    if ($form.chromium) { $argList += ('--proxy-server={0}' -f $proxyUrl) }
    if ($form.extraArgs) { $argList += $form.extraArgs }

    Start-Process -FilePath $form.exe -ArgumentList $argList | Out-Null
    Add-Log ('已启动：{0}  代理={1}' -f (Split-Path -Leaf $form.exe), $proxyUrl) '#27AE60'
    Add-Log '提示：若应用已在运行，请勾选“启动前关闭同名进程”后重新启动。' '#888888'
}

function Invoke-Lock {
    $form = Read-Form
    if (-not $form.lockExes -or $form.lockExes.Count -eq 0) { Add-Log '锁定列表为空：请至少填写一个 exe 路径' '#C0392B'; return }
    Commit-Form -Quiet
    $tag = Get-Tag $script:Profiles[$script:Current]
    $logFile = Join-Path $env:TEMP ('appnet-{0}.log' -f [guid]::NewGuid().ToString('N'))
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:LockScript),
        '-Tag', $tag, '-Action', 'Lock', '-LogPath', ('"{0}"' -f $logFile), '-Exe')
    $argList += (($form.lockExes | ForEach-Object { '"{0}"' -f $_ }) -join ',')
    try {
        Add-Log '请求管理员权限（UAC）…' '#E67E22'
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait | Out-Null
    } catch {
        Add-Log ('提权失败或被取消：{0}' -f $_.Exception.Message) '#C0392B'
        return
    }
    if (Test-Path -LiteralPath $logFile) {
        foreach ($line in (Get-Content -LiteralPath $logFile -Encoding UTF8)) { Add-Log ('  ' + $line) '#555555' }
        Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    }
    Show-Profile $script:Profiles[$script:Current]
}

function Invoke-Unlock {
    $form = Read-Form
    Commit-Form -Quiet
    $tag = Get-Tag $script:Profiles[$script:Current]
    $logFile = Join-Path $env:TEMP ('appnet-{0}.log' -f [guid]::NewGuid().ToString('N'))
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:LockScript),
        '-Tag', $tag, '-Action', 'Unlock', '-LogPath', ('"{0}"' -f $logFile))
    try {
        Add-Log '请求管理员权限（UAC）…' '#E67E22'
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait | Out-Null
    } catch {
        Add-Log ('提权失败或被取消：{0}' -f $_.Exception.Message) '#C0392B'
        return
    }
    if (Test-Path -LiteralPath $logFile) {
        foreach ($line in (Get-Content -LiteralPath $logFile -Encoding UTF8)) { Add-Log ('  ' + $line) '#555555' }
        Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    }
    Show-Profile $script:Profiles[$script:Current]
}

function Invoke-ConnectionTest {
    $form = Read-Form
    $uri = Convert-ProxyUrl $form.proxy
    $procName = [IO.Path]::GetFileNameWithoutExtension($form.exe)
    $pids = @(Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { Add-Log ('{0} 没有在运行，无法采样。' -f $procName) '#E67E22'; return }

    Add-Log ('采样 {0} 的连接 6 秒（PID: {1}）…' -f $procName, ($pids -join ',')) '#888888'
    $seen = @{}
    $end = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $end) {
        foreach ($line in (netstat -ano -p tcp)) {
            $parts = ($line -split '\s+') | Where-Object { $_ }
            if ($parts.Count -lt 5 -or $parts[0] -ne 'TCP') { continue }
            $owner = 0
            if (-not [int]::TryParse($parts[4], [ref] $owner)) { continue }
            if ($pids -notcontains $owner) { continue }
            $key = $parts[1] + '|' + $parts[2]
            if (-not $seen.ContainsKey($key)) { $seen[$key] = [pscustomobject]@{ Local = $parts[1]; Foreign = $parts[2]; State = $parts[3] } }
        }
        Start-Sleep -Milliseconds 600
    }

    if ($seen.Count -eq 0) { Add-Log '采样期间没有连接；让应用发一条请求后再试。' '#E67E22'; return }
    $leaks = 0
    foreach ($k in ($seen.Keys | Sort-Object)) {
        $r = $seen[$k]
        $isLoop = $r.Foreign -match '^(127\.|\[::1\]|0\.0\.0\.0)'
        if ($isLoop) {
            Add-Log ('  [OK]    {0} -> {1}' -f $r.Local, $r.Foreign) '#27AE60'
        } else {
            $leaks++
            Add-Log ('  [LEAK]  {0} -> {1}' -f $r.Local, $r.Foreign) '#C0392B'
        }
    }
    if ($leaks -eq 0) { Add-Log '结论：全部流量都进了本地代理。' '#27AE60' }
    else { Add-Log ('结论：检测到 {0} 条绕过代理的直连，建议启用防火墙锁定。' -f $leaks) '#C0392B' }
}

function Invoke-ProxyTest {
    $form = Read-Form
    try { $uri = Convert-ProxyUrl $form.proxy } catch { Add-Log $_.Exception.Message '#C0392B'; return }
    if (Test-TcpPort -TargetHost $uri.Host -Port $uri.Port) {
        Add-Log ('端口可连：{0}:{1}' -f $uri.Host, $uri.Port) '#27AE60'
    } else {
        Add-Log ('端口不可达：{0}:{1}（代理客户端没开？）' -f $uri.Host, $uri.Port) '#C0392B'
        return
    }
    $t = Test-ProxyTunnel -ProxyUri $uri
    if ($t.Ok) { Add-Log $t.Detail '#27AE60' } else { Add-Log ('经代理不通：{0}' -f $t.Detail) '#C0392B' }
}

# ------------------------------------------------------------------ XAML
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CodexNet 应用代理器" Height="720" Width="1040"
        WindowStartupLocation="CenterScreen" FontFamily="Microsoft YaHei UI"
        AllowDrop="True" Background="#F4F6F9">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="170"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock Text="CodexNet 应用代理器" FontSize="22" FontWeight="SemiBold" Foreground="#1B2A41"/>
      <TextBlock Text="让指定应用只能通过指定代理访问外网；代理关闭即断网。" FontSize="12" Foreground="#6B7A90" Margin="0,3,0,0"/>
    </StackPanel>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="280"/>
        <ColumnDefinition Width="16"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="White" CornerRadius="8" Padding="10">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="应用列表" FontWeight="SemiBold" Foreground="#1B2A41" Margin="2,0,0,8"/>
          <ListBox Grid.Row="1" x:Name="listProfiles" BorderBrush="#DDE3EC" FontSize="12"/>
          <StackPanel Grid.Row="2" Margin="0,8,0,0">
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnNew" Content="新建" Width="62" Height="30" Margin="0,0,6,0"/>
              <Button x:Name="btnAdd" Content="添加程序…" Width="106" Height="30" Margin="0,0,6,0"/>
              <Button x:Name="btnDelete" Content="删除" Width="62" Height="30"/>
            </StackPanel>
            <TextBlock Text="也可以把桌面快捷方式直接拖进窗口" FontSize="10.5" Foreground="#8A98AB"
                       Margin="2,6,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Grid>
      </Border>

      <Border Grid.Column="2" Background="White" CornerRadius="8" Padding="16">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="96"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <TextBlock Grid.Row="0" Grid.Column="0" Text="应用名称" VerticalAlignment="Center" Foreground="#4A5A70"/>
          <TextBox   Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="2" x:Name="txtName" Height="30" Margin="0,4" VerticalContentAlignment="Center" Padding="6,0"/>

          <TextBlock Grid.Row="1" Grid.Column="0" Text="程序路径" VerticalAlignment="Center" Foreground="#4A5A70"/>
          <TextBox   Grid.Row="1" Grid.Column="1" x:Name="txtExe" Height="30" Margin="0,4" VerticalContentAlignment="Center" Padding="6,0"/>
          <Button    Grid.Row="1" Grid.Column="2" x:Name="btnBrowse" Content="浏览" Width="70" Height="30" Margin="8,4,0,4"/>

          <TextBlock Grid.Row="2" Grid.Column="0" Text="代理地址" VerticalAlignment="Center" Foreground="#4A5A70"/>
          <TextBox   Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" x:Name="txtProxy" Height="30" Margin="0,4" VerticalContentAlignment="Center" Padding="6,0"/>

          <TextBlock Grid.Row="3" Grid.Column="0" Text="本机代理" VerticalAlignment="Center" Foreground="#4A5A70"/>
          <ComboBox  Grid.Row="3" Grid.Column="1" x:Name="cmbProxy" Height="30" Margin="0,4" FontSize="12"
                     VerticalContentAlignment="Center" DisplayMemberPath="Label"
                     ToolTip="点右侧「扫描」列出本机正在监听的代理（HTTP / SOCKS5 / 系统代理）"/>
          <Button    Grid.Row="3" Grid.Column="2" x:Name="btnScan" Content="扫描" Width="70" Height="30" Margin="8,4,0,4"/>

          <TextBlock Grid.Row="4" Grid.Column="0" Text="启动参数" VerticalAlignment="Center" Foreground="#4A5A70"/>
          <TextBox   Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2" x:Name="txtArgs" Height="30" Margin="0,4" VerticalContentAlignment="Center" Padding="6,0"/>

          <WrapPanel Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,6,0,0">
            <CheckBox x:Name="chkChromium" Content="Chromium/Electron 应用（附加 --proxy-server）" IsChecked="True" Margin="0,0,22,6" Foreground="#4A5A70"/>
            <CheckBox x:Name="chkKill" Content="启动前关闭同名进程" IsChecked="True" Margin="0,0,22,6" Foreground="#4A5A70"/>
            <CheckBox x:Name="chkAllowDown" Content="代理不可达时仍允许启动" Margin="0,0,0,6" Foreground="#4A5A70"/>
          </WrapPanel>

          <TextBlock Grid.Row="6" Grid.Column="0" Text="锁定进程" VerticalAlignment="Top" Margin="0,10,0,0" Foreground="#4A5A70"/>
          <RichTextBox Grid.Row="6" Grid.Column="1" Grid.ColumnSpan="2" x:Name="txtLockExes" Height="86" Margin="0,8,0,4"
                       BorderBrush="#DDE3EC" FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto"/>

          <StackPanel Grid.Row="7" Grid.Column="1" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,10,0,0">
            <Button x:Name="btnSave" Content="保存配置" Width="110" Height="32" Background="#2F6FEB" Foreground="White" BorderThickness="0"/>
            <TextBlock x:Name="txtLockState" Text="防火墙：未锁定" VerticalAlignment="Center" Margin="16,0,0,0" Foreground="#6B7A90"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>

    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,14,0,10">
      <Button x:Name="btnStart" Content="启动应用" Width="120" Height="36" Background="#27AE60" Foreground="White" BorderThickness="0"/>
      <Button x:Name="btnLock" Content="防火墙锁定" Width="120" Height="36" Margin="10,0,0,0"/>
      <Button x:Name="btnUnlock" Content="解锁" Width="90" Height="36" Margin="10,0,0,0"/>
      <Button x:Name="btnTestProxy" Content="测试代理" Width="100" Height="36" Margin="10,0,0,0"/>
      <Button x:Name="btnSelfCheck" Content="网络自检" Width="100" Height="36" Margin="10,0,0,0"/>
      <Button x:Name="btnOpenDir" Content="打开目录" Width="100" Height="36" Margin="10,0,0,0"/>
    </StackPanel>

    <Border Grid.Row="3" Background="#1B2A41" CornerRadius="8" Padding="10">
      <RichTextBox x:Name="logBox" Background="Transparent" Foreground="#D6E1F0" BorderThickness="0"
                   FontFamily="Consolas" FontSize="12" IsReadOnly="True" VerticalScrollBarVisibility="Auto"/>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$script:Win = [Windows.Markup.XamlReader]::Load($reader)

# window / taskbar icon (optional asset)
$icoPath = Join-Path $script:Root 'assets\codexnet.ico'
if (Test-Path -LiteralPath $icoPath) {
    try {
        $fs = [IO.File]::OpenRead($icoPath)
        try {
            $script:Win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create(
                $fs,
                [Windows.Media.Imaging.BitmapCreateOptions]::None,
                [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        } finally { $fs.Close() }
    } catch { }
}

# ------------------------------------------------------------------ wiring
$w = $script:Win

$w.FindName('listProfiles').Add_SelectionChanged({
    $lb = $script:Win.FindName('listProfiles')
    if ($lb.SelectedIndex -lt 0) { return }
    $script:Current = $lb.SelectedIndex
    Show-Profile $script:Profiles[$script:Current]
})

$w.FindName('btnAdd').Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = '选择要加入的程序或桌面快捷方式'
    $dlg.Filter = '快捷方式或程序 (*.lnk;*.exe)|*.lnk;*.exe|所有文件 (*.*)|*.*'
    $dlg.Multiselect = $false
    if (-not $dlg.ShowDialog()) { return }
    try {
        Add-ProfileFromTarget -Path $dlg.FileName
    } catch {
        Add-Log ('添加失败：{0}' -f $_.Exception.Message) '#C0392B'
    }
})

$w.Add_Drop({
    param($sender, $e)
    try {
        $files = @($e.Data.GetData('FileDrop'))
        if (-not $files -or $files.Count -eq 0) { return }
        $added = 0
        foreach ($f in $files) {
            if ($f -notmatch '\.(lnk|exe)$') { continue }
            try { Add-ProfileFromTarget -Path $f; $added++ }
            catch { Add-Log ('跳过 {0}：{1}' -f (Split-Path -Leaf $f), $_.Exception.Message) '#E67E22' }
        }
        if ($added -gt 0) { $e.Handled = $true }
    } catch {
        Add-Log ('拖放失败：{0}' -f $_.Exception.Message) '#C0392B'
    }
})

$w.FindName('btnNew').Add_Click({
    $script:Current = -1
    $script:Win.FindName('listProfiles').SelectedIndex = -1
    $w2 = $script:Win
    $w2.FindName('txtName').Text = '新应用'
    $w2.FindName('txtExe').Text = ''
    $w2.FindName('txtProxy').Text = 'http://127.0.0.1:7890'
    $w2.FindName('txtArgs').Text = ''
    $w2.FindName('chkChromium').IsChecked = $false
    $w2.FindName('chkKill').IsChecked = $true
    $w2.FindName('chkAllowDown').IsChecked = $false
    $w2.FindName('txtLockExes').Document.Blocks.Clear()
    $w2.FindName('txtLockState').Text = '防火墙：未锁定'
    Add-Log '新建配置：填写后点“保存配置”。' '#2F6FEB'
})

$w.FindName('btnDelete').Add_Click({
    if ($script:Current -lt 0 -or $script:Current -ge $script:Profiles.Count) { return }
    $name = $script:Profiles[$script:Current].name
    $script:Profiles = @($script:Profiles | Where-Object { $_ -ne $script:Profiles[$script:Current] })
    $script:Current = 0
    Save-Profiles
    Update-List
    Add-Log ('已删除：{0}' -f $name) '#888888'
})

$w.FindName('btnBrowse').Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
    if ($dlg.ShowDialog()) {
        $script:Win.FindName('txtExe').Text = $dlg.FileName
        $lockBox = $script:Win.FindName('txtLockExes')
        $cur = (New-Object Windows.Documents.TextRange($lockBox.Document.ContentStart, $lockBox.Document.ContentEnd)).Text.Trim()
        if (-not $cur) { Set-LockBoxText $dlg.FileName }
    }
})

$w.FindName('btnScan').Add_Click({
    try {
        Add-Log '正在扫描本机代理端口…' '#888888'
        $list = @(Find-LocalProxies)
        $cmb = $script:Win.FindName('cmbProxy')
        $cmb.Items.Clear()
        if ($list.Count -eq 0) {
            Add-Log '没有发现正在监听的代理。确认代理客户端已启动。' '#C0392B'
            return
        }
        foreach ($item in $list) { [void]$cmb.Items.Add($item) }
        Add-Log ('发现 {0} 个候选代理：' -f $list.Count) '#27AE60'
        foreach ($item in $list) { Add-Log ('  {0}   [{1}]' -f $item.Label, $item.Url) '#555555' }
        $cur = $script:Win.FindName('txtProxy').Text.Trim()
        $match = $list | Where-Object { $_.Url -eq $cur } | Select-Object -First 1
        if ($match) { $cmb.SelectedItem = $match }
        else { $cmb.SelectedIndex = 0 }
    } catch {
        Add-Log ('扫描失败：{0}' -f $_.Exception.Message) '#C0392B'
    }
})

$w.FindName('cmbProxy').Add_SelectionChanged({
    $cmb = $script:Win.FindName('cmbProxy')
    if (-not $cmb.SelectedItem) { return }
    $script:Win.FindName('txtProxy').Text = [string]$cmb.SelectedItem.Url
})
$w.FindName('btnSave').Add_Click({
    try { Commit-Form } catch { Add-Log ('保存失败：{0}' -f $_.Exception.Message) '#C0392B' }
})

$w.FindName('btnStart').Add_Click({
    try { Start-Profile } catch { Add-Log ('启动失败：{0}' -f $_.Exception.Message) '#C0392B' }
})

$w.FindName('btnLock').Add_Click({
    try { Invoke-Lock } catch { Add-Log ('锁定失败：{0}' -f $_.Exception.Message) '#C0392B' }
})

$w.FindName('btnUnlock').Add_Click({
    try { Invoke-Unlock } catch { Add-Log ('解锁失败：{0}' -f $_.Exception.Message) '#C0392B' }
})

$w.FindName('btnTestProxy').Add_Click({
    try { Invoke-ProxyTest } catch { Add-Log ('测试失败：{0}' -f $_.Exception.Message) '#C0392B' }
})

$w.FindName('btnSelfCheck').Add_Click({
    try { Invoke-ConnectionTest } catch { Add-Log ('自检失败：{0}' -f $_.Exception.Message) '#C0392B' }
})

$w.FindName('btnOpenDir').Add_Click({
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:Root)
})

Import-Profiles
Repair-Profiles
Update-List
if ($script:Profiles.Count -gt 0) { Show-Profile $script:Profiles[0] }

if ($ResolvePath) {
    try {
        $r = Resolve-AppTarget $ResolvePath
        Write-Host ('exe      = {0}' -f $r.Exe)
        Write-Host ('chromium = {0}' -f $r.Chromium)
        if ($r.Note) { Write-Host ('note     = {0}' -f $r.Note) }
        if ($r.Source) { Write-Host ('source   = {0}' -f $r.Source) }
        exit 0
    } catch {
        Write-Host ('ERROR: {0}' -f $_.Exception.Message)
        exit 2
    }
}

if ($ScanProxies) {
    $list = @(Find-LocalProxies)
    if ($list.Count -eq 0) { Write-Host '没有发现正在监听的代理端口。'; exit 3 }
    foreach ($item in $list) { Write-Host ('{0,-42} {1}' -f $item.Url, $item.Label) }
    exit 0
}

if ($AddPath) {
    try {
        $p = New-ProfileFromTarget -Path $AddPath -Proxy 'http://127.0.0.1:7890'
        $p | ConvertTo-Json -Depth 4
        exit 0
    } catch {
        Write-Host ('ERROR: {0}' -f $_.Exception.Message)
        exit 2
    }
}

# ------------------------------------------------------------------ run
if ($SmokeTest) {
    $names = @('listProfiles', 'txtName', 'txtExe', 'txtProxy', 'txtArgs', 'txtLockExes', 'txtLockState',
        'chkChromium', 'chkKill', 'chkAllowDown', 'btnNew', 'btnAdd', 'btnDelete', 'btnBrowse', 'btnScan', 'cmbProxy', 'btnSave', 'btnStart',
        'btnLock', 'btnUnlock', 'btnTestProxy', 'btnSelfCheck', 'btnOpenDir', 'logBox')
    $missing = @()
    foreach ($n in $names) { if (-not $script:Win.FindName($n)) { $missing += $n } }
    if ($missing.Count -gt 0) {
        Write-Host ('SMOKE FAIL missing controls: {0}' -f ($missing -join ', '))
        exit 3
    }
    Write-Host ('SMOKE OK  controls={0}  profiles={1}  data={2}' -f $names.Count, $script:Profiles.Count, $script:DataFile)
    exit 0
}

if ($RenderPng) {
    # Off-screen render of the real UI, used to produce docs/screenshot.png
    Import-Profiles
    Repair-Profiles
    Update-List
    if ($script:Profiles.Count -gt 0) { Show-Profile $script:Profiles[0] }
    Add-Log '端口 127.0.0.1:7890 在监听，正在验证经代理能否真正连通…' '#888888'
    Add-Log '隧道连通：example.com -> HTTP/1.1 200 OK' '#27AE60'
    Add-Log '已启动：ChatGPT.exe  代理=http://127.0.0.1:7890' '#27AE60'
    Add-Log '防火墙：已锁定 4 条规则（AppNet-*-Block-*）' '#2F6FEB'
    $script:Win.FindName('txtLockState').Text = '防火墙：已锁定（4 条规则）'

    $root = $script:Win.Content
    $root.Background = (New-Object Windows.Media.BrushConverter).ConvertFromString('#F4F6F9')
    $w = 1040; $h = 720
    $size = New-Object Windows.Size($w, $h)
    $root.Measure($size)
    $root.Arrange((New-Object Windows.Rect(0, 0, $w, $h)))
    $root.UpdateLayout()

    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($root)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $dir = Split-Path -Parent $RenderPng
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $fs = [IO.File]::Create($RenderPng)
    try { $enc.Save($fs) } finally { $fs.Close() }
    Write-Host ('rendered: {0}' -f $RenderPng)
    exit 0
}

$script:Win.ShowDialog() | Out-Null
