// unwrap of an absent value stops the program
fn parse(s: str) -> Opt[i64] {
    v, ok := parse_i64(s)
    if !ok {
        return None
    }
    Some(v)
}
fn main() {
    print(parse("12").unwrap())
    print(parse("twelve").unwrap())
    print("not reached")
}
