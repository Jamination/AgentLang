// mulhi needs two integers of the same type
fn main() {
    a := 5
    var b u32 = 7
    print(mulhi(a, b))
    print(mulhi(1.5, 2.5))
    print(mulhi(a))
    print(mulhi("x", a))
    print(mulhi(b, 5000000000))
    var f f64 = 2.0
    print(mulhi(3, f))
}
