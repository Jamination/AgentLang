// Runge-Kutta 4 on two systems: Lorenz (3 vars) and a damped driven-free double well (2 vars)
struct S3 { x: f64, y: f64, z: f64 }

fn lorenz(s: S3) -> S3 {
    S3{10.0 * (s.y - s.x), s.x * (28.0 - s.z) - s.y, s.x * s.y - 8.0 / 3.0 * s.z}
}

fn axpy(a: S3, h: f64, b: S3) -> S3 {
    S3{a.x + h * b.x, a.y + h * b.y, a.z + h * b.z}
}

fn rk4_step(s: S3, h: f64) -> S3 {
    k1 := lorenz(s)
    k2 := lorenz(axpy(s, h * 0.5, k1))
    k3 := lorenz(axpy(s, h * 0.5, k2))
    k4 := lorenz(axpy(s, h, k3))
    h6 := h / 6.0
    S3{
        s.x + h6 * (k1.x + 2.0 * k2.x + 2.0 * k3.x + k4.x),
        s.y + h6 * (k1.y + 2.0 * k2.y + 2.0 * k3.y + k4.y),
        s.z + h6 * (k1.z + 2.0 * k2.z + 2.0 * k3.z + k4.z)
    }
}

fn well(x: f64, v: f64) -> (f64, f64) {
    (v, x - x * x * x - 0.1 * v)
}

fn rk4_well(x: f64, v: f64, h: f64) -> (f64, f64) {
    a1, b1 := well(x, v)
    a2, b2 := well(x + 0.5 * h * a1, v + 0.5 * h * b1)
    a3, b3 := well(x + 0.5 * h * a2, v + 0.5 * h * b2)
    a4, b4 := well(x + h * a3, v + h * b3)
    (x + h / 6.0 * (a1 + 2.0 * a2 + 2.0 * a3 + a4), v + h / 6.0 * (b1 + 2.0 * b2 + 2.0 * b3 + b4))
}

fn main() {
    s := S3{1.0, 1.0, 1.0}
    h: f64 = 0.0005
    acc: f64 = 0.0
    for i in 0..8000000 {
        s = rk4_step(s, h)
        acc += s.z
    }
    x: f64 = 0.5
    v: f64 = 1.2
    for i in 0..8000000 {
        x, v = rk4_well(x, v, 0.001)
    }
    print(cast[u64](s.x), cast[u64](s.y), cast[u64](s.z), cast[u64](acc), cast[u64](x), cast[u64](v))
}
