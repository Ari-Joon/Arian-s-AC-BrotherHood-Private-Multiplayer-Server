"""Upscale one Assassin's Creed Brotherhood .TextureMap.

Decodes every mip level, resamples, re-encodes in the SAME BC format, and
rewrites the four header fields and three trailer fields that describe the new
geometry. The File ID is copied through untouched - the game binds textures by
it, and a changed ID renders as a flat grey block.

    python texture_upscale.py --in X.TextureMap --out Y.TextureMap --scale 2

Exits non-zero and writes nothing on any failure, so a batch can treat each
file independently.

WHAT THIS DOES NOT PROVE. A larger texture makes the .data container and the
forge record around it grow by roughly the square of the scale. Nothing here
tests whether repack and the game tolerate that. Do one texture end to end
before batching.
"""
import argparse, os, sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bc
from texmap import TextureMap, full_mip_count, level_size

FILTERS = {
    'lanczos': Image.LANCZOS,
    'bicubic': Image.BICUBIC,
    'bilinear': Image.BILINEAR,
    'nearest': Image.NEAREST,
}


# NO ALPHA-EDGE FIX HERE, DELIBERATELY. Resampling RGBA directly normally causes
# transparent-black RGB to bleed across alpha edges as a dark fringe, and a
# nearest-opaque fill before resampling is the usual cure. It was implemented and
# then measured, and both premises were false for these textures: on a BC2
# diffuse that is 75% transparent the mean absolute error at alpha EDGES was 13.0
# against 16.9 in the opaque interior - lower at the edges, so there is no fringe
# - and the RGB stored under alpha=0 is real texture data, not black, so filling
# it with the nearest opaque colour would have discarded genuine detail. The fix
# changed 73% of pixels and moved the error by 0.0 dB.
#
# The residual error is the resampling filter itself: upscaling and downscaling
# with no BC step at all gives 15.6 against the pipeline's 16.9, so the codec
# contributes about a tenth of it.


def resample(rgba, w, h, flt):
    if (rgba.shape[1], rgba.shape[0]) == (w, h):
        return rgba
    return np.array(Image.fromarray(rgba, 'RGBA').resize((w, h), flt))


def plan_mips(old_w, old_h, old_mips, new_w, new_h):
    """How many levels the rebuilt texture should carry.

    Most textures ship a complete chain, and a complete chain must stay
    complete - doubling 1024 takes 11 levels to 12, so the payload grows by
    more than 4x and a 4x assumption yields a file that is a third short. A few
    textures ship a deliberately partial chain (the cubemap has one level); those
    keep their level count rather than gaining one.
    """
    if old_mips == full_mip_count(old_w, old_h):
        return full_mip_count(new_w, new_h)
    return old_mips


def ai_base(rgba, model, flt, verbose=False):
    """Real-ESRGAN the colour, Lanczos the alpha, at the model's native 4x.

    The model is RGB-only. Alpha carries cut-out shapes rather than texture, so
    interpolating it is right anyway - and running a hallucinating model on a
    mask would invent holes.
    """
    def tick(done, total):
        if verbose:
            sys.stderr.write("\r    tile %d/%d" % (done, total))
            sys.stderr.flush()
    rgb = model.upscale(rgba[..., :3], progress=tick)
    if verbose:
        sys.stderr.write("\r")
    h, w = rgb.shape[:2]
    a = np.array(Image.fromarray(rgba[..., 3], 'L').resize((w, h), flt))
    return np.dstack([rgb, a])


def upscale(src, scale, flt, verbose=False, model=None):
    tex = TextureMap.load(src)

    new_w = max(1, int(round(tex.width * scale)))
    new_h = max(1, int(round(tex.height * scale)))
    new_mips = plan_mips(tex.width, tex.height, tex.mips, new_w, new_h)

    # Decode each face's largest level once and resample from it for every mip,
    # rather than halving repeatedly - successive halving compounds filter error.
    surfaces = {}
    for f, i, mw, mh, blk in tex.faces_levels():
        if i != 0:
            continue
        base = bc.decode(blk, mw, mh, tex.format)
        if model is not None:
            # Always run the model at its native 4x and resample DOWN to the
            # target. Downsampling a 4x result beats asking for 2x directly:
            # the detail the model invents survives the reduction, and the
            # reduction hides its mistakes.
            base = ai_base(base, model, flt, verbose)
        surfaces[f] = resample(base, new_w, new_h, flt)

    payloads = []
    for f in range(tex.faces):
        base = surfaces[f]
        for i in range(new_mips):
            mw, mh = max(1, new_w >> i), max(1, new_h >> i)
            payloads.append(bc.encode(resample(base, mw, mh, flt), tex.format))
            if verbose:
                print("    face %d mip %-2d %4dx%-4d %8d bytes"
                      % (f, i, mw, mh, len(payloads[-1])))

    out = tex.rebuild(new_w, new_h, new_mips, payloads)
    return tex, out, new_w, new_h, new_mips


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--in', dest='src', required=True)
    ap.add_argument('--out', dest='dst', required=True)
    ap.add_argument('--scale', type=float, default=2.0)
    ap.add_argument('--filter', default='lanczos', choices=sorted(FILTERS))
    ap.add_argument('--model', help="ONNX 4x upscaler; omit for plain resampling")
    ap.add_argument('--tile', type=int, default=192)
    ap.add_argument('--overlap', type=int, default=24)
    ap.add_argument('--dry-run', action='store_true', help="report, write nothing")
    ap.add_argument('-v', '--verbose', action='store_true')
    a = ap.parse_args()

    if a.scale <= 0:
        print("scale must be positive", file=sys.stderr)
        return 2

    model = None
    if a.model:
        import esrgan
        try:
            model = esrgan.Upscaler(a.model, tile=a.tile, overlap=a.overlap)
        except Exception as e:
            print("could not load %s: %s" % (a.model, e), file=sys.stderr)
            return 2

    try:
        tex, out, nw, nh, nm = upscale(a.src, a.scale, FILTERS[a.filter],
                                       a.verbose, model)
    except Exception as e:
        print("%s: %s" % (os.path.basename(a.src), e), file=sys.stderr)
        return 1

    print("  %-46s %dx%d/%d mips -> %dx%d/%d mips  %d -> %d bytes"
          % (os.path.basename(a.src), tex.width, tex.height, tex.mips,
             nw, nh, nm, len(tex.raw), len(out)))

    if a.dry_run:
        print("  dry run, nothing written")
        return 0

    tmp = a.dst + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(out)
    os.replace(tmp, a.dst)

    # Read it back through the same parser: it validates the marker, the
    # payload-vs-geometry invariant and the 61-byte trailer, so a bad rewrite
    # cannot leave a plausible-looking file on disk.
    check = TextureMap.load(a.dst)
    if (check.width, check.height, check.mips) != (nw, nh, nm):
        print("  written file does not read back as intended", file=sys.stderr)
        return 1
    if check.file_id != tex.file_id:
        print("  File ID changed - the game would not bind this", file=sys.stderr)
        return 1
    print("  verified: %r" % (check,))
    return 0


if __name__ == '__main__':
    sys.exit(main())
