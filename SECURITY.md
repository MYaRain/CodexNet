# Security notes

CodexNet deliberately touches two sensitive surfaces: **process launch environment** and
**Windows Firewall rules**. This file states what it does and does not protect against.

## What the tool changes

1. **Environment variables of the process it launches** (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`,
   `NO_PROXY` and their lowercase forms). They are set inside the launcher/GUI process only and are
   inherited by the started child. Closing the launcher ends their lifetime. Nothing is written to the
   user or machine environment.
2. **Firewall rules** named `AppNet-<tag>-Block-<exe>`, outbound, blocking every remote address outside
   `127.0.0.0/8`, for the executables you listed. They require administrator rights and are removable
   with `Lock-AppNet.ps1 -Action Unlock -Tag <tag>` or the 解锁 button.

Nothing else is modified: no system proxy registry keys, no routes, no network adapters, no services,
no drivers.

## What it does not protect against

* **A local administrator can undo everything.** Firewall rules and elevated steps are not a security
  boundary against someone with admin rights on the same machine.
* **Child processes are not covered by firewall rules.** Rules are per executable. A program that spawns
  `curl --noproxy '*'` can still reach the network directly.
* **IPv6 is not blocked** by the firewall rules, which only list IPv4 address ranges.
* **Traffic is not inspected or decrypted.** The tool only decides routing; it does not read payloads.
* **It does not hide traffic from the network operator**, and it is not a circumvention guarantee.

## Supply chain

The whole project is plain-text PowerShell plus a VBScript launcher, with no binaries and no
dependencies. Read the scripts before running them — that is the point of shipping them as text.

`CodexNet.vbs` starts `powershell.exe -ExecutionPolicy Bypass -File CodexNet-GUI.ps1`. The
`-ExecutionPolicy Bypass` flag exists because downloaded `.ps1` files are refused by default; it applies
to that single invocation only and does not change machine policy.

## Reporting

Open a GitHub issue for anything that looks like unintended network exposure, an incomplete unlock, or
a rule that survives uninstall.
