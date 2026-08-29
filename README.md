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
| `tools/glyph-swap.ps1` | Switch the controller diagram between Xbox and PlayStation |
| `tools/acb-graphics.ps1` | Read and raise the multiplayer graphics settings |
| `tools/recolour_texture.py` | Recolour a persona or any BC1/BC2 texture, reversibly |
| `tools/recolour-persona.ps1` | Recolour a whole persona at once, with matching tone |
| `tools/bot_vm.py` | Behaviour VM for bot players — tiers, patrols, pursuit |
| `tools/warm-body.ps1` | Put bot players in a match so challenges can score |
| `tools/anvil-unpack/` | Unpack `.data` containers in batch, no GUI |
| `tools/anvil-inflate/` | Inflate a container chunk — archives, `OPTIONS`, `.SAV` |
| `tools/anvil-repack/` | Repack `.data` containers and the `.forge`, no GUI |

### Display modes

The game has no windowed or borderless option, and its options menu cannot be extended — it is Scaleform UI compiled into the executable. The launcher applies the window style via Win32 after launch instead:

```
powershell -File tools\acb-launcher.ps1 -Display Borderless -Quality High
powershell -File tools\acb-launcher.ps1 -Display Windowed -Width 1600 -Height 900
```

`-Quality High` passes `/shadows:full /postfx:full /msaa:8x`, switches found in
the game's own argument table.

Two of those used to be wrong. The MSAA switch has its own value vocabulary —
`none | 2x | 4x | 6x | 8x`, matching the `Multisample_8x`..`Multisample_None`
enum — so the old `/msaa:full` was not a value the game accepts and did nothing.
And `/lightmode:full` is no longer passed at all: `DisplayOptions::LightingMode`
enumerates `NormalLighting | DefaultLight | FullBright`, so `full` most likely
selects the flat debug view, which takes lighting *away*.

### Graphics quality — three INI files, and an open question

There are **three** INIs, not two, and until today the third was missed entirely:

```
%USERPROFILE%\Saved Games\Assassin's Creed Brotherhood\
    ACBrotherhood.ini      bare key names — ShadowQuality=4, PostFX=1
    ACBrotherhoodMP.ini    key bindings only
<game>\
    ACBrotherhoodMP.ini    Options* key names — OptionsShadowQuality=2
```

`ACBMP.exe` names **both** graphics files as wide strings, so the multiplayer
binary touches both and the third file is certainly real. **Which one actually
drives multiplayer rendering is unresolved**, and the two candidates predict
opposite things:

- the `Options*` file ships every quality key at **2**, the top of the
  three-step in-game menu;
- the bare-name file already ships **above** that — 4, 3 and 4 — so on that
  reading multiplayer is running high already.

Do not assume the convention splits by executable: `ACBSP.exe` contains the same
`Options*` names, and both binaries carry the bare names too. The bare list also
holds `SupportedMSAAModes` and `GraphicsModified`, which cannot be INI keys at
all, so some of those names are runtime properties rather than file keys.

Settling it needs one clean run: raise the keys with the game closed, exit
**through the menu**, re-read. Killing the process proves nothing — write-on-exit
is the whole mechanism.

```
powershell -File tools\acb-graphics.ps1 -Status
powershell -File tools\acb-graphics.ps1 -Set Beyond
powershell -File tools\acb-graphics.ps1 -Verify     # after playing once and quitting
powershell -File tools\acb-graphics.ps1 -Restore
```

The game rewrites this INI **on exit**, which is what makes the test work: set
the values, play a match, then quit **through the menu**. Do not open the in-game
graphics menu in between — saving it writes the menu's own values back over
yours. The script refuses to write while `ACBMP.exe` is running, and keeps a
backup of the original.

`-Verify` checks **whether the game rewrote the file** before it believes any
value, because a value comparison alone cannot tell a pass from a non-run:

| what `-Verify` sees | what it means |
|---|---|
| file unchanged | the run says **nothing** — usually the game was killed rather than exited, so the write never happened |
| rewritten, key gone | **inert** — the game rewrote the file and did not re-emit that key |
| rewritten, value back to 2 | **read and clamped** |
| rewritten, value still 5 | **read and honoured** — real headroom the menu never offers |

It baselines all three INIs, not just the one it edits, so a run that rewrites a
file nobody was watching is not mistaken for a run that rewrote nothing. On a
no-run it keeps the pending state so the test still stands.

It targets `<game>\ACBrotherhoodMP.ini`. If the open question above resolves the
other way, point it at the other file with `-GamePath`, or the tool will be
editing something the game ignores.

`-Set Beyond` also sets `MultiSampleType=8` and raises `RefreshRate` to the
display's actual rate; neither is a quality-menu entry, so neither is subject to
whatever the menu clamps.

### Controller glyphs — Xbox or PlayStation

Brotherhood ships **both** glyph sets on PC, but the executable only ever
requests the Xbox one, so `Binding_PS3` sits unused. `glyph-swap.ps1` puts
whichever artwork you want into the slot the game asks for, and switches back:

```
powershell -File tools\glyph-swap.ps1 -Status
powershell -File tools\glyph-swap.ps1 -Set PlayStation
powershell -File tools\glyph-swap.ps1 -Set Xbox
```

**Prerequisite** — unpack these in AnvilToolkit first, in order:
`multi\DataPC_extra.forge`, then `1000_-_Binding_360_DiffuseMapDesc.data`,
then `1001_-_Binding_PS3_DiffuseMapDesc.data`.

Afterwards repack in AnvilToolkit, inner first (`1000_-_...data`, then
`DataPC_extra.forge`). **Close the game before repacking** — it holds the forge
open and Repack fails silently, with no error and no log line.

The script keeps a pristine copy of the stock Xbox texture on first run, so the
switch is reversible. No game assets are redistributed; both textures are read
from your own installation.

**Why it needs a script rather than a file copy:** each TextureMap carries a
4-byte File ID at offset 2. Copying the PS3 texture brings its own ID
(`0x1D3FE379`) with it, the game cannot bind the texture, and the diagram
renders as a flat grey block. The script always rewrites the ID to the 360's
value (`0x1D3FE3AF`).

**Scope:** this changes the CONTROLLER LAYOUT diagram. Footer prompt icons are
drawn from `PC_btn_circle`, a PC-only texture with no PlayStation counterpart,
with the letter drawn over it as text — so those stay as they are.

### Recolouring personas

`recolour_texture.py` recolours a character by transforming only the two RGB565
**endpoints** of each compressed block and leaving the per-pixel index bits
alone. Every pixel changes colour while all detail, shading, folds and stitching
survive exactly — the block compression does the interpolation for you. There is
no decode, no re-encode and no image editor involved.

```
python tools/recolour_texture.py --texture "<path>\1_-_BarberUp_DiffuseMap.TextureMap" \
    --scheme gold_black --keep G2,H2,H3,H4 \
    --backup "<game>\multi\_persona_backup\BarberUp_ORIGINAL.TextureMap" \
    --preview out.png
```

| Option | Purpose |
|---|---|
| `--scheme` | Repaint: `gold_black`, `crimson_black`, `emerald_black`, `sapphire_black`, `bone_white`, `desaturate`. Enhance: `vibrant`, `vibrant_soft`, `vibrant_strong` |
| `--strength` | `0.0`–`1.0`, blend towards the scheme |
| `--grid` | Render a labelled `A1..H8` overlay of the atlas |
| `--keep` | Hold cells (`G2,H2`) or rects (`x0:y0:x1:y1`) at original colours |
| `--only` | Recolour **only** those cells — the inverse of `--keep` |
| `--part` | Recolour one named part from a region map |
| `--auto-map` | Analyse the atlas and write a starter region map |
| `--mask-coherence` | How much of the 3×3 around a block must agree before it is held back |
| `--max-saturation` | Only recolour blocks duller than N, so leather, wood and metal keep their own colour |
| `--strong-saturation` | Blocks this colourful are protected whatever their hue, so dyed cloth survives |
| `--levels` | Force one tonal range across every texture of an outfit so the halves match |
| `--dry-run` | Preview only, write nothing |
| `--restore` | Put the backup back |

Character textures are **atlases** — clothing, straps, boots and props share one
sheet. Use `--grid` to see the layout, then `--keep` to protect anything that
should stay its original colour.

`--max-saturation` is usually the better tool for that. Cloth is close to grey
while leather, wood and metal are strongly coloured, so a single threshold
(around `25`) recolours the garment and leaves its fittings alone — no region
picking, and it transfers to any persona.

Protection is **hue-aware**, which matters more than the threshold. On the
Barber, 6,549 protected blocks were warm (leather, wood, skin) and 771 were cool
blue-greys — and both sat in the same 30–44 saturation band, so no threshold
could separate them. Requiring protected blocks to be *warm* recolours the greys
and keeps the leather. `--strong-saturation` then rescues strongly dyed cloth of
any hue, so a green sash survives on warmth grounds it would otherwise fail.

#### Region maps — colouring parts individually

Saturation alone cannot tell a belt from a boot. A **region map** names parts of
an outfit so they can be coloured separately, and remembers them between
sessions:

```
python tools/recolour_texture.py --texture "<tex>" --regions tools/persona-regions.json     --persona Barber --auto-map
python tools/recolour_texture.py --texture "<tex>" --regions tools/persona-regions.json     --persona Barber --part fittings --scheme crimson_black
```

`--auto-map` classifies every grid cell by the **fraction** of blocks in it that
are colourful — not the mean, which averages a mixed cell back down to "cloth"
and was the first thing that went wrong here. It writes `cloth` and `fittings`
plus a `measured` table of per-cell colourfulness and brightness. Rename and
split those into real parts (`tunic`, `belt`, `boots`) as you identify them,
then colour each with its own scheme.

`tools/persona-regions.json` ships with the Barber already mapped.

To do a whole character at once, use the wrapper — it finds every diffuse
texture the persona owns, measures the tonal range **once** and forces it on all
of them, so the halves match instead of drifting apart:

```
powershell -File tools\recolour-persona.ps1 -Persona Barber -Scheme gold_black
powershell -File tools\recolour-persona.ps1 -Persona Barber -Status
powershell -File tools\recolour-persona.ps1 -Persona Barber -Restore
```

It reports which of the persona's resources still need unpacking in AnvilToolkit.
Head resources are skipped unless you pass `-IncludeHead`, since a recoloured
face reads as a rendering bug rather than a costume.

Afterwards repack in AnvilToolkit, inner `.data` first, then the `.forge`, with
the game closed.

#### Unpacking without the GUI

`tools/anvil-unpack` drives AnvilToolkit's own code through reflection, so
containers can be unpacked in batch instead of one click at a time. Needs the
[.NET 9 SDK](https://dotnet.microsoft.com/download/dotnet/9.0).

```
dotnet run --project tools/anvil-unpack -- --all "<game>\multi\Extracted\DataPC.forge" --filter _Set
```

64 persona containers in one pass. The container codec is LZO1X with the
algorithm and version carried in each block header — but rather than
reimplement it (an attempt that failed on the details), this calls
`DataFile.Deserialize` directly and gets exactly what the GUI produces.

`tools/anvil-repack` is the write half:

```
dotnet run --project tools/anvil-repack -- --data-all "<...>\DataPC.forge" --only-modified
dotnet run --project tools/anvil-repack -- --forge  "<...>\multi\DataPC.forge"
```

**Inner `.data` first, then the `.forge`** — the forge gathers the containers as
they are on disk, so doing it first silently repacks the originals.

Both paths write to a temp file and swap only on success, and both verify the
file actually changed. A repack against a forge held open by the game or
AnvilToolkit fails *silently* — no error, no log line — so "no exception" is not
evidence of success and is not treated as such. The forge keeps the previous
version beside it as `.bak`; delete it once you are satisfied.

**Texture format.** A `.TextureMap` is a 90-byte header, then raw BC blocks for
every mip level largest-first, then a 61-byte trailer. Because that trailer is
always 61 bytes, `filesize - payloadsize` always equals `151`, which looks
exactly like a header length and is not one — reading from there shifts every
block by 61 bytes. See [re/FINDINGS.md](re/FINDINGS.md) for the full layout and
the two bugs worth not repeating.

---

## Bots

`bot_vm.py` is a behaviour runtime for bot *players*. Brotherhood's AI is
compiled into `ACBMP.exe` and matches are peer-to-peer, so nothing can be
injected — a bot is a client with its own account, driven by synthetic input.

That constraint is also a feature: a bot has no position feed and no entity
list, so it genuinely cannot cheat. It goes off the face and heading of what is
on screen, and nothing else.

Behaviour is a small instruction set, the way a mission script walks a character
to a location — `GOTO`, `WANDER`, `LOOK`, `OBSERVE`, `STALK`, `PURSUE`, `KILL`,
`BLEND`, `WAIT` — with a program per state. Perception returns contacts carrying
only bearing, apparent distance, facing and appearance match. Confidence builds
by watching, and each tier needs a different amount before committing:

| Tier | Commits at | Patience | Sprints | Tells | Accuracy |
|---|---|---|---|---|---|
| `assassin` | 0.82 confidence | 7 ticks observing | 0% | 6% | **52%** |
| `hunter` | 0.62 | 4 ticks | 2% | 14% | 46% |
| `brute` | 0.38 | 1 tick | 6% | 27% | 39% |

Accuracy is over 60 runs of 120 ticks, scored against **ground truth** the bot
cannot see. A random guess scores 33%.

That baseline exists because the simulated crowd contains **doubles** —
civilians wearing the target's own persona, visually identical to it. That is
the game's central mechanic, and without it appearance alone identifies the
target and every tier scores 100%, which is exactly what the first version of
this simulator did.

With doubles present, appearance cannot discriminate and **behaviour has to**.
The only behavioural channel inside the face-and-direction constraint is
*facing*: civilians hold a heading, a player looks around. Reading that takes
repeated observation of **the same body**, which is what makes patience worth
something — and what makes the impatient tier wrong most of the time.

```
python tools/bot_vm.py --simulate --ticks 40 --seed 7
```

**Honest reading of those numbers.** The ordering is monotonic and matches the
design, and the behavioural metrics (sprint rate, tell rate, blown cover)
separate cleanly. The accuracy gap between `assassin` and `hunter` is only about
1.2 standard deviations, because the patient tier commits rarely and so has a
small sample — treat it as suggestive, not established. `brute` versus the
others is solid.

**Perception is still the blocker.** `ScreenPerception` returns nothing:
locating the compass and target indicator in screen space at a given resolution
and HUD scale has not been done. Everything above that boundary is tested; below
it, nothing is. A bot that hallucinates contacts is worse than one that stands
still, so it returns nothing rather than guessing.

### Warm bodies — `warm-body.ps1`

**Putting a body in a match needs no perception at all.** Ability challenges
need another live player present, not a skilled one — the game assigns contracts
itself, so a bot that logs in, joins and moves is enough to generate the
situations a challenge scores.

```
powershell -File tools\warm-body.ps1 -Count 2 -Macro tools\join-match.macro -DryRun
powershell -File tools\warm-body.ps1 -Count 2 -Macro tools\join-match.macro
powershell -File tools\warm-body.ps1 -Stop
```

It provisions throwaway accounts, launches one client per bot with
`/onlineUser` and `/onlinePassword` (switches confirmed working), walks a menu
macro, then wanders. It identifies nothing and reads nothing.

**Verified:** account creation, the launch switches, the input layer.
**Not verified:** that the game will run two instances at once, and the menu
macro. `join-match.macro` is a *starting point* — the keypresses to reach a
match cannot be derived without watching the menus, so it is data-driven and
ships uncalibrated rather than hard-coded to look tested. Run `-DryRun` first.

**Focus is exclusive.** `SendInput` goes to whichever window has focus, so the
script fronts each instance before driving it. While bots run you cannot use the
machine — that is inherent to driving a game through synthetic input.

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

- **Ability tuning, player counts and map rotation are locked** behind the `.cxb` encoding. The container format *is* solved: 28 sections, 40-byte header records of 32-byte name plus 8-byte ASCII size, payloads stored sequentially from offset 1192, and a trailer reporting 93,684 bytes uncompressed against 57,292 stored (~61%). The **per-section payload codec is not solved** — roughly 200 LZSS parameter combinations each decode exactly 33 correct bytes and then fail, which suggests a preset dictionary or a bespoke scheme. `tools/cxb_tool.py` parses the container if you want to continue this. **Tested against AnvilToolkit 1.3.6 and rejected** — the `.cxb` is not an Anvil `.data` container, and offering it as one produces no output at all. AnvilToolkit's own symbols (`tag_dictionary.tdct`, `ZstandardDictionary`, `GetDecompressionDictionary`) show Anvil resources use *dictionary-based* tokenised XML — which is why zlib, all six LZO variants, zstd and LZSS all fail: the back-references resolve into a dictionary that is not present in the file.
- **`.forge` modding does work.** AnvilToolkit unpacks the multiplayer archives, including `multi/DataPC_skins_*_dlc.forge`, into typed resources. That is the viable route for personas, armour and textures — but every player needs identical files, since gameplay is peer-to-peer.
- **Challenges cannot be completed *from the server*.** The challenges screen makes **zero** server requests, so progress is entirely client-side and no server change can affect it. Whether it can be reached locally depends on the save container codec, which is unsolved.
- **Stats do not persist.** `HermesPlayerStatisticsService` method 2 (write) discards everything it receives, and reads return hardcoded constants.
- **Save files can be read.** `tools/anvil-inflate` inflates any container chunk via AnvilToolkit's `CompressedFileData`, which understands the per-block table that hand-parsing misses. `ACBROTHERHOODSAVEGAME0.SAV` opens to 252,401 bytes and all four `OPTIONS` chunks open cleanly. The payloads are **hash-keyed binary** — 56–66% zeros, no readable field names — so opening them and locating challenge flags are different problems, and only the first is solved.
- **Local save state exists**, contrary to an earlier claim here. `Saved Games/.../SAVES/OPTIONS` and the `.SAV` carry the same container magic as the game archives and are rewritten on exit. Whether challenge progress is among what they hold is unverified, but it can no longer be ruled out. The container codec is unsolved and now gates three separate things — GUI-free unpacking, save editing, and probably the `.cxb` payload. See [re/FINDINGS.md](re/FINDINGS.md).
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
