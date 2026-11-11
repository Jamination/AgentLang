// nested functions with many parameters next to the hidden ones: more than six integers,
// floats, vectors, structs by value and by reference, struct results
struct P { x i64, y i64 }
struct Big { a i64, b i64, c i64, d i64, e i64, f f64 }
struct V3 { x f64, y f64, z f64 }

fn main() {
    w := 1000
    off := 0.5
    hits := 0
    scale := vec4(0.5)
    tag := "t"
    fn m8(a i64, b i64, c i64, d i64, e i64, f i64, g i64, h i64) i64 {
        hits += 1
        a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + w
    }
    fn m6(a i64, b i64, c i64, d i64, e i64, f i64) i64 { hits += 1; a - b + c - d + e - f + w }
    fn m5(a i64, b i64, c i64, d i64, e i64) i64 { hits += 1; a * b + c * d + e + w }
    fn mixed(a f64, b i64, v vec3, p P, g Big, s str, h f32) Big {
        w += 1
        Big{b + w, p.x, p.y, g.e, len(s) + len(tag), a + f64(v.z) + g.f + f64(h) + off}
    }
    fn floats(a f64, b f64, c f64, d f64, e f64, f f64, g f64, h f64, i f64, j f64) f64 {
        hits += 1
        a + b * 2.0 + c + d + e + f + g + h + i * 3.0 + j + off
    }
    fn sret7(a i64, b i64, c i64, d i64, e i64, f i64, g i64) Big { Big{a + w, b, c, d + e, f + g, off} }
    fn small(p P, v V3) P { P{p.x + w, p.y + i64(v.y + off)} }
    fn vecs(a vec2, b vec3, c vec4, q quat, m mat4) vec4 { hits += 1; m * c * scale + vec4(a, b.x, q.w) }
    fn strs(s str, xs []i64, t (i64, f64), p *P) str { p.x += 1; fmt(w, s, len(xs), t.1, p.y, tag) }
    print(m8(1, 2, 3, 4, 5, 6, 7, 8), m6(1, 2, 3, 4, 5, 6), m5(1, 2, 3, 4, 5))
    print(mixed(1.5, 2, vec3(1.0, 2.0, 3.0), P{3, 4}, Big{1, 2, 3, 4, 5, 6.5}, "hey", 0.25))
    print(floats(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0))
    print(sret7(1, 2, 3, 4, 5, 6, 7), small(P{1, 2}, V3{1.0, 2.0, 3.0}))
    print(vecs(vec2(1.0, 2.0), vec3(3.0, 4.0, 5.0), vec4(6.0, 7.0, 8.0, 9.0), quat(0.0, 0.0, 0.0, 1.0), mat4(2.0)))
    q := P{8, 9}
    print(strs("s", []i64{1, 2}, (3, 4.5), &q), q, hits, w)
    // called in a loop, more hidden parameters than registers
    a1 := 1
    a2 := 2
    a3 := 3
    a4 := 4
    a5 := 5
    a6 := 6
    a7 := 7
    fn all7(x i64, y f64) f64 {
        a1 += x
        a7 += a1 % 3
        f64(a1 + a2 + a3 + a4 + a5 + a6 + a7) + y
    }
    acc := 0.0
    for i in 0..1000 {
        acc += all7(i, 0.5)
    }
    print(acc, a1, a7)
}
