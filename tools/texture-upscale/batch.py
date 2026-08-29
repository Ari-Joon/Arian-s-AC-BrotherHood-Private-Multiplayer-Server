"""AI-upscale every environment diffuse texture across the multiplayer maps.

Same pipeline as the character roster, pointed at the map forges. These have
never been upscaled by anyone, so the live file IS the original - but that is
checked per file rather than assumed, because assuming it for the character
roster is exactly what would have produced 4096 textures.

Environment textures are much smaller than character ones: mostly 256 and 512
with the occasional 1024, against the roster's 1024s. So this is a cheaper job
per texture AND the one that changes more of the screen, since the city is what
you are looking at for almost all of a match.

    python maps_ai.py [--dry-run] [--only SUBSTRING]
"""
import argparse, glob, os, shutil, struct, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import esrgan
from texmap import TextureMap
from upscale import upscale, FILTERS

G = r"C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood"
EXTRACTED = os.path.join(G, "multi", "Extracted")
SD = os.path.dirname(os.path.abspath(__file__))
MYBK = os.path.join(SD, "map_originals")
MODEL = os.path.join(os.path.dirname(SD), "models", "RealESRGAN_x4plus.fp16.onnx")

MAP_FORGES = "DataPC_AC2MP_", "DataPC_ACR_Rome_Multi"


def deprioritise():
    try:
        import ctypes
        ctypes.windll.kernel32.SetPriorityClass(
            ctypes.windll.kernel32.GetCurrentProcess(), 0x00004000)
        return True
    except Exception:
        return False


def width_of(path):
    with open(path, 'rb') as f:
        return struct.unpack_from('<I', f.read(96), 10)[0]


def collect(only=None):
    out = []
    for d in sorted(os.listdir(EXTRACTED)):
        if not any(d.startswith(p) for p in MAP_FORGES):
            continue
        if only and only.lower() not in d.lower():
            continue
        root = os.path.join(EXTRACTED, d, "Extracted")
        out += sorted(glob.glob(os.path.join(root, "**", "*DiffuseMap*.TextureMap"),
                                recursive=True))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--only', help="restrict to forges whose name contains this")
    a = ap.parse_args()

    print("below-normal priority: %s" % deprioritise(), flush=True)
    targets = collect(a.only)
    print("%d diffuse textures across the map forges" % len(targets), flush=True)

    plan, skipped = [], []
    for p in targets:
        rel = os.path.relpath(p, EXTRACTED)
        mine = os.path.join(MYBK, rel)
        src = mine if os.path.exists(mine) else p
        try:
            t = TextureMap.load(src)
        except Exception as e:
            skipped.append((rel, str(e)))
            continue
        # Anything already above 1024 is left alone, for either of two reasons
        # that happen to want the same action. If it is a texture this pipeline
        # already doubled, doubling again gives 4096. If it is a NATIVE 2048
        # asset - and the two here, a background-city atlas and a door, are
        # native - then 2x would ALSO give 4096. The 32-bit client cannot afford
        # 4096 either way, so the rule is the same and only the wording differs.
        if src is p and width_of(p) > 1024:
            skipped.append((rel, "%dpx already; 2x would be 4096, which the "
                                 "32-bit client cannot afford" % width_of(p)))
            continue
        # Already done: the live file is exactly twice its pristine source.
        if src is not p and width_of(p) == t.width * 2:
            continue
        plan.append((p, src, t))

    from collections import Counter
    print("  will process %d, skipping %d" % (len(plan), len(skipped)), flush=True)
    print("  widths: %s" % dict(sorted(Counter(t.width for _, _, t in plan).items())), flush=True)
    print("  formats: %s" % dict(sorted(Counter(t.format for _, _, t in plan).items())), flush=True)
    for rel, why in skipped[:20]:
        print("  SKIP %-56s %s" % (rel[-56:], why), flush=True)
    if a.dry_run:
        print("dry run, nothing written")
        return

    model = esrgan.Upscaler(MODEL, tile=192, overlap=24)
    t_all = time.time()
    ok = fail = 0
    for i, (live, src, _) in enumerate(plan, 1):
        rel = os.path.relpath(live, EXTRACTED)
        mine = os.path.join(MYBK, rel)
        os.makedirs(os.path.dirname(mine), exist_ok=True)
        if not os.path.exists(mine):
            shutil.copy2(src, mine)
        t0 = time.time()
        try:
            tex, out, nw, nh, nm = upscale(mine, 2.0, FILTERS['lanczos'], False, model)
            chk = TextureMap(out)
            assert chk.file_id == tex.file_id, "File ID changed"
            assert chk.format == tex.format and chk.faces == tex.faces
            assert (chk.width, chk.height, chk.mips) == (nw, nh, nm)
            tmp = live + ".tmp"
            with open(tmp, 'wb') as f:
                f.write(out)
            os.replace(tmp, live)
            ok += 1
            if i % 10 == 0 or tex.width >= 1024:
                print("  [%3d/%d] %-46s %dx%d -> %dx%d %3.0fs"
                      % (i, len(plan), os.path.basename(live)[:46], tex.width, tex.height,
                         nw, nh, time.time() - t0), flush=True)
        except Exception as e:
            fail += 1
            print("  [%3d/%d] FAIL %-42s %s" % (i, len(plan), os.path.basename(live)[:42], e),
                  flush=True)
    print("done: %d ok, %d failed, %d skipped, %.0f min"
          % (ok, fail, len(skipped), (time.time() - t_all) / 60), flush=True)


if __name__ == '__main__':
    main()
