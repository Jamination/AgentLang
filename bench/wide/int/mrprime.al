// deterministic Miller-Rabin over 64-bit odd numbers with Montgomery multiplication (mulhi)
inline fn mont_mul(a: u64, b: u64, n: u64, ninv: u64) -> u64 {
    lo := a * b
    hi := mulhi(a, b)
    m := lo * ninv
    mh := mulhi(m, n)
    t := hi - mh
    if hi < mh { t + n } else { t }
}

fn is_prime(n: u64) -> bool {
    ninv := n
    for _ in 0..5 {
        ninv *= 2 - n * ninv
    }
    one := (0 - n) % n
    r2 := one
    for _ in 0..64 {
        r2 = r2 + r2
        if r2 >= n { r2 -= n }
    }
    nm1 := n - one
    d := n - 1
    s := 0
    while d & 1 == 0 {
        d >>= 1
        s += 1
    }
    bases := [12]u64{2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37}
    for a in bases {
        x := one
        b := mont_mul(a, r2, n, ninv)
        e := d
        while e != 0 {
            if e & 1 != 0 { x = mont_mul(x, b, n, ninv) }
            b = mont_mul(b, b, n, ninv)
            e >>= 1
        }
        if x == one || x == nm1 { continue }
        found := false
        for _ in 1..s {
            x = mont_mul(x, x, n, ninv)
            if x == nm1 {
                found = true
                break
            }
        }
        if !found { return false }
    }
    true
}

fn main() {
    base: u64 = 0x4000_0000_0000_0001
    count := 0
    xs: u64 = 0
    for k in 0..2000000 {
        n := base + u64(k) * 2
        if is_prime(n) {
            count += 1
            xs ^= n * 0x9E3779B97F4A7C15
        }
    }
    put(count, " ", xs, "\n")
}
