// A keyword where a name is expected: the message says that it is a keyword. (`in`, `by` and
// `test` are keywords only in their place, elsewhere names: tests/run/contextual_keywords.al)
struct S { loop: i64 }
struct T { defer: i64, x: i64 }
fn f(use: i64) -> i64 { 1 }
fn g(a: i64, while: i64) -> i64 { 1 }
fn h(loop: i64) {}
fn k() {
    for match in 0..3 { }
}
fn l() {
    for i, defer in "ab" { }
}
fn m() {
    use := 0
}
fn n(s: S) {
    s.loop = 3
}
enum E { A, match }
const extern = 1
fn loop() {}
fn o() {
    test "inside" { }
}
