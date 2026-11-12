// sort takes n log n steps on every input: an organ pipe (up, then down) made the quicksort
// with a middle pivot quadratic (a million elements: minutes).
fn check(a: []i64, n: i64) {
    for i in 1..len(a) {
        assert a[i - 1] <= a[i]
    }
    // each value v < n/2 occurs twice (once on the way up, once down), except 0
    for i in 0..len(a) {
        assert a[i] == (i + 1) / 2
    }
}

fn main() {
    n := 1000000
    a := alloc[i64](n)
    for i in 0..n {
        a[i] = if i < n / 2 { i } else { n - i }
    }
    sort(a)
    check(a, n)
    // the same through the heap-sort path with floats, NaN does not break it
    f := alloc[f64](n)
    for i in 0..n {
        f[i] = f64(if i < n / 2 { i } else { n - i })
    }
    f[17] = 0.0 / 0.0
    sort(f)
    nans := 0
    for x in f {
        if x != x { nans += 1 }
    }
    print(a[..5], a[n - 3..], nans)
}
