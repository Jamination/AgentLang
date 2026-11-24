// Fixture for editors/vim/test/syntax/run.vim: every construct the syntax file
// highlights. TODO FIXME XXX NOTE are marked in comments. `alc check` accepts it.
use "fixture_other.al"
use std.math

const LIMIT = 1_000
const MASK: u32 = 0xFF_00
priv const BITS = 0b1010_0101
priv const PERMS = 0o755
const HALF = 1.5
const BIG = 1e9
const SMALL = 2.5e-3
const UNDER = 1_000.000_5E+10
const NEWLINE = '\n'
const QUOTE = '\''
const DQUOTE = '"'
const HEX = '\x41'
const LETTER = 'a'
const GREETING = "tab\t nl\n cr\r nul\0 bs\\ dq\" sq\' hex\x7f end"
const RAW = `raw \n "not a string" // not a comment
second line 'x' 0x10
`

priv struct Point { x: f64, y: f64 }

enum Shape[T] { Circle(Point, T), Rect(Point, Point), Empty }

extern "libc.so.6" fn getpid() -> i32

inline fn tiny(x: i64) -> i64 { x + 1 }

noinline fn pick[T](a: T, b: T, less: fn(T, T) -> bool) -> T {
    if less(a, b) { a } else { b }
}

when TARGET_OS == Windows {
    const SEP = '\\'
} else when TARGET_OS == Linux {
    const SEP = '/'
} else {
    const SEP = ':'
}

fn area(s: Shape[f64]) -> f64 {
    return match s {
        Circle(_, r) => 3.0 * r * r
        Shape.Rect(a, b) => (b.x - a.x) * (b.y - a.y)
        Empty => 0.0
    }
}

fn main() {
    t := (1, (2, 3))
    u := t.1.0
    v := vec[str]()
    v.push("a")
    n := len(v[..]) + v.len + sizeof[Point]()
    o: Opt[u8] = Opt[u8].None
    p := &Point{1.0, 2.0}
    ok := true && !false || p != nil
    q := i64(u8(200)) << 2 >> 1
    rows: for y in 0..10 {
        for x, w in v {
            if x == 3 {
                continue rows
            }
        }
    }
    for i in 9..=0 by -1 {
        print(i, n, o, ok, q, u, w_of(i))
    }
    outer: loop {
        break outer
    }
    defer {
        assert n > 0, "positive"
    }
    in := 1
    by := 2
    test := in + by
    print(test)
}

fn w_of(i: i64) -> i64 { i * 2 }

test "areas" {
    assert area(Empty) == 0.0
    assert area(Rect(Point{0.0, 0.0}, Point{2.0, 3.0})) == 6.0, "rect"
}

// a comment with `backquotes` and "quotes" and 'q' inside
x := 1 // trailing comment
// alc fmt: off
y :=    2   // kept as written; alc fmt: offset is not the marker
