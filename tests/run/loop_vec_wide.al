// The loop vectorizer (src/opt/vec.al) with values of several lane sizes in one loop: zero and
// sign extension between every pair of integer sizes, truncation, sums of bytes into wider
// integers (psadbw), counts of compares, high halves of products (division by a constant),
// and loads and stores of different element sizes that overlap or not; every trip count 0..40
// and odd offsets. The output was made at -O0.

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

fn fill_rand(b: []u8) {
    for i in 0..len(b) {
        r := rnd()
        b[i] = match r % 7 {
            0 => 0
            1 => 0xFF
            2 => 0x80
            3 => 0x7F
            4 => 10
            _ => u8(r >> 8)
        }
    }
}

// ---------- extensions and truncations (destination, source) ----------
noinline fn z8_16(d: []u16, a: []u8, n: i64) {
    for i in 0..n {
        d[i] = u16(a[i]) * 3 + 1
    }
}

noinline fn s8_32(d: []i32, a: []i8, n: i64) {
    for i in 0..n {
        d[i] = i32(a[i]) - 5
    }
}

noinline fn z8_64(d: []u64, a: []u8, n: i64) {
    for i in 0..n {
        d[i] = u64(a[i]) << 40
    }
}

noinline fn s16_64(d: []i64, a: []i16, n: i64) {
    for i in 0..n {
        d[i] = i64(a[i]) ^ 0x7F
    }
}

noinline fn z32_64(d: []u64, a: []u32, n: i64) {
    for i in 0..n {
        d[i] += u64(a[i])
    }
}

noinline fn s32_64(d: []i64, a: []i32, n: i64) {
    for i in 0..n {
        d[i] = i64(a[i]) * 1
    }
}

noinline fn t16_8(d: []u8, a: []u16, n: i64) {
    for i in 0..n {
        d[i] = u8(a[i] + 0x1234)
    }
}

noinline fn t32_8(d: []i8, a: []i32, n: i64) {
    for i in 0..n {
        d[i] = i8(a[i] >> 3)
    }
}

noinline fn t64_16(d: []u16, a: []u64, n: i64) {
    for i in 0..n {
        d[i] = u16(a[i] >> 7)
    }
}

noinline fn t64_32(d: []i32, a: []i64, n: i64) {
    for i in 0..n {
        d[i] = i32(a[i]) + i32(a[i] >> 32)
    }
}

// widen, compute, narrow: a 3-tap filter with a division by 3 (multiply by its inverse)
noinline fn avg3(d: []u8, a: []u8, n: i64) {
    for i in 1..n - 1 {
        s := u32(a[i - 1]) + u32(a[i]) + u32(a[i + 1])
        d[i] = u8(s / 3)
    }
}

noinline fn div7_u16(d: []u16, a: []u16, n: i64) {
    for i in 0..n {
        d[i] = a[i] / 7 + a[i] % 7
    }
}

noinline fn div10_i16(d: []i16, a: []i16, n: i64) {
    for i in 0..n {
        d[i] = a[i] / 10
    }
}

// accumulate a narrow source into a wide destination, in place
noinline fn colsum(acc: []u32, row: []u8, n: i64) {
    for i in 0..n {
        acc[i] += u32(row[i])
    }
}

// a compare of one size selecting into another (not vectorized: the mask sizes differ)
noinline fn mixsel(d: []i64, a: []i32, n: i64) {
    for i in 0..n {
        d[i] = if a[i] > 0 { 1 } else { d[i] }
    }
}

// ---------- reductions over wider integers ----------
noinline fn bsum64(a: []u8, n: i64) -> u64 {
    s: u64 = 7
    for i in 0..n {
        s += u64(a[i])
    }
    s
}

noinline fn bsum16(a: []u8, n: i64) -> u16 {
    s: u16 = 0xFFF0
    for i in 0..n {
        s += u16(a[i])
    }
    s
}

noinline fn bsum32(a: []u8, n: i64) -> u32 {
    s: u32 = 0xFFFF_FF00
    for i in 0..n {
        s += u32(a[i])
    }
    s
}

noinline fn count_nl(a: []u8, n: i64) -> i64 {
    c := 0
    for i in 0..n {
        if a[i] == 10 {
            c += 1
        }
    }
    c
}

noinline fn count_ne(a: []u8, n: i64) -> i32 {
    c: i32 = 0
    for i in 0..n {
        c += i32(a[i] != 0x80)
    }
    c
}

noinline fn count_lt16(a: []i16, n: i64) -> i64 {
    c := 0
    for i in 0..n {
        if a[i] < -3 {
            c += 1
        }
    }
    c
}

noinline fn count_u32(a: []u32, n: i64) -> u64 {
    c: u64 = 0
    for i in 0..n {
        c += u64(a[i] >= 0x8000_0000)
    }
    c
}

noinline fn ssum8_32(a: []i8, n: i64) -> i32 {
    s: i32 = 0
    for i in 0..n {
        s += i32(a[i])
    }
    s
}

noinline fn ssum16_64(a: []i16, n: i64) -> i64 {
    s: i64 = -1
    for i in 0..n {
        s += i64(a[i]) * 1
    }
    s
}

noinline fn zsum32_64(a: []u32, n: i64) -> u64 {
    s: u64 = 0
    for i in 0..n {
        s += u64(a[i])
    }
    s
}

noinline fn max_widened(a: []u8, n: i64) -> u32 {
    m: u32 = 3
    for i in 0..n {
        m = max(m, u32(a[i]) * 2)
    }
    m
}

// ---------- drivers ----------
fn run_map[D, S](name: str, op: fn([]D, []S, i64)) {
    h: u64 = 1469598103934665603
    da := alloc[D](48)
    sa := alloc[S](48)
    for n in 0..41 {
        for off in 0..3 {
            fill_rand(bytes_of(da))
            fill_rand(bytes_of(sa))
            op(da[off..], sa[(off * 2) % 3..], n)
            h = h8(h, bytes_of(da))
        }
    }
    // the destination over the source, at byte distances -40..40
    buf := alloc[u8](8 * 160)
    dsz := len(bytes_of(da[..1]))
    ssz := len(bytes_of(sa[..1]))
    for dist in -40..41 {
        for n in [4]i64{6, 17, 33, 40} {
            fill_rand(buf)
            base := 8 * 60
            d := cast[[]D](buf[base + dist * dsz..base + dist * dsz + 44 * dsz])
            s := cast[[]S](buf[base..base + 44 * ssz])
            op(d, s, n)
            h = h8(h, buf)
        }
    }
    print(name, h)
}

fn main() {
    seed = 4242
    run_map[u16, u8]("z8_16", z8_16)
    run_map[i32, i8]("s8_32", s8_32)
    run_map[u64, u8]("z8_64", z8_64)
    run_map[i64, i16]("s16_64", s16_64)
    run_map[u64, u32]("z32_64", z32_64)
    run_map[i64, i32]("s32_64", s32_64)
    run_map[u8, u16]("t16_8", t16_8)
    run_map[i8, i32]("t32_8", t32_8)
    run_map[u16, u64]("t64_16", t64_16)
    run_map[i32, i64]("t64_32", t64_32)
    run_map[u8, u8]("avg3", avg3)
    run_map[u16, u16]("div7_u16", div7_u16)
    run_map[i16, i16]("div10_i16", div10_i16)
    run_map[u32, u8]("colsum", colsum)
    run_map[i64, i32]("mixsel", mixsel)
    buf := alloc[u8](8 * 48)
    h: u64 = 0
    for n in 0..41 {
        for off in 0..4 {
            fill_rand(buf)
            a8 := buf[off..]
            i8s := cast[[]i8](buf[off + 3..])
            a16 := cast[[]i16](buf[2 * off..2 * off + 88])
            a32 := cast[[]u32](buf[4 * off..4 * off + 176])
            r := [12]u64{
                bsum64(a8, n),
                u64(bsum16(a8, n)),
                u64(bsum32(a8, n)),
                u64(count_nl(a8, n)),
                u64(count_ne(a8, n)),
                u64(count_lt16(a16, n)),
                count_u32(a32, n),
                u64(ssum8_32(i8s, n)),
                u64(ssum16_64(a16, n)),
                zsum32_64(a32, n),
                u64(max_widened(a8, n)),
                0,
            }
            for x in r {
                h = (h ^ x) * 1099511628211
            }
            if n == 37 && off == 3 {
                print(r)
            }
        }
    }
    print("hash", h)
}
