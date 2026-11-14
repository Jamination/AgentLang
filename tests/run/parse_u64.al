// parse_u64: the conventions of parse_i64 over the whole range of u64; out of range or bad text
// gives (0, false)
fn show(s: str) {
    v, ok := parse_u64(s)
    print(s, "->", v, ok)
}

fn show(s: str, base: i64) {
    v, ok := parse_u64(s, base)
    print(s, base, "->", v, ok)
}

fn main() {
    for s in []str{"0", "+0", "42", "+42", "18446744073709551615", "18446744073709551616",
                   "99999999999999999999", "-0", "-1", "", "+", "-", " 1", "1 ", "1_000", "0x10", "00017", "9223372036854775808"} {
        show(s)
    }
    show("ffffffffffffffff", 16)
    show("FFFFFFFFFFFFFFFF", 16)
    show("10000000000000000", 16)
    show("1111111111111111111111111111111111111111111111111111111111111111", 2)
    show("11111111111111111111111111111111111111111111111111111111111111111", 2)
    show("3w5e11264sgsf", 36)
    show("3w5e11264sgsg", 36)
    show("z", 35)
    show("0xffffffffffffffff", 0)
    show("+0b101", 0)
    show("0o777", 0)
    show("017", 0)
    show("-0x1", 0)
    show("0x", 0)
    show("0x10", 16)
    // every value round-trips through to_base in every base
    x: u64 = 0xFFFF_FFFF_FFFF_FFFF
    bad := 0
    for k in 0..200 {
        for b in 2..=36 {
            v, ok := parse_u64(to_base(x, b), b)
            if !ok || v != x {
                bad += 1
            }
        }
        x = x / 3 + u64(k)
    }
    print("round trips failed:", bad)
    // parse_i64 still parses its full range
    print(parse_i64("-9223372036854775808"), parse_i64("9223372036854775807"), parse_i64("9223372036854775808"), parse_i64("-0x8000000000000000", 0))
}
