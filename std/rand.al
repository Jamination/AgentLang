// std.rand: seedable random numbers (xoshiro256**), geometric helpers and hash-based noise.
// Core module: available in every program. Everything is deterministic: the same seed gives
// the same sequence on every run and in every build mode. Nothing here allocates.

// Generator state (xoshiro256**, period 2^256 - 1). Create it with rng(seed); the all-zero
// state is invalid. Copying an Rng forks the sequence.
struct Rng { s0: u64, s1: u64, s2: u64, s3: u64 }

priv fn splitmix(x: *u64) -> u64 {
    *x += 0x9e3779b97f4a7c15
    z := *x
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ^ (z >> 27)) * 0x94d049bb133111eb
    return z ^ (z >> 31)
}

// a generator whose sequence is fully determined by `seed` (state expanded with splitmix64)
fn rng(seed: u64) -> Rng {
    r: Rng
    r.s0 = splitmix(&seed)
    r.s1 = splitmix(&seed)
    r.s2 = splitmix(&seed)
    r.s3 = splitmix(&seed)
    return r
}

// the next 64 uniformly distributed bits
fn next_u64(r: *Rng) -> u64 {
    out := rotl(r.s1 * 5, 7) * 9
    t := r.s1 << 17
    r.s2 ^= r.s0
    r.s3 ^= r.s1
    r.s1 ^= r.s2
    r.s0 ^= r.s3
    r.s2 ^= t
    r.s3 = rotl(r.s3, 45)
    return out
}

// the next 32 uniformly distributed bits (the high half of next_u64)
fn next_u32(r: *Rng) -> u32 {
    return u32(next_u64(r) >> 32)
}

// uniform f32 in [0, 1) with 24 random bits
fn next_f32(r: *Rng) -> f32 {
    return f32(i64(next_u64(r) >> 40)) * (1.0 / 16777216.0)
}

// uniform f64 in [0, 1) with 53 random bits
fn next_f64(r: *Rng) -> f64 {
    return f64(i64(next_u64(r) >> 11)) * (1.0 / 9007199254740992.0)
}

// unbiased uniform integer in [0, n); n must not be 0
fn below(r: *Rng, n: u64) -> u64 {
    assert n != 0, "below: empty range"
    if n <= 0xFFFFFFFF {
        // Lemire's multiply-and-reject on 32 bits: no division in the common case
        m := (next_u64(r) >> 32) * n
        if (m & 0xFFFFFFFF) < n {
            t := (0x100000000 - n) % n
            while (m & 0xFFFFFFFF) < t {
                m = (next_u64(r) >> 32) * n
            }
        }
        return m >> 32
    }
    mask := ~u64(0) >> u64(clz(n - 1))
    loop {
        x := next_u64(r) & mask
        if x < n {
            return x
        }
    }
}

// unbiased uniform integer in [lo, hi); requires lo < hi
fn range(r: *Rng, lo: i64, hi: i64) -> i64 {
    assert lo < hi, "range: lo must be less than hi"
    return lo + i64(below(r, u64(hi) - u64(lo)))
}

// uniform f32 in [lo, hi)
fn range(r: *Rng, lo: f32, hi: f32) -> f32 {
    span := hi - lo
    loop {
        v := lo + span * next_f32(r)
        // rounding can give hi itself: draw again (not for an empty or infinite range)
        if v < hi || !(span > 0.0 && span - span == 0.0) {
            return v
        }
    }
}

// true with probability p (p <= 0: never, p >= 1: always)
fn chance(r: *Rng, p: f32) -> bool {
    return next_f32(r) < p
}

// reorders xs uniformly at random (Fisher-Yates)
fn shuffle[T](r: *Rng, xs: []T) {
    for i in len(xs) - 1..=1 by -1 {
        j := i64(below(r, u64(i + 1)))
        t := xs[i]
        xs[i] = xs[j]
        xs[j] = t
    }
}

// a uniformly chosen element of xs, which must not be empty
fn pick[T](r: *Rng, xs: []T) -> T {
    assert len(xs) > 0, "pick: empty slice"
    return xs[i64(below(r, u64(len(xs))))]
}

// uniform point inside the unit disc (rejection sampling)
fn in_circle(r: *Rng) -> vec2 {
    loop {
        x := next_f32(r) * 2.0 - 1.0
        y := next_f32(r) * 2.0 - 1.0
        if x * x + y * y < 1.0 {
            return vec2(x, y)
        }
    }
}

// uniform point inside the unit ball (rejection sampling)
fn in_sphere(r: *Rng) -> vec3 {
    loop {
        x := next_f32(r) * 2.0 - 1.0
        y := next_f32(r) * 2.0 - 1.0
        z := next_f32(r) * 2.0 - 1.0
        if x * x + y * y + z * z < 1.0 {
            return vec3(x, y, z)
        }
    }
}

// uniform direction in the plane (length 1)
fn unit_vec2(r: *Rng) -> vec2 {
    loop {
        p := in_circle(r)
        d := p.x * p.x + p.y * p.y
        if d > 0.0001 {
            return p / sqrt(d)
        }
    }
}

// uniform direction in space (length 1; Marsaglia's method)
fn unit_vec3(r: *Rng) -> vec3 {
    p := in_circle(r)
    d := p.x * p.x + p.y * p.y
    k := 2.0 * sqrt(1.0 - d)
    return vec3(p.x * k, p.y * k, 1.0 - 2.0 * d)
}

// normally distributed value with the given mean and standard deviation (Marsaglia polar method)
fn normal(r: *Rng, mean: f32, stddev: f32) -> f32 {
    loop {
        u := next_f64(r) * 2.0 - 1.0
        v := next_f64(r) * 2.0 - 1.0
        s := u * u + v * v
        if s < 1.0 && s > 0.0 {
            return mean + stddev * f32(u * sqrt(-2.0 * log(s) / s))
        }
    }
}

// ---------- default generator ----------
// One process-wide generator for code that does not care about reproducible streams per
// subsystem. It starts in the state of rng(0), so unseeded programs are deterministic too.
priv default_rng := Rng{s0: 0xe220a8397b1dcdaf, s1: 0x6e789e6aa1b965f4, s2: 0x06c45d188009454f, s3: 0xf88bb8a8724c81ec}

// restarts the default generator from `seed`
fn rand_seed(seed: u64) {
    default_rng = rng(seed)
}

// next 64 bits of the default generator
fn rand_u64() -> u64 {
    return next_u64(&default_rng)
}

// uniform f32 in [0, 1) from the default generator
fn rand_f32() -> f32 {
    return next_f32(&default_rng)
}

// unbiased uniform integer in [lo, hi) from the default generator
fn rand_range(lo: i64, hi: i64) -> i64 {
    return range(&default_rng, lo, hi)
}

// uniform f32 in [lo, hi) from the default generator
fn rand_range(lo: f32, hi: f32) -> f32 {
    return range(&default_rng, lo, hi)
}

// ---------- noise ----------
// well-mixed 32-bit hash of an integer lattice point and a seed
fn noise_hash(x: i64, y: i64, z: i64, seed: u32) -> u32 {
    h := (u32(x) * 0x8da6b343 ^ u32(y) * 0xd8163841 ^ u32(z) * 0xcb1ab31f ^ seed * 0x9e3779b9) + 0x2545f491
    h = (h ^ (h >> 16)) * 0x7feb352d
    h = (h ^ (h >> 15)) * 0x846ca68b
    return h ^ (h >> 16)
}

priv inline fn ifloor(x: f32) -> i64 {
    i := i64(x)
    if f32(i) > x { i - 1 } else { i }
}

priv inline fn fade(t: f32) -> f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

// dot product of the offset (dx, dy) with the pseudo-random gradient of lattice point (ix, iy)
priv inline fn grad2(ix: i64, iy: i64, seed: u32, dx: f32, dy: f32) -> f32 {
    h := noise_hash(ix, iy, 0, seed)
    gx := f32(i64(h & 0xFFFF)) * (1.0 / 32768.0) - 1.0
    gy := f32(i64(h >> 16)) * (1.0 / 32768.0) - 1.0
    return gx * dx + gy * dy
}

priv inline fn grad3(ix: i64, iy: i64, iz: i64, seed: u32, dx: f32, dy: f32, dz: f32) -> f32 {
    h := noise_hash(ix, iy, iz, seed)
    gx := f32(i64(h & 0x3FF)) * (1.0 / 512.0) - 1.0
    gy := f32(i64((h >> 10) & 0x3FF)) * (1.0 / 512.0) - 1.0
    gz := f32(i64(h >> 22)) * (1.0 / 512.0) - 1.0
    return gx * dx + gy * dy + gz * dz
}

// 2D gradient noise in [-1, 1]: smooth, 0 at integer points, one feature per unit; `seed`
// selects an independent noise field
fn noise2(x: f32, y: f32, seed: u32) -> f32 {
    ix := ifloor(x)
    iy := ifloor(y)
    fx := x - f32(ix)
    fy := y - f32(iy)
    u := fade(fx)
    a := grad2(ix, iy, seed, fx, fy)
    b := grad2(ix + 1, iy, seed, fx - 1.0, fy)
    c := grad2(ix, iy + 1, seed, fx, fy - 1.0)
    d := grad2(ix + 1, iy + 1, seed, fx - 1.0, fy - 1.0)
    lo := a + (b - a) * u
    hi := c + (d - c) * u
    return lo + (hi - lo) * fade(fy)
}

// 2D gradient noise with seed 0
fn noise2(x: f32, y: f32) -> f32 {
    return noise2(x, y, 0)
}

// 3D gradient noise in [-1, 1] (use z as time for animated 2D fields)
fn noise3(x: f32, y: f32, z: f32, seed: u32) -> f32 {
    ix := ifloor(x)
    iy := ifloor(y)
    iz := ifloor(z)
    fx := x - f32(ix)
    fy := y - f32(iy)
    fz := z - f32(iz)
    u := fade(fx)
    v := fade(fy)
    plane: [2]f32
    for k in 0..2 {
        dz := fz - f32(k)
        a := grad3(ix, iy, iz + k, seed, fx, fy, dz)
        b := grad3(ix + 1, iy, iz + k, seed, fx - 1.0, fy, dz)
        c := grad3(ix, iy + 1, iz + k, seed, fx, fy - 1.0, dz)
        d := grad3(ix + 1, iy + 1, iz + k, seed, fx - 1.0, fy - 1.0, dz)
        lo := a + (b - a) * u
        hi := c + (d - c) * u
        plane[k] = lo + (hi - lo) * v
    }
    return (plane[0] + (plane[1] - plane[0]) * fade(fz)) * (2.0 / 3.0)
}

// 3D gradient noise with seed 0
fn noise3(x: f32, y: f32, z: f32) -> f32 {
    return noise3(x, y, z, 0)
}

// fractal sum of `octaves` layers of noise2 (each twice the frequency and half the amplitude
// of the previous one), normalized to [-1, 1]
fn fbm2(x: f32, y: f32, octaves: i64, seed: u32) -> f32 {
    sum: f32 = 0.0
    amp: f32 = 1.0
    total: f32 = 0.0
    for o in 0..octaves {
        sum += amp * noise2(x, y, seed + u32(o))
        total += amp
        amp = amp * 0.5
        x = x * 2.0
        y = y * 2.0
    }
    return if total > 0.0 { sum / total } else { 0.0 }
}

// fbm2 with seed 0
fn fbm2(x: f32, y: f32, octaves: i64) -> f32 {
    return fbm2(x, y, octaves, 0)
}
