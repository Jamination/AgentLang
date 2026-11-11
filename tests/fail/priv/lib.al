// Helper of tests/fail/priv_other_file.al and priv_used_from.al.
priv struct Ctx { name: str }
priv enum Mode { LibOn, LibOff }
priv const LIMIT = 3
priv counter: i64
priv fn bump() -> i64 {
    counter += 1
    counter
}
priv fn find(c: Ctx, x: i64) -> i64 { x }
priv fn pick[T](a: T, b: T) -> T { a }
fn lib_make() -> Ctx { Ctx{"made"} }
fn lib_uses_owner() -> i64 {
    // private to the file that includes this one: not visible here either
    return owner_secret() + OWNER_LIMIT
}
