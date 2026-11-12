// A keyword where a name is expected: the message says that it is a keyword.
struct S { in: i64 }
struct T { test: i64, x: i64 }
fn f(in: i64) -> i64 { 1 }
fn g(a: i64, by: i64) -> i64 { 1 }
fn h(loop: i64) {}
fn k() {
    for match in 0..3 { }
}
fn l() {
    for i, test in "ab" { }
}
fn m() {
    by := 0
}
fn n(s: S) {
    s.in = 3
}
enum E { A, match }
const test = 1
fn loop() {}
