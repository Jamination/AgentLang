#!/usr/bin/env python3
"""Fuzzer for nested functions.

Generates random AL programs built from nested functions: reads and writes of the variables
of the enclosing functions, functions nested in functions, shadowing, early return, recursion,
calls between nested functions (which forwards what the callee uses), up to eight parameters,
method-call syntax, and nested functions that use no outer variable passed as plain function
values (to higher-order and generic functions, in a struct field). The generator evaluates
every program itself, so the output of the unoptimized, the optimized (with the IR verifier)
and the unchecked build is compared with the expected one.

usage: tests/gen/fuzz_nested.py [count] [first_seed] [--keep]
"""
import os
import random
import subprocess
import sys
import tempfile

ALC = os.path.join(os.path.dirname(__file__), "..", "..", "build", "alc")
M = 1000003
NAMES = ["a", "b", "c", "d", "e", "x", "y", "z"]
INF = 1 << 30

PRELUDE = """const M = 1000003
struct Holder { f fn(i64) i64, bias i64 }
fn p_inc(a i64) i64 { (a + 1) % M }
fn p_add(a i64, b i64) i64 { (a + b) % M }
fn p_mix(a i64, b i64, c i64, d i64, e i64, f i64, g i64, h i64) i64 { (a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h) % M }
fn apply1(f fn(i64) i64, v i64) i64 { f(v) }
fn twice(f fn(i64) i64, v i64) i64 { f(f(v)) }
fn gapply[T](v T, f fn(T) T) T { f(v) }
fn fold(xs []i64, init i64, f fn(i64, i64) i64) i64 {
    acc := init
    for v in xs { acc = f(acc, v) }
    acc
}
fn sum_map(xs []i64, f fn(i64) i64) i64 {
    s := 0
    for v in xs { s = (s + f(v)) % M }
    s
}
fn call8(f fn(i64, i64, i64, i64, i64, i64, i64, i64) i64, v i64) i64 { f(v, 1, 2, 3, 4, 5, 6, 7) }
"""


class Ret(Exception):
    def __init__(self, v):
        self.v = v


class TooLong(Exception):
    """The program runs too many statements (nested loops and recursion multiply)."""


class Fn:
    """A nested function known to the generator."""

    def __init__(self, name, arity, rec, level):
        self.name = name
        self.arity = arity      # declared parameters (a recursive one has its depth first)
        self.rec = rec
        self.level = level      # level of its body
        # lowest level of a variable it needs (directly or through a callee); INF: none, so
        # it is a plain function value
        self.need = INF


class Scope:
    """One block: the names declared in it. `level` counts the enclosing functions."""

    def __init__(self, parent, level):
        self.parent = parent
        self.level = level
        self.ints = {}      # name -> may be assigned (loop variables and depths may not)
        self.fns = {}       # name -> Fn

    def all_ints(self, assignable=False):
        out = {}
        s = self
        while s:
            for n, rw in s.ints.items():
                out.setdefault(n, (rw, s.level))
            s = s.parent
        return {n: v[1] for n, v in out.items() if v[0] or not assignable}

    def all_fns(self):
        out = {}
        s = self
        while s:
            for n, f in s.fns.items():
                out.setdefault(n, f)
            s = s.parent
        return out


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.n_fns = 0
        self.stack = []     # the nested functions whose bodies are being generated
        # the lowest function level whose variables may be used (above 0 inside a function
        # that is to be a plain function value)
        self.floor = 0

    def need(self, level):
        """The code being generated uses a variable of function level `level`."""
        for f in self.stack:
            if f.level > level:
                f.need = min(f.need, level)

    def var(self, sc, assignable=False):
        ints = {n: l for n, l in sc.all_ints(assignable).items() if l >= self.floor}
        if not ints:
            return None
        n = self.r.choice(sorted(ints))
        self.need(ints[n])
        return n

    # ---- generation: statements are tuples, see `emit` and `run` ----
    def expr(self, sc, depth):
        r = self.r
        if depth <= 0 or r.random() < 0.25:
            v = self.var(sc) if r.random() < 0.75 else None
            return ("var", v) if v else ("lit", r.randint(0, 50))
        k = r.random()
        if k < 0.45:
            return ("bin", r.choice(["+", "*", "-"]), self.expr(sc, depth - 1), self.expr(sc, depth - 1))
        # (a function is not called from inside itself, except by the recursion pattern)
        fns = {n: f for n, f in sc.all_fns().items() if f not in self.stack and (f.need == INF or f.need >= self.floor)}
        if k < 0.8 and fns:
            f = fns[r.choice(sorted(fns))]
            if f.need != INF:
                self.need(f.need)
            elif not f.rec and r.random() < 0.5:
                # a function that uses no outer variable is a value
                if f.arity == 1:
                    return ("hof1", r.choice(["apply1", "twice", "gapply", "sum_map", "holder"]), f.name, self.expr(sc, depth - 1))
                if f.arity == 2:
                    return ("fold", f.name, [r.randint(0, 9) for _ in range(r.randint(0, 4))], self.expr(sc, depth - 1))
                if f.arity == 8:
                    return ("call8", f.name, self.expr(sc, depth - 1))
            args = [self.expr(sc, depth - 1) for _ in range(f.arity)]
            if f.rec:
                args[0] = ("lit", r.randint(0, 3))
            return ("call", f.name, args, f.arity >= 1 and not f.rec and r.random() < 0.3)
        if k < 0.9:
            which = r.choice(["p_inc", "p_add", "p_mix"])
            if which == "p_inc":
                return ("hof1", r.choice(["apply1", "twice", "gapply", "sum_map", "holder"]), "p_inc", self.expr(sc, depth - 1))
            if which == "p_add":
                return ("fold", "p_add", [r.randint(0, 9) for _ in range(r.randint(0, 4))], self.expr(sc, depth - 1))
            return ("call8", "p_mix", self.expr(sc, depth - 1))
        return ("lit", r.randint(0, 50))

    def block(self, parent, depth, n=None):
        r = self.r
        sc = Scope(parent, parent.level)
        out = []
        for _ in range(n if n is not None else r.randint(1, 4)):
            k = r.random()
            if k < 0.25:
                v = self.var(sc, assignable=True)
                if v:
                    out.append(("assign", v, self.expr(sc, 2)))
            elif k < 0.45:
                name = r.choice(NAMES)
                if name in sc.ints or name in sc.fns:
                    continue
                e = self.expr(sc, 2)
                sc.ints[name] = True
                out.append(("let", name, e))
            elif k < 0.6 and depth > 0:
                c = (self.expr(sc, 1), self.expr(sc, 1))
                out.append(("if", c, self.block(sc, depth - 1), self.block(sc, depth - 1)))
            elif k < 0.7 and depth > 0:
                iv = r.choice(["i", "j", "k"])
                inner = Scope(sc, sc.level)
                inner.ints[iv] = False
                out.append(("for", iv, r.randint(0, 4), self.block(inner, depth - 1)))
            elif k < 0.9 and depth > 0 and self.n_fns < 14:
                out.append(self.function(sc, depth))
            elif k < 0.95 and self.stack:
                out.append(("retif", (self.expr(sc, 1), self.expr(sc, 1)), self.expr(sc, 1)))
            else:
                v = self.var(sc)
                if v:
                    out.append(("print", v))
        return out

    def function(self, sc, depth):
        r = self.r
        self.n_fns += 1
        name = f"f{self.n_fns}"
        rec = r.random() < 0.2
        own_pure = r.random() < 0.3     # uses nothing of the enclosing functions
        ar = r.choice([0, 1, 1, 1, 2, 2, 3, 8])
        params = r.sample(NAMES, ar)
        if rec:
            params = ["dep"] + params
        f = Fn(name, len(params), rec, sc.level + 1)
        ps = Scope(sc, sc.level + 1)
        for p in params:
            ps.ints[p] = p != "dep"
        self.stack.append(f)
        save_floor = self.floor
        if own_pure:
            self.floor = f.level
        body = self.block(ps, depth - 1)
        # the result expression sees the names of the body
        bs = Scope(ps, ps.level)
        for st in body:
            if st[0] == "let":
                bs.ints[st[1]] = True
            if st[0] == "fn":
                bs.fns[st[1].name] = st[1]
        res = self.expr(bs, 2)
        if rec:
            args = [("bin", "-", ("var", "dep"), ("lit", 1))] + [self.expr(bs, 1) for _ in range(len(params) - 1)]
            res = ("bin", "+", ("call", name, args, False), res)
            body = [("retif", (("var", "dep"), ("lit", 1)), self.expr(ps, 1))] + body
        self.stack.pop()
        self.floor = save_floor
        # what it needs below its own level is needed by the function around it too
        if f.need != INF:
            self.need(f.need)
        sc.fns[name] = f
        return ("fn", f, params, body, res)

    def program(self):
        top = Scope(None, 0)
        body = []
        for i in range(self.r.randint(2, 4)):
            name = f"v{i}"
            top.ints[name] = True
            body.append(("let", name, ("lit", self.r.randint(0, 99))))
        stmts = self.block(top, 3, n=self.r.randint(5, 10))
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
            args = [self.ex(a) for a in e[2]]
            if e[3]:
                # method-call syntax
                return f"({args[0]}).{e[1]}({', '.join(args[1:])})"
            return f"{e[1]}({', '.join(args)})"
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
            elif k == "fn":
                ps = ", ".join(f"{n} i64" for n in s[2])
                out.append(f"{p}fn {s[1].name}({ps}) i64 {{")
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
            self.steps += 1
            if self.steps > 100000:
                raise TooLong()
            k = s[0]
            if k == "assign":
                v = self.ev(s[2], env)
                self.look(env, s[1])[s[1]] = v
            elif k == "let":
                # a new frame per declaration: functions declared earlier do not see the name
                env = env + [{s[1]: self.ev(s[2], env)}]
            elif k == "print":
                out.append(str(self.look(env, s[1])[s[1]]))
            elif k == "if":
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
            elif k == "fn":
                frame = {}
                env = env + [frame]
                # (the function sees itself)
                frame[s[1].name] = self.make(s, env, out)
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
        self.steps = 0
        out = []
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
