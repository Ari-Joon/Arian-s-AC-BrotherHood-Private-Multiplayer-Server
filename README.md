# AC Brotherhood — Private Multiplayer Server + Launcher

A private matchmaking server for **Assassin's Creed: Brotherhood** multiplayer, whose official Ubisoft services were decommissioned on 1 October 2022 — plus a launcher that adds display and quality options the game itself does not expose.

This is a fork of [michal-kapala/acb-rdv](https://github.com/michal-kapala/acb-rdv), which does the hard part: reimplementing Ubisoft's Quazal **Rendez-Vous** backend.

> **You need your own legal copy of the game.** No game assets are distributed here.

---

## What this actually is

Brotherhood's multiplayer splits in two:

| Layer | Who handles it |
|---|---|
| Login, lobbies, matchmaking, friends | **This server** (Quazal Rendez-Vous) |
| The match itself | **Peer-to-peer between players** |

The server introduces players to each other and then steps out. It never sees the gameplay. That means you do not need a powerful host — but it also means players must be able to reach each other directly (see *Networking*).

---

## Requirements

- Assassin's Creed: Brotherhood (PC)
- Windows, .NET Framework **4.8 runtime** (Windows 10/11 ships with it)
- **.NET Framework 4.8 Developer Pack** — build only ([download](https://aka.ms/msbuild/developerpacks))
- Visual Studio 2022, or Build Tools (MSBuild)
- [SQLite CLI](https://sqlite.org/download.html) on `PATH`

---

## Setup

### 1. Build

```
MSBuild "ACB RDV\ACB RDV.csproj" -p:Configuration=Release -p:Platform=x86
```

> Upstream gitignores `*.config`, so `packages.config` is not committed and NuGet restore cannot run. Every required DLL already ships in `ACB RDV/bin/x86/Release/` — recreate `packages/` from those, plus a stub for `Stub.System.Data.SQLite.Core.NetFramework.targets` (its only job is copying a native DLL the repo already includes).

### 2. Database

```
sqlite3 "ACB RDV\bin\x86\Release\database.sqlite" < db_init.sql
sqlite3 "ACB RDV\bin\x86\Release\database.sqlite" < tools\dlc-privileges.sql
```

Then **change the default password** — `Player`/`pass` is published in this repo:

```
powershell -File tools\rename-player.ps1 -List
```

### 3. Point the server at an address

`App.config` is per-user and not tracked. Copy the template:

```
copy "ACB RDV\App.config.example" "ACB RDV\App.config"
```

Then set `SecureServerAddress` to the IP players will reach you on:

```xml
<appSettings>
  <add key="SecureServerAddress" value="YOUR.IP.HERE" />
</appSettings>
```

This value is **both** the bind address and what clients are told to connect to, so it must be a real adapter on the host *and* reachable by every player. Rebuild after changing it.

### 4. Each client

Add to `C:\Windows\System32\drivers\etc\hosts` (needs admin):

```
YOUR.IP.HERE onlineconfigservice.ubi.com
```

### 5. Play

```
powershell -STA -File tools\acb-settings.ps1
```

> `-STA` is required. In MTA mode `ShowDialog()` returns immediately and no window appears.

---

## Networking

Because the server binds the literal IP it advertises, **port forwarding a public IP does not work** — you cannot bind an address that lives on your router.

Use a virtual LAN instead. Every player installs [Radmin VPN](https://www.radmin-vpn.com/) (or ZeroTier / Tailscale), joins one network, and the host uses their `26.x.x.x` address as `SecureServerAddress`. The same virtual LAN also carries the peer-to-peer gameplay traffic, so nobody needs router configuration.

Ports: **TCP 80**, **UDP 21030–21031**. Scope firewall rules to the virtual LAN subnet only — never expose them to the internet.

---

## Tools

| Script | Purpose |
|---|---|
| `tools/acb-settings.ps1` | Launcher GUI — display mode, quality, account |
| `tools/acb-launcher.ps1` | CLI launcher; starts the server, applies window style |
| `tools/add-player.ps1` | Create an account with a random password |
| `tools/rename-player.ps1` | Rename an account (this is the in-game name) |
| `tools/dlc-privileges.sql` | DLC entitlements + locale fix |
| `tools/cxb_tool.py` | Parse the `gamesettings` `.cxb` container |

### Display modes

The game has no windowed or borderless option, and its options menu cannot be extended — it is Scaleform UI compiled into the executable. The launcher applies the window style via Win32 after launch instead:

```
powershell -File tools\acb-launcher.ps1 -Display Borderless -Quality High
powershell -File tools\acb-launcher.ps1 -Display Windowed -Width 1600 -Height 900
```

`-Quality High` passes `/shadows:full /postfx:full /lightmode:full /msaa:full`, switches found in the game's own argument table.

---

## Changes from upstream

### Security

- **SQL injection fixed** in `GetPrivileges`. `LocaleCode` came straight off the network into an interpolated query, exposing the `users` table — which stores plaintext passwords. Now parameterised.
- **Passwords no longer logged** in cleartext by `LoginEx` / `RegisterEx`.
- **UDP listeners bind one interface.** `AuthServer` and `RdvServer` used `new UdpClient(port)` (i.e. `0.0.0.0`), exposing the pre-authentication packet parsers on every adapter. They now bind `SecureServerAddress`, matching `OnlineConfigService`.

### Fixes

- **Locale bug.** `GetPrivileges` filters on an exact locale match and only `en-US` was seeded — a client requesting `en-GB` received *nothing*, including privilege 1, "Allow to play online". `tools/dlc-privileges.sql` mirrors all locales.
- DLC entitlements for the multiplayer DLC (Alhambra, Mont Saint-Michel, Pienza, three skin packs). **IDs are inferred and unverified** — see *Known limits*.

### Convenience

- The server auto-starts its services on launch; no toolbar click needed.
- Launcher, account creation and rename tooling.

---

## Known limits

Findings from testing, recorded so nobody repeats the work.

- **Ability tuning, player counts and map rotation are locked** behind the `.cxb` encoding. The container format *is* solved: 28 sections, 40-byte header records of 32-byte name plus 8-byte ASCII size, payloads stored sequentially from offset 1192, and a trailer reporting 93,684 bytes uncompressed against 57,292 stored (~61%). The **per-section payload codec is not solved** — roughly 200 LZSS parameter combinations each decode exactly 33 correct bytes and then fail, which suggests a preset dictionary or a bespoke scheme. `tools/cxb_tool.py` parses the container if you want to continue this.
- **Challenges cannot be completed.** The challenges screen makes **zero** server requests; progress is entirely client-side. No server change can affect it, and there is no local save file, so it never persists.
- **Stats do not persist.** `HermesPlayerStatisticsService` method 2 (write) discards everything it receives, and reads return hardcoded constants.
- **`GetPrivileges` and `GetRewards` were never observed being called** by the client, so the DLC and reward entries may never be read at all.
- **New abilities are not possible.** The eight abilities are compiled into `ACBMP.exe`; the `.cxb` only supplies their parameters.
- `HermesAchievements` (`0x74`) and `AcbProxyGameProfile` (`0x79`) are declared in the protocol enum but unimplemented — and the client never requests them.

---

## Credits and licence

- [michal-kapala/acb-rdv](https://github.com/michal-kapala/acb-rdv) — the server this forks
- [Warranty Voider](https://github.com/zeroKilo) — original GRO backend
- [Kinnay](https://github.com/kinnay/NintendoClients/wiki) — PRUDP / NEX documentation
- [AC:MPR Discord](https://discord.com/invite/SVtzwm8) — the community keeping this alive

**MIT with [Commons Clause](https://commonsclause.com/)** — non-commercial only, per upstream. Not affiliated with Ubisoft. Built on Ubisoft's own [end-of-life announcement](https://www.ubisoft.com/en-us/help/purchases-and-rewards/article/decommissioning-of-online-services-for-older-legacy-ubisoft-games-a-m/000064576) for the game's online services.
