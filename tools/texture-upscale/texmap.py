"""Read and rewrite Assassin's Creed Brotherhood .TextureMap files.

Layout, confirmed against all 192 multiplayer textures - the declared payload
size equals the computed mip-chain size for every one of them:

      0   u16  0x0100
      2   u32  File ID              unique per texture, the game binds by this
      6   u32  0xa2b7e917           constant
     10   u32  width
     14   u32  height
     18   u32  depth = 1
     22   u32  format               2,3 = BC1 (8 b/block); 4 = BC2, 5 = BC3 (16)
     26   u32  texture type         1 = 2D (191 files), 2 = cube (1 file, 6 faces)
     30   u32  sRGB flag
     34   u32  mip count
     38.. 46  zero
     50.. 58  1, 1, 1
     62   u32  varies 0/1/2/10
     66   u32  1 or 4
     70   u32  256 or 65792
     74.. 78  zero
     82   u16  0x7fe9
     84   u16  0x1323               marker
     86   u32  payload size N
     90        payload: raw BC blocks, every mip level, largest first
   90+N        61-byte trailer

The trailer repeats the geometry: u32 2, u32 32, width, height, depth, mips,
format, then constants. There is NO per-mip offset table anywhere, so changing
the resolution means rewriting exactly four header fields and three trailer
fields and nothing else.
"""
import struct

BLOCK_BYTES = {2: 8, 3: 8, 4: 16, 5: 16}

# Format 0 is NOT block-compressed: it is uncompressed 32-bit RGBA, 4 bytes per
# texel. Found on 28_-_AC2MP_Radar_2ndTarget_01_DiffuseMap in a skins DLC forge,
# 128x128 with 8 mips declaring 87,380 bytes - which is exactly
# 65536+16384+4096+1024+256+64+16+4, the uncompressed chain. Reading it as a BC
# format gives 10,936 or 21,872 and nothing lines up, which is how it was found.
# Deliberately unsupported rather than silently mishandled.
UNCOMPRESSED = {0: 4}
TRAILER_LEN = 61
HEADER_LEN = 90

H_WIDTH, H_HEIGHT, H_TYPE, H_FORMAT, H_MIPS, H_PAYLOAD = 10, 14, 26, 22, 34, 86

# Offset 26. The binary carries a Tex1D/Tex2D/TexCubeMap/Tex3D enum; across the
# multiplayer roster only these two appear, and the cube one is corroborated by
# its payload being exactly six times a single face.
FACES = {1: 1, 2: 6}
T_WIDTH, T_HEIGHT, T_MIPS = 8, 12, 20


def level_size(w, h, mips, fmt, faces=1):
    """Bytes for the whole mip chain, times the number of faces."""
    bb = BLOCK_BYTES[fmt]
    total = 0
    for i in range(mips):
        mw, mh = max(1, w >> i), max(1, h >> i)
        total += max(1, (mw + 3) // 4) * max(1, (mh + 3) // 4) * bb
    return total * faces


def full_mip_count(w, h):
    n = 1
    while max(w, h) > 1:
        w = max(1, w >> 1)
        h = max(1, h >> 1)
        n += 1
    return n


class TextureMap:
    def __init__(self, raw):
        self.raw = bytearray(raw)
        u = lambda o: struct.unpack_from('<I', self.raw, o)[0]
        self.width = u(H_WIDTH)
        self.height = u(H_HEIGHT)
        self.format = u(H_FORMAT)
        self.mips = u(H_MIPS)
        self.payload_len = u(H_PAYLOAD)
        self.file_id = u(2)
        self.tex_type = u(H_TYPE)

        if self.format in UNCOMPRESSED:
            raise ValueError("format %d is uncompressed RGBA, not block-compressed "
                             "- unsupported here" % self.format)
        if self.format not in BLOCK_BYTES:
            raise ValueError("unknown texture format %d" % self.format)
        if self.tex_type not in FACES:
            raise ValueError("unknown texture type %d at offset 26" % self.tex_type)
        self.faces = FACES[self.tex_type]
        if struct.unpack_from('<H', self.raw, 84)[0] != 0x1323:
            raise ValueError("marker 0x1323 missing at offset 84")

        expect = level_size(self.width, self.height, self.mips, self.format, self.faces)
        if expect != self.payload_len:
            raise ValueError("payload %d but geometry implies %d"
                             % (self.payload_len, expect))
        tail = len(self.raw) - HEADER_LEN - self.payload_len
        if tail != TRAILER_LEN:
            # The 151-byte trap: filesize - payload is always 151, which looks
            # like a header length and is not one. Refuse rather than guess.
            raise ValueError("trailer is %d bytes, expected %d" % (tail, TRAILER_LEN))

    @classmethod
    def load(cls, path):
        with open(path, 'rb') as f:
            return cls(f.read())

    @property
    def header(self):
        return bytes(self.raw[:HEADER_LEN])

    @property
    def trailer(self):
        return bytes(self.raw[HEADER_LEN + self.payload_len:])

    def levels(self):
        """Yield (index, w, h, blockbytes) per mip, for face 0 only.

        Cube faces are assumed face-major - all mips of face 0, then face 1 -
        which is the DDS convention. The single cube in this roster has ONE mip
        level, so face-major and mip-major are indistinguishable in it and this
        ordering is untested. Anything that rewrites a multi-mip cube must
        establish the order first.
        """
        off = HEADER_LEN
        bb = BLOCK_BYTES[self.format]
        for i in range(self.mips):
            mw, mh = max(1, self.width >> i), max(1, self.height >> i)
            n = max(1, (mw + 3) // 4) * max(1, (mh + 3) // 4) * bb
            yield i, mw, mh, bytes(self.raw[off:off + n])
            off += n

    def faces_levels(self):
        """Yield (face, index, w, h, blockbytes) over every stored surface."""
        off = HEADER_LEN
        bb = BLOCK_BYTES[self.format]
        for f in range(self.faces):
            for i in range(self.mips):
                mw, mh = max(1, self.width >> i), max(1, self.height >> i)
                n = max(1, (mw + 3) // 4) * max(1, (mh + 3) // 4) * bb
                yield f, i, mw, mh, bytes(self.raw[off:off + n])
                off += n

    def rebuild(self, width, height, mips, payloads):
        """Return a new .TextureMap with new geometry and new mip payloads.

        Everything outside the four header fields and three trailer fields is
        copied through byte for byte, including the File ID - the game binds
        textures by that and a changed one renders as a flat grey block.
        """
        payload = b''.join(payloads)
        expect = level_size(width, height, mips, self.format, self.faces)
        if len(payload) != expect:
            raise ValueError("assembled %d bytes, geometry implies %d"
                             % (len(payload), expect))

        head = bytearray(self.header)
        struct.pack_into('<I', head, H_WIDTH, width)
        struct.pack_into('<I', head, H_HEIGHT, height)
        struct.pack_into('<I', head, H_MIPS, mips)
        struct.pack_into('<I', head, H_PAYLOAD, len(payload))

        tail = bytearray(self.trailer)
        struct.pack_into('<I', tail, T_WIDTH, width)
        struct.pack_into('<I', tail, T_HEIGHT, height)
        struct.pack_into('<I', tail, T_MIPS, mips)

        return bytes(head) + payload + bytes(tail)

    def __repr__(self):
        return ("<TextureMap %dx%d fmt=%d mips=%d faces=%d payload=%d id=0x%08X>"
                % (self.width, self.height, self.format, self.mips, self.faces,
                   self.payload_len, self.file_id))
