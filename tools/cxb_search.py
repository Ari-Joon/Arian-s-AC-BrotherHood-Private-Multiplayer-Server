"""Brute-force the LZSS token encoding by scoring how far each variant decodes."""
import sys, itertools, re

def decode(data, start, out_len, msb, lit_bit, split, dist_plus, min_len):
    out = bytearray(); i = start
    while i < len(data) and len(out) < out_len:
        flags = data[i]; i += 1
        for b in range(8):
            if len(out) >= out_len or i >= len(data): break
            bit = (flags >> (7-b)) & 1 if msb else (flags >> b) & 1
            if bit == lit_bit:
                out.append(data[i]); i += 1
            else:
                if i+1 >= len(data): return bytes(out), False
                b0, b1 = data[i], data[i+1]; i += 2
                if split == 0:      dist = b0 | ((b1 >> 4) << 8);  ln = (b1 & 0x0F)
                elif split == 1:    dist = b0 | ((b1 & 0x0F) << 8); ln = (b1 >> 4)
                elif split == 2:    dist = b1 | ((b0 >> 4) << 8);  ln = (b0 & 0x0F)
                else:               dist = b1 | ((b0 & 0x0F) << 8); ln = (b0 >> 4)
                ln += min_len
                dist += dist_plus
                if dist == 0 or dist > len(out): return bytes(out), False
                for _ in range(ln): out.append(out[-dist])
    return bytes(out), True

if __name__ == '__main__':
    data = open(sys.argv[1],'rb').read()
    start = data.find(b'<?xml') - 1
    target = 5468
    best = []
    for msb, lit_bit, split, dp, ml in itertools.product((False,True),(0,1),(0,1,2,3),(0,1),(2,3)):
        out, ok = decode(data, start, target, msb, lit_bit, split, dp, ml)
        printable = sum(1 for c in out if 9<=c<=13 or 32<=c<=126)/max(len(out),1)
        best.append((len(out), printable, ok, msb, lit_bit, split, dp, ml))
    best.sort(key=lambda t: (-t[0], -t[1]))
    print(f"{'len':>6} {'print':>6} {'ok':>5}  msb lit split d+ minlen")
    for r in best[:8]:
        print(f"{r[0]:>6} {r[1]:>6.3f} {str(r[2]):>5}  {int(r[3])}   {r[4]}   {r[5]}    {r[6]}  {r[7]}")
    top = best[0]
    out,_ = decode(data, start, target, top[3], top[4], top[5], top[6], top[7])
    print("\n--- best output, first 600 bytes ---")
    sys.stdout.write(out[:600].decode('latin-1'))
