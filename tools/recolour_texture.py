#!/usr/bin/env python3
"""
Recolour a block-compressed texture at the block level.

Accepts an Anvil .TextureMap or a plain .dds.

WHY THIS WORKS WITHOUT AN IMAGE EDITOR
--------------------------------------
Textures are stored as BC1/BC2/BC3 blocks. A BC1
block is two RGB565 endpoint colours plus 2 bits per pixel selecting a point
along the line between them. Recolour the *endpoints* and leave the index bits
alone, and every pixel shifts colour while all detail, shading, folds and edges
survive perfectly intact - the compression itself does the interpolation.

So there is no decode, no re-encode, and no quality loss beyond the endpoint
rounding that BC1 already imposed. It also means the File ID never changes,
because the file is edited in place rather than copied from another slot.

THE TRAP
--------
In BC1 the *ordering* of the two endpoints is the mode flag:

    c0 >  c1  -> 4 colours, fully opaque
    c0 <= c1  -> 3 colours + transparent

Recolouring can reverse that ordering, silently flipping the mode of a block
and scrambling every pixel in it. This tool detects the flip, swaps the
endpoints back and remaps the index bits to match, so the mode always survives.
(BC2 colour blocks are always 4-colour, so they need none of this.)

Every mip level is recoloured, not just the top one - otherwise a character
would change colour as the camera pulled away.

TEXTUREMAP HEADER (offsets, little-endian u32)
     2  File ID        10  width        14  height
    22  format  2=BC1 4=BC2            30  sRGB flag      34  mip count
    86  payload size   84  marker 0x1323                 151  payload begins

TEXTUREMAP LAYOUT
-----------------
    0..89     header, ending with the payload size at offset 86
    90        raw BC blocks begin, exactly <size> bytes
    then      a 61-byte trailer repeating format, dimensions and mip count

Because the trailer is always 61 bytes, filesize minus payload size is always
151 - which looks exactly like a 151-byte header and is not one. Reading from
151 shifts every block by 61 bytes: BC2 UI art still resembles itself, so the
mistake survives casual inspection, while a detailed BC1 texture becomes noise.
Verified by exporting BarberUp_DiffuseMap to DDS from AnvilToolkit: the DDS
payload is byte-for-byte identical to TextureMap[90:], all 699,064 bytes.

Every archive tested stores plain BC blocks - no compression, no swizzle - so
these files can be recoloured in place and repacked directly.

No game assets are distributed with this script - it reads and writes textures
inside your own installation, and always writes a backup first.
"""
import argparse
import os
import shutil
import struct
import sys

PAYLOAD_OFF = 90               # payload begins right after the size field
OFF_FID, OFF_W, OFF_H, OFF_FMT, OFF_SRGB, OFF_MIPS = 2, 10, 14, 22, 30, 34
OFF_PAYLOAD_SIZE = 86          # u32, matches len(file) - 151 on both archives
FMT_BC1, FMT_BC2 = 2, 4
BYTES_PER_BLOCK = {FMT_BC1: 8, FMT_BC2: 16}
FMT_NAME = {FMT_BC1: "BC1/DXT1", FMT_BC2: "BC2/DXT3"}

# Block kinds, by how the colour endpoints sit inside a block:
#   (bytes per block, offset of the colour half, does endpoint order pick mode)
KIND = {
    "bc1": (8, 0, True),       # c0>c1 = 4 colours, c0<=c1 = 3 colours + alpha
    "bc2": (16, 8, False),     # explicit alpha, colour half always 4-colour
    "bc3": (16, 8, False),     # interpolated alpha, colour half always 4-colour
}
KIND_FROM_FMT = {FMT_BC1: "bc1", FMT_BC2: "bc2"}
KIND_FROM_FOURCC = {b"DXT1": "bc1", b"DXT3": "bc2", b"DXT5": "bc3"}


# ---------------------------------------------------------------- colour ----
def dec565(v):
    r, g, b = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


def enc565(r, g, b):
    r = 0 if r < 0 else 255 if r > 255 else int(r)
    g = 0 if g < 0 else 255 if g > 255 else int(g)
    b = 0 if b < 0 else 255 if b > 255 else int(b)
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def ramp_at(stops, t):
    if t <= stops[0][0]:
        return stops[0][1]
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        if t <= p1:
            u = (t - p0) / (p1 - p0) if p1 > p0 else 0.0
            return tuple(c0[i] + (c1[i] - c0[i]) * u for i in range(3))
    return stops[-1][1]


# Two kinds of transform:
#   "ramp" - map luminance onto a colour ramp. Strong, stylised, two-tone.
#   "hue"  - rotate hue in HLS, keeping the original tonal range. Subtler.
SCHEMES = {
    "gold_black": dict(
        kind="ramp", black=0.06, white=0.86, gamma=1.25,
        stops=[(0.00, (10, 7, 2)), (0.32, (60, 40, 8)), (0.58, (150, 110, 28)),
               (0.80, (212, 172, 66)), (1.00, (255, 240, 185))],
        desc="Deep black shadows into rich gold highlights"),
    "crimson_black": dict(
        kind="ramp", black=0.06, white=0.88, gamma=1.25,
        stops=[(0.00, (8, 2, 3)), (0.32, (66, 10, 16)), (0.58, (146, 24, 34)),
               (0.80, (200, 62, 62)), (1.00, (255, 186, 176))],
        desc="Black into deep crimson"),
    "emerald_black": dict(
        kind="ramp", black=0.06, white=0.88, gamma=1.25,
        stops=[(0.00, (2, 8, 5)), (0.32, (10, 56, 32)), (0.58, (22, 128, 74)),
               (0.80, (74, 190, 126)), (1.00, (196, 250, 220))],
        desc="Black into emerald green"),
    "sapphire_black": dict(
        kind="ramp", black=0.06, white=0.88, gamma=1.25,
        stops=[(0.00, (2, 4, 10)), (0.32, (14, 28, 78)), (0.58, (34, 70, 164)),
               (0.80, (88, 134, 220)), (1.00, (198, 224, 255))],
        desc="Black into sapphire blue"),
    "bone_white": dict(
        kind="ramp", black=0.04, white=0.92, gamma=0.85,
        stops=[(0.00, (24, 22, 20)), (0.35, (120, 114, 104)),
               (0.70, (206, 199, 184)), (1.00, (255, 253, 246))],
        desc="Bleached bone white"),
    "desaturate": dict(kind="hue", rotate=0.0, sat=0.0,
                       desc="Greyscale, tones untouched"),
}


def measure_levels(payload, kind, lo=0.02, hi=0.98):
    """Find the texture's real tonal range, as (black, white) in 0..1.

    A ramp keyed to a fixed 0..1 range washes out on a dark texture and blows
    out on a bright one. Reading the actual endpoint luminance histogram makes
    one scheme land correctly on any persona.
    """
    step, cbase, _ = KIND[kind]
    hist = [0] * 256
    for off in range(cbase, len(payload) - 7, step):
        for e in (off, off + 2):
            r, g, b = dec565(payload[e] | (payload[e + 1] << 8))
            hist[int(0.299 * r + 0.587 * g + 0.114 * b)] += 1
    total = sum(hist)
    if not total:
        return 0.0, 1.0
    acc, black, white = 0, 0, 255
    for i, c in enumerate(hist):
        acc += c
        if acc >= total * lo:
            black = i
            break
    acc = 0
    for i, c in enumerate(hist):
        acc += c
        if acc >= total * hi:
            white = i
            break
    if white - black < 8:                    # degenerate, fall back to full range
        black, white = 0, 255
    return black / 255.0, white / 255.0


def build_lut(scheme, strength=1.0, levels=None):
    """Map every possible RGB565 endpoint to its recoloured value."""
    s = SCHEMES[scheme]
    lut = [0] * 65536
    if s["kind"] == "ramp":
        blk, wht, gam = s["black"], s["white"], s["gamma"]
        if levels:
            blk, wht = levels
        span = max(1e-6, wht - blk)
        for v in range(65536):
            r, g, b = dec565(v)
            lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            t = (lum - blk) / span
            t = 0.0 if t < 0.0 else 1.0 if t > 1.0 else t
            nr, ng, nb = ramp_at(s["stops"], t ** gam)
            if strength < 1.0:
                nr, ng, nb = (r + (nr - r) * strength,
                              g + (ng - g) * strength,
                              b + (nb - b) * strength)
            lut[v] = enc565(nr, ng, nb)
    else:
        import colorsys
        rot, sat = s["rotate"] / 360.0, s["sat"]
        for v in range(65536):
            r, g, b = dec565(v)
            h, l, sa = colorsys.rgb_to_hls(r / 255.0, g / 255.0, b / 255.0)
            nr, ng, nb = colorsys.hls_to_rgb((h + rot) % 1.0, l, sa * sat)
            nr, ng, nb = nr * 255.0, ng * 255.0, nb * 255.0
            if strength < 1.0:
                nr, ng, nb = (r + (nr - r) * strength,
                              g + (ng - g) * strength,
                              b + (nb - b) * strength)
            lut[v] = enc565(nr, ng, nb)
    return lut


# 3-colour mode index remap for one byte (4 pixels): 0<->1, 2 and 3 unchanged.
LUT3 = bytearray(256)
for _b in range(256):
    _o = 0
    for _k in range(4):
        _v = (_b >> (2 * _k)) & 3
        _o |= (1 if _v == 0 else 0 if _v == 1 else _v) << (2 * _k)
    LUT3[_b] = _o


GRID_COLS = GRID_ROWS = 8


def parse_keep(spec):
    """Regions to leave at their original colours.

    A character texture is an atlas - clothing, straps, boots and often props
    or weapon parts share one sheet. Accepts grid cells (A1, D3) matching the
    --grid overlay, or explicit rects as x0:y0:x1:y1 in 0..1.
    """
    rects = []
    for tok in (t.strip() for t in spec.split(",") if t.strip()):
        if ":" in tok:
            v = [float(x) for x in tok.split(":")]
            if len(v) != 4:
                sys.exit("bad --keep rect %r, want x0:y0:x1:y1" % tok)
            rects.append(tuple(v))
            continue
        col = tok[0].upper()
        if not tok[1:].isdigit() or not ("A" <= col < chr(ord("A") + GRID_COLS)):
            sys.exit("bad --keep cell %r, want A1..%s%d" % (
                tok, chr(ord("A") + GRID_COLS - 1), GRID_ROWS))
        cx, ry = ord(col) - 65, int(tok[1:]) - 1
        if not (0 <= ry < GRID_ROWS):
            sys.exit("bad --keep row in %r" % tok)
        rects.append((cx / GRID_COLS, ry / GRID_ROWS,
                      (cx + 1) / GRID_COLS, (ry + 1) / GRID_ROWS))
    return rects


_SATLUT = None


def sat_lut():
    """Saturation (max channel minus min channel, 0..255) of every RGB565."""
    global _SATLUT
    if _SATLUT is None:
        _SATLUT = [0] * 65536
        for v in range(65536):
            r, g, b = dec565(v)
            _SATLUT[v] = max(r, g, b) - min(r, g, b)
    return _SATLUT


def recolour(payload, kind, lut, w, h, mips, keep=(), sat_max=None):
    """Transform every block of every mip level. Returns (data, stats).

    sat_max leaves already-colourful blocks alone. On a character atlas the
    cloth is near-grey and the leather, wood and metal are strongly coloured,
    so one threshold separates the garment from its fittings without having to
    name regions by hand.
    """
    data = bytearray(payload)
    step, cbase, ordered = KIND[kind]
    sl = sat_lut() if sat_max is not None else None
    swaps = flats = kept = done = 0
    for mo, mw, mh, msz in mip_layout(w, h, step, mips):
        bw, bh = max(1, (mw + 3) // 4), max(1, (mh + 3) // 4)
        for by in range(bh):
            cy = (by + 0.5) / bh
            for bx in range(bw):
                off = mo + (by * bw + bx) * step + cbase
                if off + 8 > len(data):
                    continue
                if keep:
                    cx = (bx + 0.5) / bw
                    if any(x0 <= cx <= x1 and y0 <= cy <= y1
                           for x0, y0, x1, y1 in keep):
                        kept += 1
                        continue
                if sl is not None:
                    if (sl[data[off] | (data[off + 1] << 8)] > sat_max or
                            sl[data[off + 2] | (data[off + 3] << 8)] > sat_max):
                        kept += 1
                        continue
                done += 1
                s = _block(data, off, lut, ordered)
                swaps += s[0]
                flats += s[1]
    return data, dict(blocks=done + kept, changed=done, kept=kept,
                      swaps=swaps, flats=flats)


def _block(data, off, lut, ordered):
        swaps = flats = 0
        c0 = data[off] | (data[off + 1] << 8)
        c1 = data[off + 2] | (data[off + 3] << 8)
        n0, n1 = lut[c0], lut[c1]
        if ordered:
            if c0 > c1:                        # was 4-colour opaque
                if n0 == n1:                   # would collapse into 3-colour
                    # Nudge by one step of BLUE, the low 5 bits. Touching the
                    # packed value directly would borrow out of the blue field
                    # and wrap it to maximum - which paints bright blue speckle
                    # across any scheme whose shadows have little blue in them.
                    if n1 & 0x1F:
                        n1 -= 1                # blue b -> b-1, no borrow
                    else:
                        n0 += 1                # blue 0 -> 1, no carry
                    flats += 1
                elif n0 < n1:                  # ordering reversed - undo it
                    n0, n1 = n1, n0
                    for k in range(4, 8):
                        data[off + k] ^= 0x55  # 0<->1, 2<->3
                    swaps += 1
            else:                              # was 3-colour punch-through
                if n0 > n1:
                    n0, n1 = n1, n0
                    for k in range(4, 8):
                        data[off + k] = LUT3[data[off + k]]
                    swaps += 1
        data[off] = n0 & 0xFF
        data[off + 1] = n0 >> 8
        data[off + 2] = n1 & 0xFF
        data[off + 3] = n1 >> 8
        return swaps, flats


# --------------------------------------------------------------- preview ----
def mip_layout(w, h, bpb, mips):
    out, o = [], 0
    for i in range(mips):
        mw, mh = max(1, w >> i), max(1, h >> i)
        sz = max(1, (mw + 3) // 4) * max(1, (mh + 3) // 4) * bpb
        out.append((o, mw, mh, sz))
        o += sz
    return out


def decode(payload, w, h, kind):
    step, cbase, ordered = KIND[kind]
    img = bytearray(w * h * 3)
    off = 0
    for by in range((h + 3) // 4):
        for bx in range((w + 3) // 4):
            c = off + cbase
            c0 = payload[c] | (payload[c + 1] << 8)
            c1 = payload[c + 2] | (payload[c + 3] << 8)
            bits = int.from_bytes(payload[c + 4:c + 8], "little")
            e0, e1 = dec565(c0), dec565(c1)
            if c0 > c1 or not ordered:
                pal = (e0, e1,
                       tuple((2 * e0[i] + e1[i]) // 3 for i in range(3)),
                       tuple((e0[i] + 2 * e1[i]) // 3 for i in range(3)))
            else:
                pal = (e0, e1,
                       tuple((e0[i] + e1[i]) // 2 for i in range(3)),
                       (0, 0, 0))
            for py in range(4):
                yy = by * 4 + py
                if yy >= h:
                    break
                row = yy * w
                for px in range(4):
                    xx = bx * 4 + px
                    if xx >= w:
                        break
                    p = pal[(bits >> (2 * (py * 4 + px))) & 3]
                    o3 = (row + xx) * 3
                    img[o3], img[o3 + 1], img[o3 + 2] = p
            off += step
    return bytes(img)


def write_preview(path, before, after, w, h, kind, mips, level):
    from PIL import Image
    bpb = KIND[kind][0]
    level = max(0, min(level, mips - 1))
    o, mw, mh, sz = mip_layout(w, h, bpb, mips)[level]
    left = Image.frombytes("RGB", (mw, mh), decode(before[o:o + sz], mw, mh, kind))
    right = Image.frombytes("RGB", (mw, mh), decode(after[o:o + sz], mw, mh, kind))
    gap = 12
    canvas = Image.new("RGB", (mw * 2 + gap, mh), (24, 24, 26))
    canvas.paste(left, (0, 0))
    canvas.paste(right, (mw + gap, 0))
    canvas.save(path)
    return mw, mh


def write_grid(path, payload, w, h, kind, mips, level, keep=()):
    """Render the atlas with a labelled A1..H8 grid, for choosing --keep cells."""
    from PIL import Image, ImageDraw
    bpb = KIND[kind][0]
    level = max(0, min(level, mips - 1))
    o, mw, mh, sz = mip_layout(w, h, bpb, mips)[level]
    img = Image.frombytes("RGB", (mw, mh), decode(payload[o:o + sz], mw, mh, kind))
    img = img.resize((768, 768), Image.LANCZOS).convert("RGB")
    d = ImageDraw.Draw(img, "RGBA")
    cw, ch = 768 / GRID_COLS, 768 / GRID_ROWS
    for x0, y0, x1, y1 in keep:                 # shade protected regions
        d.rectangle([x0 * 768, y0 * 768, x1 * 768, y1 * 768], fill=(0, 200, 255, 70))
    for i in range(1, GRID_COLS):
        d.line([(i * cw, 0), (i * cw, 768)], fill=(255, 60, 60, 200), width=1)
    for i in range(1, GRID_ROWS):
        d.line([(0, i * ch), (768, i * ch)], fill=(255, 60, 60, 200), width=1)
    for r in range(GRID_ROWS):
        for c in range(GRID_COLS):
            lbl = "%s%d" % (chr(65 + c), r + 1)
            px, py = c * cw + 3, r * ch + 2
            d.text((px + 1, py + 1), lbl, fill=(0, 0, 0, 220))
            d.text((px, py), lbl, fill=(255, 255, 0, 255))
    img.save(path)
    return path


# ------------------------------------------------------------------ load ----
def load(raw, name):
    """Accept either an Anvil .TextureMap or a plain .dds.

    Returns (head, payload, width, height, kind, mips, label).

    Anvil TextureMaps in DataPC_extra.forge hold raw blocks. The ones in
    DataPC.forge do not - same container, same declared size, but the payload
    is reordered, so it must be exported to DDS by AnvilToolkit first.
    """
    if raw[:4] == b"DDS ":
        h, w = struct.unpack_from("<I", raw, 12)[0], struct.unpack_from("<I", raw, 16)[0]
        mips = max(1, struct.unpack_from("<I", raw, 28)[0])
        fourcc = raw[84:88]
        if fourcc == b"DX10":
            dxgi = struct.unpack_from("<I", raw, 128)[0]
            kind = {70: "bc1", 71: "bc1", 72: "bc1",
                    73: "bc2", 74: "bc2", 75: "bc2",
                    76: "bc3", 77: "bc3", 78: "bc3"}.get(dxgi)
            if not kind:
                sys.exit("DDS: unsupported DXGI format %d" % dxgi)
            off = 148
        else:
            kind = KIND_FROM_FOURCC.get(fourcc)
            if not kind:
                sys.exit("DDS: unsupported FourCC %r" % fourcc)
            off = 128
        return raw[:off], raw[off:], b"", w, h, kind, mips, "DDS %s" % kind.upper()

    fid, w, h = (struct.unpack_from("<I", raw, x)[0] for x in (OFF_FID, OFF_W, OFF_H))
    fmt, mips = (struct.unpack_from("<I", raw, x)[0] for x in (OFF_FMT, OFF_MIPS))
    kind = KIND_FROM_FMT.get(fmt)
    if not kind:
        sys.exit("TextureMap: unsupported format code %d (expected 2=BC1 or 4=BC2)" % fmt)
    size = struct.unpack_from("<I", raw, OFF_PAYLOAD_SIZE)[0]
    if not 0 < size <= len(raw) - PAYLOAD_OFF:
        sys.exit("TextureMap: bad payload size %d in a %d byte file" % (size, len(raw)))
    end = PAYLOAD_OFF + size
    return (raw[:PAYLOAD_OFF], raw[PAYLOAD_OFF:end], raw[end:], w, h, kind, max(1, mips),
            "TextureMap %s  File ID 0x%08X" % (FMT_NAME[fmt], fid))


# ------------------------------------------------------------------ main ----
def main():
    ap = argparse.ArgumentParser(
        description="Recolour an Anvil BC1/BC2 TextureMap in place.")
    ap.add_argument("--texture", required=True)
    ap.add_argument("--scheme", default="gold_black", choices=sorted(SCHEMES))
    ap.add_argument("--strength", type=float, default=1.0,
                    help="0.0-1.0 blend towards the scheme")
    ap.add_argument("--backup", help="where to keep the pristine original")
    ap.add_argument("--preview", help="write a before/after PNG here")
    ap.add_argument("--preview-mip", type=int, default=1)
    ap.add_argument("--grid", help="write a labelled A1..H8 overlay for picking --keep cells")
    ap.add_argument("--keep", default="", help="regions to leave untouched: cells like D1,E1 or rects x0:y0:x1:y1")
    ap.add_argument("--max-saturation", type=int, default=None, metavar="N",
                    help="only recolour blocks duller than N (0-255). Keeps leather, "
                         "wood and metal while recolouring near-grey cloth. Try 40.")
    ap.add_argument("--levels", help="force a tonal range as black:white, e.g. 0.00:0.58. Use the SAME value on every texture of one outfit so the halves match.")
    ap.add_argument("--no-autolevel", action="store_true",
                    help="use the scheme fixed tonal range instead of measuring the texture")
    ap.add_argument("--dry-run", action="store_true",
                    help="preview only, do not touch the texture")
    ap.add_argument("--restore", action="store_true",
                    help="copy the backup back over the texture")
    a = ap.parse_args()

    if not os.path.isfile(a.texture):
        sys.exit("not found: " + a.texture)

    if a.restore:
        if not a.backup or not os.path.isfile(a.backup):
            sys.exit("--restore needs an existing --backup")
        shutil.copyfile(a.backup, a.texture)
        print("  restored  " + os.path.basename(a.texture) + "  <-  backup")
        return

    raw = open(a.texture, "rb").read()
    head, payload, tail, w, h, kind, mips, label = load(raw, a.texture)
    expect = sum(s for _, _, _, s in mip_layout(w, h, KIND[kind][0], mips))
    print("  %s" % os.path.basename(a.texture))
    print("  %dx%d  %s  %d mips" % (w, h, label, mips))
    if expect != len(payload):
        print("  ! payload %d != expected %d; proceeding on raw blocks"
              % (len(payload), expect))

    # Back up before the first modification, and never overwrite a backup.
    if a.backup:
        if os.path.isfile(a.backup):
            # Always work from pristine, so schemes never stack - including in
            # a dry run, whose whole point is to preview against the original.
            payload = load(open(a.backup, "rb").read(), a.backup)[1]
            print("  source: the pristine backup, so schemes do not stack")
        elif not a.dry_run:
            os.makedirs(os.path.dirname(a.backup), exist_ok=True)
            shutil.copyfile(a.texture, a.backup)
            print("  backup -> %s" % a.backup)

    keep = parse_keep(a.keep)
    if a.grid:
        write_grid(a.grid, payload, w, h, kind, mips, a.preview_mip, keep)
        print("  grid -> %s" % a.grid)

    levels = None
    if a.levels:
        try:
            levels = tuple(float(x) for x in a.levels.split(":"))
            if len(levels) != 2 or not 0.0 <= levels[0] < levels[1] <= 1.0:
                raise ValueError
        except ValueError:
            sys.exit("bad --levels %r, want black:white with 0 <= black < white <= 1"
                     % a.levels)
        print("  levels: black %.2f  white %.2f (forced)" % levels)
    elif not a.no_autolevel and SCHEMES[a.scheme]["kind"] == "ramp":
        levels = measure_levels(payload, kind)
        print("  auto-levels: black %.2f  white %.2f (measured, pass --levels %.2f:%.2f "
              "to match other textures)" % (levels + levels))
    lut = build_lut(a.scheme, max(0.0, min(1.0, a.strength)), levels)
    new, st = recolour(payload, kind, lut, w, h, mips, keep, a.max_saturation)
    print("  scheme '%s' - %s" % (a.scheme, SCHEMES[a.scheme]["desc"]))
    print("  %d blocks: %d recoloured, %d kept original"
          % (st["blocks"], st["changed"], st["kept"]))
    print("  %d endpoint swaps, %d flattened" % (st["swaps"], st["flats"]))

    if a.preview:
        mw, mh = write_preview(a.preview, payload, new, w, h, kind, mips, a.preview_mip)
        print("  preview -> %s  (%dx%d each, before | after)" % (a.preview, mw, mh))

    if a.dry_run:
        print("  dry run - texture not modified")
        return

    with open(a.texture, "wb") as f:
        f.write(head)
        f.write(new)
        f.write(tail)
    print("  written  (%d bytes, header/trailer/File ID unchanged)"
          % (len(head) + len(new) + len(tail)))


if __name__ == "__main__":
    main()
