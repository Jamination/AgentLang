// division and remainder by constants (signed, unsigned, 32/64-bit) and by a loop-invariant run-time divisor
fn main() {
    d := i64(len(args())) + 999
    du := u32(d)
    sum: u64 = 0
    acc: i64 = 0
    acc32: u32 = 0
    for i in 0..30000000 {
        x := u64(i) * 2654435761
        t := x
        while t != 0 {
            sum += t % 10
            t = t / 10
        }
        y := i64(x) - 0x8_0000_0000_0000
        acc += y / 7 + y % 13 - y / 1000
        acc ^= y / d + y % d
        z := u32(x)
        acc32 += z / 3 + z % 100 + z / du
    }
    put(sum, " ", acc, " ", acc32, "\n")
}
