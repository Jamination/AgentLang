// AL runtime prelude. Compiled together with every program.
//
// Everything that depends on the operating system is in the OS layer of the target, compiled
// right after this file: src/prelude_linux.al (system calls) or src/prelude_windows.al
// (kernel32.dll). Each layer defines the same functions:
//   __rt_init(sp)                  called first by the generated entry point
//   __os_exit(code) -> never       ends the process (output is flushed by the callers)
//   __os_panic(kind, loc, msg)     after a panic message was written to standard error (Windows
//                                  GUI programs: a message box)
//   __write_all(fd, p, n) -> errno writes everything (fd 1 / 2: standard output / error)
//   __os_read(fd, p, n)            bytes read, 0 at the end, or -errno
//   __os_open(path, write)         a descriptor or -errno (path: NUL-terminated)
//   __os_close(fd), __os_fstat(fd) -> (size, is a regular file)
//   __heap_grow(n)                 the slow path of the arena allocator (see below)
//   __os_map(n), __os_unmap(p, n)  memory outside the arena (address or -errno; 0 or -errno)
//   __os_test(f) -> 1 / 0 / -1     runs one `test` block in a process of its own: passed,
//                                  failed, or not run by this process
//   __os_error_text(e)             error_text for numbers it does not know
//   clock_ns, args, env_get        the public functions of that name
// plus the __os_* functions used by std.asset, std.time and std.os. Error numbers are
// Linux errno values on every target (the Windows layer maps its error codes to them).

__heap_cur: i64
__heap_end: i64
__heap_base: i64
__heap_hwm: i64
__obuf: [65536]u8
__olen: i64
__tests_failed: i64

// ---------- process ----------
fn exit(code: i64) -> never {
    flush()
    __os_exit(code)
}

// standard output that cannot be written stops the program (a closed pipe normally ends it
// before, with SIGPIPE)
noinline fn __out_write(p: i64, n: i64) {
    e := __write_all(1, p, n)
    if e != 0 {
        __olen = 0
        __die("panic: cannot write to standard output: ", error_text(e), "")
    }
}

fn __err(s: str) {
    __write_all(2, cast[i64](ptr(s)), len(s))
}

fn __die(kind: str, loc: str, msg: str) -> never {
    flush()
    __err(kind)
    __err(loc)
    if len(msg) > 0 {
        __err(": ")
        __err(msg)
    }
    __err("\n")
    __os_panic(kind, loc, msg)
    __os_exit(1)
}

noinline fn __bounds_fail(loc: str) -> never {
    __die("panic: index out of bounds at ", loc, "")
}

noinline fn __div_fail(loc: str) -> never {
    __die("panic: division by zero at ", loc, "")
}

noinline fn __step_fail(loc: str) -> never {
    __die("panic: loop step must be positive at ", loc, "")
}

noinline fn __assert_fail(loc: str, msg: str) -> never {
    __die("assertion failed at ", loc, if msg == "assertion failed" { "" } else { msg })
}

noinline fn __panic(loc: str, msg: str) -> never {
    __die("panic at ", loc, msg)
}

// ---------- memory ----------
// The arena that allocations come from is described by __heap_cur / __heap_end / __heap_base /
// __heap_hwm. A program starts in the main arena; enter(&r) makes a Region the arena in use.
// The state of an arena that is not in use is kept in its Region struct (the main arena's in
// __heap_main), so the allocation paths below never look at regions.
struct Region { cur: i64, end: i64, base: i64, hwm: i64 }

__heap_main: Region
__region_stack: [64]*Region
__region_depth: i64

// __heap_grow(n) (OS layer) hands out n bytes when they do not fit between __heap_cur and
// __heap_end, or stops the program with "out of memory". The first call for an arena reserves
// its address space: 64 GiB for the main arena, 16 GiB for a region (thousands of regions
// fit), less if refused. __heap_end is the end of the memory that may be used without asking
// the system again (Linux: the whole reservation; Windows: the committed part).

// uninitialized memory, 16-byte aligned; never freed individually (see mark/release). A size
// that is negative (also one that overflowed) is refused by __heap_grow.
inline fn __alloc_raw(n: i64) -> i64 {
    n = (n + 15) & ~15
    p := __heap_cur
    if u64(n) > u64(__heap_end - p) {
        return __heap_grow(n)
    }
    __heap_cur = p + n
    return p
}

// the bytes of n elements of `size` bytes; stops the program if n is negative or the result
// does not fit in an i64
inline fn __alloc_size(n: i64, size: i64) -> i64 {
    if n < 0 || mulhi(u64(n), u64(size)) != 0 || n * size < 0 {
        __size_fail(n)
    }
    return n * size
}

noinline fn __size_fail(n: i64) -> never {
    if n < 0 {
        __die("panic: negative allocation size", "", "")
    }
    __die("panic: out of memory", "", "")
}

// zeroed memory: only memory that was handed out before (below the high-water mark) is dirty
inline fn __alloc(n: i64) -> i64 {
    p := __alloc_raw(n)
    if p < __heap_hwm {
        d := __heap_hwm - p
        memfill(p, 0, if d < n { d } else { n })
    }
    return p
}

// a + b for sizes that are not negative; stops the program if the sum does not fit
inline fn __add_size(a: i64, b: i64) -> i64 {
    if a + b < 0 {
        __size_fail(0)
    }
    return a + b
}

fn alloc[T](n: i64) -> []T {
    return mkslice[T](__alloc(__alloc_size(n, sizeof[T]())), n)
}

fn new[T]() -> *T {
    return cast[*T](__alloc(sizeof[T]()))
}

// arena control: everything allocated after mark() is released by release()
fn mark() -> i64 {
    return __heap_cur
}

fn release(m: i64) {
    // a mark taken before the first allocation (the heap is mapped lazily) means "everything"
    if m == 0 {
        m = __heap_base
    }
    if m >= __heap_base && m < __heap_cur {
        if __heap_cur > __heap_hwm {
            __heap_hwm = __heap_cur
        }
        __heap_cur = m
    }
}

// ---------- regions: independent arenas ----------
// A Region is an arena of its own. The zero value is a valid empty region. Between enter(&r)
// and the matching leave() everything that allocates (alloc, new, Vec, Map, fmt, slice
// literals, clone, ...) takes its memory from r; reset(&r) empties it in one step. A region
// is used through a pointer and must not be copied while it holds memory or is entered.
fn region() -> Region {
    return Region{}
}

fn __region_save(r: *Region) {
    r.cur = __heap_cur
    r.end = __heap_end
    r.base = __heap_base
    r.hwm = __heap_hwm
}

fn __region_load(r: *Region) {
    __heap_cur = r.cur
    __heap_end = r.end
    __heap_base = r.base
    __heap_hwm = r.hwm
}

// the arena in use: the innermost entered region, or the main arena
fn __region_top() -> *Region {
    if __region_depth == 0 {
        return &__heap_main
    }
    return __region_stack[__region_depth - 1]
}

fn __region_entered(r: *Region) -> bool {
    return contains(__region_stack[..__region_depth], r)
}

// allocations now come from r, until the matching leave(); calls nest up to 64 deep
fn enter(r: *Region) {
    if __region_depth == 64 {
        __die("panic: enter: more than 64 regions are entered (is a leave() missing?)", "", "")
    }
    if __region_entered(r) {
        __die("panic: enter: this region is already entered", "", "")
    }
    __region_save(__region_top())
    __region_load(r)
    __region_stack[__region_depth] = r
    __region_depth += 1
}

// back to the arena that was in use before the matching enter()
fn leave() {
    if __region_depth == 0 {
        __die("panic: leave without enter", "", "")
    }
    __region_save(__region_stack[__region_depth - 1])
    __region_depth -= 1
    __region_load(__region_top())
}

// empties r: everything allocated from it is gone. Its memory is kept and handed out again
// (zeroed) by later allocations. r may be the region in use.
fn reset(r: *Region) {
    if __region_depth > 0 && __region_stack[__region_depth - 1] == r {
        if __heap_cur > __heap_hwm {
            __heap_hwm = __heap_cur
        }
        __heap_cur = __heap_base
        return
    }
    if r.cur > r.hwm {
        r.hwm = r.cur
    }
    r.cur = r.base
}

// bytes of r in use
fn used(r: *Region) -> i64 {
    if __region_depth > 0 && __region_stack[__region_depth - 1] == r {
        return __heap_cur - __heap_base
    }
    return r.cur - r.base
}

// gives the memory of r back to the operating system; r is empty afterwards and can be used
// again. The region must not be entered.
fn region_free(r: *Region) {
    if __region_entered(r) {
        __die("panic: region_free: this region is entered (leave() first)", "", "")
    }
    if r.base != 0 {
        __os_unmap(r.base, r.end - r.base)
    }
    *r = Region{}
}

// ---------- output ----------
fn flush() {
    if __olen > 0 {
        n := __olen
        __olen = 0
        __out_write(cast[i64](ptr(__obuf)), n)
    }
}

noinline fn __put_str(s: str) {
    if __cap_on != 0 {
        __cap_put(s)
        return
    }
    n := len(s)
    if n > 65536 - __olen {
        flush()
        if n >= 65536 {
            __out_write(cast[i64](ptr(s)), n)
            return
        }
    }
    memcopy(cast[i64](ptr(__obuf)) + __olen, ptr(s), n)
    __olen += n
}

fn putc(c: u8) {
    if __cap_on != 0 {
        one: [1]u8
        one[0] = c
        __cap_put(one[..])
        return
    }
    if __olen == 65536 {
        flush()
    }
    __obuf[__olen] = c
    __olen += 1
}

fn __put_u64(x: u64) {
    b: [24]u8
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

fn __put_i64(x: i64) {
    if x < 0 {
        putc('-')
        __put_u64(u64(0) - u64(x))
    } else {
        __put_u64(u64(x))
    }
}

fn __put_bool(b: bool) {
    if b {
        __put_str("true")
    } else {
        __put_str("false")
    }
}

fn __put_ptr(x: i64) {
    b: [18]u8
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
fn __dec_expand(m: u64, e: i64, buf: []u8) -> (i64, i64) {
    limbs: [40]u32
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
        tmp: [340]u8
        tn := 0
        while nl > 0 && limbs[nl - 1] == 0 {
            nl -= 1
        }
        while nl > 0 {
            rem: u64 = 0
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
    ip: u64 = 0
    fr := m
    if k < 64 {
        ip = m >> u64(k)
        fr = m & ((u64(1) << u64(k)) - 1)
    }
    if ip != 0 {
        tmp: [24]u8
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
        carry: u64 = 0
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
fn __f64_parts(x: f64) -> (u64, i64, i64) {
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

fn __copy_str(out: []u8, o: i64, s: str) -> i64 {
    return o + copy(out[o..], s)
}

// printf("%.*f") semantics: exact value, round half to even. Returns the length written to out.
fn __fmt_fixed(x: f64, prec: i64, out: []u8) -> i64 {
    if prec < 0 {
        prec = 0
    }
    // every f64 has at most 1074 digits after the point: more precision only adds zeros, which
    // the callers append (__fmt_extra)
    if prec > 1100 {
        prec = 1100
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
    d: [1600]u8
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
        o += copy(out[o..], d[..pos])
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

fn __dec_cmp(a: []u8, an: i64, ap: i64, b: []u8, bn: i64, bp: i64) -> i64 {
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
fn __fmt_shortest(x: f64, out: []u8) -> i64 {
    m, e, cls := __f64_parts(x)
    neg := (cast[u64](x) >> 63) != 0
    return __fmt_short_parts(neg, m, e, cls, m == (u64(1) << 52) && e > -1074, out)
}

fn __fmt_shortest32(x: f32, out: []u8) -> i64 {
    bits := cast[u32](x)
    ex := i64((bits >> 23) & 255)
    man := u64(bits & 0x7FFFFF)
    neg := (bits >> 31) != 0
    if ex == 255 {
        return __fmt_short_parts(neg, man, 0, if man == 0 { 1 } else { 2 }, false, out)
    }
    if ex == 0 {
        return __fmt_short_parts(neg, man, -149, 0, false, out)
    }
    return __fmt_short_parts(neg, man | (u64(1) << 23), ex - 150, 0, man == 0 && ex > 1, out)
}

// value = m * 2^e; `closer`: the gap to the next smaller float is half the usual one
fn __fmt_short_parts(neg: bool, m: u64, e: i64, cls: i64, closer: bool, out: []u8) -> i64 {
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
    d: [1100]u8
    dh: [1100]u8
    dl: [1100]u8
    n, pos := __dec_expand(m, e, d[..])
    nh, ph := __dec_expand(2 * m + 1, e - 1, dh[..])
    nl := 0
    pl := 0
    if closer {
        nl, pl = __dec_expand(4 * m - 1, e - 2, dl[..])
    } else {
        nl, pl = __dec_expand(2 * m - 1, e - 1, dl[..])
    }
    even := (m & 1) == 0
    c: [24]u8
    cn := 0
    cp := 0
    found := false
    for p in 1..19 {
        if p >= n {
            copy(c[..], d[..n])
            cn = n
            cp = pos
            break
        }
        // the p-digit numbers below and above x: the nearer one first; the other one counts
        // too, since below a power of two the interval is closer on one side
        nearer_up := d[p] > '5' || (d[p] == '5' && (n > p + 1 || ((d[p - 1] - '0') & 1) == 1))
        for t in 0..2 {
            up := if t == 0 { nearer_up } else { !nearer_up }
            copy(c[..], d[..p])
            cn = p
            cp = pos
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
                found = true
                break
            }
        }
        if found {
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
            o += copy(out[o..], c[cp..cn])
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
        fill(out[o..o - cp], '0')
        o -= cp
        o += copy(out[o..], c[..cn])
        return o
    }
    out[o] = c[0]
    o += 1
    if cn > 1 {
        out[o] = '.'
        o += 1
        o += copy(out[o..], c[1..cn])
    }
    out[o] = 'e'
    o += 1
    ex := cp - 1
    if ex < 0 {
        out[o] = '-'
        o += 1
        ex = -ex
    }
    t: [8]u8
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

fn __put_f32(x: f32) {
    b: [40]u8
    n := __fmt_shortest32(x, b[..])
    __put_str(b[..n])
}

// ---------- matrix / quaternion operators ----------
fn __mat4_mulv(m: mat4, v: vec4) -> vec4 {
    return m[0] * v.x + m[1] * v.y + m[2] * v.z + m[3] * v.w
}

fn __mat4_mul(a: mat4, b: mat4) -> mat4 {
    return mat4(__mat4_mulv(a, b[0]), __mat4_mulv(a, b[1]), __mat4_mulv(a, b[2]), __mat4_mulv(a, b[3]))
}

fn __mat4_diag(s: f32) -> mat4 {
    return mat4(vec4(s, 0.0, 0.0, 0.0), vec4(0.0, s, 0.0, 0.0), vec4(0.0, 0.0, s, 0.0), vec4(0.0, 0.0, 0.0, s))
}

// Hamilton product; components are (x, y, z, w) with w the scalar part
fn __quat_mul(a: quat, b: quat) -> quat {
    return quat(
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
}

// rotate v by the unit quaternion q: v + 2w(u x v) + 2 u x (u x v)
fn __quat_rotate(q: quat, v: vec3) -> vec3 {
    u := q.xyz
    t := (u.yzx * v.zxy - u.zxy * v.yzx) * 2.0
    return v + t * q.w + (u.yzx * t.zxy - u.zxy * t.yzx)
}

fn __put_f64(x: f64) {
    b: [40]u8
    n := __fmt_shortest(x, b[..])
    __put_str(b[..n])
}

// the zeros beyond the 1100 digits that __fmt_fixed writes (x finite)
fn __fmt_extra(x: f64, prec: i64) -> i64 {
    return if prec > 1100 && x - x == 0.0 { prec - 1100 } else { 0 }
}

// print x with exactly `prec` digits after the decimal point (like printf "%.Nf")
fn putf(x: f64, prec: i64) {
    __at_putf(x, prec, "?")
}

fn __at_putf(x: f64, prec: i64, at: str) {
    __check_digits(prec, at)
    b: [1420]u8
    n := __fmt_fixed(x, prec, b[..])
    __put_str(b[..n])
    for i in 0..__fmt_extra(x, prec) {
        putc('0')
    }
}

fn __check_digits(prec: i64, at: str) {
    if prec < 0 {
        __assert_fail(at, "fmtf: negative number of digits")
    }
}

fn fmtf(x: f64, prec: i64) -> str {
    return __at_fmtf(x, prec, "?")
}

fn __at_fmtf(x: f64, prec: i64, at: str) -> str {
    __check_digits(prec, at)
    b: [1420]u8
    n := __fmt_fixed(x, prec, b[..])
    s := alloc[u8](n + __fmt_extra(x, prec))
    copy(s, b[..n])
    fill(s[n..], '0')
    return s
}

// fmtf(x, prec) right-aligned in `width` characters (like printf "%W.Nf")
fn fmtf(x: f64, prec: i64, width: i64) -> str {
    return __at_fmtf(x, prec, width, "?")
}

fn __at_fmtf(x: f64, prec: i64, width: i64, at: str) -> str {
    return pad_left(__at_fmtf(x, prec, at), width, ' ')
}

// the f32 versions: an f32 converts to f64 exactly, so the digits are those of the exact value
fn putf(x: f32, prec: i64) {
    __at_putf(f64(x), prec, "?")
}

fn __at_putf(x: f32, prec: i64, at: str) {
    __at_putf(f64(x), prec, at)
}

fn fmtf(x: f32, prec: i64) -> str {
    return __at_fmtf(f64(x), prec, "?")
}

fn __at_fmtf(x: f32, prec: i64, at: str) -> str {
    return __at_fmtf(f64(x), prec, at)
}

fn fmtf(x: f32, prec: i64, width: i64) -> str {
    return __at_fmtf(f64(x), prec, width, "?")
}

fn __at_fmtf(x: f32, prec: i64, width: i64, at: str) -> str {
    return __at_fmtf(f64(x), prec, width, at)
}

fn __put_slice[T](s: []T) {
    putc('[')
    for i, x in s {
        if i > 0 {
            __put_str(", ")
        }
        put(x)
    }
    putc(']')
}

fn __str_eq(a: str, b: str) -> bool {
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
fn __run_test(name: str, f: fn()) {
    flush()
    r := __os_test(f)
    if r < 0 {
        // (a process that runs one test of the program, on Windows: not this one)
        return
    }
    if r == 1 {
        put("ok   ", name, "\n")
    } else {
        put("FAIL ", name, "\n")
        __tests_failed += 1
    }
    flush()
}

fn __tests_done() -> i64 {
    if __tests_failed > 0 {
        put(__tests_failed, " test(s) failed\n")
        return 1
    }
    return 0
}

// ---------- capture output into a string: fmt(...) ----------
// The capture buffer lives outside the arena (release() must not take it away): a static block
// first, then mappings of its own.
__cap_on: i64
__cap_static: [1024]u8
__cap_buf: []u8
__cap_len: i64

// captures nest: each fmt() takes the text appended after its starting position
fn __cap_begin() -> i64 {
    if len(__cap_buf) == 0 {
        __cap_buf = __cap_static[..]
    }
    __cap_on += 1
    return __cap_len
}

fn __cap_put(s: str) {
    n := len(s)
    if __cap_len + n > len(__cap_buf) {
        if n > (1 << 46) - __cap_len {
            __die("panic: out of memory", "", "")
        }
        cap := len(__cap_buf) * 2
        while cap < __cap_len + n {
            cap = cap * 2
        }
        p := __os_map(cap)
        if p < 0 && p > -4096 {
            __die("panic: out of memory", "", "")
        }
        memcopy(p, ptr(__cap_buf), __cap_len)
        if len(__cap_buf) > 1024 {
            __os_unmap(cast[i64](ptr(__cap_buf)), len(__cap_buf))
        }
        __cap_buf = mkslice[u8](p, cap)
    }
    memcopy(cast[i64](ptr(__cap_buf)) + __cap_len, ptr(s), n)
    __cap_len += n
}

fn __cap_end(start: i64) -> str {
    n := __cap_len - start
    out := alloc[u8](n)
    memcopy(ptr(out), cast[i64](ptr(__cap_buf)) + start, n)
    __cap_len = start
    __cap_on -= 1
    return out
}

// ---------- hashing and equality helpers ----------
fn __hash_u64(x: u64) -> u64 {
    x = (x ^ (x >> 33)) * 0xff51afd7ed558ccd
    x = (x ^ (x >> 33)) * 0xc4ceb9fe1a85ec53
    return x ^ (x >> 33)
}

fn __hash_str(s: str) -> u64 {
    h: u64 = 0xcbf29ce484222325
    for c in s {
        h = (h ^ u64(c)) * 0x100000001b3
    }
    return __hash_u64(h)
}

fn __hash_mix(a: u64, b: u64) -> u64 {
    return __hash_u64(a ^ (b + 0x9e3779b97f4a7c15 + (a << 6) + (a >> 2)))
}

fn __hash_slice[T](s: []T) -> u64 {
    h: u64 = u64(len(s))
    for x in s {
        h = __hash_mix(h, hash(x))
    }
    return h
}

fn __slice_eq[T](a: []T, b: []T) -> bool {
    if len(a) != len(b) {
        return false
    }
    for i in 0..len(a) {
        if a[i] != b[i] {
            return false
        }
    }
    return true
}

// ---------- small generic helpers ----------
// a NaN argument makes the result NaN, whatever its position (`b != b`: only a NaN)
fn min[T](a: T, b: T) -> T {
    if b < a || b != b { b } else { a }
}

fn max[T](a: T, b: T) -> T {
    if b > a || b != b { b } else { a }
}

// strings are ordered bytewise, like `cmp`
fn min(a: str, b: str) -> str {
    if cmp(b, a) < 0 { b } else { a }
}

fn max(a: str, b: str) -> str {
    if cmp(b, a) > 0 { b } else { a }
}

fn abs[T](x: T) -> T {
    // `0 - x`, not `-x`: the absolute value of -0.0 is 0.0
    if x <= 0 { 0 - x } else { x }
}

inline fn swap[T](a: *T, b: *T) {
    t := *a
    *a = *b
    *b = t
}

inline fn copy[T](dst: []T, src: []T) -> i64 {
    n := min(len(dst), len(src))
    d := cast[i64](ptr(dst))
    s := cast[i64](ptr(src))
    if d > s && d < s + n * sizeof[T]() {
        // overlapping, the destination after the source (copy(a[1..], a)): from the end
        k := n - 1
        while k >= 0 {
            dst[k] = src[k]
            k -= 1
        }
        return n
    }
    memcopy(ptr(dst), ptr(src), n * sizeof[T]())
    return n
}

inline fn fill[T](a: []T, x: T) {
    for i in 0..len(a) {
        a[i] = x
    }
}

fn floor(x: f64) -> f64 {
    // (x == 0: keeps the sign of -0.0, as C's floor)
    if x != x || x == 0.0 || fabs(x) >= 4503599627370496.0 {
        return x
    }
    t := f64(i64(x))
    if t > x { t - 1.0 } else { t }
}

fn ceil(x: f64) -> f64 {
    if x != x || x == 0.0 || fabs(x) >= 4503599627370496.0 {
        return x
    }
    if x < 0.0 && x > -1.0 {
        return -0.0
    }
    t := f64(i64(x))
    if t < x { t + 1.0 } else { t }
}

// ---------- growable vector ----------
struct Vec[T] { buf: []T, len: i64 }

fn vec[T]() -> Vec[T] {
    return Vec[T]{buf: mkslice[T](__heap_cur, 0), len: 0}
}

// a Vec holding a copy of the elements of s
fn vec_of[T](s: []T) -> Vec[T] {
    n := len(s)
    buf := mkslice[T](__alloc_raw(__alloc_size(n, sizeof[T]())), n)
    memcopy(ptr(buf), ptr(s), n * sizeof[T]())
    return Vec[T]{buf: buf, len: n}
}

// a Vec of n copies of x
fn vec_fill[T](n: i64, x: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(__alloc_size(n, sizeof[T]())), n)
    fill(buf, x)
    return Vec[T]{buf: buf, len: n}
}

fn reserve[T](v: *Vec[T], n: i64) {
    if n > len(v.buf) {
        cap := max(len(v.buf) * 2, max(n, 8))
        // the spare capacity is never read before it is written: no need to zero it
        nb := mkslice[T](__alloc_raw(__alloc_size(cap, sizeof[T]())), cap)
        memcopy(ptr(nb), ptr(v.buf), v.len * sizeof[T]())
        v.buf = nb
    }
}

fn push[T](v: *Vec[T], x: T) {
    if v.len == len(v.buf) {
        reserve(v, v.len + 1)
    }
    v.buf[v.len] = x
    v.len += 1
}

// A function `f` with a twin `__at_f`: the compiler turns every call `f(args)` into
// `__at_f(args, "file:line" of the call)`, so that a failure names the caller's line. The
// plain function is what `f` denotes as a function value.
fn pop[T](v: *Vec[T]) -> T {
    return __at_pop(v, "?")
}

fn __at_pop[T](v: *Vec[T], at: str) -> T {
    if v.len == 0 {
        __die("panic: pop from an empty Vec at ", at, "")
    }
    v.len -= 1
    return v.buf[v.len]
}

// the live elements of a Vec as a slice (valid until the next push that grows it)
fn items[T](v: *Vec[T]) -> []T {
    return v.buf[..v.len]
}

fn last[T](v: *Vec[T]) -> T {
    return __at_last(v, "?")
}

fn __at_last[T](v: *Vec[T], at: str) -> T {
    if v.len <= 0 {
        __assert_fail(at, "last of an empty Vec")
    }
    return v.buf[v.len - 1]
}

fn is_empty[T](v: *Vec[T]) -> bool {
    return v.len == 0
}

fn clear[T](v: *Vec[T]) {
    v.len = 0
}

fn truncate[T](v: *Vec[T], n: i64) {
    __at_truncate(v, n, "?")
}

fn __at_truncate[T](v: *Vec[T], n: i64, at: str) {
    if n < 0 {
        __assert_fail(at, "Vec truncate to a negative length")
    }
    if n < v.len {
        v.len = n
    }
}

// grows (with copies of x) or shrinks to exactly n elements
fn resize[T](v: *Vec[T], n: i64, x: T) {
    __at_resize(v, n, x, "?")
}

fn __at_resize[T](v: *Vec[T], n: i64, x: T, at: str) {
    if n < 0 {
        __assert_fail(at, "Vec resize to a negative length")
    }
    reserve(v, n)
    for i in v.len..n {
        v.buf[i] = x
    }
    v.len = n
}

fn extend[T](v: *Vec[T], s: []T) {
    reserve(v, v.len + len(s))
    memcopy(cast[i64](ptr(v.buf)) + v.len * sizeof[T](), ptr(s), len(s) * sizeof[T]())
    v.len += len(s)
}

// inserts x before position i
fn insert[T](v: *Vec[T], i: i64, x: T) {
    __at_insert(v, i, x, "?")
}

fn __at_insert[T](v: *Vec[T], i: i64, x: T, at: str) {
    if i < 0 || i > v.len {
        __assert_fail(at, "Vec insert position out of range")
    }
    push(v, x)
    copy(v.buf[i + 1..v.len], v.buf[i..v.len - 1])
    v.buf[i] = x
}

// removes and returns element i, keeping the order of the rest
fn remove[T](v: *Vec[T], i: i64) -> T {
    return __at_remove(v, i, "?")
}

fn __at_remove[T](v: *Vec[T], i: i64, at: str) -> T {
    if i < 0 || i >= v.len {
        __assert_fail(at, "Vec remove position out of range")
    }
    x := v.buf[i]
    copy(v.buf[i..v.len - 1], v.buf[i + 1..v.len])
    v.len -= 1
    return x
}

// removes and returns element i, moving the last element into its place
fn swap_remove[T](v: *Vec[T], i: i64) -> T {
    return __at_swap_remove(v, i, "?")
}

fn __at_swap_remove[T](v: *Vec[T], i: i64, at: str) -> T {
    if i < 0 || i >= v.len {
        __assert_fail(at, "Vec swap_remove position out of range")
    }
    x := v.buf[i]
    v.len -= 1
    v.buf[i] = v.buf[v.len]
    return x
}

// position of the first element equal to x, or -1
fn index_of[T](s: []T, x: T) -> i64 {
    for i, y in s {
        if y == x {
            return i
        }
    }
    return -1
}

fn contains[T](s: []T, x: T) -> bool {
    return index_of(s, x) >= 0
}

fn contains[T](v: *Vec[T], x: T) -> bool {
    return index_of(v.buf[..v.len], x) >= 0
}

fn reverse[T](s: []T) {
    i := 0
    j := len(s) - 1
    while i < j {
        swap(&s[i], &s[j])
        i += 1
        j -= 1
    }
}

// removes adjacent duplicates (use after sort)
fn dedup[T](v: *Vec[T]) {
    if v.len == 0 {
        return
    }
    n := 1
    for i in 1..v.len {
        if v.buf[i] != v.buf[n - 1] {
            v.buf[n] = v.buf[i]
            n += 1
        }
    }
    v.len = n
}

// keeps the elements x with keep(x), in their order: one pass in place, keep is called once
// per element, first to last (the slots past the new length keep their old contents, as
// with truncate)
fn retain[T](v: *Vec[T], keep: fn(T) -> bool) {
    n := 0
    for x in v.buf[..v.len] {
        if keep(x) {
            v.buf[n] = x
            n += 1
        }
    }
    v.len = n
}

// the same with a context value that is handed to every call of keep
fn retain[T, C](v: *Vec[T], ctx: C, keep: fn(C, T) -> bool) {
    n := 0
    for x in v.buf[..v.len] {
        if keep(ctx, x) {
            v.buf[n] = x
            n += 1
        }
    }
    v.len = n
}

// ---------- hash map that keeps the insertion order ----------
// The entries live in three parallel arrays in the order of their first insertion: keys[e],
// vals[e], tags[e] for e < used (the slices are as long as the capacity; what lies beyond
// `used` is uninitialised). tags[e] is the upper half of the key's hash with the top bit set;
// 0 marks a deleted entry (a hole; `len` counts the live ones). `index` is the open-addressing
// table (linear probing, a power of two long) that finds an entry: the home slot of a key is
// tag & mask; a slot is 0 (free), or e + 1 in the bits of the mask and the tag in the others,
// or mask (its entry was deleted: equal to no tag in the upper bits). The entry arrays hold
// half of len(index) entries, so at least half of the slots are free. When they are full, the
// map is compacted in place if a quarter or more are holes, and grows otherwise.
struct Map[K, V] { keys: []K, vals: []V, tags: []u32, index: []u32, len: i64, used: i64 }

fn map[K, V]() -> Map[K, V] {
    return Map[K, V]{}
}

// the entry number of k, or -1
fn __map_find[K, V](m: *Map[K, V], k: K) -> i64 {
    n := len(m.index)
    if n == 0 {
        return -1
    }
    mask := u32(n - 1)
    tag := u32(hash(k) >> 32) | 0x8000_0000
    i := tag & mask
    loop {
        s := m.index[i]
        if s == 0 {
            return -1
        }
        if (s ^ tag) <= mask {
            e := i64(s & mask) - 1
            if m.keys[e] == k {
                return e
            }
        }
        i = (i + 1) & mask
    }
}

// enters entry e into a table that does not have it
fn __map_place(index: []u32, tag: u32, e: i64) {
    mask := u32(len(index) - 1)
    i := tag & mask
    while index[i] != 0 {
        i = (i + 1) & mask
    }
    index[i] = (tag & ~mask) | u32(e + 1)
}

// the live entries of s, moved to the front of dst (dst may be s)
fn __map_pack[T](dst: []T, s: []T, tags: []u32, used: i64) {
    n := 0
    for e in 0..used {
        if tags[e] != 0 {
            dst[n] = s[e]
            n += 1
        }
    }
}

// makes room for one more entry: removes the holes, in larger arrays unless the holes are a
// quarter of the entries (4 times the size while small: fewer steps for the many maps that
// stay small; twice later: less memory)
fn __map_grow[K, V](m: *Map[K, V]) {
    cap := len(m.index)
    keys := m.keys
    vals := m.vals
    tags := m.tags
    if cap == 0 || m.len * 4 > m.used * 3 {
        cap = if cap < 65536 { max(16, cap * 4) } else { cap * 2 }
        if cap > 0x8000_0000 {
            __die("panic: Map too large", "", "")
        }
        n := cap / 2
        // (the spare capacity is never read before it is written)
        keys = mkslice[K](__alloc_raw(__alloc_size(n, sizeof[K]())), n)
        vals = mkslice[V](__alloc_raw(__alloc_size(n, sizeof[V]())), n)
        tags = mkslice[u32](__alloc_raw(n * 4), n)
        m.index = alloc[u32](cap)
    } else {
        memfill(ptr(m.index), 0, cap * 4)
    }
    if m.len == m.used {
        if ptr(keys) != ptr(m.keys) {
            memcopy(ptr(keys), ptr(m.keys), m.used * sizeof[K]())
            memcopy(ptr(vals), ptr(m.vals), m.used * sizeof[V]())
            memcopy(ptr(tags), ptr(m.tags), m.used * 4)
        }
    } else {
        __map_pack(keys, m.keys, m.tags, m.used)
        __map_pack(vals, m.vals, m.tags, m.used)
        __map_pack(tags, m.tags, m.tags, m.used)
    }
    m.keys = keys
    m.vals = vals
    m.tags = tags
    m.used = m.len
    for e in 0..m.used {
        __map_place(m.index, tags[e], e)
    }
}

fn set[K, V](m: *Map[K, V], k: K, v: V) {
    tag := u32(hash(k) >> 32) | 0x8000_0000
    slot := -1              // where a new entry goes: the first reusable slot on the way
    if len(m.index) != 0 {
        mask := u32(len(m.index) - 1)
        i := tag & mask
        loop {
            s := m.index[i]
            if s == 0 {
                if slot < 0 {
                    slot = i64(i)
                }
                break
            }
            if (s ^ tag) <= mask {
                e := i64(s & mask) - 1
                if m.keys[e] == k {
                    m.vals[e] = v
                    return
                }
            } else if s == mask && slot < 0 {
                slot = i64(i)
            }
            i = (i + 1) & mask
        }
    }
    e := m.used
    if e == len(m.keys) {
        __map_grow(m)
        e = m.used
        slot = -1
    }
    m.keys[e] = k
    m.vals[e] = v
    m.tags[e] = tag
    m.used = e + 1
    m.len += 1
    if slot < 0 {
        __map_place(m.index, tag, e)
    } else {
        m.index[slot] = (tag & ~u32(len(m.index) - 1)) | u32(e + 1)
    }
}

fn get[K, V](m: *Map[K, V], k: K) -> (V, bool) {
    e := __map_find(m, k)
    if e < 0 {
        zero: V
        return (zero, false)
    }
    return (m.vals[e], true)
}

// the value stored for k, or `default` when k is missing
fn get_or[K, V](m: *Map[K, V], k: K, default: V) -> V {
    e := __map_find(m, k)
    if e < 0 {
        return default
    }
    return m.vals[e]
}

fn has[K, V](m: *Map[K, V], k: K) -> bool {
    return __map_find(m, k) >= 0
}

// removes k (false if it was missing): its entry becomes a hole, its slot stays taken
fn del[K, V](m: *Map[K, V], k: K) -> bool {
    n := len(m.index)
    if n == 0 {
        return false
    }
    mask := u32(n - 1)
    tag := u32(hash(k) >> 32) | 0x8000_0000
    i := tag & mask
    loop {
        s := m.index[i]
        if s == 0 {
            return false
        }
        if (s ^ tag) <= mask {
            e := i64(s & mask) - 1
            if m.keys[e] == k {
                m.index[i] = mask
                m.tags[e] = 0
                m.len -= 1
                return true
            }
        }
        i = (i + 1) & mask
    }
}

// removes every entry
fn clear[K, V](m: *Map[K, V]) {
    *m = Map[K, V]{}
}

// a pointer to the value stored for k (nil if k is missing), to change it in place; valid
// until the next `set` of a new key
fn ptr[K, V](m: *Map[K, V], k: K) -> *V {
    e := __map_find(m, k)
    if e < 0 {
        return nil
    }
    return &m.vals[e]
}

// a new slice of the live entries of s
fn __map_live[K, V, T](m: *Map[K, V], s: []T) -> []T {
    out := mkslice[T](__alloc_raw(__alloc_size(m.len, sizeof[T]())), m.len)
    if m.len == m.used {
        memcopy(ptr(out), ptr(s), m.len * sizeof[T]())
    } else {
        __map_pack(out, s, m.tags, m.used)
    }
    return out
}

// all keys, in the order in which they were first inserted (a new slice)
fn keys[K, V](m: *Map[K, V]) -> []K {
    return __map_live(m, m.keys)
}

// all values, in the order of keys()
fn values[K, V](m: *Map[K, V]) -> []V {
    return __map_live(m, m.vals)
}

// print(m): {key: value, key: value} in insertion order
fn __put_map[K, V](m: *Map[K, V]) {
    putc('{')
    n := 0
    for e in 0..m.used {
        if m.tags[e] != 0 {
            if n > 0 {
                __put_str(", ")
            }
            put(m.keys[e])
            __put_str(": ")
            put(m.vals[e])
            n += 1
        }
    }
    putc('}')
}

// ---------- clone ----------
// The builtin `clone(x)` copies x member by member and calls these for the parts that own
// storage. All copies are allocated from the arena in use.

// a slice of elements that own nothing: one allocation, one memory copy
fn __clone_plain[T](s: []T) -> []T {
    n := len(s)
    out := mkslice[T](__alloc_raw(__alloc_size(n, sizeof[T]())), n)
    memcopy(ptr(out), ptr(s), n * sizeof[T]())
    return out
}

fn __clone_slice[T](s: []T) -> []T {
    n := len(s)
    out := mkslice[T](__alloc_raw(__alloc_size(n, sizeof[T]())), n)
    for i in 0..n {
        out[i] = clone(s[i])
    }
    return out
}

// the elements of an array, cloned into another array of the same length
fn __clone_elems[T](dst: []T, src: []T) {
    for i in 0..len(src) {
        dst[i] = clone(src[i])
    }
}

// a Vec with the same live elements; the spare capacity (uninitialised memory) is not copied
fn __clone_vec_plain[T](v: Vec[T]) -> Vec[T] {
    return Vec[T]{buf: __clone_plain(v[..]), len: v.len}
}

fn __clone_vec[T](v: Vec[T]) -> Vec[T] {
    return Vec[T]{buf: __clone_slice(v[..]), len: v.len}
}

// the keys or values of a Map with the same capacity: only live entries hold a value
// (`plain`: T owns no storage)
fn __clone_slots[T](s: []T, tags: []u32, used: i64, plain: bool) -> []T {
    out := mkslice[T](__alloc_raw(__alloc_size(len(s), sizeof[T]())), len(s))
    if plain {
        memcopy(ptr(out), ptr(s), used * sizeof[T]())
    } else {
        for e in 0..used {
            if tags[e] != 0 {
                out[e] = clone(s[e])
            }
        }
    }
    return out
}

fn __clone_map[K, V](m: *Map[K, V], kplain: bool, vplain: bool) -> Map[K, V] {
    return Map[K, V]{
        keys: __clone_slots(m.keys, m.tags, m.used, kplain),
        vals: __clone_slots(m.vals, m.tags, m.used, vplain),
        tags: __clone_slots(m.tags, m.tags, m.used, true),
        index: __clone_plain(m.index),
        len: m.len,
        used: m.used,
    }
}

// ---------- sorting ----------
// quicksort; after `depth` levels of bad pivots the rest of the range is heap-sorted, so that
// no input takes more than n log n steps
fn __sort_range[T](a: []T, lo: i64, hi: i64, depth: i64) {
    while hi - lo > 16 {
        if depth == 0 {
            __heap_sort(a, lo, hi)
            return
        }
        depth -= 1
        p := a[lo + (hi - lo) / 2]
        i := lo
        j := hi
        while i <= j {
            while a[i] < p {
                i += 1
            }
            while p < a[j] {
                j -= 1
            }
            if i <= j {
                swap(&a[i], &a[j])
                i += 1
                j -= 1
            }
        }
        // recurse into the smaller half, loop on the larger one
        if j - lo < hi - i {
            __sort_range(a, lo, j, depth)
            lo = i
        } else {
            __sort_range(a, i, hi, depth)
            hi = j
        }
    }
    for i in lo + 1..=hi {
        x := a[i]
        j := i - 1
        while j >= lo && x < a[j] {
            a[j + 1] = a[j]
            j -= 1
        }
        a[j + 1] = x
    }
}

// a[lo..=hi] sorted with a heap
fn __heap_sort[T](a: []T, lo: i64, hi: i64) {
    n := hi - lo + 1
    for r in 0..n / 2 {
        __sift_down(a, lo, n / 2 - 1 - r, n)
    }
    end := n - 1
    while end > 0 {
        swap(&a[lo], &a[lo + end])
        __sift_down(a, lo, 0, end)
        end -= 1
    }
}

fn __sift_down[T](a: []T, lo: i64, root: i64, n: i64) {
    loop {
        c := 2 * root + 1
        if c >= n {
            return
        }
        if c + 1 < n && a[lo + c] < a[lo + c + 1] {
            c += 1
        }
        if !(a[lo + root] < a[lo + c]) {
            return
        }
        swap(&a[lo + root], &a[lo + c])
        root = c
    }
}

// ascending sort of numbers (anything comparable with `<`)
fn sort[T](a: []T) {
    depth := 0
    k := len(a)
    while k > 0 {
        depth += 2
        k = k >> 1
    }
    __sort_range(a, 0, len(a) - 1, depth)
}

fn sort(a: []str) {
    sort_by(a, fn(x: str, y: str) -> bool { cmp(x, y) < 0 })
}

// stable merge sort with a user-supplied "less than"
fn sort_by[T](a: []T, less: fn(T, T) -> bool) {
    n := len(a)
    if n < 2 {
        return
    }
    tmp := alloc[T](n)
    src := a
    dst := tmp
    width := 1
    while width < n {
        lo := 0
        while lo < n {
            mid := min(lo + width, n)
            hi := min(lo + 2 * width, n)
            i := lo
            j := mid
            k := lo
            while i < mid && j < hi {
                if less(src[j], src[i]) {
                    dst[k] = src[j]
                    j += 1
                } else {
                    dst[k] = src[i]
                    i += 1
                }
                k += 1
            }
            while i < mid {
                dst[k] = src[i]
                i += 1
                k += 1
            }
            while j < hi {
                dst[k] = src[j]
                j += 1
                k += 1
            }
            lo = hi
        }
        t := src
        src = dst
        dst = t
        width = width * 2
    }
    if ptr(src) != ptr(a) {
        copy(a, src)
    }
}

// the same with a context value that is handed to every comparison (the state a
// comparison needs, since a function value cannot refer to local variables)
fn sort_by[T, C](a: []T, ctx: C, less: fn(C, T, T) -> bool) {
    n := len(a)
    if n < 2 {
        return
    }
    tmp := alloc[T](n)
    src := a
    dst := tmp
    width := 1
    while width < n {
        lo := 0
        while lo < n {
            mid := min(lo + width, n)
            hi := min(lo + 2 * width, n)
            i := lo
            j := mid
            k := lo
            while i < mid && j < hi {
                if less(ctx, src[j], src[i]) {
                    dst[k] = src[j]
                    j += 1
                } else {
                    dst[k] = src[i]
                    i += 1
                }
                k += 1
            }
            while i < mid {
                dst[k] = src[i]
                i += 1
                k += 1
            }
            while j < hi {
                dst[k] = src[j]
                j += 1
                k += 1
            }
            lo = hi
        }
        t := src
        src = dst
        dst = t
        width = width * 2
    }
    if ptr(src) != ptr(a) {
        copy(a, src)
    }
}

// ---------- strings ----------
fn concat(a: str, b: str) -> str {
    out := alloc[u8](__add_size(len(a), len(b)))
    memcopy(ptr(out), ptr(a), len(a))
    memcopy(cast[i64](ptr(out)) + len(a), ptr(b), len(b))
    return out
}

// index of the first occurrence of sub in s, or -1
// (a plain scan; when it may have compared too many bytes in vain, as with "aaa...ab" in
// "aaaa...", the rest of s is searched in linear time: __kmp_find)
fn find(s: str, sub: str) -> i64 {
    n := len(s)
    m := len(sub)
    if m == 0 {
        return 0
    }
    c := sub[0]
    work := 0
    i := 0
    while i + m <= n {
        if s[i] == c {
            if s[i..i + m] == sub {
                return i
            }
            // (at most m bytes compared)
            work += m
            if work > 8 * i + 1024 {
                return __kmp_find(s, sub, i, false)
            }
        }
        i += 1
    }
    return -1
}

// Knuth-Morris-Pratt: the first occurrence of sub in s at `from` or later, or -1; with `rev`
// both strings are read backwards (s[len(s) - 1 - i]): the result is then the start of the
// last occurrence that ends at len(s) - from or earlier, counted from the front
fn __kmp_find(s: str, sub: str, from: i64, rev: bool) -> i64 {
    n := len(s)
    m := len(sub)
    mk := mark()
    // border[k]: length of the longest proper border of the first k + 1 bytes of sub
    border := alloc[i64](m)
    j := 0
    for k in 1..m {
        ck := if rev { sub[m - 1 - k] } else { sub[k] }
        while j > 0 && ck != (if rev { sub[m - 1 - j] } else { sub[j] }) {
            j = border[j - 1]
        }
        if ck == (if rev { sub[m - 1 - j] } else { sub[j] }) {
            j += 1
        }
        border[k] = j
    }
    r := -1
    j = 0
    for i in from..n {
        ci := if rev { s[n - 1 - i] } else { s[i] }
        while j > 0 && ci != (if rev { sub[m - 1 - j] } else { sub[j] }) {
            j = border[j - 1]
        }
        if ci == (if rev { sub[m - 1 - j] } else { sub[j] }) {
            j += 1
        }
        if j == m {
            r = if rev { n - 1 - i } else { i - m + 1 }
            break
        }
    }
    // the table was the last allocation: give it back
    release(mk)
    return r
}

// the first occurrence that starts at `from` or later; `from` is checked like s[from..]
fn find(s: str, sub: str, from: i64) -> i64 {
    return __at_find(s, sub, from, "?")
}

fn __at_find(s: str, sub: str, from: i64, at: str) -> i64 {
    if from < 0 || from > len(s) {
        __bounds_fail(at)
    }
    i := find(s[from..], sub)
    if i < 0 {
        return -1
    }
    return from + i
}

// index of the first byte at `from` or later that is one of `chars`, or -1
fn find_any(s: str, chars: str, from: i64) -> i64 {
    return __at_find_any(s, chars, from, "?")
}

fn __at_find_any(s: str, chars: str, from: i64, at: str) -> i64 {
    if from < 0 || from > len(s) {
        __bounds_fail(at)
    }
    for i in from..len(s) {
        if contains(chars, s[i]) {
            return i
        }
    }
    return -1
}

// index of the last occurrence of sub in s, or -1
fn rfind(s: str, sub: str) -> i64 {
    n := len(s)
    m := len(sub)
    if m == 0 {
        return n
    }
    c := sub[m - 1]
    work := 0
    i := n - m
    while i >= 0 {
        if s[i + m - 1] == c {
            if s[i..i + m] == sub {
                return i
            }
            work += m
            if work > 8 * (n - m - i) + 1024 {
                return __kmp_find(s, sub, n - m - i, true)
            }
        }
        i -= 1
    }
    return -1
}

// how often sub occurs in s (occurrences that do not overlap, counted from the left)
fn count(s: str, sub: str) -> i64 {
    return __at_count(s, sub, "?")
}

fn __at_count(s: str, sub: str, at: str) -> i64 {
    if len(sub) == 0 {
        __panic(at, "count: empty substring")
    }
    n := 0
    i := find(s, sub)
    while i >= 0 {
        n += 1
        i = __at_find(s, sub, i + len(sub), at)
    }
    return n
}

// s with every occurrence of old (left to right, not overlapping) replaced by new
fn replace(s: str, old: str, new: str) -> str {
    return __at_replace(s, old, new, "?")
}

fn __at_replace(s: str, old: str, new: str, at: str) -> str {
    if len(old) == 0 {
        __panic(at, "replace: empty substring")
    }
    cnt := __at_count(s, old, at)
    out := alloc[u8](if len(new) >= len(old) { __add_size(len(s), __alloc_size(cnt, len(new) - len(old))) } else { len(s) - cnt * (len(old) - len(new)) })
    k := 0
    start := 0
    loop {
        i := __at_find(s, old, start, at)
        end := if i < 0 { len(s) } else { i }
        memcopy(cast[i64](ptr(out)) + k, cast[i64](ptr(s)) + start, end - start)
        k += end - start
        if i < 0 {
            return out
        }
        memcopy(cast[i64](ptr(out)) + k, ptr(new), len(new))
        k += len(new)
        start = i + len(old)
    }
}

// n copies of s (none if n <= 0)
fn repeat(s: str, n: i64) -> str {
    if n <= 0 || len(s) == 0 {
        return ""
    }
    out := alloc[u8](__alloc_size(n, len(s)))
    for i in 0..n {
        memcopy(cast[i64](ptr(out)) + i * len(s), ptr(s), len(s))
    }
    return out
}

fn starts_with(s: str, p: str) -> bool {
    return len(s) >= len(p) && s[..len(p)] == p
}

fn ends_with(s: str, p: str) -> bool {
    return len(s) >= len(p) && s[len(s) - len(p)..] == p
}

// white space: ' ', '\t', '\n', '\r', vertical tab, form feed
fn is_space(c: u8) -> bool {
    return c == ' ' || (c >= '\t' && c <= '\r')
}

// views of s without white space at both ends / at the start / at the end
fn trim(s: str) -> str {
    return trim_right(trim_left(s))
}

fn trim_left(s: str) -> str {
    lo := 0
    while lo < len(s) && is_space(s[lo]) {
        lo += 1
    }
    return s[lo..]
}

fn trim_right(s: str) -> str {
    hi := len(s)
    while hi > 0 && is_space(s[hi - 1]) {
        hi -= 1
    }
    return s[..hi]
}

// the same for the bytes of `chars` instead of white space
fn trim(s: str, chars: str) -> str {
    return trim_right(trim_left(s, chars), chars)
}

fn trim_left(s: str, chars: str) -> str {
    lo := 0
    while lo < len(s) && contains(chars, s[lo]) {
        lo += 1
    }
    return s[lo..]
}

fn trim_right(s: str, chars: str) -> str {
    hi := len(s)
    while hi > 0 && contains(chars, s[hi - 1]) {
        hi -= 1
    }
    return s[..hi]
}

// pieces of s between occurrences of sep (views into s, no copying)
fn split(s: str, sep: u8) -> []str {
    n := 1
    for c in s {
        if c == sep {
            n += 1
        }
    }
    out := alloc[str](n)
    k := 0
    start := 0
    for i in 0..len(s) {
        if s[i] == sep {
            out[k] = s[start..i]
            k += 1
            start = i + 1
        }
    }
    out[k] = s[start..]
    return out
}

// pieces of s between occurrences of sep (left to right, not overlapping)
fn split(s: str, sep: str) -> []str {
    return __at_split(s, sep, "?")
}

fn __at_split(s: str, sep: str, at: str) -> []str {
    if len(sep) == 0 {
        __panic(at, "split: empty separator")
    }
    out := alloc[str](__at_count(s, sep, at) + 1)
    k := 0
    start := 0
    loop {
        i := __at_find(s, sep, start, at)
        if i < 0 {
            out[k] = s[start..]
            return out
        }
        out[k] = s[start..i]
        k += 1
        start = i + len(sep)
    }
}

// the pieces of s between runs of white space (views; none is empty)
fn fields(s: str) -> []str {
    n := 0
    for i, c in s {
        if !is_space(c) && (i == 0 || is_space(s[i - 1])) {
            n += 1
        }
    }
    out := alloc[str](n)
    k := 0
    i := 0
    while k < n {
        while is_space(s[i]) {
            i += 1
        }
        start := i
        while i < len(s) && !is_space(s[i]) {
            i += 1
        }
        out[k] = s[start..i]
        k += 1
    }
    return out
}

fn lines(s: str) -> []str {
    if ends_with(s, "\n") {
        return split(s[..len(s) - 1], '\n')
    }
    return split(s, '\n')
}

// lexicographic comparison: negative, zero or positive
fn cmp(a: str, b: str) -> i64 {
    n := min(len(a), len(b))
    for i in 0..n {
        if a[i] != b[i] {
            return i64(a[i]) - i64(b[i])
        }
    }
    return len(a) - len(b)
}

fn parse_i64(s: str) -> (i64, bool) {
    return __parse_int(s, 10)
}

// an integer in another base (2..36; digits beyond 9 are letters of either case). Base 0: the
// text says it with 0x, 0b or 0o after the sign, and is decimal without one. With a base
// given, a prefix is not accepted.
fn parse_i64(s: str, base: i64) -> (i64, bool) {
    return __at_parse_i64(s, base, "?")
}

fn __at_parse_i64(s: str, base: i64, at: str) -> (i64, bool) {
    if base != 0 && (base < 2 || base > 36) {
        __panic(at, "parse_i64: the base must be 0 or 2..36")
    }
    return __parse_int(s, base)
}

fn __parse_int(s: str, base: i64) -> (i64, bool) {
    n := len(s)
    i := 0
    neg := false
    if n > 0 && (s[0] == '-' || s[0] == '+') {
        neg = s[0] == '-'
        i = 1
    }
    if base == 0 {
        base = 10
        if i + 1 < n && s[i] == '0' {
            p := s[i + 1] | 0x20
            base = if p == 'x' { 16 } else if p == 'b' { 2 } else if p == 'o' { 8 } else { 10 }
            if base != 10 {
                i += 2
            }
        }
    }
    if i == n {
        return (0, false)
    }
    v: u64 = 0
    // the largest magnitude: 2^63 - 1, or 2^63 after a minus sign
    limit: u64 = if neg { 0x8000_0000_0000_0000 } else { 0x7FFF_FFFF_FFFF_FFFF }
    b := u64(base)
    q := limit / b
    r := limit % b
    while i < n {
        c := s[i]
        d: u64 = 99
        if c >= '0' && c <= '9' {
            d = u64(c - '0')
        } else if (c | 0x20) >= 'a' && (c | 0x20) <= 'z' {
            d = u64((c | 0x20) - 'a') + 10
        }
        if d >= b || v > q || (v == q && d > r) {
            return (0, false)
        }
        v = v * b + d
        i += 1
    }
    if neg {
        return (i64(0 - v), true)
    }
    return (i64(v), true)
}

// ---- exact decimal to binary conversion: big integers as little-endian u32 limbs ----
const __BIG_LIMBS = 224

fn __big_mul_small(a: []u32, n: i64, k: u32) -> i64 {
    carry: u64 = 0
    for i in 0..n {
        t := u64(a[i]) * u64(k) + carry
        a[i] = u32(t)
        carry = t >> 32
    }
    if carry != 0 {
        a[n] = u32(carry)
        n += 1
    }
    return n
}

fn __big_add_small(a: []u32, n: i64, k: u32) -> i64 {
    carry: u64 = u64(k)
    i := 0
    while carry != 0 {
        if i == n {
            a[n] = 0
            n += 1
        }
        t := u64(a[i]) + carry
        a[i] = u32(t)
        carry = t >> 32
        i += 1
    }
    return n
}

fn __big_mul_pow10(a: []u32, n: i64, e: i64) -> i64 {
    while e >= 9 {
        n = __big_mul_small(a, n, 1000000000)
        e -= 9
    }
    k: u32 = 1
    while e > 0 {
        k = k * 10
        e -= 1
    }
    if k != 1 {
        n = __big_mul_small(a, n, k)
    }
    return n
}

fn __big_shl(a: []u32, n: i64, bits: i64) -> i64 {
    if n == 0 || bits == 0 {
        return n
    }
    words := bits >> 5
    sh := u32(bits & 31)
    i := n - 1
    if sh != 0 {
        a[n + words] = a[n - 1] >> (32 - sh)
    }
    while i >= 0 {
        lo := if i > 0 && sh != 0 { a[i - 1] >> (32 - sh) } else { u32(0) }
        a[i + words] = (a[i] << sh) | lo
        i -= 1
    }
    fill(a[..words], 0)
    n += words
    if sh != 0 && a[n] != 0 {
        n += 1
    }
    return n
}

fn __big_cmp(a: []u32, an: i64, b: []u32, bn: i64) -> i64 {
    if an != bn {
        return if an < bn { -1 } else { 1 }
    }
    i := an - 1
    while i >= 0 {
        if a[i] != b[i] {
            return if a[i] < b[i] { -1 } else { 1 }
        }
        i -= 1
    }
    return 0
}

// compares the decimal value num * 10^e10 (num: n limbs, already multiplied by 10^e10 when
// e10 > 0) with mm * 2^q
fn __dec_cmp_bin(num: []u32, n: i64, e10: i64, mm: u64, q: i64) -> i64 {
    a: [__BIG_LIMBS]u32
    b: [__BIG_LIMBS]u32
    copy(a[..n], num[..n])
    an := n
    b[0] = u32(mm)
    b[1] = u32(mm >> 32)
    bn := if b[1] != 0 { 2 } else { if b[0] != 0 { 1 } else { 0 } }
    if e10 < 0 {
        bn = __big_mul_pow10(b[..], bn, -e10)
    }
    if q >= 0 {
        bn = __big_shl(b[..], bn, q)
    } else {
        an = __big_shl(a[..], an, -q)
    }
    return __big_cmp(a[..], an, b[..], bn)
}

// decimal text to the nearest f64 (ties to even), exactly as a C compiler reads a literal:
// [+-] digits [. digits] [e [+-] digits]; (0, false) if s is not a number
fn parse_f64(s: str) -> (f64, bool) {
    num: [__BIG_LIMBS]u32
    v, ok, _, _ := __parse_dec(s, num[..])
    return (v, ok)
}

// decimal text to the nearest f32 (ties to even), rounded once from the text: the nearest f64
// can only mislead when it lies exactly halfway between two f32s, and then the exact decimal
// value decides
fn parse_f32(s: str) -> (f32, bool) {
    num: [__BIG_LIMBS]u32
    v, ok, nn, exp10 := __parse_dec(s, num[..])
    r := f32(v)
    if !ok || nn == 0 || f64(r) == v || v != v {
        return (r, ok)
    }
    // lo: the largest f32 below |v|, hi: the next one (2^128 above the largest finite f32)
    av := fabs(v)
    lb := cast[u32](f32(av))
    if f64(cast[f32](lb)) > av {
        lb -= 1
    }
    lo := f64(cast[f32](lb))
    hi := if lb + 1 == 0x7F800000 { cast[f64](u64(0x47F0000000000000)) } else { f64(cast[f32](lb + 1)) }
    if av != (lo + hi) * 0.5 {
        return (r, true)
    }
    m, e, _ := __f64_parts(av)
    c := __dec_cmp_bin(num[..], nn, exp10, m, e)
    if c == 0 {
        return (r, true)
    }
    x := cast[f32](if c > 0 { lb + 1 } else { lb })
    return (if v < 0.0 { -x } else { x }, true)
}

// parse_f64 with the digits as a big integer: (value, ok, nn, exp10) where num[..nn] * 10^exp10
// is the exact value (num already multiplied when exp10 > 0); nn is 0 for zero, overflow,
// underflow and errors
fn __parse_dec(s: str, num: []u32) -> (f64, bool, i64, i64) {
    n := len(s)
    i := 0
    neg := false
    if n > 0 && (s[0] == '-' || s[0] == '+') {
        neg = s[0] == '-'
        i = 1
    }
    // significant digits as a big integer (at most 800 are kept; more only set a sticky digit)
    nn := 0
    mant: u64 = 0
    digits := 0
    mdigits := 0
    exp10 := 0
    mexp := 0
    seen := false
    sticky := false
    frac := false
    loop {
        if i < n && s[i] == '.' && !frac {
            frac = true
            i += 1
            continue
        }
        if i >= n || s[i] < '0' || s[i] > '9' {
            break
        }
        d := u32(s[i] - '0')
        seen = true
        if digits < 800 {
            if digits > 0 || d != 0 {
                nn = __big_mul_small(num[..], nn, 10)
                nn = __big_add_small(num[..], nn, d)
                digits += 1
            }
            if frac {
                exp10 -= 1
            }
        } else {
            sticky = sticky || d != 0
            if !frac {
                exp10 += 1
            }
        }
        if mdigits < 19 {
            mant = mant * 10 + u64(d)
            if mant != 0 {
                mdigits += 1
            }
            if frac {
                mexp -= 1
            }
        } else if !frac {
            mexp += 1
        }
        i += 1
    }
    if !seen {
        return (0.0, false, 0, 0)
    }
    if i < n && (s[i] == 'e' || s[i] == 'E') {
        i += 1
        eneg := false
        if i < n && (s[i] == '-' || s[i] == '+') {
            eneg = s[i] == '-'
            i += 1
        }
        if i == n {
            return (0.0, false, 0, 0)
        }
        e := 0
        while i < n && s[i] >= '0' && s[i] <= '9' {
            // saturates far beyond any digit count a string can have (no overflow)
            if e < 100_000_000_000_000_000 {
                e = e * 10 + i64(s[i] - '0')
            }
            i += 1
        }
        exp10 += if eneg { -e } else { e }
        mexp += if eneg { -e } else { e }
    }
    if i != n {
        return (0.0, false, 0, 0)
    }
    inf := cast[f64](u64(0x7FF0000000000000))
    if nn == 0 {
        return (if neg { -0.0 } else { 0.0 }, true, 0, 0)
    }
    if digits + exp10 > 310 {
        return (if neg { -inf } else { inf }, true, 0, 0)
    }
    if digits + exp10 < -326 {
        return (if neg { -0.0 } else { 0.0 }, true, 0, 0)
    }
    if sticky {
        // the dropped digits only matter as "a little more": one extra non-zero digit
        nn = __big_mul_small(num[..], nn, 10)
        nn = __big_add_small(num[..], nn, 1)
        exp10 -= 1
    }
    if exp10 > 0 {
        nn = __big_mul_pow10(num[..], nn, exp10)
    }
    // a first guess in floating point (within a few units in the last place)
    x := f64(mant)
    e := if mexp < 0 { -mexp } else { mexp }
    while e > 0 {
        step := if e > 300 { 300 } else { e }
        scale: f64 = 1.0
        p: f64 = 10.0
        k := step
        while k > 0 {
            if k & 1 == 1 {
                scale = scale * p
            }
            p = p * p
            k = k >> 1
        }
        x = if mexp < 0 { x / scale } else { x * scale }
        e -= step
    }
    bits: u64 = cast[u64](x)
    if bits >= 0x7FF0000000000000 {
        bits = 0x7FEFFFFFFFFFFFFF
    }
    // correct the guess: move while the exact value lies beyond the midpoint to a neighbour
    loop {
        ex := i64(bits >> 52)
        fr := bits & 0xFFFFFFFFFFFFF
        m := if ex == 0 { fr } else { fr | (u64(1) << 52) }
        q := if ex == 0 { -1074 } else { ex - 1075 }
        hi := __dec_cmp_bin(num[..], nn, exp10, 2 * m + 1, q - 1)
        if hi > 0 || (hi == 0 && m & 1 == 1) {
            bits += 1
            if bits >= 0x7FF0000000000000 {
                break
            }
            if hi == 0 {
                break
            }
            continue
        }
        if hi == 0 || m == 0 {
            break
        }
        lo := 0
        if fr == 0 && ex > 1 {
            // the double below a power of two is only half as far away
            lo = __dec_cmp_bin(num[..], nn, exp10, 4 * m - 1, q - 2)
        } else {
            lo = __dec_cmp_bin(num[..], nn, exp10, 2 * m - 1, q - 1)
        }
        if lo < 0 || (lo == 0 && m & 1 == 1) {
            bits -= 1
            if lo == 0 {
                break
            }
            continue
        }
        break
    }
    r := cast[f64](bits)
    return (if neg { -r } else { r }, true, nn, exp10)
}

// ---------- files and arguments ----------
fn __cstr(s: str) -> i64 {
    p := __alloc(len(s) + 1)
    memcopy(p, ptr(s), len(s))
    return p
}

// opens path for reading or (created or emptied) for writing; a path with a NUL byte would
// name another file: EINVAL
fn __open(path: str, write: bool) -> i64 {
    if index_of(path, 0) >= 0 {
        return __io_result(-22)
    }
    return __io_result(__os_open(cast[*u8](__cstr(path)), write))
}

// the error number of the most recent failed file operation (0 after a success)
__io_errno: i64

// records the outcome of a system call: a negative result is `-errno`; returns `r`
fn __io_result(r: i64) -> i64 {
    if r < 0 {
        __io_errno = -r
    } else {
        __io_errno = 0
    }
    return r
}

// The OS error number (Linux errno) of the most recent failed file operation of the library
// (`read_file`, `write_file`, `read_all`, and the file functions of std.asset); 0 if the
// most recent one succeeded. Read it right after the call that returned `false`.
fn io_error() -> i64 {
    return __io_errno
}

// a short text for an OS error number, e.g. for `io_error()`
fn error_text(e: i64) -> str {
    match e {
        0 => "no error"
        1 => "operation not permitted"
        2 => "no such file or directory"
        3 => "no such process"
        4 => "interrupted system call"
        5 => "input/output error"
        6 => "no such device or address"
        7 => "argument list too long"
        8 => "exec format error"
        9 => "bad file descriptor"
        10 => "no child processes"
        11 => "resource temporarily unavailable"
        12 => "out of memory"
        13 => "permission denied"
        16 => "device or resource busy"
        17 => "file exists"
        18 => "cross-device link"
        19 => "no such device"
        20 => "not a directory"
        21 => "is a directory"
        22 => "invalid argument"
        23 => "too many open files in system"
        24 => "too many open files"
        26 => "text file busy"
        27 => "file too large"
        28 => "no space left on device"
        29 => "illegal seek"
        30 => "read-only file system"
        31 => "too many links"
        32 => "broken pipe"
        36 => "file name too long"
        39 => "directory not empty"
        40 => "too many levels of symbolic links"
        122 => "disk quota exceeded"
        _ => __os_error_text(e)
    }
}

// everything readable from a file descriptor (0 = standard input); what was read before an
// error is returned, and `io_error()` tells whether there was one
fn read_all(fd: i64) -> str {
    // a regular file: room for its size and one more byte (to see the end); /proc files
    // report 0. Other inputs (pipes, terminals): 64 KiB first. The buffer doubles as needed.
    size := 65536
    fsize, regular := __os_fstat(fd)
    if regular {
        size = if fsize > 0 { fsize + 1 } else { 4096 }
    }
    buf := alloc[u8](size)
    n := 0
    loop {
        if n == len(buf) {
            nb := alloc[u8](len(buf) * 2)
            memcopy(ptr(nb), ptr(buf), n)
            buf = nb
        }
        r := __os_read(fd, cast[i64](ptr(buf)) + n, len(buf) - n)
        __io_result(r)
        if r <= 0 {
            break
        }
        n += r
    }
    return buf[..n]
}

// the content of a file; ("", false) if it cannot be opened or read (see `io_error()`)
fn read_file(path: str) -> (str, bool) {
    fd := __open(path, false)
    if fd < 0 {
        return ("", false)
    }
    data := read_all(fd)
    __os_close(fd)
    if __io_errno != 0 {
        return ("", false)
    }
    return (data, true)
}

// creates or replaces a file; false if that failed (see `io_error()`)
fn write_file(path: str, data: str) -> bool {
    fd := __open(path, true)
    if fd < 0 {
        return false
    }
    e := __write_all(fd, cast[i64](ptr(data)), len(data))
    if e != 0 {
        __io_errno = e
    }
    __os_close(fd)
    return e == 0
}

// ---------- text helpers ----------
// s right-aligned in a field of `width` characters (padded on the left with `fill`)
fn pad_left(s: str, width: i64, fill: u8) -> str {
    if len(s) >= width {
        return s
    }
    out := alloc[u8](width)
    k := width - len(s)
    for i in 0..k {
        out[i] = fill
    }
    memcopy(cast[i64](ptr(out)) + k, ptr(s), len(s))
    return out
}

// s left-aligned in a field of `width` characters
fn pad_right(s: str, width: i64, fill: u8) -> str {
    if len(s) >= width {
        return s
    }
    out := alloc[u8](width)
    memcopy(ptr(out), ptr(s), len(s))
    for i in len(s)..width {
        out[i] = fill
    }
    return out
}

// lower-case hexadecimal digits of x (no prefix)
fn hex(x: u64) -> str {
    return __to_base(x, 16)
}

// at least `width` digits (zeros in front)
fn hex(x: u64, width: i64) -> str {
    return pad_left(__to_base(x, 16), width, '0')
}

// the digits of x in a base of 2..36 (0-9, then a-z; no prefix)
fn to_base(x: u64, base: i64) -> str {
    return __at_to_base(x, base, "?")
}

fn __at_to_base(x: u64, base: i64, at: str) -> str {
    if base < 2 || base > 36 {
        __panic(at, "to_base: the base must be 2..36")
    }
    return __to_base(x, u64(base))
}

fn __to_base(x: u64, base: u64) -> str {
    b: [64]u8
    i := 64
    loop {
        i -= 1
        d := u8(x % base)
        b[i] = if d < 10 { d + '0' } else { d - 10 + 'a' }
        x = x / base
        if x == 0 {
            break
        }
    }
    out := alloc[u8](64 - i)
    memcopy(ptr(out), cast[i64](ptr(b)) + i, 64 - i)
    return out
}

// an integer right-aligned in `width` characters; with fill '0' the zeros follow the sign:
// fmti(-42, 5, '0') is "-0042"
fn fmti[T](x: T, width: i64, fill: u8) -> str {
    s := fmt(x)
    if fill == '0' && len(s) < width && s[0] == '-' {
        out := pad_left(s[1..], width, '0')
        out[0] = '-'
        return out
    }
    return pad_left(s, width, fill)
}

fn to_upper(s: str) -> str {
    out := alloc[u8](len(s))
    for i, c in s {
        out[i] = if c >= 'a' && c <= 'z' { c - 32 } else { c }
    }
    return out
}

fn to_lower(s: str) -> str {
    out := alloc[u8](len(s))
    for i, c in s {
        out[i] = if c >= 'A' && c <= 'Z' { c + 32 } else { c }
    }
    return out
}

// concatenation of all parts with sep between them
fn join(parts: []str, sep: str) -> str {
    n := 0
    for p in parts {
        n = __add_size(n, len(p))
    }
    if len(parts) > 1 {
        n = __add_size(n, __alloc_size(len(parts) - 1, len(sep)))
    }
    out := alloc[u8](n)
    k := 0
    for i, p in parts {
        if i > 0 {
            memcopy(cast[i64](ptr(out)) + k, ptr(sep), len(sep))
            k += len(sep)
        }
        memcopy(cast[i64](ptr(out)) + k, ptr(p), len(p))
        k += len(p)
    }
    return out
}

// a NUL-terminated copy of s, for C functions (string literals are NUL-terminated already:
// `ptr("literal")` can be passed directly)
fn cstr(s: str) -> *u8 {
    return cast[*u8](__cstr(s))
}

// the text of a NUL-terminated C string (not copied)
fn from_cstr(p: *u8) -> str {
    if p == nil {
        return ""
    }
    n := 0
    while p[n] != 0 {
        n += 1
    }
    return mkslice[u8](p, n)
}

// ---------- characters, environment, standard error ----------
fn is_digit(c: u8) -> bool {
    return c >= '0' && c <= '9'
}

fn is_alpha(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

fn is_alnum(c: u8) -> bool {
    return is_digit(c) || is_alpha(c)
}

fn is_upper(c: u8) -> bool {
    return c >= 'A' && c <= 'Z'
}

fn is_lower(c: u8) -> bool {
    return c >= 'a' && c <= 'z'
}

// ---------- standard error ----------
// (environment variables: env_get(name) of the OS layer)

// like print, to standard error
fn eprint(s: str) {
    flush()
    __err(s)
    __err("\n")
}

// like put (no newline), to standard error
fn eput(s: str) {
    flush()
    __err(s)
}


// ---------- optional values ----------
// a value that may be absent
// (`None` first: the zero value of an Opt is None)
enum Opt[T] { None, Some(T) }

fn is_some[T](o: Opt[T]) -> bool {
    match o {
        Some(_) => true
        None => false
    }
}

fn is_none[T](o: Opt[T]) -> bool {
    match o {
        Some(_) => false
        None => true
    }
}

// the value of `o`; stops the program if there is none
fn unwrap[T](o: Opt[T]) -> T {
    match o {
        Some(x) => x
        None => __die("panic: unwrap of None", "", "")
    }
}

// the value of `o`, or `default` if there is none
fn or[T](o: Opt[T], default: T) -> T {
    match o {
        Some(x) => x
        None => default
    }
}

// ---------- target ----------
// The system and processor the program is built for, constants for `when` and `if`:
// `when TARGET_OS == Windows { ... }`. TARGET_OS is declared by the OS layer.
enum Os { Linux, Windows }
enum Arch { X86_64 }

const TARGET_ARCH = Arch.X86_64
