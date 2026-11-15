// a negative number of digits for fmtf / putf is an argument error that names the caller's line
// (each case runs in a process of its own: this program, started again with its number)
use std.os

fn cases() -> []fn() {
    []fn(){
        fn() { print(fmtf(1.5, -1)) },
        fn() { print(fmtf(1.5, -2, 8)) },
        fn() { putf(1.5, -3) },
    }
}

fn main() {
    a := args()
    if len(a) > 2 && a[1] == "case" {
        k, _ := parse_i64(a[2])
        cases()[k]()
        print("not stopped")
        return
    }
    print(fmtf(2.5, 0), fmtf(2.5, 1, 6))
    for k in 0..len(cases()) {
        print("exit status", run([]str{a[0], "case", fmt(k)}))
    }
}
