struct P { x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, m: f64, hits: i64 }

fn step(ps: []P, dt: f64, k: f64) {
    for i in 0..len(ps) {
        p := &ps[i]
        p.vx += (0.0 - p.x * k) * dt / p.m
        p.vy += (0.0 - p.y * k - 9.81) * dt / p.m
        p.vz += (0.0 - p.z * k) * dt / p.m
        p.x += p.vx * dt
        p.y += p.vy * dt
        p.z += p.vz * dt
        if p.y < -1.0 {
            p.y = -1.0
            p.vy = 0.0 - p.vy * 0.9
            p.hits += 1
        }
    }
}

fn main() {
    n := 200000
    ps := alloc[P](n)
    seed: u64 = 12345
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        ps[i].x = f64(i64(seed >> 40)) / 16777216.0 - 0.5
        seed = seed * 6364136223846793005 + 1442695040888963407
        ps[i].y = f64(i64(seed >> 40)) / 16777216.0
        seed = seed * 6364136223846793005 + 1442695040888963407
        ps[i].z = f64(i64(seed >> 40)) / 16777216.0 - 0.5
        ps[i].m = 1.0 + f64(i % 7)
    }
    for s in 0..1000 {
        step(ps, 0.001, 3.0)
    }
    sx: f64 = 0.0
    hits := 0
    for p in ps {
        sx += p.x + p.y + p.z + p.vx + p.vy + p.vz
        hits += p.hits
    }
    put(i64(sx * 1000.0), " ", hits, "\n")
}
