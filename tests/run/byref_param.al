// An aggregate argument passed by reference (the Windows convention for aggregates of other
// than 1, 2, 4 or 8 bytes: slices, strings, larger structs) points to a copy the caller made
// for the call, which the optimiser treats as memory of the callee's own: stores through other
// pointers and calls do not change it, unless the callee lets its address escape.
use std.os

// the compiler for the system this program runs on, as ./build.sh builds it
when TARGET_OS == Windows {
    const ALC = "build/alc.exe"
} else {
    const ALC = "./build/alc"
}

struct Big { a: i64, b: i64, c: i64 }

g_p: *Big = nil

noinline fn poke() {
    g_p.a += 90
}

// the copy keeps its value while the original changes
noinline fn keeps(x: Big) -> i64 {
    s := x.a
    poke()
    return s + x.a
}

// a write to the copy is seen after a call
noinline fn writes(x: Big) -> i64 {
    x.a = 5
    poke()
    return x.a + x.b
}

// once its address escapes, a call may change it
noinline fn escapes(x: Big) -> i64 {
    s := x.a
    g_p = &x
    poke()
    return s * 1000 + x.a
}

// stores through the slice do not reload its length and pointer (checked in the IR below)
noinline fn scatter(a: []i64, idx: []i64, s: str) {
    k := 0
    while k < len(idx) {
        a[idx[k]] = k + len(s)
        k += 1
    }
}

const SRC = `noinline fn scatter(a: []i64, idx: []i64, s: str) {
    k := 0
    while k < len(idx) {
        a[idx[k]] = k + len(s)
        k += 1
    }
}
fn main() {
    a := []i64{0, 0, 0, 0}
    scatter(a[..], []i64{3, 1, 2}, "ab")
    print(a)
}
`

fn main() {
    b := Big{1, 2, 3}
    g_p = &b
    print(keeps(b), b.a)
    print(writes(b), b.a)
    print(escapes(b), b.a)
    v := []i64{0, 0, 0, 0}
    scatter(v[..], []i64{3, 1, 2}, "ab")
    print(v)
    if !file_exists(ALC) {
        print(fmt("no compiler at ", ALC, " (./build.sh builds it)"))
        exit(77)
    }
    make_dir("tmp")
    src := fmt("tmp/al_byref_param_", process_id(), ".al")
    exe := src[..len(src) - 3]
    write_file(src, SRC)
    out, status := run_capture([]str{ALC, "build", "--target", "windows", "--emit-ir", src, "-o", exe})
    // the loads in the loop of scatter (the blocks after the loop's phi): only the one of idx[k]
    // for each store into an element of `a` (the loop may be unrolled: one load per copy of
    // the body; the stores of the failing check's message have other alias classes)
    loads := 0
    stores := 0
    inside := false
    in_loop := false
    for l in split(out, "\n") {
        if starts_with(l, "fn ") {
            inside = starts_with(l, "fn scatter(")
            in_loop = false
        } else if inside {
            if find(l, " = Phi ") >= 0 {
                in_loop = true
            }
            if in_loop && find(l, " = Load ") >= 0 {
                loads += 1
            }
            if in_loop && find(l, "  Store i64 !3.0 ") >= 0 {
                stores += 1
            }
        }
    }
    print(status, loads / max(stores, 1))
    remove_file(src)
    remove_file(fmt(exe, ".exe"))
}
