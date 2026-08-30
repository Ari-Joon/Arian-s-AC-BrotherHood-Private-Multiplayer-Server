<#
  Edit every ability the game has, from one screen.

  WHAT THIS IS EDITING. abilitymanagermulti inside the gamesettings .cxb the
  server hands to clients - 75 ability references across 22 classes. It is
  SERVER-AUTHORITATIVE: change it here and everyone who joins inherits it.
  Nothing is installed on anyone's machine.

  PER CLASS, NOT PER TIER. Most abilities exist four times, once per upgrade
  tier, with the same parameters at different values. The underlying tool
  matches by class name, so a change applies to ALL tiers of that ability. The
  values shown are the first tier's. That is a deliberate simplification: it is
  what you want when raising a smoke bomb's radius, and per-tier editing would
  need object-ID targeting the rules tool does not have.

  WHAT CANNOT BE DONE HERE. New abilities. Each element binds to a class
  compiled into ACBMP.exe, so anything listed can be retuned and unlocked, and
  nothing new can be invented.

  MUST be run with -STA, like the settings screen.
#>
param(
    [string]$Cxb,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not $Cxb) { $Cxb = Join-Path $RepoRoot "ACB RDV\bin\x86\Release\gamesettings_c1380_d873_s6285.cxb" }
$bak     = "$Cxb.bak"
$cxbEdit = Join-Path $RepoRoot "tools\cxb-edit"
$rules   = Join-Path $RepoRoot "tools\ability_rules.py"
$work    = Join-Path $env:TEMP "acb-abilities.xml"

$cBg = [Drawing.Color]::FromArgb(22,22,26);   $cPanel  = [Drawing.Color]::FromArgb(34,34,40)
$cText = [Drawing.Color]::FromArgb(236,236,240); $cMuted = [Drawing.Color]::FromArgb(140,140,152)
$cAccent = [Drawing.Color]::FromArgb(198,52,62)
$fBody = New-Object Drawing.Font("Segoe UI", 9.75)
$fSmall = New-Object Drawing.Font("Segoe UI", 8.25)
$fHead = New-Object Drawing.Font("Segoe UI Semibold", 11)

function Fail($m) {
    [void][Windows.Forms.MessageBox]::Show($m, "Skills", 'OK', 'Error'); exit 1
}
if (-not (Test-Path $Cxb)) { Fail "Cannot find the gamesettings file:`n$Cxb" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Fail "python is not on PATH." }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { Fail "the .NET SDK is not on PATH." }

# Always work from the pristine backup, so edits set absolute values instead of
# compounding on every visit. Same rule the launcher's match rules follow.
if (-not (Test-Path $bak)) { Copy-Item $Cxb $bak }

# dotnet and python write progress to stderr, which is TERMINATING while
# ErrorActionPreference is 'Stop'. Judge these by exit code instead.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& dotnet run --project $cxbEdit --no-build -- extract $bak abilitymanagermulti $work 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = $prevEAP; Fail "Could not read abilities out of the settings file." }
$json = & python $rules --xml $work --dump-json 2>&1
if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = $prevEAP; Fail "Could not parse abilities:`n$json" }
$ErrorActionPreference = $prevEAP

$all = $json | ConvertFrom-Json
# One row per class; first occurrence carries the values we show.
$byClass = [ordered]@{}
foreach ($e in $all) { if (-not $byClass.Contains($e.ability)) { $byClass[$e.ability] = $e.params } }

# --- window ------------------------------------------------------------------
$f = New-Object Windows.Forms.Form
$f.Text = "Skills"
$f.ClientSize = New-Object Drawing.Size(780, 560)
$f.StartPosition = 'CenterScreen'
$f.BackColor = $cBg; $f.ForeColor = $cText; $f.Font = $fBody
$f.MinimumSize = New-Object Drawing.Size(700, 480)

$hdr = New-Object Windows.Forms.Label
$hdr.Text = "ABILITIES"; $hdr.Font = $fHead; $hdr.ForeColor = $cAccent
$hdr.Location = New-Object Drawing.Point(16,12); $hdr.AutoSize = $true
$f.Controls.Add($hdr)

$sub = New-Object Windows.Forms.Label
$sub.Text = "Set by the host. Everyone who joins plays by these. Changes apply to all upgrade tiers of an ability."
$sub.Font = $fSmall; $sub.ForeColor = $cMuted
$sub.Location = New-Object Drawing.Point(18,36); $sub.AutoSize = $true
$f.Controls.Add($sub)

$list = New-Object Windows.Forms.ListBox
$list.Location = New-Object Drawing.Point(16,64); $list.Size = New-Object Drawing.Size(250,400)
$list.BackColor = $cPanel; $list.ForeColor = $cText; $list.BorderStyle = 'FixedSingle'
foreach ($k in $byClass.Keys) { [void]$list.Items.Add(($k -replace '^Ability','')) }
$f.Controls.Add($list)

$panel = New-Object Windows.Forms.Panel
$panel.Location = New-Object Drawing.Point(282,64); $panel.Size = New-Object Drawing.Size(482,400)
$panel.BackColor = $cBg; $panel.AutoScroll = $true
$f.Controls.Add($panel)

# className -> @{ param -> textbox }
$boxes = @{}
$original = @{}

function Show-Ability($className) {
    $panel.Controls.Clear()
    $y = 4
    $t = New-Object Windows.Forms.Label
    $t.Text = ($className -replace '^Ability',''); $t.Font = $fHead; $t.ForeColor = $cText
    $t.Location = New-Object Drawing.Point(4,$y); $t.AutoSize = $true
    $panel.Controls.Add($t); $y += 34

    if (-not $boxes.ContainsKey($className)) { $boxes[$className] = @{} }
    $p = $byClass[$className]
    foreach ($name in ($p.PSObject.Properties.Name | Sort-Object)) {
        $lab = New-Object Windows.Forms.Label
        $lab.Text = $name; $lab.ForeColor = $cText
        $lab.Location = New-Object Drawing.Point(6,($y+4)); $lab.AutoSize = $true
        $panel.Controls.Add($lab)

        $tb = New-Object Windows.Forms.TextBox
        $tb.Location = New-Object Drawing.Point(250,$y); $tb.Size = New-Object Drawing.Size(120,24)
        $tb.BackColor = $cPanel; $tb.ForeColor = $cText; $tb.BorderStyle = 'FixedSingle'
        # Keep whatever the user typed on this visit; otherwise show the file's value.
        $tb.Text = if ($boxes[$className].ContainsKey($name)) { $boxes[$className][$name].Text }
                   else { [string]$p.$name }
        $panel.Controls.Add($tb)
        $boxes[$className][$name] = $tb
        $original["$className|$name"] = [string]$p.$name
        $y += 32
    }

    $note = New-Object Windows.Forms.Label
    $note.Text = "Applies to every tier of this ability."
    $note.Font = $fSmall; $note.ForeColor = $cMuted
    $note.Location = New-Object Drawing.Point(6,($y+6)); $note.AutoSize = $true
    $panel.Controls.Add($note)
}

$list.Add_SelectedIndexChanged({
    if ($list.SelectedIndex -ge 0) { Show-Ability @($byClass.Keys)[$list.SelectedIndex] }
})
if ($list.Items.Count) { $list.SelectedIndex = 0 }

$unlock = New-Object Windows.Forms.CheckBox
$unlock.Text = "Unlock every ability for every account (level 1)"
$unlock.Location = New-Object Drawing.Point(16,476); $unlock.AutoSize = $true
$unlock.ForeColor = $cText; $unlock.Checked = $true
$f.Controls.Add($unlock)

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(16,506); $status.AutoSize = $true
$status.Font = $fSmall; $status.ForeColor = $cMuted
$f.Controls.Add($status)

function Make-Button($text,$x,$w) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x,470); $b.Size = New-Object Drawing.Size($w,34)
    $b.FlatStyle = 'Flat'; $b.ForeColor = $cText; $b.BackColor = $cPanel
    $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(74,74,86)
    $f.Controls.Add($b); return $b
}
$resetBtn = Make-Button "Reset to shipped" 470 150
$saveBtn  = Make-Button "Apply to server"  630 134
$saveBtn.BackColor = $cAccent; $saveBtn.ForeColor = [Drawing.Color]::White
$saveBtn.FlatAppearance.BorderSize = 0

$resetBtn.Add_Click({
    if (-not (Test-Path $bak)) { $status.Text = "no backup to restore"; return }
    Copy-Item $bak $Cxb -Force
    $status.Text = "shipped rules restored - reopen to see the original values"
    $status.ForeColor = [Drawing.Color]::FromArgb(120,200,120)
})

$saveBtn.Add_Click({
    $sets = @()
    foreach ($cls in $boxes.Keys) {
        foreach ($name in $boxes[$cls].Keys) {
            $v = $boxes[$cls][$name].Text.Trim()
            $o = $original["$cls|$name"]
            if ($v -ne $o -and $v -match '^-?\d+(\.\d+)?$') { $sets += "$cls`:$name=$v" }
        }
    }
    if (-not $sets -and -not $unlock.Checked) { $status.Text = "nothing changed"; return }

    $saveBtn.Enabled = $false; $status.ForeColor = $cMuted; $status.Text = "applying..."; $f.Refresh()
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        # Rebuild from the pristine backup so values are absolute, never compounded.
        & dotnet run --project $cxbEdit --no-build -- extract $bak abilitymanagermulti $work 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not read the shipped abilities" }

        $argv = @($rules, "--xml", $work)
        foreach ($s in $sets) { $argv += @("--set", $s) }
        if ($unlock.Checked) { $argv += "--unlock-all" }
        $out = & python @argv 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }

        $out = & dotnet run --project $cxbEdit --no-build -- replace $Cxb abilitymanagermulti $work 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }

        $status.ForeColor = [Drawing.Color]::FromArgb(120,200,120)
        $status.Text = "applied: $($sets.Count) change(s)" + $(if ($unlock.Checked) { ", all abilities unlocked" } else { "" })
    } catch {
        $status.ForeColor = [Drawing.Color]::FromArgb(220,120,120)
        $status.Text = "failed - shipped rules still in place"
        [void][Windows.Forms.MessageBox]::Show("$_", "Skills", 'OK', 'Error')
    } finally {
        $ErrorActionPreference = $prev; $saveBtn.Enabled = $true
    }
})

[void]$f.ShowDialog()
