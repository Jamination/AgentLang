import os, random, struct, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); OUT = "/tmp/wavfz"; os.makedirs(OUT, exist_ok=True)
def mk(rng):
    bits = rng.choice([8, 16, 24, 32, 32, 64]); fmt = 3 if bits == 64 or (bits == 32 and rng.random() < .5) else 1
    ch = rng.randint(1, 6); rate = rng.choice([8000, 44100, 48000]); n = rng.randint(0, 50)
    raw = bytes(rng.randrange(256) for _ in range(n * ch * bits // 8))
    if fmt == 3:
        if bits == 32: raw = b"".join(struct.pack("<f", rng.uniform(-1, 1)) for _ in range(n * ch))
        else: raw = b"".join(struct.pack("<d", rng.uniform(-1, 1)) for _ in range(n * ch))
    ext = rng.random() < 0.3
    if ext:
        f = struct.pack("<HHIIHHHHIH14s", 0xFFFE, ch, rate, rate * ch * bits // 8, ch * bits // 8, bits, 22, bits, 0, fmt, b"\0" * 14)
    else:
        f = struct.pack("<HHIIHH", fmt, ch, rate, rate * ch * bits // 8, ch * bits // 8, bits)
    chunks = b"fmt " + struct.pack("<I", len(f)) + f
    if rng.random() < .3: chunks += b"LIST" + struct.pack("<I", 3) + b"abc\0"
    chunks += b"data" + struct.pack("<I", len(raw)) + raw
    return b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks
def mut(b, rng):
    b = bytearray(b)
    for _ in range(rng.randint(1, 4)):
        k = rng.randrange(4)
        if k == 0 and b: b[rng.randrange(len(b))] = rng.randrange(256)
        elif k == 1: b = b[:rng.randrange(len(b) + 1)]
        elif k == 2 and len(b) > 4:
            i = rng.randrange(len(b) - 3); b[i:i+4] = struct.pack("<I", rng.choice([0, 1, 0xffffffff, 0x7fffffff, 0xfffffffe, rng.randrange(1 << 32)]))
        elif k == 3 and len(b) > 40:
            i = rng.choice([22, 24, 34, 36, 40, 20]); b[i] = rng.choice([0, 1, 3, 8, 16, 24, 32, 64, 255])
    return bytes(b)
n, seed = int(sys.argv[1]), int(sys.argv[2]); rng = random.Random(seed); names = []
for i in range(n):
    b = mk(rng)
    if rng.random() < .8: b = mut(b, rng)
    p = f"{OUT}/{seed}_{i}.wav"; open(p, "wb").write(b); names.append(p)
r = subprocess.run(["timeout", "60", HERE + "/wavfz"] + names, capture_output=True, text=True)
print("exit", r.returncode, r.stdout.splitlines()[-1:], r.stderr[:300])
