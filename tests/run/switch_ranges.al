// two compares of one value against constants that test an interval (`lo <= x && x <= hi`,
// `x < lo || x > hi`, in either order, signed or unsigned) become one unsigned compare; the
// results must not change at the ends of the intervals and of the types

const MAX = 0x7FFF_FFFF_FFFF_FFFF

fn lower(c: u8) -> bool {
    return c >= 'a' && c <= 'z'
}

fn not_digit(c: u8) -> bool {
    return c < '0' || c > '9'
}

fn ident(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// reversed order and strict compares
fn rev(x: i64) -> i64 {
    if x < 100 && x > -100 {
        return 1
    }
    if 1000 >= x && 500 <= x {
        return 2
    }
    return 0
}

// signed narrow values around zero and the ends of the type
fn s8(x: i8) -> i64 {
    r := 0
    if x >= -5 && x <= 5 {
        r += 1
    }
    if x >= -128 && x <= -100 {
        r += 2
    }
    if x > 120 && x <= 127 {
        r += 4
    }
    if x < -1 || x > 1 {
        r += 8
    }
    return r
}

// unsigned values near the top of the type
fn u64top(x: u64) -> i64 {
    r := 0
    if x >= 0xFFFF_FFFF_FFFF_FFF0 && x <= 0xFFFF_FFFF_FFFF_FFFE {
        r += 1
    }
    if x >= 0x7FFF_FFFF_FFFF_FFFF && x <= 0x8000_0000_0000_0001 {
        r += 2
    }
    if x > 10 && x < 20 {
        r += 4
    }
    return r
}

fn i64ends(x: i64) -> i64 {
    r := 0
    if x >= -MAX - 1 && x <= -MAX + 2 {
        r += 1
    }
    if x >= MAX - 2 && x <= MAX {
        r += 2
    }
    if x >= -3 && x <= MAX - 3 {
        r += 4
    }
    // one value
    if x >= 7 && x <= 7 {
        r += 8
    }
    // empty and full intervals stay as they are
    if x > 5 && x < 5 {
        r += 16
    }
    if x >= -MAX - 1 || x <= MAX {
        r += 32
    }
    return r
}

fn u16r(x: u16) -> i64 {
    r := 0
    if x >= 65000 && x <= 65535 {
        r += 1
    }
    if x < 3 || x > 65533 {
        r += 2
    }
    return r
}

// a value merged from the arms of the tests
fn val(x: i32, a: i64) -> i64 {
    v := a
    if x >= 10 && x <= 20 {
        v = a * 3
    }
    return v + 1
}

fn main() {
    ps := vec[i64]()
    for k in -300..300 {
        ps.push(k)
    }
    for k in []i64{499, 500, 501, 999, 1000, 1001, 64999, 65000, 65001, 65532, 65533, 65534, 65535, 65536,
        MAX, MAX - 1, MAX - 2, MAX - 3, MAX - 4, -MAX - 1, -MAX, -MAX + 1, -MAX + 2, -MAX + 3,
        -15, -16, -17, -2, -1, 0x7FFF_FFFF, 0x8000_0000} {
        ps.push(k)
    }
    h: u64 = 1469598103934665603
    counts := [8]i64{}
    for p in ps {
        rs := []i64{
            if lower(u8(p)) { 1 } else { 0 },
            if not_digit(u8(p)) { 1 } else { 0 },
            if ident(u8(p)) { 1 } else { 0 },
            rev(p),
            s8(i8(p)),
            u64top(u64(p)),
            i64ends(p),
            u16r(u16(p)) + 4 * val(i32(p), p),
        }
        for i in 0..8 {
            h = (h ^ u64(rs[i])) * 1099511628211
            counts[i] += rs[i] & 0xFF
        }
    }
    for i in 0..8 {
        put(counts[i], " ")
    }
    put("\n", h, "\n")
    for c in "az`{AZ09_ /:" {
        put(if lower(c) { "l" } else { "-" }, if not_digit(c) { "n" } else { "d" }, if ident(c) { "i" } else { "." }, " ")
    }
    put("\n")
}
