// small structs passed and returned by value through layers of helpers:
// a 3-vector particle integrator and complex-number Julia iteration

struct V3 { x: f64, y: f64, z: f64 }
struct Body { p: V3, v: V3 }
struct Cx { re: f64, im: f64 }

fn add(a: V3, b: V3) -> V3 { V3{a.x + b.x, a.y + b.y, a.z + b.z} }
fn sub(a: V3, b: V3) -> V3 { V3{a.x - b.x, a.y - b.y, a.z - b.z} }
fn scale(a: V3, s: f64) -> V3 { V3{a.x * s, a.y * s, a.z * s} }
fn dot(a: V3, b: V3) -> f64 { a.x * b.x + a.y * b.y + a.z * b.z }
fn cross(a: V3, b: V3) -> V3 { V3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x} }

fn accel(p: V3, axis: V3) -> V3 {
    r2 := dot(p, p) + 0.01
    add(scale(p, -1.0 / r2), scale(cross(axis, p), 0.001))
}

fn step(b: Body, axis: V3, dt: f64) -> Body {
    v := add(b.v, scale(accel(b.p, axis), dt))
    Body{add(b.p, scale(v, dt)), v}
}

fn cmul(a: Cx, b: Cx) -> Cx { Cx{a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re} }
fn cadd(a: Cx, b: Cx) -> Cx { Cx{a.re + b.re, a.im + b.im} }
fn norm2(a: Cx) -> f64 { a.re * a.re + a.im * a.im }

fn julia(z0: Cx, c: Cx, limit: i64) -> i64 {
    z := z0
    for i in 0..limit {
        if norm2(z) > 4.0 { return i }
        z = cadd(cmul(z, z), c)
    }
    limit
}

fn main() {
    axis := V3{0.0, 0.0, 1.0}
    bodies := alloc[Body](64)
    for i in 0..64 {
        f := f64(i)
        bodies[i] = Body{V3{1.0 + f * 0.01, 0.5, -0.25}, V3{0.0, 0.8 - f * 0.005, 0.1}}
    }
    for s in 0..1000000 {
        for i in 0..64 { bodies[i] = step(bodies[i], axis, 0.001) }
    }
    e: f64 = 0.0
    for b in bodies { e += dot(b.v, b.v) + dot(b.p, b.p) }
    c := Cx{-0.8, 0.156}
    iters := 0
    for y in 0..1200 {
        for x in 0..1200 {
            z := Cx{f64(x) * (3.0 / 1200.0) - 1.5, f64(y) * (3.0 / 1200.0) - 1.5}
            iters += julia(z, c, 200)
        }
    }
    put(fmtf(e, 6), " ", iters, "\n")
}
