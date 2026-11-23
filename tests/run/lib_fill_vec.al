// fill (memory fill for bytes and for values whose bytes are all alike, doubling copies for
// long slices, an element loop otherwise), vec_fill / resize through it, and Vec push / pop
// (an inlined fast path, growth out of line): every length 0..40 and long ones, a sub-slice
// whose neighbours must stay as they are, -0.0 and NaN, structs.
struct P { a: i32, b: u8, c: f64 }

fn bytes_eq(a: *u8, b: *u8, n: i64) -> bool {
    for i in 0..n {
        if a[i] != b[i] {
            return false
        }
    }
    return true
}

fn check_fill[T](x: T, y: T, name: str) {
    bad := 0
    for n in ([]i64{0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33, 40, 63, 64, 65, 100, 511, 512, 513, 1000, 4097}) {
        for off in 0..3 {
            buf := alloc[T](n + 6)
            for i in 0..len(buf) {
                buf[i] = y
            }
            fill(buf[off..off + n], x)
            for i in 0..len(buf) {
                want := if i >= off && i < off + n { x } else { y }
                // (scalars compared as bytes: -0.0 and NaN must be exactly what was filled)
                ok := if sizeof[T]() == 4 || sizeof[T]() == 8 { bytes_eq(cast[*u8](&buf[i]), cast[*u8](&want), sizeof[T]()) } else { buf[i] == want }
                if !ok {
                    bad += 1
                }
            }
        }
    }
    print(name, "wrong:", bad)
}

fn main() {
    check_fill(u8(0), u8(9), "u8 0")
    check_fill(u8(0xAB), u8(9), "u8 AB")
    check_fill(i8(-1), i8(3), "i8 -1")
    check_fill(true, false, "bool")
    check_fill(i64(0), i64(5), "i64 0")
    check_fill(i64(-1), i64(5), "i64 -1")
    check_fill(i64(0x0102030405060708), i64(5), "i64 mixed")
    check_fill(i32(0x7F7F7F7F), i32(5), "i32 7F")
    check_fill(u16(0x1234), u16(5), "u16")
    check_fill(0.0, 1.0, "f64 0")
    check_fill(-0.0, 1.0, "f64 -0")
    check_fill(0.0 / 0.0, 1.0, "f64 nan")
    check_fill(f32(1.5), f32(2.0), "f32")
    check_fill(vec3(1.0, 2.0, 3.0), vec3(0.0), "vec3")
    check_fill(P{a: 0, b: 0, c: 0.0}, P{a: 1, b: 2, c: 3.0}, "P zero")
    check_fill(P{a: -7, b: 200, c: -0.0}, P{a: 1, b: 2, c: 3.0}, "P")
    check_fill("text", "", "str")

    v := vec_fill(1000, 7)
    v.resize(1500, 0)
    v.resize(2000, -1)
    print(len(v), v[0], v[999], v[1000], v[1499], v[1500], v[1999])

    // push / pop across many growths, and values of a struct type
    w := vec[P]()
    for i in 0..10000 {
        w.push(P{a: i32(i), b: u8(i & 255), c: f64(i) * 0.5})
        if i % 7 == 6 {
            p := w.pop()
            w.push(P{a: p.a + 1, b: p.b, c: p.c})
        }
    }
    s: f64 = 0.0
    k := 0
    while w.len > 0 {
        p := w.pop()
        s += p.c
        k += i64(p.a) + i64(p.b)
    }
    print(s, k, w.len)
    b := vec[u8]()
    for i in 0..100 {
        b.push(u8(i))
    }
    b.extend("xyz")
    print(len(b), b[99], b[102], b.pop(), b.pop(), len(b))

    // extend (short copies byte by byte, long ones as a memory copy; growth out of line), join,
    // repeat (doubling copies) and resize with fill, against element-by-element references
    bad := 0
    src := alloc[u8](64)
    for i in 0..64 {
        src[i] = u8(i * 7 + 1)
    }
    for start in 0..4 {
        e := vec[u8]()
        r := vec[u8]()
        for k in 0..41 {
            e.extend(src[start..start + k])
            for x in src[start..start + k] {
                r.push(x)
            }
        }
        if e.items() != r.items() {
            bad += 1
        }
    }
    f := vec[f64]()
    for k in 0..30 {
        f.extend([]f64{f64(k), -0.0, 0.5}[..k % 4])
    }
    for t in 1..6 {
        for n in 0..41 {
            s := src[1..1 + t]
            want := vec[u8]()
            for _ in 0..n {
                want.extend(s)
            }
            if repeat(s, n) != want.items() {
                bad += 1
            }
            parts := alloc[str](n)
            for i in 0..n {
                parts[i] = src[i % 5..i % 5 + i % 19]
            }
            j := join(parts, s)
            ref := vec[u8]()
            for i in 0..n {
                if i > 0 {
                    ref.extend(s)
                }
                ref.extend(parts[i])
            }
            if j != ref.items() {
                bad += 1
            }
        }
    }
    g := vec[i32]()
    gr := vec[i32]()
    for n in ([]i64{3, 1, 40, 40, 100, 7, 1000}) {
        g.resize(n, i32(n))
        gr.truncate(n)
        while gr.len < n {
            gr.push(i32(n))
        }
        if g.items() != gr.items() {
            bad += 1
        }
    }
    print("extend join repeat resize wrong:", bad, len(f), f[..6], len(repeat("ab", 1000)), g[999])
}
