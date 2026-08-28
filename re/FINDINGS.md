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

None of the INIs ship with the game; it creates them on demand. To find where,
change a setting in-game and then search for a newly written `.ini`.

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

**`OptionsReflectionQuality` and `OptionsCharacterQuality` are not exposed in
the in-game options menu.** These are the most promising leads for raising
visual fidelity beyond what the UI allows.

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

## What this does *not* get you

Adding new UI (a colour picker), new abilities, or new gameplay behaviour still
requires patching compiled code and extending the P2P protocol. Nothing here
changes that. What it does give is a **configuration surface** reachable without
touching the binary at all.

## Suggested next steps

1. Change a graphics setting in-game, quit, then locate the written
   `ACBrotherhoodMP.ini`. That confirms the path and reveals real key/value
   formatting.
2. Try the undocumented quality keys (`OptionsReflectionQuality`,
   `OptionsCharacterQuality`) at higher values than the menu allows.
3. Inspect `multi\DefaultBindings.map` — it exists and is only 17 KB.
4. For genuine code work, load `ACBMP.exe` into Ghidra (free) and start at the
   `GetPrivateProfileStringW` imports; the call sites name every INI key the
   game reads, which is a far better index than guessing from strings.
