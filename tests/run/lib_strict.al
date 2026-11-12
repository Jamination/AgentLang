// parse_i64 overflow, len of a Map, sort / min / max on strings, vec_of / vec_fill,
// and the Vec functions that check their arguments.
fn main() {
    print(parse_i64("9223372036854775807"), parse_i64("9223372036854775808"), parse_i64("-9223372036854775808"))
    print(parse_i64("-9223372036854775809"), parse_i64("99999999999999999999999"), parse_i64("+0"), parse_i64("-12"), parse_i64("18446744073709551616"))
    m := map[str, i64]()
    m.set("a", 1)
    m.set("b", 2)
    print(len(m), m.len, m.len(), len(&m))
    names := []str{"pear", "apple", "fig", "app"}
    sort(names)
    print(names, min("b", "a"), max("b", "ab"), min("", "a"), max("x", "x"), min(3, 2), max(1.5, 2.5))
    bytes := clone("hello")
    sort(bytes)                                    // a str is a []u8: sorts the bytes
    print(bytes)
    v := vec_of(names)
    v.push("zz")
    w := vec_fill(3, 7)
    w[1] = 8
    print(v[..], names.len, w[..], vec_fill(0, "x").len, vec_of([]i64{}).is_empty())
    v.truncate(9)
    v.truncate(3)
    v.insert(3, "end")
    v.insert(0, "start")
    print(v[..], v.remove(1), v.swap_remove(0), v.last(), v.pop(), v[..])
    v.truncate(0)
    print(v.len)
}
