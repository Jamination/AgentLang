// a branch that is not taken is still parsed: its syntax errors are reported
const ON = false
when ON {
    fn f( { }
}
when ON { } else if ON { }
fn main() {
    when ON {
        x := := 1
    }
}
