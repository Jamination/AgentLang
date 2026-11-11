// constants in read-only memory cannot be assigned to or have their address taken
struct Point { x i64, y i64 }
struct Body { pos vec3, id i64 }
const TABLE = [4]i64{1, 2, 4, 8}
const ORIGIN = Point{x: 0, y: 0}
const GRID = [2][2]i64{[2]i64{1, 2}, [2]i64{3, 4}}
const UP = vec3(0.0, 1.0, 0.0)
const BODY = Body{pos: UP, id: 1}
const LIMIT = 10
const PAIR = (1, "one")

fn n() i64 { 3 }
const BAD1 = [2]i64{1, n()}
const BAD2 = Point{x: n()}
const BAD3 [3]i64 = [4]i64{1, 2, 3, 4}
const BAD4 = [2]i64{1, 2, 3}
const SELF = [2]Point{ORIGIN, SELF2}
const SELF2 = SELF
const BAD5 = embed("data/no_such_file.txt")
const BAD6 = embed(LIMIT)
const BAD7 = (1, n())
const BAD8 = Unknown{x: 1}

fn poke(p *Point) { p.x = 1 }

fn main() {
    TABLE = [4]i64{0, 0, 0, 0}
    TABLE[1] = 5
    ORIGIN.x = 1
    GRID[1][0] += 2
    UP.y = 0.0
    BODY.pos.x = 1.0
    BODY.id = 2
    LIMIT = 11
    PAIR.0 = 2
    p := &ORIGIN
    q := &TABLE[2]
    r := &GRID[0]
    poke(&ORIGIN)
    TABLE, LIMIT = (TABLE, 1)
    print(p, q, r)
}
