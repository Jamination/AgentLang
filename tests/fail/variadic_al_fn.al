// `...` belongs to C functions only: an AL function, a nested or anonymous one and a function
// type take a slice instead
fn sum(first: i64, ...) -> i64 {
    first
}
fn main() {
    fn inner(a: i64, ...) {}
    f := fn(a: i64, ...) -> i64 { a }
    g: fn(i64, ...) -> i64 = sum
    print(sum(1, 2))
}
