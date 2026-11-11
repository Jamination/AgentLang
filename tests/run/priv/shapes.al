// Helper of tests/run/priv_files.al: the same private names as the main file and queue.al.
priv Ctx :: struct { name: str }
priv Mode :: enum { ShapeRound, ShapeSquare(i64) }
priv LIMIT :: "limit of shapes"
priv counter: f64
priv table := [2]str{"circle", "square"}

priv find :: (c: Ctx, x: i64) -> i64 { len(c.name) * x }
priv bump :: () -> f64 {
    counter += 0.5
    counter
}
priv describe :: (m: Mode) -> str {
    match m {
        ShapeRound => "round"
        ShapeSquare(side) => fmt("square of ", side)
    }
}
priv show :: (s: str) -> str { fmt("shapes-str:", s) }

shapes_run :: () {
    c := Ctx{"bee"}
    print(c, c.find(2), find(c, 3), LIMIT, bump(), bump(), counter, table[1])
    print(describe(ShapeSquare(4)), describe(ShapeRound))
    // the private `show` for text, the public one of the main file for integers
    print(show("s"), show(1))
}
