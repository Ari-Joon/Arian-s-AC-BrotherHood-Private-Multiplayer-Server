# Joining the server

For everyone **except** the host. You need your own legal copy of Assassin's
Creed: Brotherhood — no game files are distributed here.

## The short version

Install [Radmin VPN](https://www.radmin-vpn.com/) and join the host's network.
Then, from this repo:

```
powershell -ExecutionPolicy Bypass -File tools\client-setup.ps1 -HostIP 26.1.2.3 -User YourName -Password thepassword
```

That sets the hosts entry (elevating itself if needed), checks the host is
actually reachable, saves your account and launches the game. **Two minutes.**

The host gives you three things: the VPN network, your account name and its
password.

You do **not** need the upscaled textures to play — see the end of this file.

---

## The same thing, step by step

## 1. Get on the same network

The server binds the literal IP it advertises, so port-forwarding a public IP
does not work. Everyone joins one virtual LAN instead.

Install [Radmin VPN](https://www.radmin-vpn.com/), join the network the host
gives you, and check you can see their `26.x.x.x` address.

> ZeroTier or Tailscale work equally well. Everyone must be on the same one.

## 2. Point the game at the host

Add this to `C:\Windows\System32\drivers\etc\hosts` — needs an admin editor:

```
HOST.IP.HERE onlineconfigservice.ubi.com
```

`HOST.IP.HERE` is the host's Radmin address, not a public IP. Without this the
game talks to Ubisoft's decommissioned servers and simply fails to log in.

## 3. Get an account

Accounts live in the host's database, so **the host creates yours** and sends
you the name and password:

```
powershell -File tools\add-player.ps1 -Name YourName
```

The name is what other players see in game.

## 4. Play

```
powershell -STA -File tools\acb-settings.ps1
```

Pick display mode and quality, choose your account, press PLAY.

> `-STA` matters. Without it the window never appears.

---

## Optional: the upscaled textures

The host runs textures upscaled 2x by an AI model — 1,133 of them across
characters, twelve maps and the DLC skins.

**You do not need this to play together.** Textures are drawn locally; the match
synchronises player state, not art. If you skip this you see the stock game and
everything works.

If you want the same visuals, you **produce them yourself** rather than copying
the host's files. The result is byte-identical, because the same model on the
same input gives the same output — so nobody has to redistribute game data.

### What you need

- [.NET 9 SDK](https://dotnet.microsoft.com/download/dotnet/9.0)
- Python 3 with `numpy`, `pillow` and an onnxruntime
- `RealESRGAN_x4plus.fp16.onnx` (33 MB), placed in `tools/texture-upscale/`

**Install the GPU build if you can:**

```
pip install onnxruntime-directml
```

It uses any DirectX 12 GPU — AMD, NVIDIA or Intel — and turns hours into
minutes. Do not install both `onnxruntime` and `onnxruntime-directml`; they
provide the same module and having both breaks it.

### Run it

Close the game and AnvilToolkit first — a repack against a forge that something
else holds open fails **silently**, reporting success while writing nothing.

```
powershell -File tools\texture-upscale\run-all.ps1
```

That extracts every multiplayer forge, upscales every diffuse texture, and
repacks. Unattended. Every rebuilt forge leaves its previous version as `.bak`,
so nothing is lost if you change your mind.

`-WhatIf` checks your prerequisites and stops without touching anything.

### Getting back to stock

Restore the `.bak` files beside each `.forge`, or verify the game files through
Steam.

---

## If it does not work

| symptom | cause |
|---|---|
| Login fails | hosts entry missing or pointing at the wrong address |
| Host not visible | not on the virtual LAN, or the host's server is not running |
| No window from the launcher | `-STA` was omitted |
| Game exits immediately | it needs `/onlineUser` and `/onlinePassword`; use the launcher rather than the exe |
| Textures look unchanged | the repack ran while the game was open, so it silently did nothing |

The host's firewall needs **TCP 80** and **UDP 21030–21031** open, scoped to the
virtual LAN subnet only — never to the internet.
