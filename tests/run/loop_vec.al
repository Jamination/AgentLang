// The loop vectorizer (src/opt/vec.al): maps over slices of every element type and operation,
// for every trip count 0..40 (around the multiples of the vector widths), slices that start at
// odd offsets, in-place updates, sources and destinations that overlap at small and large
// distances in both directions, invariant operands and shift counts, and loops that must stay
// scalar. Each function's results over all cases go into one checksum: the output must be the
// scalar loops' (it was made at -O0).

fn h8(h: u64, a: []u8) -> u64 {
    x := h
    for i in 0..len(a) {
        x = (x ^ u64(a[i])) * 1099511628211
    }
    x
}

fn bytes_of[T](a: []T) -> []u8 {
    return cast[[]u8](a)
}

priv seed: u64

fn rnd() -> u64 {
    seed = seed * 6364136223846793005 + 1442695040888963407
    return seed >> 29
}

// random bytes, some of them extreme (0, 0xFF, 0x80, 0x7F)
fn fill_rand(b: []u8) {
    for i in 0..len(b) {
        r := rnd()
        b[i] = match r % 9 {
            0 => 0
            1 => 0xFF
            2 => 0x80
            3 => 0x7F
            _ => u8(r >> 8)
        }
    }
}

// random floats with special values among them (NaN, infinities, signed zeros)
fn fill_f64(a: []f64) {
    for i in 0..len(a) {
        r := rnd()
        a[i] = match r % 13 {
            0 => 0.0 / 0.0
            1 => -0.0
            2 => 0.0
            3 => 1.0 / 0.0
            4 => -1.0 / 0.0
            _ => (f64(i64(r % 2000001) - 1000000)) / 1024.0
        }
    }
}

fn fill_f32(a: []f32) {
    for i in 0..len(a) {
        r := rnd()
        a[i] = match r % 13 {
            0 => f32(0.0 / 0.0)
            1 => -0.0
            2 => 0.0
            3 => f32(1.0 / 0.0)
            4 => f32(-1.0 / 0.0)
            _ => f32(i64(r % 2000001) - 1000000) / 1024.0
        }
    }
}

// ---------- maps ----------
noinline fn add_u8(d: []u8, a: []u8, b: []u8, n: i64) {
    for i in 0..n {
        d[i] = a[i] + b[i]
    }
}

noinline fn mix_u8(d: []u8, a: []u8, b: []u8, n: i64) {
    for i in 0..n {
        d[i] = (a[i] ^ 0x5A) - (b[i] | 3) & a[i] + 7
    }
}

noinline fn add_i16(d: []i16, a: []i16, b: []i16, n: i64) {
    for i in 0..n {
        d[i] = a[i] * b[i] - (a[i] >> 3) + (b[i] << 5)
    }
}

noinline fn shr_u16(d: []u16, a: []u16, b: []u16, n: i64) {
    for i in 0..n {
        d[i] = (a[i] >> 7) ^ (b[i] << 2)
    }
}

noinline fn mul_u32(d: []u32, a: []u32, b: []u32, n: i64) {
    for i in 0..n {
        d[i] = a[i] * b[i] + 0x9E3779B9
    }
}

noinline fn ops_i32(d: []i32, a: []i32, b: []i32, n: i64) {
    for i in 0..n {
        d[i] = (a[i] >> 9) - (b[i] << 3) ^ (a[i] & b[i]) * 3
    }
}

noinline fn shr_u32(d: []u32, a: []u32, b: []u32, n: i64) {
    for i in 0..n {
        d[i] = (a[i] >> 31) | (b[i] >> 1)
    }
}

noinline fn add_i64(d: []i64, a: []i64, b: []i64, n: i64) {
    for i in 0..n {
        d[i] = (a[i] - b[i]) ^ (a[i] << 13) | (b[i] >> 50) & 0x0F0F
    }
}

noinline fn shr_u64(d: []u64, a: []u64, b: []u64, n: i64) {
    for i in 0..n {
        d[i] = (a[i] >> 63) + (b[i] >> 17) - a[i]
    }
}

// a shift count that is the same in every iteration but not known (also >= the width)
noinline fn shift_var_u32(d: []u32, a: []u32, b: []u32, n: i64) {
    s := b[0] % 70
    t := a[0] % 40
    for i in 0..n {
        d[i] = (a[i] << s) ^ (b[i] >> t)
    }
}

noinline fn shift_var_i16(d: []i16, a: []i16, b: []i16, n: i64) {
    s := i64(b[0]) & 31
    for i in 0..n {
        d[i] = (a[i] >> s) + (b[i] << s)
    }
}

noinline fn shift_var_i64(d: []i64, a: []i64, b: []i64, n: i64) {
    s := u32(a[0]) % 100
    for i in 0..n {
        d[i] = (a[i] << s) + i64(u64(b[i]) >> s)
    }
}

// an invariant operand and an invariant store
noinline fn axpy_i32(d: []i32, a: []i32, b: []i32, n: i64) {
    k := b[0]
    for i in 0..n {
        d[i] = a[i] * k + 17
    }
}

noinline fn set_i16(d: []i16, a: []i16, b: []i16, n: i64) {
    k := a[0] ^ b[0]
    for i in 0..n {
        d[i] = k
    }
}

// selects on compares (min / max, clamps, unsigned compares)
noinline fn sel_i32(d: []i32, a: []i32, b: []i32, n: i64) {
    for i in 0..n {
        x := a[i]
        y := b[i]
        d[i] = if x < y { max(x, -1000000) } else { min(y, 1000000) }
    }
}

noinline fn sel_u32(d: []u32, a: []u32, b: []u32, n: i64) {
    for i in 0..n {
        d[i] = if a[i] >= b[i] { a[i] - b[i] } else { b[i] }
    }
}

noinline fn sel_u8(d: []u8, a: []u8, b: []u8, n: i64) {
    for i in 0..n {
        d[i] = if a[i] > b[i] { a[i] } else { b[i] + 1 }
    }
}

noinline fn sel_i8(d: []i8, a: []i8, b: []i8, n: i64) {
    for i in 0..n {
        d[i] = if a[i] <= b[i] { a[i] } else { b[i] ^ 1 }
    }
}

noinline fn sel_u16(d: []u16, a: []u16, b: []u16, n: i64) {
    for i in 0..n {
        d[i] = if a[i] != b[i] { min(a[i], b[i]) } else { 7 }
    }
}

noinline fn sel_i16(d: []i16, a: []i16, b: []i16, n: i64) {
    for i in 0..n {
        d[i] = if a[i] == 0 { b[i] } else { max(a[i], b[i]) }
    }
}

// floats
noinline fn axpy_f64(d: []f64, a: []f64, b: []f64, n: i64) {
    k := b[0]
    for i in 0..n {
        d[i] = a[i] * 0.75 + k * b[i] - a[i] / 3.0
    }
}

noinline fn fops_f64(d: []f64, a: []f64, b: []f64, n: i64) {
    for i in 0..n {
        d[i] = fmin(sqrt(fabs(a[i])), b[i]) + fmax(-a[i], b[i])
    }
}

noinline fn minmax_f64(d: []f64, a: []f64, b: []f64, n: i64) {
    for i in 0..n {
        d[i] = min(a[i], b[i]) - max(a[i], 2.5)
    }
}

noinline fn clamp_f64(d: []f64, a: []f64, b: []f64, n: i64) {
    for i in 0..n {
        x := a[i]
        d[i] = if x < -100.0 { -100.0 } else if x > b[i] { b[i] } else { x }
    }
}

noinline fn axpy_f32(d: []f32, a: []f32, b: []f32, n: i64) {
    for i in 0..n {
        d[i] = d[i] + 0.25 * a[i] - b[i] * b[i]
    }
}

noinline fn fops_f32(d: []f32, a: []f32, b: []f32, n: i64) {
    for i in 0..n {
        d[i] = fmax(sqrt(a[i]), b[i]) / (fabs(b[i]) + 1.0) - fmin(a[i], -b[i])
    }
}

noinline fn sel_f32(d: []f32, a: []f32, b: []f32, n: i64) {
    for i in 0..n {
        d[i] = if a[i] >= b[i] { a[i] } else if a[i] != a[i] { 1.5 } else { b[i] * 2.0 }
    }
}

noinline fn minmax_f32(d: []f32, a: []f32, b: []f32, n: i64) {
    for i in 0..n {
        d[i] = max(a[i], b[i]) + min(b[i], -1.0)
    }
}

// in place
noinline fn inplace_i32(d: []i32, a: []i32, b: []i32, n: i64) {
    for i in 0..n {
        d[i] = d[i] * 5 + a[i]
    }
}

noinline fn inplace_f64(d: []f64, a: []f64, b: []f64, n: i64) {
    for i in 0..n {
        d[i] = -d[i] * 0.5
    }
}

// a counter of another type, a loop that does not start at 0
noinline fn mid_u8(d: []u8, a: []u8, b: []u8, n: i64) {
    for i in u32(n / 3)..u32(n) {
        d[i] = a[i] - b[i]
    }
}

noinline fn mid_i64(d: []i64, a: []i64, b: []i64, n: i64) {
    for i in n / 2..n {
        d[i] = a[i] + b[i - n / 2]
    }
}

// ---------- loops that stay scalar ----------
// a recurrence: each element from the one before
noinline fn recur_i32(d: []i32, a: []i32, b: []i32, n: i64) {
    for i in 1..n {
        d[i] = d[i - 1] + a[i]
    }
}

// a store ahead of the load by one element
noinline fn ahead_u8(d: []u8, a: []u8, b: []u8, n: i64) {
    for i in 0..n - 1 {
        d[i + 1] = d[i] + 1
    }
}

// a store behind the load (the loop reads what the previous iteration did not write)
noinline fn behind_u16(d: []u16, a: []u16, b: []u16, n: i64) {
    for i in 1..n {
        d[i - 1] = d[i] * 3
    }
}

// an early exit
noinline fn until_i32(d: []i32, a: []i32, b: []i32, n: i64) {
    for i in 0..n {
        if a[i] == 0 {
            break
        }
        d[i] = a[i] + b[i]
    }
}

priv calls: i64

noinline fn note(x: i32) -> i32 {
    calls += 1
    x + 1
}

noinline fn call_i32(d: []i32, a: []i32, b: []i32, n: i64) {
    for i in 0..n {
        d[i] = note(a[i])
    }
}

// a stored value from the counter
noinline fn iota_i32(d: []i32, a: []i32, b: []i32, n: i64) {
    for i in 0..n {
        d[i] = i32(i) + a[i]
    }
}

// ---------- drivers ----------
// every n in 0..40 and offsets 0..3 of the three slices (disjoint)
fn run_disjoint[T](name: str, op: fn([]T, []T, []T, i64)) {
    h: u64 = 1469598103934665603
    da := alloc[T](48)
    aa := alloc[T](48)
    ba := alloc[T](48)
    for n in 0..41 {
        for off in 0..4 {
            fill_rand(bytes_of(da))
            fill_rand(bytes_of(aa))
            fill_rand(bytes_of(ba))
            if off == 3 {
                // equal sources
                op(da[off..], aa[1..], aa[1..], n)
            } else {
                op(da[off..], aa[(off * 3) % 5..], ba[(off + 1) % 4..], n)
            }
            h = h8(h, bytes_of(da))
        }
    }
    print(name, h)
}

// one buffer: the destination at every distance -34..34 elements from the first source
fn run_overlap[T](name: str, op: fn([]T, []T, []T, i64)) {
    h: u64 = 1469598103934665603
    buf := alloc[T](120)
    other := alloc[T](48)
    for dist in -34..35 {
        for n in [5]i64{0, 7, 17, 33, 40} {
            fill_rand(bytes_of(buf))
            fill_rand(bytes_of(other))
            op(buf[40 + dist..], buf[40..], other[..], n)
            h = h8(h, bytes_of(buf))
            // the destination as the second source
            fill_rand(bytes_of(buf))
            op(buf[40 + dist..], other[..], buf[40..], n)
            h = h8(h, bytes_of(buf))
        }
    }
    print(name, h)
}

fn run_float[T](name: str, op: fn([]T, []T, []T, i64), fl: fn([]T)) {
    h: u64 = 1469598103934665603
    da := alloc[T](48)
    aa := alloc[T](48)
    ba := alloc[T](48)
    for n in 0..41 {
        for off in 0..3 {
            fl(da)
            fl(aa)
            fl(ba)
            op(da[off..], aa[(off * 3) % 5..], ba[(off + 1) % 4..], n)
            h = h8(h, bytes_of(da))
        }
    }
    buf := alloc[T](120)
    for dist in -9..10 {
        for n in [4]i64{3, 16, 31, 40} {
            fl(buf)
            fl(aa)
            op(buf[40 + dist..], buf[40..], aa[..], n)
            h = h8(h, bytes_of(buf))
        }
    }
    print(name, h)
}

fn main() {
    seed = 12345
    run_disjoint[u8]("add_u8", add_u8)
    run_overlap[u8]("add_u8 overlap", add_u8)
    run_disjoint[u8]("mix_u8", mix_u8)
    run_overlap[u8]("mix_u8 overlap", mix_u8)
    run_disjoint[i16]("add_i16", add_i16)
    run_overlap[i16]("add_i16 overlap", add_i16)
    run_disjoint[u16]("shr_u16", shr_u16)
    run_disjoint[u32]("mul_u32", mul_u32)
    run_overlap[u32]("mul_u32 overlap", mul_u32)
    run_disjoint[i32]("ops_i32", ops_i32)
    run_disjoint[u32]("shr_u32", shr_u32)
    run_disjoint[i64]("add_i64", add_i64)
    run_overlap[i64]("add_i64 overlap", add_i64)
    run_disjoint[u64]("shr_u64", shr_u64)
    run_disjoint[u32]("shift_var_u32", shift_var_u32)
    run_disjoint[i16]("shift_var_i16", shift_var_i16)
    run_disjoint[i64]("shift_var_i64", shift_var_i64)
    run_disjoint[i32]("axpy_i32", axpy_i32)
    run_overlap[i32]("axpy_i32 overlap", axpy_i32)
    run_disjoint[i16]("set_i16", set_i16)
    run_disjoint[i32]("sel_i32", sel_i32)
    run_disjoint[u32]("sel_u32", sel_u32)
    run_disjoint[u8]("sel_u8", sel_u8)
    run_disjoint[i8]("sel_i8", sel_i8)
    run_disjoint[u16]("sel_u16", sel_u16)
    run_disjoint[i16]("sel_i16", sel_i16)
    run_overlap[i16]("sel_i16 overlap", sel_i16)
    run_float[f64]("axpy_f64", axpy_f64, fill_f64)
    run_float[f64]("fops_f64", fops_f64, fill_f64)
    run_float[f64]("minmax_f64", minmax_f64, fill_f64)
    run_float[f64]("clamp_f64", clamp_f64, fill_f64)
    run_float[f32]("axpy_f32", axpy_f32, fill_f32)
    run_float[f32]("fops_f32", fops_f32, fill_f32)
    run_float[f32]("sel_f32", sel_f32, fill_f32)
    run_float[f32]("minmax_f32", minmax_f32, fill_f32)
    run_disjoint[i32]("inplace_i32", inplace_i32)
    run_overlap[i32]("inplace_i32 overlap", inplace_i32)
    run_float[f64]("inplace_f64", inplace_f64, fill_f64)
    run_disjoint[u8]("mid_u8", mid_u8)
    run_disjoint[i64]("mid_i64", mid_i64)
    run_overlap[i64]("mid_i64 overlap", mid_i64)
    run_disjoint[i32]("recur_i32", recur_i32)
    run_disjoint[u8]("ahead_u8", ahead_u8)
    run_disjoint[u16]("behind_u16", behind_u16)
    run_disjoint[i32]("until_i32", until_i32)
    run_disjoint[i32]("call_i32", call_i32)
    print("calls", calls)
    run_disjoint[i32]("iota_i32", iota_i32)
}
