// json_parse rejects what RFC 8259 does not allow: parse_f64's wider number syntax and raw
// control characters in strings; valid numbers and escapes still work; nesting is limited to 200.
use std.asset

fn main() {
    for s in []str{"+1", ".5", "5.", "01", "-.5", "1.e5", "[00]", "-", "1e", "1e+", "--1", "\"a\nb\"", "\"tab\there\"", "[\"\x01\"]"} {
        _, ok := json_parse(s)
        print(fmt("[", s, "]"), ok, json_error_line(s))
    }
    for s in []str{"0", "-0", "10", "0.5", "-1.25e+2", "1E3", "2e-2", "[0,1,-2]", "\"\\u00e9\\n\\t\"", "{\"a\": [1.5e1]}"} {
        v, ok := json_parse(s)
        print(s, ok, v.as_f64(-99.0), v.at(0).as_f64(-99.0), len(v.as_str("")))
    }
    deep := concat(repeat("[", 200), repeat("]", 200))
    _, ok200 := json_parse(deep)
    deeper := concat(repeat("[", 100000), repeat("]", 100000))
    _, ok201 := json_parse(deeper)
    print(ok200, ok201, json_error_line(deeper))
}
