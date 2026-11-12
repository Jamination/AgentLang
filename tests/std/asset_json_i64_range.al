// as_i64 of a number outside the range of i64 gives the default (it gave i64 MIN through the
// float to integer conversion); integer literals keep all 64 bits, others are truncated
use std.asset

fn main() {
    for s in []str{"1e19", "-1e400", "1e400", "9223372036854775808", "-9223372036854775809", "9223372036854775807", "-9223372036854775808", "-9.2233720368547e18", "2.9", "-2.9", "1e3"} {
        v, _ := json_parse(s)
        print(s, v.as_i64(42))
    }
}
