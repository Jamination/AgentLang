// `main` and `test` blocks cannot be private.
priv fn helper() -> i64 { 1 }

priv fn main() {
    print(helper())
}

priv test "nothing" {
    assert helper() == 1
}

priv use "priv/lib.al"
