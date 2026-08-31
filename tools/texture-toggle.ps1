<#
  Switch the game between VANILLA and UPSCALED textures in seconds.

  WHY THIS EXISTS. Without it there is no honest before/after. Comparing a
  screenshot taken today against one taken this morning compares two different
  camera positions, and a "sharpness" number computed that way measures where
  you were standing. A toggle lets you stand still, switch, and shoot the same
  frame twice - which is the only comparison worth publishing.

  HOW IT WORKS. Two complete sets of forges are kept side by side under
  multi\_texture_sets. Switching copies a set over the live files. No repacking,
  no extraction - it is a file copy, so it takes seconds rather than the hours
  the pipeline itself needs.

  DISK. Roughly 3 GB for both sets. That is the price of instant switching.

  USAGE
    .\texture-toggle.ps1 -Status
    .\texture-toggle.ps1 -Capture Upscaled     # snapshot the live forges as a set
    .\texture-toggle.ps1 -Capture Vanilla      # ... from .bak files where they are pristine
    .\texture-toggle.ps1 -Mode Vanilla
    .\texture-toggle.ps1 -Mode Upscaled
#>
[CmdletBinding(DefaultParameterSetName='Status')]
param(
    [Parameter(ParameterSetName='Switch', Mandatory)]
    [ValidateSet('Vanilla','Upscaled')] [string]$Mode,

    [Parameter(ParameterSetName='Capture', Mandatory)]
    [ValidateSet('Vanilla','Upscaled')] [string]$Capture,

    [Parameter(ParameterSetName='Status')] [switch]$Status,

    [string]$GamePath = "C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood"
)

$ErrorActionPreference = 'Stop'
$multi = Join-Path $GamePath "multi"
$store = Join-Path $multi "_texture_sets"

# Sizes of every forge as Steam ships it, recorded before anything was upscaled.
# Used to tell a genuine pristine backup from an intermediate one - an
# intermediate .bak looks exactly like a real one except for its size.
$VANILLA_SIZE = @{
    "DataPC_ACR_Rome_Multi.forge"          = 66355200
    "DataPC_AC2MP_Alhambra_dlc.forge"      = 58294272
    "DataPC_AC2MP_Firenze.forge"           = 62193664
    "DataPC_AC2MP_Forli.forge"             = 58621952
    "DataPC_AC2MP_MtStMichel_dlc.forge"    = 52789248
    "DataPC_AC2MP_Palazzio.forge"          = 60882944
    "DataPC_AC2MP_Pienza_dlc.forge"        = 58949632
    "DataPC_AC2MP_SanDonato.forge"         = 63832064
    "DataPC_AC2MP_SanMarco.forge"          = 62291968
    "DataPC_AC2MP_Siena.forge"             = 56721408
    "DataPC_AC2MP_Villa.forge"             = 57606144
    "DataPC_AC2MP_Whiteroom.forge"         = 32473088
    "DataPC_skins_0000_00000001_dlc.forge" = 9535488
    "DataPC_skins_0002_00000004_dlc.forge" = 138018816
}

# Forges REBUILT from pristine textures rather than restored from a Steam
# backup. Their contents are vanilla; their size is not, because a first repack
# adds roughly 40 MB of container overhead whatever the payload. Accepting them
# is correct - rejecting them would mean no vanilla side for these two at all -
# but they are listed separately so nobody mistakes them for untouched files.
$REBUILT_VANILLA = @{
    "DataPC.forge"               = 529530880
    "DataPC_AC2MP_Firenze.forge" = 102400000
}
$forges = @($VANILLA_SIZE.Keys) + @("DataPC.forge")

function Assert-Closed {
    $busy = Get-Process ACBMP,ACBSP,AnvilToolkit -ErrorAction SilentlyContinue
    if ($busy) {
        Write-Host "These hold the forges open - close them first:" -ForegroundColor Red
        ($busy.Name | Sort-Object -Unique) | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
        exit 1
    }
}

function Set-Dir($name) { Join-Path $store $name }

# ---------------------------------------------------------------- status -----
if ($PSCmdlet.ParameterSetName -eq 'Status') {
    Write-Host ""
    Write-Host "  live forges" -ForegroundColor Cyan
    foreach ($f in ($forges | Sort-Object)) {
        $p = Join-Path $multi $f
        if (-not (Test-Path $p)) { continue }
        $len = (Get-Item $p).Length
        $tag = if ($VANILLA_SIZE.ContainsKey($f) -and $len -eq $VANILLA_SIZE[$f]) { "vanilla" }
               elseif ($VANILLA_SIZE.ContainsKey($f)) { "modified" } else { "?" }
        "    {0,-40} {1,12:N0}  {2}" -f $f, $len, $tag
    }
    Write-Host ""
    foreach ($s in 'Vanilla','Upscaled') {
        $d = Set-Dir $s
        $n = if (Test-Path $d) { @(Get-ChildItem $d -Filter *.forge).Count } else { 0 }
        $sz = if ($n) { (Get-ChildItem $d -Filter *.forge | Measure-Object Length -Sum).Sum/1GB } else { 0 }
        "  set '{0}': {1} forges, {2:N1} GB" -f $s, $n, $sz
    }
    Write-Host ""
    return
}

# --------------------------------------------------------------- capture -----
if ($PSCmdlet.ParameterSetName -eq 'Capture') {
    Assert-Closed
    $d = Set-Dir $Capture
    New-Item -ItemType Directory -Force $d | Out-Null
    $saved = 0; $skipped = @()
    foreach ($f in $forges) {
        $live = Join-Path $multi $f
        if (-not (Test-Path $live)) { continue }

        if ($Capture -eq 'Vanilla') {
            # Prefer a .bak whose size matches what Steam ships. An intermediate
            # backup is indistinguishable from a pristine one by name alone.
            $bak = "$live.bak"
            if ($VANILLA_SIZE.ContainsKey($f) -and (Test-Path $bak) -and
                (Get-Item $bak).Length -eq $VANILLA_SIZE[$f]) {
                Copy-Item $bak (Join-Path $d $f) -Force; $saved++
            } elseif ($VANILLA_SIZE.ContainsKey($f) -and (Get-Item $live).Length -eq $VANILLA_SIZE[$f]) {
                Copy-Item $live (Join-Path $d $f) -Force; $saved++
            } elseif ($REBUILT_VANILLA.ContainsKey($f) -and (Get-Item $live).Length -eq $REBUILT_VANILLA[$f]) {
                Copy-Item $live (Join-Path $d $f) -Force; $saved++
                Write-Host "    $f taken from a REBUILD (vanilla contents, repacked container)" -ForegroundColor DarkGray
            } else {
                $skipped += $f
            }
        } else {
            Copy-Item $live (Join-Path $d $f) -Force; $saved++
        }
    }
    Write-Host "  captured $saved forges into set '$Capture'" -ForegroundColor Green
    if ($skipped.Count) {
        Write-Host "  no pristine source for:" -ForegroundColor Yellow
        $skipped | ForEach-Object { Write-Host "     $_" -ForegroundColor Yellow }
        Write-Host "  Restore these through Steam (Verify integrity of game files)," -ForegroundColor Yellow
        Write-Host "  then re-run -Capture Vanilla before switching." -ForegroundColor Yellow
    }
    return
}

# ---------------------------------------------------------------- switch -----
Assert-Closed
$d = Set-Dir $Mode
if (-not (Test-Path $d)) { Write-Host "  set '$Mode' has not been captured yet" -ForegroundColor Red; exit 1 }
$files = @(Get-ChildItem $d -Filter *.forge)
if (-not $files) { Write-Host "  set '$Mode' is empty" -ForegroundColor Red; exit 1 }

Write-Host "  switching to $Mode ($($files.Count) forges)" -ForegroundColor Cyan
# Skip anything already in the requested state. This used to copy all 15
# forges every time - 1.3 to 2.1 GB - even when the live files already WERE
# that set, which made picking a set on every launch too slow to be worth
# doing. Size distinguishes the sets: they differ by tens of MB per forge.
$copied = 0; $already = 0
foreach ($f in $files) {
    $live = Join-Path $multi $f.Name
    if ((Test-Path $live) -and ((Get-Item $live).Length -eq $f.Length)) {
        $already++
        continue
    }
    Copy-Item $f.FullName $live -Force
    $copied++
    "    {0,-40} {1,12:N0}" -f $f.Name, $f.Length
}
if ($already) { Write-Host "    $already already in place, skipped" -ForegroundColor DarkGray }
Write-Host "  done - launch and compare" -ForegroundColor Green
