// `for` with a condition instead of `in`: the hint names `while`
fn main() {
    i := 0
    for i < 10 {
        i += 1
    }
    done := false
    for !done {
        done = true
    }
    for (i > 0) && f(i, 2) {
        i -= 1
    }
    for x in 0..3 {
        print(x)
    }
}
fn f(a: i64, b: i64) -> bool { a > b }
