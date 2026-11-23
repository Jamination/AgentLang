// deep non-tail recursion: tak (3 args, nested calls), ackermann (very deep stack)
fn tak(x: i64, y: i64, z: i64) -> i64 {
    if y < x { tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y)) } else { z }
}

fn ack(m: i64, n: i64) -> i64 {
    if m == 0 { return n + 1 }
    if n == 0 { return ack(m - 1, 1) }
    ack(m - 1, ack(m, n - 1))
}

fn main() {
    base := len(args())          // 1 at run time: keeps the arguments opaque
    t := 0
    for i in 0..4 { t += tak(22 + base + i, 14 + base, 6 + base) }
    a := 0
    for i in 0..3 { a += ack(2 + base, 8 + base + i) }
    put(t, " ", a, "\n")
}
