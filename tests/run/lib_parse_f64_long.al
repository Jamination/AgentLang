// Exponents larger than 99999 are not cut off: they can balance a long run of digits.
fn main() {
    zeros := repeat("0", 100000)
    a, oka := parse_f64(fmt("0.", zeros, "15e100001"))
    b, okb := parse_f64(fmt("25", zeros, "e-100001"))
    c, okc := parse_f64("1e123456789012345678901234567890")
    d, okd := parse_f64("-1e-123456789012345678901234567890")
    print(a, oka, b, okb, c, okc, d, okd)
}
