// A check that fails inside an unrolled loop (src/opt/unroll.al, unroll_runtime: each copy of
// the body keeps its checks in order) stops the program at that iteration, after the output
// of the iterations before it.

noinline fn gather(a: []i64, idx: []i64, n: i64) -> i64 {
    s := 0
    for k in 0..n {
        s += a[idx[k]]
    }
    s
}

fn main() {
    a := alloc[i64](10)
    for i in 0..10 {
        a[i] = i * i
    }
    idx := alloc[i64](23)
    for i in 0..23 {
        idx[i] = (i * 7) % 10
    }
    print(gather(a, idx, 23), gather(a, idx, 5), gather(a, idx, 0))
    idx[14] = 10
    print(gather(a, idx, 14))
    print(gather(a, idx, 23))
    print("not reached")
}
