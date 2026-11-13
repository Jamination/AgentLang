// errors in a taken branch are reported like any other
const ON = true
when ON {
    fn f() -> i64 { "text" }
}
fn main() {
    when ON {
        x: i64 = "text"
    }
}
