<#
  Build a small zip a friend downloads, unpacks and plays from.

  WHAT GOES IN: only what a JOINING player needs - the launcher, the settings
  screen, the one-command setup, and the joining guide. About 100 KB.

  WHAT DOES NOT: the server and its database, AnvilKit, DS4Windows, the
  reverse-engineering notes, and above all NO GAME FILES. Players need their own
  legal copy; nothing here redistributes Ubisoft's data. The texture pipeline is
  offered as an optional extra rather than bundled, because it is useless
  without the 33 MB model, which is also not ours to ship.

  The host still sends three things out of band: the VPN network, an account
  name, and its password.

    .\make-client-pack.ps1
    .\make-client-pack.ps1 -IncludeUpscaler   # add the texture tools too
#>
param(
    [string]$OutDir = "$PSScriptRoot\..\dist",
    [switch]$IncludeUpscaler
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$stage = Join-Path $env:TEMP "acb-client-pack"

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $stage "tools") | Out-Null

# The joining player's whole world.
$core = @(
    "tools\client-setup.ps1",
    "tools\acb-launcher.ps1",
    "tools\acb-settings.ps1",
    "JOINING.md"
)
foreach ($f in $core) {
    $src = Join-Path $repo $f
    if (-not (Test-Path $src)) { throw "missing from the repo: $f" }
    Copy-Item $src (Join-Path $stage $f) -Force
}

if ($IncludeUpscaler) {
    New-Item -ItemType Directory -Force (Join-Path $stage "tools\texture-upscale") | Out-Null
    Get-ChildItem (Join-Path $repo "tools\texture-upscale") -Filter *.py |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $stage "tools\texture-upscale") -Force }
    Copy-Item (Join-Path $repo "tools\texture-upscale\run-all.ps1") (Join-Path $stage "tools\texture-upscale") -Force
    foreach ($d in "forge-extract","anvil-unpack","anvil-repack") {
        $t = Join-Path $stage "tools\$d"
        New-Item -ItemType Directory -Force $t | Out-Null
        Get-ChildItem (Join-Path $repo "tools\$d") -File | Where-Object { $_.Extension -in '.cs','.csproj' } |
            ForEach-Object { Copy-Item $_.FullName $t -Force }
    }
    # The model is NOT bundled - 33 MB, and not ours to redistribute.
    @"
Put RealESRGAN_x4plus.fp16.onnx in this folder before running run-all.ps1.
It is about 33 MB and is not included here.

Install the GPU runtime first or this takes hours instead of minutes:
    pip install onnxruntime-directml
"@ | Set-Content (Join-Path $stage "tools\texture-upscale\MODEL-GOES-HERE.txt") -Encoding utf8
}

# A first thing to read, so the zip explains itself without the README.
@"
AC Brotherhood - private server, client pack
===========================================

You need your own legal copy of the game. No game files are included.

1. Install Radmin VPN and join the network your host gives you.
2. Open PowerShell in this folder and run:

     powershell -ExecutionPolicy Bypass -File tools\client-setup.ps1 ``
         -HostIP <the host's 26.x.x.x address> -User <your name> -Password <your password>

   That points the game at the host, checks it is reachable, saves your
   account and launches. It needs admin once, to edit the hosts file.

3. After that, just run:

     powershell -STA -File tools\acb-settings.ps1

Full detail, including troubleshooting, is in JOINING.md.

You do NOT need the upscaled textures to play with the host. They are
drawn locally - you will see the stock game and the match works fine.
"@ | Set-Content (Join-Path $stage "READ ME FIRST.txt") -Encoding utf8

New-Item -ItemType Directory -Force $OutDir | Out-Null
$name = if ($IncludeUpscaler) { "acb-client-pack-with-upscaler.zip" } else { "acb-client-pack.zip" }
$zip = Join-Path $OutDir $name
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Optimal

# Refuse to ship anything that looks like game data, however it got staged.
$bad = Get-ChildItem $stage -Recurse -File |
       Where-Object { $_.Extension -in '.forge','.TextureMap','.data','.onnx' -or $_.Length -gt 5MB }
if ($bad) {
    Remove-Item $zip -Force
    Write-Host "REFUSED: these look like game data or are oversized:" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "   $($_.FullName)" -ForegroundColor Red }
    exit 1
}

Remove-Item $stage -Recurse -Force
$kb = [math]::Round((Get-Item $zip).Length / 1KB, 1)
Write-Host "  built $zip  ($kb KB)" -ForegroundColor Green
Write-Host "  send it with: the VPN network, an account name, and its password."
