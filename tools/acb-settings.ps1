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

$root     = Split-Path $PSScriptRoot -Parent
$server   = Join-Path $root "ACB RDV\bin\x86\Release"
$db       = Join-Path $server "database.sqlite"
$launcher = Join-Path $PSScriptRoot "acb-launcher.ps1"
$cfgPath  = Join-Path $PSScriptRoot "settings.json"

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

# Standard 16:9 / 16:10 modes, plus the monitor's native size. Only those that
# actually fit on this display are offered.
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

# --- form --------------------------------------------------------------------
$form                 = New-Object Windows.Forms.Form
$form.Text            = "Assassin's Creed Brotherhood - Multiplayer"
$form.Size            = New-Object Drawing.Size(440, 500)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false

function Add-Label($text, $x, $y, $bold) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object Drawing.Point($x, $y)
    $l.AutoSize = $true
    if ($bold) { $l.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold) }
    $form.Controls.Add($l)
    return $l
}

# --- graphics ----------------------------------------------------------------
[void](Add-Label "GRAPHICS" 20 18 $true)
[void](Add-Label "Display mode" 20 48 $false)

$modes  = @('Fullscreen','Borderless','Windowed')
$radios = @{}
$y = 70
foreach ($m in $modes) {
    $r = New-Object Windows.Forms.RadioButton
    $r.Text = $m
    $r.Location = New-Object Drawing.Point(35, $y)
    $r.AutoSize = $true
    $r.Checked = ($cfg.Display -eq $m)
    $form.Controls.Add($r)
    $radios[$m] = $r
    $y += 26
}

$resLabel = Add-Label "Resolution" 20 152 $false
$resBox = New-Object Windows.Forms.ComboBox
$resBox.Location = New-Object Drawing.Point(35, 174)
$resBox.Size = New-Object Drawing.Size(200, 24)
$resBox.DropDownStyle = 'DropDownList'
foreach ($r in $resList) { [void]$resBox.Items.Add($r) }
if ($cfg.Resolution -and $resBox.Items.Contains($cfg.Resolution)) {
    $resBox.SelectedItem = $cfg.Resolution
} else {
    $resBox.SelectedIndex = 0
}
$form.Controls.Add($resBox)

[void](Add-Label "Visual quality" 20 212 $false)
$qBox = New-Object Windows.Forms.ComboBox
$qBox.Location = New-Object Drawing.Point(35, 234)
$qBox.Size = New-Object Drawing.Size(200, 24)
$qBox.DropDownStyle = 'DropDownList'
[void]$qBox.Items.Add('Default')
[void]$qBox.Items.Add('High')
$qBox.SelectedItem = $(if ($cfg.Quality) { $cfg.Quality } else { 'High' })
$form.Controls.Add($qBox)

# Resolution only applies to Windowed; the other modes use the full display.
$syncRes = {
    $on = $radios['Windowed'].Checked
    $resBox.Enabled = $on
    $resLabel.Text = $(if ($on) { "Resolution" } else { "Resolution (Windowed only)" })
}
foreach ($m in $modes) { $radios[$m].Add_CheckedChanged($syncRes) }
& $syncRes

# --- account -----------------------------------------------------------------
[void](Add-Label "ACCOUNT" 20 276 $true)
[void](Add-Label "This is the name other players see in-game." 20 298 $false)
$uBox = New-Object Windows.Forms.ComboBox
$uBox.Location = New-Object Drawing.Point(35, 320)
$uBox.Size = New-Object Drawing.Size(200, 24)
$uBox.DropDownStyle = 'DropDownList'
foreach ($a in $accounts) { [void]$uBox.Items.Add($a) }
$uBox.SelectedItem = $(if ($cfg.User -and $accounts -contains $cfg.User) { $cfg.User } else { $accounts[0] })
$form.Controls.Add($uBox)

# Small modal prompt; avoids taking a dependency on Microsoft.VisualBasic.
function Show-NamePrompt($current) {
    $d = New-Object Windows.Forms.Form
    $d.Text = "Rename account"
    $d.Size = New-Object Drawing.Size(340, 170)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false

    $l = New-Object Windows.Forms.Label
    $l.Text = "New name (letters, digits, underscore; max 15):"
    $l.Location = New-Object Drawing.Point(15, 15); $l.AutoSize = $true
    $d.Controls.Add($l)

    $t = New-Object Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point(18, 42); $t.Size = New-Object Drawing.Size(290, 24)
    $t.Text = $current; $t.MaxLength = 15
    $d.Controls.Add($t)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = "OK"; $ok.Location = New-Object Drawing.Point(140, 85)
    $ok.Size = New-Object Drawing.Size(80, 30); $ok.DialogResult = 'OK'
    $d.Controls.Add($ok); $d.AcceptButton = $ok

    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = "Cancel"; $cancel.Location = New-Object Drawing.Point(228, 85)
    $cancel.Size = New-Object Drawing.Size(80, 30); $cancel.DialogResult = 'Cancel'
    $d.Controls.Add($cancel); $d.CancelButton = $cancel

    if ($d.ShowDialog() -eq 'OK') { return $t.Text.Trim() }
    return $null
}

$renameBtn = New-Object Windows.Forms.Button
$renameBtn.Text = "Rename..."
$renameBtn.Location = New-Object Drawing.Point(245, 319)
$renameBtn.Size = New-Object Drawing.Size(90, 26)
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

$note = Add-Label "High quality passes /shadows /postfx /lightmode /msaa." 20 360 $false
$note.ForeColor = [Drawing.Color]::DimGray

# --- launch ------------------------------------------------------------------
$btn = New-Object Windows.Forms.Button
$btn.Text = "PLAY"
$btn.Location = New-Object Drawing.Point(262, 392)
$btn.Size = New-Object Drawing.Size(130, 46)
$btn.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
$form.Controls.Add($btn)
$form.AcceptButton = $btn

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
        # Entries look like "1600 x 900" or "2560 x 1600  (native)".
        $m = [regex]::Match([string]$resBox.SelectedItem, '(\d+)\s*x\s*(\d+)')
        if ($m.Success) { $a += @('-Width', $m.Groups[1].Value, '-Height', $m.Groups[2].Value) }
    }

    Start-Process powershell -ArgumentList $a -WindowStyle Hidden
    $form.Close()
})

[void]$form.ShowDialog()
