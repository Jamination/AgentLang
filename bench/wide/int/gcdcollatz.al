// branchy scalar integer code: Euclid gcd (division by a variable), binary gcd, Collatz chain lengths
fn gcd(a0: u64, b0: u64) -> u64 {
    a := a0
    b := b0
    while b != 0 {
        t := a % b
        a = b
        b = t
    }
    a
}

fn bgcd(a0: u64, b0: u64) -> u64 {
    a := a0
    b := b0
    if a == 0 { return b }
    if b == 0 { return a }
    shift: u64 = 0
    while (a | b) & 1 == 0 {
        a >>= 1
        b >>= 1
        shift += 1
    }
    while a & 1 == 0 { a >>= 1 }
    while b != 0 {
        while b & 1 == 0 { b >>= 1 }
        if a > b {
            t := a
            a = b
            b = t
        }
        b -= a
    }
    a << shift
}

fn collatz_len(n0: u64) -> i64 {
    n := n0
    steps := 0
    while n != 1 {
        n = if n & 1 == 0 { n >> 1 } else { 3 * n + 1 }
        steps += 1
    }
    steps
}

fn main() {
    s: u64 = 0
    x: u64 = 0x9E3779B97F4A7C15
    for i in 0..1500000 {
        x = x * 6364136223846793005 + 1442695040888963407
        a := x >> 20
        b := (x << 7) >> 30
        s += gcd(a, b) + bgcd(a + 2, b * 6)
    }
    best := 0
    bestn: u64 = 0
    total := 0
    for n in 1..1500000 {
        l := collatz_len(u64(n))
        total += l
        if l > best {
            best = l
            bestn = u64(n)
        }
    }
    put(s, " ", best, " ", bestn, " ", total, "\n")
}
