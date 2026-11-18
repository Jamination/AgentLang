// A bracket that is never closed: the error names where it was opened. A closing bracket that
// stands left of the indentation of the line that opened its bracket was meant for an outer
// one: the inner bracket is named.
struct P { a: i64, s: str }
const T = [_]P{
    P{1, "x"},
    P{2, "y",
}
fn call() {
    x := max(1, 2
    y := 3
}
fn index(v: []i64) {
    v[1 = 2
}
fn lit() {
    a := [3]i64{1, 2
}
struct S {
    a: i64
fn after_struct() {}
enum E {
    A, B
const K = 1
fn arms(n: i64) -> i64 {
    return match n {
        0 => 1
        _ => 2
}
fn closed_later(a: i64 b: i64) {}
fn tuple() {
    t := (1, 2
}
fn main() {
    if true {
        print(1)
