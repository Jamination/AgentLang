// File-private declarations: three files declare the same names with `priv`, each sees its own.
use "priv/shapes.al"
use "priv/queue.al"

priv struct Ctx { n: i64, tag: str }
priv enum Mode { MainFast, MainSlow }
priv const LIMIT = 10
priv counter: i64
priv table := [3]i64{1, 2, 3}

priv fn find(c: Ctx, x: i64) -> i64 { c.n + x }
priv fn find(c: *Ctx, s: str) -> str { concat(c.tag, s) }
priv fn bump() -> i64 {
    counter += 1
    counter
}
priv fn describe(m: Mode) -> str {
    match m {
        MainFast => "fast"
        MainSlow => "slow"
    }
}

// public, overloaded by private definitions of the other files
fn show(x: i64) -> str { fmt("main-int:", x) }

fn main() {
    c := Ctx{n: 5, tag: "main-"}
    print(c, c.find(1), find(c, 2), c.find("x"))
    print(LIMIT, bump(), bump(), counter, table[2])
    print(describe(MainSlow), MainFast)
    // the same names in the other files mean other things
    shapes_run()
    queue_run()
    // main's own are untouched by the calls above
    print(counter, LIMIT, bump())
    // `find` on text is still the library function here
    print(find("hello", "l"))
    // public functions of the other files work as always, also on values of their private types
    q := queue_make()
    queue_put(&q, 7)
    queue_put(&q, 8)
    print(queue_total(&q), q)
    // a variant of another file's private enum is an ordinary variant
    m := QueueFull(3)
    print(m)
    print(show(4))
}
