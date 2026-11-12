// path_join("a//", "b") gave "a//b" (doc: exactly one '/'); path_stem("..") gave "." and
// path_ext("..a") "a" (pathlib: stem "..", "..a", no suffix).
// expected: a/b .. ..a   actual (before the fix): a//b . .
use std.asset
fn main() {
    print(path_join("a//", "b"), path_stem(".."), path_stem("..a"))
}
