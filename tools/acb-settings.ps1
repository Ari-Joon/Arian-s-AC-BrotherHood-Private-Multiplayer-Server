<#
  AC Brotherhood - private server launcher with a graphics settings screen.

  The game's own options menu is compiled into ACBMP.exe and cannot be extended,
  so display mode lives here instead. Choices are remembered between runs in
  settings.json next to this script.

  MUST be run with -STA:
      powershell -STA -File tools\acb-settings.ps1
  In MTA mode ShowDialog() returns immediately and no window is shown.
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

# --- palette -----------------------------------------------------------------
$cBg     = [Drawing.Color]::FromArgb(22, 22, 26)
$cPanel  = [Drawing.Color]::FromArgb(32, 32, 38)
$cText   = [Drawing.Color]::FromArgb(236, 236, 240)
$cMuted  = [Drawing.Color]::FromArgb(138, 138, 150)
$cAccent = [Drawing.Color]::FromArgb(198, 52, 62)
$cAccentHi = [Drawing.Color]::FromArgb(222, 68, 78)

$fH1   = New-Object Drawing.Font("Segoe UI Semibold", 15, [Drawing.FontStyle]::Regular)
$fHead = New-Object Drawing.Font("Segoe UI Semibold", 9,  [Drawing.FontStyle]::Regular)
$fBody = New-Object Drawing.Font("Segoe UI", 9.5, [Drawing.FontStyle]::Regular)
$fBtn  = New-Object Drawing.Font("Segoe UI Semibold", 11, [Drawing.FontStyle]::Regular)

# --- saved preferences -------------------------------------------------------
$cfg = @{ Display = 'Borderless'; Quality = 'High'; Resolution = ''; User = '' }
if (Test-Path $cfgPath) {
    try {
        (Get-Content $cfgPath -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $cfg[$_.Name] = $_.Value }
    } catch { }
}

$accounts = @(sqlite3 "$db" "SELECT name FROM users WHERE name <> 'Tracking' ORDER BY pid;")
if (-not $accounts) { $accounts = @('Player') }

# --- true (non-DPI-scaled) desktop size, for the resolution list --------------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Scr {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int  GetSystemMetrics(int i);
}
"@
[void][Scr]::SetProcessDPIAware()
$nativeW = [Scr]::GetSystemMetrics(0)
$nativeH = [Scr]::GetSystemMetrics(1)

$standard = @(
    @(1280,720), @(1366,768), @(1440,900), @(1600,900), @(1680,1050),
    @(1920,1080), @(1920,1200), @(2560,1440), @(2560,1600), @(3440,1440), @(3840,2160)
)
$resList = New-Object System.Collections.Generic.List[string]
$resList.Add("$nativeW x $nativeH   (native)")
foreach ($r in $standard) {
    if ($r[0] -le $nativeW -and $r[1] -le $nativeH -and -not ($r[0] -eq $nativeW -and $r[1] -eq $nativeH)) {
        $resList.Add("$($r[0]) x $($r[1])")
    }
}

# --- form --------------------------------------------------------------------
$form                 = New-Object Windows.Forms.Form
$form.Text            = "Assassin's Creed Brotherhood"
$form.ClientSize      = New-Object Drawing.Size(440, 520)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
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
    $p.BackColor = [Drawing.Color]::FromArgb(52, 52, 60)
    $form.Controls.Add($p)
}

function Style-Combo($c) {
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle     = 'Flat'
    $c.BackColor     = $cPanel
    $c.ForeColor     = $cText
    $c.Font          = $fBody
}

# --- header ------------------------------------------------------------------
[void](Add-Text "BROTHERHOOD" 28 24 $fH1 $cText)
[void](Add-Text "Private multiplayer server" 30 52 $fBody $cMuted)
Add-Rule 28 84 384

# --- graphics ----------------------------------------------------------------
[void](Add-Text "GRAPHICS" 28 102 $fHead $cAccent)

[void](Add-Text "Display mode" 28 132 $fBody $cMuted)
$modes  = @('Fullscreen','Borderless','Windowed')
$radios = @{}
$x = 32
foreach ($m in $modes) {
    $r = New-Object Windows.Forms.RadioButton
    $r.Text = $m
    $r.Location = New-Object Drawing.Point($x, 156)
    $r.AutoSize = $true
    $r.Font = $fBody
    $r.ForeColor = $cText
    $r.BackColor = [Drawing.Color]::Transparent
    $r.Checked = ($cfg.Display -eq $m)
    $form.Controls.Add($r)
    $radios[$m] = $r
    $x += 128
}

$resLabel = Add-Text "Resolution" 28 196 $fBody $cMuted
$resBox = New-Object Windows.Forms.ComboBox
$resBox.Location = New-Object Drawing.Point(32, 218)
$resBox.Size = New-Object Drawing.Size(240, 26)
Style-Combo $resBox
foreach ($r in $resList) { [void]$resBox.Items.Add($r) }
if ($cfg.Resolution -and $resBox.Items.Contains($cfg.Resolution)) {
    $resBox.SelectedItem = $cfg.Resolution
} else { $resBox.SelectedIndex = 0 }
$form.Controls.Add($resBox)

[void](Add-Text "Visual quality" 28 258 $fBody $cMuted)
$qBox = New-Object Windows.Forms.ComboBox
$qBox.Location = New-Object Drawing.Point(32, 280)
$qBox.Size = New-Object Drawing.Size(240, 26)
Style-Combo $qBox
[void]$qBox.Items.Add('Default')
[void]$qBox.Items.Add('High')
$qBox.SelectedItem = $(if ($cfg.Quality) { $cfg.Quality } else { 'High' })
$form.Controls.Add($qBox)

$qHint = Add-Text "High passes /shadows /postfx /lightmode /msaa" 32 310 $fBody $cMuted
$qHint.Font = New-Object Drawing.Font("Segoe UI", 8.25)

# Resolution only applies to Windowed; other modes use the whole display.
$syncRes = {
    $on = $radios['Windowed'].Checked
    $resBox.Enabled  = $on
    $resLabel.Text   = $(if ($on) { "Resolution" } else { "Resolution  -  windowed only" })
    $resBox.ForeColor = $(if ($on) { $cText } else { $cMuted })
}
foreach ($m in $modes) { $radios[$m].Add_CheckedChanged($syncRes) }
& $syncRes

Add-Rule 28 344 384

# --- account -----------------------------------------------------------------
[void](Add-Text "ACCOUNT" 28 362 $fHead $cAccent)
[void](Add-Text "The name other players see in-game" 28 388 $fBody $cMuted)

$uBox = New-Object Windows.Forms.ComboBox
$uBox.Location = New-Object Drawing.Point(32, 412)
$uBox.Size = New-Object Drawing.Size(240, 26)
Style-Combo $uBox
foreach ($a in $accounts) { [void]$uBox.Items.Add($a) }
$uBox.SelectedItem = $(if ($cfg.User -and $accounts -contains $cfg.User) { $cfg.User } else { $accounts[0] })
$form.Controls.Add($uBox)

# Small modal prompt; avoids a dependency on Microsoft.VisualBasic.
function Show-NamePrompt($current) {
    $d = New-Object Windows.Forms.Form
    $d.Text = "Rename account"
    $d.ClientSize = New-Object Drawing.Size(330, 150)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.BackColor = $cBg; $d.ForeColor = $cText; $d.Font = $fBody

    $l = New-Object Windows.Forms.Label
    $l.Text = "New name"
    $l.Location = New-Object Drawing.Point(20, 20); $l.AutoSize = $true
    $l.ForeColor = $cMuted
    $d.Controls.Add($l)

    $t = New-Object Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point(22, 44); $t.Size = New-Object Drawing.Size(286, 26)
    $t.Text = $current; $t.MaxLength = 15
    $t.BackColor = $cPanel; $t.ForeColor = $cText; $t.BorderStyle = 'FixedSingle'
    $d.Controls.Add($t)

    $h = New-Object Windows.Forms.Label
    $h.Text = "Letters, digits and underscore. Max 15."
    $h.Location = New-Object Drawing.Point(22, 74); $h.AutoSize = $true
    $h.ForeColor = $cMuted; $h.Font = New-Object Drawing.Font("Segoe UI", 8.25)
    $d.Controls.Add($h)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = "Save"; $ok.Location = New-Object Drawing.Point(148, 104)
    $ok.Size = New-Object Drawing.Size(74, 30); $ok.DialogResult = 'OK'
    $ok.FlatStyle = 'Flat'; $ok.BackColor = $cAccent; $ok.ForeColor = [Drawing.Color]::White
    $ok.FlatAppearance.BorderSize = 0
    $d.Controls.Add($ok); $d.AcceptButton = $ok

    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = "Cancel"; $cancel.Location = New-Object Drawing.Point(232, 104)
    $cancel.Size = New-Object Drawing.Size(76, 30); $cancel.DialogResult = 'Cancel'
    $cancel.FlatStyle = 'Flat'; $cancel.BackColor = $cPanel; $cancel.ForeColor = $cText
    $cancel.FlatAppearance.BorderSize = 0
    $d.Controls.Add($cancel); $d.CancelButton = $cancel

    if ($d.ShowDialog() -eq 'OK') { return $t.Text.Trim() }
    return $null
}

$renameBtn = New-Object Windows.Forms.Button
$renameBtn.Text = "Rename"
$renameBtn.Location = New-Object Drawing.Point(284, 411)
$renameBtn.Size = New-Object Drawing.Size(84, 28)
$renameBtn.FlatStyle = 'Flat'
$renameBtn.BackColor = $cPanel
$renameBtn.ForeColor = $cText
$renameBtn.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(70, 70, 80)
$renameBtn.FlatAppearance.BorderSize = 1
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

# --- play --------------------------------------------------------------------
$btn = New-Object Windows.Forms.Button
$btn.Text = "PLAY"
$btn.Location = New-Object Drawing.Point(28, 460)
$btn.Size = New-Object Drawing.Size(384, 44)
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

    @{
        Display    = $mode
        Quality    = $qBox.SelectedItem
        Resolution = $resBox.SelectedItem
        User       = $uBox.SelectedItem
    } | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding utf8

    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$launcher`"",
           '-Display', $mode, '-Quality', $qBox.SelectedItem, '-User', $uBox.SelectedItem)

    if ($mode -eq 'Windowed') {
        # Entries look like "1600 x 900" or "2560 x 1600   (native)".
        $m = [regex]::Match([string]$resBox.SelectedItem, '(\d+)\s*x\s*(\d+)')
        if ($m.Success) { $a += @('-Width', $m.Groups[1].Value, '-Height', $m.Groups[2].Value) }
    }

    Start-Process powershell -ArgumentList $a -WindowStyle Hidden
    $form.Close()
})

[void]$form.ShowDialog()
