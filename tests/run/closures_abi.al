// closure calls with many arguments: more than six integers, floats, vectors, structs by
// value and by reference, struct results; plain functions called through closure values
struct P { x i64, y i64 }
struct Big { a i64, b i64, c i64, d i64, e i64, f f64 }
struct V3 { x f64, y f64, z f64 }

fn many(f |i64, i64, i64, i64, i64, i64, i64, i64| i64) i64 { f(1, 2, 3, 4, 5, 6, 7, 8) }
fn plain8(a i64, b i64, c i64, d i64, e i64, f i64, g i64, h i64) i64 {
    a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h
}
fn six(f |i64, i64, i64, i64, i64, i64| i64) i64 { f(1, 2, 3, 4, 5, 6) }
fn plain6(a i64, b i64, c i64, d i64, e i64, f i64) i64 { a - b + c - d + e - f }
fn five(f |i64, i64, i64, i64, i64| i64) i64 { f(1, 2, 3, 4, 5) }
fn plain5(a i64, b i64, c i64, d i64, e i64) i64 { a * b + c * d + e }
fn mixed(f |f64, i64, vec3, P, Big, str, f32| Big) Big {
    f(1.5, 2, vec3(1.0, 2.0, 3.0), P{3, 4}, Big{1, 2, 3, 4, 5, 6.5}, "hey", 0.25)
}
fn plain_mixed(a f64, b i64, v vec3, p P, g Big, s str, h f32) Big {
    Big{b, p.x, p.y, g.e, len(s), a + f64(v.z) + g.f + f64(h)}
}
fn floats(f |f64, f64, f64, f64, f64, f64, f64, f64, f64, f64| f64) f64 {
    f(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0)
}
fn plain_floats(a f64, b f64, c f64, d f64, e f64, f f64, g f64, h f64, i f64, j f64) f64 {
    a + b * 2.0 + c + d + e + f + g + h + i * 3.0 + j
}
// struct result through a hidden pointer, plus seven integers
fn sret7(f |i64, i64, i64, i64, i64, i64, i64| Big) Big { f(1, 2, 3, 4, 5, 6, 7) }
fn plain_sret7(a i64, b i64, c i64, d i64, e i64, f i64, g i64) Big { Big{a, b, c, d + e, f + g, 0.5} }
fn small(f |P, V3| P) P { f(P{1, 2}, V3{1.0, 2.0, 3.0}) }
fn plain_small(p P, v V3) P { P{p.x + i64(v.z), p.y + i64(v.x)} }
fn vecs(f |vec2, vec3, vec4, quat, mat4| vec4) vec4 {
    f(vec2(1.0, 2.0), vec3(3.0, 4.0, 5.0), vec4(6.0, 7.0, 8.0, 9.0), quat(0.0, 0.0, 0.0, 1.0), mat4(2.0))
}
fn plain_vecs(a vec2, b vec3, c vec4, q quat, m mat4) vec4 { m * (c + vec4(a, b.x, b.z)) * q.w }
fn strs(f |str, []i64, (i64, f64), *P| str) str {
    p := P{8, 9}
    f("s", []i64{1, 2}, (3, 4.5), &p)
}
fn plain_strs(s str, xs []i64, t (i64, f64), p *P) str { fmt(s, xs, t, p.x + p.y) }

fn main() {
    w := 1000
    off := 0.5
    print(many(plain8), many(|a i64, b i64, c i64, d i64, e i64, f i64, g i64, h i64| i64 { a + b + c + d + e + f + g + h + w }))
    print(six(plain6), six(|a i64, b i64, c i64, d i64, e i64, f i64| i64 { a + b + c + d + e + f + w }))
    print(five(plain5), five(|a i64, b i64, c i64, d i64, e i64| i64 { a + b + c + d + e + w }))
    print(mixed(plain_mixed))
    print(mixed(|a f64, b i64, v vec3, p P, g Big, s str, h f32| Big {
        Big{b + w, p.x, p.y, g.e, len(s), a + f64(v.z) + g.f + f64(h) + off}
    }))
    print(floats(plain_floats), floats(|a f64, b f64, c f64, d f64, e f64, f f64, g f64, h f64, i f64, j f64| f64 {
        a + b * 2.0 + c + d + e + f + g + h + i * 3.0 + j + off
    }))
    print(sret7(plain_sret7))
    print(sret7(|a i64, b i64, c i64, d i64, e i64, f i64, g i64| Big { Big{a + w, b, c, d + e, f + g, off} }))
    print(small(plain_small), small(|p P, v V3| P { P{p.x + w, p.y + i64(v.y + off)} }))
    print(vecs(plain_vecs))
    sc := vec4(0.5)
    print(vecs(|a vec2, b vec3, c vec4, q quat, m mat4| vec4 { m * c * sc + vec4(a, b.x, q.w) }))
    print(strs(plain_strs), strs(|s str, xs []i64, t (i64, f64), p *P| str { fmt(w, s, len(xs), t.1, p.y) }))
    // the same closure value called many times in a loop, alternating targets
    cs := []|i64, i64, i64, i64, i64, i64, i64, i64| i64{plain8, |a i64, b i64, c i64, d i64, e i64, f i64, g i64, h i64| i64 { h - a + w }}
    acc := 0
    for i in 0..1000 {
        acc += cs[i % 2](i, 1, 1, 1, 1, 1, 1, i + 1)
    }
    print(acc)
}
