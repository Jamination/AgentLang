use std.asset
fn dump(v: *Json, b: *Vec[u8]) {
    match v.kind {
        JsonNull => b.extend("n")
        JsonBool => b.extend(if v.num != 0.0 { "t" } else { "f" })
        JsonNumber => b.extend(fmt("#", hex(cast[u64](v.num)), "|", v.as_i64(0), "|"))
        JsonString => { b.extend("s"); b.extend(hex_str(v.text)) }
        JsonArray => {
            b.extend("[")
            for i in 0..v.count() { dump(v.at(i), b); b.extend(",") }
            b.extend("]")
        }
        JsonObject => {
            b.extend("{")
            for i in 0..v.count() { b.extend(hex_str(v.at(i).key)); b.extend(":"); dump(v.at(i), b); b.extend(",") }
            b.extend("}")
        }
    }
}
fn hex_str(s: str) -> str {
    b := vec[u8]()
    b.extend("'")
    for c in s { b.extend(hex(u64(c), 2)) }
    b.extend("'")
    b.items()
}
fn main() {
    a := args()
    for i in 1..len(a) {
        put(a[i], " ")
        flush()
        data, _ := read_file(a[i])
        v, ok := json_parse(data)
        if !ok { print("bad"); continue }
        b := vec[u8]()
        dump(v, &b)
        print(b.items())
    }
}
