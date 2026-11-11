#!/usr/bin/env python3
"""Differential fuzzer for f32 / vector code generation.

Random programs over f32, vec2, vec3, vec4, quat and mat4 values (arithmetic, swizzles, component
stores, arrays, structs, calls) must print the same bytes unoptimized, optimized and unchecked.

usage: tests/gen/fuzz_vec.py [count] [first_seed]
"""
import os
import random
import subprocess
import sys
import tempfile

ALC = os.path.join(os.path.dirname(__file__), "..", "..", "build", "alc")
LANES = {"vec2": 2, "vec3": 3, "vec4": 4, "quat": 4}
COMP = "xyzw"


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.out = []
        self.funcs = []

    def flit(self):
        return self.r.choice(["0.5", "1.5", "2.0", "0.25", "3.0", "-1.0", "0.125", "7.0", "1.0", "-0.75"])

    def var_of(self, env, ty):
        c = [n for n, t in env.items() if t == ty]
        return self.r.choice(c) if c else None

    def expr(self, env, ty, d):
        r = self.r
        if d <= 0 or r.random() < 0.12:
            v = self.var_of(env, ty)
            if v and r.random() < 0.75:
                return v
            if ty == "f32":
                return f"f32({self.flit()})"
            if ty == "mat4":
                return "mat4(1.0)"
            n = LANES[ty]
            if r.random() < 0.3:
                return f"{ty}({self.flit()})"
            return f"{ty}({', '.join(self.flit() for _ in range(n))})"
        k = r.random()
        if ty == "f32":
            if k < 0.35:
                op = r.choice(["+", "-", "*"])
                return f"({self.expr(env, 'f32', d - 1)} {op} {self.expr(env, 'f32', d - 1)})"
            if k < 0.6:
                vt = r.choice(list(LANES))
                c = COMP[r.randrange(LANES[vt])]
                return f"{self.expr(env, vt, d - 1)}.{c}"
            if k < 0.7:
                return f"fmin({self.expr(env, 'f32', d - 1)}, {self.expr(env, 'f32', d - 1)})"
            if k < 0.8:
                return f"sqrt(fabs({self.expr(env, 'f32', d - 1)}))"
            if k < 0.9 and self.funcs:
                return self.call(env, "f32", d)
            vt = r.choice(["vec3", "vec4"])
            return f"{self.expr(env, vt, d - 1)}[{r.randrange(LANES[vt])}]"
        if ty == "mat4":
            if k < 0.4:
                return f"({self.expr(env, 'mat4', d - 1)} * {self.expr(env, 'mat4', d - 1)})"
            if k < 0.8:
                return f"mat4({', '.join(self.expr(env, 'vec4', d - 1) for _ in range(4))})"
            return self.var_of(env, "mat4") or "mat4(2.0)"
        n = LANES[ty]
        if k < 0.3:
            op = r.choice(["+", "-", "*"])
            return f"({self.expr(env, ty, d - 1)} {op} {self.expr(env, ty, d - 1)})"
        if k < 0.45:
            op = r.choice(["+", "-", "*"])
            if r.random() < 0.5:
                return f"({self.expr(env, ty, d - 1)} {op} {self.expr(env, 'f32', d - 1)})"
            return f"({self.expr(env, 'f32', d - 1)} {op} {self.expr(env, ty, d - 1)})"
        if k < 0.6 and ty != "quat":
            src = r.choice([t for t in ("vec2", "vec3", "vec4") if True])
            sw = "".join(COMP[r.randrange(LANES[src])] for _ in range(n))
            return f"{self.expr(env, src, d - 1)}.{sw}"
        if k < 0.7:
            return f"-{self.expr(env, ty, d - 1)}"
        if k < 0.78:
            return f"fmax({self.expr(env, ty, d - 1)}, {self.expr(env, ty, d - 1)})"
        if k < 0.84 and ty == "vec4":
            return f"({self.expr(env, 'mat4', d - 1)} * {self.expr(env, 'vec4', d - 1)})"
        if k < 0.88 and ty == "vec3":
            return f"vec3({self.expr(env, 'vec4', d - 1)})"
        if k < 0.92 and ty == "vec4":
            return f"vec4({self.expr(env, 'vec3', d - 1)}, {self.expr(env, 'f32', d - 1)})"
        if k < 0.96 and self.funcs:
            return self.call(env, ty, d)
        return f"{ty}({', '.join(self.expr(env, 'f32', d - 1) for _ in range(n))})"

    def call(self, env, ty, d):
        c = [f for f in self.funcs if f[2] == ty]
        if not c:
            return self.expr(env, ty, 0)
        name, ptys, _ = self.r.choice(c)
        return f"{name}({', '.join(self.expr(env, t, d - 1) for t in ptys)})"

    def stmts(self, env, n, ind, loop_depth):
        r = self.r
        pad = "    " * ind
        for _ in range(n):
            k = r.random()
            ty = r.choice(["f32", "vec2", "vec3", "vec3", "vec4", "quat", "mat4"])
            if k < 0.3:
                v = self.var_of(env, ty)
                if v:
                    self.out.append(f"{pad}{v} = {self.expr(env, ty, 3)}")
            elif k < 0.45:
                vt = r.choice(list(LANES))
                v = self.var_of(env, vt)
                if v:
                    c = COMP[r.randrange(LANES[vt])]
                    op = r.choice(["=", "+=", "*="])
                    self.out.append(f"{pad}{v}.{c} {op} {self.expr(env, 'f32', 2)}")
            elif k < 0.55:
                self.out.append(f"{pad}ga[{r.randrange(8)}] = {self.expr(env, 'vec3', 3)}")
            elif k < 0.62:
                self.out.append(f"{pad}gs.p = {self.expr(env, 'vec3', 2)}")
                self.out.append(f"{pad}gs.c = gs.c + {self.expr(env, 'vec4', 2)}")
            elif k < 0.7:
                v = self.var_of(env, "mat4")
                if v:
                    self.out.append(f"{pad}{v}[{r.randrange(4)}] = {self.expr(env, 'vec4', 2)}")
            elif k < 0.8 and loop_depth < 2:
                i = f"i{len(self.out)}"
                self.out.append(f"{pad}for {i} in 0..{r.randint(1, 6)} {{")
                self.stmts(env, r.randint(1, 3), ind + 1, loop_depth + 1)
                v = self.var_of(env, "vec3")
                if v:
                    self.out.append(f"{pad}    {v} = {v} * 0.5 + ga[{i} & 7]")
                self.out.append(f"{pad}}}")
            elif k < 0.9:
                a, b = self.expr(env, "f32", 2), self.expr(env, "f32", 2)
                self.out.append(f"{pad}if {a} < {b} {{")
                self.stmts(env, r.randint(1, 2), ind + 1, loop_depth)
                self.out.append(f"{pad}}} else {{")
                self.stmts(env, 1, ind + 1, loop_depth)
                self.out.append(f"{pad}}}")
            else:
                vt = r.choice(["vec3", "vec4"])
                self.out.append(f"{pad}if {self.expr(env, vt, 2)} == {self.expr(env, vt, 1)} {{ gf += 1.0 }}")

    def program(self):
        r = self.r
        self.out.append("struct S { p vec3, c vec4, k f32 }")
        self.out.append("var ga [8]vec3")
        self.out.append("var gs S")
        self.out.append("var gf f32")
        for fi in range(r.randint(1, 4)):
            ptys = [r.choice(["f32", "vec2", "vec3", "vec4", "quat", "mat4"]) for _ in range(r.randint(1, 5))]
            rt = r.choice(["f32", "vec2", "vec3", "vec4", "quat"])
            env = {f"p{i}": t for i, t in enumerate(ptys)}
            ps = ", ".join(f"p{i} {t}" for i, t in enumerate(ptys))
            self.out.append(f"fn f{fi}({ps}) {rt} {{")
            self.stmts(env, r.randint(0, 3), 1, 1)
            self.out.append(f"    return {self.expr(env, rt, 3)}")
            self.out.append("}")
            self.funcs.append((f"f{fi}", ptys, rt))
        self.out.append("fn show(v vec4) {")
        self.out.append("    print(hex(u64(cast[u32](v.x))), hex(u64(cast[u32](v.y))), hex(u64(cast[u32](v.z))), hex(u64(cast[u32](v.w))))")
        self.out.append("}")
        self.out.append("fn main() {")
        self.out.append("    for i in 0..8 { ga[i] = vec3(f32(i), f32(i) * 0.5, 1.0 - f32(i)) }")
        env = {}
        for i, t in enumerate(["f32", "f32", "vec2", "vec3", "vec3", "vec4", "vec4", "quat", "mat4"]):
            env[f"x{i}"] = t
            self.out.append(f"    var x{i} {t} = {self.expr({}, t, 1)}")
        self.stmts(env, r.randint(6, 16), 1, 0)
        for n, t in env.items():
            if t == "f32":
                self.out.append(f"    show(vec4({n}))")
            elif t == "mat4":
                self.out.append(f"    for c in 0..4 {{ show({n}[c]) }}")
            elif t == "vec2":
                self.out.append(f"    show(vec4({n}, 0.0, 0.0))")
            elif t == "vec3":
                self.out.append(f"    show(vec4({n}, 0.0))")
            else:
                self.out.append(f"    show(vec4({n}))")
        self.out.append("    for i in 0..8 { show(vec4(ga[i], gf)) }")
        self.out.append("    show(vec4(gs.p, gs.k) + gs.c)")
        self.out.append("}")
        return "\n".join(self.out) + "\n"


def run(seed, tmp):
    src = os.path.join(tmp, "f.al")
    with open(src, "w") as f:
        f.write(Gen(seed).program())
    outs = []
    for flags in (["-O0"], [], ["--unchecked"]):
        env = dict(os.environ, ALC_DEBUG="verify")
        c = subprocess.run([ALC, "build", src, "-o", os.path.join(tmp, "f")] + flags, capture_output=True, env=env, timeout=120)
        if c.returncode != 0:
            return f"compile failed {flags}: {c.stderr.decode()[:400]}"
        try:
            p = subprocess.run([os.path.join(tmp, "f")], capture_output=True, timeout=20)
        except subprocess.TimeoutExpired:
            return f"timeout {flags}"
        outs.append((p.returncode, p.stdout))
    if outs[0] != outs[1] or outs[0] != outs[2]:
        return f"outputs differ: codes {[o[0] for o in outs]}"
    if outs[0][0] != 0:
        return f"exit code {outs[0][0]}"
    return None


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    fails = 0
    with tempfile.TemporaryDirectory() as tmp:
        for seed in range(first, first + count):
            err = run(seed, tmp)
            if err:
                fails += 1
                keep = f"/tmp/alfuzzvec_fail_{seed}.al"
                os.replace(os.path.join(tmp, "f.al"), keep)
                print(f"seed {seed}: {err}\n  saved {keep}")
    print(f"fuzz_vec: {count} programs from seed {first}, {fails} failures")
    sys.exit(1 if fails else 0)


main()
