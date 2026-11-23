struct Soa { x: []f64, y: []f64, z: []f64, vx: []f64, vy: []f64, vz: []f64, m: []f64, hits: []i64 }

fn step(s: *Soa, dt: f64, k: f64) {
    for i in 0..len(s.x) {
        s.vx[i] += (0.0 - s.x[i] * k) * dt / s.m[i]
        s.vy[i] += (0.0 - s.y[i] * k - 9.81) * dt / s.m[i]
        s.vz[i] += (0.0 - s.z[i] * k) * dt / s.m[i]
        s.x[i] += s.vx[i] * dt
        s.y[i] += s.vy[i] * dt
        s.z[i] += s.vz[i] * dt
        if s.y[i] < -1.0 {
            s.y[i] = -1.0
            s.vy[i] = 0.0 - s.vy[i] * 0.9
            s.hits[i] += 1
        }
    }
}

fn main() {
    n := 200000
    s := Soa{alloc[f64](n), alloc[f64](n), alloc[f64](n), alloc[f64](n), alloc[f64](n), alloc[f64](n), alloc[f64](n), alloc[i64](n)}
    seed: u64 = 12345
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        s.x[i] = f64(i64(seed >> 40)) / 16777216.0 - 0.5
        seed = seed * 6364136223846793005 + 1442695040888963407
        s.y[i] = f64(i64(seed >> 40)) / 16777216.0
        seed = seed * 6364136223846793005 + 1442695040888963407
        s.z[i] = f64(i64(seed >> 40)) / 16777216.0 - 0.5
        s.m[i] = 1.0 + f64(i % 7)
    }
    for t in 0..1000 {
        step(&s, 0.001, 3.0)
    }
    sx: f64 = 0.0
    hits := 0
    for i in 0..n {
        sx += s.x[i] + s.y[i] + s.z[i] + s.vx[i] + s.vy[i] + s.vz[i]
        hits += s.hits[i]
    }
    put(i64(sx * 1000.0), " ", hits, "\n")
}
