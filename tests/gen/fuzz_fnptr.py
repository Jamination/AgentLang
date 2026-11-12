#!/usr/bin/env python3
"""Random programs whose functions are reached only through function values stored in data.

Top-level functions are never called by name from `main`: they sit in globals, constants
(also constants naming other constants), struct fields, nested structs, arrays, tuples, `Vec`s
(also inside a struct) and `Map` values, and call chains of further top-level functions by
name. Functions with nested and anonymous functions store those (and more anonymous ones) into
the mutable containers at run time; `main` keeps function values in local containers as well.
A rank on every function and container rules out recursion: a function only calls functions
and containers whose contents have a higher rank. The generator computes the expected output
itself. Each program is built with -O0, default and --unchecked.

usage: fuzz_fnptr.py [count] [first seed] [--keep]
"""
import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ALC = os.environ.get("ALC", os.path.join(ROOT, "build", "alc"))
MASK = (1 << 20) - 1
T = {1: "fn(i64) -> i64", 2: "fn(i64, i64) -> i64"}
NONE = -10 ** 9          # the rank of `main` and of the setters: may call everything

HEADER = """struct Ops { k: i64, f: fn(i64) -> i64, g: fn(i64, i64) -> i64 }
struct Nest { ops: Ops, tab: [3]fn(i64) -> i64 }
struct Reg { n: i64, fs: Vec[fn(i64) -> i64] }
fn apply1(f: fn(i64) -> i64, v: i64) -> i64 { f(v) & 1048575 }
fn mget(m: *Map[i64, fn(i64) -> i64], k: i64) -> fn(i64) -> i64 {
    f, ok := m.get(k)
    assert ok
    f
}
"""


class TooLong(Exception):
    pass


class Fn:
    def __init__(self, name, arity, rank, kind):
        self.name = name          # "" for an anonymous function
        self.arity = arity
        self.rank = rank
        self.kind = kind          # "top", "setter", "nested", "anon"
        self.nested = []          # functions declared at the start of the body
        self.body = []            # ("let", name, e) ("fnlet", name, Fn) ("store", Slot, i, ref)
        self.result = ("c", 0)

    @property
    def params(self):
        return ["x", "y"][:self.arity]


class Slot:
    """One place holding function values: a variable, a field, all elements of an array."""

    def __init__(self, sid, arity, rank, n, mutable, local, access):
        self.sid = sid
        self.arity = arity
        self.rank = rank          # every function stored here has a higher rank
        self.n = n                # elements
        self.mutable = mutable
        self.local = local        # a local variable of `main`
        self.access = access      # source of element i: a function of the index source
        self.store_src = None     # source of `element i = value`
        self.init = []            # initial contents (Fn per element)
        self.key = False          # a Map: element i has the key 7 * i + 1
        self.default = None       # the default of `get_or` for a Map


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.steps = 0
        self.nid = 0
        self.slots = []
        self.decls = []           # top-level declarations (source)
        self.main_init = []       # main: filling the containers
        r = self.r
        n = r.randint(5, 13)
        self.tops = [Fn(f"f{i}", 1 if r.random() < 0.7 else 2, i, "top") for i in range(n)]
        for a in (1, 2):
            if not any(f.arity == a for f in self.tops[1:]):
                self.tops[-1 if a == 2 else 0].arity = a
        self.make_slots()
        for f in self.tops:
            self.fill_fn(f, f.rank)
        self.setters = []
        for i in range(r.randint(1, 4)):
            s = Fn(f"s{i}", 1, NONE, "setter")
            self.fill_setter(s)
            self.setters.append(s)
        self.main = self.make_main()

    # ---------- containers ----------
    def pick_fn(self, arity, rank):
        cands = [f for f in self.tops if f.arity == arity and f.rank > rank]
        return self.r.choice(cands) if cands else None

    def new_slot(self, arity, n, mutable, local, access):
        r = self.r
        rank = r.randint(-1, len(self.tops) - 2) if not local else -1
        while not any(f.arity == arity and f.rank > rank for f in self.tops):
            rank -= 1
        s = Slot(len(self.slots), arity, rank, n, mutable, local, access)
        s.init = [self.pick_fn(arity, rank) for _ in range(n)]
        self.slots.append(s)
        return s

    def ref(self, f, consts=True):
        """The source of a top-level function in an initialiser: its name or a constant's."""
        if consts and self.r.random() < 0.4:
            names = [nm for nm, g in self.cfns if g is f]
            if names:
                return self.r.choice(names)
        return f.name

    def make_slots(self):
        r = self.r
        self.cfns = []            # (constant name, Fn): constants that are a single function
        k = 0
        for _ in range(r.randint(4, 9)):
            k += 1
            kind = r.choice(["gvar", "garr", "cfn", "carr", "ops", "nest", "tup", "gvec", "greg", "gmap"])
            a = 1 if r.random() < 0.7 else 2
            if kind == "gvar":
                nm = f"g{k}"
                s = self.new_slot(a, 1, True, False, lambda i, nm=nm: nm)
                s.store_src = lambda i, v, nm=nm: f"{nm} = {v}"
                self.decls.append(lambda s=s, nm=nm: f"{nm}: {T[s.arity]} = {self.ref(s.init[0])}")
            elif kind == "cfn":
                nm = f"C{k}"
                s = self.new_slot(a, 1, False, False, lambda i, nm=nm: nm)
                self.cfns.append((nm, s.init[0]))
                typed = r.random() < 0.4
                self.decls.append(lambda s=s, nm=nm, typed=typed: f"const {nm}{': ' + T[s.arity] if typed else ''} = {s.init[0].name}")
                if r.random() < 0.4:
                    al = f"C{k}a"
                    s2 = Slot(len(self.slots), a, s.rank, 1, False, False, lambda i, al=al: al)
                    s2.init = list(s.init)
                    self.slots.append(s2)
                    self.decls.append(lambda nm=nm, al=al: f"const {al} = {nm}")
            elif kind in ("garr", "carr"):
                n = r.randint(1, 4)
                if kind == "garr":
                    nm = f"ga{k}"
                    s = self.new_slot(a, n, True, False, lambda i, nm=nm: f"{nm}[{i}]")
                    s.store_src = lambda i, v, nm=nm: f"{nm}[{i}] = {v}"
                    self.decls.append(lambda s=s, nm=nm: f"{nm} := [{s.n}]{T[s.arity]}{{{', '.join(self.ref(f) for f in s.init)}}}")
                else:
                    nm = f"TAB{k}"
                    s = self.new_slot(a, n, False, False, lambda i, nm=nm: f"{nm}[{i}]")
                    self.decls.append(lambda s=s, nm=nm: f"const {nm} = [{s.n}]{T[s.arity]}{{{', '.join(self.ref(f) for f in s.init)}}}")
            elif kind == "ops":
                glob = r.random() < 0.5
                nm = f"ops{k}" if glob else f"OPS{k}"
                sf = self.new_slot(1, 1, glob, False, lambda i, nm=nm: f"{nm}.f")
                sg = self.new_slot(2, 1, glob, False, lambda i, nm=nm: f"{nm}.g")
                if glob:
                    sf.store_src = lambda i, v, nm=nm: f"{nm}.f = {v}"
                    sg.store_src = lambda i, v, nm=nm: f"{nm}.g = {v}"
                kv = r.randint(0, 9)
                head = f"{nm} :=" if glob else f"const {nm} ="
                self.decls.append(lambda sf=sf, sg=sg, head=head, kv=kv:
                                  f"{head} Ops{{k: {kv}, f: {self.ref(sf.init[0])}, g: {self.ref(sg.init[0])}}}")
            elif kind == "nest":
                glob = r.random() < 0.5
                nm = f"nest{k}" if glob else f"NEST{k}"
                sf = self.new_slot(1, 1, glob, False, lambda i, nm=nm: f"{nm}.ops.f")
                sg = self.new_slot(2, 1, glob, False, lambda i, nm=nm: f"{nm}.ops.g")
                st = self.new_slot(1, 3, glob, False, lambda i, nm=nm: f"{nm}.tab[{i}]")
                if glob:
                    sf.store_src = lambda i, v, nm=nm: f"{nm}.ops.f = {v}"
                    sg.store_src = lambda i, v, nm=nm: f"{nm}.ops.g = {v}"
                    st.store_src = lambda i, v, nm=nm: f"{nm}.tab[{i}] = {v}"
                head = f"{nm} :=" if glob else f"const {nm} ="
                self.decls.append(lambda sf=sf, sg=sg, st=st, head=head:
                                  f"{head} Nest{{ops: Ops{{k: 1, f: {self.ref(sf.init[0])}, g: {self.ref(sg.init[0])}}}, "
                                  f"tab: [3]fn(i64) -> i64{{{', '.join(self.ref(f) for f in st.init)}}}}}")
            elif kind == "tup":
                glob = r.random() < 0.5
                nm = f"tup{k}" if glob else f"TUP{k}"
                s = self.new_slot(a, 1, glob, False, lambda i, nm=nm: f"{nm}.1")
                kv = r.randint(0, 9)
                if glob:
                    s.store_src = lambda i, v, nm=nm: f"{nm}.1 = {v}"
                    self.decls.append(lambda s=s, nm=nm, kv=kv: f"{nm}: (i64, {T[s.arity]}) = ({kv}, {self.ref(s.init[0])})")
                else:
                    self.decls.append(lambda s=s, nm=nm, kv=kv: f"const {nm} = ({kv}, {self.ref(s.init[0], False)})")
            elif kind == "gvec":
                nm = f"gv{k}"
                s = self.new_slot(a, r.randint(1, 4), True, False, lambda i, nm=nm: f"{nm}[{i}]")
                s.store_src = lambda i, v, nm=nm: f"{nm}[{i}] = {v}"
                self.decls.append(lambda s=s, nm=nm: f"{nm}: Vec[{T[s.arity]}]")
                self.main_init.append(("push", s, f"{nm}.push"))
            elif kind == "greg":
                nm = f"reg{k}"
                s = self.new_slot(1, r.randint(1, 4), True, False, lambda i, nm=nm: f"{nm}.fs[{i}]")
                s.store_src = lambda i, v, nm=nm: f"{nm}.fs[{i}] = {v}"
                self.decls.append(lambda nm=nm: f"{nm}: Reg")
                self.main_init.append(("push", s, f"{nm}.fs.push"))
            else:
                nm = f"gm{k}"
                via = r.random() < 0.5
                s = self.new_slot(1, r.randint(1, 4), True, False,
                                  (lambda i, nm=nm: f"mget(&{nm}, {i})") if via else (lambda i, nm=nm: f"{nm}.get_or({i}, DFLT)"))
                s.key = True
                s.default = self.r.choice([f for f in self.tops if f.arity == 1])
                s.store_src = lambda i, v, nm=nm: f"{nm}.set({i}, {v})"
                self.decls.append(lambda nm=nm: f"{nm}: Map[i64, fn(i64) -> i64]")
                self.main_init.append(("map", s, nm))
        # main's own containers
        for k in range(r.randint(0, 3)):
            kind = r.choice(["lvec", "larr", "lslice", "lmap"])
            a = 1 if kind == "lmap" or r.random() < 0.7 else 2
            n = r.randint(1, 3)
            nm = f"loc{k}"
            if kind == "lmap":
                s = self.new_slot(1, n, True, True, lambda i, nm=nm: f"{nm}.get_or({i}, DFLT)")
                s.key = True
                s.default = self.r.choice([f for f in self.tops if f.arity == 1])
                s.store_src = lambda i, v, nm=nm: f"{nm}.set({i}, {v})"
            else:
                s = self.new_slot(a, n, True, True, lambda i, nm=nm: f"{nm}[{i}]")
                s.store_src = lambda i, v, nm=nm: f"{nm}[{i}] = {v}"
            self.main_init.append((kind, s, nm))

    # ---------- functions ----------
    # expressions: ("c", n) ("v", name) ("op", o, a, b) ("if", a, b, x, y) ("call", callee, args)
    # callee: ("top", Fn) ("nest", Fn) ("local", name, Fn) ("slot", Slot, idx) ("apply", callee-or-anon)
    #         idx: ("k", i) or ("e", expr)
    def expr(self, sc, depth):
        r = self.r
        k = r.random()
        if depth <= 0 or k < 0.3:
            if sc["ints"] and r.random() < 0.7:
                return ("v", r.choice(sc["ints"]))
            return ("c", r.randint(0, 40))
        if k < 0.55:
            return ("op", r.choice("+-*&^"), self.expr(sc, depth - 1), self.expr(sc, depth - 1))
        if k < 0.62:
            return ("if", self.expr(sc, depth - 1), self.expr(sc, depth - 1), self.expr(sc, depth - 1), self.expr(sc, depth - 1))
        callee = self.callee(sc, depth)
        if callee is None:
            return self.expr(sc, depth - 1)
        return ("call", callee, [self.expr(sc, depth - 1) for _ in range(self.arity_of(callee))])

    def arity_of(self, c):
        if c[0] == "apply":
            return 1
        if c[0] == "slot":
            return c[1].arity
        return c[-1].arity

    def callee(self, sc, depth):
        r = self.r
        rank = sc["rank"]
        opts = []
        tops = [f for f in self.tops if f.rank > rank]
        if tops and sc["direct"]:
            opts.append(lambda: ("top", r.choice(tops)))
        if sc["nested"]:
            opts.append(lambda: ("nest", r.choice(sc["nested"])))
        if sc["fnlets"]:
            opts.append(lambda: ("local",) + r.choice(sc["fnlets"]))
        slots = [s for s in self.slots if s.rank >= rank and (sc["main"] or not s.local)]
        if slots:
            def via_slot():
                s = r.choice(slots)
                idx = ("k", r.randrange(s.n)) if s.n == 1 or r.random() < 0.5 else ("e", self.expr(sc, depth - 2))
                return ("slot", s, idx)
            opts += [via_slot, via_slot]
        if not opts:
            return None
        c = r.choice(opts)()
        if self.arity_of(c) == 1 and r.random() < 0.2:
            return ("apply", c)
        if r.random() < 0.1 and rank != NONE and not sc["main"]:
            # an anonymous function handed to apply1
            f = Fn("", 1, rank + 0.5 if rank == int(rank) else rank + 0.125, "anon")
            self.fill_fn(f, f.rank)
            return ("apply", ("anon", f))
        return c

    def scope(self, f, rank, main=False):
        return {"rank": rank, "ints": list(f.params) if f else [], "nested": [], "fnlets": [],
                "direct": not main, "main": main}

    def fill_fn(self, f, rank, level=0):
        r = self.r
        sc = self.scope(f, rank)
        if level < 2:
            for _ in range(r.choice([0, 0, 1, 1, 2])):
                self.nid += 1
                g = Fn(f"h{self.nid}", 1 if r.random() < 0.7 else 2, rank + 0.5 ** (level + 1), "nested")
                self.fill_fn(g, g.rank, level + 1)
                f.nested.append(g)
                sc["nested"].append(g)
        self.fill_body(f, sc)

    def fill_body(self, f, sc):
        r = self.r
        for i in range(r.randint(0, 3)):
            if r.random() < 0.25 and sc["rank"] != NONE:
                nm = f"fv{i}"
                g = Fn("", 1 if r.random() < 0.7 else 2, sc["rank"] + 0.125, "anon")
                self.fill_fn(g, g.rank, 2)
                f.body.append(("fnlet", nm, g))
                sc["fnlets"].append((nm, g))
            else:
                nm = f"t{i}"
                f.body.append(("let", nm, self.expr(sc, 3)))
                sc["ints"].append(nm)
        f.result = self.expr(sc, 3)

    def stored_value(self, s, owner):
        """A function to store into `s`: a top-level one, an anonymous one, or a new nested one of `owner`."""
        r = self.r
        k = r.random()
        if k < 0.4:
            f = self.pick_fn(s.arity, s.rank)
            if f:
                return ("top", f)
        rank = s.rank + 0.5
        if k < 0.7 and owner is not None:
            self.nid += 1
            g = Fn(f"h{self.nid}", s.arity, rank, "nested")
            self.fill_fn(g, rank, 1)
            owner.append(g)
            return ("nest", g)
        g = Fn("", s.arity, rank, "anon")
        self.fill_fn(g, rank, 1)
        return ("anon", g)

    def fill_setter(self, f):
        r = self.r
        sc = self.scope(f, NONE)
        sc["direct"] = False
        targets = [s for s in self.slots if s.mutable and not s.local]
        for i in range(r.randint(1, 3)):
            if not targets:
                break
            s = r.choice(targets)
            f.body.append(("store", s, r.randrange(s.n), self.stored_value(s, f.nested)))
        sc["nested"] = []
        if r.random() < 0.5:
            nm = "t0"
            f.body.append(("let", nm, self.expr(sc, 3)))
            sc["ints"].append(nm)
        f.result = self.expr(sc, 3)

    # ---------- main ----------
    # ("print", e) ("store", Slot, i, ref) ("fn", Fn) ("set", setter index, e) ("for", n, stmts)
    def make_main(self, depth=0):
        r = self.r
        out = []
        sc = self.scope(None, NONE, True)
        sc["ints"] = [f"i{d}" for d in range(depth)]
        for _ in range(r.randint(3, 8) if depth == 0 else r.randint(1, 3)):
            k = r.random()
            if k < 0.45:
                out.append(("print", self.expr(sc, 3)))
            elif k < 0.65:
                targets = [s for s in self.slots if s.mutable]
                if targets:
                    s = r.choice(targets)
                    owner = []
                    v = self.stored_value(s, owner)
                    for g in owner:
                        out.append(("fn", g))
                    out.append(("store", s, r.randrange(s.n), v))
            elif k < 0.9:
                out.append(("set", r.randrange(len(self.setters)), self.expr(sc, 2)))
            elif depth < 2:
                out.append(("for", r.randint(1, 3), self.make_main(depth + 1)))
        return out

    # ---------- source ----------
    def key(self, s, i):
        return f"{i * 7 + 1}" if s.key else f"{i}"

    def idx_src(self, s, idx):
        if idx[0] == "k":
            return self.key(s, idx[1])
        e = f"(({self.e(idx[1])}) & 1023) % {s.n}"
        return f"({e}) * 7 + 1" if s.key else e

    def slot_src(self, s, idx):
        src = s.access(self.idx_src(s, idx))
        return src.replace("DFLT", s.default.name) if s.default else src

    def callee_src(self, c, ind):
        t = c[0]
        if t in ("top", "nest"):
            return c[1].name
        if t == "local":
            return c[1]
        if t == "slot":
            return self.slot_src(c[1], c[2])
        if t == "anon":
            return self.fn_src(c[1], ind)
        return "apply1"

    def e(self, x, ind=1):
        t = x[0]
        if t == "c":
            return str(x[1])
        if t == "v":
            return x[1]
        if t == "op":
            s = f"({self.e(x[2], ind)} {x[1]} {self.e(x[3], ind)})"
            return f"({s} & {MASK})" if x[1] == "*" else s
        if t == "if":
            return f"(if {self.e(x[1], ind)} < {self.e(x[2], ind)} {{ {self.e(x[3], ind)} }} else {{ {self.e(x[4], ind)} }})"
        c = x[1]
        args = [self.e(a, ind) for a in x[2]]
        if c[0] == "apply":
            return f"apply1({self.callee_src(c[1], ind)}, {args[0]})"
        f = self.callee_src(c, ind)
        if c[0] == "slot" and self.r.random() < 0.2 and not c[1].key:
            f = f"({f})"
        return f"{f}({', '.join(args)})"

    def value_src(self, v, ind):
        if v[0] in ("top", "nest"):
            return v[1].name
        return self.fn_src(v[1], ind)

    def fn_src(self, f, ind):
        pad = "    " * ind
        ps = ", ".join(f"{p}: i64" for p in f.params)
        lines = [f"fn {f.name}({ps}) -> i64 {{" if f.name else f"fn({ps}) -> i64 {{"]
        for g in f.nested:
            lines.append(pad + "    " + self.fn_src(g, ind + 1))
        for s in f.body:
            if s[0] == "let":
                lines.append(f"{pad}    {s[1]} := {self.e(s[2], ind + 1)} & {MASK}")
            elif s[0] == "fnlet":
                lines.append(f"{pad}    {s[1]} := {self.fn_src(s[2], ind + 1)}")
            else:
                lines.append(f"{pad}    {s[1].store_src(self.key(s[1], s[2]), self.value_src(s[3], ind + 1))}")
        lines.append(f"{pad}    return {self.e(f.result, ind + 1)} & {MASK}")
        lines.append(pad + "}")
        return "\n".join(lines)

    def main_src(self, stmts, ind, depth=0):
        pad = "    " * ind
        out = []
        n = 0
        for s in stmts:
            t = s[0]
            if t == "print":
                out.append(f"{pad}print({self.e(s[1], ind)} & {MASK})")
            elif t == "fn":
                out.append(pad + self.fn_src(s[1], ind))
            elif t == "store":
                out.append(pad + s[1].store_src(self.key(s[1], s[2]), self.value_src(s[3], ind)))
            elif t == "set":
                n += 1
                via = self.r.choice([f"SETTERS[{s[1]}]", f"setters[{s[1]}]"])
                out.append(f"{pad}r{depth}_{n} := {via}({self.e(s[2], ind)} & {MASK})")
                out.append(f"{pad}print(r{depth}_{n})")
            else:
                out.append(f"{pad}for i{depth} in 0..{s[1]} {{")
                out += self.main_src(s[2], ind + 1, depth + 1)
                out.append(pad + "}")
        return out

    def program(self):
        parts = [HEADER]
        for f in self.tops + self.setters:
            parts.append(self.fn_src(f, 0) + "\n")
        for d in self.decls:
            parts.append(d() + "\n")
        names = ", ".join(s.name for s in self.setters)
        parts.append(f"const SETTERS = [{len(self.setters)}]fn(i64) -> i64{{{names}}}\n")
        parts.append(f"setters := [{len(self.setters)}]fn(i64) -> i64{{{names}}}\n")
        body = []
        for kind, s, nm in self.main_init:
            if kind == "push":
                for f in s.init:
                    body.append(f"    {nm}({f.name})")
            elif kind == "map":
                body.append(f"    {nm} = map[i64, fn(i64) -> i64]()")
                for i, f in enumerate(s.init):
                    body.append(f"    {nm}.set({self.key(s, i)}, {f.name})")
            elif kind == "lmap":
                body.append(f"    {nm} := map[i64, fn(i64) -> i64]()")
                for i, f in enumerate(s.init):
                    body.append(f"    {nm}.set({self.key(s, i)}, {f.name})")
            elif kind == "lvec":
                body.append(f"    {nm} := vec[{T[s.arity]}]()")
                for f in s.init:
                    body.append(f"    {nm}.push({f.name})")
            elif kind == "larr":
                body.append(f"    {nm}: [{s.n}]{T[s.arity]}")
                for i, f in enumerate(s.init):
                    body.append(f"    {nm}[{i}] = {f.name}")
            else:
                body.append(f"    {nm} := []{T[s.arity]}{{{', '.join(f.name for f in s.init)}}}")
        body += self.main_src(self.main, 1)
        parts.append("fn main() {\n" + "\n".join(body) + "\n}\n")
        return "\n".join(parts)

    # ---------- evaluation ----------
    def tick(self):
        self.steps += 1
        if self.steps > 300000:
            raise TooLong()

    def ev(self, x, env):
        self.tick()
        t = x[0]
        if t == "c":
            return x[1]
        if t == "v":
            return env[x[1]]
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
        c = x[1]
        if c[0] == "apply":
            f = self.target(c[1], env)
            return self.invoke(f, [self.ev(x[2][0], env)]) & MASK
        f = self.target(c, env)
        return self.invoke(f, [self.ev(a, env) for a in x[2]])

    def target(self, c, env):
        t = c[0]
        if t in ("top", "nest", "anon"):
            return c[1]
        if t == "local":
            return c[2]
        s, idx = c[1], c[2]
        i = idx[1] if idx[0] == "k" else (self.ev(idx[1], env) & 1023) % s.n
        return self.state[s.sid][i]

    def invoke(self, f, args):
        self.tick()
        env = dict(zip(f.params, args))
        for s in f.body:
            if s[0] == "let":
                env[s[1]] = self.ev(s[2], env) & MASK
            elif s[0] == "store":
                self.state[s[1].sid][s[2]] = s[3][1]
        return self.ev(f.result, env) & MASK

    def run_main(self, stmts, env):
        for s in stmts:
            t = s[0]
            if t == "print":
                self.out.append(str(self.ev(s[1], env) & MASK))
            elif t == "store":
                self.state[s[1].sid][s[2]] = s[3][1]
            elif t == "set":
                self.out.append(str(self.invoke(self.setters[s[1]], [self.ev(s[2], env) & MASK])))
            elif t == "for":
                for i in range(s[1]):
                    inner = dict(env)
                    inner[f"i{len(env)}"] = i
                    self.run_main(s[2], inner)

    def expected(self):
        self.out = []
        self.steps = 0
        self.state = {s.sid: list(s.init) for s in self.slots}
        self.run_main(self.main, {})
        return "".join(l + "\n" for l in self.out)


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
    tmp = tempfile.mkdtemp(prefix="alfuzzf")
    bad = 0
    skipped = 0
    for seed in range(first, first + count):
        g = Gen(seed)
        src = g.program()
        try:
            want = g.expected().encode()
        except (TooLong, RecursionError):
            skipped += 1
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
            dst = f"/tmp/alfuzzf_fail_{seed}.al"
            open(dst, "w").write(src + "// expected:\n" + "".join("// " + l + "\n" for l in want.decode().splitlines()))
            print(f"seed {seed}: {failed}\n  saved {dst}")
            if bad >= 5:
                break
        elif not keep:
            os.remove(path)
    print(f"fuzz_fnptr: {count} programs from seed {first}, {skipped} too long, {bad} failures")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
