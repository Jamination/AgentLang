// constants that are not scalars: aggregates in read-only memory, embed() in const / var
struct Point { x: i64, y: i64 }
struct Named { name: str, at: Point, tags: [2]str, f: fn(i64) -> i64, scale: f32 }

const TABLE = [4]i64{1, 2, 4, 8}
const ORIGIN = Point{x: 0, y: 0}
const UNIT: Point = Point{1, 1}
const NAMES = [2]str{"a", "bb"}
const N = 3
const GRID = [2][3]u8{[3]u8{1, 2, 3}, [3]u8{4, 5, 6}}
const PARTIAL: [8]i32 = [8]i32{-1, N, N * 2}
const THING = Named{name: "thing", at: UNIT, tags: NAMES, f: double, scale: 2.5}
const PAIR = (N, "three", 3.5)
const COPY = TABLE
const CORNERS = [3]Point{ORIGIN, UNIT, Point{y: N}}
const UP = vec3(0.0, 1.0, 0.0)
const IDENT = mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0))
const OPS = [2]fn(i64) -> i64{double, negate}
const TEXT = embed("data/const_embed.txt")
const TEXT_LEN = 21
const EMPTY = [0]i64{}
const BYTES = [4]u8{'a', 'b', 0xFF, 0}
const FLAGS = [3]bool{true, false, true}
const FLOATS = [3]f64{1, 2.5, -N}

blob := embed("data/const_embed.txt")
blob2: str = embed("data/const_embed.txt")
table_copy := TABLE
corner := UNIT

fn double(x: i64) -> i64 { x * 2 }
fn negate(x: i64) -> i64 { -x }
fn sum(xs: []i64) -> i64 {
    t := 0
    for x in xs {
        t += x
    }
    t
}
fn sum4(a: [4]i64) -> i64 { a[0] + a[1] + a[2] + a[3] }
fn norm1(p: Point) -> i64 { p.x + p.y }
fn shifted(p: Point) -> Point {
    p.x += 100
    return p
}
fn total[T](xs: []T) -> T {
    t: T
    for x in xs {
        t += x
    }
    t
}
fn first[T](a: [4]T) -> T { a[0] }
fn mutate(a: [4]i64) -> i64 {
    a[0] = 50
    return a[0] + a[1]
}
fn get() -> [4]i64 { TABLE }
fn pick(c: bool) -> Point { if c { UNIT } else { ORIGIN } }
fn lookup(i: i64) -> i64 { TABLE[i] }

fn main() {
    // reading, indexing, iterating, len
    print(TABLE, TABLE[2], len(TABLE), TABLE.len, ORIGIN, UNIT.y, NAMES, NAMES[1], len(NAMES[1]))
    t := 0
    for i, x in TABLE {
        t += i * x
    }
    print(t, lookup(3), GRID, GRID[1][2], PARTIAL, sizeof[[3]u8]())
    print(THING.name, THING.at, THING.tags[1], THING.f(21), THING.scale, PAIR, PAIR.1, COPY, CORNERS)
    print(UP, UP.y, UP * 2.0, IDENT[1], IDENT[2].z, OPS[0](5), OPS[1](5))
    print(len(TEXT), TEXT == blob, blob == blob2, len(TEXT) == TEXT_LEN, EMPTY, len(EMPTY), BYTES, FLAGS, FLOATS)
    put(TEXT)
    // passing by value, slicing, generics, UFCS
    print(sum(TABLE[..]), sum(TABLE[1..3]), sum4(TABLE), norm1(UNIT), UNIT.norm1(), total(TABLE[..]), first(TABLE), TABLE.first())
    // a copy can be changed; the constant stays what it is
    c := TABLE
    c[0] = 100
    p := UNIT
    p.x = 7
    q := &p
    q.y = 9
    print(c, TABLE, p, UNIT, mutate(TABLE), TABLE[0], shifted(ORIGIN), ORIGIN, get(), pick(true), pick(false))
    // globals initialised from constants are ordinary variables
    table_copy[0] = 9
    corner.x = 5
    print(table_copy, corner, TABLE, UNIT)
    // comparisons, hashing, tuples of constants, match on elements
    print(TABLE == COPY, TABLE == c, ORIGIN != UNIT, hash(TABLE) == hash(COPY), (TABLE, UNIT).1.x)
    m := map[Point, str]()
    m.set(ORIGIN, "origin")
    m.set(UNIT, "unit")
    print(m.get_or(Point{1, 1}, "?"), m.get_or(CORNERS[0], "?"))
    n := 0
    for pt in CORNERS {
        match pt.y {
            0 => n += 1
            N => n += 10
            _ => n += 100
        }
    }
    print(n)
    local_const_shadow := 5
    {
        TABLE := 3
        print(TABLE + local_const_shadow)
    }
}
