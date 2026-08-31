r"""
EXPERIMENT: try to raise crowd density and skin variety, by defaulting the
attributes that gate them.

HOW IT WORKS. The client reads settings out of the gamesettings .cxb by matching
XML attribute names against strings compiled into ACBMP.exe. Rename one and the
lookup never matches, so the field keeps its constructor default. This is the
same one-byte technique that gave solo lobbies (PrivateMinPlayers) and stopped
short-handed matches ending (PlayersThreshold).

WHY IT IS AN EXPERIMENT AND NOT A FIX. Renaming can only fall back to a
DEFAULT - it cannot set a chosen value. We do not know what those defaults are.
Turning off bandwidth management might let the crowd spawn freely, or might
disable crowd synchronisation and give FEWER npcs, or nothing at all. Expect to
find out by looking, not by reasoning.

WHY THIS IS THE ONLY ROUTE LEFT. Crowd population is not in the .cxb - the only
crowd entries there are CrowdBandwidth_*, which govern network sync, not counts.
It lives as compiled binary inside the map forges' world data, and any forge
repack silently loses data, which is what destroyed a character model earlier.
So editing the data is off the table and this is what remains.

TARGETS
  bandwidth  CrowdBandwidth_AllowBandwidthManagement (true) - throttling on/off
  spawngate  CrowdBandwidth_AvoidSpawningBelowQuality (6)   - suppresses spawns
  skins      MaxPlayersWithSameSkin (1)                     - persona variety

    python crowd-patch.py --status
    python crowd-patch.py --apply bandwidth,spawngate
    python crowd-patch.py --revert
"""
import argparse
import os
import re
import sys

DEFAULT_EXE = (r"C:\Program Files (x86)\Steam\steamapps\common"
               r"\Assassins Creed Brotherhood\ACBMP.exe")

TARGETS = {
    'bandwidth': b'CrowdBandwidth_AllowBandwidthManagement',
    'spawngate': b'CrowdBandwidth_AvoidSpawningBelowQuality',
    'migrate':   b'CrowdBandwidth_TryToMigrateBelowQuality',
    'skins':     b'MaxPlayersWithSameSkin',
}


def patched(name):
    return name[:-1] + b'Z'


def find(data, name):
    """Offset of an exact single occurrence, patched or not. None if absent."""
    for cand in (name, patched(name)):
        hits = [m.start() for m in re.finditer(re.escape(cand), data)]
        if len(hits) > 1:
            raise SystemExit(f"  {cand!r} occurs {len(hits)} times - refusing to guess")
        if hits:
            return hits[0], cand == patched(name)
    return None, False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--exe', default=DEFAULT_EXE)
    ap.add_argument('--apply', help="comma-separated: " + ", ".join(TARGETS))
    ap.add_argument('--revert', action='store_true')
    ap.add_argument('--status', action='store_true')
    a = ap.parse_args()

    if not os.path.isfile(a.exe):
        raise SystemExit(f"  not found: {a.exe}")
    data = bytearray(open(a.exe, 'rb').read())

    if a.status or not (a.apply or a.revert):
        for k, name in TARGETS.items():
            off, is_patched = find(data, name)
            where = f"0x{off:X}" if off is not None else "absent"
            print(f"  {k:<10} {name.decode():<42} {where:<12} "
                  f"{'PATCHED' if is_patched else 'vanilla'}")
        return 0

    changed = 0
    if a.revert:
        for k, name in TARGETS.items():
            off, is_patched = find(data, name)
            if off is not None and is_patched:
                data[off:off + len(name)] = name
                print(f"  reverted {k}")
                changed += 1
    else:
        want = [k.strip() for k in a.apply.split(',') if k.strip()]
        bad = [k for k in want if k not in TARGETS]
        if bad:
            raise SystemExit(f"  unknown target(s): {bad}. Have: {list(TARGETS)}")
        for k in want:
            name = TARGETS[k]
            off, is_patched = find(data, name)
            if off is None:
                print(f"  {k}: string not found - skipped")
                continue
            if is_patched:
                print(f"  {k}: already patched")
                continue
            data[off:off + len(name)] = patched(name)
            print(f"  patched {k} at 0x{off:X}: {name.decode()} -> {patched(name).decode()}")
            changed += 1

    if changed:
        open(a.exe, 'wb').write(data)
        print(f"  wrote {changed} change(s). Rebuild the bot client if you use it:")
        print(f"    python tools/bot-client.py --build")
    else:
        print("  nothing to do")
    return 0


if __name__ == '__main__':
    sys.exit(main())
