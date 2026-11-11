// unwrap of an error stops the program with its message
fn parse(s str) Res[i64] {
    v, ok := parse_i64(s)
    if !ok {
        return Err(fmt("not a number: ", s))
    }
    Ok(v)
}
fn main() {
    print(parse("12").unwrap())
    print(parse("twelve").unwrap())
    print("not reached")
}
