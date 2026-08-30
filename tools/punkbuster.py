r"""
Turn the PunkBuster client off, so a second game client is not ejected.

THE PROBLEM. Running two clients on one machine, the SECOND is ejected after
about two minutes:

    PunkBuster kicked player 'Bot1' (for 0 minutes) ... RESTRICTION:
    Service Communication Failure: PnkBstrB.exe initialization failed

PnkBstrB.exe serves one game instance. The first client claims it and the
second cannot initialise, so it is kicked. The first client is never affected,
which is why solo play looks fine and only bots die.

WHY STOPPING THE WINDOWS SERVICE DOES NOT HELP. The game starts it on demand,
and with no service reachable at all the client fails initialisation and is
kicked for that instead. The service is not the lever.

WHY RENAMING pbcl.dll DID NOT WORK EITHER. An earlier attempt renamed
pb/pbcl.dll. PunkBuster does not load that: it loads VERSIONED copies out of
pb/dll (wc*.dll is the client, ws*.dll the server, wa*.dll the ag module), and
wc002261.dll is byte-for-byte the same size as the renamed pbcl.dll. The
rename looked like it had worked and changed nothing.

This renames the versioned client module, which is what actually loads.

    python punkbuster.py --status
    python punkbuster.py --disable
    python punkbuster.py --enable

NOT a system change: these are files inside the game folder, and --enable puts
them back. The Windows service is left alone - manage that yourself if you want
it back on Automatic.
"""
import argparse
import glob
import os
import sys

GAME = (r"C:\Program Files (x86)\Steam\steamapps\common"
        r"\Assassins Creed Brotherhood")
SUFFIX = ".disabled"


# WHICH MODULE ACTUALLY KICKS. Only the SERVER module carries the strings
# "kicked player" and "RESTRICTION" - the client module carries neither:
#
#   ws001802.dll  {'kicked player': 1, 'RESTRICTION': 5}   <- the ejector
#   wc002261.dll  none
#
# That matches the peer-to-peer message name O2O_SendPunkBusterKick: the HOST
# runs the PunkBuster server module, judges its peer and kicks it. Disabling
# the client module on the bot cannot prevent a decision the host makes, and
# very likely caused the "initialization failed" text in the first place.
PATTERNS = {"server": "ws*.dll", "client": "wc*.dll", "ag": "wa*.dll"}


def modules(pb, kinds=("server",)):
    out = []
    for kind in kinds:
        pat = PATTERNS[kind]
        for p in (pat, pat + SUFFIX):
            out += glob.glob(os.path.join(pb, "dll", p))
    return sorted(set(out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--game', default=GAME)
    ap.add_argument('--status', action='store_true')
    ap.add_argument('--disable', action='store_true')
    ap.add_argument('--enable', action='store_true')
    ap.add_argument('--kinds', default='server',
                    help="comma-separated: server, client, ag. Default 'server' - "
                         "the only module that does the kicking.")
    a = ap.parse_args()

    pb = os.path.join(a.game, "pb")
    if not os.path.isdir(pb):
        raise SystemExit(f"  no pb folder at {pb}")

    kinds = tuple(k.strip() for k in a.kinds.split(',') if k.strip() in PATTERNS)
    mods = modules(pb, kinds or ('server',))
    if not mods:
        raise SystemExit(f"  no {kinds} module found in pb/dll - "
                         f"refusing to guess which file to touch")

    if a.status or not (a.disable or a.enable):
        for m in mods:
            state = "DISABLED" if m.endswith(SUFFIX) else "active"
            print(f"   {os.path.basename(m):<28} {state}")
        return 0

    changed = 0
    for m in mods:
        if a.disable and not m.endswith(SUFFIX):
            os.rename(m, m + SUFFIX)
            print(f"  disabled {os.path.basename(m)}")
            changed += 1
        elif a.enable and m.endswith(SUFFIX):
            os.rename(m, m[:-len(SUFFIX)])
            print(f"  enabled  {os.path.basename(m)[:-len(SUFFIX)]}")
            changed += 1
    if not changed:
        print("  already in that state")
    elif a.disable:
        print("  disabled - the host should stop ejecting its peer")
    return 0


if __name__ == '__main__':
    sys.exit(main())
