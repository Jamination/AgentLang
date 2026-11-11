// `priv` stands once in front of a declaration.
priv priv twice :: (x: i64) -> i64 { x * 2 }

priv 5

priv ok :: () -> i64 { 1 }

local :: () {
    priv x := 1
}

S :: struct {
    priv a: i64
}

E :: enum {
    priv A
}

inline priv late :: () {}

main :: () {}
