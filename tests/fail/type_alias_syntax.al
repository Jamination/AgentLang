// a type alias cannot be generic; `type` needs a name, `=` and a type
type H[T] = Vec[T]
type I = 5
type J i64
fn main() {
    // `type` is an ordinary identifier everywhere else
    type := 3
    print(type)
}
