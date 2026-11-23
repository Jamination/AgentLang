// Monte Carlo with a xorshift64* generator producing doubles
struct Gen { s: u64 }

fn next_double(g: *Gen) -> f64 {
    x := g.s
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    g.s = x
    r := x * 2685821657736338717
    f64(r >> 11) * (1.0 / 9007199254740992.0)
}

fn main() {
    g := Gen{88172645463325252}
    n := 40000000
    in2 := 0
    in3 := 0
    under := 0
    for i in 0..n {
        x := next_double(&g)
        y := next_double(&g)
        z := next_double(&g)
        if x * x + y * y < 1.0 {
            in2 += 1
            if x * x + y * y + z * z < 1.0 {
                in3 += 1
            }
        }
        // area under y = x^2 - x^3 + 0.5 over [0, 1]
        if y < x * x - x * x * x + 0.5 {
            under += 1
        }
    }
    print(in2, in3, under)
}
