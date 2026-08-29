<#
  AC Brotherhood - private server launcher with a graphics settings screen.

  The game's own options menu is compiled into ACBMP.exe and cannot be extended,
  so everything the command line can reach lives here instead. Choices are
  remembered between runs in settings.json next to this script.

  WHY SOME CONTROLS ARE HERE AND OTHERS ARE NOT

  Of the 66 switches registered in ACBMP.exe, these reach graphics: shadows,
  postfx, msaa, brightness, fullscreen, skipmips, skipmipscharacter,
  skipmipsenvironment, generateatlasmipmaps, computeao, skipao, deleteao,
  computeaoforambientgrid, fardist, layersdepthbias, loadondemand,
  preloadshaders, usestrips, nofogofwar.

  These have NO switch and exist only as INI keys and menu items:
  TextureQuality, EnvironmentQuality, CharacterQuality, ReflectionQuality,
  VSync, Resolution. They are shown here as read-only status, because writing
  them has been tested and the game rewrites the file back to its own values.
  Every one is already at its ceiling, so there is nothing to gain by trying.

  Four of the controls here have no in-game equivalent at all - full mip chains,
  atlas mipmaps, ambient occlusion and draw distance. Those are the ones this
  screen genuinely adds.

  MEASURED, NOT VERIFIED. The memory figures quoted below come from launching
  with each switch against an invented control switch, on an idle machine, with
  a 0.2 MB noise floor. They prove the switches DO something. Nobody has
  compared frames, so none of them is a verified image improvement.

  MUST be run with -STA:
      powershell -STA -File tools\acb-settings.ps1
  In MTA mode ShowDialog() returns immediately and no window is shown.

  NOTE: this process deliberately stays DPI-UNAWARE so Windows scales the
  window on high-DPI displays. The true screen size is read via
  EnumDisplaySettings instead, which does not require DPI awareness.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root     = Split-Path $PSScriptRoot -Parent
$server   = Join-Path $root "ACB RDV\bin\x86\Release"
$db       = Join-Path $server "database.sqlite"
$launcher = Join-Path $PSScriptRoot "acb-launcher.ps1"
$cfgPath  = Join-Path $PSScriptRoot "settings.json"
$savedIni = Join-Path $env:USERPROFILE "Saved Games\Assassin's Creed Brotherhood\ACBrotherhood.ini"

# --- palette -----------------------------------------------------------------
$cBg       = [Drawing.Color]::FromArgb(22, 22, 26)
$cPanel    = [Drawing.Color]::FromArgb(34, 34, 40)
$cText     = [Drawing.Color]::FromArgb(236, 236, 240)
$cMuted    = [Drawing.Color]::FromArgb(140, 140, 152)
$cRule     = [Drawing.Color]::FromArgb(52, 52, 60)
$cAccent   = [Drawing.Color]::FromArgb(198, 52, 62)
$cAccentHi = [Drawing.Color]::FromArgb(222, 68, 78)

$fH1    = New-Object Drawing.Font("Segoe UI Semibold", 16)
$fSub   = New-Object Drawing.Font("Segoe UI", 9)
$fHead  = New-Object Drawing.Font("Segoe UI Semibold", 9)
$fBody  = New-Object Drawing.Font("Segoe UI", 9.75)
$fSmall = New-Object Drawing.Font("Segoe UI", 8.25)
$fBtn   = New-Object Drawing.Font("Segoe UI Semibold", 12)

# --- saved preferences -------------------------------------------------------
$cfg = @{
    Display = 'Borderless'; Resolution = ''; User = ''
    Shadows = 'default'; PostFX = 'default'; MSAA = 'default'
    FullMips = 'default'; AtlasMips = 'default'; AmbientOcclusion = 'default'
    FarDist = 0
}
if (Test-Path $cfgPath) {
    try {
        (Get-Content $cfgPath -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $cfg[$_.Name] = $_.Value }
    } catch { }
}

$accounts = @(sqlite3 "$db" "SELECT name FROM users WHERE name <> 'Tracking' ORDER BY pid;")
if (-not $accounts) { $accounts = @('Player') }

# --- real screen size, without making this process DPI-aware ------------------
# Screen.PrimaryScreen.Bounds would return DPI-scaled values here (e.g. 1707x1067
# on a 2560x1600 panel at 150%), so ask the display adapter for its actual mode.
# Hybrid-graphics laptops expose several controllers; take the largest.
$nativeW = 1920; $nativeH = 1080
try {
    $mode = Get-CimInstance Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.CurrentHorizontalResolution -gt 0 } |
            Sort-Object { [long]$_.CurrentHorizontalResolution * [long]$_.CurrentVerticalResolution } -Descending |
            Select-Object -First 1
    if ($mode) {
        $nativeW = [int]$mode.CurrentHorizontalResolution
        $nativeH = [int]$mode.CurrentVerticalResolution
    }
} catch { }

$standard = @(
    @(1280,720), @(1366,768), @(1440,900), @(1600,900), @(1680,1050),
    @(1920,1080), @(1920,1200), @(2560,1440), @(2560,1600), @(3440,1440), @(3840,2160)
)
$resList = New-Object System.Collections.Generic.List[string]
$resList.Add("$nativeW x $nativeH  (native)")
foreach ($r in $standard) {
    if ($r[0] -le $nativeW -and $r[1] -le $nativeH -and -not ($r[0] -eq $nativeW -and $r[1] -eq $nativeH)) {
        $resList.Add("$($r[0]) x $($r[1])")
    }
}

# --- what the game's own settings currently are ------------------------------
# Read-only on purpose. Every one of these is already at its measured ceiling
# and the game rewrites the file from its own state, so a control here would be
# a control that silently does nothing.
$CEILINGS = [ordered]@{
    TextureQuality = 2; EnvironmentQuality = 5; ShadowQuality = 4
    ReflectionQuality = 3; CharacterQuality = 4; PostFX = 1
}
function Get-IniGraphics {
    $map = [ordered]@{}
    if (-not (Test-Path $savedIni)) { return $map }
    $inGraphics = $false
    foreach ($line in [System.IO.File]::ReadAllLines($savedIni)) {
        if ($line -match '^\s*\[(.+?)\]\s*$') { $inGraphics = ($Matches[1] -eq 'Graphics'); continue }
        if ($inGraphics -and $line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $map[$Matches[1]] = $Matches[2]
        }
    }
    return $map
}
$ini = Get-IniGraphics

# --- form --------------------------------------------------------------------
$form                 = New-Object Windows.Forms.Form
$form.Text            = "Assassin's Creed Brotherhood"
$form.ClientSize      = New-Object Drawing.Size(470, 900)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.AutoScaleMode   = 'None'      # explicit coordinates; no font-based reflow
$form.BackColor       = $cBg
$form.ForeColor       = $cText
$form.Font            = $fBody

function Add-Text($text, $x, $y, $font, $colour) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object Drawing.Point($x, $y)
    $l.AutoSize = $true
    $l.Font = $font
    $l.ForeColor = $colour
    $l.BackColor = [Drawing.Color]::Transparent
    $form.Controls.Add($l)
    return $l
}

function Add-Rule($x, $y, $w) {
    $p = New-Object Windows.Forms.Panel
    $p.Location = New-Object Drawing.Point($x, $y)
    $p.Size = New-Object Drawing.Size($w, 1)
    $p.BackColor = $cRule
    $form.Controls.Add($p)
}

function Style-Combo($c) {
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle     = 'Flat'
    $c.BackColor     = $cPanel
    $c.ForeColor     = $cText
    $c.Font          = $fBody
}

# One labelled dropdown row, with a short note to the right of the label.
function Add-Row($label, $note, $y, $values, $current) {
    [void](Add-Text $label 34 ($y + 4) $fBody $cText)
    if ($note) { [void](Add-Text $note 34 ($y + 22) $fSmall $cMuted) }
    $c = New-Object Windows.Forms.ComboBox
    $c.Location = New-Object Drawing.Point(268, $y)
    $c.Size = New-Object Drawing.Size(168, 28)
    Style-Combo $c
    foreach ($v in $values) { [void]$c.Items.Add($v) }
    $c.SelectedItem = $(if ($current -and $c.Items.Contains($current)) { $current } else { $values[0] })
    $form.Controls.Add($c)
    return $c
}

# --- header ------------------------------------------------------------------
[void](Add-Text "BROTHERHOOD"               30 22 $fH1  $cText)
[void](Add-Text "Private multiplayer server" 32 58 $fSub $cMuted)
Add-Rule 30 92 410

# --- display -----------------------------------------------------------------
[void](Add-Text "DISPLAY" 30 108 $fHead $cAccent)

[void](Add-Text "Window mode" 30 136 $fBody $cMuted)
$modes  = @('Fullscreen','Borderless','Windowed')
$radios = @{}
$x = 34
foreach ($m in $modes) {
    $r = New-Object Windows.Forms.RadioButton
    $r.Text = $m
    $r.Location = New-Object Drawing.Point($x, 160)
    $r.AutoSize = $true
    $r.Font = $fBody
    $r.ForeColor = $cText
    $r.BackColor = [Drawing.Color]::Transparent
    $r.Checked = ($cfg.Display -eq $m)
    $form.Controls.Add($r)
    $radios[$m] = $r
    $x += 140
}

$resLabel = Add-Text "Resolution" 30 194 $fBody $cMuted
$resBox = New-Object Windows.Forms.ComboBox
$resBox.Location = New-Object Drawing.Point(34, 218)
$resBox.Size = New-Object Drawing.Size(260, 28)
Style-Combo $resBox
foreach ($r in $resList) { [void]$resBox.Items.Add($r) }
if ($cfg.Resolution -and $resBox.Items.Contains($cfg.Resolution)) {
    $resBox.SelectedItem = $cfg.Resolution
} else { $resBox.SelectedIndex = 0 }
$form.Controls.Add($resBox)

Add-Rule 30 256 410

# --- image quality -----------------------------------------------------------
[void](Add-Text "IMAGE QUALITY" 30 272 $fHead $cAccent)
[void](Add-Text "Passed on the command line. 'default' leaves the switch off entirely." 32 292 $fSmall $cMuted)

$shadowBox = Add-Row "Shadows"          "unmeasured"                 316 @('default','off','normal','full')        $cfg.Shadows
$postBox   = Add-Row "Post-processing"  "unmeasured"                 364 @('default','off','normal','full')        $cfg.PostFX
$msaaBox   = Add-Row "Anti-aliasing"    "MSAA level"                 412 @('default','none','2x','4x','6x','8x')   $cfg.MSAA
$mipsBox   = Add-Row "Full mip chains"  "+109 MB - no in-game equivalent"  460 @('default','on','off')             $cfg.FullMips
$atlasBox  = Add-Row "Atlas mipmaps"    "+111 MB - likely the same effect" 508 @('default','on','off')             $cfg.AtlasMips
$aoBox     = Add-Row "Ambient occlusion" "contact shadowing - no in-game equivalent" 556 @('default','on','off')   $cfg.AmbientOcclusion
$farBox    = Add-Row "Draw distance"    "no in-game equivalent"      604 @('default','5000','10000','20000')       $(if ($cfg.FarDist -gt 0) { "$($cfg.FarDist)" } else { 'default' })

Add-Rule 30 648 410

# --- what the game itself is set to ------------------------------------------
[void](Add-Text "IN-GAME SETTINGS" 30 664 $fHead $cAccent)
$iniBits = @()
foreach ($k in $CEILINGS.Keys) {
    if ($ini.Contains($k)) {
        $at = if ("$($ini[$k])" -eq "$($CEILINGS[$k])") { '' } else { " (ceiling $($CEILINGS[$k]))" }
        $iniBits += "$k $($ini[$k])$at"
    }
}
if ($iniBits.Count) {
    [void](Add-Text (($iniBits -join '   ') -replace '(.{62}\S*)\s', "`$1`n") 32 686 $fSmall $cMuted)
    [void](Add-Text "Read-only. These have no command-line switch, and the game rewrites`nthem from its own state - all six are already at their ceiling." 32 722 $fSmall $cMuted)
} else {
    [void](Add-Text "No [Graphics] section found - launch the game once." 32 686 $fSmall $cMuted)
}

Add-Rule 30 756 410

# --- account -----------------------------------------------------------------
[void](Add-Text "ACCOUNT" 30 772 $fHead $cAccent)

$uBox = New-Object Windows.Forms.ComboBox
$uBox.Location = New-Object Drawing.Point(34, 796)
$uBox.Size = New-Object Drawing.Size(260, 28)
Style-Combo $uBox
foreach ($a in $accounts) { [void]$uBox.Items.Add($a) }
$uBox.SelectedItem = $(if ($cfg.User -and $accounts -contains $cfg.User) { $cfg.User } else { $accounts[0] })
$form.Controls.Add($uBox)

function Show-NamePrompt($current) {
    $d = New-Object Windows.Forms.Form
    $d.Text = "Rename account"
    $d.ClientSize = New-Object Drawing.Size(360, 168)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.AutoScaleMode = 'None'
    $d.BackColor = $cBg; $d.ForeColor = $cText; $d.Font = $fBody

    $l = New-Object Windows.Forms.Label
    $l.Text = "New name"; $l.Location = New-Object Drawing.Point(22, 22)
    $l.AutoSize = $true; $l.ForeColor = $cMuted
    $d.Controls.Add($l)

    $t = New-Object Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point(24, 48); $t.Size = New-Object Drawing.Size(310, 28)
    $t.Text = $current; $t.MaxLength = 15
    $t.BackColor = $cPanel; $t.ForeColor = $cText; $t.BorderStyle = 'FixedSingle'
    $d.Controls.Add($t)

    $h = New-Object Windows.Forms.Label
    $h.Text = "Letters, digits and underscore. Max 15."
    $h.Location = New-Object Drawing.Point(24, 80); $h.AutoSize = $true
    $h.ForeColor = $cMuted; $h.Font = $fSmall
    $d.Controls.Add($h)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = "Save"; $ok.Location = New-Object Drawing.Point(160, 116)
    $ok.Size = New-Object Drawing.Size(84, 32); $ok.DialogResult = 'OK'
    $ok.FlatStyle = 'Flat'; $ok.BackColor = $cAccent; $ok.ForeColor = [Drawing.Color]::White
    $ok.FlatAppearance.BorderSize = 0
    $d.Controls.Add($ok); $d.AcceptButton = $ok

    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = "Cancel"; $cancel.Location = New-Object Drawing.Point(252, 116)
    $cancel.Size = New-Object Drawing.Size(84, 32); $cancel.DialogResult = 'Cancel'
    $cancel.FlatStyle = 'Flat'; $cancel.BackColor = $cPanel; $cancel.ForeColor = $cText
    $cancel.FlatAppearance.BorderSize = 0
    $d.Controls.Add($cancel); $d.CancelButton = $cancel

    if ($d.ShowDialog() -eq 'OK') { return $t.Text.Trim() }
    return $null
}

$renameBtn = New-Object Windows.Forms.Button
$renameBtn.Text = "Rename"
$renameBtn.Location = New-Object Drawing.Point(308, 795)
$renameBtn.Size = New-Object Drawing.Size(132, 30)
$renameBtn.Font = $fBody
$renameBtn.FlatStyle = 'Flat'
$renameBtn.BackColor = $cPanel
$renameBtn.ForeColor = $cText
$renameBtn.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(74, 74, 86)
$renameBtn.FlatAppearance.BorderSize = 1
$renameBtn.Cursor = 'Hand'
$form.Controls.Add($renameBtn)

$renameBtn.Add_Click({
    $old = [string]$uBox.SelectedItem
    if (-not $old) { return }
    $new = Show-NamePrompt $old
    if (-not $new -or $new -eq $old) { return }

    if ($new -notmatch '^[A-Za-z0-9_]{1,15}$') {
        [void][Windows.Forms.MessageBox]::Show(
            "Names must be 1-15 characters: letters, digits or underscore only.",
            "Invalid name", 'OK', 'Warning')
        return
    }
    if ((sqlite3 "$db" "SELECT COUNT(*) FROM users WHERE name='$new';") -ne '0') {
        [void][Windows.Forms.MessageBox]::Show("'$new' is already taken.", "Name in use", 'OK', 'Warning')
        return
    }

    sqlite3 "$db" "UPDATE users SET name='$new', email='$new@notubi.com' WHERE name='$old';" | Out-Null

    $i = $uBox.Items.IndexOf($old)
    if ($i -ge 0) { $uBox.Items[$i] = $new }
    $uBox.SelectedItem = $new
})

# --- resolution only applies to windowed -------------------------------------
$syncRes = {
    $on = $radios['Windowed'].Checked
    $resBox.Enabled   = $on
    $resBox.ForeColor = $(if ($on) { $cText } else { $cMuted })
    $resLabel.Text    = $(if ($on) { "Resolution" } else { "Resolution  -  windowed only" })
}
foreach ($m in $modes) { $radios[$m].Add_CheckedChanged($syncRes) }
& $syncRes

# --- play --------------------------------------------------------------------
$btn = New-Object Windows.Forms.Button
$btn.Text = "PLAY"
$btn.Location = New-Object Drawing.Point(30, 840)
$btn.Size = New-Object Drawing.Size(410, 46)
$btn.Font = $fBtn
$btn.FlatStyle = 'Flat'
$btn.BackColor = $cAccent
$btn.ForeColor = [Drawing.Color]::White
$btn.FlatAppearance.BorderSize = 0
$btn.Cursor = 'Hand'
$form.Controls.Add($btn)
$form.AcceptButton = $btn

$btn.Add_MouseEnter({ $btn.BackColor = $cAccentHi })
$btn.Add_MouseLeave({ $btn.BackColor = $cAccent })

$btn.Add_Click({
    $mode = @($modes | Where-Object { $radios[$_].Checked })[0]
    $far  = $(if ([string]$farBox.SelectedItem -eq 'default') { 0 } else { [int]$farBox.SelectedItem })

    @{
        Display          = $mode
        Resolution       = $resBox.SelectedItem
        User             = $uBox.SelectedItem
        Shadows          = $shadowBox.SelectedItem
        PostFX           = $postBox.SelectedItem
        MSAA             = $msaaBox.SelectedItem
        FullMips         = $mipsBox.SelectedItem
        AtlasMips        = $atlasBox.SelectedItem
        AmbientOcclusion = $aoBox.SelectedItem
        FarDist          = $far
    } | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding utf8

    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$launcher`"",
           '-Display', $mode, '-User', $uBox.SelectedItem,
           '-Shadows', $shadowBox.SelectedItem,
           '-PostFX', $postBox.SelectedItem,
           '-MSAA', $msaaBox.SelectedItem,
           '-FullMips', $mipsBox.SelectedItem,
           '-AtlasMips', $atlasBox.SelectedItem,
           '-AmbientOcclusion', $aoBox.SelectedItem)
    if ($far -gt 0) { $a += @('-FarDist', "$far") }

    if ($mode -eq 'Windowed') {
        # Entries look like "1600 x 900" or "2560 x 1600  (native)".
        $m = [regex]::Match([string]$resBox.SelectedItem, '(\d+)\s*x\s*(\d+)')
        if ($m.Success) { $a += @('-Width', $m.Groups[1].Value, '-Height', $m.Groups[2].Value) }
    }

    Start-Process powershell -ArgumentList $a -WindowStyle Hidden
    $form.Close()
})

[void]$form.ShowDialog()
