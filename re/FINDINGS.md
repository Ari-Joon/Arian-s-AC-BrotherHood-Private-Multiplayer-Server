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
| `ACBrotherhoodMP.ini` | multiplayer settings (UTF-16, matches the `...W` API calls) |
| `ACBrotherhood.ini` | singleplayer settings |
| `VertexShaderConfig.ini` | shader configuration |
| `PixelShaderConfig.ini` | shader configuration |
| `LightingShaderConfig.ini` | shader configuration |
| `multi\DefaultBindings.map` | key bindings — **this file exists on disk**, 17 KB |

**Location found** — the Windows *Saved Games* known folder, which is why no
`Documents` or `My Games` string appears in the binary:

```
%USERPROFILE%\Saved Games\Assassin's Creed Brotherhood\
    ACBrotherhood.ini      <- [Graphics] + input profiles (shared by SP and MP)
    ACBrotherhoodMP.ini    <- multiplayer key bindings only
    SAVES\
```

The game writes these **on exit**, not when a setting changes.

**Quality values are clamped.** Setting the five quality keys one step above the
in-game maximum and relaunching results in the game rewriting them back down
(6->5, 3->2, 5->4, 4->3, 5->4). The menu ceiling is the engine ceiling; there is
no hidden visual headroom here. The INI is 0-indexed while the menu displays
1-based, so menu "6" is `=5` in the file.

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

These map to the in-game menu entries and are **all clamped** — see above.
Tested: raising them beyond the menu maximum does not stick.

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

A nearby value vocabulary suggests the accepted arguments:
`off | force | default | normal | full | none`

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

## What this does *not* get you

Adding new UI (a colour picker), new abilities, or new gameplay behaviour still
requires patching compiled code and extending the P2P protocol. Nothing here
changes that. What it does give is a **configuration surface** reachable without
touching the binary at all.

## Suggested next steps

1. ~~Locate the written INI~~ — **done**, see above.
2. ~~Try quality keys above the menu maximum~~ — **done, they clamp.**
3. Inspect `multi\DefaultBindings.map` — it exists and is only 17 KB. Combined
   with the editable `[Keyboard*]` sections, this is the open surface for
   remapping.
4. For genuine code work, load `ACBMP.exe` into Ghidra (free) and start at the
   `GetPrivateProfileStringW` imports; the call sites name every INI key the
   game reads, which is a far better index than guessing from strings.
