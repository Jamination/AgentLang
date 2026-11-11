// Within one file a name is private or public, not both.
priv area :: (x: i64) -> i64 { x }
area :: (x: f64) -> f64 { x }

scale :: (x: i64) -> i64 { x }
priv scale :: (x: f64) -> f64 { x }
priv scale :: (x: str) -> str { x }

priv LIMIT :: 1
LIMIT: i64

Point :: struct { x: i64 }
priv Point :: (x: i64) -> i64 { x }

// a private name hides a variant of the same file
priv Red :: () -> i64 { 0 }
Color :: enum { Red, Green }

// all private, different parameter types: fine
priv ok :: (x: i64) -> i64 { x }
priv ok :: (x: str) -> str { x }

main :: () {
    print(ok(1), ok("s"))
}
