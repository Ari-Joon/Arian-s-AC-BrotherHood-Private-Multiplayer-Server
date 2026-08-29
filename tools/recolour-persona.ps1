<#
  Recolour a whole persona - every diffuse texture it owns - in one step.

  A persona is split across several resources (upper body, lower body, head).
  Recolouring them one at a time lets each measure its own tonal range, so the
  halves drift apart and the outfit no longer matches. This script measures the
  range ONCE across the persona and forces it on every texture.

  PREREQUISITE
    In AnvilToolkit, unpack multi\DataPC.forge, then unpack each of the
    persona's *_Set.data resources. This script finds whatever is unpacked and
    tells you what is missing.

  USAGE
    .\recolour-persona.ps1 -Persona Barber -Scheme gold_black
    .\recolour-persona.ps1 -Persona Barber -Status
    .\recolour-persona.ps1 -Persona Barber -Restore

  Afterwards repack in AnvilToolkit, inner .data files first, then DataPC.forge,
  with the game CLOSED - it holds the forge open and Repack fails silently.

  No game assets are distributed with this script.
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(Mandatory)]
    [string]$Persona,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateSet('gold_black', 'crimson_black', 'emerald_black', 'sapphire_black',
                 'bone_white', 'desaturate')]
    [string]$Scheme = 'gold_black',

    # Blocks more colourful than this keep their own colour, so leather, wood
    # and metal survive while near-grey cloth is recoloured.
    [Parameter(ParameterSetName = 'Apply')]
    [int]$MaxSaturation = 25,

    # Atlas cells to leave alone entirely, e.g. "G2,H2,H3,H4".
    [Parameter(ParameterSetName = 'Apply')]
    [string]$Keep = '',

    # Force a tonal range as black:white. Omit to measure it from the persona.
    [Parameter(ParameterSetName = 'Apply')]
    [string]$Levels = '',

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$Restore,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    # A face recoloured to match a costume looks like a rendering bug, so
    # head resources are skipped unless you ask for them.
    [switch]$IncludeHead,

    [string]$GamePath = "C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood"
)

$ErrorActionPreference = 'Stop'

$root    = Join-Path $GamePath "multi\Extracted\DataPC.forge\Extracted"
$backups = Join-Path $GamePath "multi\_persona_backup"
$engine  = Join-Path $PSScriptRoot "recolour_texture.py"

if (-not (Test-Path $root))   { Write-Host "Not unpacked: multi\DataPC.forge" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $engine)) { Write-Host "Missing $engine" -ForegroundColor Red; exit 1 }

# Which resources belong to this persona, and which are unpacked yet.
$containers = Get-ChildItem -Path (Split-Path $root) -Filter "*.data" -File |
              Where-Object { $_.Name -like "*$Persona*" }
if (-not $IncludeHead) {
    $containers = $containers | Where-Object { $_.Name -notmatch 'head' }
}
if (-not $containers) {
    Write-Host "No resources matching '$Persona' in DataPC.forge." -ForegroundColor Yellow
    Write-Host "Unpack multi\DataPC.forge first, or check the spelling." -ForegroundColor Yellow
    exit 1
}

$textures, $missing = @(), @()
foreach ($c in $containers) {
    $dir = Join-Path $root $c.Name
    if (Test-Path $dir) {
        $found = Get-ChildItem -Path $dir -Filter "*DiffuseMap.TextureMap" -File
        if ($found) { $textures += $found }
    } else {
        $missing += $c.Name
    }
}

Write-Host ""
Write-Host "Persona '$Persona'" -ForegroundColor Cyan
foreach ($t in $textures) { Write-Host ("   ready    " + $t.Name) -ForegroundColor Green }
foreach ($m in $missing)  { Write-Host ("   UNPACK   " + $m) -ForegroundColor Yellow }

if ($missing.Count) {
    Write-Host ""
    Write-Host "Unpack the above in AnvilToolkit, then rerun." -ForegroundColor Yellow
}
if (-not $textures) { exit 1 }

function Backup-Path([string]$name) { Join-Path $backups ($name -replace '\.TextureMap$', '_ORIGINAL.TextureMap') }

if ($Status) {
    Write-Host ""
    foreach ($t in $textures) {
        $b = Backup-Path $t.Name
        $state = if (Test-Path $b) { "recoloured (backup present)" } else { "original" }
        Write-Host ("   {0,-42} {1}" -f $t.Name, $state)
    }
    Write-Host ""
    return
}

if ($Restore) {
    Write-Host ""
    foreach ($t in $textures) {
        $b = Backup-Path $t.Name
        if (Test-Path $b) {
            & python $engine --texture $t.FullName --backup $b --restore
        } else {
            Write-Host ("   no backup for " + $t.Name + ", already original") -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "Now repack in AnvilToolkit, inner .data first, then DataPC.forge." -ForegroundColor Cyan
    return
}

# Measure the tonal range once, from whichever texture is still pristine, so
# every piece of the outfit lands on the same part of the ramp.
if (-not $Levels) {
    $probe = $textures[0]
    $pb = Backup-Path $probe.Name
    $src = if (Test-Path $pb) { $pb } else { $probe.FullName }
    $out = & python $engine --texture $src --scheme $Scheme --dry-run 2>&1
    $line = $out | Where-Object { $_ -match 'black\s+([\d.]+)\s+white\s+([\d.]+)' }
    if ($line -and $line -match 'black\s+([\d.]+)\s+white\s+([\d.]+)') {
        $Levels = "{0}:{1}" -f $Matches[1], $Matches[2]
        Write-Host ""
        Write-Host "   measured tonal range $Levels from $($probe.Name)" -ForegroundColor DarkGray
    }
}

Write-Host ""
foreach ($t in $textures) {
    Write-Host ("-- " + $t.Name) -ForegroundColor Cyan
    $argv = @('--texture', $t.FullName, '--scheme', $Scheme,
              '--backup', (Backup-Path $t.Name), '--max-saturation', $MaxSaturation)
    if ($Levels)  { $argv += @('--levels', $Levels) }
    if ($Keep)    { $argv += @('--keep', $Keep) }
    if ($DryRun)  { $argv += '--dry-run' }
    & python $engine @argv
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run - nothing was written." -ForegroundColor Yellow
} else {
    Write-Host "Now repack in AnvilToolkit, inner .data files first, then DataPC.forge." -ForegroundColor Cyan
    Write-Host "CLOSE THE GAME FIRST - it holds the forge open and Repack fails silently." -ForegroundColor Yellow
}
