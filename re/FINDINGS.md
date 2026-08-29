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

Blocked only on AnvilToolkit's **Repack**, which has not yet succeeded. Repack
is currently the single blocker for three separate mods: persona recolouring,
weapon-model swaps, and these glyphs.

Context: a DualSense reaches the game through DS4Windows + ViGEm as a virtual
Xbox 360 pad, so the game legitimately believes it is an Xbox controller and
shows `Binding_360`. Swapping the texture is what makes the prompts match the
hardware.

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
