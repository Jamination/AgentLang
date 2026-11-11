// `priv` stands once in front of a declaration.
priv priv twice :: (x: i64) -> i64 { x * 2 }

priv 5

priv fn ok() -> i64 { 1 }

fn local() {
    priv x := 1
}

struct S {
    priv a: i64
}

enum E {
    priv A
}

inline priv late :: () {}

fn main() {}
