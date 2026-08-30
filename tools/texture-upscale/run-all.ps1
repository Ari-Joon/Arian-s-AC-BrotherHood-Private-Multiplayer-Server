<#
  Upscale every multiplayer texture, start to finish, unattended.

  Produces BYTE-IDENTICAL results on any machine: the same model on the same
  input gives the same output, so everyone who runs this ends up with exactly
  the same textures. That is the point - it means nobody has to redistribute
  game files to share the result.

  WHAT IT DOES
    1. extract each multiplayer .forge into .data containers
    2. unpack the containers holding diffuse textures
    3. AI-upscale every diffuse texture 2x through Real-ESRGAN
    4. repack containers, then forges (inner first - the forge gathers the
       containers as they are on disk, so the other order silently packs the
       originals and reports success)

  REQUIREMENTS
    .NET 9 SDK, Python 3 with numpy + pillow + onnxruntime, and the model
    RealESRGAN_x4plus.fp16.onnx beside this script.

    For a GPU, install onnxruntime-directml INSTEAD of onnxruntime. It works on
    any DX12 card and turns hours into minutes. Both packages provide the same
    module, so having both installed breaks it - uninstall one.

  TIME
    Several hours on a CPU. Roughly ten to twenty minutes on a GPU.

  SAFETY
    Originals are copied aside before anything is written, and every rebuilt
    forge leaves the previous version as .bak. Close the game and AnvilToolkit
    first: a repack against a forge held open fails SILENTLY.
#>
param(
    [string]$GamePath = "C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood",
    [switch]$SkipExtract,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path (Split-Path $here -Parent) -Parent

function Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Die($msg) { Write-Host "  $msg" -ForegroundColor Red; exit 1 }

# --- preflight, all of it, before anything is written -----------------------
Step 0 "Checking prerequisites"
if (-not (Test-Path $GamePath)) { Die "Game not found at $GamePath" }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { Die ".NET SDK not on PATH - needed for the forge tools" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Die "python not on PATH" }

$model = Get-ChildItem $here -Filter "RealESRGAN_x4plus*.onnx" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $model) {
    Die @"
No Real-ESRGAN model beside this script.
Download RealESRGAN_x4plus.fp16.onnx (33 MB) and put it in:
  $here
"@
}
"  model: $($model.Name)"

$prov = & python -c "import onnxruntime as o; print(','.join(o.get_available_providers()))" 2>$null
if (-not $prov) { Die "onnxruntime not importable - pip install onnxruntime (or onnxruntime-directml for GPU)" }
"  onnxruntime providers: $prov"
if ($prov -notmatch 'Dml|CUDA') {
    Write-Host "  CPU only - this will take HOURS. pip install onnxruntime-directml for a GPU run." -ForegroundColor Yellow
}

# A repack against a held-open forge fails silently, so refuse rather than warn.
$busy = Get-Process ACBMP,ACBSP,AnvilToolkit -ErrorAction SilentlyContinue
if ($busy) { Die "Close these first, they hold the forges open: $(($busy.Name | Sort-Object -Unique) -join ', ')" }
"  nothing holding the forges"

if ($WhatIf) { Write-Host "`n-WhatIf: stopping before any work" -ForegroundColor Yellow; exit 0 }

$forges = @(Get-ChildItem "$GamePath\multi\DataPC_AC2MP_*.forge","$GamePath\multi\DataPC_ACR_Rome_Multi.forge" -ErrorAction SilentlyContinue)

# --- 1 & 2: extract and unpack ----------------------------------------------
if (-not $SkipExtract) {
    Step 1 "Extracting $($forges.Count) map forges and the skins archives"
    foreach ($f in $forges) {
        & dotnet run --project "$repo\tools\forge-extract" -- $f.FullName 2>&1 |
            Select-String -Pattern 'containers ->|already extracted|FAILED' | ForEach-Object { "    $_" }
    }
    foreach ($f in Get-ChildItem "$GamePath\multi\DataPC_skins_*.forge") {
        & dotnet run --project "$repo\tools\forge-extract" -- $f.FullName 2>&1 |
            Select-String -Pattern 'containers ->|already extracted|FAILED' | ForEach-Object { "    $_" }
    }

    Step 2 "Unpacking containers"
    foreach ($f in $forges) {
        $d = "$GamePath\multi\Extracted\$($f.Name)"
        if (Test-Path $d) {
            & dotnet run --project "$repo\tools\anvil-unpack" -- --all $d --filter DiffuseMap 2>&1 | Select-Object -Last 1 | ForEach-Object { "    $($f.Name): $_" }
        }
    }
    # Skins archives use HASH-NAMED containers, so a DiffuseMap filter matches
    # nothing there and reports a clean zero. They have to be unpacked whole.
    foreach ($f in Get-ChildItem "$GamePath\multi\DataPC_skins_*.forge") {
        $d = "$GamePath\multi\Extracted\$($f.Name)"
        if (Test-Path $d) {
            & dotnet run --project "$repo\tools\anvil-unpack" -- --all $d 2>&1 | Select-Object -Last 1 | ForEach-Object { "    $($f.Name): $_" }
        }
    }
}

# --- 3: upscale --------------------------------------------------------------
Step 3 "Upscaling (this is the long part)"
& python "$here\batch.py"
& python "$here\batch.py" --prefix DataPC_skins_

# --- 4: repack, inner containers first ---------------------------------------
Step 4 "Repacking containers, then forges"
$all = @($forges) + @(Get-ChildItem "$GamePath\multi\DataPC_skins_*.forge")
foreach ($f in $all) {
    $d = "$GamePath\multi\Extracted\$($f.Name)"
    if (-not (Test-Path $d)) { continue }
    $out = & dotnet run --project "$repo\tools\anvil-repack" -- --data-all $d --only-modified 2>&1
    $n = ($out | Select-String -Pattern '^(\d+) repacked').Matches.Groups[1].Value
    if ([int]$n -gt 0) {
        & dotnet run --project "$repo\tools\anvil-repack" -- --forge $f.FullName 2>&1 |
            Select-String -Pattern 'done:|FAILED|UNCHANGED' | ForEach-Object { "    $($f.Name): $_" }
    } else {
        "    $($f.Name): no containers changed"
    }
}

Write-Host "`nDone. Every rebuilt forge kept its previous version as .bak." -ForegroundColor Green
Write-Host "If anything looks wrong, restore the .bak files and nothing is lost."
