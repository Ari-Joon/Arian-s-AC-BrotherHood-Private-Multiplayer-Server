"""Re-upscale persona textures from PRE-RECOLOUR originals.

WHY THIS EXISTS. The character roster was upscaled from `multi\\_upscale_backup`,
which looked like a pristine set and was not: an earlier session had recoloured
62 of the 64 personas before that backup was taken, so the 2x textures shipped
with someone else's colour mod baked in. The genuinely untouched copies live in
`multi\\_persona_backup` as `*_ORIGINAL.TextureMap`, and this sources from those.

The distinction is invisible by geometry - both are 1024 and both parse - so
nothing in the pipeline could have caught it. It only surfaced when the user
said they did not want modified skins.

Diffuse only, 2x, same model and settings as the rest of the roster.
"""
import glob, os, shutil, struct, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import esrgan
from texmap import TextureMap
from upscale import upscale, FILTERS
from batch import find_model

G = r"C:\Program Files (x86)\Steam\steamapps\common\Assassins Creed Brotherhood"
E = os.path.join(G, "multi", "Extracted", "DataPC.forge", "Extracted")
PB = os.path.join(G, "multi", "_persona_backup")
SD = os.path.dirname(os.path.abspath(__file__))
VBK = os.path.join(SD, "vanilla_originals")

try:
    import ctypes
    ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x4000)
except Exception:
    pass


def main():
    dry = '--dry-run' in sys.argv
    plan, skipped = [], []
    for o in sorted(glob.glob(os.path.join(PB, "*_ORIGINAL.TextureMap"))):
        base = os.path.basename(o).replace("_ORIGINAL.TextureMap", ".TextureMap")
        live = glob.glob(os.path.join(E, "*", base))
        if not live:
            skipped.append((base, "no live file in DataPC.forge")); continue
        try:
            t = TextureMap.load(o)
        except Exception as e:
            skipped.append((base, str(e))); continue
        if t.width > 1024:
            skipped.append((base, "original is %dpx; 2x exceeds budget" % t.width)); continue
        plan.append((live[0], o, t))

    print("%d pre-recolour originals -> %d to re-upscale, %d skipped"
          % (len(plan) + len(skipped), len(plan), len(skipped)), flush=True)
    for b, w in skipped:
        print("  SKIP %-52s %s" % (b[:52], w), flush=True)
    if dry:
        print("dry run, nothing written"); return

    model = esrgan.Upscaler(find_model(None), tile=192, overlap=24)
    ok = fail = 0
    t0 = time.time()
    for i, (live, src, tex0) in enumerate(plan, 1):
        # Keep the vanilla source pinned so this is repeatable.
        keep = os.path.join(VBK, os.path.basename(src))
        os.makedirs(VBK, exist_ok=True)
        if not os.path.exists(keep):
            shutil.copy2(src, keep)
        t1 = time.time()
        try:
            tex, out, nw, nh, nm = upscale(keep, 2.0, FILTERS['lanczos'], False, model)
            chk = TextureMap(out)
            assert chk.file_id == tex.file_id, "File ID changed"
            assert chk.format == tex.format and chk.faces == tex.faces
            tmp = live + ".tmp"
            with open(tmp, 'wb') as f:
                f.write(out)
            os.replace(tmp, live)
            ok += 1
            print("  [%2d/%d] %-50s %dx%d -> %dx%d %3.0fs"
                  % (i, len(plan), os.path.basename(live)[:50], tex.width, tex.height,
                     nw, nh, time.time() - t1), flush=True)
        except Exception as e:
            fail += 1
            print("  [%2d/%d] FAIL %-44s %s" % (i, len(plan), os.path.basename(live)[:44], e),
                  flush=True)
    print("done: %d ok, %d failed, %.0f min" % (ok, fail, (time.time() - t0) / 60), flush=True)


if __name__ == '__main__':
    main()
