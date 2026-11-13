// what a `when` condition cannot use: variables, calls, other operators, non-bool values
counter := 0
fn on() -> bool { true }
const LIMIT = 3
const BAD = on()

when counter == 0 { }
when on() { }
when LIMIT > 2 { }
when LIMIT { }
when BAD { }

fn main() {
    x := 1
    when x == 1 { }
}
