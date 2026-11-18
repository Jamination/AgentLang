// An enum without data from its variant number: `Color(i)`, the inverse of `i64(c)`; and
// variant_count[E](), the number of variants. Both are constants where their arguments are.
// A number that is no variant's stops the program (tests/run/enum_from_int_bad.al) or, when
// it is a constant, the compilation (tests/fail/enum_from_int.al).
enum Color { Red, Green, Blue }
enum Kind { Wall, Floor, Door, Water, Lava, Exit }
enum Mode[T] { Off, On }                       // generic, but without data
priv enum Secret { A, B }

const COLORS = variant_count[Color]()
const LAST = Kind(variant_count[Kind]() - 1)
const DEFAULT: Kind = Kind(1)
const NAMES = [variant_count[Kind]()]str{"wall", "floor", "door", "water", "lava", "exit"}

struct Tile { kind: Kind, lit: bool }

fn main() {
    print(COLORS, LAST, DEFAULT, NAMES[i64(LAST)], variant_count[Mode[i64]](), variant_count[Opt[str]]())
    // every variant, in order
    for i in 0..variant_count[Kind]() {
        k := Kind(i)
        assert i64(k) == i
        put(k, " ")
    }
    print()
    // any integer type
    b: u8 = 2
    n: i32 = 0
    w: u64 = 1
    print(Color(b), Color(n), Color(w), Mode[str](1), Secret(1), Kind(i64(Kind.Door) + 1))
    // checking a number read from outside first
    saved := []i64{4, -1, 2, 6}
    for s in saved {
        if s >= 0 && s < variant_count[Kind]() {
            put(Kind(s), " ")
        } else {
            put("(", s, " is no Kind) ")
        }
    }
    print()
    t := Tile{kind: Kind(5), lit: true}
    print(t, t.kind == Exit, hash(Kind(3)) == hash(Water))
}
