// AL runtime prelude. Compiled together with every program.

__heap_cur: i64
__heap_end: i64
__heap_base: i64
__heap_hwm: i64
__argc: i64
__argv: i64
__obuf: [65536]u8
__olen: i64
__tests_failed: i64

__sigstack: [32768]u8

noinline fn __on_fault(sig: i64) -> never {
    if sig == 8 {
        __die("panic: arithmetic fault (division by zero or overflow)", "", "")
    }
    __die("panic: memory fault (nil dereference, stack overflow or use of released memory)", "", "")
}

fn __rt_init(sp: i64) {
    __argc = cast[*i64](sp)[0]
    __argv = sp + 8
    // report crashes as panics: handlers run on their own stack so that stack overflow works too
    ss: [3]i64
    ss[0] = cast[i64](ptr(__sigstack))
    ss[2] = 32768
    syscall(131, ptr(ss), 0)
    sa: [4]i64
    sa[0] = cast[i64](__on_fault)
    // SA_ONSTACK | SA_RESTORER | SA_NODEFER
    sa[1] = 0x08000000 | 0x04000000 | 0x40000000
    sa[2] = cast[i64](__on_fault)
    syscall(13, 11, ptr(sa), 0, 8)
    syscall(13, 7, ptr(sa), 0, 8)
    syscall(13, 8, ptr(sa), 0, 8)
}

// ---------- process ----------
fn exit(code: i64) -> never {
    flush()
    syscall(231, code)
}

fn __write_all(fd: i64, p: i64, n: i64) {
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
    syscall(231, 1)
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

noinline fn __heap_grow(n: i64) -> i64 {
    if __heap_base == 0 {
        // address space is reserved on the first allocation, memory is committed by use: 64 GiB
        // for the main arena, 16 GiB for a region (thousands of regions fit), less if refused
        size := if __region_depth == 0 { 1 << 36 } else { 1 << 34 }
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

// uninitialized memory, 16-byte aligned; never freed individually (see mark/release)
inline fn __alloc_raw(n: i64) -> i64 {
    n = (n + 15) & ~15
    p := __heap_cur
    e := p + n
    if e > __heap_end {
        return __heap_grow(n)
    }
    __heap_cur = e
    return p
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

fn alloc[T](n: i64) -> []T {
    if n < 0 {
        __die("panic: negative allocation size", "", "")
    }
    return mkslice[T](__alloc(n * sizeof[T]()), n)
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
    for i in 0..__region_depth {
        if __region_stack[i] == r {
            return true
        }
    }
    return false
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
        syscall(11, r.base, r.end - r.base)
    }
    *r = Region{}
}

// ---------- output ----------
fn flush() {
    if __olen > 0 {
        __write_all(1, cast[i64](ptr(__obuf)), __olen)
        __olen = 0
    }
}

fn __put_str(s: str) {
    if __cap_on != 0 {
        __cap_put(s)
        return
    }
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
    for c in s {
        out[o] = c
        o += 1
    }
    return o
}

// printf("%.*f") semantics: exact value, round half to even. Returns the length written to out.
fn __fmt_fixed(x: f64, prec: i64, out: []u8) -> i64 {
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

// print x with exactly `prec` digits after the decimal point (like printf "%.Nf")
fn putf(x: f64, prec: i64) {
    b: [800]u8
    n := __fmt_fixed(x, prec, b[..])
    __put_str(b[..n])
}

fn fmtf(x: f64, prec: i64) -> str {
    b: [800]u8
    n := __fmt_fixed(x, prec, b[..])
    s := alloc[u8](n)
    for i in 0..n {
        s[i] = b[i]
    }
    return s
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
    pid := syscall(57)
    if pid == 0 {
        f()
        exit(0)
    }
    status: i32
    syscall(61, pid, &status, 0, 0)
    if status == 0 {
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
        cap := len(__cap_buf) * 2
        while cap < __cap_len + n {
            cap = cap * 2
        }
        // PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS
        p := syscall(9, 0, cap, 3, 0x22, -1, 0)
        if p < 0 && p > -4096 {
            __die("panic: out of memory", "", "")
        }
        memcopy(p, ptr(__cap_buf), __cap_len)
        if len(__cap_buf) > 1024 {
            syscall(11, ptr(__cap_buf), len(__cap_buf))
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
fn min[T](a: T, b: T) -> T {
    if b < a { b } else { a }
}

fn max[T](a: T, b: T) -> T {
    if b > a { b } else { a }
}

fn abs[T](x: T) -> T {
    if x < 0 { -x } else { x }
}

fn swap[T](a: *T, b: *T) {
    t := *a
    *a = *b
    *b = t
}

fn copy[T](dst: []T, src: []T) -> i64 {
    n := min(len(dst), len(src))
    memcopy(ptr(dst), ptr(src), n * sizeof[T]())
    return n
}

fn fill[T](a: []T, x: T) {
    for i in 0..len(a) {
        a[i] = x
    }
}

fn floor(x: f64) -> f64 {
    if x != x || fabs(x) >= 4503599627370496.0 {
        return x
    }
    t := f64(i64(x))
    if t > x { t - 1.0 } else { t }
}

fn ceil(x: f64) -> f64 {
    if x != x || fabs(x) >= 4503599627370496.0 {
        return x
    }
    t := f64(i64(x))
    if t < x { t + 1.0 } else { t }
}

fn clock_ns() -> i64 {
    ts: [2]i64
    syscall(228, 1, ptr(ts))
    return ts[0] * 1000000000 + ts[1]
}

// ---------- growable vector ----------
struct Vec[T] { buf: []T, len: i64 }

fn vec[T]() -> Vec[T] {
    return Vec[T]{buf: mkslice[T](__heap_cur, 0), len: 0}
}

fn reserve[T](v: *Vec[T], n: i64) {
    if n > len(v.buf) {
        cap := max(len(v.buf) * 2, max(n, 8))
        // the spare capacity is never read before it is written: no need to zero it
        nb := mkslice[T](__alloc_raw(cap * sizeof[T]()), cap)
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

fn pop[T](v: *Vec[T]) -> T {
    if v.len == 0 {
        __die("panic: pop from an empty Vec", "", "")
    }
    v.len -= 1
    return v.buf[v.len]
}

// the live elements of a Vec as a slice (valid until the next push that grows it)
fn items[T](v: *Vec[T]) -> []T {
    return v.buf[..v.len]
}

// ---------- hash map (open addressing, linear probing) ----------
struct Map[K, V] { keys: []K, vals: []V, state: []u8, len: i64, used: i64 }

fn map[K, V]() -> Map[K, V] {
    return Map[K, V]{keys: alloc[K](0), vals: alloc[V](0), state: alloc[u8](0), len: 0, used: 0}
}

fn __map_find[K, V](m: *Map[K, V], k: K) -> i64 {
    n := len(m.state)
    if n == 0 {
        return -1
    }
    mask := n - 1
    i := i64(hash(k) >> 1) & mask
    loop {
        s := m.state[i]
        if s == 0 {
            return -1
        }
        if s == 1 && m.keys[i] == k {
            return i
        }
        i = (i + 1) & mask
    }
}

fn __map_grow[K, V](m: *Map[K, V]) {
    old_keys := m.keys
    old_vals := m.vals
    old_state := m.state
    n := max(16, m.len * 4)
    cap := 16
    while cap < n {
        cap = cap * 2
    }
    m.keys = alloc[K](cap)
    m.vals = alloc[V](cap)
    m.state = alloc[u8](cap)
    m.len = 0
    m.used = 0
    for i in 0..len(old_state) {
        if old_state[i] == 1 {
            set(m, old_keys[i], old_vals[i])
        }
    }
}

fn set[K, V](m: *Map[K, V], k: K, v: V) {
    if (m.used + 1) * 4 > len(m.state) * 3 {
        __map_grow(m)
    }
    mask := len(m.state) - 1
    i := i64(hash(k) >> 1) & mask
    first_free := -1
    loop {
        s := m.state[i]
        if s == 0 {
            break
        }
        if s == 1 && m.keys[i] == k {
            m.vals[i] = v
            return
        }
        if s == 2 && first_free < 0 {
            first_free = i
        }
        i = (i + 1) & mask
    }
    if first_free >= 0 {
        i = first_free
    } else {
        m.used += 1
    }
    m.state[i] = 1
    m.keys[i] = k
    m.vals[i] = v
    m.len += 1
}

fn get[K, V](m: *Map[K, V], k: K) -> (V, bool) {
    i := __map_find(m, k)
    if i < 0 {
        zero: V
        return (zero, false)
    }
    return (m.vals[i], true)
}

// the value stored for k, or `default` when k is missing
fn get_or[K, V](m: *Map[K, V], k: K, default: V) -> V {
    i := __map_find(m, k)
    if i < 0 {
        return default
    }
    return m.vals[i]
}

fn has[K, V](m: *Map[K, V], k: K) -> bool {
    return __map_find(m, k) >= 0
}

fn del[K, V](m: *Map[K, V], k: K) -> bool {
    i := __map_find(m, k)
    if i < 0 {
        return false
    }
    m.state[i] = 2
    m.len -= 1
    return true
}

// all keys, in unspecified order
fn keys[K, V](m: *Map[K, V]) -> []K {
    out := alloc[K](m.len)
    n := 0
    for i in 0..len(m.state) {
        if m.state[i] == 1 {
            out[n] = m.keys[i]
            n += 1
        }
    }
    return out
}

// ---------- clone ----------
// The builtin `clone(x)` copies x member by member and calls these for the parts that own
// storage. All copies are allocated from the arena in use.

// a slice of elements that own nothing: one allocation, one memory copy
fn __clone_plain[T](s: []T) -> []T {
    n := len(s)
    out := mkslice[T](__alloc_raw(n * sizeof[T]()), n)
    memcopy(ptr(out), ptr(s), n * sizeof[T]())
    return out
}

fn __clone_slice[T](s: []T) -> []T {
    n := len(s)
    out := mkslice[T](__alloc_raw(n * sizeof[T]()), n)
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

// the keys or values of a Map: only occupied slots hold a value (`plain`: T owns no storage)
fn __clone_slots[T](s: []T, state: []u8, plain: bool) -> []T {
    if plain {
        return __clone_plain(s)
    }
    out := alloc[T](len(s))
    for i in 0..len(s) {
        if state[i] == 1 {
            out[i] = clone(s[i])
        }
    }
    return out
}

fn __clone_map[K, V](m: *Map[K, V], kplain: bool, vplain: bool) -> Map[K, V] {
    return Map[K, V]{
        keys: __clone_slots(m.keys, m.state, kplain),
        vals: __clone_slots(m.vals, m.state, vplain),
        state: __clone_plain(m.state),
        len: m.len,
        used: m.used,
    }
}

// ---------- sorting ----------
fn __sort_range[T](a: []T, lo: i64, hi: i64) {
    while hi - lo > 16 {
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
                t := a[i]
                a[i] = a[j]
                a[j] = t
                i += 1
                j -= 1
            }
        }
        // recurse into the smaller half, loop on the larger one
        if j - lo < hi - i {
            __sort_range(a, lo, j)
            lo = i
        } else {
            __sort_range(a, i, hi)
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

// ascending sort of numbers (anything comparable with `<`)
fn sort[T](a: []T) {
    __sort_range(a, 0, len(a) - 1)
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
        for i in 0..n {
            a[i] = src[i]
        }
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
        for i in 0..n {
            a[i] = src[i]
        }
    }
}

// ---------- strings ----------
fn concat(a: str, b: str) -> str {
    out := alloc[u8](len(a) + len(b))
    memcopy(ptr(out), ptr(a), len(a))
    memcopy(cast[i64](ptr(out)) + len(a), ptr(b), len(b))
    return out
}

// index of the first occurrence of sub in s, or -1
fn find(s: str, sub: str) -> i64 {
    n := len(s)
    m := len(sub)
    if m == 0 {
        return 0
    }
    i := 0
    while i + m <= n {
        if s[i] == sub[0] && s[i..i + m] == sub {
            return i
        }
        i += 1
    }
    return -1
}

fn starts_with(s: str, p: str) -> bool {
    return len(s) >= len(p) && s[..len(p)] == p
}

fn ends_with(s: str, p: str) -> bool {
    return len(s) >= len(p) && s[len(s) - len(p)..] == p
}

fn __is_space(c: u8) -> bool {
    return c == ' ' || c == '\n' || c == '\t' || c == '\r'
}

fn trim(s: str) -> str {
    lo := 0
    hi := len(s)
    while lo < hi && __is_space(s[lo]) {
        lo += 1
    }
    while hi > lo && __is_space(s[hi - 1]) {
        hi -= 1
    }
    return s[lo..hi]
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

fn lines(s: str) -> []str {
    if len(s) > 0 && s[len(s) - 1] == '\n' {
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
    n := len(s)
    i := 0
    neg := false
    if n > 0 && (s[0] == '-' || s[0] == '+') {
        neg = s[0] == '-'
        i = 1
    }
    if i == n {
        return (0, false)
    }
    v: u64 = 0
    while i < n {
        c := s[i]
        if c < '0' || c > '9' {
            return (0, false)
        }
        v = v * 10 + u64(c - '0')
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
    for j in 0..words {
        a[j] = 0
    }
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
    for i in 0..n {
        a[i] = num[i]
    }
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
    n := len(s)
    i := 0
    neg := false
    if n > 0 && (s[0] == '-' || s[0] == '+') {
        neg = s[0] == '-'
        i = 1
    }
    // significant digits as a big integer (at most 800 are kept; more only set a sticky digit)
    num: [__BIG_LIMBS]u32
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
        return (0.0, false)
    }
    if i < n && (s[i] == 'e' || s[i] == 'E') {
        i += 1
        eneg := false
        if i < n && (s[i] == '-' || s[i] == '+') {
            eneg = s[i] == '-'
            i += 1
        }
        if i == n {
            return (0.0, false)
        }
        e := 0
        while i < n && s[i] >= '0' && s[i] <= '9' {
            if e < 10000 {
                e = e * 10 + i64(s[i] - '0')
            }
            i += 1
        }
        exp10 += if eneg { -e } else { e }
        mexp += if eneg { -e } else { e }
    }
    if i != n {
        return (0.0, false)
    }
    inf := cast[f64](u64(0x7FF0000000000000))
    if nn == 0 {
        return (if neg { -0.0 } else { 0.0 }, true)
    }
    if digits + exp10 > 310 {
        return (if neg { -inf } else { inf }, true)
    }
    if digits + exp10 < -326 {
        return (if neg { -0.0 } else { 0.0 }, true)
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
        scale := 1.0
        p := 10.0
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
    return (if neg { -r } else { r }, true)
}

// ---------- files and arguments ----------
fn __cstr(s: str) -> i64 {
    p := __alloc(len(s) + 1)
    memcopy(p, ptr(s), len(s))
    return p
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
        0 => return "no error"
        1 => return "operation not permitted"
        2 => return "no such file or directory"
        4 => return "interrupted system call"
        5 => return "input/output error"
        6 => return "no such device or address"
        9 => return "bad file descriptor"
        11 => return "resource temporarily unavailable"
        12 => return "out of memory"
        13 => return "permission denied"
        16 => return "device or resource busy"
        17 => return "file exists"
        18 => return "cross-device link"
        19 => return "no such device"
        20 => return "not a directory"
        21 => return "is a directory"
        22 => return "invalid argument"
        23 => return "too many open files in system"
        24 => return "too many open files"
        26 => return "text file busy"
        27 => return "file too large"
        28 => return "no space left on device"
        29 => return "illegal seek"
        30 => return "read-only file system"
        31 => return "too many links"
        32 => return "broken pipe"
        36 => return "file name too long"
        39 => return "directory not empty"
        40 => return "too many levels of symbolic links"
        122 => return "disk quota exceeded"
        _ => {}
    }
    return fmt("os error ", e)
}

// everything readable from a file descriptor (0 = standard input); what was read before an
// error is returned, and `io_error()` tells whether there was one
fn read_all(fd: i64) -> str {
    buf := alloc[u8](65536)
    n := 0
    loop {
        if n == len(buf) {
            nb := alloc[u8](len(buf) * 2)
            memcopy(ptr(nb), ptr(buf), n)
            buf = nb
        }
        r := syscall(0, fd, cast[i64](ptr(buf)) + n, len(buf) - n)
        if r == -4 {
            continue
        }
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
    fd := __io_result(syscall(2, __cstr(path), 0, 0))
    if fd < 0 {
        return ("", false)
    }
    data := read_all(fd)
    syscall(3, fd)
    if __io_errno != 0 {
        return ("", false)
    }
    return (data, true)
}

// creates or replaces a file; false if that failed (see `io_error()`)
fn write_file(path: str, data: str) -> bool {
    // O_WRONLY|O_CREAT|O_TRUNC, mode 0644
    fd := __io_result(syscall(2, __cstr(path), 577, 420))
    if fd < 0 {
        return false
    }
    p := cast[i64](ptr(data))
    n := len(data)
    ok := true
    while n > 0 {
        r := syscall(1, fd, p, n)
        if r == -4 {
            continue
        }
        if r <= 0 {
            // (a write of nothing without an error: reported as an input/output error)
            __io_errno = if r < 0 { -r } else { 5 }
            ok = false
            break
        }
        p += r
        n -= r
    }
    syscall(3, fd)
    return ok
}

// command line arguments (args()[0] is the program name)
fn args() -> []str {
    out := alloc[str](__argc)
    for i in 0..__argc {
        p := cast[*i64](__argv)[i]
        n := 0
        while cast[*u8](p)[n] != 0 {
            n += 1
        }
        out[i] = mkslice[u8](p, n)
    }
    return out
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
    b: [16]u8
    i := 16
    loop {
        i -= 1
        d := u8(x & 15)
        b[i] = if d < 10 { d + '0' } else { d - 10 + 'a' }
        x = x >> 4
        if x == 0 {
            break
        }
    }
    out := alloc[u8](16 - i)
    memcopy(ptr(out), cast[i64](ptr(b)) + i, 16 - i)
    return out
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
        n += len(p)
    }
    if len(parts) > 1 {
        n += len(sep) * (len(parts) - 1)
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

// ---------- optional values and results ----------
// a value that may be absent
enum Opt[T] { Some(T), None }

// a value, or the message of the error that prevented it
enum Res[T] { Ok(T), Err(str) }

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
        Some(x) => { return x }
        None => {}
    }
    __die("panic: unwrap of None", "", "")
}

// the value of `o`, or `default` if there is none
fn or[T](o: Opt[T], default: T) -> T {
    match o {
        Some(x) => x
        None => default
    }
}

fn is_ok[T](r: Res[T]) -> bool {
    match r {
        Ok(_) => true
        Err(_) => false
    }
}

fn is_err[T](r: Res[T]) -> bool {
    match r {
        Ok(_) => false
        Err(_) => true
    }
}

// the value of `r`; stops the program with the error message if it is an error
fn unwrap[T](r: Res[T]) -> T {
    match r {
        Ok(x) => { return x }
        Err(e) => { __die("panic: unwrap of Err: ", e, "") }
    }
}

// the value of `r`, or `default` if it is an error
fn or[T](r: Res[T], default: T) -> T {
    match r {
        Ok(x) => x
        Err(_) => default
    }
}

// the error message of `r` ("" if it is not an error)
fn error[T](r: Res[T]) -> str {
    match r {
        Ok(_) => ""
        Err(e) => e
    }
}
