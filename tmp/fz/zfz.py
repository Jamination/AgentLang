#!/usr/bin/env python3
# Differential fuzzer for inflate / zlib_decompress / deflate in std.image against Python's zlib.
import os, random, subprocess, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "zfz")
OUT = "/tmp/zfz"
os.makedirs(OUT, exist_ok=True)

def gen_plain(rng):
    k = rng.randrange(6)
    n = rng.choice([0, 1, 2, 3, 4, 7, 8, 9, 100, 258, 259, 1000, 40000, 70000, 140000])
    if k == 0: return bytes(rng.randrange(256) for _ in range(n))
    if k == 1: return bytes([rng.randrange(256)]) * n
    if k == 2: return bytes(rng.choice(b"ab") for _ in range(n))
    if k == 3:
        unit = bytes(rng.randrange(256) for _ in range(rng.randint(1, 40)))
        return (unit * (n // len(unit) + 1))[:n]
    if k == 4:
        words = [bytes(rng.randrange(97, 123) for _ in range(rng.randint(1, 8))) for _ in range(30)]
        out = b""
        while len(out) < n: out += rng.choice(words) + b" "
        return out[:n]
    # far matches: random block repeated at distance up to 32768+
    blk = bytes(rng.randrange(256) for _ in range(rng.randint(3, 300)))
    gap = bytes(rng.randrange(256) for _ in range(rng.choice([1, 100, 4000, 32000, 32765, 32768, 33000])))
    return blk + gap + blk + gap[:10] + blk

def raw_deflate(data, level, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
    return c.compress(data) + c.flush()

def py_inflate(data, wbits):
    d = zlib.decompressobj(wbits)
    try:
        out = d.decompress(data)
        if not d.eof: return None
        return out
    except zlib.error:
        return None

def mutate(b, rng):
    b = bytearray(b)
    for _ in range(rng.randint(1, 3)):
        m = rng.randrange(4)
        if m == 0 and b: b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
        elif m == 1 and b: b[rng.randrange(len(b))] = rng.randrange(256)
        elif m == 2: b = b[:rng.randrange(len(b) + 1)]
        elif m == 3:
            i = rng.randrange(len(b) + 1); b[i:i] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 4)))
    return bytes(b)

def main():
    n = int(sys.argv[1]); seed = int(sys.argv[2])
    rng = random.Random(seed)
    files = []
    for i in range(n):
        plain = gen_plain(rng)
        r = rng.random()
        if r < 0.15:
            data = plain
        else:
            level = rng.choice([0, 1, 6, 9])
            strat = rng.choice([zlib.Z_DEFAULT_STRATEGY, zlib.Z_FIXED, zlib.Z_HUFFMAN_ONLY, zlib.Z_RLE])
            if rng.random() < 0.5:
                data = raw_deflate(plain, level, strat)
            else:
                c = zlib.compressobj(level, zlib.DEFLATED, 15, 9, strat)
                data = c.compress(plain) + c.flush()
            if rng.random() < 0.5:
                data = mutate(data, rng)
        name = os.path.join(OUT, f"{seed}_{i}")
        open(name, "wb").write(data)
        files.append(name)
    bad = 0
    i = 0
    while i < len(files):
        chunk = files[i:i + 100]
        r = subprocess.run(["bash", "-c", "ulimit -v 4000000; exec timeout 60 " + BIN + ' "$@"', "x"] + chunk, capture_output=True, text=True)
        lines = r.stdout.splitlines()
        res = {}
        for l in lines:
            p = l.split()
            if len(p) == 7: res[p[0]] = p[1:]
        if r.returncode != 0:
            last = lines[-1].split()[0] if lines else chunk[0]
            print("CRASH", last, r.stderr.strip()[:300]); bad += 1
            i += chunk.index(last) + 1 if last in chunk else len(chunk)
        else:
            i += len(chunk)
        for f, p in res.items():
            data = open(f, "rb").read()
            for (okp, lenp, crcp), wb in (((p[0], p[1], p[2]), -15), ((p[3], p[4], p[5]), 15)):
                ref = py_inflate(data, wb)
                if ref is None:
                    if okp == "true":
                        print("ACCEPTS", wb, f); bad += 1
                else:
                    want = ["true", str(len(ref)), "%x" % (zlib.crc32(ref) & 0xffffffff)]
                    if [okp, lenp, crcp] != want:
                        print("MISMATCH", wb, f, [okp, lenp, crcp], want); bad += 1
            z = open(f + ".z", "rb").read()
            if zlib.decompress(z) != data:
                print("ZLIB OUT BAD", f); bad += 1
    print("bad", bad)

main()
