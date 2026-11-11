// Helper of tests/fail/priv_other_file.al and priv_used_from.al.
priv Ctx :: struct { name: str }
priv Mode :: enum { LibOn, LibOff }
priv LIMIT :: 3
priv counter: i64
priv bump :: () -> i64 {
    counter += 1
    counter
}
priv find :: (c: Ctx, x: i64) -> i64 { x }
priv pick[T] :: (a: T, b: T) -> T { a }
lib_make :: () -> Ctx { Ctx{"made"} }
lib_uses_owner :: () -> i64 {
    // private to the file that includes this one: not visible here either
    return owner_secret() + OWNER_LIMIT
}
