#!/usr/bin/env python3
"""Negative / crash fuzzer for alc check and alc fmt.

Feeds malformed, mutated, truncated, deeply nested, and adversarial AL inputs
to `alc check --json` and `alc fmt --check --json` and asserts that the compiler
NEVER panics, crashes (signal / exit >= 128), hangs, or emits invalid JSON.

Usage:
    python3 tests/gen/fuzz_crash.py [--cases N] [--seed S] [--alc PATH]
"""
import argparse
import json
import os
import random
import subprocess
import sys
import tempfile

TOKENS = [
    "fn", "struct", "enum", "const", "use", "priv", "extern", "inline",
    "noinline", "if", "else", "while", "loop", "for", "in", "by", "return",
    "break", "continue", "assert", "match", "defer", "true", "false", "nil",
    "when", "test", "main", "x", "y", "T", "Opt", "Some", "None", "Vec",
    "Map", "i64", "u8", "f32", "f64", "str", "bool", "vec3", "0", "-1",
    "0xFF", "1.5", "1e999", "'a'", '"hi"', "`raw`", "+", "-", "*", "/",
    "%", "==", "!=", "<=", ">=", "&&", "||", "&", "|", "^", "<<", ">>",
    "!", "~", ":=", "=", "+=", "->", "=>", "..", "..=", "(", ")", "[", "]",
    "{", "}", ",", ";", ":", ".", "_", "\n", "// comment\n",
]

CORPUS = [
    "fn main() { x := 1; print(x) }\n",
    "struct S[T] { a: T, b: *S[T] }\nfn main() { s: S[i64]; print(s) }\n",
    "enum E { A(i64), B }\nfn main() { m := match A(1) { A(x) if x > 0 => x; B => 0 } }\n",
    "when TARGET_OS == Linux { const X = 1 } else { const X = 2 }\nfn main() {}\n",
    "priv fn f(a: i64) -> i64 { a + 1 }\nfn main() { _ = f(1) }\n",
    "fn main() { defer { print(1) }; loop { break } }\n",
]


def gen_random_tokens(rng: random.Random) -> str:
    n = rng.randint(1, 60)
    return " ".join(rng.choice(TOKENS) for _ in range(n)) + "\n"


def gen_mutated_corpus(rng: random.Random) -> str:
    s = rng.choice(CORPUS)
    for _ in range(rng.randint(1, 6)):
        kind = rng.randint(0, 4)
        if kind == 0 and len(s) > 2:
            # delete slice
            a = rng.randint(0, len(s) - 1)
            b = min(len(s), a + rng.randint(1, 12))
            s = s[:a] + s[b:]
        elif kind == 1:
            # insert random token
            pos = rng.randint(0, len(s))
            s = s[:pos] + rng.choice(TOKENS) + s[pos:]
        elif kind == 2 and len(s) > 1:
            # flip a byte (avoid NUL which is cleanly rejected as non-source)
            pos = rng.randint(0, len(s) - 1)
            ch = chr(rng.randint(1, 126))
            s = s[:pos] + ch + s[pos + 1:]
        elif kind == 3:
            # deep brackets
            depth = rng.randint(5, 80)
            op, cl = rng.choice([("(", ")"), ("{", "}"), ("[", "]")])
            s = "fn main() { x := " + op * depth + "1" + cl * max(0, depth - rng.randint(0, 3)) + " }\n"
        else:
            # unclosed string / raw string / bad escape
            s += rng.choice(['"unterminated', "`unterminated", "'\\xZZ'", "// alc fmt: off\nfn x("])
    return s


def check_cmd(alc: str, args: list, path: str, src: str, mode: str) -> str:
    try:
        p = subprocess.run(
            [alc] + args + [path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        return f"{mode}: TIMEOUT"
    if p.returncode < 0 or p.returncode >= 128:
        return f"{mode}: CRASH signal/rc={p.returncode}\nstderr={p.stderr[:300]!r}"
    if b"panic" in p.stderr.lower() or b"assertion failed" in p.stderr.lower():
        return f"{mode}: INTERNAL PANIC rc={p.returncode}\nstderr={p.stderr[:400]!r}"
    if "--json" in args and p.stdout.strip():
        try:
            data = json.loads(p.stdout.decode("utf-8", errors="replace"))
            if not isinstance(data, list):
                return f"{mode}: JSON root not list: {p.stdout[:200]!r}"
        except Exception as e:
            return f"{mode}: INVALID JSON ({e}): {p.stdout[:200]!r}"
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--alc", default="./build/alc")
    ns = ap.parse_args()

    rng = random.Random(ns.seed)
    failures = 0
    with tempfile.TemporaryDirectory(prefix="alc_fuzz_crash_") as tmp:
        path = os.path.join(tmp, "fuzz.al")
        for i in range(ns.cases):
            src = gen_random_tokens(rng) if i % 2 == 0 else gen_mutated_corpus(rng)
            with open(path, "w", encoding="utf-8", errors="replace") as f:
                f.write(src)
            for mode, cmd_args in [
                ("check", ["check", "--json", "-W"]),
                ("fmt", ["fmt", "--check", "--json"]),
            ]:
                err = check_cmd(ns.alc, cmd_args, path, src, mode)
                if err:
                    print(f"FAIL case {i} ({err})\n--- source ---\n{src}\n--------------")
                    failures += 1
                    if failures >= 5:
                        return 1
    print(f"fuzz_crash: {ns.cases} cases x 2 modes passed (0 crashes, seed={ns.seed})")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
