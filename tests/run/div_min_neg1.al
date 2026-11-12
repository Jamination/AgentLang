// MIN / -1 and MIN % -1 wrap in every mode and width (regression: --unchecked died with an arithmetic fault)
noinline fn id[T](x: T) -> T { x }
fn main() {
    a := id(-0x7FFFFFFFFFFFFFFF - 1)
    b: i32 = id(i32(-0x7FFFFFFF) - 1)
    c: i16 = id(i16(-0x7FFF) - 1)
    d: i8 = id(i8(-0x7F) - 1)
    print(a / id(-1), a % id(-1), b / id(i32(-1)), b % id(i32(-1)), c / id(i16(-1)), c % id(i16(-1)), d / id(i8(-1)), d % id(i8(-1)))
    x := id(7)
    x /= id(-1)
    print(x, id(-7) % id(-2), id(7) / id(-2))
}
