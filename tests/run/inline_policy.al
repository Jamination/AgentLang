// call sites the inliner weighs by their benefit (aggregates by value, constant arguments that
// the callee compares, calls in loops, leaf callees) and by their coldness (a block that only
// leads to a trap): the results must not depend on what was inlined
struct Quat { x: f64, y: f64, z: f64, w: f64 }
struct Hit { t: f64, idx: i64 }

fn qmul(a: Quat, b: Quat) -> Quat {
    Quat{
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
    }
}

fn rot(q: Quat, v: Quat) -> Quat { qmul(qmul(q, v), Quat{-q.x, -q.y, -q.z, q.w}) }

// constant width and height: loop bounds once inlined
fn blur(src: []i64, dst: []i64, w: i64, h: i64) {
    for y in 1..h - 1 {
        for x in 1..w - 1 {
            i := y * w + x
            dst[i] = (src[i - 1] + src[i] + src[i + 1] + src[i - w] + src[i + w]) / 5
        }
    }
}

fn best(ts: []f64) -> Hit {
    h := Hit{1e30, -1}
    for i in 0..len(ts) {
        if ts[i] > 0.0 && ts[i] < h.t {
            h = Hit{ts[i], i}
        }
    }
    h
}

fn describe(k: i64) -> str { fmt("value ", k, " out of range [0, ", 100, ")") }

fn checked(k: i64) -> i64 {
    if k < 0 || k >= 100 {
        // a cold path: only leads to the panic
        panic(describe(k))
    }
    return k * 2
}

fn main() {
    q := Quat{0.0, 0.0, 0.0, 1.0}
    d := Quat{0.01, 0.02, 0.015, 0.9997}
    for i in 0..1000 {
        q = qmul(q, d)
    }
    r := rot(q, Quat{1.0, 2.0, 3.0, 0.0})
    print(i64(q.w * 1e6), i64(r.x * 1e6), i64(r.y * 1e6), i64(r.z * 1e6))
    w := 18
    h := 12
    a := alloc[i64](w * h)
    b := alloc[i64](w * h)
    for i in 0..w * h {
        a[i] = (i * 37) % 101
    }
    for g in 0..10 {
        if g % 2 == 0 { blur(a, b, w, h) } else { blur(b, a, w, h) }
    }
    s := 0
    for i in 0..w * h {
        s += a[i] * (i + 1)
    }
    print(s)
    ts := []f64{3.5, -1.0, 2.25, 9.0, 2.5}
    hit := best(ts)
    print(hit.t, hit.idx)
    t := 0
    for k in 0..100 {
        t += checked(k)
    }
    print(t)
}
