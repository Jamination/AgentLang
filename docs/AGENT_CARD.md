# AL in one screen

For a model that writes AL: load this instead of the 900-line [reference](LANGUAGE.md), and
read the reference only where this card is not enough. Everything here is checked by the
compiler, so when in doubt run `alc check --json -W file.al` and read the `code` and `fix` of
each diagnostic ([DIAGNOSTICS.md](DIAGNOSTICS.md)).

```
struct Point { x: f64, y: f64 }
enum Shape { Circle(Point, f64), Rect(Point, Point), Empty }
const LIMIT = 1000

fn area(s: Shape) -> f64 {
    match s {
        Circle(_, r) => 3.14159 * r * r
        Rect(a, b) => (b.x - a.x) * (b.y - a.y)
        Empty => 0.0
    }
}

fn parse_port(s: str) -> (i64, str) {          // errors are values: (T, bool) or (T, str)
    n, ok := parse_i64(s)
    if !ok { return (0, fmt("not a number: ", s)) }
    (n, "")                                    // the last expression is the result
}

fn main() {
    xs := vec[i64]()                           // growable; map[str, i64]() is the hash map
    for i in 0..10 { xs.push(i * i) }          // 0..10 excludes 10, 0..=10 includes it
    total := 0                                 // i64; `x := 0.5` is an f32, `x: f64 = 0.5` an f64
    for i, x in xs.items() { total += x + i }
    p := Point{x: 1.0, y: 2.0}
    print("total:", total, p)                  // print: any values, separated by spaces
}

test "area" { assert area(Empty) == 0.0 }
```

## Rules that differ from the languages you know

- **Statements end at the newline.** A line may end with an operator to continue; it may not
  start with one.
- **`:=` declares, `=` assigns.** `x: T` declares a zeroed variable. Variables are mutable.
  There is no `let`, `var`, `mut` or `;`.
- **No implicit conversions.** `i + f` is an error: write `f64(i) + f`. Types: `i8`..`i64`,
  `u8`..`u64`, `f32`, `f64`, `bool`, `str` (which is `[]u8`), `*T`, `[]T`, `[N]T`, tuples,
  `fn(A) -> R`. There is no `int`, `float`, `string` or `char`.
- **Conditions are `bool`.** `if n { }` is an error: write `if n != 0 { }`. No parentheses
  around conditions; braces always.
- **Loops:** `for x in items`, `for i in a..b`, `while cond`, `loop`. There is no C-style `for`.
- **No methods, classes, interfaces, closures or exceptions.** `x.f(a)` is the ordinary
  function `f(x, a)`. A nested or anonymous function cannot use the locals around it: pass
  them as parameters.
- **A `match` used as a value must cover every case.** Variants are written bare (`Empty`), or
  `Shape.Empty` when two enums share the name.
- **Strings:** `fmt(a, b, ...)` builds one from any values (no format string), `==` compares,
  `cmp(a, b)` orders (`<` does not work on `str`), `s[i]` is a byte.
- **`Opt[T]`** (`Some(x)` / `None`) is for data that may be absent, not for errors.
- **Memory:** `alloc[T](n)`, `new[T]()`, `Vec`, `Map` and `fmt` take memory from an arena.
  There is no `free`. A short program releases nothing. A loop that runs for long gives memory
  back in bulk: `m := mark()` ... `release(m)`, and whatever must survive is copied out first
  with `clone`. Nothing allocated after `mark()` may be used after `release(m)`
  ([MEMORY.md](MEMORY.md)).
- **Visibility:** everything is visible to the whole program unless it is `priv` (its file
  only). `use "other.al"` includes a file, `use std.os` a library module.
- **What is defined:** integers wrap, division truncates toward zero, an index out of range
  and a division by zero stop the program with `file:line` ([SEMANTICS.md](SEMANTICS.md)).

## Commands

| Task | Command |
|---|---|
| Check, as JSON with codes and fixes | `alc check --json -W file.al` |
| What a code means | `alc explain E0401` |
| Build / run / test | `alc build file.al -o out`, `alc run file.al -- args`, `alc test --json file.al` |
| Look up a library function | `alc sigs --std --json --pub --filter <name> file.al` |
| Format | `alc fmt file.al` |
| Everything the compiler accepts, as JSON | `alc capabilities` |
| Find a bug in the use of memory | `ALC_CHECK_MEMORY=1 ./program` |

Do not guess a library function: `alc sigs` lists the real ones with their signatures and
comments.
