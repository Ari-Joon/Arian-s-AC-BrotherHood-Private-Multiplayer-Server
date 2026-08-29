"""BC1/BC2/BC3 decode and encode, vectorised over whole images with numpy.

Written for Assassin's Creed Brotherhood .TextureMap payloads, which are plain
BC blocks with no swizzle - see re/FINDINGS.md. Format codes:

    2, 3 -> 8 bytes/block  (BC1 / DXT1; 3 is a DXT1a variant)
    4    -> 16 bytes/block (BC2 / DXT3, 4-bit explicit alpha)
    5    -> 16 bytes/block (BC3 / DXT5, interpolated alpha)

Decode returns RGBA uint8 (h, w, 4). Encode takes the same and returns bytes.
"""
import numpy as np

BLOCK_BYTES = {2: 8, 3: 8, 4: 16, 5: 16}


# --------------------------------------------------------------------- shared
def _blocks_of(img):
    """(h,w,4) -> (nblocks, 16, 4) in row-major block order, 4x4 within."""
    h, w, _ = img.shape
    bh, bw = h // 4, w // 4
    b = img.reshape(bh, 4, bw, 4, 4).transpose(0, 2, 1, 3, 4)
    return b.reshape(bh * bw, 16, 4), bh, bw


def _unblock(blocks, bh, bw):
    """(nblocks,16,4) -> (bh*4, bw*4, 4)."""
    b = blocks.reshape(bh, bw, 4, 4, 4).transpose(0, 2, 1, 3, 4)
    return b.reshape(bh * 4, bw * 4, 4)


def _rgb565_unpack(v):
    """uint16 array -> (n,3) uint8, replicating high bits like the hardware."""
    r = ((v >> 11) & 0x1F).astype(np.uint16)
    g = ((v >> 5) & 0x3F).astype(np.uint16)
    b = (v & 0x1F).astype(np.uint16)
    r = (r << 3) | (r >> 2)
    g = (g << 2) | (g >> 4)
    b = (b << 3) | (b >> 2)
    return np.stack([r, g, b], -1).astype(np.uint8)


def _rgb565_pack(rgb):
    """(n,3) float/int -> uint16."""
    c = np.clip(np.rint(rgb), 0, 255).astype(np.uint16)
    return ((c[..., 0] >> 3) << 11) | ((c[..., 1] >> 2) << 5) | (c[..., 2] >> 3)


# --------------------------------------------------------------------- decode
def _decode_colour(raw, n, always_four=False):
    """Shared BC1 colour half. raw is (n,8) uint8. Returns (n,16,4) uint8.

    always_four: BC2 and BC3 carry alpha separately and their colour half is
    ALWAYS the 4-colour interpretation, whatever the c0/c1 ordering says. Only
    BC1 uses the ordering to select 3-colour + punch-through.
    """
    c0 = raw[:, 0].astype(np.uint16) | (raw[:, 1].astype(np.uint16) << 8)
    c1 = raw[:, 2].astype(np.uint16) | (raw[:, 3].astype(np.uint16) << 8)
    bits = (raw[:, 4].astype(np.uint32)
            | (raw[:, 5].astype(np.uint32) << 8)
            | (raw[:, 6].astype(np.uint32) << 16)
            | (raw[:, 7].astype(np.uint32) << 24))

    e0 = _rgb565_unpack(c0).astype(np.uint16)
    e1 = _rgb565_unpack(c1).astype(np.uint16)
    four = np.ones((n, 1), bool) if always_four else (c0 > c1)[:, None]

    # 4-colour: 2/3-1/3 mixes. 3-colour: midpoint, then transparent black.
    c2 = np.where(four, (2 * e0 + e1) // 3, (e0 + e1) // 2)
    c3 = np.where(four, (e0 + 2 * e1) // 3, 0)

    pal = np.stack([e0, e1, c2, c3], 1).astype(np.uint8)          # (n,4,3)
    alpha = np.ones((n, 4), np.uint8) * 255
    alpha[:, 3] = np.where(four[:, 0], 255, 0)                     # c3 punch-through

    idx = np.empty((n, 16), np.uint8)
    for i in range(16):
        idx[:, i] = ((bits >> (2 * i)) & 3).astype(np.uint8)

    rows = np.arange(n)[:, None]
    rgb = pal[rows, idx]                                            # (n,16,3)
    a = alpha[rows, idx]                                            # (n,16)
    return np.concatenate([rgb, a[..., None]], -1)


def _decode_bc3_alpha(raw, n):
    """DXT5 alpha half: raw is (n,8). Returns (n,16) uint8."""
    a0 = raw[:, 0].astype(np.int32)
    a1 = raw[:, 1].astype(np.int32)
    bits = np.zeros(n, np.uint64)
    for i in range(6):
        bits |= raw[:, 2 + i].astype(np.uint64) << np.uint64(8 * i)

    pal = np.zeros((n, 8), np.int32)
    pal[:, 0] = a0
    pal[:, 1] = a1
    big = a0 > a1
    for i in range(1, 7):                       # 8-value mode
        pal[:, i + 1] = np.where(big, ((7 - i) * a0 + i * a1) // 7, 0)
    for i in range(1, 5):                       # 6-value mode overwrite
        pal[:, i + 1] = np.where(big, pal[:, i + 1], ((5 - i) * a0 + i * a1) // 5)
    pal[:, 6] = np.where(big, pal[:, 6], 0)
    pal[:, 7] = np.where(big, pal[:, 7], 255)

    idx = np.empty((n, 16), np.uint8)
    for i in range(16):
        idx[:, i] = ((bits >> np.uint64(3 * i)) & np.uint64(7)).astype(np.uint8)
    return pal[np.arange(n)[:, None], idx].astype(np.uint8)


def decode(data, w, h, fmt):
    bb = BLOCK_BYTES[fmt]
    bw, bh = max(1, (w + 3) // 4), max(1, (h + 3) // 4)
    n = bw * bh
    raw = np.frombuffer(data[:n * bb], np.uint8).reshape(n, bb)

    if bb == 8:
        px = _decode_colour(raw, n)
    else:
        px = _decode_colour(raw[:, 8:], n, always_four=True)
        if fmt == 4:                                   # BC2: 4-bit explicit
            a = np.empty((n, 16), np.uint8)
            for i in range(16):
                byte = raw[:, i // 2]
                nib = np.where(i % 2 == 0, byte & 0xF, byte >> 4)
                a[:, i] = (nib << 4) | nib
            px[..., 3] = a
        else:                                          # BC3
            px[..., 3] = _decode_bc3_alpha(raw[:, :8], n)

    img = _unblock(px, bh, bw)
    return img[:h, :w]


# --------------------------------------------------------------------- encode
def _fit_endpoints(blocks_rgb, weights=None):
    """Principal-axis endpoint fit. blocks_rgb (n,16,3) float -> two (n,3)."""
    if weights is None:
        mean = blocks_rgb.mean(1, keepdims=True)
    else:
        w = weights[..., None]
        tot = np.maximum(w.sum(1, keepdims=True), 1e-6)
        mean = (blocks_rgb * w).sum(1, keepdims=True) / tot
    d = blocks_rgb - mean
    if weights is not None:
        d = d * weights[..., None]

    # Power iteration on the 3x3 covariance, batched.
    cov = np.einsum('nij,nik->njk', d, d)
    v = np.array([0.9, 1.0, 0.7], np.float64)
    v = np.broadcast_to(v, (blocks_rgb.shape[0], 3)).copy()
    for _ in range(8):
        v = np.einsum('njk,nk->nj', cov, v)
        norm = np.linalg.norm(v, axis=1, keepdims=True)
        flat = norm[:, 0] < 1e-12
        v = np.where(flat[:, None], np.array([1.0, 0.0, 0.0]), v / np.maximum(norm, 1e-12))

    t = np.einsum('nij,nj->ni', blocks_rgb - mean, v)
    lo = t.min(1)[:, None]
    hi = t.max(1)[:, None]
    e0 = mean[:, 0, :] + v * hi
    e1 = mean[:, 0, :] + v * lo
    return np.clip(e0, 0, 255), np.clip(e1, 0, 255)


def _bc1_indices(blocks_rgb, e0q, e1q, four_colour):
    """Nearest-palette index per texel. Endpoints are already 565-quantised."""
    n = blocks_rgb.shape[0]
    a = e0q.astype(np.int32)
    b = e1q.astype(np.int32)
    if four_colour:
        c2 = (2 * a + b) // 3
        c3 = (a + 2 * b) // 3
    else:
        c2 = (a + b) // 2
        c3 = np.zeros_like(a)
    pal = np.stack([a, b, c2, c3], 1).astype(np.float64)     # (n,4,3)
    diff = blocks_rgb[:, :, None, :] - pal[:, None, :, :]    # (n,16,4,3)
    return np.argmin((diff * diff).sum(-1), -1).astype(np.uint8), pal


def _pack_bc1(c0, c1, idx):
    n = c0.shape[0]
    out = np.empty((n, 8), np.uint8)
    out[:, 0] = c0 & 0xFF
    out[:, 1] = c0 >> 8
    out[:, 2] = c1 & 0xFF
    out[:, 3] = c1 >> 8
    bits = np.zeros(n, np.uint32)
    for i in range(16):
        bits |= idx[:, i].astype(np.uint32) << np.uint32(2 * i)
    out[:, 4] = bits & 0xFF
    out[:, 5] = (bits >> 8) & 0xFF
    out[:, 6] = (bits >> 16) & 0xFF
    out[:, 7] = (bits >> 24) & 0xFF
    return out


def _encode_colour(blocks, punchthrough):
    """blocks (n,16,4) uint8 -> (n,8) uint8 BC1 colour half.

    punchthrough: allow the 3-colour mode for blocks containing alpha<128.
    Without it every block is forced to 4-colour, which is what BC2/BC3 need
    because their colour half must always use the 4-colour interpretation.
    """
    n = blocks.shape[0]
    rgb = blocks[..., :3].astype(np.float64)

    if punchthrough:
        opaque = blocks[..., 3] >= 128
        needs3 = ~opaque.all(1)
        wt = opaque.astype(np.float64)
        # A fully transparent block has no colour worth fitting.
        wt = np.where(wt.sum(1, keepdims=True) > 0, wt, 1.0)
    else:
        needs3 = np.zeros(n, bool)
        wt = None

    e0, e1 = _fit_endpoints(rgb, wt)
    c0 = _rgb565_pack(e0)
    c1 = _rgb565_pack(e1)

    # Mode is carried by the c0/c1 ordering, so fix the order to match intent.
    want4 = ~needs3
    swap = np.where(want4, c0 <= c1, c0 > c1)
    c0n = np.where(swap, c1, c0)
    c1n = np.where(swap, c0, c1)
    # Degenerate block: both endpoints identical. 4-colour needs c0>c1, so nudge.
    same = c0n == c1n
    if same.any():
        c0i = c0n.astype(np.int32)
        c1i = c1n.astype(np.int32)
        # 4-colour needs c0 > c1; 3-colour needs c0 <= c1. Move whichever
        # endpoint keeps the block inside its intended mode.
        fix4_hi = np.where(c0i > 0, c0i, 1)
        fix4_lo = np.where(c0i > 0, c0i - 1, 0)
        fix3_hi = np.where(c1i < 0xFFFF, c1i + 1, 0xFFFF)
        fix3_lo = np.where(c1i < 0xFFFF, c1i, 0xFFFE)
        m4 = same & want4
        m3 = same & ~want4
        c0n = np.where(m4, fix4_hi, np.where(m3, fix3_lo, c0i)).astype(np.uint16)
        c1n = np.where(m4, fix4_lo, np.where(m3, fix3_hi, c1i)).astype(np.uint16)

    e0q = _rgb565_unpack(c0n)
    e1q = _rgb565_unpack(c1n)

    idx4, _ = _bc1_indices(rgb, e0q, e1q, True)
    idx3, _ = _bc1_indices(rgb, e0q, e1q, False)
    idx = np.where(want4[:, None], idx4, idx3)
    if punchthrough:
        # index 3 is the transparent slot in 3-colour mode
        transparent = blocks[..., 3] < 128
        idx = np.where(needs3[:, None] & transparent, 3, idx)
    return _pack_bc1(c0n, c1n, idx)


def _encode_bc3_alpha(a):
    """a (n,16) uint8 -> (n,8) uint8. 8-value mode only."""
    n = a.shape[0]
    a0 = a.max(1).astype(np.int32)
    a1 = a.min(1).astype(np.int32)
    same = a0 == a1
    a1 = np.where(same, np.maximum(a0 - 1, 0), a1)      # keep a0>a1 for 8-value

    pal = np.zeros((n, 8), np.float64)
    pal[:, 0] = a0
    pal[:, 1] = a1
    for i in range(1, 7):
        pal[:, i + 1] = ((7 - i) * a0 + i * a1) / 7.0

    d = np.abs(a[:, :, None].astype(np.float64) - pal[:, None, :])
    idx = np.argmin(d, -1).astype(np.uint64)

    out = np.zeros((n, 8), np.uint8)
    out[:, 0] = a0.astype(np.uint8)
    out[:, 1] = a1.astype(np.uint8)
    bits = np.zeros(n, np.uint64)
    for i in range(16):
        bits |= idx[:, i] << np.uint64(3 * i)
    for i in range(6):
        out[:, 2 + i] = ((bits >> np.uint64(8 * i)) & np.uint64(0xFF)).astype(np.uint8)
    return out


def _encode_bc2_alpha(a):
    n = a.shape[0]
    nib = (a.astype(np.uint16) * 15 + 127) // 255
    out = np.zeros((n, 8), np.uint8)
    for i in range(0, 16, 2):
        out[:, i // 2] = (nib[:, i] | (nib[:, i + 1] << 4)).astype(np.uint8)
    return out


def encode(img, fmt):
    h, w, _ = img.shape
    ph, pw = ((h + 3) // 4) * 4, ((w + 3) // 4) * 4
    if (ph, pw) != (h, w):                    # edge-replicate to a block multiple
        pad = np.zeros((ph, pw, 4), np.uint8)
        pad[:h, :w] = img
        if pw > w: pad[:h, w:] = img[:, -1:]
        if ph > h: pad[h:, :] = pad[h - 1:h, :]
        img = pad

    blocks, bh, bw = _blocks_of(img)
    if fmt in (2, 3):
        return _encode_colour(blocks, punchthrough=True).tobytes()
    colour = _encode_colour(blocks, punchthrough=False)
    alpha = _encode_bc2_alpha(blocks[..., 3]) if fmt == 4 else _encode_bc3_alpha(blocks[..., 3])
    return np.concatenate([alpha, colour], 1).tobytes()
