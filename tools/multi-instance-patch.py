r"""
Let more than one game client run on one Windows session.

WHY. ACBMP.exe allows a single instance per session, which is why a second
client "dies after 5s with exit code 0". It is not a mutex - it is a named
semaphore, and the check is on the NAME already existing, not on acquiring a
slot:

    push  offset "scimitar_semaphore"
    push  1                    ; lMaximumCount
    push  1                    ; lInitialCount
    push  0
    call  CreateSemaphoreA
    call  GetLastError
    cmp   eax, 0B7h            ; ERROR_ALREADY_EXISTS
    jnz   continue             ; not already running -> carry on
    ...   Sleep(100) x50, then exit cleanly

RAISING THE COUNTS DOES NOTHING. CreateSemaphoreA on an existing name returns
the existing object and sets ERROR_ALREADY_EXISTS whatever the counts say, and
that error is the whole test. The counts are never even inspected.

So this flips the single conditional: `jnz` (75) becomes `jmp` (EB), and the
"already running" branch - the retry loop and the quiet exit - becomes
unreachable. One byte.

WHAT IT IS FOR. Bot players. A bot in this game has to be a real client with
its own account, because matches are peer-to-peer and the AI is compiled into
the executable. Without this, each bot needs its own Windows account.

WHAT IT DOES NOT DO. It does not make the second instance sensible on its own.
Two clients share one machine's GPU, and they share config: both write
`Saved Games\...\ACBrotherhood.ini`, so graphics settings are last-writer-wins.
Give each instance its own account with /onlineUser.

    python multi-instance-patch.py --status
    python multi-instance-patch.py --apply
    python multi-instance-patch.py --revert
"""
import argparse
import hashlib
import os
import re
import shutil
import sys

# Anchored on the surrounding instructions, not a fixed offset: 'cmp eax,0B7h;
# jnz' alone appears three times in the binary, and this longer form appears
# exactly once. A fixed offset would silently move with a game update.
ANCHOR = bytes.fromhex('FFD733C93DB7000000')   # call GetLastError; xor ecx,ecx; cmp eax,0B7h
JNZ, JMP = 0x75, 0xEB
DEFAULT_EXE = (r"C:\Program Files (x86)\Steam\steamapps\common"
               r"\Assassins Creed Brotherhood\ACBMP.exe")


def site(data):
    """File offset of the conditional byte, or None. Refuses if ambiguous."""
    hits = [m.start() for m in re.finditer(re.escape(ANCHOR), data)]
    if not hits:
        return None
    if len(hits) > 1:
        raise SystemExit(f"  anchor found {len(hits)} times - refusing to guess")
    off = hits[0] + len(ANCHOR)
    if data[off] not in (JNZ, JMP):
        raise SystemExit(f"  expected 75 or EB at 0x{off:X}, found {data[off]:02X} - refusing")
    return off


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
    off = site(data)

    print(f"  {os.path.basename(a.exe)}  {len(data):,} bytes")
    print(f"  md5     {hashlib.md5(data).hexdigest()}")
    if off is None:
        print("  state   anchor not found - a game update probably replaced the exe")
        return 1
    print(f"  site    0x{off:X}")
    print(f"  state   {'multi-instance' if data[off] == JMP else 'single-instance'}")
    print(f"  backup  {'present' if os.path.isfile(backup) else 'MISSING'}")

    if a.status or not (a.apply or a.revert):
        return 0

    if a.revert:
        # Only this byte, so an unrelated patch in the same exe survives.
        if data[off] == JNZ:
            print("  already single-instance - nothing to do")
            return 0
        data[off] = JNZ
        open(a.exe, 'wb').write(data)
        print("  reverted: one client per Windows session")
        return 0

    if data[off] == JMP:
        print("  already patched - nothing to do")
        return 0
    if not os.path.isfile(backup):
        shutil.copy2(a.exe, backup)
        print(f"  backed up to {os.path.basename(backup)}")
    data[off] = JMP
    open(a.exe, 'wb').write(data)
    print(f"  patched at 0x{off:X}: jnz -> jmp")
    print("  more than one client can now run on this Windows session")
    return 0


if __name__ == '__main__':
    sys.exit(main())
