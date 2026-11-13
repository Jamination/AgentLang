// The float default: an untyped float literal or constant without an expected type is an f32;
// where an f64 is expected it is the f64 nearest to it. Either way it is rounded once.
const THIRD = 1.0 / 3.0
const TENTH = 0.1
const DT = f64(1) / 60.0                       // the value has a type: an f64 constant
const H = 1.00000005960464477539062500000001   // just above the midpoint of 1.0 and 1.0000001

fn pick(x: f32) -> str { "f32" }
fn pick(x: f64) -> str { "f64" }
noinline fn id[T](x: T) -> T { x }
fn half(x: f64) -> f64 { x / 2.0 }

g := 0.1                                       // a global: f32 too

fn main() {
    a := 0.1
    b: f64 = 0.1
    print(a, b, f64(a), 1.0 / 3.0, THIRD, f64(THIRD), TENTH, half(TENTH), DT)
    print(pick(1.5), pick(b), pick(TENTH), pick(DT), pick(id(2.5)), pick(g), pick(0.5 * DT), pick(2.0 * 3.0))
    // rounded once from the text: as an f32 1.0000001, as an f64 1.0000000596046448
    print(H, f64(H), -H, pick(H))
    // an untyped operand, branch or match arm takes the type of the other one
    k := clock_ns() > 0
    m := match k { true => 0.5; false => b }
    n := if k { 2.0 } else { b }
    o := if k { 2.0 } else if b > 1.0 { b } else { 1.0 }
    s := sqrt(2.0) * b
    t := sqrt(2.0)
    print(pick(m), pick(n), pick(o), s, t, pick(s), pick(t), pick(fmin(1.5, b)), pick(-0.5 * fabs(-b)))
    // to an integer: the untyped float's exact value (as in a constant), not its f32
    print(i64(16777217.0), u64(1e19), i64(id(16777217.0)), i64(THIRD * 3e9))
    // printing with fixed digits: the exact value of the f32 or f64
    print(fmtf(0.1, 12), fmtf(b, 12), fmtf(2.5, 1, 6))
    putf(TENTH, 10)
    putc('\n')
    // parse_f32 rounds once from the text (f32(parse_f64(..)) would give 1.0 for the first)
    print(parse_f32("1.00000005960464477539062500000001"), parse_f32("1.00000005960464477539062499999999"), parse_f32("-0.1"), parse_f32("1e39"), parse_f32("1.5x"))
    print(parse_f32("340282356779733661637539395458142568447"), parse_f32("7.006492321624085354618647916449580656401309709382578858785341419448955413429303007433190941810607910156251e-46"))
}
