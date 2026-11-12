// std.asset json_parse accepted text that is not JSON (RFC 8259), although the doc says
// "(nil, false) if it is not valid JSON": numbers in parse_f64's wider syntax (+1, .5, 5., 01, 1.e5)
// and raw control characters inside strings.
// expected: false for every line; actual (before the fix): true
use std.asset
fn main() {
    for s in []str{"+1", ".5", "5.", "01", "-.5", "1.e5", "[00]", "\"a\nb\"", "\"tab\there\""} {
        _, ok := json_parse(s)
        print(ok)
    }
}
