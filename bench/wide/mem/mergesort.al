// top-down merge sort with one temp buffer (two slices that the compiler cannot prove distinct)
fn merge_sort(a: []i64, tmp: []i64, lo: i64, hi: i64) {
    if hi - lo < 2 {
        return
    }
    mid := (lo + hi) / 2
    merge_sort(a, tmp, lo, mid)
    merge_sort(a, tmp, mid, hi)
    if a[mid - 1] <= a[mid] {
        return
    }
    i := lo
    j := mid
    k := lo
    while i < mid && j < hi {
        if a[j] < a[i] {
            tmp[k] = a[j]
            j += 1
        } else {
            tmp[k] = a[i]
            i += 1
        }
        k += 1
    }
    while i < mid {
        tmp[k] = a[i]
        i += 1
        k += 1
    }
    while j < hi {
        tmp[k] = a[j]
        j += 1
        k += 1
    }
    for t in lo..hi {
        a[t] = tmp[t]
    }
}

fn main() {
    n := 4000000
    a := alloc[i64](n)
    tmp := alloc[i64](n)
    seed: u64 = 1
    check: u64 = 0
    for r in 0..2 {
        for i in 0..n {
            seed = seed * 6364136223846793005 + 1442695040888963407
            a[i] = i64(seed >> 24)
        }
        merge_sort(a, tmp, 0, n)
        for i in 0..n {
            check = check * 31 + u64(a[i])
        }
    }
    put(check, " ", a[0], " ", a[n - 1], "\n")
}
