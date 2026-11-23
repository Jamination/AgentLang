// deep non-tail recursion: fib (call / prologue overhead, two self calls)
fn fib(n: i64) -> i64 {
    if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}

fn main() {
    base := len(args())          // 1 at run time: keeps the arguments opaque
    f := 0
    for i in 0..4 { f += fib(35 + base + i) }
    put(f, "\n")
}
