// countif.al with a branch-free count (bool converted to 0/1)
fn count_above(a: []i32, t: i32) -> i64 {
    c := 0
    for x in a {
        c += i64(x > t)
    }
    c
}

fn main() {
    n := 1 << 14
    a := alloc[i32](n)
    seed: u32 = 31337
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        a[i] = i32(seed >> 16)
    }
    total: i64 = 0
    for r in 0..150000 {
        total += count_above(a, i32(r & 0xFFFF))
        a[r & (n - 1)] = i32(r & 0xFFFF)
    }
    put(total, "\n")
}
