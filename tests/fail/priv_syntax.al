// `priv` stands once in front of a declaration.
priv priv fn twice(x i64) i64 { x * 2 }

priv 5

priv ok :: () -> i64 { 1 }

local :: () {
    priv x := 1
}

struct S {
    priv a i64
}

enum E {
    priv A
}

main :: () {}
