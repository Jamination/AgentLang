#!/usr/bin/env python3
"""Differential fuzzer for the AL compiler.

Generates random (but always in-bounds, terminating) AL programs and checks that the unoptimized
build, the optimized build and the unchecked build all print the same output.

usage: tests/gen/fuzz.py [count] [first_seed] [--keep]
"""
import os
import random
import subprocess
import sys
import tempfile

ALC = os.path.join(os.path.dirname(__file__), "..", "..", "build", "alc")
INT_TYPES = ["i64", "u64", "i32", "u32", "i16", "u16", "i8", "u8"]
BITS = {"i64": 64, "u64": 64, "i32": 32, "u32": 32, "i16": 16, "u16": 16, "i8": 8, "u8": 8}


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.lines = []
        self.ind = 0
        self.funcs = []  # (name, param types, return type)
        self.tmp = 0

    def w(self, s):
        self.lines.append("    " * self.ind + s)

    def lit(self, ty):
        r = self.r
        if ty == "f64":
            return r.choice(["0.5", "1.5", "2.0", "0.25", "3.0", "10.0", "0.1", "100.0", "1.0"])
        if ty == "bool":
            return r.choice(["true", "false"])
        b = BITS[ty]
        signed = ty[0] == "i"
        choice = r.random()
        if choice < 0.5:
            v = r.randint(0, 20)
        elif choice < 0.8:
            v = r.randint(0, (1 << (b - 1)) - 1)
        else:
            v = r.choice([1, 2, 3, 7, 8, 15, 16, 255, 256, 1000, (1 << (b - 1)) - 1])
            v = min(v, (1 << (b - 1)) - 1)
        if signed and r.random() < 0.25:
            return f"{ty}(-{v})" if v else f"{ty}(0)"
        return f"{ty}({v})"

    def var_of(self, env, ty):
        c = [n for n, t in env.items() if t == ty]
        return self.r.choice(c) if c else None

    def expr(self, env, ty, depth):
        r = self.r
        if depth <= 0 or r.random() < 0.15:
            v = self.var_of(env, ty)
            if v and r.random() < 0.7:
                return v
            return self.lit(ty)
        if ty == "bool":
            k = r.random()
            if k < 0.6:
                t = r.choice(INT_TYPES + ["f64"])
                op = r.choice(["==", "!=", "<", "<=", ">", ">="])
                return f"({self.expr(env, t, depth - 1)} {op} {self.expr(env, t, depth - 1)})"
            if k < 0.8:
                op = r.choice(["&&", "||"])
                return f"({self.expr(env, 'bool', depth - 1)} {op} {self.expr(env, 'bool', depth - 1)})"
            if k < 0.9:
                return f"!{self.expr(env, 'bool', depth - 1)}"
            v = self.var_of(env, "bool")
            return v if v else self.lit("bool")
        if ty == "f64":
            k = r.random()
            if k < 0.55:
                op = r.choice(["+", "-", "*"])
                return f"({self.expr(env, 'f64', depth - 1)} {op} {self.expr(env, 'f64', depth - 1)})"
            if k < 0.7:
                # keep magnitudes bounded
                t = r.choice(["i16", "u8", "i8", "u16"])
                return f"f64({self.expr(env, t, depth - 1)})"
            if k < 0.8:
                return f"(if {self.expr(env, 'bool', depth - 1)} {{ {self.expr(env, 'f64', depth - 1)} }} else {{ {self.expr(env, 'f64', depth - 1)} }})"
            if k < 0.87:
                return f"sqrt(fabs({self.expr(env, 'f64', depth - 1)}))"
            if k < 0.93:
                return f"({self.expr(env, 'f64', depth - 1)} / ({self.lit('f64')} + 1.0))"
            v = self.var_of(env, "f64")
            return v if v else self.lit("f64")
        # integers
        k = r.random()
        b = BITS[ty]
        if k < 0.40:
            op = r.choice(["+", "-", "*", "&", "|", "^", "+", "-"])
            return f"({self.expr(env, ty, depth - 1)} {op} {self.expr(env, ty, depth - 1)})"
        if k < 0.50:
            op = r.choice(["<<", ">>"])
            cnt = self.expr(env, r.choice(["u8", "i64", "u32"]), depth - 2) if r.random() < 0.5 else str(r.randint(0, b + 3))
            return f"({self.expr(env, ty, depth - 1)} {op} {cnt})"
        if k < 0.60:
            op = r.choice(["/", "%"])
            if r.random() < 0.6:
                d = r.choice([1, 2, 3, 5, 7, 10, 16, 100, 127])
                d = min(d, (1 << (b - 1)) - 1)
                if ty[0] == "i" and r.random() < 0.3:
                    return f"({self.expr(env, ty, depth - 1)} {op} {ty}(-{max(d, 2)}))"
                return f"({self.expr(env, ty, depth - 1)} {op} {ty}({d}))"
            # run-time divisor that is never zero (and never -1)
            return f"({self.expr(env, ty, depth - 1)} {op} (({self.expr(env, ty, depth - 1)} & {ty}(63)) + {ty}(2)))"
        if k < 0.70:
            src = r.choice(INT_TYPES)
            return f"{ty}({self.expr(env, src, depth - 1)})"
        if k < 0.76:
            return f"(if {self.expr(env, 'bool', depth - 1)} {{ {self.expr(env, ty, depth - 1)} }} else {{ {self.expr(env, ty, depth - 1)} }})"
        if k < 0.80:
            return r.choice(["-", "~"]) + self.expr(env, ty, depth - 1)
        if k < 0.88:
            # array read with a masked (always valid) index
            arr, aty, n = r.choice(self.arrays)
            idx = f"({self.expr(env, 'i64', depth - 2)} & {n - 1})"
            return self.conv(f"{arr}[{idx}]", aty, ty)
        if k < 0.94 and self.funcs:
            name, ptys, rty = r.choice(self.funcs)
            args = ", ".join(self.expr(env, p, depth - 2) for p in ptys)
            return self.conv(f"{name}({args})", rty, ty)
        if k < 0.955 and getattr(self, "helpers", False):
            c = r.random()
            if c < 0.3:
                e = f"ssum(smix(sv, {self.expr(env, 'i64', depth - 2)}))"
            elif c < 0.5:
                e = f"wsum(ga[..], {self.expr(env, 'i64', depth - 2)}, {self.expr(env, 'i64', depth - 2)})"
            elif c < 0.65:
                e = f"wsum(ga[4..12], {self.expr(env, 'i64', depth - 2)}, {r.randint(0, 9)})"
            elif c < 0.8:
                e = f"fibr({self.expr(env, 'i64', depth - 2)} & 7)"
            else:
                e = f"(sv.a + i64(sv.b) + i64(sv.d))"
            return self.conv(e, "i64", ty)
        if k < 0.97:
            f = r.choice(["popcnt", "ctz", "clz", "bswap"])
            return f"{f}({self.expr(env, ty, depth - 1)})"
        v = self.var_of(env, ty)
        return v if v else self.lit(ty)

    def conv(self, e, src, dst):
        if src == dst:
            return e
        if src == "f64":
            return f"{dst}(i64({e}) & 1023)" if dst != "i64" else f"(i64({e}) & 1023)"
        return f"{dst}({e})"

    def stmt(self, env, depth, in_loop):
        r = self.r
        k = r.random()
        mutable = [n for n in env if not n.startswith("i_") and not n.startswith("p_")]
        if k < 0.35 and mutable:
            n = r.choice(mutable)
            t = env[n]
            if t in BITS and r.random() < 0.3:
                op = r.choice(["+=", "-=", "*=", "^=", "|=", "&="])
                self.w(f"{n} {op} {self.expr(env, t, 3)}")
            else:
                self.w(f"{n} = {self.expr(env, t, 3)}")
        elif k < 0.50:
            arr, aty, n = r.choice(self.arrays)
            idx = f"({self.expr(env, 'i64', 2)} & {n - 1})"
            self.w(f"{arr}[{idx}] = {self.expr(env, aty, 3)}")
        elif k < 0.65 and depth > 0:
            self.w(f"if {self.expr(env, 'bool', 3)} {{")
            self.block(env, depth - 1, in_loop)
            if r.random() < 0.5:
                self.w("} else {")
                self.block(env, depth - 1, in_loop)
            self.w("}")
        elif k < 0.85 and depth > 0:
            self.tmp += 1
            iv = f"i_{self.tmp}"
            kind = r.random()
            if kind < 0.35:
                n = r.choice([1, 2, 3, 4, 5, 8, 12, 16, 20, 64])
                self.w(f"for {iv} in 0..{n} {{")
            elif kind < 0.55:
                self.w(f"for {iv} in 0..({self.expr(env, 'i64', 2)} & 15) {{")
            elif kind < 0.70:
                arr, aty, n = r.choice(self.arrays)
                self.w(f"for {iv} in 0..{n} {{")
                env2 = dict(env)
                env2[iv] = "i64"
                self.ind += 1
                # direct (unmasked) indexing with the induction variable
                tgt = self.var_of(env, aty)
                if tgt and not tgt.startswith("i_") and not tgt.startswith("p_"):
                    self.w(f"{tgt} = {tgt} + {arr}[{iv}]")
                if r.random() < 0.5:
                    self.w(f"{arr}[{n - 1} - {iv}] = {self.expr(env2, aty, 2)}")
                self.ind -= 1
            elif kind < 0.85:
                n = r.choice([3, 7, 10, 16])
                s = r.choice([1, 2, 3])
                self.w(f"for {iv} in {n}..0 by -{s} {{")
            else:
                n = r.choice([4, 9, 16, 30])
                s = r.choice([2, 3, 4])
                self.w(f"for {iv} in 0..{n} by {s} {{")
            env2 = dict(env)
            env2[iv] = "i64"
            self.block(env2, depth - 1, True)
            self.w("}")
        elif k < 0.90 and in_loop:
            self.w(f"if {self.expr(env, 'bool', 2)} {{")
            self.w("    " + r.choice(["break", "continue"]))
            self.w("}")
        elif k < 0.93 and getattr(self, "helpers", False):
            c = r.random()
            if c < 0.3:
                self.w(f"sv = smix(sv, {self.expr(env, 'i64', 2)})")
            elif c < 0.5:
                self.w(f"sv.{r.choice(['a', 'a', 'b', 'd'])} += {r.randint(1, 9)}")
            elif c < 0.7:
                self.w(f"rot(ga[{r.choice(['..', '2..9', '8..', '..5'])}], {self.expr(env, 'i64', 2)})")
            elif c < 0.85:
                self.tmp += 1
                self.w(f"pa_{self.tmp}, pb_{self.tmp} := pairup({self.expr(env, 'i64', 2)}, {self.expr(env, 'u32', 2)})")
                self.w(f"sv.b = sv.b + pa_{self.tmp}")
                self.w(f"sv.a = sv.a ^ pb_{self.tmp}")
            else:
                self.w(f"sv.c = sv.c * 0.5 + f64(i8({self.expr(env, 'i64', 2)}))")
        elif k < 0.95:
            self.tmp += 1
            n = f"v_{self.tmp}"
            t = r.choice(INT_TYPES + ["f64", "bool"])
            self.w(f"{n} := {self.expr(env, t, 3)}")
            env[n] = t
        else:
            if mutable:
                n = r.choice(mutable)
                self.w(f"{n} = {self.expr(env, env[n], 4)}")

    def block(self, env, depth, in_loop):
        self.ind += 1
        env = dict(env)
        for _ in range(self.r.randint(1, 4)):
            self.stmt(env, depth, in_loop)
        self.ind -= 1

    def program(self):
        r = self.r
        self.arrays = [("ga", "i64", 16), ("gb", "u32", 8), ("gc", "u8", 32), ("gd", "f64", 4), ("ge", "i16", 16)]
        for a, t, n in self.arrays:
            self.w(f"{a}: [{n}]{t}")
        self.w("")
        # fixed helpers that exercise structs, tuples, slices and run-time loop bounds
        self.w("S :: struct { a: i64, b: u32, c: f64, d: i16 }")
        self.w("smix :: (s: S, k: i64) -> S {")
        self.w("    S{a: s.a * 3 + k, b: s.b ^ u32(k), c: s.c * 0.5 + f64(s.d), d: s.d + i16(k)}")
        self.w("}")
        self.w("ssum :: (s: S) -> i64 {")
        self.w("    s.a + i64(s.b) + i64(s.c) + i64(s.d)")
        self.w("}")
        self.w("pairup :: (x: i64, y: u32) -> (u32, i64) {")
        self.w("    (y + u32(x), x - i64(y))")
        self.w("}")
        self.w("wsum :: (a: []i64, lo: i64, n: i64) -> i64 {")
        self.w("    s := 0")
        self.w("    lo = lo & 7")
        self.w("    n = min(n & 7, len(a) - lo)")
        self.w("    for i in lo..lo + n {")
        self.w("        s += a[i] * (i + 1)")
        self.w("    }")
        self.w("    i := len(a) - 1")
        self.w("    while i >= 0 && a[i] != s {")
        self.w("        s = s ^ a[i]")
        self.w("        i -= 2")
        self.w("    }")
        self.w("    s")
        self.w("}")
        self.w("rot :: (a: []i64, k: i64) {")
        self.w("    n := len(a)")
        self.w("    for r in 0..(k & 3) {")
        self.w("        t := a[0]")
        self.w("        for i in 0..n - 1 {")
        self.w("            a[i] = a[i + 1]")
        self.w("        }")
        self.w("        a[n - 1] = t + r")
        self.w("    }")
        self.w("}")
        self.w("fibr :: (n: i64) -> i64 {")
        self.w("    if n < 2 {")
        self.w("        return n")
        self.w("    }")
        self.w("    fibr(n - 1) + fibr(n - 2)")
        self.w("}")
        self.w("")
        for fi in range(r.randint(1, 4)):
            ptys = [r.choice(INT_TYPES + ["f64"]) for _ in range(r.randint(1, 4))]
            rty = r.choice(INT_TYPES + ["f64"])
            name = f"f{fi}"
            params = ", ".join(f"p_{i}: {t}" for i, t in enumerate(ptys))
            attr = r.choice(["", "", "noinline ", "inline "])
            self.w(f"{attr}{name} :: ({params}) -> {rty} {{")
            env = {f"p_{i}": t for i, t in enumerate(ptys)}
            self.ind += 1
            self.w(f"acc: {rty} = {self.expr(env, rty, 2)}")
            env["acc"] = rty
            for _ in range(r.randint(1, 5)):
                self.stmt(env, 2, False)
            self.w("return acc")
            self.ind -= 1
            self.w("}")
            self.w("")
            self.funcs.append((name, ptys, rty))
        self.w("main :: () {")
        self.ind += 1
        env = {}
        for a, t, n in self.arrays:
            self.w(f"for i in 0..{n} {{")
            if t == "f64":
                self.w(f"    {a}[i] = f64(i) * 0.75 - 1.0")
            else:
                self.w(f"    {a}[i] = {t}(i * {r.randint(3, 99)} + {r.randint(0, 50)})")
            self.w("}")
        for i, t in enumerate(INT_TYPES + ["f64", "f64", "bool", "i64", "u32"]):
            n = f"x{i}"
            self.w(f"{n}: {t} = {self.lit(t)}")
            env[n] = t
        self.w("sv := S{a: 7, b: 9, c: 1.5, d: -3}")
        self.helpers = True
        for _ in range(r.randint(4, 14)):
            self.stmt(env, 3, False)
        self.ind = 1
        self.w("print(sv.a, sv.b, sv.d)")
        self.w("putf(sv.c, 4)")
        self.w("putc('\\n')")
        names = [n for n in env if n.startswith("x")]
        for n in names:
            if env[n] == "f64":
                self.w(f"putf({n}, 6)")
                self.w("putc('\\n')")
            else:
                self.w(f"print({n})")
        for a, t, n in self.arrays:
            if t == "f64":
                self.w(f"for v in {a} {{")
                self.w("    putf(v, 6)")
                self.w("    putc(' ')")
                self.w("}")
                self.w("putc('\\n')")
            else:
                self.w(f"print({a})")
        self.ind -= 1
        self.w("}")
        return "\n".join(self.lines) + "\n"


def run(cmd, timeout=20, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -999, b"", b"timeout"


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    keep = "--keep" in sys.argv
    tmp = tempfile.mkdtemp(prefix="alfuzz")
    bad = 0
    for seed in range(first, first + count):
        src = Gen(seed).program()
        path = os.path.join(tmp, f"p{seed}.al")
        open(path, "w").write(src)
        outs = []
        failed = None
        for flags in (["-O0"], [], ["--unchecked"]):
            exe = os.path.join(tmp, "bin")
            # optimized builds also run the IR verifier after every pass
            env = dict(os.environ, ALC_DEBUG="verify") if flags != ["-O0"] else None
            code, _, err = run([ALC, "build", path, "-o", exe] + flags, env=env)
            if code != 0:
                failed = f"compile {flags}: {err.decode(errors='replace')[:300]}"
                break
            code, out, err = run([exe])
            outs.append((code, out, err[:200]))
        if failed is None:
            if not (outs[0][:2] == outs[1][:2] == outs[2][:2]):
                failed = f"outputs differ: codes {[o[0] for o in outs]} stderr {[o[2] for o in outs]}"
            elif outs[0][0] != 0:
                failed = f"program failed with code {outs[0][0]}: {outs[0][2]}"
        if failed:
            bad += 1
            dst = f"/tmp/alfuzz_fail_{seed}.al"
            open(dst, "w").write(src)
            print(f"seed {seed}: {failed}\n  saved {dst}")
            if bad >= 5:
                break
        elif not keep:
            os.remove(path)
    print(f"fuzz: {count} programs from seed {first}, {bad} failures")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
