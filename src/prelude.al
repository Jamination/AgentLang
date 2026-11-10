// AL runtime prelude. Compiled together with every program.

var __heap_cur i64
var __heap_end i64
var __heap_base i64
var __argc i64
var __argv i64
var __obuf [65536]u8
var __olen i64
var __tests_failed i64

fn __rt_init(sp i64) {
    __argc = cast[*i64](sp)[0]
    __argv = sp + 8
}

// ---------- process ----------
fn exit(code i64) never {
    flush()
    syscall(231, code)
}

fn __write_all(fd i64, p i64, n i64) {
    while n > 0 {
        r := syscall(1, fd, p, n)
        if r <= 0 {
            if r == -4 {
                continue
            }
            return
        }
        p += r
        n -= r
    }
}

fn __err(s str) {
    __write_all(2, cast[i64](ptr(s)), len(s))
}

fn __die(kind str, loc str, msg str) never {
    flush()
    __err(kind)
    __err(loc)
    if len(msg) > 0 {
        __err(": ")
        __err(msg)
    }
    __err("\n")
    syscall(231, 1)
}

noinline fn __bounds_fail(loc str) never {
    __die("panic: index out of bounds at ", loc, "")
}

noinline fn __div_fail(loc str) never {
    __die("panic: division by zero at ", loc, "")
}

noinline fn __step_fail(loc str) never {
    __die("panic: loop step must be positive at ", loc, "")
}

noinline fn __assert_fail(loc str, msg str) never {
    __die("assertion failed at ", loc, if msg == "assertion failed" { "" } else { msg })
}

noinline fn __panic(loc str, msg str) never {
    __die("panic at ", loc, msg)
}

// ---------- memory ----------
noinline fn __heap_grow(n i64) i64 {
    if __heap_base == 0 {
        size := 1 << 36
        while size >= (1 << 24) {
            // PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE
            p := syscall(9, 0, size, 3, 0x4022, -1, 0)
            if p > 0 || p < -4096 {
                __heap_base = p
                __heap_cur = p
                __heap_end = p + size
                break
            }
            size = size >> 1
        }
        if __heap_base != 0 && n <= __heap_end - __heap_cur {
            p := __heap_cur
            __heap_cur = p + n
            return p
        }
    }
    __die("panic: out of memory", "", "")
}

// zeroed memory, 16-byte aligned; never freed individually (see mark/release)
inline fn __alloc(n i64) i64 {
    n = (n + 15) & ~15
    p := __heap_cur
    e := p + n
    if e > __heap_end {
        return __heap_grow(n)
    }
    __heap_cur = e
    return p
}

fn alloc[T](n i64) []T {
    if n < 0 {
        __die("panic: negative allocation size", "", "")
    }
    return mkslice[T](__alloc(n * sizeof[T]()), n)
}

fn new[T]() *T {
    return cast[*T](__alloc(sizeof[T]()))
}

// arena control: everything allocated after mark() is released (and zeroed) by release()
fn mark() i64 {
    return __heap_cur
}

fn release(m i64) {
    if m >= __heap_base && m < __heap_cur {
        memfill(m, 0, __heap_cur - m)
        __heap_cur = m
    }
}

// ---------- output ----------
fn flush() {
    if __olen > 0 {
        __write_all(1, cast[i64](ptr(__obuf)), __olen)
        __olen = 0
    }
}

fn __put_str(s str) {
    n := len(s)
    if n > 65536 - __olen {
        flush()
        if n >= 65536 {
            __write_all(1, cast[i64](ptr(s)), n)
            return
        }
    }
    memcopy(cast[i64](ptr(__obuf)) + __olen, ptr(s), n)
    __olen += n
}

fn putc(c u8) {
    if __olen == 65536 {
        flush()
    }
    __obuf[__olen] = c
    __olen += 1
}

fn __put_u64(x u64) {
    var b [24]u8
    i := 24
    loop {
        i -= 1
        b[i] = u8(x % 10) + '0'
        x = x / 10
        if x == 0 {
            break
        }
    }
    __put_str(b[i..24])
}

fn __put_i64(x i64) {
    if x < 0 {
        putc('-')
        __put_u64(u64(0) - u64(x))
    } else {
        __put_u64(u64(x))
    }
}

fn __put_bool(b bool) {
    if b {
        __put_str("true")
    } else {
        __put_str("false")
    }
}

fn __put_ptr(x i64) {
    var b [18]u8
    i := 18
    v := u64(x)
    loop {
        i -= 1
        d := u8(v & 15)
        b[i] = if d < 10 { d + '0' } else { d - 10 + 'a' }
        v = v >> 4
        if v == 0 {
            break
        }
    }
    i -= 1
    b[i] = 'x'
    i -= 1
    b[i] = '0'
    __put_str(b[i..18])
}

// ---------- exact float formatting ----------
// Exact decimal digits of m * 2^e written to buf (no leading/trailing zeros).
// Returns (n, pos): value = 0.d1..dn * 10^pos.
fn __dec_expand(m u64, e i64, buf []u8) (i64, i64) {
    var limbs [40]u32
    n := 0
    pos := 0
    if m == 0 {
        return (0, 0)
    }
    if e >= 0 {
        sh := e & 31
        w := e >> 5
        t := (m & 0xFFFFFFFF) << u64(sh)
        limbs[w] = u32(t)
        t = (t >> 32) + ((m >> 32) << u64(sh))
        limbs[w + 1] = u32(t)
        limbs[w + 2] = u32(t >> 32)
        nl := w + 3
        var tmp [340]u8
        tn := 0
        while nl > 0 && limbs[nl - 1] == 0 {
            nl -= 1
        }
        while nl > 0 {
            var rem u64 = 0
            i := nl - 1
            while i >= 0 {
                cur := (rem << 32) | u64(limbs[i])
                limbs[i] = u32(cur / 1000000000)
                rem = cur % 1000000000
                i -= 1
            }
            while nl > 0 && limbs[nl - 1] == 0 {
                nl -= 1
            }
            for k in 0..9 {
                if nl == 0 && rem == 0 {
                    break
                }
                tmp[tn] = u8(rem % 10) + '0'
                tn += 1
                rem = rem / 10
            }
        }
        start := 0
        while start < tn && tmp[start] == '0' {
            start += 1
        }
        n = tn - start
        for j in 0..n {
            buf[j] = tmp[tn - 1 - j]
        }
        return (n, tn)
    }
    k := -e
    var ip u64 = 0
    fr := m
    if k < 64 {
        ip = m >> u64(k)
        fr = m & ((u64(1) << u64(k)) - 1)
    }
    if ip != 0 {
        var tmp [24]u8
        tn := 0
        while ip != 0 {
            tmp[tn] = u8(ip % 10) + '0'
            tn += 1
            ip = ip / 10
        }
        for j in 0..tn {
            buf[j] = tmp[tn - 1 - j]
        }
        n = tn
        pos = tn
    }
    kw := k >> 5
    kb := u32(k & 31)
    nl := kw + 2
    limbs[0] = u32(fr)
    limbs[1] = u32(fr >> 32)
    nonzero := fr != 0
    while nonzero {
        var carry u64 = 0
        for i in 0..nl {
            cur := u64(limbs[i]) * 10 + carry
            limbs[i] = u32(cur)
            carry = cur >> 32
        }
        d := (u64(limbs[kw]) | (u64(limbs[kw + 1]) << 32)) >> u64(kb)
        d = d & 15
        limbs[kw] = limbs[kw] & ((u32(1) << kb) - 1)
        limbs[kw + 1] = 0
        nonzero = false
        for i in 0..kw + 1 {
            if limbs[i] != 0 {
                nonzero = true
            }
        }
        if n == 0 && d == 0 {
            pos -= 1
        } else {
            buf[n] = u8(d) + '0'
            n += 1
        }
    }
    while n > 0 && buf[n - 1] == '0' {
        n -= 1
    }
    return (n, pos)
}

// (mantissa, exponent) with value = m * 2^e; class: 0 finite, 1 inf, 2 nan
fn __f64_parts(x f64) (u64, i64, i64) {
    bits := cast[u64](x)
    ex := i64((bits >> 52) & 2047)
    man := bits & 0xFFFFFFFFFFFFF
    if ex == 2047 {
        return (man, 0, if man == 0 { 1 } else { 2 })
    }
    if ex == 0 {
        return (man, -1074, 0)
    }
    return (man | (u64(1) << 52), ex - 1075, 0)
}

fn __copy_str(out []u8, o i64, s str) i64 {
    for c in s {
        out[o] = c
        o += 1
    }
    return o
}

// printf("%.*f") semantics: exact value, round half to even. Returns the length written to out.
fn __fmt_fixed(x f64, prec i64, out []u8) i64 {
    if prec < 0 {
        prec = 0
    }
    if prec > 400 {
        prec = 400
    }
    m, e, cls := __f64_parts(x)
    neg := (cast[u64](x) >> 63) != 0
    o := 0
    if cls == 2 {
        return __copy_str(out, o, "nan")
    }
    if neg {
        out[o] = '-'
        o += 1
    }
    if cls == 1 {
        return __copy_str(out, o, "inf")
    }
    var d [1600]u8
    n, pos := __dec_expand(m, e, d[..])
    keep := pos + prec
    up := false
    if keep < n && keep >= 0 {
        c := d[keep]
        if c > '5' {
            up = true
        } else if c == '5' {
            if n > keep + 1 {
                up = true
            } else if keep > 0 && ((d[keep - 1] - '0') & 1) == 1 {
                up = true
            }
        }
    }
    if keep < 0 {
        keep = 0
    }
    for i in n..keep {
        d[i] = '0'
    }
    if up {
        i := keep - 1
        while i >= 0 && d[i] == '9' {
            d[i] = '0'
            i -= 1
        }
        if i >= 0 {
            d[i] += 1
        } else {
            // carry out: 0.99.. -> 1.00..
            d[keep] = '0'
            d[0] = '1'
            pos += 1
            keep += 1
        }
    }
    if pos <= 0 {
        out[o] = '0'
        o += 1
    } else {
        for i in 0..pos {
            out[o] = d[i]
            o += 1
        }
    }
    if prec > 0 {
        out[o] = '.'
        o += 1
        for j in 0..prec {
            idx := pos + j
            out[o] = if idx >= 0 && idx < keep { d[idx] } else { '0' }
            o += 1
        }
    }
    return o
}

fn __dec_cmp(a []u8, an i64, ap i64, b []u8, bn i64, bp i64) i64 {
    if ap != bp {
        return if ap < bp { -1 } else { 1 }
    }
    mx := if an > bn { an } else { bn }
    for i in 0..mx {
        x := if i < an { a[i] } else { '0' }
        y := if i < bn { b[i] } else { '0' }
        if x != y {
            return if x < y { -1 } else { 1 }
        }
    }
    return 0
}

// shortest decimal that parses back to exactly x. Returns the length written to out.
fn __fmt_shortest(x f64, out []u8) i64 {
    m, e, cls := __f64_parts(x)
    neg := (cast[u64](x) >> 63) != 0
    o := 0
    if cls == 2 {
        return __copy_str(out, o, "nan")
    }
    if neg {
        out[o] = '-'
        o += 1
    }
    if cls == 1 {
        return __copy_str(out, o, "inf")
    }
    if m == 0 {
        return __copy_str(out, o, "0.0")
    }
    var d [1100]u8
    var dh [1100]u8
    var dl [1100]u8
    n, pos := __dec_expand(m, e, d[..])
    nh, ph := __dec_expand(2 * m + 1, e - 1, dh[..])
    nl := 0
    pl := 0
    if m == (u64(1) << 52) && e > -1074 {
        nl, pl = __dec_expand(4 * m - 1, e - 2, dl[..])
    } else {
        nl, pl = __dec_expand(2 * m - 1, e - 1, dl[..])
    }
    even := (m & 1) == 0
    var c [24]u8
    cn := 0
    cp := 0
    for p in 1..19 {
        if p >= n {
            for i in 0..n {
                c[i] = d[i]
            }
            cn = n
            cp = pos
            break
        }
        for i in 0..p {
            c[i] = d[i]
        }
        cn = p
        cp = pos
        up := d[p] > '5' || (d[p] == '5' && (n > p + 1 || ((d[p - 1] - '0') & 1) == 1))
        if up {
            i := p - 1
            while i >= 0 && c[i] == '9' {
                i -= 1
            }
            if i >= 0 {
                c[i] += 1
                cn = i + 1
            } else {
                c[0] = '1'
                cn = 1
                cp = pos + 1
            }
        }
        while cn > 1 && c[cn - 1] == '0' {
            cn -= 1
        }
        lo := __dec_cmp(c[..], cn, cp, dl[..], nl, pl)
        hi := __dec_cmp(c[..], cn, cp, dh[..], nh, ph)
        if (lo > 0 || (even && lo == 0)) && (hi < 0 || (even && hi == 0)) {
            break
        }
    }
    if cp > 0 && cp <= 21 {
        for i in 0..cp {
            out[o] = if i < cn { c[i] } else { '0' }
            o += 1
        }
        out[o] = '.'
        o += 1
        if cn > cp {
            for i in cp..cn {
                out[o] = c[i]
                o += 1
            }
        } else {
            out[o] = '0'
            o += 1
        }
        return o
    }
    if cp <= 0 && cp > -6 {
        out[o] = '0'
        out[o + 1] = '.'
        o += 2
        for i in 0..-cp {
            out[o] = '0'
            o += 1
        }
        for i in 0..cn {
            out[o] = c[i]
            o += 1
        }
        return o
    }
    out[o] = c[0]
    o += 1
    if cn > 1 {
        out[o] = '.'
        o += 1
        for i in 1..cn {
            out[o] = c[i]
            o += 1
        }
    }
    out[o] = 'e'
    o += 1
    ex := cp - 1
    if ex < 0 {
        out[o] = '-'
        o += 1
        ex = -ex
    }
    var t [8]u8
    tn := 0
    loop {
        t[tn] = u8(ex % 10) + '0'
        tn += 1
        ex = ex / 10
        if ex == 0 {
            break
        }
    }
    for i in 0..tn {
        out[o] = t[tn - 1 - i]
        o += 1
    }
    return o
}

fn __put_f64(x f64) {
    var b [40]u8
    n := __fmt_shortest(x, b[..])
    __put_str(b[..n])
}

// print x with exactly `prec` digits after the decimal point (like printf "%.Nf")
fn putf(x f64, prec i64) {
    var b [800]u8
    n := __fmt_fixed(x, prec, b[..])
    __put_str(b[..n])
}

fn fmtf(x f64, prec i64) str {
    var b [800]u8
    n := __fmt_fixed(x, prec, b[..])
    s := alloc[u8](n)
    for i in 0..n {
        s[i] = b[i]
    }
    return s
}

fn __put_slice[T](s []T) {
    putc('[')
    for i, x in s {
        if i > 0 {
            __put_str(", ")
        }
        put(x)
    }
    putc(']')
}

fn __str_eq(a str, b str) bool {
    n := len(a)
    if n != len(b) {
        return false
    }
    for i in 0..n {
        if a[i] != b[i] {
            return false
        }
    }
    return true
}

// ---------- tests ----------
fn __run_test(name str, f fn()) {
    flush()
    pid := syscall(57)
    if pid == 0 {
        f()
        exit(0)
    }
    var status i32
    syscall(61, pid, &status, 0, 0)
    if status == 0 {
        put("ok   ", name, "\n")
    } else {
        put("FAIL ", name, "\n")
        __tests_failed += 1
    }
    flush()
}

fn __tests_done() i64 {
    if __tests_failed > 0 {
        put(__tests_failed, " test(s) failed\n")
        return 1
    }
    return 0
}
