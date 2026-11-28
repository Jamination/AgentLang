// The guarantees of `alc fmt` on every .al file of the repository (src/, std/, examples/,
// tests/, bench/), checked on copies in a scratch directory. tests/run.al runs it from the
// repository root as the test fmt/tree:
//   check ALC DIR [ROUNDS [SEED]]
// 1. `alc fmt` on a copy of the tree: no internal error; a file with a syntax error is left
//    byte for byte as it was (and reported).
//    A file with a comment `// alc fmt: off` keeps the lines from it on as they are.
// 2. idempotent: `alc fmt --check` on the result lists no file.
// 3. meaning: every formatted file has the same lines as the original apart from white space
//    and blank lines (the formatter also compares the tokens itself), and the compiler built
//    from the formatted sources is the same compiler: it reproduces itself byte for byte and
//    compiles the original sources to the same executable as ALC does.
// 4. fuzz: ROUNDS times (default 1, from SEED, default 1) the layout of the original files is
//    scrambled (indentation, spaces next to brackets and commas, trailing spaces, blank lines,
//    CRLF line ends) where that cannot change a token; formatting the scrambled tree must give
//    the formatted files of 1 (with CRLF where the scrambled file has it). Files marked
//    `alc fmt: off` are not scrambled.
// The exit status is 0 if everything holds; failures are listed on standard output.
use std.os

when TARGET_OS == Windows {
    priv const EXE = ".exe"
} else {
    priv const EXE = ""
}

priv const ROOTS = [5]str{"src", "std", "examples", "tests", "bench"}

priv failures: i64

priv fn fail(msg: str) {
    failures += 1
    if failures <= 20 {
        print("FAIL", msg)
    }
}

priv fn has(s: str, sub: str) -> bool {
    return find(s, sub) >= 0
}

priv fn slurp(path: str) -> str {
    t, _ := read_file(path)
    return t
}

// runs argv with standard output and error in files; its exit status
priv fn exec(argv: []str, out: str, err: str) -> i64 {
    p, ok := spawn(argv, Launch{stdin: NULL_DEVICE, stdout: out, stderr: err})
    if !ok {
        return -1
    }
    return wait(p)
}

// the .al files under dir (relative paths), in order
priv fn walk(dir: str, out: *Vec[str]) {
    names := vec_of(list_dir(dir))
    sort(names.items())
    for n in names {
        if len(n) == 0 || n[0] == '.' {
            continue
        }
        p := fmt(dir, "/", n)
        if is_dir(p) {
            walk(p, out)
        } else if ends_with(n, ".al") {
            out.push(p)
        }
    }
}

// writes a file, making its directories
priv fn put_file(path: str, text: str) {
    k := rfind(path, "/")
    if k > 0 && !is_dir(path[..k]) {
        put_file_dir(path[..k])
    }
    if !write_file(path, text) {
        fail(fmt("cannot write ", path))
    }
}

priv fn put_file_dir(dir: str) {
    k := rfind(dir, "/")
    if k > 0 && !is_dir(dir[..k]) {
        put_file_dir(dir[..k])
    }
    make_dir(dir)
}

// whether a and b have the same lines apart from white space and blank lines
priv fn same_lines(a: str, b: str) -> bool {
    i := 0
    j := 0
    started := false
    loop {
        // the next character that is not white space, and whether a line ended before it
        nla := false
        while i < len(a) && (a[i] == ' ' || a[i] == '\t' || a[i] == '\r' || a[i] == '\n') {
            nla = nla || a[i] == '\n'
            i += 1
        }
        nlb := false
        while j < len(b) && (b[j] == ' ' || b[j] == '\t' || b[j] == '\r' || b[j] == '\n') {
            nlb = nlb || b[j] == '\n'
            j += 1
        }
        if i == len(a) || j == len(b) {
            return i == len(a) && j == len(b)
        }
        if (nla != nlb && i > 0 && j > 0 && started) || a[i] != b[j] {
            return false
        }
        started = true
        i += 1
        j += 1
    }
}
// The text of t from the line of its comment `// alc fmt: off` up to `// alc fmt: on` (or EOF),
// which formatting must leave as it is ("" if it has none)
priv fn off_part(t: str) -> str {
    m := concat("// alc fmt", ": off")      // (not the marker itself in this file)
    k := find(t, m)
    while k > 0 && t[k - 1] != ' ' && t[k - 1] != '\t' && t[k - 1] != '\n' {
        k = find(t, m, k + 1)
    }
    if k < 0 {
        return ""
    }
    start := rfind(t[..k], "\n") + 1
    on := concat("// alc fmt", ": on")
    e := find(t, on, k + len(m))
    if e >= 0 {
        nl := find(t, "\n", e)
        if nl >= 0 {
            return t[start..nl + 1]
        }
    }
    return t[start..]
}

// `alc fmt` on the trees under base; its standard error
priv fn fmt_tree(alc: str, base: str, tmp: str) -> str {
    argv := vec_of([]str{alc, "fmt"})
    for r in ROOTS {
        argv.push(fmt(base, "/", r))
    }
    err := concat(tmp, "/fmt.err")
    exec(argv.items(), concat(tmp, "/fmt.out"), err)
    return slurp(err)
}

// the files that `alc fmt` reported errors for
priv fn error_files(errs: str, base: str) -> Map[str, bool] {
    m := map[str, bool]()
    for l in lines(errs) {
        k := find(l, ".al:")
        if starts_with(l, base) && k > 0 {
            m.set(l[len(base) + 1..k + 3], true)
        }
    }
    return m
}

priv fn is_bracket(c: u8) -> bool {
    return c == '(' || c == ')' || c == '[' || c == ']' || c == ',' || c == ';'
}

// whether a raw string is open at the end of the line `l` (`in_raw`: at its start)
priv fn raw_after(l: str, in_raw: bool) -> bool {
    j := 0
    while j < len(l) {
        c := l[j]
        if in_raw {
            if c == '`' {
                in_raw = false
            }
        } else if c == '/' && j + 1 < len(l) && l[j + 1] == '/' {
            break
        } else if c == '"' || c == '\'' {
            j += 1
            while j < len(l) && l[j] != c {
                j += if l[j] == '\\' { 2 } else { 1 }
            }
        } else if c == '`' {
            in_raw = true
        }
        j += 1
    }
    return in_raw
}

// the text with its layout scrambled where no token can change (see the top)
priv fn scramble(t: str, r: *Rng) -> str {
    out := vec[u8]()
    ls := lines(t)
    in_raw := false
    for i, l in ls {
        trimmed := trim(l)
        // a line in or with a raw string stays as it is, as do the white space and line end
        // after it
        raw := in_raw || has(l, "`")
        in_raw = raw_after(l, in_raw)
        if raw {
            out.extend(l)
            if i + 1 < len(ls) || ends_with(t, "\n") {
                out.push('\n')
            }
            continue
        }
        special := has(l, "\"") || has(l, "'") || has(l, "//")
        body := trim_left(l)
        if len(trimmed) == 0 {
            if r.chance(0.3) {
                out.push('\n')
            }
        } else if !special {
            out.extend(repeat(" ", r.range(0, 13)))
            // spaces added or removed next to brackets and commas, others doubled
            for j in 0..len(body) {
                c := body[j]
                prev: u8 = if j > 0 { body[j - 1] } else { 0 }
                next: u8 = if j + 1 < len(body) { body[j + 1] } else { 0 }
                if c == ' ' && (is_bracket(prev) || is_bracket(next)) && r.chance(0.5) {
                    continue
                }
                out.push(c)
                if c == ' ' && r.chance(0.2) {
                    out.push(' ')
                }
                if is_bracket(c) && next != 0 && r.chance(0.2) {
                    out.push(' ')
                }
            }
        } else {
            out.extend(l)
        }
        if r.chance(0.2) {
            out.extend(repeat(" ", r.range(1, 4)))
        }
        if i + 1 < len(ls) || ends_with(t, "\n") {
            out.push('\n')
        }
        if !special && ends_with(trimmed, "{") && r.chance(0.2) {
            out.push('\n')
        }
    }
    return out.items()
}

fn main() -> i64 {
    a := args()
    if len(a) < 3 {
        print("usage: check ALC DIR [ROUNDS [SEED]]")
        return 2
    }
    alc := a[1]
    tmp := a[2]
    rounds := 1
    seed := 1
    if len(a) > 3 {
        rounds, _ = parse_i64(a[3])
    }
    if len(a) > 4 {
        seed, _ = parse_i64(a[4])
    }
    files := vec[str]()
    for r in ROOTS {
        walk(r, &files)
    }
    orig := map[str, str]()
    tree := concat(tmp, "/tree")
    for f in files {
        t := slurp(f)
        orig.set(f, t)
        put_file(fmt(tree, "/", f), t)
    }

    // 1. the tree formatted; files with syntax errors untouched
    errs := fmt_tree(alc, tree, tmp)
    if has(errs, "internal error") {
        for l in lines(errs) {
            if has(l, "internal error") {
                fail(l)
            }
        }
    }
    bad := error_files(errs, tree)
    formatted := map[str, str]()
    changed := 0
    marked := 0
    for f in files {
        t := slurp(fmt(tree, "/", f))
        o := orig.get_or(f, "")
        if bad.has(f) {
            if t != o {
                fail(fmt(f, ": has a syntax error and was changed"))
            }
            continue
        }
        formatted.set(f, t)
        if t != o {
            changed += 1
        }
        // a file marked `// alc fmt: off` keeps the marked part as it is
        off := off_part(o)
        if len(off) > 0 {
            marked += 1
            if find(t, off) < 0 {
                fail(fmt(f, ": formatting changed the lines after its `alc fmt: off`"))
            }
        }
        // 3. the same lines apart from white space
        if !same_lines(o, t) {
            fail(fmt(f, ": formatting changed more than white space"))
        }
    }
    print(fmt("fmt/tree: ", files.len, " files, ", bad.len, " with syntax errors (left as they are), ", marked, " marked `alc fmt: off`, ", changed, " changed by alc fmt"))

    // 2. idempotent
    argv := vec_of([]str{alc, "fmt", "--check"})
    for r in ROOTS {
        argv.push(fmt(tree, "/", r))
    }
    exec(argv.items(), concat(tmp, "/check.out"), NULL_DEVICE)
    again := slurp(concat(tmp, "/check.out"))
    if len(again) != 0 {
        fail(fmt("formatting the formatted tree again changes ", len(lines(again)), " files, the first: ", lines(again)[0]))
    }

    // 3. the compiler from the formatted sources is the same compiler
    b1 := fmt(tmp, "/b1", EXE)
    b2 := fmt(tmp, "/b2", EXE)
    c0 := fmt(tmp, "/c0", EXE)
    c1 := fmt(tmp, "/c1", EXE)
    main_f := concat(tree, "/src/main.al")
    ok := exec([]str{alc, "build", main_f, "-o", b1}, NULL_DEVICE, NULL_DEVICE) == 0
    ok = ok && exec([]str{b1, "build", main_f, "-o", b2}, NULL_DEVICE, NULL_DEVICE) == 0
    ok = ok && exec([]str{alc, "build", "src/main.al", "-o", c0}, NULL_DEVICE, NULL_DEVICE) == 0
    ok = ok && exec([]str{b1, "build", "src/main.al", "-o", c1}, NULL_DEVICE, NULL_DEVICE) == 0
    if !ok {
        fail("the compiler cannot be built from the formatted sources")
    } else {
        if slurp(b1) != slurp(b2) {
            fail("the compiler built from the formatted sources does not reproduce itself")
        }
        if slurp(c0) != slurp(c1) {
            fail("the compiler built from the formatted sources compiles src/main.al to another executable")
        }
    }

    // 4. scrambled layouts
    for round in 0..rounds {
        r := rng(u64(seed + round))
        fz := concat(tmp, fmt("/fuzz", round))
        crlf := map[str, bool]()
        for root in ROOTS {
            put_file_dir(fmt(fz, "/", root))
        }
        n := 0
        for f in files {
            o := orig.get_or(f, "")
            if !formatted.has(f) || has(o, "\r") || len(off_part(o)) > 0 {
                continue
            }
            s := scramble(o, &r)
            if !has(o, "`") && r.chance(0.1) {
                s = replace(s, "\n", "\r\n")
                crlf.set(f, true)
            }
            put_file(fmt(fz, "/", f), s)
            n += 1
        }
        ferrs := fmt_tree(alc, fz, tmp)
        for l in lines(ferrs) {
            if len(l) > 0 {
                fail(fmt("seed ", seed + round, ": ", l))
            }
        }
        differ := 0
        for f in files {
            o := orig.get_or(f, "")
            if !formatted.has(f) || has(o, "\r") || len(off_part(o)) > 0 {
                continue
            }
            want := formatted.get_or(f, "")
            if crlf.has(f) {
                want = replace(want, "\n", "\r\n")
            }
            if slurp(fmt(fz, "/", f)) != want {
                differ += 1
                fail(fmt("seed ", seed + round, ": ", f, ": the scrambled file formats differently"))
            }
        }
        print(fmt("fmt/tree: seed ", seed + round, ": ", n, " scrambled files, ", differ, " formatted differently"))
    }
    if failures > 0 {
        print(fmt(failures, " failure(s)"))
        return 1
    }
    return 0
}
