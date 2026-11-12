// as_i64 of a JSON number outside the i64 range gave i64 MIN (float to integer overflow) instead of a
// documented result. Now: default.
// expected: 42 42   actual (before the fix): MIN MIN
use std.asset
fn main() {
    a, _ := json_parse("1e19")
    b, _ := json_parse("-1e400")
    print(a.as_i64(42), b.as_i64(42))
}
