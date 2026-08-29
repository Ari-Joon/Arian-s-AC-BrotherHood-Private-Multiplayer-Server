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
    # A persona name, or -All for every persona that is unpacked.
    [string]$Persona = '',

    [switch]$All,

    # Personas to skip in -All mode, e.g. one you have already styled
    # differently and do not want reset.
    [string[]]$Exclude = @(),

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateSet('gold_black', 'crimson_black', 'emerald_black', 'sapphire_black',
                 'bone_white', 'desaturate', 'vibrant', 'vibrant_soft',
                 'vibrant_strong')]
    [string]$Scheme = 'gold_black',

    # Blocks more colourful than this keep their own colour, so leather, wood
    # and metal survive while near-grey cloth is recoloured.
    [Parameter(ParameterSetName = 'Apply')]
    [int]$MaxSaturation = -1,     # -1 = pick a sensible default for the scheme

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

# A vibrance scheme keeps every hue and just deepens it, so there is nothing to
# protect - masking would leave the fittings flat while the cloth got richer.
if ($MaxSaturation -lt 0) {
    $MaxSaturation = if ($Scheme -like 'vibrant*') { 0 } else { 25 }
}

$root    = Join-Path $GamePath "multi\Extracted\DataPC.forge\Extracted"
$backups = Join-Path $GamePath "multi\_persona_backup"
$engine  = Join-Path $PSScriptRoot "recolour_texture.py"

if (-not (Test-Path $root))   { Write-Host "Not unpacked: multi\DataPC.forge" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $engine)) { Write-Host "Missing $engine" -ForegroundColor Red; exit 1 }

# Which resources belong to this persona, and which are unpacked yet.
if (-not $All -and -not $Persona) {
    Write-Host "Give -Persona <name> or -All." -ForegroundColor Yellow
    exit 1
}
# Not every persona texture lives in a *_Set.data container - ID18 keeps a
# body texture in AC2MP_ID18_custom_top.data - so match any container and let
# the diffuse-map check below decide. Scope is therefore whatever you have
# unpacked, which is the thing you actually control.
$containers = Get-ChildItem -Path (Split-Path $root) -Filter "*.data" -File
if (-not $All) {
    $containers = $containers | Where-Object { $_.Name -like "*$Persona*" }
} elseif ($Exclude.Count) {
    $containers = $containers | Where-Object {
        $n = $_.Name
        -not ($Exclude | Where-Object { $n -like "*$_*" })
    }
}
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
Write-Host $(if ($All) { "All unpacked personas" } else { "Persona '$Persona'" }) -ForegroundColor Cyan
foreach ($t in $textures) { Write-Host ("   ready    " + $t.Name) -ForegroundColor Green }
if (-not $All) { foreach ($m in $missing) { Write-Host ("   UNPACK   " + $m) -ForegroundColor Yellow } }
elseif ($missing.Count) { Write-Host ("   " + $missing.Count + " more not unpacked yet") -ForegroundColor DarkGray }

if ($missing.Count -and -not $All) {
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

# Group textures by the persona they belong to, so an upper and lower half
# share one tonal range. Measuring each separately lets the halves drift apart
# in contrast, which is visible on the model as a mismatched outfit.
function Persona-Key([string]$name) {
    $k = $name -replace '^\d+_-_', '' -replace '\.TextureMap$', '' -replace '^\d+_-_', ''
    $k = $k -replace '_DiffuseMap$', ''
    foreach ($suffix in @('Up','Upper','Bottom','Down','Haut','Bas','Top','Low','LOD2','LOD')) {
        $k = $k -replace ("(?i)" + $suffix + '$'), ''
    }
    $k = $k -replace '(?i)_?Custom\d*$', '' -replace '_+$', ''
    if (-not $k) { $k = $name }
    return $k
}

Write-Host ""
$groups = $textures | Group-Object { Persona-Key $_.Name }
foreach ($grp in $groups) {
    $groupLevels = $Levels
    if (-not $groupLevels) {
        # Measure from the first member of this persona, reading its pristine
        # backup when one exists so a re-run does not measure its own output.
        $probe = $grp.Group[0]
        $pb = Backup-Path $probe.Name
        $src = if (Test-Path $pb) { $pb } else { $probe.FullName }
        $out = & python $engine --texture $src --scheme $Scheme --dry-run 2>&1
        $line = $out | Where-Object { $_ -match 'black\s+([\d.]+)\s+white\s+([\d.]+)' }
        if ($line -and $line -match 'black\s+([\d.]+)\s+white\s+([\d.]+)') {
            $groupLevels = "{0}:{1}" -f $Matches[1], $Matches[2]
        }
    }
    Write-Host ("== " + $grp.Name + "   (" + $grp.Count + " texture(s), levels " +
                $(if ($groupLevels) { $groupLevels } else { "auto" }) + ")") -ForegroundColor Magenta
    foreach ($t in $grp.Group) {
        Write-Host ("-- " + $t.Name) -ForegroundColor Cyan
        $argv = @('--texture', $t.FullName, '--scheme', $Scheme,
                  '--backup', (Backup-Path $t.Name), '--max-saturation', $MaxSaturation)
        if ($groupLevels) { $argv += @('--levels', $groupLevels) }
        if ($Keep)   { $argv += @('--keep', $Keep) }
        if ($DryRun) { $argv += '--dry-run' }
        # One odd texture must not abort the roster. With ErrorActionPreference
        # Stop, any stderr from a native command is a terminating error, so
        # relax it just around the call and report per-texture instead.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & python $engine @argv 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("   skipped (exit " + $LASTEXITCODE + ")") -ForegroundColor DarkYellow
        }
        $ErrorActionPreference = $prev
    }
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run - nothing was written." -ForegroundColor Yellow
} else {
    Write-Host "Now repack in AnvilToolkit, inner .data files first, then DataPC.forge." -ForegroundColor Cyan
    Write-Host "CLOSE THE GAME FIRST - it holds the forge open and Repack fails silently." -ForegroundColor Yellow
}
