import math, os, random, struct, subprocess, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = ["sin","cos","tan","asin","acos","atan","atan2","exp","log","log2","pow","fmod","trunc","round","fract","sincos.s","sincos.c","floor","ceil"]
seed = int(sys.argv[1]); N = int(sys.argv[2]); rng = random.Random(seed)
def rand64():
    k = rng.randrange(12)
    if k == 0: return struct.unpack("<d", struct.pack("<Q", rng.getrandbits(64)))[0]
    if k == 1: return rng.choice([0.0, -0.0, math.inf, -math.inf, math.nan, 1.0, -1.0, 0.5, -0.5, 2.0, 5e-324, -5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, -1.7976931348623157e308, 1e-300, 709.782712893384, 709.79, -745.13321910194122, -745.2, -708.4, 1e22, 2**53, 2**52+0.5, 0.49999999999999994, 2.5, -2.5])
    if k == 2: return (rng.randint(-200000, 200000)) * math.pi / 2 * (1 + rng.choice([0, 1e-16, -1e-16, 2e-16]))
    if k == 3: return rng.uniform(-1, 1)
    if k == 4: return 1 - rng.random() * 1e-8 * rng.choice([1, -1])
    if k == 5: return rng.uniform(-800, 800)
    if k == 6: return math.ldexp(rng.uniform(1, 2), rng.randint(-1074, 1023)) * rng.choice([1, -1])
    if k == 7: return float(rng.randint(-100, 100))
    if k == 8: return rng.uniform(-10, 10)
    if k == 9: return 1 + rng.uniform(-1e-3, 1e-3)
    if k == 10: return math.ldexp(1.0, rng.randint(-1074, 1023)) * rng.choice([1, -1])
    return rng.uniform(0, 1e6)
def f32(x): return struct.unpack("<f", struct.pack("<f", x))[0] if abs(x) < 3.4e38 or math.isinf(x) or math.isnan(x) else math.copysign(math.inf, x)
def rand32():
    k = rng.randrange(6)
    if k == 0: return struct.unpack("<f", struct.pack("<I", rng.getrandbits(32)))[0]
    if k == 1: return rng.choice([0.0, -0.0, math.inf, -math.inf, math.nan, 1.0, -1.0, 2.0, 1e-45, 1.1754944e-38, 3.4028235e38, 88.72283, 88.7229, -103.97, -87.33654, 0.5, 2.5, 8388608.5, 0.49999997])
    if k == 2: return f32(rng.randint(-20000, 20000) * math.pi / 2)
    return f32(rand64()) if k < 5 else f32(rng.uniform(-5, 5))
in64 = []
in32 = []
for i in range(N):
    x = rand64(); y = rand64()
    if rng.random() < 0.3: y = rng.choice([float(rng.randint(-10, 10)), 0.5, -0.5, 1/3, rng.uniform(-50, 50), math.inf, -math.inf, 0.0, -0.0, 1e300, 2**53+2.0])
    in64 += [x, y]
    x = rand32(); y = rand32()
    if rng.random() < 0.3: y = f32(rng.choice([float(rng.randint(-10, 10)), 0.5, -0.5, 1/3, rng.uniform(-50, 50), math.inf, -math.inf, 0.0, -0.0, 1e30]))
    in32 += [x, y]
np.array(in64, dtype="<f8").tofile("/tmp/mfz/in64.bin")
np.array(in32, dtype="<f4").tofile("/tmp/mfz/in32.bin")
for exe in ("mathfz", "mathref"):
    r = subprocess.run([os.path.join(HERE, exe)], capture_output=True, text=True)
    if r.returncode: print(exe, "failed", r.stderr); sys.exit(1)
def ulps(a, b, bits):
    if np.isnan(a) and np.isnan(b): return 0
    if np.isnan(a) or np.isnan(b): return 1 << 60
    if a == b: return 0 if (a != 0 or np.signbit(a) == np.signbit(b)) else 1 << 59
    it = np.int64 if bits == 64 else np.int32
    ia = int(np.array([a]).view(it)[0]); ib = int(np.array([b]).view(it)[0])
    if ia < 0: ia = -(ia & ((1 << (bits - 1)) - 1))
    if ib < 0: ib = -(ib & ((1 << (bits - 1)) - 1))
    return abs(ia - ib)
for bits, dt in ((64, "<f8"), (32, "<f4")):
    got = np.fromfile(f"/tmp/mfz/out{bits}.bin", dtype=dt).reshape(-1, 19)
    ref = np.fromfile(f"/tmp/mfz/ref{bits}.bin", dtype=dt).reshape(-1, 19)
    inp = np.array(in64 if bits == 64 else in32, dtype=dt).reshape(-1, 2)
    for j, name in enumerate(NAMES):
        worst = 0; shown = 0; cnt = 0
        for i in range(len(got)):
            u = ulps(got[i, j], ref[i, j], bits)
            if u > 1:
                cnt += 1
                if shown < 3: print(f"  f{bits} {name}({inp[i,0]!r}, {inp[i,1]!r}) = {got[i,j]!r} ref {ref[i,j]!r} ulps {u}"); shown += 1
            worst = max(worst, u)
        if worst > 1: print(f"f{bits} {name}: {cnt} inputs > 1 ulp, worst {worst}")
print("done")
