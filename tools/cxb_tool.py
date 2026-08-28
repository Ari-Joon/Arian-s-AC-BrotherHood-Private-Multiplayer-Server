"""Decode the AC Brotherhood gamesettings .cxb container.

Layout discovered by inspection:
  - header: N records of 40 bytes -> name[32] (NUL-padded ASCII) + size[8] (ASCII decimal)
  - then a trailer record + small binary blob
  - then each section payload, LZSS-compressed, in header order
"""
import sys, struct, re

REC = 40

def parse_header(data):
    secs, off = [], 0
    while off + REC <= len(data):
        raw = data[off:off+REC]
        name = raw[:32].split(b'\x00')[0]
        size = raw[32:40].split(b'\x00')[0]
        if not re.fullmatch(rb'[a-z0-9_]+', name or b'') or not re.fullmatch(rb'\d+', size or b''):
            break
        secs.append((name.decode(), int(size), off))
        off += REC
    return secs, off


def lzss(data, start, out_len, lit_is_zero=True, dist_plus=1):
    """Flag byte then 8 tokens; literal byte, or 2-byte match.
    match: byte0 = dist low 8, byte1 = (dist high 4 bits << 4) | (len - 2)"""
    out = bytearray()
    i = start
    while i < len(data) and len(out) < out_len:
        flags = data[i]; i += 1
        for bit in range(8):
            if len(out) >= out_len or i >= len(data):
                break
            is_lit = ((flags >> bit) & 1) == (0 if lit_is_zero else 1)
            if is_lit:
                out.append(data[i]); i += 1
            else:
                if i + 1 >= len(data):
                    break
                b0, b1 = data[i], data[i+1]; i += 2
                dist = b0 | ((b1 >> 4) << 8)
                ln = (b1 & 0x0F) + 2
                dist += dist_plus
                if dist == 0 or dist > len(out):
                    return bytes(out), i, False
                for _ in range(ln):
                    out.append(out[-dist])
    return bytes(out), i, True


def score(b):
    if not b:
        return -1
    printable = sum(1 for c in b if 9 <= c <= 13 or 32 <= c <= 126)
    s = printable / len(b)
    if b.lstrip().startswith(b'<?xml'):
        s += 1
    if b.rstrip().endswith(b'>'):
        s += 0.5
    return s


if __name__ == '__main__':
    path = sys.argv[1]
    data = open(path, 'rb').read()
    secs, hdr_end = parse_header(data)
    print(f"file={len(data)} bytes  header={hdr_end}  sections={len(secs)}")
    for n, s, o in secs:
        print(f"  {n:32} {s:>7}")
    print(f"\ntrailer bytes {hdr_end}..{hdr_end+72}: {data[hdr_end:hdr_end+72].hex()}")

    # First payload begins at the flag byte just before the first '<?xml'
    first = data.find(b'<?xml')
    start = first - 1
    print(f"\nfirst '<?xml' at {first}; assuming payload starts at {start}")

    name, size, _ = secs[0]
    for lit_zero in (True, False):
        for dp in (0, 1):
            out, end, ok = lzss(data, start, size, lit_zero, dp)
            print(f"  lit_is_zero={lit_zero} dist+{dp}: got {len(out)}/{size} ok={ok} score={score(out):.3f}")
