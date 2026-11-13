// a branch that is not taken is parsed, not type-checked: nothing in it is an error, also
// not a file it includes that does not exist
const ON = false

when ON {
    use "no/such/file.al"
    fn f() -> i64 { "text" }
    fn g() { undefined_function(1, 2) }
} else when !ON {
    fn f() -> i64 { 1 }
}

fn main() {
    when ON {
        x: i64 = "text"
        y := missing + 1
    }
    print(f())
}
