struct J { id: i64, name: str }
fn num(s: str) -> (i64, str) { (len(s), "") }
fn main() {
    j: J
    err := ""
    xs := []i64{0, 0}
    a := 0
    a, err = num("abc")
    j.id, err = num("abcd")
    xs[1], j.name = num("ab")
    print(a, j, xs, err)
}
struct M { job: Opt[i64], n: i64 }
test "zero Opt is None" {
    m: M
    o: Opt[str]
    assert m.job == None && o == None
}
