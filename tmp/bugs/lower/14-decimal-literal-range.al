// a decimal literal must fit its type; hex / binary / octal / character literals may be bit patterns
const C1: i8 = 200
const C2: i64 = 9223372036854775808
G1 := [2]i8{1, 128}
fn main() {
    a: i8 = 128
    b := 9223372036854775808
    c := -18446744073709551615
    d: i32 = 2147483648
    ok1: i8 = 0xFF
    ok2 := 0xFFFF_FFFF_FFFF_FFFF
    ok3: i8 = -128
    ok4 := -9223372036854775808
    ok5: u64 = 18446744073709551615
    ok6: i8 = '\xFF'
    print(a, b, c, d, ok1, ok2, ok3, ok4, ok5, ok6, C1, C2, G1)
}
