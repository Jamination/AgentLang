// multi-limb arithmetic: schoolbook multiply with u32 limbs and u64 products, add with carries on u64 limbs
fn mul(a: []u32, b: []u32, r: []u32) {
    for k in 0..len(r) { r[k] = 0 }
    nb := len(b)
    for i in 0..len(a) {
        carry: u64 = 0
        ai := u64(a[i])
        for j in 0..nb {
            t := ai * u64(b[j]) + u64(r[i + j]) + carry
            r[i + j] = u32(t)
            carry = t >> 32
        }
        r[i + nb] = u32(carry)
    }
}

fn add(a: []u64, b: []u64, r: []u64) -> u64 {
    carry: u64 = 0
    for i in 0..len(a) {
        s := a[i] + carry
        c1: u64 = if s < carry { 1 } else { 0 }
        s2 := s + b[i]
        c2: u64 = if s2 < s { 1 } else { 0 }
        r[i] = s2
        carry = c1 + c2
    }
    carry
}

fn main() {
    n := 1200
    a := alloc[u32](n)
    b := alloc[u32](n)
    r := alloc[u32](2 * n)
    seed: u64 = 1
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        a[i] = u32(seed >> 32)
        seed = seed * 6364136223846793005 + 1442695040888963407
        b[i] = u32(seed >> 32)
    }
    chk: u32 = 0
    for rep in 0..250 {
        a[rep] ^= chk
        mul(a, b, r)
        for k in 0..2 * n { chk = chk * 31 + r[k] }
    }
    m := 2048
    x := alloc[u64](m)
    y := alloc[u64](m)
    z := alloc[u64](m)
    x[0] = 1
    y[0] = 1
    carries: u64 = 0
    for it in 0..150000 {
        carries += add(x, y, z)
        t := x
        x = y
        y = z
        z = t
    }
    xs: u64 = 0
    for k in 0..m { xs = xs * 1099511628211 ^ y[k] }
    put(chk, " ", carries, " ", xs, "\n")
}
