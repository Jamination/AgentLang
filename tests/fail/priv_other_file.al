// Private declarations of another file are unknown names here.
use "priv/lib.al"

priv fn owner_secret() -> i64 { 1 }
priv const OWNER_LIMIT = 2

fn main() {
    c := Ctx{"x"}
    d: Ctx
    m: Mode
    print(LIMIT)
    print(bump())
    counter = 1
    made := lib_make()
    // the library's `find` is the one visible here
    made.find(1)
    print(counter + 1)
    print(pick[i64](1, 2))
    print(owner_secret() + OWNER_LIMIT)
}
