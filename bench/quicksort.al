fn quicksort(a: []i64, lo: i64, hi: i64) {
    p := a[(lo + hi) / 2]
    i := lo
    j := hi
    while i <= j {
        while a[i] < p {
            i += 1
        }
        while a[j] > p {
            j -= 1
        }
        if i <= j {
            t := a[i]
            a[i] = a[j]
            a[j] = t
            i += 1
            j -= 1
        }
    }
    if lo < j {
        quicksort(a, lo, j)
    }
    if i < hi {
        quicksort(a, i, hi)
    }
}

fn main() -> i64 {
    n := 5000000
    a := alloc[i64](n)
    seed: u64 = 88172645463325252
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        a[i] = i64(seed >> 16)
    }
    quicksort(a, 0, n - 1)
    sum: u64 = 0
    for i in 0..n {
        if i > 0 && a[i - 1] > a[i] {
            put("not sorted at ", i, "\n")
            return 1
        }
        sum = sum * 31 + u64(a[i])
    }
    put(a[0], " ", a[n / 2], " ", a[n - 1], " ", sum, "\n")
    return 0
}
