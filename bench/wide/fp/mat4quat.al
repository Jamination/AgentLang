// 4x4 matrices and quaternions on small fixed-size f64 arrays / structs
struct M4 { m: [16]f64 }
struct Quat { x: f64, y: f64, z: f64, w: f64 }
struct V3 { x: f64, y: f64, z: f64 }

fn mul(a: M4, b: M4) -> M4 {
    r: M4
    for i in 0..4 {
        for j in 0..4 {
            s: f64 = 0.0
            for k in 0..4 {
                s += a.m[i * 4 + k] * b.m[k * 4 + j]
            }
            r.m[i * 4 + j] = s
        }
    }
    r
}

fn qmul(a: Quat, b: Quat) -> Quat {
    Quat{
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
    }
}

fn qnormalize(q: Quat) -> Quat {
    inv := 1.0 / sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
    Quat{q.x * inv, q.y * inv, q.z * inv, q.w * inv}
}

fn to_matrix(q: Quat, t: V3) -> M4 {
    r: M4
    r.m[0] = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    r.m[1] = 2.0 * (q.x * q.y - q.z * q.w)
    r.m[2] = 2.0 * (q.x * q.z + q.y * q.w)
    r.m[3] = t.x
    r.m[4] = 2.0 * (q.x * q.y + q.z * q.w)
    r.m[5] = 1.0 - 2.0 * (q.x * q.x + q.z * q.z)
    r.m[6] = 2.0 * (q.y * q.z - q.x * q.w)
    r.m[7] = t.y
    r.m[8] = 2.0 * (q.x * q.z - q.y * q.w)
    r.m[9] = 2.0 * (q.y * q.z + q.x * q.w)
    r.m[10] = 1.0 - 2.0 * (q.x * q.x + q.y * q.y)
    r.m[11] = t.z
    r.m[15] = 1.0
    r
}

fn transform(m: M4, p: V3) -> V3 {
    V3{
        m.m[0] * p.x + m.m[1] * p.y + m.m[2] * p.z + m.m[3],
        m.m[4] * p.x + m.m[5] * p.y + m.m[6] * p.z + m.m[7],
        m.m[8] * p.x + m.m[9] * p.y + m.m[10] * p.z + m.m[11]
    }
}

fn rotate(q: Quat, v: V3) -> V3 {
    // v' = q * (v, 0) * conj(q)
    p := qmul(qmul(q, Quat{v.x, v.y, v.z, 0.0}), Quat{-q.x, -q.y, -q.z, q.w})
    V3{p.x, p.y, p.z}
}

fn main() {
    q := Quat{0.0, 0.0, 0.0, 1.0}
    dq := qnormalize(Quat{0.001, 0.002, 0.0015, 1.0})
    acc: M4
    for i in 0..4 {
        acc.m[i * 4 + i] = 1.0
    }
    pts: [8]V3
    for i in 0..8 {
        pts[i] = V3{f64(i) * 0.5, 1.0 - f64(i) * 0.25, f64(i % 3)}
    }
    sx: f64 = 0.0
    sy: f64 = 0.0
    sz: f64 = 0.0
    for it in 0..6000000 {
        q = qnormalize(qmul(q, dq))
        r := to_matrix(q, V3{0.001, -0.002, 0.0005})
        acc = mul(r, acc)
        if it % 64 == 63 {
            // keep acc bounded: reset to the latest rotation
            acc = r
        }
        p := pts[it & 7]
        a := transform(acc, p)
        b := rotate(q, p)
        sx += a.x + b.x
        sy += a.y + b.y
        sz += a.z + b.z
    }
    print(cast[u64](sx), cast[u64](sy), cast[u64](sz), cast[u64](q.w))
}
