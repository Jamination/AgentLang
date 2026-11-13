// Built with --gui and started by gui.c in several ways: writes 1000 lines to standard output
// and one to standard error, reads standard input, and panics if asked to. Without standard
// handles all of it must succeed silently: the exit status (42) is then the only result.
fn main() -> i64 {
    a := args()
    for i in 0..1000 {
        print("out", i)
    }
    eprint("err line")
    input := read_all(0)
    print("input", len(input))
    if len(a) > 1 && a[1] == "panic" {
        panic("boom")
    }
    42
}
