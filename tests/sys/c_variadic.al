// calls of variadic C functions (`...`): the arguments as C reads them with va_arg (the C
// library c_variadic.c reports them), the C default argument promotions, stack slots, many
// float arguments, and the C library's own sprintf (Windows: msvcrt.dll)
when TARGET_OS == Windows {
    extern "c_variadic.dll" fn va_report(out: *u8, spec: *u8, ...) -> i32
    extern "c_variadic.dll" fn va_sum(n: i32, ...) -> f64
    extern "c_variadic.dll" fn va_after_float(x: f32, n: i32, ...) -> f64
    extern "msvcrt.dll" fn sprintf(buf: *u8, format: *u8, ...) -> i32
} else {
    extern "libc_variadic.so" fn va_report(out: *u8, spec: *u8, ...) -> i32
    extern "libc_variadic.so" fn va_sum(n: i32, ...) -> f64
    extern "libc_variadic.so" fn va_after_float(x: f32, n: i32, ...) -> f64
    extern "libc.so.6" fn sprintf(buf: *u8, format: *u8, ...) -> i32
}

buf: [2048]u8

fn show(n: i32) {
    print(n, from_cstr(&buf[0]))
}

fn twice(x: i32) -> i32 {
    return 2 * x + 1
}

fn main() {
    // values the optimiser cannot know: registers may hold more than the narrow value
    k := i64(len(args()))                      // 3
    big := k * 0x100 + 0x7FB                   // 0xAFB: low byte 0xFB, low 16 bits 0x0AFB
    i8v := i8(big)                             // -5
    u8v := u8(big)                             // 251
    i16v := i16(big * 0x10 + 0x10000)          // 0x1AFB0: -20560
    u16v := u16(big * 0x10 + 0x10000)          // 44976
    show(va_report(&buf[0], ptr("iiiiiiii"), i8v, u8v, i16v, u16v, true, false, i8(-128), u8(255)))

    // 32 and 64 bits: edge values
    show(va_report(&buf[0], ptr("iiuulllLL"), i32(-2147483648), i32(2147483647), u32(0), u32(4294967295),
        i64(-9223372036854775807) - 1, i64(9223372036854775807), i64(-1), u64(0), u64(18446744073709551615)))

    // untyped literals: i32 if they fit, else i64 (u64 beyond); f64; nil a pointer
    show(va_report(&buf[0], ptr("iiilLdpi"), 7, -7, 'A', 1 << 40, 18446744073709551615, 2.5, nil, 0x7FFFFFFF))

    // f32 becomes f64 (its exact value, not the nearest f64 to the decimal), f64 as it is
    f: f32 = 1.1
    g := 0.1
    show(va_report(&buf[0], ptr("dddd"), f, f64(1.1), g, f32(-0.0)))

    // pointers and function values
    show(va_report(&buf[0], ptr("pfpf"), cast[*u8](0x1234), twice, cast[*u8](u64(0xFFFFFFFFFFFF0000)), fn(x: i32) -> i32 { x * x }))

    // more than 6 integer and 8 float arguments: the rest in stack slots, mixed
    show(va_report(&buf[0], ptr("ididididididididididid"), 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6, 6.5,
        7, 7.5, 8, 8.5, 9, 9.5, i8v, f, u16v, 11.25))
    show(va_report(&buf[0], ptr("lllllllllll"), k, k + 1, k + 2, k + 3, k + 4, k + 5, k + 6, k + 7, k + 8, k + 9, k + 10))
    show(va_report(&buf[0], ptr("ddddddddddd"), 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, f64(k)))

    // floats in the first slots (Windows: also in rdx, r8, r9), the result in xmm0
    print(va_sum(1, 1.0), va_sum(3, 1.0, 2.0, 3.0), va_sum(9, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0))
    print(va_sum(4, f32(1.0), f64(k), 0.0, f32(2.5)))
    // a fixed f32 parameter stays an f32
    print(va_after_float(0.5, 3, 1.0, 1, 2.0, 2, 3.0, i8(-3)))

    // the C library's sprintf (formats that print the same on both systems)
    n := sprintf(&buf[0], ptr("%d %u %lld %llu %.3f %s %c %x %5.1f|%-3d|"), -42, u32(4000000000), i64(-9000000000),
        u64(18000000000000000000), 3.14159, ptr("text"), 'z', 255, f32(2.4), 7)
    show(n)
    n = sprintf(&buf[0], ptr("%g %g %g %g %g %g %g %g %g %g"), 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5)
    show(n)
    n = sprintf(&buf[0], ptr("%d %d %d %d %d %d %d %d %.1f %d"), 1, 2, 3, 4, 5, 6, 7, 8, 9.0, true)
    show(n)
}
