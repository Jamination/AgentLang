// mutual recursion and tail recursion: Hofstadter female/male (non-tail, mutual),
// Collatz by two mutually tail-calling functions, tail-recursive gcd and digit sums

fn hf(n: i64) -> i64 { if n == 0 { 1 } else { n - hm(hf(n - 1)) } }
fn hm(n: i64) -> i64 { if n == 0 { 0 } else { n - hf(hm(n - 1)) } }

fn even_step(n: i64, steps: i64) -> i64 {
    if n == 1 { return steps }
    if n & 1 == 1 { return odd_step(n, steps) }
    even_step(n >> 1, steps + 1)
}
fn odd_step(n: i64, steps: i64) -> i64 { even_step(3 * n + 1, steps + 1) }

fn gcd(a: i64, b: i64) -> i64 { if b == 0 { a } else { gcd(b, a % b) } }

fn digsum(n: i64, acc: i64) -> i64 { if n == 0 { acc } else { digsum(n / 10, acc + n % 10) } }

fn main() {
    base := len(args())
    h := 0
    for i in 0..60 { h += hf(i + base) + hm(i + base) }
    c := 0
    for i in 1..1500000 { c += even_step(i + base, 0) }
    g := 0
    for i in 1..1500 {
        for j in 1..400 { g += gcd(i * 7919 + base, j * 104729) }
    }
    d := 0
    for i in 0..3000000 { d += digsum(i * base, 0) }
    put(h, " ", c, " ", g, " ", d, "\n")
}
