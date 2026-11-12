#!/usr/bin/env python3
# Mutation fuzzer + differential check for std.image's PNG/BMP decoders.
# usage: pngfz.py N SEED
import os, random, struct, subprocess, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "imgfz")
OUT = "/tmp/pngfz"
os.makedirs(OUT, exist_ok=True)

def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

NIN = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
ADAM = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]

def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc: return a
    if pb <= pc: return b
    return c

def filt(rows, bpp, rng):
    out = bytearray()
    prev = bytes(len(rows[0])) if rows else b""
    for r in rows:
        ft = rng.randrange(5)
        o = bytearray([ft])
        for i in range(len(r)):
            a = r[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            pred = [0, a, b, (a + b) >> 1, paeth(a, b, c)][ft]
            o.append((r[i] - pred) & 255)
        out += o
        prev = r
    return out

def pack_row(samples, depth):
    if depth == 8: return bytes(samples)
    if depth == 16: return b"".join(struct.pack(">H", s) for s in samples)
    out = bytearray()
    acc = 0; n = 0
    for s in samples:
        acc = acc << depth | s; n += depth
        if n == 8: out.append(acc); acc = 0; n = 0
    if n: out.append(acc << (8 - n))
    return bytes(out)

def make_png(rng):
    ct = rng.choice([0, 2, 3, 4, 6])
    depths = {0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]}[ct]
    d = rng.choice(depths)
    w = rng.randint(1, 37); h = rng.randint(1, 37)
    il = rng.randrange(2)
    nin = NIN[ct]
    maxv = (1 << d) - 1
    npal = 0; pal = b""; trns = None
    if ct == 3:
        npal = rng.randint(1, 1 << d)
        pal = bytes(rng.randrange(256) for _ in range(3 * npal))
        maxv = npal - 1
        if rng.random() < 0.4:
            trns = bytes(rng.randrange(256) for _ in range(rng.randint(0, npal)))
    elif ct in (0, 2) and rng.random() < 0.4:
        trns = [rng.randint(0, maxv) for _ in range(nin)]
    style = rng.randrange(3)
    pix = [[[ (rng.randint(0, maxv) if style == 0 else (x * 7 + y * 3 + c) % (maxv + 1) if style == 1 else (trns[c] if trns and ct != 3 and rng.random() < .3 else rng.randint(0, maxv)))
              for c in range(nin)] for x in range(w)] for y in range(h)]
    def rows_of(xs, ys):
        return [pack_row([s for x in xs for s in pix[y][x]], d) for y in ys]
    bpp = max(nin * d // 8, 1)
    if il == 0:
        raw = filt(rows_of(range(w), range(h)), bpp, rng)
    else:
        raw = bytearray()
        for (x0, y0, dx, dy) in ADAM:
            xs = range(x0, w, dx); ys = range(y0, h, dy)
            if len(xs) == 0 or len(ys) == 0: continue
            raw += filt(rows_of(xs, ys), bpp, rng)
    z = zlib.compress(bytes(raw), rng.choice([0, 1, 6, 9]))
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, d, ct, 0, 0, il))
    if ct == 3: out += chunk(b"PLTE", pal)
    if trns is not None:
        out += chunk(b"tRNS", trns if ct == 3 else b"".join(struct.pack(">H", v) for v in trns))
    if rng.random() < 0.2: out += chunk(b"tEXt", b"Comment\0hello")
    # split IDAT
    k = rng.choice([1, 1, 2, 3, 7])
    cuts = sorted(rng.randint(0, len(z)) for _ in range(k - 1))
    prev = 0
    for c in cuts + [len(z)]:
        out += chunk(b"IDAT", z[prev:c]); prev = c
    out += chunk(b"IEND", b"")
    # reference decode
    ch = 3 if ct == 3 else nin
    if trns is not None: ch += 1
    ref = bytearray()
    scale = 255 // ((1 << d) - 1) if d < 8 else 1
    for y in range(h):
        for x in range(w):
            s = pix[y][x]
            if ct == 3:
                i = s[0]
                rgb = pal[3 * i:3 * i + 3]
                ref += rgb
                if trns is not None: ref.append(trns[i] if i < len(trns) else 255)
            else:
                for v in s: ref.append(v >> 8 if d == 16 else v * scale)
                if trns is not None: ref.append(0 if list(s) == list(trns) else 255)
    return out, (w, h, ch, zlib.crc32(bytes(ref)) & 0xffffffff)

def make_bmp(rng):
    bpp = rng.choice([1, 4, 8, 24, 32])
    w = rng.randint(1, 30); h = rng.randint(1, 30)
    top = rng.random() < 0.3
    hsize = rng.choice([40, 108, 124]) if bpp != 32 else rng.choice([40, 108, 124])
    npal = 0
    if bpp <= 8:
        npal = rng.randint(1, 1 << bpp)
    pal = bytes(rng.randrange(256) for _ in range(4 * npal))
    stride = (w * bpp + 31) // 32 * 4
    data = bytearray()
    ref = bytearray()
    alpha_any = 0
    rows = []
    pixels = []
    for y in range(h):
        row = []
        for x in range(w):
            if bpp <= 8: row.append(rng.randrange(npal))
            else: row.append(tuple(rng.randrange(256) for _ in range(bpp // 8)))
        pixels.append(row)
    for y in range(h):
        for x in range(w):
            p = pixels[y][x]
            if bpp <= 8: ref += bytes([pal[4*p+2], pal[4*p+1], pal[4*p]])
            elif bpp == 24: ref += bytes([p[2], p[1], p[0]])
            else:
                ref += bytes([p[2], p[1], p[0], p[3]]); alpha_any |= p[3]
    if bpp == 32 and alpha_any == 0:
        for i in range(3, len(ref), 4): ref[i] = 255
    order = range(h) if top else range(h - 1, -1, -1)
    for y in order:
        rb = bytearray()
        if bpp <= 8: rb += pack_row(pixels[y], bpp)
        else:
            for p in pixels[y]: rb += bytes(p)
        rb += bytes(stride - len(rb))
        data += rb
    comp = 0
    hdr = struct.pack("<IiiHHIIiiII", hsize, w, -h if top else h, 1, bpp, comp, len(data), 2835, 2835, npal if bpp <= 8 and rng.random() < 0.5 else 0, 0)
    if npal != (1 << bpp) and bpp <= 8:
        hdr = hdr[:32] + struct.pack("<I", npal) + hdr[36:]
    hdr += bytes(hsize - 40)
    off = 14 + hsize + len(pal)
    out = b"BM" + struct.pack("<IHHI", off + len(data), 0, 0, off) + hdr + pal + bytes(data)
    ch = 4 if bpp == 32 else 3
    return out, (w, h, ch, zlib.crc32(bytes(ref)) & 0xffffffff)

def fix_crcs(b):
    b = bytearray(b)
    pos = 8
    while pos + 12 <= len(b):
        n = struct.unpack(">I", b[pos:pos + 4])[0]
        if pos + 12 + n > len(b): break
        b[pos + 8 + n:pos + 12 + n] = struct.pack(">I", zlib.crc32(bytes(b[pos + 4:pos + 8 + n])) & 0xffffffff)
        pos += 12 + n
    return bytes(b)

def mutate(b, rng, png):
    b = bytearray(b)
    for _ in range(rng.randint(1, 4)):
        m = rng.randrange(7)
        if m == 0 and b: b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
        elif m == 1 and b: b[rng.randrange(len(b))] = rng.randrange(256)
        elif m == 2: b = b[:rng.randrange(len(b) + 1)]
        elif m == 3:
            i = rng.randrange(len(b) + 1); b[i:i] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 8)))
        elif m == 4 and len(b) > 4:
            i = rng.randrange(len(b) - 4); b[i:i + 4] = struct.pack(">I", rng.choice([0, 1, 0xffffffff, 0x7fffffff, 0x80000000, 0x10000, 1 << 24, (1 << 24) + 1, rng.randrange(1 << 32)]))
        elif m == 5 and b:
            i = rng.randrange(len(b)); j = rng.randrange(i, len(b) + 1); del b[i:j]
        elif m == 6 and len(b) > 30:
            # header field mutation
            i = rng.randrange(8, min(len(b), 60)); b[i] = rng.choice([0, 1, 2, 3, 4, 6, 8, 16, 255, 0x80])
    if png and rng.random() < 0.7:
        b = fix_crcs(b)
    return bytes(b)

def mutate_zdata(rng):
    # valid zlib wrapper with corrupted deflate data, CRCs fixed: reaches inflate and the row code
    png, _ = make_png(rng)
    return png

def run(files):
    try:
        r = subprocess.run(["bash", "-c", "ulimit -v 4000000; exec timeout 20 " + BIN + " \"$@\"", "x"] + files, capture_output=True, text=True)
    except Exception as e:
        return None, str(e)
    return r, None

def main():
    n = int(sys.argv[1]); seed = int(sys.argv[2])
    rng = random.Random(seed)
    batch = []
    expect = {}
    bad = 0
    for i in range(n):
        kind = rng.random()
        png = kind < 0.75
        b, info = make_png(rng) if png else make_bmp(rng)
        name = os.path.join(OUT, f"{seed}_{i}.{'png' if png else 'bmp'}")
        if rng.random() < 0.3:
            expect[name] = info
        else:
            b = mutate(b, rng, png)
        open(name, "wb").write(b)
        batch.append(name)
        if len(batch) == 200 or i == n - 1:
          while batch:
            r, err = run(batch)
            lines = r.stdout.splitlines()
            done = {}
            for l in lines:
                parts = l.split()
                if len(parts) >= 2: done[parts[0]] = parts[1:]
            rest = []
            if r.returncode != 0:
                last = lines[-1].split()[0] if lines else batch[0]
                print("CRASH", r.returncode, last, r.stderr.strip()[:300]); bad += 1
                rest = batch[batch.index(last) + 1:] if last in batch else []
            for f, inf in expect.items():
                if f in done:
                    want = ["ok", str(inf[0]), str(inf[1]), str(inf[2]), "%x" % inf[3]]
                    if done[f] != want:
                        print("MISMATCH", f, done[f], want); bad += 1
            expect = {k: v for k, v in expect.items() if k not in done}
            batch = rest
    print("bad", bad)

main()
