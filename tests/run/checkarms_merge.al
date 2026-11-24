// both arms of a branch begin with the same check (checkmerge_arms): merge sort's
// `tmp[k] = a[j]` / `tmp[k] = a[i]`, which then becomes one store of a select; arms that check
// different indices or different arrays keep their checks
noinline fn merge(a: []i64, tmp: []i64, lo: i64, mid: i64, hi: i64) {
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
}

noinline fn other(x: []i64, y: []i64, c: bool, i: i64, j: i64) -> i64 {
    s := 0
    if c {
        s = x[i]
    } else {
        s = x[j]
    }
    if c {
        s += x[i]
    } else {
        s += y[i]
    }
    return s
}

fn main() {
    a := []i64{1, 4, 9, 12, 30, 2, 3, 10, 11, 40}
    tmp := alloc[i64](10)
    merge(a, tmp, 0, 5, 10)
    print(tmp)
    print(other(a, tmp, true, 2, 3), other(a, tmp, false, 2, 3))
}
