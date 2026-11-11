// Within one file a name is private or public, not both.
priv fn area(x i64) i64 { x }
fn area(x f64) f64 { x }

fn scale(x i64) i64 { x }
priv fn scale(x f64) f64 { x }
priv fn scale(x str) str { x }

priv const LIMIT = 1
var LIMIT i64

struct Point { x i64 }
priv fn Point(x i64) i64 { x }

// a private name hides a variant of the same file
priv fn Red() i64 { 0 }
enum Color { Red, Green }

// all private, different parameter types: fine
priv fn ok(x i64) i64 { x }
priv fn ok(x str) str { x }

fn main() {
    print(ok(1), ok("s"))
}
