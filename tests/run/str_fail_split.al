// A string function that is called wrongly names the line of the call, not a line of the library.
fn main() {
    print("before")
    // the next line fails
    // (a programming error, not bad input)
    sep := ""
    print(split("abc", sep))
    print("after")
}
