r"""
Read a game client's memory. The "sonar" half of bot perception.

WHY NOT PIXELS. Reading the HUD off the screen needs calibration per
resolution, breaks on any UI change, and is noisy. The values behind the HUD -
where the target is, who is hunting you, how hot the threat meter is - are
exact in memory and need finding only once.

IS THIS CHEATING? Only if the bot learns things a player cannot see. Compass
bearing, current contract and pursuer count are all ON the HUD already, so
reading them is parity, not advantage. Fairness comes from REACTION, not
ignorance: bot_vm.py's observe_ticks, commit_confidence and tell_rate are the
dials that make a bot beatable, and they work the same whatever the input.

HOW YOU FIND AN ADDRESS. The same way Cheat Engine does - scan for a value you
can see, change it in game, scan again for the new value, and keep narrowing
until one address survives:

    python mem.py --account Bot1 --scan-float 100.0      # e.g. health at full
    ... take a hit ...
    python mem.py --account Bot1 --narrow-float 80.0
    ... repeat until a handful remain ...
    python mem.py --account Bot1 --read 0x1A2B3C4D --type float

Candidates persist in a scan file between runs, so narrowing is incremental.

WARNING. Addresses found this way are specific to one build of ACBMP.exe and
usually to one run, unless they are reached through a static pointer chain.
Finding the chain is a second job after finding the address.
"""
import argparse
import ctypes
import json
import os
import re
import struct
import subprocess
import sys
from ctypes import wintypes

k32 = ctypes.WinDLL('kernel32', use_last_error=True)

PROCESS_VM_READ = 0x0010
PROCESS_QUERY_INFORMATION = 0x0400
MEM_COMMIT = 0x1000
PAGE_READABLE = 0x02 | 0x04 | 0x20 | 0x40      # RO, RW, EXEC_READ, EXEC_RW
PAGE_GUARD = 0x100


class MEMORY_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
                ("AllocationProtect", wintypes.DWORD), ("RegionSize", ctypes.c_size_t),
                ("State", wintypes.DWORD), ("Protect", wintypes.DWORD),
                ("Type", wintypes.DWORD)]


def find_pid(account):
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "Get-CimInstance Win32_Process -Filter \"Name='ACBMP.exe'\" | "
         "Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress"],
        capture_output=True, text=True)
    txt = out.stdout.strip()
    if not txt:
        return None
    data = json.loads(txt)
    if isinstance(data, dict):
        data = [data]
    for row in data:
        cmd = row.get("CommandLine") or ""
        m = re.search(r"/onlineUser:(\S+)", cmd)
        if m and m.group(1).lower() == account.lower():
            return int(row["ProcessId"])
    return None


def regions(h):
    """Committed, readable, non-guard regions. Guard pages fault when read."""
    mbi = MEMORY_BASIC_INFORMATION()
    addr = 0
    out = []
    while k32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi),
                             ctypes.sizeof(mbi)):
        if (mbi.State == MEM_COMMIT and (mbi.Protect & PAGE_READABLE)
                and not (mbi.Protect & PAGE_GUARD)):
            out.append((mbi.BaseAddress or 0, mbi.RegionSize))
        nxt = (mbi.BaseAddress or 0) + mbi.RegionSize
        if nxt <= addr:
            break
        addr = nxt
    return out


def read(h, addr, size):
    buf = ctypes.create_string_buffer(size)
    got = ctypes.c_size_t(0)
    ok = k32.ReadProcessMemory(h, ctypes.c_void_p(addr), buf, size,
                               ctypes.byref(got))
    return buf.raw[:got.value] if ok else b''


def scan(h, value, tol, prev=None):
    """Addresses holding `value` as a 4-byte float, within `tol`."""
    packed = struct.pack('<f', value)
    hits = []
    if prev is not None:
        for a in prev:
            d = read(h, a, 4)
            if len(d) == 4 and abs(struct.unpack('<f', d)[0] - value) <= tol:
                hits.append(a)
        return hits
    for base, size in regions(h):
        # Cap per-region work: a 32-bit game still maps very large regions and
        # scanning every one exhaustively takes minutes for no benefit.
        if size > 64 * 1024 * 1024:
            continue
        data = read(h, base, size)
        if not data:
            continue
        start = 0
        while True:
            i = data.find(packed, start)
            if i < 0:
                break
            hits.append(base + i)
            start = i + 1
            if len(hits) > 400000:
                return hits
    return hits


def statefile(pid):
    return os.path.join(os.environ.get('TMP', '.'), f'acb-mem-{pid}.json')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--account', default='Bot1')
    ap.add_argument('--pid', type=int)
    ap.add_argument('--scan-float', type=float)
    ap.add_argument('--narrow-float', type=float)
    ap.add_argument('--tol', type=float, default=0.001)
    ap.add_argument('--read', help='address, e.g. 0x1A2B3C4D')
    ap.add_argument('--type', default='float', choices=['float', 'int'])
    ap.add_argument('--regions', action='store_true')
    a = ap.parse_args()

    pid = a.pid or find_pid(a.account)
    if not pid:
        print(f"  no running client for account {a.account!r}")
        return 1
    h = k32.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        print(f"  cannot open process {pid} (error {ctypes.get_last_error()}) - "
              f"try an elevated shell")
        return 1
    label = a.account if not a.pid else "by pid"
    print(f"  attached to pid {pid} ({label})")

    if a.regions:
        rs = regions(h)
        total = sum(s for _, s in rs)
        print(f"  {len(rs)} readable regions, {total/1024/1024:.1f} MB")
        return 0

    if a.read:
        addr = int(a.read, 0)
        d = read(h, addr, 4)
        if len(d) != 4:
            print("  unreadable")
            return 1
        v = struct.unpack('<f' if a.type == 'float' else '<i', d)[0]
        print(f"  0x{addr:X} = {v}")
        return 0

    sf = statefile(pid)
    if a.scan_float is not None:
        hits = scan(h, a.scan_float, a.tol)
        json.dump(hits, open(sf, 'w'))
        print(f"  {len(hits)} candidate(s) hold {a.scan_float}")
        print(f"  change the value in game, then --narrow-float <new value>")
        return 0

    if a.narrow_float is not None:
        if not os.path.isfile(sf):
            print("  no previous scan for this pid - run --scan-float first")
            return 1
        prev = json.load(open(sf))
        hits = scan(h, a.narrow_float, a.tol, prev=prev)
        json.dump(hits, open(sf, 'w'))
        print(f"  {len(prev)} -> {len(hits)} candidate(s) hold {a.narrow_float}")
        for x in hits[:12]:
            print(f"     0x{x:X}")
        return 0

    ap.print_help()
    return 0


if __name__ == '__main__':
    sys.exit(main())
