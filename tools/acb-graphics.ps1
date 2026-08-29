<#
  Read and raise the multiplayer graphics settings.

  THE FILE THE MULTIPLAYER GAME ACTUALLY READS

  There are two INIs named ACBrotherhoodMP.ini, in two places, holding
  different things:

      %USERPROFILE%\Saved Games\Assassin's Creed Brotherhood\
          ACBrotherhood.ini      <- singleplayer [Graphics] + input profiles
          ACBrotherhoodMP.ini    <- multiplayer KEY BINDINGS only

      <game>\ACBrotherhoodMP.ini <- multiplayer [Graphics]   *** this one ***

  The game-directory file is the multiplayer quality surface, and it uses its
  own key names - OptionsShadowQuality, not ShadowQuality. re/FINDINGS.md
  recorded those Options* names from string analysis but assumed they lived in
  the Saved Games file, so the "quality values are clamped" experiment was run
  against the singleplayer INI and never touched this one.

  WHAT THAT MISSED

  Singleplayer ceilings, established by that clamp test:

      EnvironmentQuality 5   TextureQuality 2   ShadowQuality 4
      ReflectionQuality  3   CharacterQuality 4

  The multiplayer file ships every quality key at 2 - which is the ceiling of
  the MP options menu (Low/Medium/High = 0/1/2), not necessarily the ceiling of
  the renderer. Shadows, reflections and characters all have documented range
  above 2 in the sibling file.

  -Set Beyond writes those higher values so the question can be settled. The
  game rewrites this INI ON EXIT, so the test is: set, play, quit, -Verify.
  Whatever it wrote back is the real ceiling.

  USAGE
    .\acb-graphics.ps1 -Status
    .\acb-graphics.ps1 -Set Menu      # everything the options menu can reach
    .\acb-graphics.ps1 -Set Beyond    # + the singleplayer ranges, to be tested
    .\acb-graphics.ps1 -Verify        # after one launch: what survived?
    .\acb-graphics.ps1 -Restore
    .\acb-graphics.ps1 -Set Menu -RefreshRate 144
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory)]
    [ValidateSet('Menu', 'Beyond')]
    [string]$Set,

    [Parameter(ParameterSetName = 'Status')] [switch]$Status,
    [Parameter(ParameterSetName = 'Verify')] [switch]$Verify,
    [Parameter(ParameterSetName = 'Restore')][switch]$Restore,

    # Only used with -Set. Left at 0, the stock 60 is raised to the display's
    # actual rate and any other value is treated as a deliberate choice and kept.
    [Parameter(ParameterSetName = 'Set')]
    [int]$RefreshRate = 0,

    [string]$GamePath = "C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood"
)

$ErrorActionPreference = 'Stop'

$ini     = Join-Path $GamePath "ACBrotherhoodMP.ini"
$backup  = Join-Path $GamePath "_graphics_backup\ACBrotherhoodMP.ini.original"
$pending = Join-Path $PSScriptRoot "graphics-pending.json"

# All three, because which file multiplayer honours is unresolved and a run that
# rewrites a file we were not watching looks identical to one that rewrites
# nothing. Baseline all of them; let the verify say which the game touched.
$saved   = Join-Path $env:USERPROFILE "Saved Games\Assassin's Creed Brotherhood"
$allInis = @($ini,
             (Join-Path $saved "ACBrotherhood.ini"),
             (Join-Path $saved "ACBrotherhoodMP.ini"))

# Menu ceiling, and the sibling file's ranges. TextureQuality is 2 in both, so
# the MP menu already reaches the engine ceiling there and nothing is claimed.
$profiles = @{
    Menu = [ordered]@{
        OptionsPostFX            = 2
        OptionsTextureQuality    = 2
        OptionsShadowQuality     = 2
        OptionsReflectionQuality = 2
        OptionsCharacterQuality  = 2
    }
    Beyond = [ordered]@{
        OptionsPostFX            = 2
        OptionsTextureQuality    = 2
        OptionsShadowQuality     = 4   # singleplayer ShadowQuality tops out here
        OptionsReflectionQuality = 3   # singleplayer ReflectionQuality
        OptionsCharacterQuality  = 4   # singleplayer CharacterQuality
    }
}

function Read-Ini([string]$path) {
    $map = [ordered]@{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $map[$Matches[1]] = $Matches[2]
        }
    }
    return $map
}

# The game writes this file itself: [Graphics] header, LF endings, no BOM.
function Write-Ini([string]$path, $map) {
    $lines = @('[Graphics]') + ($map.Keys | ForEach-Object { "$_=$($map[$_])" })
    $text  = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-Fingerprint([string]$path) {
    if (-not (Test-Path $path)) { return [pscustomobject]@{ Path = $path; Exists = $false; Hash = ''; Length = 0 } }
    [pscustomobject]@{
        Path   = $path
        Exists = $true
        Hash   = (Get-FileHash $path -Algorithm SHA256).Hash
        Length = (Get-Item $path).Length
    }
}

function Get-NativeMode {
    # Hybrid-graphics laptops expose several controllers; take the largest panel.
    try {
        $m = Get-CimInstance Win32_VideoController -ErrorAction Stop |
             Where-Object { $_.CurrentHorizontalResolution -gt 0 } |
             Sort-Object { [long]$_.CurrentHorizontalResolution * [long]$_.CurrentVerticalResolution } -Descending |
             Select-Object -First 1
        if ($m) {
            return @{
                Width   = [int]$m.CurrentHorizontalResolution
                Height  = [int]$m.CurrentVerticalResolution
                Refresh = [int]$m.CurrentRefreshRate
            }
        }
    } catch { }
    return $null
}

function Assert-GameClosed {
    if (Get-Process ACBMP -ErrorAction SilentlyContinue) {
        Write-Host "ACBMP.exe is running. It rewrites this INI on exit and would" -ForegroundColor Red
        Write-Host "overwrite anything written now. Close the game first." -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path $ini)) {
    Write-Host "No $ini." -ForegroundColor Yellow
    Write-Host "Launch the multiplayer game once and quit - it writes the file on exit." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- status -----
if ($PSCmdlet.ParameterSetName -eq 'Status') {
    $cur    = Read-Ini $ini
    $native = Get-NativeMode
    Write-Host ""
    Write-Host "  $ini"
    Write-Host ""
    Write-Host ("  {0,-26} {1,-8} {2}" -f 'key', 'current', 'note')
    Write-Host ("  {0,-26} {1,-8} {2}" -f '---', '-------', '----')
    foreach ($k in $cur.Keys) {
        $note = ''
        if ($profiles.Beyond.Contains($k)) {
            $hi = $profiles.Beyond[$k]
            if ([int]$cur[$k] -lt $hi) { $note = "menu ceiling; singleplayer range reaches $hi" }
            elseif ($hi -eq 2)         { $note = 'at the engine ceiling' }
            else                       { $note = 'above the menu ceiling' }
        }
        if ($k -eq 'RefreshRate' -and $native -and [int]$cur[$k] -lt $native.Refresh) {
            $note = "display runs at $($native.Refresh) Hz"
        }
        if ($k -eq 'MultiSampleType') { $note = 'MSAA; accepted levels 0 2 4 6 8' }
        Write-Host ("  {0,-26} {1,-8} {2}" -f $k, $cur[$k], $note)
    }
    Write-Host ""
    Write-Host "  backup: $(if (Test-Path $backup) { 'present' } else { 'none yet' })"
    if (Test-Path $pending) { Write-Host "  a -Set is awaiting -Verify (run the game once, quit, then -Verify)" -ForegroundColor Cyan }
    Write-Host ""
    return
}

# --------------------------------------------------------------- restore -----
if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    Assert-GameClosed
    if (-not (Test-Path $backup)) { Write-Host "No backup to restore." -ForegroundColor Yellow; exit 1 }
    Copy-Item $backup $ini -Force
    Remove-Item $pending -ErrorAction SilentlyContinue
    Write-Host "Restored the original $ini." -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- verify -----
if ($PSCmdlet.ParameterSetName -eq 'Verify') {
    if (-not (Test-Path $pending)) {
        Write-Host "Nothing pending. Run -Set first, then play once and quit." -ForegroundColor Yellow
        exit 1
    }
    if (Get-Process ACBMP -ErrorAction SilentlyContinue) {
        Write-Host "The game is still running - it writes the INI on exit. Quit first." -ForegroundColor Yellow
        exit 1
    }
    $state = Get-Content $pending -Raw | ConvertFrom-Json
    $want  = $state.Wrote

    # Which files did the game actually rewrite? This has to come first. A value
    # left at 5 in a file the game never opened is not evidence of anything, and
    # comparing values alone reports it as a pass.
    Write-Host ""
    Write-Host "  Did the game rewrite each INI?"
    Write-Host ""
    $targetRewritten = $false
    foreach ($b in $state.Baseline) {
        $now = Get-Fingerprint $b.Path
        $same = ($now.Exists -eq $b.Exists) -and ($now.Hash -eq $b.Hash)
        if (-not $same -and $b.Path -eq $ini) { $targetRewritten = $true }
        $mark = if ($same) { 'unchanged' } else { 'REWRITTEN' }
        $col  = if ($same) { 'DarkGray' } else { 'Green' }
        Write-Host ("    {0,-10} {1}" -f $mark, $b.Path) -ForegroundColor $col
    }
    Write-Host ""

    if (-not $targetRewritten) {
        Write-Host "  The game did not rewrite the file we edited." -ForegroundColor Yellow
        Write-Host "  This run says NOTHING about these keys - not that they were honoured," -ForegroundColor Yellow
        Write-Host "  not that they clamped. The usual cause is exiting by killing the" -ForegroundColor Yellow
        Write-Host "  process instead of through the menu, which skips the write entirely." -ForegroundColor Yellow
        if (@($state.Baseline | Where-Object { (Get-Fingerprint $_.Path).Hash -ne $_.Hash }).Count) {
            Write-Host "  Note that another INI above DID change - that is where to look next." -ForegroundColor Cyan
        }
        Write-Host ""
        return   # deliberately keep $pending: nothing was learned, the test still stands
    }

    $cur = Read-Ini $ini
    $honoured = 0; $clamped = 0; $dropped = 0
    Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f 'key', 'wrote', 'now', 'verdict')
    Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f '---', '-----', '---', '-------')
    foreach ($p in $want.PSObject.Properties) {
        if (-not $cur.Contains($p.Name)) {
            $dropped++
            Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f $p.Name, $p.Value, '-', 'DROPPED - the game does not track this key')
        } elseif ("$($cur[$p.Name])" -eq "$($p.Value)") {
            $honoured++
            Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f $p.Name, $p.Value, $cur[$p.Name], 'honoured - written back unchanged')
        } else {
            $clamped++
            Write-Host ("  {0,-26} {1,-8} {2,-8} {3}" -f $p.Name, $p.Value, $cur[$p.Name], 'clamped')
        }
    }
    Write-Host ""
    if ($dropped)  { Write-Host "  Dropped keys are inert - the game rewrote the file and did not re-emit them." -ForegroundColor Yellow }
    if ($clamped)  { Write-Host "  Clamped keys are read, and the menu ceiling is the engine ceiling for them." -ForegroundColor Yellow }
    if ($honoured) { Write-Host "  Honoured keys are real headroom the menu does not expose. This is the win." -ForegroundColor Green }
    Write-Host "  Record the result in re/FINDINGS.md so it is not retested." -ForegroundColor DarkGray
    Write-Host ""
    Remove-Item $pending -ErrorAction SilentlyContinue
    return
}

# ------------------------------------------------------------------- set -----
Assert-GameClosed

if (-not (Test-Path $backup)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $backup) | Out-Null
    Copy-Item $ini $backup
    Write-Host "Saved the original -> $backup" -ForegroundColor DarkGray
}

$cur    = Read-Ini $ini
$before = [ordered]@{}; foreach ($k in $cur.Keys) { $before[$k] = $cur[$k] }

foreach ($k in $profiles[$Set].Keys) { $cur[$k] = $profiles[$Set][$k] }

# MSAA and refresh rate are not quality-menu entries and are not clamped by it.
$cur['MultiSampleType'] = 8

# The game writes RefreshRate=60 whatever the panel does. Raise that, but treat
# any other value as somebody's deliberate choice and leave it alone.
$native = Get-NativeMode
if ($RefreshRate -gt 0) {
    $cur['RefreshRate'] = $RefreshRate
} elseif ($native -and $native.Refresh -gt 0) {
    $now = 0; [void][int]::TryParse("$($cur['RefreshRate'])", [ref]$now)
    if ($now -eq 0 -or $now -eq 60) { $cur['RefreshRate'] = $native.Refresh }
}

Write-Ini $ini $cur

$changed = @($cur.Keys | Where-Object { "$($before[$_])" -ne "$($cur[$_])" })
Write-Host ""
if ($changed.Count) {
    Write-Host "  Changed:" -ForegroundColor Green
    foreach ($k in $changed) { Write-Host ("    {0,-26} {1} -> {2}" -f $k, $before[$k], $cur[$k]) }
} else {
    Write-Host "  Already at these values; nothing changed." -ForegroundColor DarkGray
}
Write-Host ""

if ($Set -eq 'Beyond') {
    # Baseline every INI, not just the one edited. Which file multiplayer honours
    # is unresolved, so a run that rewrites a file we were not watching would
    # otherwise be indistinguishable from a run that rewrote nothing.
    [pscustomobject]@{
        Wrote    = [pscustomobject]$profiles.Beyond
        Baseline = @($allInis | ForEach-Object { Get-Fingerprint $_ })
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $pending -Encoding utf8

    Write-Host "  These are ABOVE what the options menu can select, and untested." -ForegroundColor Cyan
    Write-Host "  Play one match, then quit THROUGH THE MENU and run:" -ForegroundColor Cyan
    Write-Host "      powershell -File tools\acb-graphics.ps1 -Verify"
    Write-Host ""
    Write-Host "  Killing the game instead of exiting through the menu skips the" -ForegroundColor Yellow
    Write-Host "  write-on-exit, and a file the game never wrote still holds these" -ForegroundColor Yellow
    Write-Host "  values - which reads as a pass and is not one. -Verify checks" -ForegroundColor Yellow
    Write-Host "  whether the file was rewritten before it believes any value." -ForegroundColor Yellow
    Write-Host "  Do not touch the in-game graphics menu in between either - saving" -ForegroundColor DarkGray
    Write-Host "  it writes the menu's own values back over these." -ForegroundColor DarkGray
    Write-Host ""
}
