// values derived from loop counters and used after the loop
fn main() {
    x := 0
    y := 100
    for i in 0..64 {
        x = i - 8
        y = y + (i & 1)
    }
    print(x, y, x + x + x)
    a := 1
    b := 2
    c := 3
    last := 0
    n := 0
    for i in 0..10 {
        t := a + b
        a = b
        b = c
        c = t
        last = i * 4
        n = i
    }
    print(a, b, c, last, n, last + n * 8)
    k := 0
    s := 0
    while k < 37 {
        s = k * 3 + 1
        k += 1
    }
    print(k, s, s - k)
    arr: [8]i64
    j := 0
    for i in 0..8 {
        arr[i] = i * i
        j = i
    }
    print(arr[j], arr[j - 1], j)
}
