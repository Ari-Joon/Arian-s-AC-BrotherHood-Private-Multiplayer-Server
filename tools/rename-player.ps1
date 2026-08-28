<#
  Renames an account. The in-game display name is the account name the client
  logs in with (client.User.Name), so this is what other players see.

  Usage:  .\tools\rename-player.ps1 -From Player -To JubblyJoon
          .\tools\rename-player.ps1 -List
#>
param(
    [string]$From,
    [string]$To,
    [switch]$List
)

$db = Join-Path $PSScriptRoot "..\ACB RDV\bin\x86\Release\database.sqlite"
if (-not (Test-Path $db)) { Write-Error "database.sqlite not found at $db"; exit 1 }

if ($List) { sqlite3 -column -header "$db" "SELECT pid, name, password FROM users ORDER BY pid;"; exit 0 }
if (-not $From -or -not $To) { Write-Error "Usage: -From <current> -To <new>   (or -List)"; exit 1 }

# Name is interpolated into SQL below, and is also passed on the game's command
# line, so keep it strictly alphanumeric.
if ($To -notmatch '^[A-Za-z0-9_]{1,15}$') {
    Write-Error "New name must be 1-15 chars, letters/digits/underscore only."; exit 1
}
if ((sqlite3 "$db" "SELECT COUNT(*) FROM users WHERE name='$From';") -eq '0') {
    Write-Error "No account named '$From'."; exit 1
}
if ((sqlite3 "$db" "SELECT COUNT(*) FROM users WHERE name='$To';") -ne '0') {
    Write-Error "'$To' is already taken."; exit 1
}

sqlite3 "$db" "UPDATE users SET name='$To', email='$To@notubi.com' WHERE name='$From';"
$pw = sqlite3 "$db" "SELECT password FROM users WHERE name='$To';"

Write-Host ""
Write-Host "Renamed '$From' -> '$To'" -ForegroundColor Green
Write-Host "  Launch with: ACBMP.exe /onlineUser:$To /onlinePassword:$pw"
Write-Host ""
Write-Host "If this is the account the desktop shortcut uses, update the" -ForegroundColor Yellow
Write-Host "`$user line in tools\launch-multiplayer.ps1 to match." -ForegroundColor Yellow
