// Windows: stack frames and preserved registers of AL functions, seen from C (regs.dll from
// regs.c), stack probes of large frames and deep recursion. Prints `ok ...` lines only.
extern "regs.dll" fn check_saved(cb: fn()) -> i32
extern "regs.dll" fn stack_aligned() -> i32
extern "regs.dll" fn call_back(cb: fn() -> i32) -> i32

burn_out: f64
burn_iout: i64

// keeps 16 floats and 12 integers alive at once: every register of both classes is written
noinline fn burn() {
    x0 := burn_out + 1.0
    x1 := x0 * 1.5
    x2 := x1 + 0.25
    x3 := x2 * 0.75
    x4 := x3 + 2.0
    x5 := x4 * 1.125
    x6 := x5 - 0.5
    x7 := x6 * 0.875
    x8 := x7 + 3.0
    x9 := x8 * 0.625
    x10 := x9 + 1.75
    x11 := x10 * 1.25
    x12 := x11 - 1.0
    x13 := x12 * 0.5
    x14 := x13 + 4.0
    x15 := x14 * 0.375
    i0 := burn_iout + 3
    i1 := i0 * 7
    i2 := i1 ^ 0x55
    i3 := i2 + i0
    i4 := i3 * 3
    i5 := i4 - i1
    i6 := i5 ^ i2
    i7 := i6 + 11
    i8 := i7 * i3
    i9 := i8 - i4
    i10 := i9 + i5
    i11 := i10 ^ i6
    for k in 0..50 {
        x0 = x0 * 0.5 + x1
        x1 = x1 * 0.5 + x2
        x2 = x2 * 0.5 + x3
        x3 = x3 * 0.5 + x4
        x4 = x4 * 0.5 + x5
        x5 = x5 * 0.5 + x6
        x6 = x6 * 0.5 + x7
        x7 = x7 * 0.5 + x8
        x8 = x8 * 0.5 + x9
        x9 = x9 * 0.5 + x10
        x10 = x10 * 0.5 + x11
        x11 = x11 * 0.5 + x12
        x12 = x12 * 0.5 + x13
        x13 = x13 * 0.5 + x14
        x14 = x14 * 0.5 + x15
        x15 = x15 * 0.5 + x0
        i0 = i0 * 3 + i1
        i1 = i1 * 5 + i2
        i2 = i2 * 7 + i3
        i3 = i3 * 9 + i4
        i4 = i4 * 11 + i5
        i5 = i5 * 13 + i6
        i6 = i6 * 15 + i7
        i7 = i7 * 17 + i8
        i8 = i8 * 19 + i9
        i9 = i9 * 21 + i10
        i10 = i10 * 23 + i11
        i11 = i11 * 25 + i0 + k
    }
    burn_out = x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7 + x8 + x9 + x10 + x11 + x12 + x13 + x14 + x15
    burn_iout = i0 ^ i1 ^ i2 ^ i3 ^ i4 ^ i5 ^ i6 ^ i7 ^ i8 ^ i9 ^ i10 ^ i11
}

// a structure copy (rep movsb: rdi and rsi) inside a callback
struct Blob { w: [40]i64 }
blob: Blob

noinline fn copy_blob() {
    b := blob
    b.w[3] = 7
    blob = b
}

// the alignment of the stack where an AL function calls C, called from C
noinline fn aligned_from_c() -> i32 {
    return stack_aligned()
}

// a frame of 1 MB: its pages are touched in order (stack probe)
noinline fn big_frame(k: i64) -> i64 {
    a: [1000000]u8
    a[k] = 5
    a[999999 - k] = 6
    return i64(a[k]) + i64(a[999999 - k])
}

// recursion through 64 KB frames: 8 MB of stack
noinline fn big_rec(n: i64) -> i64 {
    a: [65536]u8
    a[n * 1000 % 65536] = u8(n)
    if n == 0 {
        return 0
    }
    return big_rec(n - 1) + i64(a[n * 1000 % 65536])
}

// deep recursion through small frames
noinline fn deep(n: i64) -> i64 {
    if n == 0 {
        return 0
    }
    return deep(n - 1) + n % 3
}

fn main() -> i64 {
    bad := 0
    fn check(what: str, ok: bool, bad: *i64) {
        if ok {
            print("ok", what)
        } else {
            print("FAIL", what)
            *bad += 1
        }
    }
    m := check_saved(burn)
    check("burn preserves registers", m == 0, &bad)
    if m != 0 {
        print("  changed mask", hex(u64(m)))
    }
    check("copy preserves rsi/rdi", check_saved(copy_blob) == 0 && blob.w[3] == 7, &bad)
    check("stack aligned at a call from AL", stack_aligned() == 1, &bad)
    check("stack aligned at a call from an AL callback", call_back(aligned_from_c) == 1001, &bad)
    check("1 MB frame", big_frame(3) == 11, &bad)
    s := 0
    for n in 0..128 {
        s += n % 256
    }
    check("recursion through 64 KB frames", big_rec(127) == s, &bad)
    d := 0
    for n in 1..=100000 {
        d += n % 3
    }
    check("recursion 100000 deep", deep(100000) == d, &bad)
    return bad
}
