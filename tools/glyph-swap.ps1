<#
  Switch the in-game CONTROLLER LAYOUT diagram between Xbox and PlayStation.

  Assassin's Creed Brotherhood ships BOTH glyph sets on PC:

      Binding_360_DiffuseMapDesc    Xbox 360 pad   (what the game asks for)
      Binding_PS3_DiffuseMapDesc    DualShock 3    (present, never requested)

  The PC executable only ever requests Binding_360, so the PlayStation art is
  orphaned. This script puts the artwork you want into the slot the game asks
  for, and can put it back.

  THE CRITICAL DETAIL
  Each TextureMap carries a 4-byte File ID at offset 2. Copying the PS3 texture
  wholesale brings its own ID along, the game cannot bind the texture, and the
  diagram renders as a flat grey block. This script always rewrites the ID to
  the 360's value, which is what makes the swap work.

  No game assets are distributed with this script - it reads both textures from
  your own installation.

  PREREQUISITES
    In AnvilToolkit, unpack in this order:
      1. multi\DataPC_extra.forge
      2. 1000_-_Binding_360_DiffuseMapDesc.data
      3. 1001_-_Binding_PS3_DiffuseMapDesc.data

  USAGE
    .\glyph-swap.ps1 -Set PlayStation
    .\glyph-swap.ps1 -Set Xbox
    .\glyph-swap.ps1 -Status

  Then repack in AnvilToolkit, inner first:
      1000_-_Binding_360_DiffuseMapDesc.data
      DataPC_extra.forge
  CLOSE THE GAME FIRST - it holds the forge open and Repack fails silently.
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory)]
    [ValidateSet('Xbox', 'PlayStation')]
    [string]$Set,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [string]$GamePath = "C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood"
)

$ErrorActionPreference = 'Stop'

# File IDs, little-endian at offset 2 of each TextureMap.
$ID_360 = 0x1D3FE3AF   # 490726319
$ID_PS3 = 0x1D3FE379   # 490726265

$ext     = Join-Path $GamePath "multi\Extracted\DataPC_extra.forge\Extracted"
$slot360 = Join-Path $ext "1000_-_Binding_360_DiffuseMapDesc.data\1_-_Binding_360_DiffuseMap.TextureMap"
$srcPS3  = Join-Path $ext "1001_-_Binding_PS3_DiffuseMapDesc.data\1_-_Binding_PS3_DiffuseMap.TextureMap"
$backup  = Join-Path $GamePath "multi\_glyph_backup\Binding_360_ORIGINAL.TextureMap"

function Require-Unpacked {
    $missing = @()
    if (-not (Test-Path $slot360)) { $missing += "1000_-_Binding_360_DiffuseMapDesc.data" }
    if (-not (Test-Path $srcPS3))  { $missing += "1001_-_Binding_PS3_DiffuseMapDesc.data" }
    if ($missing.Count) {
        Write-Host "Not unpacked yet:" -ForegroundColor Yellow
        $missing | ForEach-Object { Write-Host "   $_" -ForegroundColor Yellow }
        Write-Host "`nUnpack these in AnvilToolkit first (DataPC_extra.forge, then each .data)." -ForegroundColor Yellow
        exit 1
    }
}

function Get-FileId([string]$path) {
    $fs = [System.IO.File]::OpenRead($path)
    try { $b = New-Object byte[] 6; [void]$fs.Read($b, 0, 6); return [BitConverter]::ToUInt32($b, 2) }
    finally { $fs.Close() }
}

function Set-FileId([string]$path, [uint32]$id) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    [BitConverter]::GetBytes($id).CopyTo($bytes, 2)
    [System.IO.File]::WriteAllBytes($path, $bytes)
}

function Which-Artwork {
    # Compare payload past the header; the ID always reads as the 360's.
    if (-not (Test-Path $slot360)) { return 'unknown' }
    $cur = [System.IO.File]::ReadAllBytes($slot360)
    $ps3 = [System.IO.File]::ReadAllBytes($srcPS3)
    if ($cur.Length -ne $ps3.Length) { return 'Xbox' }
    for ($i = 6; $i -lt $cur.Length; $i++) {
        if ($cur[$i] -ne $ps3[$i]) { return 'Xbox' }
    }
    return 'PlayStation'
}

Require-Unpacked

# Keep a pristine copy of the stock Xbox texture the first time we touch it.
if (-not (Test-Path $backup)) {
    if ((Which-Artwork) -eq 'PlayStation') {
        Write-Host "The 360 slot already holds PlayStation artwork and no backup exists." -ForegroundColor Red
        Write-Host "Restore it by re-unpacking DataPC_extra.forge from a clean forge, then rerun." -ForegroundColor Red
        exit 1
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $backup) | Out-Null
    Copy-Item $slot360 $backup
    Write-Host "Saved pristine Xbox texture -> $backup" -ForegroundColor DarkGray
}

if ($PSCmdlet.ParameterSetName -eq 'Status' -or -not $Set) {
    $id = Get-FileId $slot360
    Write-Host ""
    Write-Host "  Current artwork : $(Which-Artwork)"
    Write-Host ("  File ID         : {0} (0x{0:X8}) {1}" -f $id, $(if ($id -eq $ID_360) { '- correct' } else { '- WRONG, game will not bind it' }))
    Write-Host "  Backup          : $(if (Test-Path $backup) { 'present' } else { 'missing' })"
    Write-Host ""
    return
}

switch ($Set) {
    'PlayStation' {
        Copy-Item $srcPS3 $slot360 -Force
        Set-FileId $slot360 $ID_360        # the step that makes it bind
        Write-Host "Set to PlayStation (DualShock) artwork." -ForegroundColor Green
    }
    'Xbox' {
        Copy-Item $backup $slot360 -Force
        Set-FileId $slot360 $ID_360
        Write-Host "Restored Xbox 360 artwork." -ForegroundColor Green
    }
}

$id = Get-FileId $slot360
Write-Host ("  artwork: {0}   File ID: {1} (0x{1:X8})" -f (Which-Artwork), $id)
Write-Host ""
Write-Host "Now repack in AnvilToolkit, inner first:" -ForegroundColor Cyan
Write-Host "   1. 1000_-_Binding_360_DiffuseMapDesc.data"
Write-Host "   2. DataPC_extra.forge"
Write-Host "Close the game first, or Repack fails silently." -ForegroundColor Yellow
