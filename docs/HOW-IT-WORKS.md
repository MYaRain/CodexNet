# How it works

Three layers, applied in order, with an optional fourth step that removes the escape hatches.

```
               ┌──────────────────────────────┐
               │  你的应用 / your app          │
               └──────────────┬───────────────┘
     ① Chromium flag          │          ② HTTP_PROXY / HTTPS_PROXY / ALL_PROXY
   --proxy-server=...         │          (inherited by child processes)
                              ▼
                   127.0.0.1:7890  (local proxy client)
                              ▲
     ③ firewall: outbound block for the listed .exe on everything except 127.0.0.0/8
```

## Layer ① — Chromium / Electron

`Start-CodexNet.ps1` and the GUI both append:

```text
--proxy-server=http://127.0.0.1:7890
```

Chromium parses this switch for the whole browser process tree: renderers, GPU process, WebSockets and
the built-in updater all use it. Because the proxy receives **hostnames** via `CONNECT`, DNS resolution
happens on the proxy side — there is no local DNS lookup to leak.

Caveat: Chromium bypasses the proxy for loopback by default (`--proxy-bypass-list` defaults to
`localhost`), which is what we want.

## Layer ② — environment variables

```powershell
HTTP_PROXY = HTTPS_PROXY = ALL_PROXY = http://127.0.0.1:7890
NO_PROXY   = localhost,127.0.0.1,::1
```

Notes that matter in practice:

* Both upper and lower case variants are set — Go's `net/http` reads `HTTP_PROXY`/`HTTPS_PROXY`,
  many Rust/Node stacks read either.
* `NO_PROXY` is intentionally **only loopback**. Leaving LAN ranges in there would re-open direct
  access to `192.168.*`, which is the opposite of the goal.
* These are set in the launcher process, so every child inherits them. Closing the launcher ends them.

## Layer ③ — firewall lock (optional, admin)

`Lock-AppNet.ps1` creates one outbound rule per executable:

```powershell
New-NetFirewallRule -DisplayName "AppNet-<tag>-Block-<exe>" `
    -Direction Outbound -Program <exe> -Action Block -Profile Any `
    -RemoteAddress '0.0.0.1-126.255.255.255','128.0.0.0-255.255.255.255'
```

Why these two ranges instead of `Any`:

* Windows Firewall **does not filter loopback traffic**, so `127.0.0.1:7890` would survive even with
  `Any`. Listing every address *except* `127.0.0.0/8` makes that guarantee explicit and keeps the rule
  readable in `wf.msc`.
* Blocking is protocol-agnostic, so QUIC/UDP and WebRTC cannot slip past a TCP-only proxy.
* Local subnet is inside the blocked ranges too, so the app cannot probe your LAN.

Rules are namespaced `AppNet-<tag>-Block-*`, where `<tag>` is derived from the profile id. Unlock
removes exactly that set and nothing else.

Elevation flow: the GUI calls `powershell.exe -Verb RunAs` with a `-LogPath` temp file, waits for the
elevated process, then replays the log lines into its own console. That is why the log pane shows the
firewall output even though the elevated process has its own console.

## The tunnel probe

A listening port is **not** evidence that the proxy works. A service-hosted core can keep the port
open long after the client UI says "stopped", with a dead subscription behind it. Port checks therefore
produce false positives, and a launcher gated on them is not really gated.

So `Test-ProxyTunnel` does the honest thing:

1. TCP connect to the proxy port;
2. `CONNECT example.com:80 HTTP/1.1` — a proxy that cannot dial upstream fails here;
3. if the proxy answers `200 Connection established`, send a real `GET / HTTP/1.0` **through the
   tunnel** and read the status line.

Only step 3 passing means bytes actually traversed the proxy to the internet. Any failure blocks the
launch unless the profile sets `allowProxyDown`.

## Data model

`profiles.json`, next to the scripts:

```json
{
  "version": 1,
  "profiles": [
    {
      "id": "2c85282f",
      "name": "ChatGPT desktop",
      "exe": "C:\\...\\app\\ChatGPT.exe",
      "proxy": "http://127.0.0.1:7890",
      "extraArgs": "",
      "chromium": true,
      "killFirst": true,
      "allowProxyDown": false,
      "lockExes": ["C:\\...\\app\\ChatGPT.exe", "C:\\...\\app\\resources\\codex.exe"]
    }
  ]
}
```

`profiles.json` is git-ignored on purpose: it contains absolute paths from the machine that created it.

## GUI architecture

* PowerShell 5.1 + WPF, XAML parsed with `XamlReader`. No Electron, no .NET SDK, no build step.
* `CodexNet.vbs` starts it with `wscript` and `-WindowStyle Hidden`, so there is no console flash.
* The app resolves the ChatGPT/Codex install path from the per-user AppModel registry key
  (`HKCU:\Software\Classes\Local Settings\...\AppModel\Repository\Packages`), because
  `C:\Program Files\WindowsApps` is not listable without elevation.
* Two encoding traps worth knowing if you fork it:
  * `.ps1` files **must** be UTF-8 **with BOM** — PowerShell 5.1 reads BOM-less files as ANSI and
    mangles non-ASCII string literals into syntax errors.
  * `.cmd` files should stay **pure ASCII** — a Chinese comment is enough to corrupt batch parsing
    under code page 936.

## Failure modes, by design

| Situation | Behaviour |
| --- | --- |
| Proxy port closed | Launch refused (`exit 3`) |
| Port open, tunnel dead | Launch refused unless `allowProxyDown` |
| App already running | Warns; `-Restart` kills it first because Electron is single-instance |
| Firewall lock on an app that ignores proxies | App loses all network — unlock to recover |
| App upgraded to a new version folder | The GUI rewrites the profile path on startup (`Repair-Profiles`); re-locking prunes rules whose program no longer exists and refreshes changed ones |
