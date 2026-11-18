// operands of different types: the operator and each operand are named (two comparisons on
// one line are told apart), a long operand by its side
struct Pair { a: i64, b: i64 }
fn main() {
    e1 := true
    e2 := false
    assert e1 == "" && e2 == ""
    x: i32 = 1
    y := 2
    print(x + y * 2)
    p := Pair{1, 2}
    print(p.a == 1.5)
    print(max(p.a + p.b + p.a + p.b + p.a + p.b, p.a + p.b + p.a + p.b) < x)
}
