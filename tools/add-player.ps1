<#
  Adds an account to the AC Brotherhood private server database.
  Passwords are stored and transmitted in PLAINTEXT (Quazal protocol limitation),
  so this generates a random throwaway per player. Never reuse a real password.

  Usage:  .\tools\add-player.ps1 -Name Marco
          .\tools\add-player.ps1 -Name Marco -List
#>
param(
    [Parameter(Mandatory=$false)][string]$Name,
    [switch]$List
)

$db = Join-Path $PSScriptRoot "..\ACB RDV\bin\x86\Release\database.sqlite"
if (-not (Test-Path $db)) { Write-Error "database.sqlite not found at $db"; exit 1 }

if ($List) {
    sqlite3 -column -header "$db" "SELECT pid, name, password FROM users ORDER BY pid;"
    exit 0
}

if (-not $Name) { Write-Error "Supply -Name <player> or -List"; exit 1 }
if ($Name -notmatch '^[A-Za-z0-9_]{1,15}$') {
    Write-Error "Name must be 1-15 chars, letters/digits/underscore only."; exit 1
}

$exists = sqlite3 "$db" "SELECT COUNT(*) FROM users WHERE name='$Name';"
if ($exists -ne '0') { Write-Error "A user named '$Name' already exists."; exit 1 }

# Command-line safe charset: the password is passed via /onlinePassword: on the
# game's command line, so no quotes, spaces or shell metacharacters.
$chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
$bytes = [byte[]]::new(20)
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$pw = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })

$maxPid = sqlite3 "$db" "SELECT COALESCE(MAX(pid),1000) FROM users;"
$newPid = [int]$maxPid + 1

sqlite3 "$db" @"
INSERT INTO users (pid, name, password, ubi_id, email, country_code, pref_lang)
VALUES ($newPid,'$Name','$pw','1234abcd-5678-90ef-4321-0987654321fe','$Name@notubi.com','US','en');
"@

Write-Host ""
Write-Host "Account created." -ForegroundColor Green
Write-Host "  name     : $Name"
Write-Host "  password : $pw"
Write-Host ""
Write-Host "Send them this launch command:" -ForegroundColor Cyan
Write-Host "  ACBMP.exe /onlineUser:$Name /onlinePassword:$pw"
