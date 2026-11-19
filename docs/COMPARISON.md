# Comparison with existing tools

There is plenty of prior art, and most of it is more powerful than this project. The point of CodexNet
is not raw power — it is **zero driver, zero install, readable code, and an honest failure mode**.

Star counts are from the GitHub API in **November 2026** and will drift.

## The landscape

| Project | How it redirects traffic | License | ★ | Notes |
| --- | --- | --- | --- | --- |
| [wiresock/proxifyre](https://github.com/wiresock/proxifyre) | NDISAPI filter driver, per-app SOCKS5 | AGPL-3.0 | 1.6k | The reference "open-source Proxifier". Needs a kernel driver, admin install, SOCKS5 only. |
| [netchx/netch](https://github.com/netchx/netch) | NetFilter SDK, per-process rules, TUN variants | GPL-3.0 | 17.7k | Game-acceleration oriented; C# GUI; heavy, opinionated. |
| [shunf4/proxychains-windows](https://github.com/shunf4/proxychains-windows) | `CreateProcess` hook + MinHook DLL injection | GPL-2.0 | 1.1k | Elegant, but last pushed in 2022 and injection trips some anti-cheat / EDR. |
| [oliver804/Local-Route-Launcher](https://github.com/oliver804/Local-Route-Launcher) | Per-app HTTP proxy launcher for ChatGPT / Antigravity, no TUN, no system proxy change | MIT | 14 | The closest in *philosophy* to this repo. Launcher-only: no firewall backstop, no leak check. |
| [Over-Flowy/ProxyLatch](https://github.com/Over-Flowy/ProxyLatch) | WinDivert (Windows) / nftables + cgroups (Linux) | MIT | 2 | Ambitious feature set (kill switch, SNI sniffing, UDP/IPv6 leak blocking). Small project. |
| [sobdurated/kepler](https://github.com/sobdurated/kepler) | WinDivert kernel packet interception, SOCKS5 upstream | none stated | 2 | Same idea as ProxyLatch, Rust. |
| [rpfilomeno/ProxiFyre-Config-Manager](https://github.com/rpfilomeno/ProxiFyre-Config-Manager) | GUI / config generator for ProxiFyre | MIT | 22 | Useful if you already accepted the ProxiFyre driver. |
| Clash Verge Rev / mihomo / sing-box | TUN adapter or system proxy + `PROCESS-NAME` rules | GPL-3.0 | very large | You must already live inside that client. TUN takes over the whole machine, then you split it back with rules. |

## Where CodexNet sits

|  | Driver-based (ProxiFyre, Netch) | Injection (proxychains-windows) | TUN + rules (mihomo) | **CodexNet** |
| --- | --- | --- | --- | --- |
| Kernel driver | yes | no | yes (wintun) | **no** |
| Admin needed to run | yes | no | yes | **no** (only for the optional firewall lock) |
| Works on apps that ignore proxy settings | yes | yes | yes | **no** — those get cut off instead |
| Transparent / no cooperation from the app | yes | yes | yes | **no** for layer ①②, **yes** for layer ③ |
| Scope of side effects | system-wide driver | per process tree | system-wide adapter | **per profile, per exe** |
| Auditable in an afternoon | no (C++/driver) | partly | no | **yes** (PowerShell text) |
| License | AGPL / GPL | GPL | GPL | **MIT** |

## Choose something else when…

* **The app ignores `HTTP_PROXY`/`--proxy-server` and you need it proxied anyway.** Use ProxiFyre
  (SOCKS5) or ProxyLatch/kepler (WinDivert). CodexNet will only block it.
* **You need UDP/QUIC proxying or full IPv6 coverage.** Driver-based tools or TUN do this; the
  firewall layer here is IPv4 and per-executable.
* **You want one switch for the whole machine.** Enable TUN in your Clash-family client and use
  `PROCESS-NAME` rules.

## Choose CodexNet when…

* The target is a **Chromium/Electron app** (Codex, ChatGPT, VS Code forks, Slack-like clients) — the
  `--proxy-server` layer is exactly what it honours.
* You refuse to install a driver or an unsigned kernel component.
* You want the change to be **reversible from a GUI**, with a named firewall rule per executable
  instead of a system-wide routing table rewrite.
* You want the tool to **fail closed**: no proxy → no launch, rather than a silent direct connection.
