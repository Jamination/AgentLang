struct V3 { x: f64, y: f64, z: f64 }
struct Ball { c: V3, r: f64, refl: f64 }
struct Hit { t: f64, idx: i64 }

fn add(a: V3, b: V3) -> V3 { V3{a.x + b.x, a.y + b.y, a.z + b.z} }
fn sub(a: V3, b: V3) -> V3 { V3{a.x - b.x, a.y - b.y, a.z - b.z} }
fn scale(a: V3, s: f64) -> V3 { V3{a.x * s, a.y * s, a.z * s} }
fn dot(a: V3, b: V3) -> f64 { a.x * b.x + a.y * b.y + a.z * b.z }
fn normalize(a: V3) -> V3 { scale(a, 1.0 / sqrt(dot(a, a))) }

const LIGHT = V3{-5.0, 8.0, -3.0}

fn intersect(balls: []Ball, o: V3, d: V3) -> Hit {
    best := Hit{1e30, -1}
    for i in 0..len(balls) {
        oc := sub(o, balls[i].c)
        b := dot(oc, d)
        c := dot(oc, oc) - balls[i].r * balls[i].r
        disc := b * b - c
        if disc > 0.0 {
            s := sqrt(disc)
            t := -b - s
            if t < 1e-6 {
                t = -b + s
            }
            if t > 1e-6 && t < best.t {
                best = Hit{t, i}
            }
        }
    }
    best
}

fn trace(balls: []Ball, o0: V3, d0: V3) -> f64 {
    o := o0
    d := d0
    color: f64 = 0.0
    weight: f64 = 1.0
    for depth in 0..4 {
        h := intersect(balls, o, d)
        if h.idx < 0 {
            color += weight * 0.25 * (d.y + 1.0)
            break
        }
        p := add(o, scale(d, h.t))
        n := normalize(sub(p, balls[h.idx].c))
        l := normalize(sub(LIGHT, p))
        diff := dot(n, l)
        if diff < 0.0 {
            diff = 0.0
        }
        q := add(p, scale(n, 1e-4))
        if diff > 0.0 {
            sh := intersect(balls, q, l)
            if sh.idx >= 0 {
                diff *= 0.2
            }
        }
        refl := balls[h.idx].refl
        color += weight * (1.0 - refl) * diff
        weight *= refl
        if weight < 0.01 {
            break
        }
        d = normalize(sub(d, scale(n, 2.0 * dot(d, n))))
        o = q
    }
    color
}

fn main() {
    balls := alloc[Ball](10)
    k := 0
    for gz in 0..3 {
        for gx in 0..3 {
            cx := f64(gx - 1) * 2.2
            cz := 4.0 + f64(gz) * 2.2
            r := 0.6 + f64((gx + gz) % 3) * 0.2
            balls[k] = Ball{V3{cx, 0.0 + r - 1.0, cz}, r, f64(k % 4) * 0.25}
            k += 1
        }
    }
    balls[9] = Ball{V3{0.0, -1001.0, 5.0}, 1000.0, 0.1}
    w := 2400
    h := 1800
    sum: f64 = 0.0
    eye := V3{0.0, 1.0, -3.0}
    for y in 0..h {
        for x in 0..w {
            dx := (f64(x) - f64(w) * 0.5) / f64(h)
            dy := (f64(h) * 0.5 - f64(y)) / f64(h)
            d := normalize(V3{dx, dy - 0.2, 1.0})
            sum += trace(balls, eye, d)
        }
    }
    print(cast[u64](sum), i64(sum))
}
