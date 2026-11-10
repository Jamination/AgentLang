fn sum(a []i64) i64 {
    s := 0
    for x in a {
        s += x
    }
    s
}

fn fill(a []i64, v i64) {
    for i in 0..len(a) {
        a[i] = v
    }
}

fn main() {
    a := alloc[i64](8)
    for i in 0..8 {
        a[i] = i + 1
    }
    print(sum(a), len(a), a.len)
    b := a[2..5]
    print(b, len(b), sum(b))
    b[0] = 100
    print(a[2], a)
    fill(a[6..], 9)
    print(a[..3], a[6..])
    var arr [5]i32
    for i in 0..5 {
        arr[i] = i32(i) * 10
    }
    print(arr, len(arr), arr[4])
    s := arr[1..4]
    s[0] = -1
    print(arr[1], s)
    lit := []u16{1, 2, 3}
    print(lit, len(lit))
    m := [3]f64{1.5, 2.5}
    print(m)
    str := "hello"
    print(str, len(str), str[1], str[1..3])
    var grid [3][4]i64
    for i in 0..3 {
        for j in 0..4 {
            grid[i][j] = i * 4 + j
        }
    }
    print(grid[2][3], grid[1])
    for i, x in lit {
        put(i, ":", x, " ")
    }
    print()
    e := alloc[f64](0)
    print(len(e), e)
    ss := [][]i64{a[0..2], a[2..4]}
    print(ss)
}
