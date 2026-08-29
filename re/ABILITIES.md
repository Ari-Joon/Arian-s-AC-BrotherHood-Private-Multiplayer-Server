# Ability and game-mode tuning

Server-authoritative, working, and verified. This is the part of the project
with the least guesswork in it: the write path reproduces the game's own file
byte for byte.

## The key fact: the server serves the rules

`QuazalWV/RMC/Services/PersistentStoreService/PersistentStoreService.cs`:

```csharp
case 4:
    const string fileName = "gamesettings_c1380_d873_s6285.cxb";
    reply = new RMCPacketResponsePersistentStoreService_GetItem(fileName);
```

and the response simply reads the bytes off disk:

```csharp
Content = File.ReadAllBytes(fileName);
```

Every client requests this on connect. **Edit it once on the host and everyone
who joins plays by the new rules** - no client-side forge patching, and no game
asset has to be sent to anyone. The file lives beside the server executable at
`ACB RDV/bin/x86/Release/`.

An earlier note asked whether the copy at `multi/Backups/gamesettings_test.data`
was live. It is the same file - identical MD5 `032a6330...` - so anything
learned from it applies directly.

## What is in it

28 sections. `tools/cxb-edit list` prints them with packed and unpacked sizes.

| Section | Unpacked | What it controls |
|---|---|---|
| `abilitymanagermulti` | 93,684 | every ability's parameters |
| `custommanagermulti` | 244,279 | customisation |
| `gamemodemanagermulti` | 10,618 | mode list |
| `gamemodeparams_*` (10) | ~1,670 each | per-mode rules, one per mode |
| `gamemode_*` (10) | ~6,500-11,300 | per-mode definitions |
| `globalparams` | 2,090 | global tuning |
| `levelxpmanager` | 7,098 | XP curve |
| `scorebonusmanager` | 17,301 | score bonuses |
| `mapmanagermulti` | 19,992 | maps |

The ability section is plain XML (ISO-8859-1), 75 ability entries across 24
classes, with these tunables:

| Parameter | Count |
|---|---|
| `CooldownDuration` | 48 |
| `Duration` | 37 |
| `Radius` | 20 |
| `SpeedFactor` | 10 |
| `Delay` | 8 |
| `Range` | 8 |
| `StreakValue` | 8 |

Classes: AutoBash, ChaseBoost, Decoy, Disguise, Escapist, ExtraSensitivity,
FireCracker, HiddenGun, KillScoreBonus, Morph, OverallCooldown, Poison,
PowerCharge, ResetCooldowns, Resistance, ScoreX2, Silent, SilentHunt,
SmokeBomb, SpeedBoost, TemplarVision, ThrowingKnives.

## Container layout

Verified against the live 58,484-byte file:

```
0      28 records x 40 bytes: name[32] NUL-padded, size[8] ASCII decimal
1120   1 trailer record, 40 bytes, "781866825"
1160   payloads in record order, each exactly its declared size
       payload = u32 uncompressed size, then a chunk (magic 33 AA FB 57 99 FA 04 10)
```

Declared sizes total 57,324, and 58,484 - 1120 - 40 = 57,324 exactly.

## The write path is proven

`AnvilToolkit.Compressions.Manager` has the mirror of the decompressor, and
`CompressedFileData` has `Create` and `Write` alongside `Read`:

```
Byte[] Decompress(Int32 Algo, Int32 AlgoVersion, Byte[] CData, Int32 UncompressedSize, Game Version)
Byte[] Compress  (Int32 Algo, Int32 AlgoVersion, Byte[] UData, Int32 Length, Game Version, Boolean Lock)
```

Extracting `abilitymanagermulti` and writing it straight back produced a file
with the **same MD5 as the original**, `032a6330...`, and the section repacked
to exactly its original 5,468 bytes. Reproducing the shipped file bit for bit
is the strongest evidence available that an edited file will be equally valid.

`cxb-edit` finds the right settings by trying the plausible
`AlgorithmOverride`/`TOCMode` combinations and keeping the first that reads
back identically; for this file that is `algo=-1 toc=False`.

## Usage

```
cxb-edit list    <file.cxb>
cxb-edit extract <file.cxb> <section> <out.xml>
cxb-edit replace <file.cxb> <section> <in.xml> [--out <file>]
```

`replace` backs the original up to `.bak`, then re-parses its own output and
inflates the section it just wrote. If that does not match the input byte for
byte it writes nothing - this file is served to every client, so a silent
corruption would break all of them at once.

## Still unknown

**The 40-byte trailer, `781866825`.** It is preserved verbatim, which is why an
unchanged rebuild is bit-identical. Whether it is a checksum over the payloads
is untested, because nothing has changed a payload size yet. If the game
rejects an edited file, this is the first thing to suspect: a size-changing
edit is the case that would expose it. A same-size edit (e.g. `60.0` -> `30.0`,
both four characters) avoids the question entirely and is the safest first
experiment.

## Note on the repo

`gamesettings_c1380_d873_s6285.cxb` is currently **tracked in git**. It is a
game asset, and the project's rule is that users supply their own copy. The
server cannot start without it, so removing it needs a plan for where players
get theirs, rather than a straight deletion.
