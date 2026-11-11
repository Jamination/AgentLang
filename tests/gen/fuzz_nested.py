#!/usr/bin/env python3
"""Random programs with nested and anonymous functions.

A function written inside another one is an ordinary function: it sees no variable of the
function around it, so everything it works on is a parameter (a pointer where it changes
something). The generator builds programs out of nested functions at several block depths,
functions nested in nested functions, shadowed names, recursion, anonymous functions,
function values in locals and passed to helpers, and a generic enclosing function; it
computes the expected output itself. Each program is built with -O0, default and
--unchecked.

usage: fuzz_nested.py [count] [first seed] [--keep]
"""
import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALC = os.environ.get("ALC", os.path.join(ROOT, "build", "alc"))
MASK = (1 << 20) - 1

HELPERS = """apply1 :: (f: (i64) -> i64, v: i64) -> i64 { f(v) }
twice :: (f: (i64) -> i64, v: i64) -> i64 { f(f(v) & 1048575) }
fold :: (xs: []i64, init: i64, f: (i64, i64) -> i64) -> i64 {
    acc := init
    for x in xs { acc = f(acc, x) & 1048575 }
    return acc
}
poke :: (f: (*i64, i64) -> i64, p: *i64, v: i64) -> i64 { f(p, v) + *p }
"""


class TooLong(Exception):
    pass


class Fn:
    def __init__(self, name, params, rec):
        self.name = name          # "" for an anonymous function
        self.params = params      # [(name, is_ptr)]
        self.rec = rec            # first parameter is a depth that goes down
        self.inner = []           # functions nested in this one
        self.body = []
        self.result = None

    def sig(self):
        return tuple(p[1] for p in self.params)

    def pure(self):
        return not any(p[1] for p in self.params)

    def typ(self):
        return "(" + ", ".join("*i64" if p[1] else "i64" for p in self.params) + ") -> i64"


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.steps = 0
        self.nfn = 0
        self.out = []
        self.generic = self.r.random() < 0.4
        self.main = self.block_main(0, [], [], [])

    # ---------- generation ----------
    # expressions: ("c", n) ("v", name) ("d", ptr) ("op", o, a, b) ("if", a, b, x, y)
    #              ("call", callee, args)   callee: ("fn", Fn) or ("val", local name, Fn)
    def pure(self, ints, ptrs, fns, depth, me=None):
        r = self.r
        k = r.random()
        if depth <= 0 or k < 0.25:
            c = r.random()
            if ints and c < 0.55:
                return ("v", r.choice(ints))
            if ptrs and c < 0.8:
                return ("d", r.choice(ptrs))
            return ("c", r.randint(0, 40))
        if k < 0.6:
            return ("op", r.choice("+-*&^"), self.pure(ints, ptrs, fns, depth - 1, me), self.pure(ints, ptrs, fns, depth - 1, me))
        if k < 0.7:
            return ("if", self.pure(ints, ptrs, fns, depth - 1, me), self.pure(ints, ptrs, fns, depth - 1, me),
                    self.pure(ints, ptrs, fns, depth - 1, me), self.pure(ints, ptrs, fns, depth - 1, me))
        cands = [c for c in fns if c[-1].pure() and (not c[-1].rec or c[-1] is me or c[0] == "fn")]
        if not cands:
            return self.pure(ints, ptrs, fns, depth - 1, me)
        c = r.choice(cands)
        if c[-1].rec and c[0] != "fn":
            return self.pure(ints, ptrs, fns, depth - 1, me)
        return ("call", c, self.args(c[-1], ints, ptrs, fns, depth - 1, me, []))

    def args(self, f, ints, ptrs, fns, depth, me, addr):
        out = []
        for i, (pn, is_ptr) in enumerate(f.params):
            if is_ptr:
                pick = self.r.choice(ptrs + addr)
                out.append(("p", pick) if pick in ptrs else ("a", pick))
            elif i == 0 and f.rec:
                out.append(("op", "-", ("v", me.params[0][0]), ("c", 1)) if f is me else ("c", self.r.randint(0, 5)))
            else:
                out.append(self.pure(ints, ptrs, fns, depth, me))
        return out

    # (a loop variable is not handed out by address: changing it would change the loop)
    def addressable(self, ints):
        return [n for n in ints if not n.startswith("i")]

    def new_fn(self, fns, named, level):
        r = self.r
        rec = named and r.random() < 0.2
        pool = ["v0", "v1", "v2", "a", "b", "p", "q", "n", "k"]
        r.shuffle(pool)
        n = r.randint(1, 3) if r.random() < 0.85 else r.randint(7, 9)
        params = []
        for i in range(n):
            nm = pool[i] if i < len(pool) else f"x{i}"
            params.append((nm, (not (rec and i == 0)) and r.random() < 0.3))
        if rec:
            params[0] = ("d", False)
        name = ""
        if named:
            self.nfn += 1
            # a few names are reused, so that inner declarations shadow outer ones
            name = r.choice(["h0", "h1", "h2"]) if r.random() < 0.3 else f"n{self.nfn}"
        f = Fn(name, params, rec)
        ints = [p[0] for p in params if not p[1]]
        ptrs = [p[0] for p in params if p[1]]
        vis = list(fns)
        if named:
            vis = [c for c in vis if c[-1].name != name]
            if rec:
                vis.append(("fn", f))
        taken = {name}
        if named and level < 2:
            for _ in range(r.choice([0, 0, 0, 1, 2])):
                g = self.new_fn(vis, True, level + 1)
                if g.name in taken or g.name in [p[0] for p in params]:
                    continue
                taken.add(g.name)
                f.inner.append(g)
                vis = [c for c in vis if c[-1].name != g.name] + [("fn", g)]
        f.body = self.fn_stmts(f, ints, ptrs, vis, 2)
        f.result = self.pure(ints + [s[1] for s in f.body if s[0] in ("let", "calllet")], ptrs, vis, 2, f)
        return f

    def fn_stmts(self, f, ints, ptrs, vis, depth, lets=True):
        r = self.r
        out = []
        ints = list(ints)
        for i in range(r.randint(0, 3)):
            k = r.random()
            if k < 0.35 and lets:
                nm = f"t{len(ints)}_{depth}"
                out.append(("let", nm, self.pure(ints, ptrs, vis, 2, f)))
                ints.append(nm)
            elif k < 0.65 and ptrs:
                out.append(("set", r.choice(ptrs), self.pure(ints, ptrs, vis, 2, f)))
            elif k < 0.85 and lets:
                cands = [c for c in vis if not c[-1].pure() and not c[-1].rec]
                if cands and ptrs:
                    c = r.choice(cands)
                    nm = f"t{len(ints)}_{depth}"
                    out.append(("calllet", nm, c, self.args(c[-1], ints, ptrs, vis, 1, f, [])))
                    ints.append(nm)
            elif depth > 0:
                out.append(("if", self.pure(ints, ptrs, vis, 1, f), self.pure(ints, ptrs, vis, 1, f),
                            self.fn_stmts(f, ints, ptrs, vis, depth - 1, False), []))
        return out

    # statements of the enclosing function:
    # ("let", name, expr) ("calllet", name, callee, args) ("fn", Fn) ("val", name, Fn, by_name)
    # ("help", name, helper, Fn-or-local, args) ("if", a, b, stmts) ("for", var, n, stmts) ("print", name)
    def block_main(self, depth, ints, fns, vals):
        r = self.r
        ints = list(ints)
        fns = list(fns)
        vals = list(vals)
        out = []
        declared = set()
        if depth == 0:
            for i in range(3):
                out.append(("let", f"v{i}", ("c", r.randint(0, 99))))
                ints.append(f"v{i}")
        for _ in range(r.randint(3, 8) if depth == 0 else r.randint(1, 4)):
            k = r.random()
            vis = fns + vals
            if k < 0.25:
                f = self.new_fn(fns, True, 0)
                if f.name in declared:
                    continue
                declared.add(f.name)
                out.append(("fn", f))
                fns = [c for c in fns if c[-1].name != f.name] + [("fn", f)]
            elif k < 0.4:
                nm = f"f{len(vals)}_{depth}_{len(out)}"
                cands = [c[-1] for c in fns if not c[-1].rec]
                if cands and r.random() < 0.5:
                    f = r.choice(cands)
                    out.append(("val", nm, f, True))
                else:
                    f = self.new_fn(fns, False, 0)
                    out.append(("val", nm, f, False))
                vals.append(("val", nm, f))
            elif k < 0.55:
                nm = f"v{len(ints)}_{depth}_{len(out)}"
                helper = r.choice(["apply1", "twice", "fold", "poke"])
                want = {"apply1": (False,), "twice": (False,), "fold": (False, False), "poke": (True, False)}[helper]
                cands = [c for c in vis if c[-1].sig() == want and not c[-1].rec]
                if cands and r.random() < 0.6:
                    c = r.choice(cands)
                    fa = ("name", c[-1]) if c[0] == "fn" else ("local", c[1], c[-1])
                else:
                    f = Fn("", [(n, p) for n, p in zip(["a", "b"], want)], False)
                    fi = [p[0] for p in f.params if not p[1]]
                    fp = [p[0] for p in f.params if p[1]]
                    f.body = self.fn_stmts(f, fi, fp, fns, 1)
                    f.result = self.pure(fi + [s[1] for s in f.body if s[0] in ("let", "calllet")], fp, fns, 2, f)
                    fa = ("anon", f)
                if helper == "fold":
                    extra = [[r.randint(0, 50) for _ in range(r.randint(0, 5))], self.pure(ints, [], vis, 1)]
                elif helper == "poke":
                    extra = [r.choice(self.addressable(ints)), self.pure(ints, [], vis, 1)]
                else:
                    extra = [self.pure(ints, [], vis, 2)]
                out.append(("help", nm, helper, fa, extra))
                ints.append(nm)
            elif k < 0.75:
                nm = f"v{len(ints)}_{depth}_{len(out)}"
                cands = [c for c in vis if not c[-1].pure() and not c[-1].rec]
                if cands and r.random() < 0.6:
                    c = r.choice(cands)
                    out.append(("calllet", nm, c, self.args(c[-1], ints, [], vis, 2, None, self.addressable(ints))))
                else:
                    out.append(("let", nm, self.pure(ints, [], vis, 3)))
                ints.append(nm)
            elif k < 0.85 and depth < 2:
                out.append(("if", self.pure(ints, [], vis, 1), self.pure(ints, [], vis, 1), self.block_main(depth + 1, ints, fns, vals)))
            elif k < 0.93 and depth < 2:
                iv = f"i{depth}"
                out.append(("for", iv, r.randint(1, 3), self.block_main(depth + 1, ints + [iv], fns, vals)))
            else:
                out.append(("print", r.choice(ints)))
        for nm in ints:
            if any(s[0] in ("let", "calllet", "help") and s[1] == nm for s in out):
                out.append(("print", nm))
        return out

    # ---------- source ----------
    def e(self, x):
        t = x[0]
        if t == "c":
            return str(x[1])
        if t == "v":
            return x[1]
        if t == "d":
            return "*" + x[1]
        if t == "op":
            s = f"({self.e(x[2])} {x[1]} {self.e(x[3])})"
            return f"({s} & {MASK})" if x[1] == "*" else s
        if t == "if":
            return f"(if {self.e(x[1])} < {self.e(x[2])} {{ {self.e(x[3])} }} else {{ {self.e(x[4])} }})"
        return self.call(x[1], x[2])

    def call(self, c, args):
        name = c[-1].name if c[0] == "fn" else c[1]
        parts = []
        for a in args:
            if a[0] == "p":
                parts.append(a[1])
            elif a[0] == "a":
                parts.append("&" + a[1])
            else:
                parts.append(self.e(a))
        # method-call syntax now and then
        if parts and c[0] == "fn" and len(parts[0]) < 12 and parts[0].replace("_", "a").isalnum() and self.r.random() < 0.2:
            return f"{parts[0]}.{name}({', '.join(parts[1:])})"
        return f"{name}({', '.join(parts)})"

    def fn_src(self, f, ind):
        pad = "    " * ind
        ps = ", ".join(f"{n}: {'*i64' if p else 'i64'}" for n, p in f.params)
        lines = [f"{f.name} :: ({ps}) -> i64 {{" if f.name else f"({ps}) -> i64 {{"]
        if f.rec:
            lines.append(f"{pad}    if d <= 0 {{ return {len(f.params)} }}")
        for g in f.inner:
            lines.append(pad + "    " + self.fn_src(g, ind + 1))
        lines += self.fn_body_src(f.body, ind + 1)
        lines.append(f"{pad}    return {self.e(f.result)} & {MASK}")
        lines.append(pad + "}")
        return "\n".join(lines)

    def fn_body_src(self, body, ind):
        pad = "    " * ind
        out = []
        for s in body:
            if s[0] == "let":
                out.append(f"{pad}{s[1]} := {self.e(s[2])} & {MASK}")
            elif s[0] == "set":
                out.append(f"{pad}*{s[1]} = {self.e(s[2])} & {MASK}")
            elif s[0] == "calllet":
                out.append(f"{pad}{s[1]} := {self.call(s[2], s[3])}")
            else:
                out.append(f"{pad}if {self.e(s[1])} < {self.e(s[2])} {{")
                out += self.fn_body_src(s[3], ind + 1)
                out.append(pad + "}")
        return out

    def main_src(self, stmts, ind):
        pad = "    " * ind
        out = []
        for s in stmts:
            t = s[0]
            if t == "let":
                out.append(f"{pad}{s[1]} := {self.e(s[2])} & {MASK}")
            elif t == "calllet":
                out.append(f"{pad}{s[1]} := {self.call(s[2], s[3])}")
            elif t == "fn":
                out.append(pad + self.fn_src(s[1], ind))
            elif t == "val":
                if s[3]:
                    form = self.r.choice([f"{s[1]} := {s[2].name}", f"{s[1]}: {s[2].typ()} = {s[2].name}"])
                    out.append(pad + form)
                else:
                    out.append(f"{pad}{s[1]} := {self.fn_src(s[2], ind)}")
            elif t == "help":
                fa = s[3]
                fs = fa[1].name if fa[0] == "name" else fa[1] if fa[0] == "local" else self.fn_src(fa[1], ind)
                x = s[4]
                if s[2] == "fold":
                    rest = f"[]i64{{{', '.join(map(str, x[0]))}}}, {self.e(x[1])} & {MASK}, {fs}"
                    out.append(f"{pad}{s[1]} := fold({rest})")
                elif s[2] == "poke":
                    out.append(f"{pad}{s[1]} := poke({fs}, &{x[0]}, {self.e(x[1])} & {MASK}) & {MASK}")
                else:
                    out.append(f"{pad}{s[1]} := {s[2]}({fs}, {self.e(x[0])} & {MASK})")
            elif t == "if":
                out.append(f"{pad}if {self.e(s[1])} < {self.e(s[2])} {{")
                out += self.main_src(s[3], ind + 1)
                out.append(pad + "}")
            elif t == "for":
                out.append(f"{pad}for {s[1]} in 0..{s[2]} {{")
                out += self.main_src(s[3], ind + 1)
                out.append(pad + "}")
            else:
                out.append(f"{pad}print({s[1]})")
        return out

    def program(self):
        body = "\n".join(self.main_src(self.main, 1))
        if self.generic:
            return (HELPERS + "run[T] :: (tag: T) {\n    same :: (x: T, y: T) -> T { y }\n    first :: (xs: []T) -> T { xs[0] }\n"
                    + body + "\n    print(same(tag, first([]T{tag, tag})))\n}\nmain :: () {\n    run(7)\n    run(\"s\")\n}\n")
        return HELPERS + "main :: () {\n" + body + "\n}\n"

    # ---------- evaluation ----------
    def tick(self):
        self.steps += 1
        if self.steps > 200000:
            raise TooLong()

    def ev(self, x, env):
        self.tick()
        t = x[0]
        if t == "c":
            return x[1]
        if t == "v":
            return env[x[1]][0]
        if t == "d":
            return env[x[1]][0]
        if t == "op":
            a = self.ev(x[2], env)
            b = self.ev(x[3], env)
            o = x[1]
            if o == "+":
                return a + b
            if o == "-":
                return a - b
            if o == "*":
                return (a * b) & MASK
            if o == "&":
                return a & b
            return a ^ b
        if t == "if":
            return self.ev(x[3], env) if self.ev(x[1], env) < self.ev(x[2], env) else self.ev(x[4], env)
        return self.do_call(x[1][-1], x[2], env)

    def do_call(self, f, args, env):
        vals = []
        for a in args:
            if a[0] in ("p", "a"):
                vals.append(env[a[1]])
            else:
                vals.append([self.ev(a, env)])
        return self.invoke(f, vals)

    # `cells`: one cell per parameter; a pointer parameter shares the cell of what it points to
    def invoke(self, f, cells):
        self.tick()
        env = {}
        for (n, is_ptr), c in zip(f.params, cells):
            env[n] = c if is_ptr else [c[0]]
        if f.rec and env["d"][0] <= 0:
            return len(f.params)
        self.fn_body(f.body, env)
        return self.ev(f.result, env) & MASK

    def fn_body(self, body, env):
        for s in body:
            if s[0] == "let":
                env[s[1]] = [self.ev(s[2], env) & MASK]
            elif s[0] == "set":
                env[s[1]][0] = self.ev(s[2], env) & MASK
            elif s[0] == "calllet":
                env[s[1]] = [self.do_call(s[2][-1], s[3], env)]
            elif self.ev(s[1], env) < self.ev(s[2], env):
                self.fn_body(s[3], env)

    def run_main(self, stmts, env):
        for s in stmts:
            t = s[0]
            if t == "let":
                env[s[1]] = [self.ev(s[2], env) & MASK]
            elif t == "calllet":
                env[s[1]] = [self.do_call(s[2][-1], s[3], env)]
            elif t == "help":
                f = s[3][-1]
                x = s[4]
                if s[2] == "apply1":
                    v = self.invoke(f, [[self.ev(x[0], env) & MASK]])
                elif s[2] == "twice":
                    v = self.invoke(f, [[self.invoke(f, [[self.ev(x[0], env) & MASK]]) & MASK]])
                elif s[2] == "fold":
                    v = self.ev(x[1], env) & MASK
                    for y in x[0]:
                        v = self.invoke(f, [[v], [y]]) & MASK
                else:
                    cell = env[x[0]]
                    v = self.invoke(f, [cell, [self.ev(x[1], env) & MASK]])
                    v = (v + cell[0]) & MASK
                env[s[1]] = [v]
            elif t == "if":
                if self.ev(s[1], env) < self.ev(s[2], env):
                    self.run_main(s[3], dict(env))
            elif t == "for":
                for i in range(s[2]):
                    inner = dict(env)
                    inner[s[1]] = [i]
                    self.run_main(s[3], inner)
            elif t == "print":
                self.out.append(str(env[s[1]][0]))

    def expected(self):
        self.out = []
        self.steps = 0
        self.run_main(self.main, {})
        text = "".join(l + "\n" for l in self.out)
        if self.generic:
            return text + "7\n" + text + "s\n"
        return text


def run(cmd, timeout=20, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, b"", b"timeout"


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    keep = "--keep" in sys.argv
    tmp = tempfile.mkdtemp(prefix="alfuzzn")
    bad = 0
    for seed in range(first, first + count):
        g = Gen(seed)
        src = g.program()
        try:
            want = g.expected().encode()
        except (TooLong, RecursionError):
            continue
        path = os.path.join(tmp, f"p{seed}.al")
        open(path, "w").write(src)
        failed = None
        for flags in (["-O0"], [], ["--unchecked"]):
            exe = os.path.join(tmp, "bin")
            env = dict(os.environ, ALC_DEBUG="verify") if flags != ["-O0"] else None
            code, _, err = run([ALC, "build", path, "-o", exe] + flags, env=env)
            if code != 0:
                failed = f"compile {flags}: {err.decode(errors='replace')[:300]}"
                break
            code, out, err = run([exe])
            if code != 0:
                failed = f"{flags}: exit code {code}: {err[:200]}"
                break
            if out != want:
                failed = f"{flags}: output differs from the expected one"
                break
        if failed:
            bad += 1
            dst = f"/tmp/alfuzzn_fail_{seed}.al"
            open(dst, "w").write(src + "// expected:\n" + "".join("// " + l + "\n" for l in want.decode().splitlines()))
            print(f"seed {seed}: {failed}\n  saved {dst}")
            if bad >= 5:
                break
        elif not keep:
            os.remove(path)
    print(f"fuzz_nested: {count} programs from seed {first}, {bad} failures")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
