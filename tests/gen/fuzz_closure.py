#!/usr/bin/env python3
"""Fuzzer for closures.

Generates random AL programs built from closure literals (captures by reference, nesting,
shadowing, early return, up to eight parameters, calls through higher-order functions, struct
fields, generic functions, plain functions converted to closures). The generator also evaluates
every program itself, so the output of the unoptimized, the optimized and the unchecked build
is compared with the expected one.

usage: tests/gen/fuzz_closure.py [count] [first_seed] [--keep]
"""
import os
import random
import subprocess
import sys
import tempfile

ALC = os.path.join(os.path.dirname(__file__), "..", "..", "build", "alc")
M = 1000003
NAMES = ["a", "b", "c", "d", "e", "x", "y", "z"]

PRELUDE = """const M = 1000003
struct Holder { f |i64| i64, bias i64 }
fn p_inc(a i64) i64 { (a + 1) % M }
fn p_add(a i64, b i64) i64 { (a + b) % M }
fn p_mix(a i64, b i64, c i64, d i64, e i64, f i64, g i64, h i64) i64 { (a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h) % M }
fn apply1(f |i64| i64, v i64) i64 { f(v) }
fn twice(f |i64| i64, v i64) i64 { f(f(v)) }
fn gapply[T](v T, f |T| T) T { f(v) }
fn fold(xs []i64, init i64, f |i64, i64| i64) i64 {
    acc := init
    for v in xs { acc = f(acc, v) }
    acc
}
fn sum_map(xs []i64, f |i64| i64) i64 {
    s := 0
    for v in xs { s = (s + f(v)) % M }
    s
}
fn call8(f |i64, i64, i64, i64, i64, i64, i64, i64| i64, v i64) i64 { f(v, 1, 2, 3, 4, 5, 6, 7) }
"""


class Ret(Exception):
    def __init__(self, v):
        self.v = v


class Scope:
    """One block: names visible in it. Mirrors a block scope of the generated program."""

    def __init__(self, parent):
        self.parent = parent
        self.ints = {}      # name -> may be assigned (loop variables may not)
        self.clos = {}      # name -> arity

    def all_ints(self, assignable=False):
        out = {}
        s = self
        while s:
            for n, rw in s.ints.items():
                out.setdefault(n, rw)
            s = s.parent
        return sorted(n for n, rw in out.items() if rw or not assignable)

    def all_clos(self):
        out = {}
        s = self
        while s:
            for n, a in s.clos.items():
                out.setdefault(n, a)
            s = s.parent
        return out


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.n_clos = 0

    # ---- generation: statements are tuples, see `emit` and `run` ----
    def expr(self, sc, depth):
        r = self.r
        ints = sc.all_ints()
        if depth <= 0 or r.random() < 0.25:
            if ints and r.random() < 0.75:
                return ("var", r.choice(ints))
            return ("lit", r.randint(0, 50))
        k = r.random()
        if k < 0.45:
            return ("bin", r.choice(["+", "*", "-"]), self.expr(sc, depth - 1), self.expr(sc, depth - 1))
        clos = sc.all_clos()
        if k < 0.8 and clos:
            name = r.choice(sorted(clos))
            ar = clos[name]
            if ar == 1 and r.random() < 0.6:
                how = r.choice(["apply1", "twice", "gapply", "sum_map", "holder"])
                return ("hof1", how, name, self.expr(sc, depth - 1))
            if ar == 2 and r.random() < 0.5:
                return ("fold", name, [r.randint(0, 9) for _ in range(r.randint(0, 4))], self.expr(sc, depth - 1))
            if ar == 8 and r.random() < 0.5:
                return ("call8", name, self.expr(sc, depth - 1))
            return ("call", name, [self.expr(sc, depth - 1) for _ in range(ar)])
        if k < 0.9:
            which = r.choice(["p_inc", "p_add", "p_mix"])
            if which == "p_inc":
                return ("hof1", r.choice(["apply1", "twice", "gapply", "sum_map", "holder"]), "p_inc", self.expr(sc, depth - 1))
            if which == "p_add":
                return ("fold", "p_add", [r.randint(0, 9) for _ in range(r.randint(0, 4))], self.expr(sc, depth - 1))
            return ("call8", "p_mix", self.expr(sc, depth - 1))
        return ("lit", r.randint(0, 50))

    def block(self, parent, depth, in_closure, n=None):
        r = self.r
        sc = Scope(parent)
        out = []
        for _ in range(n if n is not None else r.randint(1, 4)):
            k = r.random()
            ints = sc.all_ints()
            if k < 0.25 and sc.all_ints(True):
                out.append(("assign", r.choice(sc.all_ints(True)), self.expr(sc, 2)))
            elif k < 0.45:
                name = r.choice(NAMES)
                if name in sc.ints or name in sc.clos:
                    continue
                e = self.expr(sc, 2)
                sc.ints[name] = True
                out.append(("let", name, e))
            elif k < 0.6 and depth > 0:
                c = (self.expr(sc, 1), self.expr(sc, 1))
                out.append(("if", c, self.block(sc, depth - 1, in_closure), self.block(sc, depth - 1, in_closure)))
            elif k < 0.7 and depth > 0:
                iv = r.choice(["i", "j", "k"])
                inner = Scope(sc)
                inner.ints[iv] = False
                out.append(("for", iv, r.randint(0, 4), self.block(inner, depth - 1, in_closure)))
            elif k < 0.9 and depth > 0 and self.n_clos < 14:
                self.n_clos += 1
                name = f"f{self.n_clos}"
                ar = r.choice([0, 1, 1, 1, 2, 2, 3, 8])
                params = r.sample(NAMES, ar)
                ps = Scope(sc)
                for p in params:
                    ps.ints[p] = True
                body = self.block(ps, depth - 1, True)
                # the result expression sees the names of the body
                bs = Scope(ps)
                for st in body:
                    if st[0] == "let":
                        bs.ints[st[1]] = True
                    if st[0] == "closure":
                        bs.clos[st[1]] = len(st[2])
                res = self.expr(bs, 2)
                sc.clos[name] = ar
                out.append(("closure", name, params, body, res))
            elif k < 0.95 and in_closure and ints:
                out.append(("retif", (self.expr(sc, 1), self.expr(sc, 1)), self.expr(sc, 1)))
            elif ints:
                out.append(("print", r.choice(ints)))
        return out

    def program(self):
        top = Scope(None)
        body = []
        for i in range(self.r.randint(2, 4)):
            name = f"v{i}"
            top.ints[name] = True
            body.append(("let", name, ("lit", self.r.randint(0, 99))))
        main_sc = Scope(top)
        stmts = self.block(main_sc, 3, False, n=self.r.randint(5, 10))
        self.stmts = body + stmts
        self.final = sorted(top.ints)
        lines = [PRELUDE, "fn main() {"]
        self.emit(self.stmts, 1, lines)
        lines.append("    print(" + ", ".join(self.final) + ")")
        lines.append("}")
        return "\n".join(lines) + "\n"

    # ---- AL text ----
    def ex(self, e):
        k = e[0]
        if k == "lit":
            return str(e[1])
        if k == "var":
            return e[1]
        if k == "bin":
            a, b = self.ex(e[2]), self.ex(e[3])
            if e[1] == "-":
                return f"(({a} + M - {b}) % M)"
            return f"(({a} {e[1]} {b}) % M)"
        if k == "call":
            return f"{e[1]}({', '.join(self.ex(a) for a in e[2])})"
        if k == "hof1":
            how, name, a = e[1], e[2], self.ex(e[3])
            if how == "gapply":
                return f"gapply({a}, {name})"
            if how == "sum_map":
                return f"sum_map([]i64{{1, 2, {a}}}, {name})"
            if how == "holder":
                return f"Holder{{f: {name}, bias: 1}}.f({a})"
            return f"{how}({name}, {a})"
        if k == "fold":
            return f"fold([]i64{{{', '.join(map(str, e[2]))}}}, {self.ex(e[3])}, {e[1]})"
        if k == "call8":
            return f"call8({e[1]}, {self.ex(e[2])})"
        raise Exception(k)

    def emit(self, stmts, ind, out):
        p = "    " * ind
        for s in stmts:
            k = s[0]
            if k == "assign":
                out.append(f"{p}{s[1]} = {self.ex(s[2])}")
            elif k == "let":
                out.append(f"{p}{s[1]} := {self.ex(s[2])}")
            elif k == "print":
                out.append(f"{p}print({s[1]})")
            elif k == "if":
                out.append(f"{p}if ({self.ex(s[1][0])}) < ({self.ex(s[1][1])}) {{")
                self.emit(s[2], ind + 1, out)
                out.append(f"{p}}} else {{")
                self.emit(s[3], ind + 1, out)
                out.append(f"{p}}}")
            elif k == "for":
                out.append(f"{p}for {s[1]} in 0..{s[2]} {{")
                self.emit(s[3], ind + 1, out)
                out.append(f"{p}}}")
            elif k == "retif":
                out.append(f"{p}if ({self.ex(s[1][0])}) < ({self.ex(s[1][1])}) {{ return {self.ex(s[2])} }}")
            elif k == "closure":
                ps = ", ".join(f"{n} i64" for n in s[2])
                head = f"|{ps}|" if s[2] else "||"
                out.append(f"{p}{s[1]} := {head} i64 {{")
                self.emit(s[3], ind + 1, out)
                out.append(f"{p}    {self.ex(s[4])}")
                out.append(f"{p}}}")

    # ---- the expected output ----
    def look(self, env, name):
        for fr in reversed(env):
            if name in fr:
                return fr
        raise Exception("unbound " + name)

    def ev(self, e, env):
        k = e[0]
        if k == "lit":
            return e[1]
        if k == "var":
            return self.look(env, e[1])[e[1]]
        if k == "bin":
            a = self.ev(e[2], env)
            b = self.ev(e[3], env)
            if e[1] == "+":
                return (a + b) % M
            if e[1] == "*":
                return (a * b) % M
            return (a + M - b) % M
        if k == "call":
            f = self.fn(env, e[1])
            return f(*[self.ev(a, env) for a in e[2]])
        if k == "hof1":
            a = self.ev(e[3], env)
            f = self.fn(env, e[2])
            if e[1] == "twice":
                return f(f(a))
            if e[1] == "sum_map":
                s = 0
                for v in (1, 2, a):
                    s = (s + f(v)) % M
                return s
            return f(a)
        if k == "fold":
            acc = self.ev(e[3], env)
            f = self.fn(env, e[1])
            for v in e[2]:
                acc = f(acc, v)
            return acc
        if k == "call8":
            f = self.fn(env, e[1])
            return f(self.ev(e[2], env), 1, 2, 3, 4, 5, 6, 7)
        raise Exception(k)

    def fn(self, env, name):
        if name == "p_inc":
            return lambda a: (a + 1) % M
        if name == "p_add":
            return lambda a, b: (a + b) % M
        if name == "p_mix":
            return lambda a, b, c, d, e, f, g, h: (a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h) % M
        return self.look(env, name)[name]

    def run(self, stmts, env, out):
        env = env + [{}]
        for s in stmts:
            k = s[0]
            if k == "assign":
                v = self.ev(s[2], env)
                self.look(env, s[1])[s[1]] = v
            elif k == "let":
                # a new frame per declaration: closures made earlier do not see the name
                env = env + [{s[1]: self.ev(s[2], env)}]
            elif k == "print":
                out.append(str(self.look(env, s[1])[s[1]]))
            elif k == "if":
                # both operands are evaluated left to right
                a = self.ev(s[1][0], env)
                b = self.ev(s[1][1], env)
                self.run(s[2] if a < b else s[3], env, out)
            elif k == "for":
                for i in range(s[2]):
                    self.run(s[3], env + [{s[1]: i}], out)
            elif k == "retif":
                a = self.ev(s[1][0], env)
                b = self.ev(s[1][1], env)
                if a < b:
                    raise Ret(self.ev(s[2], env))
            elif k == "closure":
                env = env + [{s[1]: self.make(s, env, out)}]
        return env

    def make(self, s, env, out):
        def call(*args):
            frame = dict(zip(s[2], args))
            try:
                inner = self.run(s[3], env + [frame], out)
                return self.ev(s[4], inner)
            except Ret as r:
                return r.v
        return call

    def expected(self):
        out = []
        # the first statements declare v0.. in the frame the final print reads
        env = [{}]
        n_top = len(self.final)
        for s in self.stmts[:n_top]:
            env[0][s[1]] = s[2][1]
        self.run(self.stmts[n_top:], env, out)
        out.append(" ".join(str(env[0][n]) for n in self.final))
        return "\n".join(out) + "\n"


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
    tmp = tempfile.mkdtemp(prefix="alfuzzc")
    bad = 0
    for seed in range(first, first + count):
        g = Gen(seed)
        src = g.program()
        want = g.expected().encode()
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
            dst = f"/tmp/alfuzzc_fail_{seed}.al"
            open(dst, "w").write(src + "// expected:\n" + "".join("// " + l + "\n" for l in want.decode().splitlines()))
            print(f"seed {seed}: {failed}\n  saved {dst}")
            if bad >= 5:
                break
        elif not keep:
            os.remove(path)
    print(f"fuzz_closure: {count} programs from seed {first}, {bad} failures")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
