# ACBMP.exe — reverse-engineering recon

First-pass reconnaissance of the multiplayer executable. No disassembler used —
this is all PE structure and string analysis, done as preparation for anyone
continuing with Ghidra or IDA.

## Binary

| | |
|---|---|
| File | `ACBMP.exe`, 38,376,568 bytes |
| Architecture | x86 (PE32) |
| Image base | `0x00400000` |
| Built | timestamp 1300982818 — 24 March 2011 |
| Sections | 7 |

```
.text    va=0x00001000  vsize=30,202,980   RX
.rdata   va=0x01ccf000  vsize= 2,754,698   R
.data    va=0x01f70000  vsize= 3,296,952   RW
.data1   va=0x02295000  vsize=     1,520   RW
.tls     va=0x02296000  vsize=       137   RW
.rsrc    va=0x02297000  vsize= 1,721,012   R
.reloc   va=0x0243c000  vsize= 1,471,914   R
```

A 30 MB `.text` — this is a large codebase to work through.

## Notable imports

- **`WS2_32`** — `WSASendTo`, `WSARecvFrom`, `WSAConnect`, `WSASocketA`.
  The UDP peer-to-peer layer. Where netcode work would start.
- **`KERNEL32`** — `GetPrivateProfileIntW`, `GetPrivateProfileStringW`,
  `WritePrivateProfileStringW`, `GetPrivateProfileSectionNamesW`.
  **The game reads and writes INI configuration.** This is the most useful
  finding: a settings surface that needs no binary modification.
- **`imagehlp`** — `StackWalk`, `SymGetSymFromAddr`, `UnDecorateSymbolName`.
  A crash handler with symbol resolution. Symbol names may be recoverable.
- **`XINPUT1_3`** — controller support.
- No static `d3d9.dll` import; Direct3D is loaded dynamically.

## Configuration files

Referenced by name in the binary:

| File | Notes |
|---|---|
| `ACBrotherhoodMP.ini` | multiplayer settings — **two files carry this name**, see below |
| `ACBrotherhood.ini` | singleplayer settings |
| `VertexShaderConfig.ini` | shader configuration |
| `PixelShaderConfig.ini` | shader configuration |
| `LightingShaderConfig.ini` | shader configuration |
| `multi\DefaultBindings.map` | key bindings — **this file exists on disk**, 17 KB |

**Location found** — the Windows *Saved Games* known folder, which is why no
`Documents` or `My Games` string appears in the binary:

```
%USERPROFILE%\Saved Games\Assassin's Creed Brotherhood\
    ACBrotherhood.ini      <- singleplayer [Graphics] + input profiles
    ACBrotherhoodMP.ini    <- multiplayer key bindings only
    SAVES\

<game>\
    ACBrotherhoodMP.ini    <- multiplayer [Graphics]   *** easy to miss ***
```

The game writes its config **early in startup, with the process alive** — not on
exit. A watcher caught `ACBrotherhood.ini` change twice within seconds of launch,
and a run ended with `Stop-Process -Force` still found the file already rewritten.
"Written on exit" appeared throughout this document and was wrong; it made a
clean menu exit look necessary for any config experiment, and it is not.

All three are plain ASCII with LF endings on disk, despite the `...W` API calls.

**Singleplayer quality values are clamped.** Setting the five quality keys in
`ACBrotherhood.ini` one step above the in-game maximum and relaunching results in
the game rewriting them back down (6->5, 3->2, 5->4, 4->3, 5->4). The INI is
0-indexed while the menu displays 1-based, so menu "6" is `=5` in the file. The
resulting ceilings are:

```
EnvironmentQuality 5   TextureQuality 2   ShadowQuality 4
ReflectionQuality  3   CharacterQuality 4
```

**This test says nothing about multiplayer** — see the next section. The earlier
conclusion here, "the menu ceiling is the engine ceiling, there is no hidden
visual headroom", was drawn from the wrong file.

### There is a THIRD INI — and the key naming is not what it looks like

```
<game>\ACBrotherhoodMP.ini        <- multiplayer [Graphics]
```

Same filename as the Saved Games one, different directory, different contents —
the Saved Games copy holds key bindings, this one holds graphics. It uses the
`Options*` key names recovered from string analysis below, which were assumed to
live in the Saved Games file and do not:

```
[Graphics]
DisplayWidth=2560          MultiSampleType=8
DisplayHeight=1600         Brightness=50
RefreshRate=60
OptionsPostFX=2            OptionsShadowQuality=2
OptionsTextureQuality=2    OptionsReflectionQuality=2
OptionsCharacterQuality=2
```

As shipped, **every quality key sits at 2** — the top of a three-step
Low/Medium/High menu, while the bare-named keys in `ACBrotherhood.ini` already
sit at 5, 4, 3 and 4. So one of these files is holding multiplayer down and the
other is not, and **which file multiplayer honours is unresolved.**

#### Do not resolve it by assuming the naming splits by executable

It does not. Searched as UTF-16 (the INI is read through
`GetPrivateProfileStringW`, so an ASCII search misses every key name — which is
why the key list below was short):

| string | `ACBMP.exe` | `ACBSP.exe` |
|---|---|---|
| `ACBrotherhoodMP.ini` | 1 | **0** |
| `ACBrotherhood.ini` | 3 | 2 |
| `OptionsShadowQuality`, `OptionsPostFX`, `OptionsCurrentResolution` | 1 each | 1 each |
| bare `ShadowQuality`, `EnvironmentQuality` | 2 each | 2 each |
| `GraphicsModified` | 1 | 0 |

Both executables carry **both** naming conventions, so `Options*` is not a
multiplayer dialect. And the multiplayer binary names *both* graphics files,
which is consistent with the observation that `ACBrotherhood.ini` was rewritten
during a session where the only game process running was `ACBMP.exe`.

The names cluster into three tables, which is the more useful structure:

```
30908020..30908404  OptionsSelectedPad OptionsPostFX OptionsCharacterQuality
                    OptionsReflectionQuality OptionsShadowQuality
                    OptionsTextureQuality OptionsEnvironmentQuality
                    OptionsVSync OptionsCurrentMSAAMode OptionsCurrentResolution

30925996..30926348  GraphicsModified PostFX CharacterQuality ReflectionQuality
                    ShadowQuality TextureQuality EnvironmentQuality VSync
                    SupportedMSAAModes CurrentMSAAMode SupportedResolutions
                    CurrentResolution

32094172..32094376  MultiSampleType RefreshRate DisplayHeight DisplayWidth
                    MonitorDesc AdapterDeviceID AdapterVendorID  + "Graphics"
```

The third is plainly the `[Graphics]` section header and its keys. The second
contains `SupportedMSAAModes` and `GraphicsModified`, which **cannot** be INI
keys — so that table is at least partly the runtime options object's property
names, and the bare names appearing in a file do not by themselves prove the
file is read.

**No anisotropic-filtering key exists in either binary** — zero hits for
`Anisotropic` in any encoding. The game has no AF setting at all, so forcing it
in the display driver is the only route, and it is likely the single largest
untapped fidelity win on ground and wall textures.

#### The experiment, and its answer: no headroom anywhere

`ACBMP.exe` rewrites `Saved Games\ACBrotherhood.ini` and leaves **both** MP-named
files untouched. The game-directory file was a real discovery and is never read.

Every key was then armed at 9 and the game launched. It wrote back:

```
TextureQuality  9 -> 2      EnvironmentQuality 9 -> 5
ShadowQuality   9 -> 4      ReflectionQuality  9 -> 3
CharacterQuality 9 -> 4     MultiSampleType    9 -> 8
PostFX          9 -> 1
```

**Every key clamped to the value it already held** — which looked conclusive and
was not, because every value armed was ABOVE the ceiling and clamping an
out-of-range value is indistinguishable from ignoring the file. Two later runs
settled it properly, in opposite directions:

```
armed ShadowQuality=1  ->  file came back 4     read as "the INI is an output"
                           WRONG: nobody checked the menu MINIMUM, so 1 was
                           also out of range and this was another rejection

armed ShadowQuality=3  ->  menu displays 4, file keeps 3 across a launch
                           The INI is READ. In-range values persist.
armed Texture=3, 4     ->  menu displays 4, then 5
                           Out-of-range values are read and DISPLAYED, then
                           CLAMPED when the game writes: 6->5, 4->2, 5->4
```

So the model is **read and apply at startup, clamp on write**. The ceiling is
exceedable per session and not persistently, and re-arming immediately before
each launch is what makes it stick — a thing the launcher is positioned to do.

**Unverified, and the distinction matters:** whether an out-of-range value renders
anything differently. Displaying a number and sampling at it are separate claims,
and both were collapsed into one more than once during this. Resident is not
sampled either, which is the same error from the asset side.

`ReflectionQuality` and `PostFX` are **enums, not numeric ranges** — the menu
reads `HIGH` and `ON`. Their ceilings of 3 and 1 are enum indices, so "push it one
past the maximum" is not a meaningful experiment for those two.

**`RefreshRate=240` IS honoured.** The options screen reports `2560x1600, 240Hz`
— the engine stating its own mode, which is stronger evidence than the file
agreeing with itself. An earlier line here calling it merely re-emitted is
superseded.

The +1 mapping is confirmed across the whole set rather than inferred from one
key: menu 6/3/5/5 against file 5/2/4/4.

Two method notes, each of which cost a run:

- A bare `ACBMP.exe` launch exits immediately with **code 41** and writes nothing.
  It needs `/onlineUser` and `/onlinePassword` to reach the point where it writes
  its config. Without them the run looks exactly like "the keys are inert" — a
  false negative arriving through a different door than the one the verifier
  guards.
- `tools/acb-graphics.ps1 -Verify` checks whether the file was **rewritten** before
  believing any value. Unchanged means the run proves nothing; a dropped key means
  inert; a reverted value means clamped; a surviving value means honoured. Without
  that distinction "still 9" and "never read" are the same observation.

Two smaller things visible in the same file: `RefreshRate` was **60** on a
240 Hz panel, and `MultiSampleType` is MSAA and is not a quality-menu entry, so
neither is subject to whatever the menu clamps.

**66 switches are registered, not the 21 listed below** — each referenced once
from `.text` at a regular 0x3c stride with its own handler. Memory-residency
measurements against an invented control switch (noise floor 0.2 MB) put
`/skipmips:off /skipmipscharacter:off /skipmipsenvironment:off` at +108.6 MB and
`/generateatlasmipmaps:on` at +111.5 MB — close enough to be the same effect
counted twice. That proves the switches do something; it does **not** prove the
image improves. Nobody has compared frames.

**Key bindings are fully open**, by contrast — `ACBrotherhoodMP.ini` holds
complete scancode bindings for `[Keyboard]`, `[KeyboardAlt]`, `[KeyboardMouse2]`
and `[KeyboardMouse5]`, and these are not clamped.

**Controller selection** is `[Input] SelectedInput=` in `ACBrotherhood.ini`. A
`[DualSense Wireless Controller]` profile already exists in the file
(VendorID=1356, ProductID=3302), so the game recognises the pad — but if
`SelectedInput` names a keyboard profile, the controller will not be used.

## INI keys recovered from string analysis

### `[Graphics]`

```
DisplayWidth      DisplayHeight     RefreshRate
MultiSampleType   AdapterDeviceID   AdapterVendorID   MonitorDesc
```

`MultiSampleType` is the MSAA level.

### Quality options

```
OptionsPostFX             OptionsTextureQuality
OptionsShadowQuality      OptionsReflectionQuality
OptionsCharacterQuality   Brightness
OptionsSelectedPad
```

These live in `<game>\ACBrotherhoodMP.ini`, **not** in the Saved Games file —
see above. They map to the multiplayer options menu, which offers three steps,
and whether they clamp at 2 has not been tested.

### `[Input]` / `[Player]` / `[Startup]`

```
SelectedInput   LastUsedProfile   lKeyboard   isAZERTY
HighProfileToggle   MouseWheelHighProfileToggle
ProductID   VendorID
```

## Command-line switches

Recovered from the argument table in `.rdata`. `onlineUser` / `onlinePassword`
are in this same list, which confirms the table is genuine — those two are known
to work.

```
fullscreen   msaa      lightmode   shadows    postfx    brightness
skipmips     skipmipsenvironment   skipmipscharacter   generateatlasmipmaps
preloadshaders   compresstextures   usestrips   noconsole   nofogofwar
gamemode     startupmission        missionroot         mapmenu
onlineKey    onlinePassword        onlineUser          userindex
```

The value vocabulary sits just before the table, at `.rdata` offset 30221980:

```
off  on  force  default  normal  full        <- general
8x  6x  4x  2x  none                         <- msaa only
```

The MSAA half is confirmed by the enum `Multisample_8x` .. `Multisample_None`
alongside `DisplayOptions::MultisampleType`. So **`/msaa:full` is not a value the
game accepts** — the launcher passed it and it did nothing. `/msaa:8x` is the
switch.

`/lightmode` is worth avoiding entirely: `DisplayOptions::LightingMode`
enumerates `NormalLighting | DefaultLight | FullBright`, so `full` most likely
selects FullBright — a flat debug view with the lighting removed. The launcher no
longer passes it.

No `windowed` or `borderless` switch exists — hence the launcher applying the
window style via Win32 after launch instead.

## PlayStation button glyphs are already in the PC build

`multi/DataPC_extra.forge` ships **both** glyph sets as a matched pair:

```
Binding_360_DiffuseMapDesc      <- Xbox prompts (what the game uses)
Binding_PS3_DiffuseMapDesc      <- PlayStation prompts, present but unused
Tips_Hud_Extend_360_MapDesc     /  Tips_Hud_Extend_PS3_MapDesc
Tips_CrossAir_360_MapDesc       /  tips_crossair_PS3_MapDesc
```

The PC release never selects the PS3 variants, but the textures are there. So
PlayStation prompts are a **texture swap, not a code change** — copy the PS3
texture into the slot the game requests, or find the selector that chooses
between them.

### WORKING RECIPE (verified 29 Aug 2026)

The controller diagram now renders as a PlayStation DualShock in-game. Method:

1. Unpack `DataPC_extra.forge`, then unpack **both**
   `1000_-_Binding_360_DiffuseMapDesc.data` and
   `1001_-_Binding_PS3_DiffuseMapDesc.data`.
   Each yields a `TextureMapSpec` (208 B) and a `TextureMap` (262,295 B) --
   identical sizes, both 512x512 `BC2_UNORM`.
2. Copy the **PS3 `TextureMap`** over the **360 `TextureMap`**.
3. **Critical:** patch the 4-byte File ID at **offset 2** back to the 360's own
   value. The IDs are the only header difference:
   - 360: `af e3 3f 1d` = `0x1D3FE3AF` (490726319)
   - PS3: `79 e3 3f 1d` = `0x1D3FE379` (490726265)
   Without this the game cannot bind the texture and draws a flat grey block.
4. Repack the inner `.data`, then repack the forge. **Close the game first** --
   it holds the forge open and Repack fails silently otherwise.

Two earlier attempts failed and are worth recording:
- Swapping the whole `.data` container: different compressed sizes, corrupted
  the resource ("Unable to read beyond the end of the stream" on repack).
- Swapping the `TextureMap` alone: carried the PS3 File ID, so the texture
  would not bind and rendered grey.

**Scope:** `Binding_360` drives the CONTROLLER LAYOUT diagram only. Footer
prompt icons come from a different atlas and remain Xbox.

**`Binding_PS3` is the only genuine PlayStation artwork in the PC build.** All
47 forge archives were swept for `*_PS3*` resources and every candidate byte-
compared against its 360 counterpart:

| pair | differing bytes | verdict |
|---|---|---|
| `Binding_360` / `Binding_PS3` | 64,137 | genuinely different art |
| `Tips_Hud_Extend_360` / `_PS3` | 28, all within first 198 B | identical payload |
| `Tips_CrossAir_360` / `_PS3` | 26, all within first 196 B | identical payload |

The two `Tips_*` pairs are the same image carrying different resource IDs --
console build-pipeline duplicates, not alternate artwork. Swapping them changes
nothing on screen. Everything else matching "PS3" across the archives is
`PC_X360_PS3`, i.e. shared multi-platform art (walls, water, horses).

Changing the footer prompt icons would therefore mean *authoring* PlayStation
glyphs and compositing them into whichever atlas draws them -- there is no
shipped source to copy.

Context: a DualSense reaches the game through DS4Windows + ViGEm as a virtual
Xbox 360 pad, so the game legitimately believes it is an Xbox controller and
shows `Binding_360`. Swapping the texture is what makes the prompts match the
hardware.

## TextureMap layout (solved)

Unpacking a `.data` yields a `.TextureMap`. The layout is the same in every
archive tested:

```
  0 .. 89     header
 90 .. 90+N   raw BC blocks, exactly N bytes, all mip levels largest-first
 then         61-byte trailer: format, width, height, mip count, repeated
```

Header fields, little-endian u32:

| offset | meaning |
|---|---|
| 2 | File ID |
| 10 / 14 | width / height |
| 22 | format: `2` = BC1/DXT1, `4` = BC2/DXT3 |
| 30 | sRGB flag |
| 34 | mip count |
| 84 | marker `0x1323` |
| 86 | payload size N |
| 90 | payload begins |

**The 151-byte trap.** The trailer is always 61 bytes, so
`filesize - payloadsize` is always `151` — which looks exactly like a header
length and is not one. Reading from 151 shifts every block by 61 bytes. On BC2
UI art the result still resembles the original closely enough to pass casual
inspection; on a detailed BC1 character texture it is pure noise. That
mismatch is what makes the error hard to spot: the *wrong* offset appears to
work on the easy file and fails on the hard one.

**Verified.** `BarberUp_DiffuseMap` was exported to DDS by AnvilToolkit and
compared against the raw file: the DDS payload is byte-for-byte identical to
`TextureMap[90:]`, all 699,064 bytes, 100% match. Recolouring the file at
offset 90 and recolouring the DDS give identical results — same measured tonal
range, same block statistics.

**Consequence:** textures are plain BC blocks with no compression and no
swizzle, in `DataPC.forge` as well as `DataPC_extra.forge`. They can be edited
in place and repacked, with no DDS round-trip and no import step.

## Save files: where challenge progress must live, and why it is still shut

**Everything outside the container is ruled out.** Swept and verified empty:
the registry footprint (no binary value anywhere above 4 bytes; the `ADVAPI32`
imports serve install path, language and a hotfix check), Ubisoft Connect cloud
saves, Steam Cloud under all three `userdata` IDs, the `ProgramData` folder
(exists, empty), and both the AppData and Documents INI stubs (211 bytes each).
The decisive test was sweeping every tree for files written in the window
bracketing a `.SAV` write: the only game-owned artifact in it was the `.SAV`.

So challenge progress is **not reachable outside the container**. That closes
the "maybe it is in the registry" line rather than leaving it an untested maybe.

### The target

`ACBROTHERHOODSAVEGAME0.SAV` chunk 2 declares **1,985 compressed -> 32,768
uncompressed** at `0x0ed`. A fixed 32 KB state block in the only game file
written during play.

| file | chunk offsets (compressed -> uncompressed) |
|---|---|
| `OPTIONS` | `0x010` 165->289, `0x0e1` 627->1306, `0x380` 91->162, `0x40f` 728->6135 |
| `.SAV` | `0x010` 177->284, `0x0ed` **1985->32768** |

The `OPTIONS` offsets `0x010/0x0e1/0x380/0x40f` are decimal 16/225/896/1039 -
the same values derived independently above. Two derivations agreeing.

Strings verified present in `ACBMP.exe`, worth grepping the moment a chunk
inflates: `PlayerProgressionSaveData`,
`SnapshotPlayerProgressionSaveDataDelta`, `ChallengeRewardManager`,
`UnlockConditionChallenge`, `ChallengeDifficulty_Basic/Advanced/Hard/Elite`,
`OnlineEventValidateChallengeStarted/Finished`. Also
`SaveGameAction_SaveProfileOptions` / `LoadProfileOptions`, which is what makes
`OPTIONS` the profile blob.

### SOLVED - the save inflates

Use **`CompressedFileData`**, not `Manager.Decompress`.
`AnvilToolkit.FileTypes.AnvilNext.Containers.CompressedFileData` has
`ctor(BinaryReader br, Game Version, bool metaData)`. Seek the reader to a chunk
header offset, construct it, read the `Data` property. Verified twice,
independently:

| chunk | declared | Data | reader ends |
|---|---|---|---|
| `.SAV` `0x010` | 284 | 284 | 221 |
| `.SAV` `0x0ed` | **252,401** | 252,401 | 21,124 = EOF exactly |

**The header sizes are per-BLOCK, not per-chunk.** The `32768` at `M+20` is the
first *block's* uncompressed size; the chunk is multi-block and inflates to
252,401. `CompressedFileData` exposes `BlockInfoData` - there is a block table
that hand-parsing does not account for. This is why offsets that were
arithmetically correct (chunk 0's payload ending exactly where chunk 1's header
begins) still produced garbage: the payload is not one LZO stream.

### Four things that waste a day if you meet them cold

1. **`Manager.InitializeAll()` hangs.** Not slow - it does not return. Do not
   call it.
2. **`Manager` must be constructed properly.** It has `ctor(bool initialize)`,
   and `LZO` has an instance field `byte[] Mem` that the decompressor writes
   through. `GetUninitializedObject` leaves it null and you get an access
   violation inside `lzo1x_decompress`.
3. **LZO1X has no bounds checking**, so every wrong offset dies with
   `0xC0000005` rather than an error, killing the process. Offset sweeping is
   useless as a search strategy: "wrong by 4 bytes" and "wrong by 4000" give an
   identical fatal crash.
4. **Check apparent plaintext against the raw bytes.** `DataBlock.Read` at
   offset 0 returns 197 bytes that are byte-identical to `raw[12:209]` - raw
   passthrough - and they contain the readable string `Options`, which looks
   exactly like a decompression success. `Options` is in the raw file too.

`GetCompressionAlgorithm` takes **four** parameters:
`(int AlgoIndex, int AlgoVersion, Game Version, bool Lock)`.

### What is inflated, and what is still unknown

The 252,401-byte payload is **hash-keyed binary**: 56% zero bytes and only 8
ASCII runs of five characters or more in the whole file, none of them field
names. Field names are hashed, so the challenge flags are **not greppable**.
Inflating the file and locating the flags are different results, and only the
first is done.

Schema types the toolkit already has, in
`AnvilToolkit.FileTypes.AnvilNext.Schema.BaseTypes`:
`AccomplishmentManagerSavegameData`, `PlayerOptionsSaveData`, `SaveData`,
`SaveGame` - each with `ctor(BinaryReader br, uint hash, bool _IsSaveGame)`.

**Cheapest way forward is a differential, not schema decoding.** Now that
inflation works: capture an inflated baseline, play one challenge step, exit
cleanly, re-inflate, and diff 252 KB against 252 KB. That localises the flags
without decoding anything.

### Unclaimed lead, for whoever owns netcode

`OnlineEventValidateChallengeStarted` / `Finished` implies challenge validation
crosses the online-event path, even though the challenges *screen* issues no
requests - those are different things, so this does not contradict the "zero
server requests" finding. `QuazalWV/RMC/Services/PersistentStoreService/` exists
in the tree with only `GetItem` implemented.

## The OPTIONS save container - structure solved, codec not

`Saved Games/.../SAVES/OPTIONS` is 1,754 bytes and holds **four** compressed
blocks. The block layout is now fully mapped:

```
  M+0   magic  33 aa fb 57 99 fa 04 10
  M+8   constant  01 00 02 00        (131073)
  M+12  constant  80 00 00 01        (16777344)
  M+16  compressed size   u32
  M+20  uncompressed size u32
  M+24  hash / checksum   u32
  M+28  payload begins
```

| block | magic at | payload at | compressed | uncompressed | ratio |
|---|---|---|---|---|---|
| 0 | 16 | 44 | 165 | 289 | 57% |
| 1 | 225 | 253 | 627 | 1,306 | 48% |
| 2 | 896 | 924 | 91 | 162 | 56% |
| 3 | 1,039 | 1,067 | 687 | 6,117 | **11%** |

Block 3 ends at byte 1,754, exactly the file length, which confirms the payload
offset. Blocks are separated by 16 to 24 bytes of inter-block record.

**The codec is not any standard one.** Every combination of payload offset
(M+20 to M+44) and length (size, ±4, ±8, ±12) was tried against:

- LZ4 block, zlib, raw deflate, gzip, bz2
- LZMA container, LZMA1 raw, LZMA2 raw (dictionary sizes 64 KB to 64 MB)
- LZO1X-1 (implemented from scratch for this, since no binding was installed)

None produced the declared uncompressed size at any offset. Combined with the
`.cxb` result - roughly 200 LZSS parameter combinations each decoding exactly 33
correct bytes before failing - and AnvilToolkit symbols naming
`GetDecompressionDictionary` and `tag_dictionary.tdct`, the evidence points to a
**dictionary-based scheme whose back-references resolve into a table not present
in the file**. No amount of codec guessing will succeed without that dictionary,
and no dictionary file was found in either the game or AnvilToolkit.

### SOLVED - by calling AnvilToolkit instead of reimplementing it

The codec guess was right and the implementation was wrong.
`Manager.GetCompressionAlgorithm(1, 2, Game.Brotherhood)` returns **LZO1X**,
which is what the hand-written decompressor above was attempting. The block
header even carries the parameters: `M+8` is `01 00 02 00`, which as two u16s
is exactly `Algo=1, AlgoVersion=2`, the first two arguments of
`Manager.Decompress(Algo, AlgoVersion, CData, UncompressedSize, Game)`.

AnvilToolkit is .NET 9, so with the .NET SDK installed a small reflection host
drives it directly. `tools/anvil-unpack` does this and **unpacks `.data`
containers with no GUI at all** - 64 persona containers in one batch, 0
failures.

Two things the GUI does at startup that a host must do itself, each of which
costs an hour if you do not know it:

1. **`HashedData.CheckStrings()` must be called.** It populates the ID-to-name
   table. Without it the unpack throws `NullReferenceException` inside
   `GetHashedString` *while writing files*, reports success, and leaves an
   empty folder.
2. **Do not pre-create the output folder.** `DataFile` treats an existing
   folder as already unpacked and skips.

Resource extensions still come out as numeric type IDs, since the extension
table is not reachable from outside the app. The two that matter are mapped in
the tool - `2729961751` = `TextureMap`, `3608045168` = `TextureSet` - and
anything unknown keeps its numeric extension rather than being given a wrong
one.

The same `Manager.Decompress` should open `SAVES/OPTIONS`, which is the route
to challenge progress. Not yet attempted: feeding it a bad offset crashes the
native LZO with an access violation that kills the process, so the block
boundaries need to be exact rather than swept.

## One codec gates almost everything left

The same container magic `33 aa fb 57 99 fa 04 10` appears in three different
kinds of file:

| file | size | magic at |
|---|---|---|
| `multi/.../228_-_BarberUp_Set.data` | 1,275,022 | 4, 169 |
| `Saved Games/.../SAVES/OPTIONS` | 1,754 | 16, 225, 896, 1039 |
| `Saved Games/.../SAVES/ACBROTHERHOODSAVEGAME0.SAV` | 21,124 | 16, 237 |

So archives and **save files** share one format. That corrects an earlier claim
in this file and the README: *"there is no local save file, so it never
persists"* was wrong. There is local state, and `OPTIONS` is rewritten on exit
(observed at 13:38 immediately after a multiplayer session).

Whether challenge progress lives in `OPTIONS` is **not verified** - it may hold
only settings. But the possibility can no longer be dismissed on the grounds
that nothing is stored locally.

This makes the container codec the single highest-value unsolved problem, since
one solution would unlock three separate things:

1. unpacking resources without the AnvilToolkit GUI, which is currently the
   only manual step in the texture pipeline,
2. reading and possibly editing save state, which is the only route to the
   challenge unlocks,
3. very likely the `.cxb` gamesettings payload too, which is the route to
   ability tuning and map rotation.

`OPTIONS` at 1,754 bytes with four blocks is a far better specimen to attack
than a 1.3 MB archive. It also changes when settings change, which allows a
differential attack: alter one option in the menu, diff the file, and the
region that moved is the region that encodes it.

## The `.data` container is compressed (unsolved)

Editing a texture needs it unpacked out of its `.data` first, and that step
still requires AnvilToolkit. The container is genuinely compressed — the
uncompressed `TextureMap` does not appear anywhere inside it (`228`'s `.data`
is 1,327,182 bytes against 1,573,438 bytes of resources, ~84%).

What is known:

- `33 aa fb 57` appears as a magic at offsets 4 and 67, followed both times by
  the same 8 bytes `99 fa 04 10 01 00 02 00`.
- A table of `00 80 xx xx` pairs begins around offset 80.
- The first block is 49 bytes and contains readable text — `BarberUp_ Set `
  plus what look like resource IDs — so it is a **name/index table**, not
  payload. That rules out the reading of `0x8000` as an uncompressed chunk
  size, which was the obvious first guess and is wrong.
- AnvilToolkit ships **`K4os.Compression.LZ4`**, `EasyCompressor.LZMA` and
  `LZMA-SDK`, so the codec is one of those. Plain LZ4 block decoding fails at
  every table and data offset swept.
- Literal runs survive visibly in the compressed bytes (`Diffu seMap`, with a
  control byte every ~8 characters), which is an LZ77-family signature and
  argues against LZMA for that region.

Anyone continuing should start from the 49-byte index block, since it is small
and its plaintext is partly known.

## Texture formats across the multiplayer roster

The `format` field at offset 22 takes **four** values, not the two the Barber
alone suggested. Block size implied by each declared payload identifies them:

| code | bytes/block | format | diffuse textures |
|---|---|---|---|
| 2 | 8 | BC1 / DXT1 | 36 |
| 3 | 8 | BC1 variant (DXT1a) | 16 |
| 4 | 16 | BC2 / DXT3 | 16 |
| 5 | 16 | BC3 / DXT5 | 1 |

Codes 2 and 3 can both be handled as BC1 provided endpoint-order mode is
**preserved rather than assumed**; 4 and 5 keep colour in the second half of the
block and always use the 4-colour interpretation, and their alpha halves are
left untouched.

This was found only by running the whole roster. A single persona is not a
large enough sample to conclude a format is universal - the same shape of error
as assuming a 21-entry switch list was complete when the binary registers 66.

Two failure modes worth carrying elsewhere:

- Mapping the format codes was not sufficient on its own. A **second, separate**
  lookup - the human-readable format name - still raised `KeyError` for the
  newly supported codes, so the fix appeared not to work.
- In PowerShell, `$ErrorActionPreference = 'Stop'` turns any **stderr output
  from a native command** into a terminating error. One bad input therefore
  killed a 69-item batch after 7. Per-item exit codes with the loop continuing
  is the fix, and this applies to any batch driving an external tool.

## Recolouring personas

`tools/recolour_texture.py` recolours a texture by transforming only the two
RGB565 **endpoints** of each block and leaving the 2-bit index bits untouched.
Every pixel changes colour while all detail, shading and edges survive exactly
— BC interpolation does the work.

Three things it has to get right, each found by testing:

1. **Endpoint order is the BC1 mode flag.** `c0 > c1` means 4 opaque colours;
   `c0 <= c1` means 3 colours plus transparent. Recolouring can reverse the
   order and silently flip a block's mode. The tool detects this, swaps the
   endpoints back and remaps the index bits (`0<->1`, and `2<->3` in 4-colour
   mode). On the Barber this affected 22,110 of 87,383 blocks when reading at
   the wrong offset, and 67 at the right one.
2. **Nudge blue, not the packed value.** When both endpoints map to the same
   colour, one must be nudged to preserve the mode. Decrementing the packed
   u16 borrows out of the blue field and wraps blue to maximum, painting bright
   blue speckle wherever a scheme has dark, blue-free shadows. Nudge the low 5
   bits only.
3. **Every mip level, not just the top one** — otherwise the character changes
   colour as the camera pulls away.

Personas are **atlases**: clothing, straps, boots and props share one sheet.
`--grid` renders a labelled A1..H8 overlay and `--keep` holds named cells at
their original colours.

The Barber is **persona ID15**, deduced from resource adjacency
(`214 barber_head`, `215 AC2MP_Weapon_ID15_RIGGED`, `228 BarberUp_Set`,
`229 BarberBottom_Set`, `231 AC2MP_ID15_UPCustom_Set`). His weapon is a
separate resource, so recolouring the outfit atlas cannot affect it.

## The game refuses a second instance (tested)

Bots have to be players, so the whole bot approach assumed two clients could run
on one machine. **They cannot.**

Tested directly: one instance launches fine and is genuinely live (pid, ~500 MB
working set, real window handle titled "Assassin's Creed Brotherhood"). A second
instance launched while the first was up **exited with code 0** — a clean,
deliberate exit, not a crash or a resource failure.

`ACBMP.exe` imports `CreateMutexA` and neither `OpenMutex` variant, which is the
signature of the standard guard: create a named mutex, check for
`ERROR_ALREADY_EXISTS`, exit if found. The name is not a plain string in the
binary.

**Consequences.** `tools/warm-body.ps1` works as far as it can be tested — it
provisions accounts, launches a client with `/onlineUser` and `/onlinePassword`,
and drives it — but it can only ever run **one** bot per Windows session. The
routes to more than one, roughly in order of effort:

| route | notes |
|---|---|
| Second machine | Definitely works. Needs a second copy of the game. |
| Sandboxie or similar | Isolates the object namespace; the usual answer for this. |
| Second Windows user session | A `Local\` mutex is per-session, so this should work without extra software. |
| Close the mutex handle | Enumerate handles in the running process and close the mutant. Works, but needs a handle tool or a `NtQuerySystemInformation` walker. |
| VM | Heaviest, most reliable isolation. |

None of these is blocked by anything technical we have found; they are all
effort and setup. Nothing here involves DRM — this is a convenience guard on a
game the user owns, being used against their own private server.

## What this does *not* get you

Adding new UI (a colour picker), new abilities, or new gameplay behaviour still
requires patching compiled code and extending the P2P protocol. Nothing here
changes that. What it does give is a **configuration surface** reachable without
touching the binary at all.

## Suggested next steps

1. ~~Locate the written INI~~ — **done**, see above.
2. ~~Try quality keys above the menu maximum~~ — **done for singleplayer, they
   clamp. Not done for multiplayer**, whose keys live in a different file that
   was missed; `tools/acb-graphics.ps1 -Set Beyond` then `-Verify` settles it.
   This is the cheapest remaining fidelity question.
3. Inspect `multi\DefaultBindings.map` — it exists and is only 17 KB. Combined
   with the editable `[Keyboard*]` sections, this is the open surface for
   remapping.
4. For genuine code work, load `ACBMP.exe` into Ghidra (free) and start at the
   `GetPrivateProfileStringW` imports; the call sites name every INI key the
   game reads, which is a far better index than guessing from strings.
