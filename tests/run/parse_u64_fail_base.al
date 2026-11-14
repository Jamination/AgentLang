// parse_u64 with a base outside 0, 2..36 names the line of the call
fn main() {
    print("before")
    v, ok := parse_u64("10", 1)
    print(v, ok)
}
