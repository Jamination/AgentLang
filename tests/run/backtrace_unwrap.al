// unwrap of None names no line itself: the trace does
fn find(names: []str, want: str) -> Opt[i64] {
    for i, n in names {
        if n == want { return Some(i) }
    }
    None
}

fn index_of_name(names: []str, want: str) -> i64 {
    return find(names, want).unwrap()
}

fn main() {
    names := []str{"ann", "bob"}
    print(index_of_name(names, "bob"))
    print(index_of_name(names, "cid"))
}
