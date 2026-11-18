// The C calling convention in both directions against a C compiler's (c_abi.c: clang for
// linux-arm64, run under the emulator tests/arm64/emu.al; MinGW for Windows): integers of every
// width (narrow ones with garbage above them in the registers), floats, more arguments than
// registers, structs by value (homogeneous float aggregates, small composites in registers,
// composites that no longer fit in the registers, large ones by reference), struct results
// (in registers and through memory), variadic calls, callbacks with many arguments and narrow
// results, the registers a callee preserves, the stack alignment, a variable of the library and
// a C function as a function value. Each C function hashes its arguments in order; the program
// computes the same hash from what it passed.
when TARGET_OS == Windows {
    priv const LIB = "c_abi.dll"
} else {
    priv const LIB = "libc_abi.so"
}

struct F2 { x: f32, y: f32 }
struct F3 { x: f32, y: f32, z: f32 }
struct D1 { a: f64 }
struct D4 { a: f64, b: f64, c: f64, d: f64 }
struct I2 { a: i32, b: i32 }
struct C3 { a: i8, b: i8, c: i8 }
struct I3 { a: i32, b: i32, c: i32 }
struct L2 { a: i64, b: i64 }
struct M { c: i8, i: i32, l: i64 }
struct FI { f: f32, i: i32 }
struct DL { d: f64, l: i64 }
struct Big { a: i64, b: i64, c: i64 }
struct Arr { v: [5]i32 }

extern LIB fn ints9(a: i8, b: u8, c: i16, d: u16, e: i32, f: u32, g: i64, h: u64, i: i8) -> i64
extern LIB fn floats10(a: f32, b: f64, c: f32, d: f64, e: f32, f: f64, g: f32, h: f64, i: f32, j: f64) -> f64
extern LIB fn mixed18(a: i32, b: f64, c: i64, d: f32, e: i8, f: f64, g: u16, h: f32, i: i64, j: f64,
    k: i32, l: f32, m: i64, n: f64, o: u8, p: f64, q: i64, r: f32) -> i64
extern LIB fn not_(b: bool) -> bool
extern LIB fn neg8(v: i8) -> i8
extern LIB fn inc16(v: u16) -> u16
extern LIB fn half(v: f32) -> f32
extern LIB fn twice(v: i64) -> i64
extern LIB fn hfa_regs(a: F3, b: D4, c: f32, d: F2, e: D1) -> f64
extern LIB fn hfa_spill(a0: f64, a1: f64, a2: f64, a3: f64, a4: f64, a5: f64, s: F3, after: f64) -> f64
extern LIB fn composite_spill(a0: i64, a1: i64, a2: i64, a3: i64, a4: i64, a5: i64, a6: i64, s: L2, after: i64) -> i64
extern LIB fn small_structs(a: I2, b: C3, c: I3, d: M, e: FI, f: DL) -> i64
extern LIB fn big_structs(b: Big, a: Arr, k: i64) -> i64
extern LIB fn ret_f3(v: f32) -> F3
extern LIB fn ret_d4(v: f64) -> D4
extern LIB fn ret_d1(v: f64) -> D1
extern LIB fn ret_f2(v: f32) -> F2
extern LIB fn ret_i3(v: i32) -> I3
extern LIB fn ret_c3(v: i8) -> C3
extern LIB fn ret_m(v: i64) -> M
extern LIB fn ret_fi(v: i32) -> FI
extern LIB fn ret_dl(v: i64) -> DL
extern LIB fn ret_big(v: i64) -> Big
extern LIB fn va_hash(spec: *u8, ...) -> i64
extern LIB fn call_ints(cb: fn(i8, u8, i16, u16, i32, u32, i64, u64, i8, i64) -> i64) -> i64
extern LIB fn call_floats(cb: fn(f32, f64, f32, f64, f32, f64, f32, f64, f32, f64) -> f64) -> f64
extern LIB fn call_mixed(cb: fn(i32, f64, i64, f32, i8, f64, u16, f32, i64, f64, i32, f32, i64, f64, u8, f64, i64, f32) -> i64) -> i64
extern LIB fn call_narrow(f: fn(i8) -> i8, g: fn(u16) -> u16, h: fn(i64) -> bool, k: fn(f32) -> f32) -> i64
extern LIB fn saved_regs(cb: fn(i64) -> i64, v: i64, result: *i64) -> i64
extern LIB fn sp_mod16() -> i64
extern LIB fn read_counter() -> i32
extern LIB abi_counter: i32

const H0: u64 = 14695981039346656037

fn mix(h: u64, v: i64) -> u64 {
    return (h ^ u64(v)) * 1099511628211
}

fn mixf(h: u64, v: f64) -> u64 {
    return mix(h, i64(v * 1024.0))
}

fn check(name: str, got: i64, want: i64) {
    if got == want {
        print(name, "ok")
    } else {
        print(name, "got", got, "want", want)
    }
}

fn checkf(name: str, got: f64, want: f64) {
    if got == want {
        print(name, "ok")
    } else {
        print(name, "got", got, "want", want)
    }
}

// ---- callbacks ----
fn cb_ints(a: i8, b: u8, c: i16, d: u16, e: i32, f: u32, g: i64, h: u64, i: i8, j: i64) -> i64 {
    x := H0
    x = mix(x, i64(a))
    x = mix(x, i64(b))
    x = mix(x, i64(c))
    x = mix(x, i64(d))
    x = mix(x, i64(e))
    x = mix(x, i64(f))
    x = mix(x, g)
    x = mix(x, i64(h))
    x = mix(x, i64(i))
    x = mix(x, j)
    return i64(x)
}

fn cb_floats(a: f32, b: f64, c: f32, d: f64, e: f32, f: f64, g: f32, h: f64, i: f32, j: f64) -> f64 {
    return f64(a) + 2.0 * b + 3.0 * f64(c) + 4.0 * d + 5.0 * f64(e) + 6.0 * f + 7.0 * f64(g) + 8.0 * h + 9.0 * f64(i) + 10.0 * j
}

fn hash18(a: i32, b: f64, c: i64, d: f32, e: i8, f: f64, g: u16, h: f32, i: i64, j: f64,
    k: i32, l: f32, m: i64, n: f64, o: u8, p: f64, q: i64, r: f32) -> i64 {
    x := H0
    x = mix(x, i64(a))
    x = mixf(x, b)
    x = mix(x, c)
    x = mixf(x, f64(d))
    x = mix(x, i64(e))
    x = mixf(x, f)
    x = mix(x, i64(g))
    x = mixf(x, f64(h))
    x = mix(x, i)
    x = mixf(x, j)
    x = mix(x, i64(k))
    x = mixf(x, f64(l))
    x = mix(x, m)
    x = mixf(x, n)
    x = mix(x, i64(o))
    x = mixf(x, p)
    x = mix(x, q)
    x = mixf(x, f64(r))
    return i64(x)
}

// narrow results computed so that the register above them holds other bits
fn cb_i8(x: i8) -> i8 {
    return i8(i64(x) * 3 + 0x7700)
}

fn cb_u16(x: u16) -> u16 {
    return u16(i64(x) + 0x55550001)
}

fn cb_bool(x: i64) -> bool {
    return x == 42
}

fn cb_f32(x: f32) -> f32 {
    return x * 2.0
}

// many values live across calls (the preserved registers), an allocation (the thread block)
// and a call of C that reports the stack alignment
fn heavy(v: i64) -> i64 {
    a := v + 1
    b := v * 3
    c := v ^ 0x55
    d := v - 7
    e := f64(v) * 0.5
    f := f64(v) + 0.25
    s := vec[i64]()
    for k in 0..10 {
        s.push(k * a + b)
    }
    m := sp_mod16()
    t := 0
    for x in s {
        t += x
    }
    return t + a * b + c * d + i64(e * f) + 1000000 * m
}

fn main() {
    // values the optimiser cannot know: registers may hold more than the narrow value
    k := i64(len(args()))                                   // 3
    i8a := i8(k * 0x100 + 0x9C)                             // -100
    u8b := u8(k * 0x100 + 200)
    i16c := i16(k * 0x10000 - 30000)
    u16d := u16(k * 0x10000 + 65000)
    i32e := i32(k * 0x100000000 - 2000000000)
    u32f := u32(k * 0x100000000 + 4000000000)
    i8i := i8(k * 0x100 - 7)

    // ---- scalars ----
    want := H0
    want = mix(want, -100)
    want = mix(want, 200)
    want = mix(want, -30000)
    want = mix(want, 65000)
    want = mix(want, -2000000000)
    want = mix(want, 4000000000)
    want = mix(want, -9000000000000)
    want = mix(want, i64(u64(17000000000000000000)))
    want = mix(want, -7)
    check("ints9", ints9(i8a, u8b, i16c, u16d, i32e, u32f, -9000000000000, 17000000000000000000, i8i), i64(want))
    fk := f64(k)
    checkf("floats10", floats10(0.5, 1.25 * fk, 2.5, 3.75, 4.5, 5.25, 6.5, 7.75, 8.5, 9.25),
        0.5 + 2.0 * 1.25 * fk + 3.0 * 2.5 + 4.0 * 3.75 + 5.0 * 4.5 + 6.0 * 5.25 + 7.0 * 6.5 + 8.0 * 7.75 + 9.0 * 8.5 + 10.0 * 9.25)
    check("mixed18", mixed18(1, 2.5, 3, 4.25, i8(k - 8), 6.75, u16(k + 4), 8.5, 9, 10.25, 11, 12.5, 13, 14.75, u8(k * 0x100 + 200), 16.5, 17, 18.25),
        hash18(1, 2.5, 3, 4.25, -5, 6.75, 7, 8.5, 9, 10.25, 11, 12.5, 13, 14.75, 200, 16.5, 17, 18.25))
    print("not", not_(k == 3), not_(k == 4))
    print("neg8", neg8(i8a), "inc16", inc16(u16d), "half", half(5.0))
    t := twice
    print("twice", t(21), twice(k))

    // ---- structs ----
    checkf("hfa_regs", hfa_regs(F3{x: 1.0, y: 2.0, z: 3.0}, D4{a: 4.0, b: 5.0, c: 6.0, d: 7.0}, 8.0, F2{x: 9.0, y: 10.0}, D1{a: fk}),
        1.0 + 4.0 + 9.0 + 16.0 + 25.0 + 36.0 + 49.0 + 64.0 + 81.0 + 100.0 + 11.0 * fk)
    checkf("hfa_spill", hfa_spill(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, F3{x: 7.0, y: 8.0, z: 9.0}, fk),
        1.0 + 4.0 + 9.0 + 16.0 + 25.0 + 36.0 + 49.0 + 64.0 + 81.0 + 10.0 * fk)
    want = H0
    for v in []i64{1, 2, 3, 4, 5, 6, 7, 80, 90, k} {
        want = mix(want, v)
    }
    check("composite_spill", composite_spill(1, 2, 3, 4, 5, 6, 7, L2{a: 80, b: 90}, k), i64(want))
    want = H0
    for v in []i64{-1, 2, -3, 4, 5, 6, 7, 8, -9, 100000, -k} {
        want = mix(want, v)
    }
    want = mixf(want, 1.5)
    want = mix(want, 12)
    want = mixf(want, -2.75)
    want = mix(want, 0x7FFF_FFFF_FFFF)
    check("small_structs", small_structs(I2{a: -1, b: 2}, C3{a: -3, b: 4, c: 5}, I3{a: 6, b: 7, c: 8},
        M{c: -9, i: 100000, l: -k}, FI{f: 1.5, i: 12}, DL{d: -2.75, l: 0x7FFF_FFFF_FFFF}), i64(want))
    big := Big{a: 1, b: 2, c: k}
    arr := Arr{v: [5]i32{10, 20, 30, 40, 50}}
    want = H0
    for v in []i64{1, 2, k, 10, 20, 30, 40, 50, -k} {
        want = mix(want, v)
    }
    check("big_structs", big_structs(big, arr, -k), i64(want))
    print("big_structs copies", big.a, arr.v[0])

    f3 := ret_f3(1.5)
    d4 := ret_d4(fk)
    d1 := ret_d1(fk)
    f2 := ret_f2(2.5)
    i3 := ret_i3(i32(k))
    c3 := ret_c3(i8(k - 10))
    m := ret_m(k)
    fi := ret_fi(i32(k))
    dl := ret_dl(k)
    bg := ret_big(k)
    print("ret_f3", f3.x, f3.y, f3.z, "ret_d4", d4.a, d4.b, d4.c, d4.d, "ret_d1", d1.a, "ret_f2", f2.x, f2.y)
    print("ret_i3", i3.a, i3.b, i3.c, "ret_c3", c3.a, c3.b, c3.c, "ret_m", m.c, m.i, m.l)
    print("ret_fi", fi.f, fi.i, "ret_dl", dl.d, dl.l, "ret_big", bg.a, bg.b, bg.c)

    // ---- variadic ----
    want = H0
    want = mix(want, -5)
    want = mix(want, 1 << 40)
    want = mixf(want, 2.5)
    want = mix(want, i64(u8b))
    want = mix(want, 0x1234)
    check("va_hash", va_hash(ptr("ildip"), i32(-5), i64(1) << 40, 2.5, u8b, cast[*u8](0x1234)), i64(want))
    want = H0
    for j in 0..12 {
        want = mix(want, j * k)
        want = mixf(want, f64(j) + 0.5)
    }
    check("va_hash many", va_hash(ptr("ldldldldldldldldldldldld"), 0 * k, 0.5, 1 * k, 1.5, 2 * k, 2.5, 3 * k, 3.5,
        4 * k, 4.5, 5 * k, 5.5, 6 * k, 6.5, 7 * k, 7.5, 8 * k, 8.5, 9 * k, 9.5, 10 * k, 10.5, 11 * k, 11.5), i64(want))

    // ---- callbacks ----
    check("call_ints", call_ints(cb_ints), cb_ints(-3, 250, -1234, 60000, -100000, 4000000000, -5000000000, 18000000000000000000, 7, 123456789) * 2 + 1)
    checkf("call_floats", call_floats(cb_floats), cb_floats(0.5, 1.25, 2.5, 3.75, 4.5, 5.25, 6.5, 7.75, 8.5, 9.25) + 1.0)
    check("call_mixed", call_mixed(hash18), hash18(1, 2.5, 3, 4.25, -5, 6.75, 7, 8.5, 9, 10.25, 11, 12.5, 13, 14.75, 200, 16.5, 17, 18.25))
    check("call_narrow", call_narrow(cb_i8, cb_u16, cb_bool, cb_f32), -15 * 1000000 + 65535 * 10 + 1 + 12)
    r := 0
    ok := saved_regs(heavy, k, &r)
    check("saved_regs", ok, 1)
    check("saved_regs result", r, heavy(k))
    check("sp_mod16", sp_mod16(), 0)

    // ---- a variable of the library ----
    print("abi_counter", abi_counter)
    abi_counter = abi_counter + i32(k)
    print("abi_counter", abi_counter, read_counter())
}
