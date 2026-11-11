Big :: struct { a: i64, b: i64, c: i64, d: i64, e: f64, f: f64 }
V3 :: struct { x: f64, y: f64, z: f64 }
Mixed :: struct { n: i32, f: f64, b: bool, c: u8 }

many :: (a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, i: i64, j: i64) -> i64 {
    a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10
}
manyf :: (a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, i: f64, j: f64) -> f64 {
    a + b * 2.0 + c * 3.0 + d * 4.0 + e * 5.0 + f * 6.0 + g * 7.0 + h * 8.0 + i * 9.0 + j * 10.0
}
mixed :: (a: i64, x: f64, b: i64, y: f64, c: i64, z: f64, d: i64, w: f64, e: i64, v: f64, f: i64, u: f64, g: i64, t: f64, h: i64, s: f64, i: i64, r: f64) -> f64 {
    f64(a + b + c + d + e + f + g + h + i) + x + y + z + w + v + u + t + s + r
}
noinline big_ret :: (k: i64) -> Big {
    Big{k, k + 1, k + 2, k + 3, f64(k) * 0.5, f64(k) * 0.25}
}
noinline big_arg :: (b: Big, scale: i64) -> i64 {
    (b.a + b.b + b.c + b.d) * scale + i64(b.e + b.f)
}
noinline cross :: (a: V3, b: V3) -> V3 {
    V3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}
noinline mixed_ret :: (i: i32) -> Mixed {
    Mixed{n: i * 3, f: f64(i) / 4.0, b: i % 2 == 0, c: u8(i + 200)}
}
noinline pair :: (a: i64, b: f64) -> (f64, i64) {
    (b * 2.0, a * 2)
}
noinline rec_f :: (n: i64, acc: f64) -> f64 {
    if n == 0 {
        return acc
    }
    x := rec_f(n - 1, acc + f64(n))
    x * 1.0001 + acc
}
noinline ack :: (m: i64, n: i64) -> i64 {
    if m == 0 {
        return n + 1
    }
    if n == 0 {
        return ack(m - 1, 1)
    }
    ack(m - 1, ack(m, n - 1))
}
apply3 :: (f: (i64, i64, i64) -> i64, a: i64) -> i64 {
    f(a, a + 1, a + 2)
}
add3 :: (a: i64, b: i64, c: i64) -> i64 { a * 100 + b * 10 + c }

main :: () {
    print(many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10))
    print(manyf(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0))
    print(mixed(1, 0.5, 2, 0.25, 3, 0.125, 4, 1.5, 5, 2.5, 6, 3.5, 7, 4.5, 8, 5.5, 9, 6.5))
    b := big_ret(10)
    print(b, big_arg(b, 3))
    c := cross(V3{1.0, 2.0, 3.0}, V3{4.0, 5.0, 6.0})
    print(c)
    m := mixed_ret(7)
    print(m, mixed_ret(8).b)
    f, i := pair(21, 1.5)
    print(f, i)
    putf(rec_f(10, 0.5), 6)
    putc('\n')
    print(ack(2, 3), apply3(add3, 4))
}
