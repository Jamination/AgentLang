#!/usr/bin/env python3
"""Differential fuzzer for `match`.

Generates random types (integers, bool, enums with and without payload, Opt, tuples, pointers),
random values of them and random matches with nested patterns, alternatives, guards and
bindings by copy and by reference. A reference matcher written here predicts what every match
prints; the program is built unoptimized, optimized (with the IR verifier) and unchecked, and
each build must print exactly the prediction.

The same reference decides whether a match is exhaustive (by enumerating the values of the
type); a match used as a value is then expected to compile if and only if it is.

usage: tests/gen/fuzz_match.py [count] [first_seed] [--keep]
"""
import itertools
import os
import random
import subprocess
import sys
import tempfile

ALC = os.path.join(os.path.dirname(__file__), "..", "..", "build", "alc")

HEADER = """Color :: enum { R, G, B }
Sh :: enum { Ci(i64), Re(i64, Color), Em }
guards: i64
flag :: (k: i64) -> bool {
    guards += 1
    k % 2 == 0
}
"""

COLORS = ["R", "G", "B"]
INT_OTHER = 4  # an integer that no pattern mentions


# ---------- types ----------
def gen_type(r, depth, allow_ptr=True):
    k = r.random()
    if depth <= 0 or k < 0.3:
        return r.choice([("int",), ("bool",), ("color",), ("sh",)])
    if k < 0.55:
        return ("opt", gen_type(r, depth - 1, allow_ptr))
    if k < 0.85:
        return ("tup", [gen_type(r, depth - 1, allow_ptr) for _ in range(r.randint(2, 3))])
    if allow_ptr:
        return ("ptr", r.choice([("sh",), ("opt", gen_type(r, depth - 1, False)), ("tup", [gen_type(r, 0), gen_type(r, 0)])]))
    return ("sh",)


def type_src(t):
    k = t[0]
    if k == "int":
        return "i64"
    if k == "bool":
        return "bool"
    if k == "color":
        return "Color"
    if k == "sh":
        return "Sh"
    if k == "opt":
        return f"Opt[{type_src(t[1])}]"
    if k == "tup":
        return "(" + ", ".join(type_src(x) for x in t[1]) + ")"
    return "*" + type_src(t[1])


def has_ptr(t):
    if t[0] == "ptr":
        return True
    if t[0] == "opt":
        return has_ptr(t[1])
    if t[0] == "tup":
        return any(has_ptr(x) for x in t[1])
    return False


def structural(t):
    """can a variant or tuple pattern look into the type?"""
    return t[0] in ("sh", "opt", "tup")


# ---------- values ----------
# int: number; bool: True/False; color: "R"; sh / opt: (name, [fields]); tup: ("tup", [..]);
# ptr: ("nil",) or ("ptr", value)
def domain(t):
    """every value of the type, with INT_OTHER standing for the integers patterns never name"""
    k = t[0]
    if k == "int":
        return [0, 1, 2, 3, INT_OTHER]
    if k == "bool":
        return [True, False]
    if k == "color":
        return list(COLORS)
    if k == "sh":
        return [("Ci", [i]) for i in domain(("int",))] + [("Re", [i, c]) for i in domain(("int",)) for c in COLORS] + [("Em", [])]
    if k == "opt":
        return [("Some", [v]) for v in domain(t[1])] + [("None", [])]
    if k == "tup":
        return [("tup", list(c)) for c in itertools.product(*[domain(x) for x in t[1]])]
    return [("nil",)] + [("ptr", v) for v in domain(t[1])]


def domain_size(t):
    k = t[0]
    if k == "int":
        return 5
    if k == "bool":
        return 2
    if k == "color":
        return 3
    if k == "sh":
        return 21
    if k == "opt":
        return domain_size(t[1]) + 1
    if k == "tup":
        n = 1
        for x in t[1]:
            n *= domain_size(x)
        return n
    return domain_size(t[1]) + 1


def gen_value(r, t):
    k = t[0]
    if k == "int":
        return r.choice([0, 1, 2, 3, INT_OTHER])
    if k == "bool":
        return r.random() < 0.5
    if k == "color":
        return r.choice(COLORS)
    if k == "sh":
        c = r.randrange(3)
        if c == 0:
            return ("Ci", [gen_value(r, ("int",))])
        if c == 1:
            return ("Re", [gen_value(r, ("int",)), r.choice(COLORS)])
        return ("Em", [])
    if k == "opt":
        return ("Some", [gen_value(r, t[1])]) if r.random() < 0.7 else ("None", [])
    if k == "tup":
        return ("tup", [gen_value(r, x) for x in t[1]])
    return ("nil",) if r.random() < 0.2 else ("ptr", gen_value(r, t[1]))


def show(t, v):
    """what `print` shows for a value without pointers"""
    k = t[0]
    if k == "int":
        return str(v)
    if k == "bool":
        return "true" if v else "false"
    if k == "color":
        return v
    if k == "sh":
        if v[0] == "Ci":
            return f"Ci({v[1][0]})"
        if v[0] == "Re":
            return f"Re({v[1][0]}, {v[1][1]})"
        return "Em"
    if k == "opt":
        return f"Some({show(t[1], v[1][0])})" if v[0] == "Some" else "None"
    return "(" + ", ".join(show(x, y) for x, y in zip(t[1], v[1])) + ")"


class Vals:
    """turns values into AL expressions; pointers need variables to point at"""

    def __init__(self):
        self.setup = []
        self.n = 0

    def src(self, t, v):
        k = t[0]
        if k == "int":
            return str(v)
        if k == "bool":
            return "true" if v else "false"
        if k == "color":
            return "Color." + v
        if k == "sh":
            return f"Sh.{v[0]}" + ("(" + ", ".join(self.src(ft, fv) for ft, fv in zip(sh_fields(v[0]), v[1])) + ")" if v[1] else "")
        if k == "opt":
            if v[0] == "None":
                return f"{type_src(t)}.None"
            return f"{type_src(t)}.Some({self.src(t[1], v[1][0])})"
        if k == "tup":
            return "(" + ", ".join(self.src(x, y) for x, y in zip(t[1], v[1])) + ")"
        if v[0] == "nil":
            return "nil"
        name = f"cell{self.n}"
        self.n += 1
        self.setup.append(f"{name}: {type_src(t[1])} = {self.src(t[1], v[1])}")
        return "&" + name


def sh_fields(name):
    return {"Ci": [("int",)], "Re": [("int",), ("color",)], "Em": []}[name]


# ---------- patterns ----------
# ("wild",) ("bind", name, type) ("ref", name, type) ("const", value) ("var", name, [subs])
# ("tup", [subs]); a pattern for a pointer is ("nil",) or the pattern of its target
class PatGen:
    def __init__(self, r, binds_ok):
        self.r = r
        self.binds_ok = binds_ok
        self.binds = []  # (name, type, by_ref)

    def gen(self, t, depth, nested):
        r = self.r
        k = t[0]
        x = r.random()
        if x < 0.2 or depth <= 0 and x < 0.5:
            return ("wild",)
        if nested and self.binds_ok and x < 0.45:
            name = f"b{len(self.binds)}"
            by_ref = r.random() < 0.3
            self.binds.append((name, t, by_ref))
            return ("ref" if by_ref else "bind", name, t)
        if k == "int":
            return ("const", r.randrange(4))
        if k == "bool":
            return ("const", r.random() < 0.5)
        if k == "color":
            return ("const", r.choice(COLORS))
        if k == "sh":
            name = r.choice(["Ci", "Re", "Em"])
            return ("var", name, [self.gen(ft, depth - 1, True) for ft in sh_fields(name)])
        if k == "opt":
            if r.random() < 0.3:
                return ("var", "None", [])
            return ("var", "Some", [self.gen(t[1], depth - 1, True)])
        if k == "tup":
            return ("tup", [self.gen(x, depth - 1, True) for x in t[1]])
        if r.random() < 0.2:
            return ("nil",)
        mark = len(self.binds)
        p = self.gen(t[1], depth, nested)
        # only variant and tuple patterns look through the pointer
        if p[0] in ("var", "tup"):
            return ("deref", p)
        del self.binds[mark:]
        return ("wild",)


def pat_src(r, t, p):
    k = p[0]
    if k == "wild":
        return "_"
    if k == "bind":
        return p[1]
    if k == "ref":
        return "&" + p[1]
    if k == "nil":
        return "nil"
    if k == "deref":
        return pat_src(r, t[1], p[1])
    if k == "const":
        v = p[1]
        if t[0] == "int":
            return r.choice([str(v), str(v), f"{v} + 0"]) if v else "0"
        if t[0] == "bool":
            return "true" if v else "false"
        return r.choice([v, "Color." + v])
    if k == "tup":
        return "(" + ", ".join(pat_src(r, x, y) for x, y in zip(t[1], p[1])) + ")"
    name = p[1]
    if t[0] == "sh":
        q = r.choice(["", "", "Sh."])
        fts = sh_fields(name)
    else:
        q = r.choice(["", "", "Opt.", type_src(t) + "."])
        fts = [t[1]] if name == "Some" else []
    if not p[2]:
        return q + name
    return q + name + "(" + ", ".join(pat_src(r, x, y) for x, y in zip(fts, p[2])) + ")"


def matches(t, p, v, env):
    """does pattern p match value v? fills env: name -> (type, value, by_ref)"""
    k = p[0]
    if k == "wild":
        return True
    if k == "bind":
        env[p[1]] = (t, v, False)
        return True
    if k == "ref":
        env[p[1]] = (t, v, True)
        return True
    if k == "nil":
        return v[0] == "nil"
    if k == "deref":
        return v[0] == "ptr" and matches(t[1], p[1], v[1], env)
    if k == "const":
        return v == p[1]
    if k == "tup":
        return all(matches(x, y, z, env) for x, y, z in zip(t[1], p[1], v[1]))
    if v[0] != p[1]:
        return False
    fts = sh_fields(p[1]) if t[0] == "sh" else ([t[1]] if p[1] == "Some" else [])
    return all(matches(x, y, z, env) for x, y, z in zip(fts, p[2], v[1]))


# ---------- programs ----------
class Match:
    def __init__(self, r, idx, value_form):
        self.r = r
        self.idx = idx
        self.t = gen_type(r, r.randint(1, 3))
        self.arms = []  # (alternatives [pattern], binds, guard k or None)
        for _ in range(r.randint(1, 6)):
            nalt = 1 if r.random() < 0.7 else r.randint(2, 3)
            if nalt > 1 and r.random() < 0.5:
                # alternatives that bind the same names: one pattern with other constants
                g = PatGen(r, True)
                first = g.gen(self.t, 3, False)
                alts = [first] + [vary(r, self.t, first) for _ in range(nalt - 1)]
            else:
                g = PatGen(r, nalt == 1)
                alts = [g.gen(self.t, 3, False) for _ in range(nalt)]
            guard = r.randrange(4) if r.random() < 0.25 else None
            self.arms.append((alts, g.binds, guard))
        if r.random() < 0.3:
            self.arms.append(([("wild",)], [], None))
        self.value_form = value_form

    def exhaustive(self):
        for v in domain(self.t):
            if not any(g is None and any(matches(self.t, p, v, {}) for p in alts) for alts, _, g in self.arms):
                return False
        return True

    def source(self):
        r = self.r
        out = []
        ret = " -> i64" if self.value_form else ""
        out.append(f"m{self.idx} :: (v: {type_src(self.t)}){ret} {{")
        out.append("    r := match v {" if self.value_form else "    match v {")
        for ai, (alts, binds, guard) in enumerate(self.arms):
            pats = ", ".join(pat_src(r, self.t, p) for p in alts)
            g = f" if flag({guard})" if guard is not None else ""
            shown = []
            for name, t, by_ref in binds:
                if not has_ptr(t):
                    shown.append("*" + name if by_ref else name)
            stmts = [f"print(\"m{self.idx} arm{ai}\"" + "".join(", " + s for s in shown) + ")"]
            for name, t, by_ref in binds:
                if t[0] == "int" and not has_ptr(self.t):
                    # a copy is private; a reference changes the matched value
                    stmts.append(f"*{name} += 10" if by_ref else f"{name} += 10")
            if self.value_form:
                stmts.append(str(ai))
            out.append(f"        {pats}{g} => {{")
            for s in stmts:
                out.append("            " + s)
            out.append("        }")
        out.append("    }")
        if not has_ptr(self.t):
            out.append(f"    print(\"m{self.idx} after\", v)")
        if self.value_form:
            out.append("    return r")
        out.append("}")
        return "\n".join(out)

    def expect(self, v, state):
        """the lines a call prints; state["guards"] counts guard evaluations"""
        lines = []
        result = None
        after = v
        for ai, (alts, binds, guard) in enumerate(self.arms):
            env = None
            hit = None
            for p in alts:
                e = {}
                if matches(self.t, p, v, e):
                    env = e
                    hit = p
                    break
            if env is None:
                continue
            if guard is not None:
                state["guards"] += 1
                if guard % 2 != 0:
                    continue
            shown = [show(t, env[name][1]) for name, t, _ in binds if not has_ptr(t)]
            lines.append(" ".join([f"m{self.idx} arm{ai}"] + shown))
            if not has_ptr(self.t):
                for name, t, by_ref in binds:
                    if t[0] == "int" and by_ref:
                        after = bump(self.t, hit, after, name)
            result = ai
            break
        if not has_ptr(self.t):
            lines.append(f"m{self.idx} after {show(self.t, after)}")
        return lines, result


def vary(r, t, p):
    """the pattern p with other constants (same shape, same bindings)"""
    k = p[0]
    if k == "const":
        if t[0] == "int":
            return ("const", r.randrange(4))
        if t[0] == "bool":
            return ("const", r.random() < 0.5)
        return ("const", r.choice(COLORS))
    if k == "tup":
        return ("tup", [vary(r, x, y) for x, y in zip(t[1], p[1])])
    if k == "deref":
        return ("deref", vary(r, t[1], p[1]))
    if k == "var":
        fts = sh_fields(p[1]) if t[0] == "sh" else ([t[1]] if p[1] == "Some" else [])
        return ("var", p[1], [vary(r, x, y) for x, y in zip(fts, p[2])])
    return p


def bump(t, p, v, name):
    """v with 10 added to the integer that the reference binding `name` of p points at"""
    k = p[0]
    if k == "ref" and p[1] == name:
        return v + 10
    if k == "tup":
        return ("tup", [bump(x, y, z, name) for x, y, z in zip(t[1], p[1], v[1])])
    if k == "var":
        fts = sh_fields(p[1]) if t[0] == "sh" else ([t[1]] if p[1] == "Some" else [])
        return (v[0], [bump(x, y, z, name) for x, y, z in zip(fts, p[2], v[1])])
    return v


def program(seed):
    """(source, expected output or None if the program must be rejected as not exhaustive)"""
    r = random.Random(seed)
    # one program in five is a single value match that is not exhaustive
    if r.random() < 0.2:
        for _ in range(200):
            m = Match(r, 0, True)
            if domain_size(m.t) <= 4000 and not m.exhaustive():
                return HEADER + m.source() + "\nmain :: () {}\n", None
    ms = []
    while len(ms) < 6:
        m = Match(r, len(ms), r.random() < 0.5)
        if m.value_form and (domain_size(m.t) > 4000 or not m.exhaustive()):
            continue
        ms.append(m)
    vals = Vals()
    body = []
    expected = []
    state = {"guards": 0}
    for m in ms:
        for _ in range(r.randint(3, 8)):
            v = gen_value(r, m.t)
            lines, result = m.expect(v, state)
            call = f"m{m.idx}({vals.src(m.t, v)})"
            if m.value_form:
                body.append(f"print({call})")
                lines.append(str(result))
            else:
                body.append(call)
            expected.extend(lines)
    body.append("print(guards)")
    expected.append(str(state["guards"]))
    src = HEADER + "\n".join(m.source() for m in ms) + "\nmain :: () {\n"
    src += "".join("    " + s + "\n" for s in vals.setup + body) + "}\n"
    return src, "\n".join(expected) + "\n"


def run(cmd, env=None):
    p = subprocess.run(cmd, capture_output=True, timeout=120, env=env)
    return p.returncode, p.stdout, p.stderr


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    keep = "--keep" in sys.argv
    tmp = tempfile.mkdtemp(prefix="almatch")
    bad = 0
    rejected = 0
    for seed in range(first, first + count):
        src, expected = program(seed)
        path = os.path.join(tmp, f"p{seed}.al")
        open(path, "w").write(src)
        failed = None
        if expected is None:
            rejected += 1
            code, _, err = run([ALC, "check", path])
            if code == 0:
                failed = "a match that is not exhaustive was accepted as a value"
            elif b"must be exhaustive" not in err or err.count(b"error:") != 1:
                failed = f"unexpected diagnostics: {err.decode(errors='replace')[:300]}"
        else:
            for flags in (["-O0"], [], ["--unchecked"]):
                exe = os.path.join(tmp, "bin")
                env = dict(os.environ, ALC_DEBUG="verify") if flags != ["-O0"] else None
                code, _, err = run([ALC, "build", path, "-o", exe] + flags, env=env)
                if code != 0:
                    failed = f"compile {flags}: {err.decode(errors='replace')[:300]}"
                    break
                code, out, err = run([exe])
                if code != 0:
                    failed = f"{flags}: exit code {code}: {err.decode(errors='replace')[:200]}"
                    break
                if out.decode() != expected:
                    got = out.decode().split("\n")
                    want = expected.split("\n")
                    at = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), min(len(got), len(want)))
                    failed = f"{flags}: output differs at line {at + 1}: got {got[at:at + 1]}, expected {want[at:at + 1]}"
                    break
        if failed:
            bad += 1
            dst = f"/tmp/almatch_fail_{seed}.al"
            open(dst, "w").write(src)
            print(f"seed {seed}: {failed}\n  saved {dst}")
            if bad >= 5:
                break
        elif not keep:
            os.remove(path)
    print(f"fuzz_match: {count} programs from seed {first} ({rejected} must be rejected), {bad} failures")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
