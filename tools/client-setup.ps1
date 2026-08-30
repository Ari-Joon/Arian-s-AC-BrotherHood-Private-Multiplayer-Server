<#
  One-command setup for someone JOINING a server. Not the host.

  Does everything a player needs and nothing they do not:
    - adds the hosts entry that points the game at the host (self-elevates)
    - checks the host is actually reachable before claiming success
    - saves the account the host gave them
    - launches the game

  Deliberately does NOT touch textures. Textures are drawn locally and the match
  synchronises player state, not art, so a player on stock textures and a player
  on upscaled ones see different things and play the same match. Making the
  texture pass part of joining would turn a two-minute setup into an afternoon
  for no gain.

  USAGE
    powershell -ExecutionPolicy Bypass -File tools\client-setup.ps1 -HostIP 26.1.2.3 -User YourName -Password whatever

  Re-running it is safe: the hosts entry is replaced rather than duplicated.
#>
param(
    [Parameter(Mandatory)] [string]$HostIP,
    [string]$User,
    [string]$Password,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$hostsFile = "$env:WINDIR\System32\drivers\etc\hosts"
$entryName = "onlineconfigservice.ubi.com"

function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  $m" -ForegroundColor Red; exit 1 }

Write-Host "`nAC Brotherhood - joining $HostIP" -ForegroundColor Cyan

# --- 1. hosts entry, elevating only if it is actually needed -----------------
$current = (Select-String -Path $hostsFile -Pattern "^\s*([\d\.]+)\s+$([regex]::Escape($entryName))" -ErrorAction SilentlyContinue |
            Select-Object -Last 1).Matches.Groups[1].Value

if ($current -eq $HostIP) {
    Ok "hosts entry already points at $HostIP"
} else {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        Write-Host "  hosts file needs admin - relaunching elevated" -ForegroundColor Yellow
        $argv = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-HostIP',$HostIP)
        if ($User)     { $argv += @('-User',$User) }
        if ($Password) { $argv += @('-Password',$Password) }
        if ($NoLaunch) { $argv += '-NoLaunch' }
        Start-Process powershell -Verb RunAs -ArgumentList $argv
        exit 0
    }
    # Replace any existing line rather than appending a second one - two entries
    # for the same name resolve unpredictably and look like a server outage.
    $lines = @(Get-Content $hostsFile | Where-Object { $_ -notmatch [regex]::Escape($entryName) })
    $lines += "$HostIP`t$entryName"
    Set-Content $hostsFile $lines -Encoding ascii
    Ok "hosts entry set to $HostIP"
    if ($current) { Warn "replaced a previous entry pointing at $current" }
}

# --- 2. prove the host is reachable before saying it worked -----------------
Write-Host "`nChecking the host is reachable" -ForegroundColor Cyan
if (Test-Connection -ComputerName $HostIP -Count 2 -Quiet -ErrorAction SilentlyContinue) {
    Ok "$HostIP responds"
} else {
    Warn "$HostIP does not respond to ping."
    Warn "Are you on the host's Radmin VPN network? That is the usual cause."
    Warn "Some machines block ping - if the host says you are on the VPN, carry on."
}
$tcp = Test-NetConnection -ComputerName $HostIP -Port 80 -WarningAction SilentlyContinue
if ($tcp.TcpTestSucceeded) { Ok "TCP 80 open - the server is listening" }
else { Warn "TCP 80 closed. The host's server may not be running, or a firewall is blocking it." }

# --- 3. remember the account -------------------------------------------------
$cfgPath = Join-Path $PSScriptRoot "settings.json"
if ($User) {
    $cfg = @{}
    if (Test-Path $cfgPath) {
        try { (Get-Content $cfgPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch {}
    }
    $cfg['User'] = $User
    if (-not $cfg.ContainsKey('Display')) { $cfg['Display'] = 'Borderless' }
    $cfg | ConvertTo-Json | Set-Content $cfgPath -Encoding utf8
    Ok "account '$User' saved"
} else {
    Warn "no -User given; pick your account in the launcher"
}

# --- 4. play -----------------------------------------------------------------
Write-Host ""
if ($NoLaunch) {
    Write-Host "Setup done. Start the game with:" -ForegroundColor Green
    Write-Host "  powershell -STA -File tools\acb-settings.ps1"
    exit 0
}
Write-Host "Setup done - launching" -ForegroundColor Green
$launcher = Join-Path $PSScriptRoot "acb-launcher.ps1"
$a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$launcher`"",'-Display','Borderless')
if ($User)     { $a += @('-User',$User) }
if ($Password) { $a += @('-Password',$Password) }
Start-Process powershell -ArgumentList $a -WindowStyle Hidden
