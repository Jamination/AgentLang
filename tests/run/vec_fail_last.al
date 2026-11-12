// A failing Vec function names the line of the call, not a line of the library.
fn main() {
    v := vec[i64]()
    print("before")
    // the next line fails
    print(v.last())
    print("after")
}
