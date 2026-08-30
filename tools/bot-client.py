r"""
Build a bot client that has its OWN config file, so it is a real player.

THE PROBLEM. Two clients on one machine share
%USERPROFILE%\Saved Games\Assassin's Creed Brotherhood\ACBrotherhood.ini.
That one file holds the input binding ([Input] SelectedInput=...) AND the
graphics settings, so the two fight over it, last writer wins. Symptoms: the
player's controller stops responding until it is re-selected in the in-game
settings, and both characters answer the same gamepad because neither client
has a device of its own.

THE FIX. The filename is a wide string inside ACBMP.exe. A bot runs from its
OWN COPY of the executable with that string renamed, so it reads and writes a
different file. Same length, so nothing moves:

    ACBrotherhood.ini  ->  ACBrotherhoo2.ini

The copy inherits whatever patches the original already has (solo launch,
multi-instance, PlayersThreshold), because it is copied after they are applied.
Rebuild it after patching the original again.

WHAT THIS BUYS. Each client can be bound to its own controller through its own
in-game settings, and can hold its own graphics settings - which matters
because a bot does not need the quality the player wants. It does not by itself
give the bot its own SAVE or loadout; those live elsewhere and are a separate
question.

    python bot-client.py --status
    python bot-client.py --build
    python bot-client.py --remove
"""
import argparse
import hashlib
import os
import re
import shutil
import sys

GAME = (r"C:\Program Files (x86)\Steam\steamapps\common"
        r"\Assassins Creed Brotherhood")
ORIG_INI = "ACBrotherhood.ini"
BOT_INI = "ACBrotherhoo2.ini"          # same length, deliberately
BOT_EXE = "ACBMP_bot.exe"


def wide(s):
    return s.encode('utf-16-le')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--game', default=GAME)
    ap.add_argument('--build', action='store_true')
    ap.add_argument('--remove', action='store_true')
    ap.add_argument('--status', action='store_true')
    a = ap.parse_args()

    src = os.path.join(a.game, "ACBMP.exe")
    dst = os.path.join(a.game, BOT_EXE)
    if not os.path.isfile(src):
        raise SystemExit(f"  not found: {src}")

    if a.remove:
        if os.path.isfile(dst):
            os.remove(dst)
            print(f"  removed {BOT_EXE}")
        else:
            print("  nothing to remove")
        return 0

    if a.status or not a.build:
        if not os.path.isfile(dst):
            print(f"  {BOT_EXE}: not built")
            return 0
        d = open(dst, 'rb').read()
        n_bot = len(re.findall(re.escape(wide(BOT_INI)), d))
        n_orig = len(re.findall(re.escape(wide(ORIG_INI)), d))
        same = hashlib.md5(d).hexdigest() == hashlib.md5(open(src, 'rb').read()).hexdigest()
        print(f"  {BOT_EXE}: built, {len(d):,} bytes")
        print(f"    config string: {n_bot} x {BOT_INI}, {n_orig} x {ORIG_INI}")
        print(f"    identical to ACBMP.exe: {same}   (must be False)")
        return 0

    assert len(ORIG_INI) == len(BOT_INI), "replacement must be the same length"
    d = bytearray(open(src, 'rb').read())
    hits = [m.start() for m in re.finditer(re.escape(wide(ORIG_INI)), d)]
    if not hits:
        raise SystemExit(f"  {ORIG_INI} not found as a wide string - "
                         f"refusing to build a copy that would share the config")
    for off in hits:
        # Every occurrence, not just the first: the name appears three times and
        # leaving one behind would make the bot read one file and write another.
        d[off:off + len(wide(ORIG_INI))] = wide(BOT_INI)
    open(dst, 'wb').write(d)
    print(f"  built {BOT_EXE} ({len(d):,} bytes)")
    print(f"  patched {len(hits)} occurrence(s): {ORIG_INI} -> {BOT_INI}")
    print(f"  it reads and writes Saved Games/.../{BOT_INI}")
    print(f"  bind its controller from inside that client's own settings")
    return 0


if __name__ == '__main__':
    sys.exit(main())
