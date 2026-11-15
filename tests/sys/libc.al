// std.libc on both systems (Linux: glibc, Windows: msvcrt.dll): the declarations they share
// print the same; what differs (snprintf / _snprintf, %p, the exponent of %e, the size of
// `long`, dprintf) is checked per system
use std.libc
when TARGET_OS == Linux {
    extern "libc.so.6" fn pipe(fds: *i32) -> i32
    extern "libc.so.6" fn read(fd: i32, buf: *u8, n: i64) -> i64
    extern "libc.so.6" fn close(fd: i32) -> i32
}

fn cmp_i32(a: *u8, b: *u8) -> i32 {
    x := cast[*i32](a)[0]
    y := cast[*i32](b)[0]
    if x < y { return -1 }
    if x > y { return 1 }
    return 0
}
fn main() {
    print(getpid() > 0, strlen(cast[*u8](ptr("hello\0"))))
    a: [6]i32
    for i in 0..6 { a[i] = i32((i * 7 + 3) % 6) }
    qsort(cast[*u8](ptr(a)), 6, 4, cmp_i32)
    print(a)
    buf: [64]u8
    n: i32
    when TARGET_OS == Windows {
        // the stream writes "\n" as it is (text mode, the default, writes "\r\n")
        _setmode(_fileno(c_stdout()), O_BINARY)
        n = _snprintf(ptr(buf), 64, cast[*u8](ptr("%.3f|%lld\0")), 3.14159, i64(42))
    } else {
        n = snprintf(ptr(buf), 64, cast[*u8](ptr("%.3f|%lld\0")), 3.14159, i64(42))
    }
    print(buf[..i64(n)], cosf(0.0), pow(f64(2.0), 10.0))
    p := malloc(100)
    print(p != nil)
    free(p)

    // variadic: sprintf with the conversions that both C libraries print alike
    big: [256]u8
    u: u8 = 200
    n = sprintf(&big[0], ptr("%d %lld %u %f %s %c %u %x %o %5s|%-4d|%05.1f"), -7, i64(-1) << 40, u32(3000000000), f32(0.25),
        ptr("str"), 'Q', u, 255, 8, ptr("ab"), 42, 2.5)
    print(n, from_cstr(&big[0]))
    // and those that differ
    when TARGET_OS == Windows {
        // pointers as 16 hexadecimal digits, three digits in the exponent, `long` has 32 bits
        n = sprintf(&big[0], ptr("%p %p %.2e %ld %I64d"), cast[*u8](0xbeef), nil, 1234.5, i32(-5), i64(1) << 40)
        print(from_cstr(&big[0]) == "000000000000BEEF 0000000000000000 1.23e+003 -5 1099511627776")
        // _snprintf: the text does not fit: -1 and no NUL; it fits exactly: no NUL either
        fill(big[..], '#')
        n = _snprintf(&big[0], 4, ptr("%d"), 123456)
        k := _snprintf(&big[8], 6, ptr("%d"), 123456)
        print(n == -1 && big[..5] == "1234#" && k == 6 && big[8..15] == "123456#")
    } else {
        n = sprintf(&big[0], ptr("%p %p %.2e %ld %ld"), cast[*u8](0xbeef), nil, 1234.5, i64(-5), i64(1) << 40)
        print(from_cstr(&big[0]) == "0xbeef (nil) 1.23e+03 -5 1099511627776")
        // snprintf: the text does not fit: the length it needs, cut and NUL-terminated
        fill(big[..], '#')
        n = snprintf(&big[0], 4, ptr("%d"), 123456)
        k := snprintf(&big[8], 7, ptr("%d"), 123456)
        print(n == 6 && big[..5] == "123\0#" && k == 6 && big[8..15] == "123456\0")
    }
    // printf to standard output, ordered with AL's own output
    print("before")
    flush()
    printf(ptr("printf: %d %s %.1f\n"), 1, ptr("two"), 3.0)
    fflush(c_stdout())
    fprintf(c_stdout(), ptr("fprintf: %llu\n"), u64(18446744073709551615))
    fflush(nil)
    print("after")
    when TARGET_OS == Windows {
        // (no dprintf: the same text through sprintf)
        w := sprintf(&big[0], ptr("%d-%d-%d %x %o %5s|"), 1, 2, 3, 255, 8, ptr("ab"))
        got := strlen(&big[0])
        print(w, got, big[..got])
    } else {
        // dprintf into a pipe, read back
        fds: [2]i32
        assert pipe(&fds[0]) == 0
        w := dprintf(fds[1], ptr("%d-%d-%d %x %o %5s|"), 1, 2, 3, 255, 8, ptr("ab"))
        close(fds[1])
        got := read(fds[0], &big[0], 256)
        close(fds[0])
        print(w, got, big[..got])
    }
    // sscanf: pointers only
    x: i32
    y: f64
    word: [16]u8
    m := sscanf(ptr("12 2.5 abc"), ptr("%d %lf %15s"), &x, &y, &word[0])
    print(m, x, y, from_cstr(&word[0]))
    // the streams
    flush()
    fprintf(c_stderr(), ptr("to %s\n"), ptr("standard error"))
    fflush(c_stderr())
    home := if TARGET_OS == Windows { "USERPROFILE" } else { "HOME" }
    print(len(from_cstr(getenv(cstr(home)))) > 0, getenv(ptr("AL_LIBC_TEST_NOT_SET")) == nil)
}
