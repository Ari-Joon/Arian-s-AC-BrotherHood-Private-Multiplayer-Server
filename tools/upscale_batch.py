#!/usr/bin/env python3
"""
Upscale many textures, one subprocess each.

WHY A SUBPROCESS PER TEXTURE
A single bad texture must not take the run down with it. The recolour batch
learned this the hard way: one unsupported format killed a 69-item run after 7,
and the failure was only visible because the count came up short. Here each
texture is its own process, so a crash, a hang or an unsupported format costs
exactly one item and the batch reports it and moves on.

WHAT IT SKIPS AND WHY
  --role Diffuse   is the default. Normal maps carry surface direction, not
                   colour, and pushing them through a colour-oriented BC1
                   encoder degrades lighting in ways that are hard to see in a
                   texture viewer and obvious on a model. Specular maps are the
                   least visible per byte. Neither is upscaled unless asked.
  BC3 (format 5)   is skipped by the upscaler itself - its alpha block is not
                   implemented. Three textures in this roster.

SIZE. Doubling every diffuse texture takes the multiplayer set from about 43 MB
to 170 MB, so the forge grows by roughly 128 MB. Every original is backed up
first and --restore puts them all back.

USAGE
  python tools/upscale_batch.py --dir "<...>\\DataPC.forge\\Extracted" --dry-run
  python tools/upscale_batch.py --dir "<...>\\DataPC.forge\\Extracted"
  python tools/upscale_batch.py --dir "<...>" --role Diffuse,Normal
  python tools/upscale_batch.py --dir "<...>" --restore

No game assets are redistributed; this reads and writes your own installation.
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
UPSCALE = os.path.join(HERE, "upscale_texture.py")


def find(root, roles):
    out = []
    for dirpath, _, files in os.walk(root):
        for f in files:
            if not f.endswith(".TextureMap"):
                continue
            if roles and not any(r.lower() in f.lower() for r in roles):
                continue
            out.append(os.path.join(dirpath, f))
    return sorted(out)


def describe(path):
    b = open(path, "rb").read(96)
    w, h = struct.unpack_from("<I", b, 10)[0], struct.unpack_from("<I", b, 14)[0]
    return w, h, struct.unpack_from("<I", b, 22)[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--dir", required=True, help="the forge's Extracted directory")
    ap.add_argument("--backup-dir", help="defaults to <game>\\multi\\_upscale_backup")
    ap.add_argument("--role", default="Diffuse",
                    help="comma-separated name filters; default Diffuse")
    # 2x only - see upscale_texture.py; the 32-bit address space is the limit.
    ap.add_argument("--scale", type=int, default=2, choices=(2,))
    ap.add_argument("--max-size", type=int, default=2048,
                    help="skip textures whose upscaled edge would exceed this")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--restore", action="store_true")
    ap.add_argument("--timeout", type=int, default=600, help="seconds per texture")
    a = ap.parse_args()

    roles = [r.strip() for r in a.role.split(",") if r.strip()]
    backup_dir = a.backup_dir or os.path.abspath(
        os.path.join(a.dir, "..", "..", "..", "_upscale_backup"))

    if a.restore:
        if not os.path.isdir(backup_dir):
            sys.exit("no backups at %s" % backup_dir)
        n = 0
        for f in sorted(os.listdir(backup_dir)):
            src = os.path.join(backup_dir, f)
            hits = [p for p in find(a.dir, None) if os.path.basename(p) == f]
            if len(hits) == 1:
                shutil.copyfile(src, hits[0])
                n += 1
            else:
                print("  ambiguous or missing target for %s (%d matches)" % (f, len(hits)))
        print("\n%d texture(s) restored. Repack containers, then the forge." % n)
        return

    files = find(a.dir, roles)
    if not files:
        sys.exit("nothing matched role(s) %s under %s" % (roles, a.dir))

    todo, skip = [], []
    for p in files:
        w, h, code = describe(p)
        if code == 5:
            skip.append((p, "BC3 not implemented"))
        elif max(w, h) * a.scale > a.max_size:
            skip.append((p, "%dx%d would exceed --max-size" % (w * a.scale, h * a.scale)))
        else:
            todo.append(p)

    print("\n  %d texture(s) to upscale, %d skipped, roles=%s" % (len(todo), len(skip), roles))
    for p, why in skip:
        print("    skip  %-52s %s" % (os.path.basename(p)[:52], why))
    if a.dry_run:
        print("\n  dry run - nothing written")
        return

    os.makedirs(backup_dir, exist_ok=True)
    ok = failed = 0
    t0 = time.time()
    for i, p in enumerate(todo, 1):
        name = os.path.basename(p)
        bak = os.path.join(backup_dir, name)
        cmd = [sys.executable, UPSCALE, "--texture", p, "--scale", str(a.scale),
               "--backup", bak]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=a.timeout)
        except subprocess.TimeoutExpired:
            print("  [%3d/%3d] TIMEOUT  %s" % (i, len(todo), name[:56]))
            failed += 1
            continue
        if r.returncode == 0:
            tail = [l for l in r.stdout.splitlines() if "->" in l]
            print("  [%3d/%3d] ok       %-56s %s"
                  % (i, len(todo), name[:56], tail[-1].strip() if tail else ""))
            ok += 1
        else:
            msg = (r.stdout + r.stderr).strip().splitlines()
            print("  [%3d/%3d] FAILED   %-56s %s"
                  % (i, len(todo), name[:56], msg[-1][:60] if msg else "exit %d" % r.returncode))
            failed += 1

    print("\n  %d upscaled, %d failed, %d skipped in %.0fs"
          % (ok, failed, len(skip), time.time() - t0))
    print("  backups in %s" % backup_dir)
    print("\n  Now repack: containers first, then the forge. Close the game and")
    print("  AnvilToolkit - both hold the forge and a repack against it fails.")


if __name__ == "__main__":
    main()
