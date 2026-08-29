# Bots — what works, what doesn't, and why

Written after a full session of testing against a live private server. Every
claim here is either marked **verified** (observed directly, more than once) or
**unverified**. Several things in an earlier draft were wrong and are corrected
below with the reason, because a wrong claim recorded confidently costs more
time than no claim at all.

---

## The short version

A bot can **log in, appear online, and sit in a lobby**. It cannot **play a
match** on the same PC as the human player, and that is an architectural limit
rather than a bug.

Everything the bot does beyond logging in currently requires a human driving
its window.

---

## Verified working

### Several game clients on one PC

`ACBMP.exe` holds a named semaphore:

```
\Sessions\<n>\BaseNamedObjects\scimitar_semaphore
```

Scimitar is Ubisoft's codename for the Anvil engine. A second client finds it
already exists and **exits after ~5 seconds with code 0** — a clean exit, which
is why it reads as "the game refuses to start" rather than an error.

Releasing that handle in the running client lets the next one start.
`tools/release-guard` does this; `tools/warm-body.ps1` calls it between
launches. **Four clients verified concurrent.** Nothing on disk is patched, and
the handle must be released again after each launch because every new client
creates the semaphore itself.

Three wrong diagnoses preceded this, all disproved by testing:

| Theory | How it was disproved |
|---|---|
| Port collision at startup | Bound 12000/12001 and launched a **single** client — it started fine |
| Detection by executable name | A renamed copy is refused identically |
| No named objects exist at all | Came from checking `CreateMutexA`/`CreateSemaphoreA` call sites for a name argument. The object is there; the name simply isn't a static string |

The lesson: **enumerate the running process, don't infer the mechanism from
imports.**

### PunkBuster ejects extra clients

```
PunkBuster kicked player 'Bot1'
RESTRICTION: Service Communication Failure: PnkBstrA.exe
```

`PnkBstrA` was never installed on this machine — only `PnkBstrB`. Running the
shipped `pbsvc.exe` installed it, but **the repair did not persist** and
reverted on its own.

Disabled client-side by renaming `PB\pbcl.dll` to `pbcl.dll.disabled`. Fully
reversible; Steam file verification also restores it. PunkBuster only ever
policed official Ubisoft servers, decommissioned in 2022, so on a private
server it protects nothing.

### Friend presence depends on launch order

`FriendsService` case 12 computes online status **at the moment the list is
requested**:

```csharp
friendClient = Global.Clients.Find(c => c.User.Pid == otherPid);
online = friendClient != null;
```

A client that connects *after* the human's friends list is fetched shows
**Offline permanently for that view**. Launch bots **before** the human client
and they show Online.

This accounted for hours of confusion and is the single most useful practical
finding here.

### Bots authenticate and hold a session

Verified repeatedly in the server log — a bot account authenticates, holds a
PRUDP session, and appears in the invite list as online. `Bot1` accumulated
several hundred log entries across a session.

---

## Verified NOT working

### Two clients cannot play a match on one PC

This is the wall. With two clients running, the UDP port set is **split between
them**:

```
pid 50260  (human)  UDP: 7917, 9100, 12001, 56053      <- no 12000
pid 26316  (bot)    UDP: 12000, 12001, 50764, 54063
```

Neither client ends up holding the full set it needs. The lobby works because
it is **server-mediated**; the match itself is **peer-to-peer over fixed
ports**, and there is one set of those per machine.

Symptoms, all consistent:

- Solo (one client only): **Play Now works**
- With a second client running: match load fails, client exits cleanly
- No Windows error event, no crash dump — it is not a fault

**A second Windows user account does not fix this.** It gives a separate
session, which solves the semaphore, but ports are machine-wide. Only a
separate network stack helps: a VM, or another PC.

### Bots do not act on their own

Corrected from an earlier draft, which claimed otherwise:

- **Auto-accepting invites was NOT observed working.** `tools/bot-autoaccept.ps1`
  exists and presses accept on a cycle, but every successful join in testing was
  the human accepting in the bot's window. The tool is untested, not proven.
- **Bots do not search for sessions autonomously.** `SearchSessions` entries do
  appear in the server log from bot accounts, but they coincided with a human
  driving that window. Attributing them to the bot was an inference from a log
  line, not an observation.

Both were reported as working before being verified. Treat them as unproven.

### Bots do not navigate menus

`tools/join-match.macro` ships uncalibrated. The keypresses to reach a lobby
cannot be derived without watching the menus, and no calibrated sequence exists.

---

## The behaviour engine

`tools/bot_vm.py` is a working behaviour VM — three difficulty tiers, patrol
routes, pursuit, and deliberate human tells. Over 60 simulated runs against a
33% random baseline:

| Tier | Accuracy | Sprints | Tells |
|---|---|---|---|
| assassin | 52% | 0% | 6% |
| hunter | 46% | 2% | 14% |
| brute | 39% | 6% | 27% |

**This is simulation only.** It has never driven a real client, because
perception is unsolved: `ScreenPerception` returns nothing rather than guessing,
since a bot that hallucinates targets is worse than one that stands still.

---

## Could bots work like singleplayer NPCs?

The idea: rather than bots being *players*, make them behave like the hunting
NPCs in singleplayer.

**Not reachable by the modding route this project uses.** Singleplayer AI is
compiled into `ACBMP.exe`, and multiplayer NPC crowds are civilians with no
hunting behaviour. Changing that means patching compiled game code, not editing
`.forge` archives — a different discipline entirely, and one nothing in this
repo touches.

Worth recording rather than dismissing: the maps already spawn NPC crowds, so
the bodies exist. What does not exist is any hook to give them pursuit
behaviour, and none was found in the `.cxb` game settings either.

---

## What would actually get playable bots

In increasing order of effort:

1. **A second PC.** Definitely works. Needs a second copy of the game.
2. **One VM per bot.** Own network stack, so the port collision goes away. The
   genuine risk is 3D acceleration — a 2010 DX9 title in a guest is plausible
   but unproven, and if it will not render the effort is wasted.
3. **Perception + menu macro**, so a bot plays rather than stands. Only worth
   building *after* one of the above, since a bot that cannot join a match has
   nothing to play.

---

## Testing the server with real people

The server side is in better shape than the bot side, and needs no bots to
exercise:

- Every player installs a virtual LAN (Radmin/ZeroTier/Tailscale) and joins one
  network
- Host sets `SecureServerAddress` to their virtual-LAN address
- Each client adds the host to `hosts` as `onlineconfigservice.ubi.com`
- Accounts via `tools/add-player.ps1`; friend each other so invites work

Real players on separate machines have their own port sets, so the limit
documented above does not apply to them. **This is the fastest route to
confirming the server actually works end to end**, and it needs friends rather
than engineering.

---

## Tools

| Tool | Status |
|---|---|
| `tools/release-guard` | **Verified** — several clients in one session |
| `tools/warm-body.ps1` | **Verified** for launching; menu macro uncalibrated |
| `tools/bot-autoaccept.ps1` | **Unverified** — never observed accepting an invite |
| `tools/bot_vm.py` | **Simulation only** — never driven a real client |
| `tools/join-match.macro` | **Uncalibrated** starting point |
| `tools/unthrottle` | **Works, but fixes nothing** - throttling was disproved as a cause |

---

## Why clients die: two things that are NOT the cause

Recorded because both looked convincing and both were wrong. A rejected
hypothesis written down is worth more than the hour it takes to re-test it.

### Not background throttling

The theory: Windows throttles background processes, so a bot behind another
window stops sending PRUDP keepalives and the server drops it. It fit the log
exactly - a PING ACK, silence, then `TIMEOUT` about 25 seconds later.

Tested directly. A bot was minimized (`SW_MINIMIZE`, confirmed with `IsIconic`,
confirmed not foreground) and left for four minutes, with and without power
throttling disabled via `SetProcessInformation`/`ProcessPowerThrottling`:

| Condition | Result |
|---|---|
| minimized, throttling untouched | survived 4 min |
| minimized, throttling disabled  | survived 4 min |

No difference, and the control did not die. **Background throttling does not
kill clients.** `tools/unthrottle` was built for this and is kept because
High priority for background bots is harmless, but it fixes nothing.

### `TIMEOUT` in the server log is an effect, not a cause

`[JubblyJoon] TIMEOUT` appears six times against `[Bot1] TIMEOUT` once. That is
the human client being closed normally. The server logs `TIMEOUT` when a client
stops answering - which is what a client that has already exited looks like.
Reading it as the reason a client died is backwards.

### The real requirement that was missed for an hour

**The server must actually be running.** `ACBRDV.exe` had stopped at 21:09 and
every test run after that was against nothing, producing both false survivals
and false deaths. Check before trusting any client result:

```powershell
Get-Process ACBRDV, ACBMP | Select-Object Name, Id, StartTime
```

The log's last-write time is the quickest tell - if it is not moving while a
client is connecting, the server is down.

## The port split, measured

Solo, one client holds the full fixed set:

```
pid 53612 (alone)   UDP: 7917, 12000, 12001, 61977
```

With a second client running it splits, and neither side holds what a match
needs. This is why the **lobby works but the match does not**: the lobby is
server-mediated, the match is peer-to-peer over those fixed ports.

Confirmed again in testing: loading a **private** lobby with a bot running
crashes at the loading screen. Same wall as Play Now, not a separate bug.

**No configuration route around it.** The game INI has 151 keys, all graphics
and input - no port, bind or network keys at all. The only port strings in
`ACBMP.exe` are UPnP (`NewExternalPort`, `NewInternalPort`,
`NewPortMappingDescr`), which map ports on the router rather than choose local
ones. A separate network stack - VM or second PC - remains the only fix.

### Practical rule

**Any bot running means no match can be loaded, private or public.** Close all
bots before playing. Bots are usable for lobby, presence and invite testing
only, until they live on their own network stack.

## A weakness in `warm-body.ps1`

It waits for a window handle before launching the next client. A window handle
appears at the splash screen, well before login completes, so clients can be
started while the previous one is still connecting and race for ports. If bots
behave inconsistently, launch spacing is the first thing to suspect.

---

## Aside: the `.cxb` game settings are now readable

Recorded here because it was found during bot work and is easy to lose.

`multi/Backups/gamesettings_test.data` uses the **same container format** as the
texture archives, so `tools/anvil-inflate` opens it. 28 chunks; the first
inflates to **93,684 bytes** — exactly the figure earlier notes recorded as
unreachable — and it is **plain XML**:

```xml
<AbilityManagerMulti memberName="AbilityManagerMulti">
  <m_AbilityReferenceList Array_Size="75">
    <AbilityDisguise><CooldownDuration value="60.0"/></AbilityDisguise>
    <AbilitySpeedBoost><CooldownDuration value="60.0"/><SpeedFactor value="1.2"/></AbilitySpeedBoost>
```

24 ability classes, 75 ability entries, with tunable `CooldownDuration` (48),
`Duration` (37), `Radius` (20), `SpeedFactor` (10), `Range` (8).

**This contradicts an earlier claim in the README** that ability tuning is
"locked behind the `.cxb` encoding". It is not, now that the container codec is
solved.

### The challenge gate is visible

Unlock conditions come in two shapes, and converting one to the other is a
mechanical edit:

```xml
CHALLENGE   classID="1475552278"  <UnlockConditionChallenge>
                                    <Handle propertyName="ChallengeRewardRef" objID="..."/>
                                    <Level value="2"/>
LEVEL       classID="1688405200"  <UnlockConditionLevel>
                                    <Level value="2"/>
```

Counts: **51 level-gated, 24 challenge-gated.** The 24 are the abilities locked
behind challenges. Every ability has `InitiallyHidden="false"`, so nothing is
hidden by flag — the gate is entirely the unlock condition.

### Two things not yet established

1. **Whether this file is live.** It exists only under `multi/Backups/`, and no
   forge in `multi/` contains a `gamesettings` or `abilitymanager` string. So
   this may be a stray copy rather than what the game reads. Until the live one
   is located, editing it changes nothing.
2. **Whether it can be written back.** The chunks inflate, but
   `anvil-unpack` FAILED on this container ("no output"), so the write path is
   unproven. Reading and writing are different problems.

### New abilities?

Partly. The 24 classes are implemented in `ACBMP.exe`, so a genuinely new
*mechanic* cannot be added by editing XML. But new **variants** of existing
classes look feasible — the list is an array of 75 references, and each entry
is a class plus parameters. A longer-lasting Smoke Bomb or a faster Speed Boost
is a parameter change, not new code.
