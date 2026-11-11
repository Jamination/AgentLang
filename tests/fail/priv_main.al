// `main` and `test` blocks cannot be private.
priv helper :: () -> i64 { 1 }

priv main :: () {
    print(helper())
}

priv test "nothing" {
    assert helper() == 1
}

priv use "priv/lib.al"
