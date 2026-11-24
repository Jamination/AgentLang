// A bounds check that fails in a loop the vectorizer (src/opt/vec.al) turns into vector code
// still stops the program with the line of the access, after the output of the calls before.

noinline fn scale(d: []f32, a: []f32, n: i64, k: f32) {
    for i in 0..n {
        d[i] = a[i] * k + 1.0
    }
}

noinline fn total(a: []i32, n: i64) -> i32 {
    s: i32 = 0
    for i in 0..n {
        s += a[i]
    }
    s
}

fn main() {
    a := alloc[f32](37)
    d := alloc[f32](40)
    for i in 0..37 {
        a[i] = f32(i)
    }
    scale(d, a, 37, 2.0)
    print(d[0], d[36], d[37])
    b := alloc[i32](21)
    for i in 0..21 {
        b[i] = i32(i * i)
    }
    print(total(b, 21), total(b, 0))
    print(total(b, 22))
    print("not reached")
}
