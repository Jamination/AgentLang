// higher-order functions in hot loops: map / filter / fold with function values,
// merge sort with a comparator callback (plain and with a context argument)

fn map_into(dst: []i64, src: []i64, f: fn(i64) -> i64) {
    for i, x in src { dst[i] = f(x) }
}

fn filter_into(dst: []i64, src: []i64, keep: fn(i64) -> bool) -> i64 {
    n := 0
    for x in src {
        if keep(x) {
            dst[n] = x
            n += 1
        }
    }
    n
}

fn fold(src: []i64, init: i64, f: fn(i64, i64) -> i64) -> i64 {
    acc := init
    for x in src { acc = f(acc, x) }
    acc
}

fn merge_sort(a: []i64, tmp: []i64, less: fn(i64, i64) -> bool) {
    n := len(a)
    if n < 2 { return }
    mid := n / 2
    merge_sort(a[..mid], tmp[..mid], less)
    merge_sort(a[mid..], tmp[mid..], less)
    i := 0
    j := mid
    k := 0
    while i < mid && j < n {
        if less(a[j], a[i]) {
            tmp[k] = a[j]
            j += 1
        } else {
            tmp[k] = a[i]
            i += 1
        }
        k += 1
    }
    while i < mid { tmp[k] = a[i]; i += 1; k += 1 }
    while j < n { tmp[k] = a[j]; j += 1; k += 1 }
    for t in 0..n { a[t] = tmp[t] }
}

// sorts indices by keys[idx]: the comparator gets the keys as context
fn merge_sort_ctx(a: []i64, tmp: []i64, keys: []i64, less: fn([]i64, i64, i64) -> bool) {
    n := len(a)
    if n < 2 { return }
    mid := n / 2
    merge_sort_ctx(a[..mid], tmp[..mid], keys, less)
    merge_sort_ctx(a[mid..], tmp[mid..], keys, less)
    i := 0
    j := mid
    k := 0
    while i < mid && j < n {
        if less(keys, a[j], a[i]) {
            tmp[k] = a[j]
            j += 1
        } else {
            tmp[k] = a[i]
            i += 1
        }
        k += 1
    }
    while i < mid { tmp[k] = a[i]; i += 1; k += 1 }
    while j < n { tmp[k] = a[j]; j += 1; k += 1 }
    for t in 0..n { a[t] = tmp[t] }
}

fn main() {
    n := 1000000
    src := alloc[i64](n)
    a := alloc[i64](n)
    b := alloc[i64](n)
    seed: u64 = 12345
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        src[i] = i64(seed >> 40)
    }
    total := 0
    for r in 0..20 {
        map_into(a, src, fn(x: i64) -> i64 { x * 3 + 1 })
        m := filter_into(b, a, fn(x: i64) -> bool { x % 7 != 3 })
        total += fold(b[..m], r, fn(acc: i64, x: i64) -> i64 { acc * 31 + (x ^ (acc >> 11)) })
        map_into(a, b[..m], fn(x: i64) -> i64 { (x >> 3) ^ (x << 2) })
        total += fold(a[..m], 0, fn(acc: i64, x: i64) -> i64 { if x > acc { x } else { acc - 1 } })
    }
    tmp := alloc[i64](n)
    for i in 0..n { a[i] = src[i] }
    merge_sort(a, tmp, fn(x: i64, y: i64) -> bool { x < y })
    s1 := fold(a, 0, fn(acc: i64, x: i64) -> i64 { acc * 31 + x })
    merge_sort(a, tmp, fn(x: i64, y: i64) -> bool { (x & 1023) > (y & 1023) })
    s2 := fold(a, 0, fn(acc: i64, x: i64) -> i64 { acc * 31 + x })
    idx := alloc[i64](n)
    for i in 0..n { idx[i] = i }
    merge_sort_ctx(idx, tmp, src, fn(keys: []i64, x: i64, y: i64) -> bool { keys[x] % 1000 < keys[y] % 1000 })
    s3 := fold(idx, 0, fn(acc: i64, x: i64) -> i64 { acc * 31 + x })
    put(total, " ", s1, " ", s2, " ", s3, "\n")
}
