// constants in read-only memory cannot be assigned to or have their address taken
Point :: struct { x: i64, y: i64 }
Body :: struct { pos: vec3, id: i64 }
TABLE :: [4]i64{1, 2, 4, 8}
ORIGIN :: Point{x: 0, y: 0}
GRID :: [2][2]i64{[2]i64{1, 2}, [2]i64{3, 4}}
UP :: vec3(0.0, 1.0, 0.0)
BODY :: Body{pos: UP, id: 1}
LIMIT :: 10
PAIR :: (1, "one")

n :: () -> i64 { 3 }
BAD1 :: [2]i64{1, n()}
BAD2 :: Point{x: n()}
BAD3 : [3]i64 : [4]i64{1, 2, 3, 4}
BAD4 :: [2]i64{1, 2, 3}
SELF :: [2]Point{ORIGIN, SELF2}
SELF2 :: SELF
BAD5 :: embed("data/no_such_file.txt")
BAD6 :: embed(LIMIT)
BAD7 :: (1, n())
BAD8 :: Unknown{x: 1}

poke :: (p: *Point) { p.x = 1 }

main :: () {
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
