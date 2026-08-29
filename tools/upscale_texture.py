#!/usr/bin/env python3
"""
Upscale an Anvil BC-compressed texture and rewrite its header to match.

WHY THIS EXISTS
TextureQuality is hard-clamped to 2 by the engine - tested by arming every
quality key at 9 and reading back what the game wrote: every key came back at
the value it already held, so the settings were already at maximum and the INI
has no headroom at all. Raising the source texture resolution is the one route
that bypasses that cap, because it changes the asset rather than a setting.

WHAT CHANGES IN THE HEADER
Doubling the dimensions changes four things, and getting any of them wrong
produces a file that looks plausible and is malformed:

    offset 10   width          x2
    offset 14   height         x2
    offset 34   mip count      +1   (1024 has 11 mips, 2048 has 12)
    offset 86   payload size   recomputed, NOT scaled

The payload is NOT four times larger. A 1024 BC1 chain is 699,064 bytes and a
2048 chain is 2,796,216 - four times 699,064 is 2,796,256, so a naive x4 is
40 bytes too long. The extra mip levels are minimum-size blocks that do not
scale. Always recompute the chain.

The 61-byte trailer repeats the same descriptor and must be updated too:
trailer u32s hold format, 32, width, height, 1, mip count. Width, height and
mip count are at trailer offsets 8, 12 and 20.

There is no per-mip offset table - mip offsets are pure arithmetic from the
dimensions and bytes-per-block - which is what makes rewriting this safe.

ENCODER SCOPE
BC1 (format codes 2 and 3) and BC2 (code 4) are implemented. BC3 (code 5) is
not: its alpha block uses two endpoints and 3-bit indices, and exactly one
diffuse texture in the roster uses it, so it is skipped with a message rather
than half-implemented.

The BC1 encoder is a bounding-box range fit: endpoints from the per-block
channel min and max, then each pixel assigned to the nearest of the four
palette entries. That is not the best possible encoder - a principal-axis fit
would beat it on blocks with a strong colour gradient - but it is honest about
what it is and it is vectorised, which matters when a 2048 texture is 262,144
blocks.

No game assets are redistributed; this reads and writes your own installation.
"""
import argparse
import os
import struct
import sys

import numpy as np
from PIL import Image

HEADER_END = 90          # payload begins here
TRAILER = 61
OFF_W, OFF_H, OFF_FMT, OFF_MIPS, OFF_SIZE = 10, 14, 22, 34, 86
BPB = {2: 8, 3: 8, 4: 16, 5: 16}
NAME = {2: "BC1", 3: "BC1a", 4: "BC2", 5: "BC3"}


# ------------------------------------------------------------------ mips ----
def mip_chain(w, h, bpb):
    """(offset, w, h, bytes) per level, largest first, plus the total."""
    out, off = [], 0
    while True:
        n = max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * bpb
        out.append((off, w, h, n))
        off += n
        if w == 1 and h == 1:
            break
        w, h = max(1, w // 2), max(1, h // 2)
    return out, off


# ---------------------------------------------------------------- decode ----
def dec565_arr(v):
    r = ((v >> 11) & 0x1F).astype(np.uint16)
    g = ((v >> 5) & 0x3F).astype(np.uint16)
    b = (v & 0x1F).astype(np.uint16)
    return np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], -1).astype(np.uint8)


def decode_level(buf, w, h, code):
    """BC block data -> HxWx3 uint8. Alpha is ignored; only colour is resampled."""
    bpb = BPB[code]
    bw, bh = max(1, (w + 3) // 4), max(1, (h + 3) // 4)
    a = np.frombuffer(buf[:bw * bh * bpb], dtype=np.uint8).reshape(bh, bw, bpb)
    c = a[:, :, 8:] if bpb == 16 else a                      # colour half
    c0 = c[:, :, 0].astype(np.uint16) | (c[:, :, 1].astype(np.uint16) << 8)
    c1 = c[:, :, 2].astype(np.uint16) | (c[:, :, 3].astype(np.uint16) << 8)
    bits = (c[:, :, 4].astype(np.uint32) | (c[:, :, 5].astype(np.uint32) << 8) |
            (c[:, :, 6].astype(np.uint32) << 16) | (c[:, :, 7].astype(np.uint32) << 24))
    e0, e1 = dec565_arr(c0).astype(np.int16), dec565_arr(c1).astype(np.int16)
    pal = np.zeros((bh, bw, 4, 3), np.int16)
    pal[:, :, 0], pal[:, :, 1] = e0, e1
    four = (c0 > c1) | (bpb == 16)                           # BC2/BC3 always 4-colour
    p2 = np.where(four[..., None], (2 * e0 + e1) // 3, (e0 + e1) // 2)
    p3 = np.where(four[..., None], (e0 + 2 * e1) // 3, 0)
    pal[:, :, 2], pal[:, :, 3] = p2, p3
    idx = np.stack([(bits >> (2 * i)) & 3 for i in range(16)], -1)          # bh,bw,16
    px = np.take_along_axis(pal, idx[..., None].astype(np.intp), axis=2)    # bh,bw,16,3
    px = px.reshape(bh, bw, 4, 4, 3).transpose(0, 2, 1, 3, 4).reshape(bh * 4, bw * 4, 3)
    return px[:h, :w].astype(np.uint8)


# ---------------------------------------------------------------- encode ----
def enc565_arr(rgb):
    r = (rgb[..., 0].astype(np.uint16) >> 3) << 11
    g = (rgb[..., 1].astype(np.uint16) >> 2) << 5
    b = rgb[..., 2].astype(np.uint16) >> 3
    return (r | g | b).astype(np.uint16)


def encode_level(img, code):
    """HxWx3 uint8 -> BC blocks. Bounding-box range fit, vectorised."""
    bpb = BPB[code]
    h, w = img.shape[:2]
    bw, bh = max(1, (w + 3) // 4), max(1, (h + 3) // 4)
    pad = np.zeros((bh * 4, bw * 4, 3), np.uint8)
    pad[:h, :w] = img
    blocks = pad.reshape(bh, 4, bw, 4, 3).transpose(0, 2, 1, 3, 4).reshape(bh, bw, 16, 3)

    lo = blocks.min(axis=2).astype(np.int16)
    hi = blocks.max(axis=2).astype(np.int16)
    c0v, c1v = enc565_arr(hi), enc565_arr(lo)

    # BC1 needs c0 > c1 for the opaque 4-colour interpretation. Where the block
    # is flat the two collapse; nudging blue by one keeps the mode without
    # borrowing out of the green field.
    if bpb == 8:
        flat = c0v <= c1v
        c1v = np.where(flat & (c0v > 0), c0v - 1, c1v)
        c0v = np.where(flat & (c0v == 0), np.uint16(1), c0v)

    e0, e1 = dec565_arr(c0v).astype(np.int16), dec565_arr(c1v).astype(np.int16)
    pal = np.stack([e0, e1, (2 * e0 + e1) // 3, (e0 + 2 * e1) // 3], axis=2)  # bh,bw,4,3
    d = blocks[:, :, :, None, :].astype(np.int32) - pal[:, :, None, :, :].astype(np.int32)
    idx = (d * d).sum(-1).argmin(-1).astype(np.uint32)                        # bh,bw,16
    bits = np.zeros((bh, bw), np.uint32)
    for i in range(16):
        bits |= (idx[:, :, i] & 3) << (2 * i)

    out = np.zeros((bh, bw, bpb), np.uint8)
    cb = 8 if bpb == 16 else 0
    if bpb == 16:
        out[:, :, 0:8] = 0xFF                      # BC2: fully opaque explicit alpha
    out[:, :, cb + 0] = (c0v & 0xFF).astype(np.uint8)
    out[:, :, cb + 1] = (c0v >> 8).astype(np.uint8)
    out[:, :, cb + 2] = (c1v & 0xFF).astype(np.uint8)
    out[:, :, cb + 3] = (c1v >> 8).astype(np.uint8)
    for k in range(4):
        out[:, :, cb + 4 + k] = ((bits >> (8 * k)) & 0xFF).astype(np.uint8)
    return out.tobytes()


# ------------------------------------------------------------------ main ----
def main():
    ap = argparse.ArgumentParser(description="Upscale an Anvil BC TextureMap.")
    ap.add_argument("--texture", required=True)
    ap.add_argument("--scale", type=int, default=2, choices=(2, 4))
    ap.add_argument("--backup")
    ap.add_argument("--preview")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    raw = open(a.texture, "rb").read()
    w, h = struct.unpack_from("<I", raw, OFF_W)[0], struct.unpack_from("<I", raw, OFF_H)[0]
    code = struct.unpack_from("<I", raw, OFF_FMT)[0]
    mips = struct.unpack_from("<I", raw, OFF_MIPS)[0]
    size = struct.unpack_from("<I", raw, OFF_SIZE)[0]
    if code not in BPB:
        sys.exit("  unsupported format code %d" % code)
    if code == 5:
        print("  SKIPPED %s: BC3 alpha encoding is not implemented"
              % os.path.basename(a.texture))
        sys.exit(3)

    head = raw[:HEADER_END]
    payload = raw[HEADER_END:HEADER_END + size]
    tail = raw[HEADER_END + size:]
    print("  %s" % os.path.basename(a.texture))
    print("  %dx%d %s  %d mips  payload %d  trailer %d"
          % (w, h, NAME[code], mips, size, len(tail)))

    src, total = mip_chain(w, h, BPB[code])
    if total != size:
        sys.exit("  payload %d does not match computed chain %d" % (size, total))

    top = decode_level(payload[src[0][0]:src[0][0] + src[0][3]], w, h, code)
    nw, nh = w * a.scale, h * a.scale
    big = np.asarray(Image.fromarray(top).resize((nw, nh), Image.LANCZOS))

    dst, ntotal = mip_chain(nw, nh, BPB[code])
    print("  -> %dx%d  %d mips  payload %d  (x%.4f, not x%d)"
          % (nw, nh, len(dst), ntotal, ntotal / size, a.scale ** 2))

    if a.preview:
        Image.fromarray(top).resize((512, 512), Image.NEAREST).save(a.preview)

    buf = bytearray()
    cur = big
    for i, (off, mw, mh, n) in enumerate(dst):
        if i:
            cur = np.asarray(Image.fromarray(cur).resize((mw, mh), Image.LANCZOS))
        enc = encode_level(cur, code)
        assert len(enc) == n, "level %d: %d != %d" % (i, len(enc), n)
        buf += enc
    assert len(buf) == ntotal

    newhead = bytearray(head)
    struct.pack_into("<I", newhead, OFF_W, nw)
    struct.pack_into("<I", newhead, OFF_H, nh)
    struct.pack_into("<I", newhead, OFF_MIPS, len(dst))
    struct.pack_into("<I", newhead, OFF_SIZE, ntotal)
    # The trailer repeats the descriptor: width, height and mip count sit at
    # trailer offsets 8, 12 and 20.
    newtail = bytearray(tail)
    if len(newtail) >= 24:
        struct.pack_into("<I", newtail, 8, nw)
        struct.pack_into("<I", newtail, 12, nh)
        struct.pack_into("<I", newtail, 20, len(dst))

    if a.dry_run:
        print("  dry run - nothing written")
        return
    if a.backup and not os.path.isfile(a.backup):
        os.makedirs(os.path.dirname(a.backup), exist_ok=True)
        open(a.backup, "wb").write(raw)
        print("  backup -> %s" % a.backup)
    with open(a.texture, "wb") as f:
        f.write(newhead); f.write(buf); f.write(newtail)
    print("  written  %d bytes (was %d)" % (len(newhead) + len(buf) + len(newtail), len(raw)))


if __name__ == "__main__":
    main()
