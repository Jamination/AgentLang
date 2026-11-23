// Bounds and division checks that the conditions before them decide: a `while` scanner
// (`while i < n && s[i] != 0`, n the length), nested scanners, a loop unrolled by hand
// (`while i + 4 <= n` with s[i] .. s[i + 3]), a loop that steps by 1 or 2 in different arms,
// masked and narrow indices into fixed-size arrays, `% b` after `b != 0` (also through a phi
// and after `b == 0` is false). The machine code of the loops of these functions (`--emit-asm`,
// blocks of depth > 0) has no branch to a block that fails a check; `kept` (whose index can
// be anywhere) keeps its check. The results must not change.
use std.os

// the compiler for the system this program runs on, as ./build.sh builds it
when TARGET_OS == Windows {
    const ALC = "build/alc.exe"
} else {
    const ALC = "./build/alc"
}

const SRC = `noinline fn scan(s: []u8) -> i64 {
    n := len(s)
    i := 0
    while i < n && s[i] != 0 {
        i += 1
    }
    return i
}
noinline fn pieces(s: []u8) -> i64 {
    n := len(s)
    t := 0
    i := 0
    while i < n {
        j := i
        while j < n && s[j] != 0 {
            j += 1
        }
        t += j - i
        i = j + 1
    }
    return t
}
noinline fn sum4(b: []u8) -> u64 {
    s0: u64 = 0
    s1: u64 = 0
    n := len(b)
    i := 0
    while i + 4 <= n {
        s0 += u64(b[i]) + u64(b[i + 1])
        s1 += u64(b[i + 2]) + u64(b[i + 3])
        i += 4
    }
    return s0 + s1
}
noinline fn skip(s: []u8) -> i64 {
    n := len(s)
    i := 0
    c := 0
    while i < n {
        if s[i] == 1 {
            i += 2
        } else {
            i += 1
        }
        c += 1
    }
    return c
}
noinline fn masked(t: []u8, x: u64) -> i64 {
    a: [64]i64
    h: [256]i64
    for k in 0..len(t) {
        h[t[k]] += 1
        a[(x >> u64(k & 7)) & 63] += 1
        a[x % 64] += 1
        a[(x >> 58)] += 1
    }
    return h[3] + a[5]
}
noinline fn gcd(a0: u64, b0: u64) -> u64 {
    a := a0
    b := b0
    while b != 0 {
        t := a % b
        a = b
        b = t
    }
    return a
}
noinline fn gcd2(a: i64, b: i64) -> i64 {
    if b == 0 {
        return a
    }
    return gcd2(b, a % b)
}
noinline fn kept(s: []i64, idx: []i64) -> i64 {
    t := 0
    i := 0
    while i < len(idx) {
        t += s[idx[i]]
        i += 1
    }
    return t
}
fn main() {
    s := "abc\x00de\x00\x00fgh"
    b := cast[[]u8](s)
    print(scan(b), pieces(b), sum4(b), skip([]u8{1, 0, 1, 1, 0}), masked(b, 77), gcd(84, 36), gcd2(84, 36), kept([]i64{5, 6, 7}, []i64{2, 0}))
}
`

// the same functions and the cases at the edges, run here
noinline fn scan(s: []u8) -> i64 {
    n := len(s)
    i := 0
    while i < n && s[i] != 0 {
        i += 1
    }
    return i
}

noinline fn sum4(b: []u8) -> u64 {
    s0: u64 = 0
    s1: u64 = 0
    n := len(b)
    i := 0
    while i + 4 <= n {
        s0 += u64(b[i]) + u64(b[i + 1])
        s1 += u64(b[i + 2]) + u64(b[i + 3])
        i += 4
    }
    return s0 + s1
}

noinline fn skip(s: []u8) -> i64 {
    n := len(s)
    i := 0
    c := 0
    while i < n {
        if s[i] == 1 {
            i += 2
        } else {
            i += 1
        }
        c += 1
    }
    return c
}

noinline fn gcd(a0: u64, b0: u64) -> u64 {
    a := a0
    b := b0
    while b != 0 {
        t := a % b
        a = b
        b = t
    }
    return a
}

// the jumps from blocks of depth > 0 of function `name` to blocks that fail a check (no
// successors, ending with ud2)
fn check_jumps(asm: str, name: str) -> i64 {
    lines := split(asm, "\n")
    fails := vec[str]()
    inside := false
    cur := ""
    cur_fail := false
    for l in lines {
        if len(l) > 0 && l[len(l) - 1] == ':' && !starts_with(l, ".") {
            inside = l == fmt(name, ":")
            continue
        }
        if !inside {
            continue
        }
        if starts_with(l, ".L") {
            cur = l[..find(l, ":")]
            cur_fail = find(l, "succs []") >= 0
        } else if cur_fail && trim(l) == "ud20" {
            fails.push(cur)
            cur_fail = false
        }
    }
    n := 0
    inside = false
    depth := 0
    for l in lines {
        if len(l) > 0 && l[len(l) - 1] == ':' && !starts_with(l, ".") {
            inside = l == fmt(name, ":")
            continue
        }
        if !inside {
            continue
        }
        if starts_with(l, ".L") {
            p := find(l, "depth ")
            depth = if p >= 0 && l[p + 6] != '0' { 1 } else { 0 }
            continue
        }
        t := trim(l)
        if depth > 0 && starts_with(t, "jcc") {
            target := t[find(t, " ") + 1..]
            for x in fails {
                if x == target {
                    n += 1
                }
            }
        }
    }
    return n
}

fn main() {
    print(scan([]u8{}), scan([]u8{1, 2}), scan([]u8{1, 0, 2}))
    print(sum4([]u8{}), sum4([]u8{1, 2, 3}), sum4([]u8{1, 2, 3, 4, 5, 6, 7, 8, 9}))
    print(skip([]u8{}), skip([]u8{1}), skip([]u8{0, 1, 1}), gcd(0, 5), gcd(5, 0), gcd(17, 5))
    if !file_exists(ALC) {
        print(fmt("no compiler at ", ALC, " (./build.sh builds it)"))
        exit(77)
    }
    make_dir("tmp")
    src := fmt("tmp/al_bce_range_", process_id(), ".al")
    exe := src[..len(src) - 3]
    write_file(src, SRC)
    out, status := run_capture([]str{ALC, "build", "--emit-asm", src, "-o", exe})
    print(status, check_jumps(out, "scan"), check_jumps(out, "pieces"), check_jumps(out, "sum4"), check_jumps(out, "skip"), check_jumps(out, "masked"), check_jumps(out, "gcd"), check_jumps(out, "gcd2"), check_jumps(out, "kept") > 0)
    res, _ := run_capture([]str{exe})
    print(trim(res))
    remove_file(src)
    remove_file(exe)
}
