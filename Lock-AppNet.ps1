#Requires -Version 5.1
<#
.SYNOPSIS
    Generic per-application network lock: block every non-loopback egress of the
    given executables, so their only possible way out is a local proxy.

.DESCRIPTION
    Creates Windows Firewall outbound rules named  AppNet-<tag>-Block-<exe>.
    Each rule blocks remote addresses outside 127.0.0.0/8 for every protocol
    (TCP + UDP, so QUIC bypass dies too). Windows Firewall does not filter
    loopback traffic, therefore 127.0.0.1:<proxy port> keeps working while the
    public internet and the LAN become unreachable for those processes.

    Used by the CodexNet GUI. Requires administrator rights (self-elevates).

.PARAMETER Exe
    One or more full paths of executables to lock.

.PARAMETER Tag
    Logical profile name; used in the rule display name so profiles can be
    locked / unlocked independently.

.PARAMETER Action
    Lock (default), Unlock, or Status.

.PARAMETER LogPath
    Optional file that receives the human readable result (for GUI use, because
    an elevated console cannot be captured by the caller).

.EXAMPLE
    .\Lock-AppNet.ps1 -Exe 'C:\Apps\foo.exe' -Tag foo -Action Lock

.EXAMPLE
    .\Lock-AppNet.ps1 -Tag foo -Action Unlock
#>
[CmdletBinding()]
param(
    [string[]] $Exe,
    [string] $Tag = 'app',
    [ValidateSet('Lock', 'Unlock', 'Status')]
    [string] $Action = 'Lock',
    [string] $LogPath,
    [switch] $Force,
    [switch] $NoElevate,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$IPv4OutsideLoopback = @('0.0.0.1-126.255.255.255', '128.0.0.0-255.255.255.255')
$log = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param([string] $Text, [string] $Color = 'Gray')
    $log.Add($Text)
    Write-Host $Text -ForegroundColor $Color
}

function Save-Log {
    if ($LogPath) {
        try { [IO.File]::WriteAllLines($LogPath, $log, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Convert-Tag {
    param([string] $Value)
    $t = ($Value -replace '[^A-Za-z0-9\-_]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($t)) { $t = 'app' }
    return $t
}

$safeTag = Convert-Tag $Tag
$rulePrefix = 'AppNet-{0}-Block-' -f $safeTag

# ---------------------------------------------------------------- Status
if ($Action -eq 'Status') {
    $rules = @(Get-NetFirewallRule -DisplayName ($rulePrefix + '*') -ErrorAction SilentlyContinue)
    Write-Log ('rules for tag "{0}": {1}' -f $safeTag, $rules.Count)
    foreach ($r in $rules) {
        $prog = ($r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
        Write-Log ('  {0} | enabled={1} | {2}' -f $r.DisplayName, $r.Enabled, $prog)
    }
    Save-Log
    exit 0
}

# ---------------------------------------------------------------- elevation
if (-not (Test-Admin)) {
    if ($NoElevate) {
        Write-Log 'ERROR: administrator rights required (run elevated).' 'Red'
        Save-Log
        exit 5
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Tag', $safeTag, '-Action', $Action)
    if ($Exe) { $argList += '-Exe'; $argList += (($Exe | ForEach-Object { '"{0}"' -f $_ }) -join ',') }
    if ($Force) { $argList += '-Force' }
    if ($DryRun) { $argList += '-DryRun' }
    if ($LogPath) { $argList += @('-LogPath', ('"{0}"' -f $LogPath)) }
    Write-Log 'requesting administrator elevation (UAC) ...' 'Yellow'
    Save-Log
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    exit 0
}

# ---------------------------------------------------------------- Unlock
if ($Action -eq 'Unlock') {
    $rules = @(Get-NetFirewallRule -DisplayName ($rulePrefix + '*') -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) {
        Write-Log ('no rules found for tag "{0}"' -f $safeTag) 'DarkGray'
        Save-Log
        exit 0
    }
    foreach ($r in $rules) {
        Write-Log ('remove: {0}' -f $r.DisplayName) 'DarkGray'
        if (-not $DryRun) { Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
    }
    Write-Log ('unlocked: {0} rule(s) removed' -f $rules.Count) 'Green'
    Save-Log
    exit 0
}

# ---------------------------------------------------------------- Lock
if (-not $Exe -or $Exe.Count -eq 0) {
    Write-Log 'ERROR: -Exe is required for Lock.' 'Red'
    Save-Log
    exit 6
}

Write-Log ('lock tag "{0}"' -f $safeTag) 'Cyan'

# App updates move the executable to a new folder, leaving rules that point at a
# path which no longer exists (they protect nothing). Prune those first.
foreach ($r in @(Get-NetFirewallRule -DisplayName ($rulePrefix + '*') -ErrorAction SilentlyContinue)) {
    $prog = ($r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
    if ($prog -and -not (Test-Path -LiteralPath $prog)) {
        Write-Log ('  prune stale: {0}' -f $r.DisplayName) 'Yellow'
        if (-not $DryRun) { Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
    }
}

$created = 0
foreach ($path in $Exe) {
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log ('  SKIP (not found): {0}' -f $path) 'Yellow'
        continue
    }
    $full = (Resolve-Path -LiteralPath $path).Path
    $leaf = [IO.Path]::GetFileName($full)
    $display = $rulePrefix + $leaf
    $existing = Get-NetFirewallRule -DisplayName $display -ErrorAction SilentlyContinue
    if ($existing) {
        $current = ($existing | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
        if ($current -ieq $full) {
            Write-Log ('  exists : {0}' -f $leaf) 'DarkGray'
            continue
        }
        Write-Log ('  refresh: {0} (old path -> new path)' -f $leaf) 'Yellow'
        if (-not $DryRun) { Remove-NetFirewallRule -Name $existing.Name -ErrorAction SilentlyContinue }
    }
    if ($DryRun) {
        Write-Log ('  would create: {0} -> {1}' -f $display, $full) 'DarkGray'
        continue
    }
    New-NetFirewallRule -DisplayName $display `
        -Direction Outbound `
        -Program $full `
        -Action Block `
        -Profile Any `
        -RemoteAddress $IPv4OutsideLoopback `
        -Enabled True -ErrorAction Stop | Out-Null
    $created++
    Write-Log ('  created: {0}' -f $leaf) 'Green'
}

Write-Log ('done. created={0}' -f $created) 'Green'
Save-Log
exit 0
