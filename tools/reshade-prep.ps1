<#
  Prepare the game for ReShade's ambient occlusion, and put it back afterwards.

  WHY THIS IS NEEDED. MXAO reads the DEPTH BUFFER, and Direct3D 9 does not hand
  one over while multisampling is on. With MSAA enabled the shader receives
  nothing and silently does nothing - it does not warn, it just has no effect.
  So ambient occlusion and hardware antialiasing are mutually exclusive here.

  THE TRADE. Edge quality is a small loss at 2560x1600 and ReShade's SMAA gets
  most of it back. Ambient occlusion, contact shadows and depth are a large gain
  on a renderer from 2010 that draws none of them. Hence: MSAA off.

  This only touches MultiSampleType in the INI the game actually reads -
  Saved Games\Assassin's Creed Brotherhood\ACBrotherhood.ini. The copy in the
  game folder is never read; see the graphics notes in the README.

    .\reshade-prep.ps1 -Status
    .\reshade-prep.ps1 -ForReShade    # MSAA off
    .\reshade-prep.ps1 -Restore       # MSAA back to 8x
#>
param(
    [switch]$ForReShade,
    [switch]$Restore,
    [switch]$Status,
    [int]$Msaa = 8
)
$ErrorActionPreference = 'Stop'
$ini = Join-Path $env:USERPROFILE "Saved Games\Assassin's Creed Brotherhood\ACBrotherhood.ini"
if (-not (Test-Path $ini)) { Write-Host "  not found: $ini" -ForegroundColor Red; exit 1 }

function Get-Msaa {
    (Select-String -Path $ini -Pattern '^MultiSampleType=(\d+)' | Select-Object -First 1).Matches.Groups[1].Value
}
function Set-Msaa([int]$v) {
    # Rewrite only that key. The file also holds every input binding, so a
    # wholesale rewrite would risk the controller setup.
    (Get-Content $ini) -replace '^MultiSampleType=\d+', "MultiSampleType=$v" |
        Set-Content $ini -Encoding ascii
}

$now = Get-Msaa
if ($Status -or (-not $ForReShade -and -not $Restore)) {
    Write-Host "  MultiSampleType = $now  $(if ($now -eq '0') { '(MSAA off - ready for ReShade MXAO)' } else { "(MSAA ${now}x - MXAO will do nothing)" })"
    Write-Host "  ini: $ini"
    exit 0
}
if ($ForReShade) {
    if ($now -eq '0') { Write-Host "  already off"; exit 0 }
    Set-Msaa 0
    Write-Host "  MSAA $now -> off. MXAO can now read the depth buffer." -ForegroundColor Green
    Write-Host "  Enable SMAA in ReShade to recover edge quality."
} elseif ($Restore) {
    Set-Msaa $Msaa
    Write-Host "  MSAA restored to ${Msaa}x (MXAO will stop working)" -ForegroundColor Yellow
}
