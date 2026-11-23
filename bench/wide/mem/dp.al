// edit distance over a full (n+1) x (m+1) table stored flat, then 0/1 knapsack on a 1-D table
fn edit_distance(a: []u8, b: []u8, d: []i32) -> i32 {
    n := len(a)
    m := len(b)
    w := m + 1
    for j in 0..=m {
        d[j] = i32(j)
    }
    for i in 1..=n {
        d[i * w] = i32(i)
        ai := a[i - 1]
        for j in 1..=m {
            cost: i32 = if ai == b[j - 1] { 0 } else { 1 }
            best := d[(i - 1) * w + j - 1] + cost
            up := d[(i - 1) * w + j] + 1
            left := d[i * w + j - 1] + 1
            if up < best { best = up }
            if left < best { best = left }
            d[i * w + j] = best
        }
    }
    d[n * w + m]
}

fn knapsack(wt: []i64, val: []i64, cap: i64, best: []i64) -> i64 {
    for w in 0..=cap {
        best[w] = 0
    }
    for k in 0..len(wt) {
        wk := wt[k]
        vk := val[k]
        for w in cap..=wk by -1 {
            cand := best[w - wk] + vk
            if cand > best[w] {
                best[w] = cand
            }
        }
    }
    best[cap]
}

fn main() {
    n := 4000
    a := alloc[u8](n)
    b := alloc[u8](n)
    seed: u64 = 5
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        a[i] = u8(97 + (seed >> 33) % 4)
        seed = seed * 6364136223846793005 + 1442695040888963407
        b[i] = u8(97 + (seed >> 33) % 4)
    }
    d := alloc[i32]((n + 1) * (n + 1))
    total := 0
    for r in 0..6 {
        total += i64(edit_distance(a[r..], b, d))
    }
    items := 2000
    wt := alloc[i64](items)
    val := alloc[i64](items)
    for i in 0..items {
        seed = seed * 6364136223846793005 + 1442695040888963407
        wt[i] = 1 + i64((seed >> 33) % 1000)
        seed = seed * 6364136223846793005 + 1442695040888963407
        val[i] = 1 + i64((seed >> 33) % 10000)
    }
    cap := 300000
    best := alloc[i64](cap + 1)
    total += knapsack(wt, val, cap, best)
    put(total, "\n")
}
