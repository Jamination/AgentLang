// std.asset: JSON construction, escaping, compact and pretty serialization, and parse round-trip.
use std.asset

fn main() {
    doc := json_object([](str, Json){
        ("name", json_string("a\"b\\c\n\t\x01")),
        ("count", json_int(42)),
        ("ok", json_bool(true)),
        ("none", json_null()),
        ("nan", json_num(0.0 / 0.0)),
        ("arr", json_array([]Json{json_int(1), json_bool(false), json_string("x")})),
        ("empty_arr", json_array(nil)),
        ("empty_obj", json_object(nil)),
    })
    compact := json_stringify(&doc)
    print("compact:", compact)
    parsed, pok := json_parse(compact)
    print("roundtrip:", pok, parsed.get("name").as_str("") == "a\"b\\c\n\t\x01", parsed.get("count").as_i64(0), parsed.get("ok").as_bool(false), parsed.get("nan").is_null(), parsed.get("arr").at(2).as_str(""))
    pretty := json_stringify_pretty(&doc, 2)
    print("pretty_lines:", len(lines(pretty)), find(pretty, "\n  \"count\": 42") >= 0)
    print("escape:", json_escape("hi\r\n\"x\""))
}
