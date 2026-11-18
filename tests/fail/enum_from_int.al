// Color(i): a constant number that is no variant's, an enum with data, variant_count of a
// type that is not an enum
enum Color { Red, Green, Blue }
enum Shape { Circle(f64), Empty }

const BAD = Color(3)
const NEG = Color(-1)

fn main() {
    print(Color(7))
    print(Shape(1))
    print(variant_count[i64]())
    print(variant_count[Color](1))
    print(Color(1.5))
}
