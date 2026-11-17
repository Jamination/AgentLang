// Bounds checks of inclusive ranges (`for k in a..=b`, whose latch compares the counter before
// the step) and of ranges with a step that is not a constant (`by s`) leave the loop: the
// machine code of the loops of `incl`, `marks` and `excl` (`--emit-asm`, blocks of depth > 0)
// has no branch to a block that fails a check; the loop of `data` (an index read from memory)
// keeps its check. A stepped loop also no longer compares the counter with the bound on every
// iteration. The results of these loops must not change, out-of-bounds ones included.
use std.os

// the compiler for the system this program runs on, as ./build.sh builds it
when TARGET_OS == Windows {
    const ALC = "build/alc.exe"
} else {
    const ALC = "./build/alc"
}

const SRC = `noinline fn h(x: i64) -> i64 { return x }
noinline fn incl(v: []i64, n: i64) -> i64 {
    s := 0
    for k in 2..=h(9) {
        s += v[k]
    }
    return s
}
noinline fn marks(s: i64) -> i64 {
    m: [61]u8
    for j in s * 2..=60 by s {
        m[j] = 1
    }
    return i64(m[56]) + i64(m[57])
}
noinline fn excl(v: []i64, a: i64, s: i64) {
    for j in a..len(v) by s {
        v[j] += j
    }
}
noinline fn data(v: []i64, idx: []i64) -> i64 {
    s := 0
    for k in 0..len(idx) {
        s += v[idx[k]]
    }
    return s
}
fn main() {
    v := vec_fill(10, 1)
    excl(v.items(), h(1), h(3))
    print(incl(v.items(), 9), marks(h(7)), data(v.items(), []i64{1, 2}))
}
`

// out-of-bounds and edge cases, run here
noinline fn h(x: i64) -> i64 {
    return x
}

noinline fn marks(v: []u8, a: i64, b: i64, s: i64) -> i64 {
    n := 0
    for j in a..=b by s {
        v[j] = 1
        n += 1
    }
    return n
}

noinline fn sum_excl(v: []i64, a: i64, s: i64) -> i64 {
    t := 0
    for j in a..len(v) by s {
        t += v[j]
    }
    return t
}

noinline fn sum_incl(v: []i64, a: i64, b: i64) -> i64 {
    t := 0
    for k in a..=b {
        t += v[k]
    }
    return t
}

// the jumps from blocks of depth > 0 of function `name` to blocks that fail a check (no
// successors, ending with ud2)
fn check_jumps(asm: str, name: str) -> i64 {
    lines := split(asm, "\n")
    // the labels of the failing blocks and the depth of every block, in one pass
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
    m := vec_fill(20, u8(0))
    print(marks(m.items(), h(3), h(19), h(4)), m[3], m[19])
    print(marks(m.items(), h(5), h(4), h(1)))
    v := vec_fill(10, 2)
    print(sum_excl(v.items(), h(0), h(3)), sum_excl(v.items(), h(9), h(100)), sum_incl(v.items(), h(0), h(9)))
    if !file_exists(ALC) {
        print(fmt("no compiler at ", ALC, " (./build.sh builds it)"))
        exit(77)
    }
    make_dir("tmp")
    src := fmt("tmp/al_bce_stepped_", process_id(), ".al")
    exe := src[..len(src) - 3]
    write_file(src, SRC)
    out, status := run_capture([]str{ALC, "build", "--emit-asm", src, "-o", exe})
    print(status, check_jumps(out, "incl"), check_jumps(out, "marks"), check_jumps(out, "excl"), check_jumps(out, "data") > 0)
    res, _ := run_capture([]str{exe})
    print(trim(res))
    remove_file(src)
    remove_file(exe)
    // the step runs past the end: the check of the last value fails
    print(marks(m.items(), h(3), h(20), h(1)))
}
