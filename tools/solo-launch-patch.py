"""
Let a PRIVATE lobby start with one player, by one byte in ACBMP.exe.

WHAT IT DOES. The client reads per-mode rules out of the gamesettings .cxb
the server sends, matching XML attributes against a table of names compiled
into the executable. One of them is PrivateMinPlayers, shipped as 2 to 4
depending on mode, and it is what greys out LAUNCH with "There are not
enough members in your group to play this mode in a PRIVATE session."

This renames that ONE string in the executable, so the lookup never matches
and the field keeps its constructor default. The .cxb is not touched.

WHY NOT EDIT THE .cxb INSTEAD. That was tried first and at length, and the
client rejects an edited settings file. Not for want of care: the trailer is
a CRC32 over the whole file with its own 40 bytes zeroed, which cxb-edit now
recomputes correctly; an unchanged extract/replace round-trip is
byte-identical; section sizes update correctly. Even a single mode changed
by one byte with a valid checksum is refused. The client validates that file
beyond the checksum, so the value has to be defeated on the client side.

WHY NOT FAKE A FULL LOBBY ON THE SERVER. Also tried, at more length. Slot
padding, fabricated joins, GameSession/InviteAccepted and every Participation
subtype. The client ACKs all of it and acts on none, because the party roster
is local state - it never asks the server who is in a session.

SCOPE. Only the machine that wants to play alone needs this. Friends joining
run a stock game; nothing here is redistributed and no game file is shared.

NOTE. Steam's "Verify integrity of game files" restores the original and
silently switches solo launch back off. Re-run this afterwards.

    python solo-launch-patch.py --status
    python solo-launch-patch.py --apply
    python solo-launch-patch.py --revert
"""
import argparse
import hashlib
import os
import shutil
import sys

NAME = b'PrivateMinPlayers'
PATCHED = NAME[:-1] + b'Z'
DEFAULT_EXE = (r"C:\Program Files (x86)\Steam\steamapps\common"
               r"\Assassins Creed Brotherhood\ACBMP.exe")


def find_one(data, needle):
    """Offset of needle, but only if it appears exactly once.

    Patching the wrong copy of a string that occurs twice would leave the
    real one intact and look like it had worked.
    """
    first = data.find(needle)
    if first < 0:
        return None
    if data.find(needle, first + 1) >= 0:
        raise SystemExit(f"  {needle!r} appears more than once - refusing to guess")
    return first


def state(data):
    if find_one(data, NAME) is not None:
        return 'vanilla'
    if find_one(data, PATCHED) is not None:
        return 'patched'
    return 'unknown'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--exe', default=DEFAULT_EXE)
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--revert', action='store_true')
    ap.add_argument('--status', action='store_true')
    a = ap.parse_args()

    if not os.path.isfile(a.exe):
        raise SystemExit(f"  not found: {a.exe}")
    backup = a.exe + '.vanilla'
    data = bytearray(open(a.exe, 'rb').read())
    st = state(data)

    print(f"  {os.path.basename(a.exe)}  {len(data):,} bytes")
    print(f"  md5      {hashlib.md5(data).hexdigest()}")
    print(f"  state    {st}")
    print(f"  backup   {'present' if os.path.isfile(backup) else 'MISSING'}")

    if a.status or not (a.apply or a.revert):
        if st == 'unknown':
            print("  Neither string found. A game update probably replaced the"
                  " executable; this patch no longer applies.")
        return 0

    if a.revert:
        # Restore ONLY this string, rather than copying the .vanilla backup
        # over the whole file. Both patch tools share one backup, so a
        # whole-file restore here would silently undo multi-instance-patch
        # too - the same trap as -ResetRules reverting the whole .cxb.
        if st == 'vanilla':
            print("  already stock - nothing to do")
            return 0
        off = find_one(data, PATCHED)
        data[off:off + len(PATCHED)] = NAME
        open(a.exe, 'wb').write(data)
        print("  reverted: private lobbies use the shipped minimums again")
        return 0

    if st == 'patched':
        print("  already patched - nothing to do")
        return 0
    if st == 'unknown':
        raise SystemExit("  cannot find the attribute name; refusing to patch blind")

    if not os.path.isfile(backup):
        shutil.copy2(a.exe, backup)
        print(f"  backed up to {os.path.basename(backup)}")

    off = find_one(data, NAME)
    if data[off + len(NAME)] != 0:
        raise SystemExit("  string is not NUL-terminated where expected - refusing")
    data[off:off + len(NAME)] = PATCHED
    open(a.exe, 'wb').write(data)
    print(f"  patched at 0x{off:X}: {NAME.decode()} -> {PATCHED.decode()}")
    print("  private lobbies can now start with one player")
    return 0


if __name__ == '__main__':
    sys.exit(main())
