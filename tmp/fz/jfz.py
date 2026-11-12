#!/usr/bin/env python3
import json, os, random, re, struct, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = "/tmp/jfz"; os.makedirs(OUT, exist_ok=True)

def rnum(rng):
    return rng.choice(["0", "-0", "1", "-1", "12", "0.5", "1e5", "1E-3", "1.25e+2", "9223372036854775807", "-9223372036854775808",
                       "9223372036854775808", "123456789012345678901234567890", "1e400", "-1e400", "4.9e-324", "1e-400", "0.1",
                       "+1", ".5", "5.", "01", "-", "1.e5", "00", "1e", "--1", "0x10", "1_0", str(rng.randrange(-10**6, 10**6)),
                       repr(rng.uniform(-1e10, 1e10)), "%de%d" % (rng.randrange(100), rng.randrange(-30, 30))])

def rstr(rng):
    parts = []
    for _ in range(rng.randint(0, 6)):
        parts.append(rng.choice(["a", "é", "\\n", "\\\"", "\\\\", "\\/", "\\u00e9", "\\u20ac", "\\ud83d\\ude00", "\\ud800", "\\udc00x",
                                 "\\u12", "\\x", "\\uZZZZ", "\t", "\x01", "\x7f", "\xff", " ", "\\b\\f\\r\\t", "\\ud800\\u0041", "\\"]))
    return '"' + "".join(parts) + '"'

def rval(rng, d):
    k = rng.randrange(8 if d < 6 else 5)
    if k == 0: return rnum(rng)
    if k == 1: return rstr(rng)
    if k == 2: return rng.choice(["true", "false", "null", "nul", "True", "NaN", "Infinity"])
    if k == 3: return rnum(rng)
    if k == 4: return rstr(rng)
    ws = lambda: rng.choice(["", " ", "\n", "\t", "\r\n", "\x0c"]) if rng.random() < 0.3 else ""
    if k in (5, 6):
        items = [ws() + rval(rng, d + 1) + ws() for _ in range(rng.randint(0, 4))]
        s = "[" + ",".join(items) + (rng.choice([",", ""]) if rng.random() < 0.1 else "") + "]"
        return s
    items = [ws() + rstr(rng) + ws() + ":" + ws() + rval(rng, d + 1) for _ in range(rng.randint(0, 4))]
    return "{" + ",".join(items) + "}"

def pair_hook(pairs): return ("obj", pairs)
def hx(s): return "'" + s.encode("utf-8", "surrogatepass").hex() + "'"

def ref(text):
    def bad(x): raise ValueError(x)
    try:
        v = json.loads(text, object_pairs_hook=pair_hook, parse_constant=bad, parse_float=lambda s: ("num", s), parse_int=lambda s: ("num", s))
    except (ValueError, RecursionError):
        return None
    out = []
    def dump(v):
        if v is None: out.append("n")
        elif v is True: out.append("t")
        elif v is False: out.append("f")
        elif isinstance(v, str): out.append("s" + hx(v))
        elif isinstance(v, list): out.append("["); [ (dump(x), out.append(",")) for x in v]; out.append("]")
        elif isinstance(v, tuple) and v[0] == "obj":
            out.append("{")
            for k, x in v[1]: out.append(hx(k) + ":"); dump(x); out.append(",")
            out.append("}")
        else:
            s = v[1]; f = float(s)
            if re.fullmatch(r"-?\d+", s) and -2**63 <= int(s) < 2**63: iv = str(int(s))
            elif abs(f) < 2**63: iv = str(int(f))
            else: iv = "*"
            out.append("#" + "%x" % struct.unpack("<Q", struct.pack("<d", f))[0] + "|" + iv + "|")
    dump(v)
    return "".join(out)

def main():
    n, seed = int(sys.argv[1]), int(sys.argv[2])
    rng = random.Random(seed)
    files = {}
    for i in range(n):
        t = rval(rng, 0)
        if rng.random() < 0.2: t = " " + t + rng.choice(["", " ", "\n", "x", ",", "]"])
        if rng.random() < 0.1 and t: 
            j = rng.randrange(len(t)); t = t[:j] + t[j + 1:]
        name = f"{OUT}/{seed}_{i}.json"
        open(name, "wb").write(t.encode("utf-8", "surrogatepass"))
        files[name] = t
    names = list(files)
    r = subprocess.run(["timeout", "60", HERE + "/jfz"] + names, capture_output=True)
    lines = r.stdout.decode("latin1").splitlines()
    bad = 0
    if r.returncode: print("CRASH", lines[-1:], r.stderr[:300]); bad += 1
    for l in lines:
        f, got = l.split(" ", 1)
        want = ref(files[f])
        if want is None: want = "bad"
        if got != want and not (want != "bad" and re.sub(r"\|-?\d+\|", "|*|", got) == re.sub(r"\|[-\d*]+\|", "|*|", want) and "*" in want):
            print("DIFF", f, repr(files[f])[:200], "\n got ", got[:200], "\n want", want[:200]); bad += 1
            if bad > 10: break
    print("bad", bad)
main()
