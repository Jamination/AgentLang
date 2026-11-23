// 5-point stencil (Jacobi relaxation) over a grid stored as rows ([][]f64), then the same over a
// flat []f64 with computed indices: the two layouts side by side
fn relax_rows(src: [][]f64, dst: [][]f64) {
    n := len(src)
    for y in 1..n - 1 {
        up := src[y - 1]
        mid := src[y]
        dn := src[y + 1]
        out := dst[y]
        for x in 1..len(mid) - 1 {
            out[x] = 0.25 * (up[x] + dn[x] + mid[x - 1] + mid[x + 1])
        }
    }
}

fn relax_flat(src: []f64, dst: []f64, n: i64) {
    for y in 1..n - 1 {
        for x in 1..n - 1 {
            i := y * n + x
            dst[i] = 0.25 * (src[i - n] + src[i + n] + src[i - 1] + src[i + 1])
        }
    }
}

// column-major walk of the rows: each access goes through the row slice table
fn col_sum(g: [][]f64) -> f64 {
    s: f64 = 0.0
    for x in 0..len(g[0]) {
        for y in 0..len(g) {
            s += g[y][x] * f64(y + 1)
        }
    }
    s
}

fn main() {
    n := 1024
    a := alloc[[]f64](n)
    b := alloc[[]f64](n)
    for y in 0..n {
        a[y] = alloc[f64](n)
        b[y] = alloc[f64](n)
    }
    fa := alloc[f64](n * n)
    fb := alloc[f64](n * n)
    seed: u64 = 3
    for y in 0..n {
        for x in 0..n {
            seed = seed * 6364136223846793005 + 1442695040888963407
            v := f64(i64(seed >> 40)) / 16777216.0
            a[y][x] = v
            b[y][x] = v
            fa[y * n + x] = v
            fb[y * n + x] = v
        }
    }
    for it in 0..100 {
        relax_rows(a, b)
        relax_rows(b, a)
    }
    for it in 0..100 {
        relax_flat(fa, fb, n)
        relax_flat(fb, fa, n)
    }
    cs: f64 = 0.0
    for it in 0..10 {
        cs += col_sum(a)
    }
    s1: f64 = 0.0
    s2: f64 = 0.0
    for y in 0..n {
        for x in 0..n {
            s1 += a[y][x]
            s2 += fa[y * n + x]
        }
    }
    put(i64(s1 * 1000.0), " ", i64(s2 * 1000.0), " ", i64(cs), "\n")
}
