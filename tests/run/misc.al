const N = 5
const SCALE f64 = 2.5
const NAME = "al"
const MASK u32 = 0xFF00
var counter i64
var table [N]i64
var primes = [5]i64{2, 3, 5, 7, 11}
var ratio = 0.5
var greeting = "hi"

fn bump() i64 {
    counter += 1; counter
}
fn apply(f fn(i64) i64, x i64) i64 { f(x) }
fn dbl(x i64) i64 { x * 2 }
fn cleanup_demo() i64 {
    defer { print("deferred 1") }
    defer { print("deferred 2") }
    print("body")
    return 7
}
fn main() {
    print(N, SCALE, NAME, MASK, N * 2, SCALE * 2.0)
    bump(); bump()
    print(counter, bump())
    for i in 0..N {
        table[i] = primes[i] * N
    }
    print(table, primes[4], ratio, greeting)
    print(apply(dbl, 21))
    var fs [2]fn(i64) i64
    fs[0] = dbl
    fs[1] = bump_by
    print(fs[0](5), fs[1](5))
    print(cleanup_demo())
    s := "abc"
    print(s == "abc", s != "abd", s == "ab", len(s))
    var x u8 = 'A'
    putc(x + 1); putc('\n')
    print('a', "tab\there", "q\"q")
    {
        defer { print("scope exit") }
        print("in scope")
    }
    for i in 0..2 {
        defer { print("iter end", i) }
        if i == 0 {
            continue
        }
        print("iter", i)
    }
    print(1 + 2.5, 7 / 2.0, 1 < 2.5)
    print(f64(u64(18446744073709551615)), f64(u64(9223372036854775808)), f64(u64(12)))
}
fn bump_by(x i64) i64 { x + 100 }
