// The independent AAPCS64 classifier (tests/arm64/aapcs.al, which tests/arm64/check.al uses on
// the C calls of executables) against the placements clang 19 gives for the same signatures
// (`clang --target=aarch64-linux-gnu -O1 -S`: the caller's moves and stores; for macOS
// `--target=arm64-apple-macos`), one row per signature. The cases are the rules of the standard
// that matter for AL: narrow integers in registers and in 8-byte stack slots, floats past v7, an
// HFA that no longer fits (the stack, and no v register after it), a composite that no longer
// fits (the stack, and no x register after it), small composites in one or two x registers,
// large ones by reference, results in x0-x1, v0-v3 or through x8, variadic arguments.
use "../arm64/aapcs.al"

fn i8_() -> CT { CT.Int(1, true) }
fn i16_() -> CT { CT.Int(2, true) }
fn i32_() -> CT { CT.Int(4, true) }
fn i64_() -> CT { CT.Int(8, true) }
fn f32_() -> CT { CT.Flt(4) }
fn f64_() -> CT { CT.Flt(8) }
fn rec(fs: []CT) -> CT { CT.Rec(vec_of(fs)) }

fn row(name: str, args: []CT, nfixed: i64, ret: Opt[CT], apple: bool, want: str) -> bool {
    locs, r := aapcs64(args, nfixed, ret, apple)
    got := loc_text(locs.items(), r)
    if got != want {
        print(fmt("  ", name, ": got `", got, "`, expected `", want, "`"))
        return false
    }
    return true
}

fn f3() -> CT { rec([]CT{f32_(), f32_(), f32_()}) }
fn l2() -> CT { rec([]CT{i64_(), i64_()}) }
fn d4() -> CT { rec([]CT{f64_(), f64_(), f64_(), f64_()}) }
fn big() -> CT { rec([]CT{i64_(), i64_(), i64_()}) }
fn i3() -> CT { rec([]CT{i32_(), i32_(), i32_()}) }

test "aapcs64 linux: scalars" {
    ok := row("narrow, double, 9th on the stack", []CT{i8_(), i16_(), i32_(), i64_(), f64_(), i64_(), i64_(), i64_(), i64_(), i8_()}, 10, Some(i64_()), false,
        "x0 x1 x2 x3 v0 x4 x5 x6 x7 [sp+0,1] -> x0")
    // t4 of the clang comparison: float f9(8 floats, float, double)
    ok = row("floats past v7", []CT{f32_(), f32_(), f32_(), f32_(), f32_(), f32_(), f32_(), f32_(), f32_(), f64_()}, 10, Some(f32_()), false,
        "v0 v1 v2 v3 v4 v5 v6 v7 [sp+0,4] [sp+8,8] -> v0") && ok
    // t5: char c10(8 longs, char, short, int): each stack argument in its own 8-byte slot
    ok = row("narrow stack slots", []CT{i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i8_(), i16_(), i32_()}, 11, Some(i8_()), false,
        "x0 x1 x2 x3 x4 x5 x6 x7 [sp+0,1] [sp+8,2] [sp+16,4] -> x0") && ok
    // t7: long va(int, ...) with (double, int, double, char as int): the same registers
    ok = row("variadic", []CT{i32_(), f64_(), i32_(), f64_(), i32_()}, 1, Some(i64_()), false,
        "x0 v0 x1 v1 x2 -> x0") && ok
    assert ok
}

test "aapcs64 linux: composites" {
    // the first comparison: long f(char, short, int, long, double, struct {float x3},
    // struct {long x3}, struct {char; int; long}, int, char)
    m := rec([]CT{i8_(), i32_(), i64_()})
    ok := row("mixed", []CT{i8_(), i16_(), i32_(), i64_(), f64_(), f3(), big(), m, i32_(), i8_()}, 10, Some(i64_()), false,
        "x0 x1 x2 x3 v0 v1-v3 &x4 x5-x6 x7 [sp+0,1] -> x0")
    // t1: hfa_spill(6 doubles, struct F3, double): the HFA needs v6-v8, so it and the double
    // after it go to the stack (12 bytes rounded up to 16)
    ok = row("hfa spill", []CT{f64_(), f64_(), f64_(), f64_(), f64_(), f64_(), f3(), f64_()}, 8, Some(f64_()), false,
        "v0 v1 v2 v3 v4 v5 [sp+0,12] [sp+16,8] -> v0") && ok
    // t2: composite_spill(7 longs, struct L2, long)
    ok = row("composite spill", []CT{i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), l2(), i64_()}, 9, Some(i64_()), false,
        "x0 x1 x2 x3 x4 x5 x6 [sp+0,16] [sp+16,8] -> x0") && ok
    // t3: small(I2, C3, I3, M, FI, DL): FI (float, int) is no HFA; DL needs x7 and x8
    ok = row("small composites", []CT{rec([]CT{i32_(), i32_()}), rec([]CT{i8_(), i8_(), i8_()}), i3(), m,
        rec([]CT{f32_(), i32_()}), rec([]CT{f64_(), i64_()})}, 6, Some(i64_()), false,
        "x0 x1 x2-x3 x4-x5 x6 [sp+0,16] -> x0") && ok
    // t6: results
    ok = row("result through x8", []CT{i32_()}, 1, Some(big()), false, "x0 -> [x8]") && ok
    ok = row("result in x0-x1", []CT{}, 0, Some(i3()), false, " -> x0-x1") && ok
    ok = row("result in v0-v3", []CT{}, 0, Some(d4()), false, " -> v0-v3") && ok
    ok = row("an array member", []CT{rec([]CT{CT.Arr(vec_of([]CT{f32_()}), 2)})}, 1, None, false, "v0-v1 -> void") && ok
    ok = row("five floats are no HFA", []CT{rec([]CT{CT.Arr(vec_of([]CT{f32_()}), 5)})}, 1, None, false, "&x0 -> void") && ok
    assert ok
}

test "aapcs64 macos" {
    // (`clang --target=arm64-apple-macos11 -O1 -S`, the same signatures)
    // t5: stack arguments packed by their size and alignment
    ok := row("narrow stack arguments", []CT{i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i8_(), i16_(), i32_()}, 11, Some(i8_()), true,
        "x0 x1 x2 x3 x4 x5 x6 x7 [sp+0,1] [sp+2,2] [sp+4,4] -> x0")
    // t4: a float, then a double at its alignment
    ok = row("floats past v7", []CT{f32_(), f32_(), f32_(), f32_(), f32_(), f32_(), f32_(), f32_(), f32_(), f64_()}, 10, Some(f32_()), true,
        "v0 v1 v2 v3 v4 v5 v6 v7 [sp+0,4] [sp+8,8] -> v0") && ok
    // t8: composites on the stack in 8-byte aligned slots of whole words
    c3 := rec([]CT{i8_(), i8_(), i8_()})
    ok = row("composites on the stack", []CT{i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i64_(), i8_(), c3, i16_(), i3(), i32_()}, 13, Some(c3), true,
        "x0 x1 x2 x3 x4 x5 x6 x7 [sp+0,1] [sp+8,3] [sp+16,2] [sp+24,12] [sp+40,4] -> x0") && ok
    // t1: the HFA that does not fit goes to the stack, rounded up to 8
    ok = row("hfa spill", []CT{f64_(), f64_(), f64_(), f64_(), f64_(), f64_(), f3(), f64_()}, 8, Some(f64_()), true,
        "v0 v1 v2 v3 v4 v5 [sp+0,12] [sp+16,8] -> v0") && ok
    // t7, t9: every variadic argument in an 8-byte stack slot, composites too
    ok = row("variadic", []CT{i32_(), f64_(), i32_(), f64_(), i32_()}, 1, Some(i64_()), true,
        "x0 [sp+0,8] [sp+8,4] [sp+16,8] [sp+24,4] -> x0") && ok
    ok = row("variadic composites", []CT{i32_(), f64_(), i32_(), f3(), l2(), i64_()}, 1, Some(i64_()), true,
        "x0 [sp+0,8] [sp+8,4] [sp+16,12] [sp+32,16] [sp+48,8] -> x0") && ok
    assert ok
}
