# AL language reference

AL is a small, statically typed, compiled language designed to be written by AI agents.
`alc` compiles a whole program (`alc build main.al`, no build system) directly to a static
x86-64 Linux executable (or, with `--target windows`, a Windows x86-64 console executable). The compiler reports all errors of a program at once (also in functions
that are never called; generic ones: see [Generics](#generics)) as `file:line:col: error: ...`.

- Integers wrap; division by zero and out-of-bounds indexing stop the program with a `file:line`
  message. There are no implicit conversions, no constructors or destructors, no exceptions.
- Memory is bump-allocated from arenas and reclaimed in bulk (`mark` / `release`, regions);
  there is no `free` and no garbage collector.
- **AL does not have**: closures (a nested function sees no local of its surroundings), methods
  or `impl` blocks (`x.f(a)` calls the ordinary function `f(x, a)`), interfaces or constraints on
  type parameters, `<` on strings (use `cmp`), error propagation syntax (see [Errors](#errors)).

Read on demand: [DETAILS.md](DETAILS.md) (grammar, fine print of name resolution and `priv`,
bounds checks, region limits, C interop), [STDLIB.md](STDLIB.md) (math, random numbers, time, processes and files, games).

## Quick tour

```
struct Point { x: f64, y: f64 }

enum Shape { Circle(Point, f64), Rect(Point, Point), Empty }

fn area(s: Shape) -> f64 {
    match s {
        Circle(c, r) => 3.141592653589793 * r * r
        Rect(a, b) => (b.x - a.x) * (b.y - a.y)
        Empty => 0.0
    }
}

fn largest[T](items: []T, less: fn(T, T) -> bool) -> T {
    best := items[0]
    for x in items {
        if less(best, x) { best = x }
    }
    best
}

fn main() {
    shapes := []Shape{Circle(Point{0.0, 0.0}, 1.0), Rect(Point{0.0, 0.0}, Point{2.0, 3.0}), Empty}
    print("largest:", largest(shapes, fn(a: Shape, b: Shape) -> bool { area(a) < area(b) }))
    // largest: Rect(Point{x: 0.0, y: 0.0}, Point{x: 2.0, y: 3.0})
    counts := map[str, i64]()
    words := vec[str]()
    for w in split("a b a c a", ' ') {
        counts.set(w, counts.get_or(w, 0) + 1)
        words.push(w)
    }
    print(counts.get_or("a", 0), counts.len, words[1])       // 3 3 b
}

test "areas" {
    assert area(Empty) == 0.0
    assert area(Rect(Point{0.0, 0.0}, Point{2.0, 3.0})) == 6.0, "rect"
}
```

`alc run tour.al` builds and runs it, `alc test tour.al` runs the test blocks.

## Lexical structure

- Source is UTF-8 text (no NUL bytes; a byte order mark at the start is skipped); identifiers
  are ASCII: `[A-Za-z_][A-Za-z0-9_]*`. Comments: `//` to the end of the line.
- **Statements end at a newline** (or `;`). A newline does *not* end a statement when the line
  ends in an operator, a comma or an opening bracket, or anywhere inside `( )` / `[ ]`.
  A line cannot *start* with a binary operator.
- Keywords (not usable as names): `fn struct enum const test use priv extern inline noinline if
  else while loop for in by return break continue assert match defer true false nil`.
- Integer literals: `42`, `1_000_000`, `0xFF`, `0b1010`, `0o17`. A character literal (`'a'`,
  `'\n'`, `'\''`, `'\x41'`) is an integer literal with the byte's value: `c: u8 = 'a'`,
  `s[i] == 'a'`; `c := 'a'` is an `i64`.
- Float literals: `1.5`, `1e9`, `2.5e-3` (digits on both sides of the point), rounded once from the text to their type: `1e999` is `inf`.
- String literals: `"text"`. Escapes in strings and characters: `\n \t \r \0 \\ \" \' \xHH`.
  A string is a `str` (`[]u8`, bytes, not characters); literals are read-only.
- Raw string literals: text between backquotes, taken as is (no escapes), may span lines.

## Types

| Type | Meaning |
|------|---------|
| `i8 i16 i32 i64`, `u8 u16 u32 u64` | integers; arithmetic wraps around |
| `f32`, `f64` | IEEE-754 single / double; `f32` is the default of a float literal, `f64` where precision matters |
| `bool` | `true` / `false` |
| `*T` | pointer to `T` (may be `nil`) |
| `[]T` | slice: pointer + length, a view of elements stored elsewhere; `nil` and `[]T{}` are empty slices |
| `[N]T` | array of `N` elements stored inline (`N` is a constant expression) |
| `str` | another name for `[]u8` |
| `(A, B, ...)` | tuple; fields `t.0`, `t.1` |
| `fn(A, B) -> R` | function value: a plain code pointer; `fn(A)` returns nothing |
| `Name`, `Name[T, U]` | struct or enum, possibly generic |
| `vec2 vec3 vec4 quat mat4` | `f32` vectors, quaternion, 4x4 matrix: see [f32, vectors, matrices](#f32-vectors-matrices) |

- **No implicit conversions.** Both operands of an operator must have the same type. Untyped
  numeric literals take the type the context asks for (`x: u8 = 200`, `x * 2`, `f(3)`), also
  through the branches of an `if` / `match` used as a value (`x: u8 = if c { 1 } else { 2 }`);
  without context an integer literal is `i64`, a float literal **`f32`**: `x := 0.1` is an
  `f32`; `x: f64 = 0.1`, `f64(0.1)` and `y * 0.1` (`y` an `f64`) use the f64 nearest to 0.1. An
  integer literal is accepted where a float is expected (`d: f64 = 5`). A decimal literal must
  fit its type (not `x: u8 = -1`); hex, binary, octal, character literals may be bit patterns (`x: i8 = 0xFF`).
- **Conversions** are written like calls: `i64(x)`, `u8(x)`, `f64(n)`. Integer to a narrower
  type keeps the low bits; to a wider type the *source* type decides: a signed source is
  sign-extended, an unsigned one zero-extended (`i64(u8(200))` is 200, `u64(i8(-1))` is
  0xFFFFFFFFFFFFFFFF, `i8(200)` is -56). Float to integer truncates toward zero; NaN and values
  beyond `i64` give 0x8000000000000000 (`u64` is exact below 2^64). `i64(true)` is 1.
- **Values and references.** Structs, tuples, arrays and enums are values: assignment, argument
  passing and returning copy them. Slices and pointers refer to shared storage, so a copy of a
  struct shares what its slices (and every `str`, `Vec` and `Map` inside) refer to. See
  [Copies share storage](#copies-share-storage); `clone(x)` makes an independent deep copy.
- `a := v[0]` is a copy: assigning to `a.x` does not change `v[0]`. Write `v[0].x = 10`, or take
  a pointer: `p := &v[0]`, `p.x = 10`. (A copy of a field or element that is only ever assigned
  to and never read is reported as a compile error.)
- Every type has a zero value (0, `false`, `nil`, empty slice, the first variant of an enum, all
  fields zero); `x: T` declares a zeroed variable. `sizeof[T]()` is the size in bytes. Layout
  follows the C rules; an enum is a 4-byte tag (a `u32`), then the payload at its alignment.

## Declarations

Top-level declarations can appear in any order. A declaration that starts with a keyword declares
something fixed at compile time; one that starts with a name declares a variable, the same at top
level and inside functions. Inside a function only variables and functions can be declared.

```
fn name(a: i64, b: f64) -> i64 { ... }     // function; no `->` means it returns nothing
fn pick[T](a: T, b: T) -> T { ... }        // generic function
inline fn tiny(x: i64) -> i64 { x + 1 }    // inlining hint; `noinline fn` forbids inlining
struct Pair[A, B] { first: A, second: B }  // struct (fields separated by `,` or newlines)
enum Color { Red, Green, Blue }            // enum without data
enum Tree[T] { Leaf(T), Node(*Tree[T], *Tree[T]) }   // enum with data ("tagged union")
const LIMIT = 1000                         // compile-time constant (untyped unless annotated)
const MASK: u32 = 0xFF00
const TABLE = [4]i64{1, 2, 4, 8}           // aggregate constant, stored once in read-only memory
counter: i64                               // global variable, zero-initialized
table := [4]i64{1, 2, 4, 8}                // global with a constant initializer
test "name" { ... }                        // unit test, run by `alc test`
use "other.al"                             // include another file (path relative to this file)
use std.window                             // a module bundled with the compiler (see STDLIB.md)
extern "libc.so.6" fn getpid() -> i32      // a C function (see C interop)
priv fn helper(x: i64) -> i64 { ... }      // `priv`: visible only inside this file
```

- The program starts at `fn main()`; `fn main() -> i64` returns the exit status.
- A function whose result type is `never` does not return (`exit`, `panic`). A block may end in
  a call of one where a value is expected: `x := if ok { v } else { panic("bad input") }`.
- Parameters are ordinary local variables (assignable; the caller's value is not affected).
- **One namespace**: all top-level names of a program are visible in all its files, whatever
  file they are in (except `priv` ones). `use` only adds a file to the program: a file included
  several times is included once, and a file need not `use` the file whose names it refers to
  as long as some file of the program includes it.
- A user declaration may reuse a library name (your own `push`, `Vec`, `find`); the library
  keeps using its own definitions internally.
- **Overloading**: a function name may be defined several times with different parameter types
  (`fn area(c: Circle)` and `fn area(r: Rect)`; a generic `fn push[T](s: *Stack[T], x: T)` next
  to the library's `push` for `Vec`). A call picks the definition whose parameters match the
  receiver and arguments; user definitions are considered before library ones.
- **Builtin names**: a function may have the name of a builtin (`len`, `print`, `clone`, `hash`,
  ...). Declared functions are tried first; when none accepts the arguments, the builtin is used
  (`fn len(q: Queue) -> i64` leaves `len("text")` to the builtin).
- `f[T](args)` passes type arguments explicitly. `f[T]` alone, or `f` where a function type is
  expected, is a function value.

### Enum variants

A variant is written `Variant` / `Variant(args)`, or qualified: `Enum.Variant`,
`Enum[T].Variant(args)`. Two enums (also one of the program and one of the library) may have
variants of the same name.

```
enum Color { Red, Green, Blue }
enum Light { Red, Amber, Green }
enum Tree[T] { Leaf(T), Node(*Tree[T], *Tree[T]), Empty }

fn main() {
    a := Color.Red                      // qualified
    b := Blue                           // only Color has Blue
    c: Light = Red                      // the declared type decides
    lights := []Light{Red, Amber}       // element type of a typed literal
    l := Tree[i64].Leaf(1)              // type arguments written out
    m := Tree.Leaf("x")                 // inferred from the payload: Tree[str]
    print(a, b, c, c == Red, lights, l, m, Opt[u8].None)   // Red Blue Red true [Red, Amber] Leaf(1) Leaf(x) None
}
```

In a pattern the type of the matched value decides. A bare `Variant` in an expression is
resolved in this order:

1. A local variable of that name is the variable.
2. If the **expected type** is an enum with that variant, it is that variant. The expected type
   is known for: a variable declared with a type, the right side of an assignment, an argument,
   a returned value and the last expression of a function (also through the branches of an
   `if` / `match` / block there: `if found { Some(id) } else { None }`), a field of a struct
   literal, an element of a typed literal, a payload value, an operand of `==` / `!=` whose
   other operand has a type.
3. Otherwise, if exactly one enum of the program has the variant, it is that one; only if none
   has it are the library's enums searched (a program's own `Some` / `None` hide the library's).
4. If several remain, it is an error that lists them: write `Color.Red`.

- `None` and other variants of generic enums without payload need a type from the context
  (`o: Opt[i64] = None`, a parameter, the result type, `Opt[i64].None`); `x := None` is an error.
  As the value of a `match` arm such a variant takes the type of the other arms.
- **Comparing.** `==` / `!=` compare the variant and its payload values (`t == Nl`,
  `o == Some(3)`). "Is it this variant, whatever the payload": `match cell { Wall(_) => true; _ => false }`.
- An enum value behind a pointer: `p := new[Tree[i64]]()`, `*p = Leaf(1)` (`&Variant(args)` is
  not allowed; `&` allocates only in front of a struct literal).
- A variant can have the name of a struct (`Expr{...}` is the struct literal, `Expr` / `Expr(e)`
  the variant), but not of a function, constant, global or enum of the program. In a call, a
  builtin name stays the builtin (`len(x)`) even if an enum has such a variant.

### Constants

A `const` is a compile-time constant. Its initialiser is built from literals, other constants,
constant expressions, `T{...}` literals and tuples, names of non-generic functions, variants
without data, `nil`, and `embed("file")` (the content of a file as a `str`, read at compile
time, path relative to the source file). Function calls are not constant. Global initialisers
follow the same rules.

- The type is taken from the value unless annotated (`const MASK: u32 = 0xFF00`). A typed or
  untyped integer constant can be an array length (`[N]i64`) and a `match` pattern.
- An aggregate constant can be read, indexed, iterated, sliced, compared, passed and copied
  (`t := TABLE` is an independent copy). No constant can be modified or have its address taken;
  to get a modifiable table, declare a global (`TABLE := [4]i64{...}`).

### `priv`: file-private declarations

`priv` in front of `fn`, `struct`, `enum`, `const`, `extern` or a global variable makes the
declaration visible only inside its file. Use it for everything that is not the interface of a
file: helpers get short names (`find`, `Ctx`, `LIMIT`) without clashing with other files.

```
priv const LIMIT = 2                       // other files may have their own LIMIT
priv slots: Vec[str]
priv fn find(key: str) -> i64 { index_of(slots[..], key) }   // the library's find(s, sub) stays usable

fn slot_add(key: str) -> bool {            // public: the interface of the file
    if key.find() >= 0 || slots.len >= LIMIT { return false }
    slots.push(key)
    true
}
```

- Inside its file a private declaration wins over public and library declarations of the same
  name. For functions, private and public definitions are overloaded together, and a private
  one that fits the call is always chosen.
- Within one file a name is either private or public. `priv enum` hides the type name only: its
  variants stay usable everywhere. `priv` cannot stand before `main`, `test`, `use`, inside a
  function, on a field or on a variant. Complete rules: [DETAILS.md](DETAILS.md#priv).

## Statements

```
x := expr                    // declare a new variable (type inferred)
x: T                         // declare, zero-initialized
x: T = expr                  // declare with an explicit type
a, b := pair()               // declare from a tuple;  `_` discards: _, ok := m.get(k)
a, v[i], p.x = f()           // assign the parts of a tuple to existing places
x = expr                     // assign;  also  += -= *= /= %= &= |= ^= <<= >>=
p.field = v    a[i] = v    *ptr = v

if cond { ... } else if cond { ... } else { ... }
while cond { ... }
loop { ... }                               // forever; leave with break / return
for i in lo..hi { ... }                    // lo, lo+1, ..., hi-1      (`..=` includes hi)
for i in lo..hi by step { ... }            // any step; a negative step must be a constant:
for i in 9..=0 by -1 { ... }               //   9, 8, ..., 0
for x in items { ... }                     // elements of a slice, array, str or Vec (copied into x)
for i, x in items { ... }                  // index and element
name: for ... { ... }                      // labelled loop (also `name: while`, `name: loop`)
break    continue    return    return expr
break name    continue name                // leave / continue the enclosing loop with that label
assert cond      assert cond, "message"    // stops the program if false
defer { ... }                              // runs when the enclosing block is left
fn name(a: T) -> R { ... }                 // nested function (see below)
match value { ... }                        // see below
{ ... }                                    // nested block (new scope)
```

- Variables (and parameters) are mutable. Declaring a name that already exists **in the same
  scope** is an error; inner scopes may shadow outer names.
- The last expression of a function body is its result (`fn sq(x: i64) -> i64 { x * x }`); the
  same holds for the branches of `if` / `match` used as values (`if` then needs an `else`).
- `defer` blocks run in reverse order when their scope ends, also on `break`, `continue` and
  `return` (the returned value is computed first).
- In `for i in a..b` the bounds are evaluated once. `for x in v` over a `Vec` reads its length
  and buffer once, when the loop starts: elements pushed during the loop are not visited. To
  change elements in place use the index: `for i in 0..v.len { v[i].hp -= 1 }`.
- **Labels.** `name:` stands directly before `for`, `while` or `loop`. `break name` leaves that
  loop, `continue name` starts its next iteration; the `defer` blocks of all scopes that are
  left run. The label must be on the same line as `break` / `continue`.
  Example: `rows: for y in 0..h { for x in 0..w { if bad(x, y) { continue rows } } }`.

### Nested functions

A function can be written inside another one, with a name (a statement) or without (an
expression). Either way it is an ordinary function that happens to be declared there: **it
does not see the variables of the function around it.** What it needs is passed as a parameter.

```
struct Item { name: str, hp: i64 }

fn rank(items: []Item, floor: i64) -> i64 {
    n := 0
    fn keep(it: Item, floor: i64, n: *i64) -> bool {   // state comes in as parameters
        if it.hp < floor { return false }          // returns from keep
        *n += 1
        true
    }
    for it in items { it.keep(floor, &n) }         // keep(it, floor, &n) or it.keep(floor, &n)
    sort_by(items, fn(a: Item, b: Item) -> bool { a.hp > b.hp })  // anonymous function
    n
}
```

- **What the body sees**: globals, constants, top-level functions, nested functions declared
  before it in the enclosing blocks, itself, and the type parameters of the enclosing function.
  Using a local or parameter of an enclosing function is a compile error: pass it as a
  parameter (`&x` if the function changes it). A callback that needs state takes it as a
  context argument, as in `sort_by(items, ctx, less)`.
- Its name, and an anonymous function, is a plain `fn(A) -> R` value: it can be called, passed,
  stored, returned, and stays valid after the enclosing function has returned.
- The name is in scope from the declaration to the end of its block and hides top-level
  functions and builtins of that name there. Nested functions have no type parameters, are not
  overloaded, and `return` / `break` / `continue` / `defer` in them stay inside them.

### match

```
match n {
    0 => print("zero")
    1, 2, 3 => print("small")            // alternatives
    _ if n < 0 => print("negative")      // guard
    _ => print("many")                   // default
}

label := match shape {                   // match is an expression when every arm yields a value
    Circle(c, r) => "circle"             // binds the variant's fields
    Rect(a, b) => { helper(); "rect" }   // a block: its last expression is the value
    Empty => "empty"
}
```

Arms are separated by newlines or `;` (`match c { 'a' => 1; _ => 0 }`), not by commas. The
matched expression is evaluated once; the arms are tried from top to bottom, and the first
whose pattern matches (and whose guard, if any, is true) is taken. The matched value can be an
integer, `bool`, `str`, a float, a pointer, an enum or a tuple.

| Pattern | Matches |
|---------|---------|
| `_` | anything |
| constant: `0`, `-1`, `'a'`, `"text"`, `true`, `1.5`, `nil`, `LIMIT`, `LIMIT + 1` | a value equal to it |
| `Variant`, `Enum.Variant` | that variant (it must have no payload) |
| `Variant(p1, p2)`, `Enum.Variant(p1, p2)` | that variant, if each payload field matches its sub-pattern (one per field) |
| `(p1, p2, ...)` | a tuple whose elements match the sub-patterns |
| `name` (only inside a variant or tuple pattern) | anything; binds `name` to a **copy** of that part |
| `&name` (only inside a variant or tuple pattern) | anything; binds `name` to a **pointer** (`*T`) to that part |

```
enum Shape { Circle(f64), Rect(f64, f64), Empty }
enum List { Cons(i64, *List), End }
struct Account { id: i64, balance: i64 }

fn describe(o: Opt[Shape]) -> str {
    match o {
        Some(Circle(r)) if r > 10.0 => "big circle"      // nested pattern, guard
        Some(Circle(_)) => "circle"
        Some(Rect(w, h)) if w == h => "square"
        Some(Rect(_, _)), Some(Empty) => "other shape"   // alternatives
        None => "nothing"
    }
}

fn both(a: Opt[i64], b: Opt[i64]) -> i64 {
    match (a, b) {
        (Some(x), Some(y)) => x + y
        (Some(x), None), (None, Some(x)) => x            // both alternatives bind x
        (None, None) => 0
    }
}

fn sum(l: *List) -> i64 {
    match l {
        Cons(x, rest) => x + sum(rest)   // l is not nil and *l is a Cons
        End => 0
        nil => 0                         // needed for the match to be exhaustive
    }
}

fn deposit(o: *Opt[Account], amount: i64) {
    match *o {
        Some(&acc) => { acc.balance += amount }          // acc is a *Account into *o
        None => {}
    }
}

fn main() {
    end := End
    b := Cons(2, &end)
    acct: Opt[Account] = Some(Account{id: 1, balance: 10})
    deposit(&acct, 5)
    print(describe(Some(Rect(1.0, 1.0))), describe(None), both(None, Some(5)), sum(&b), acct)
    // square nothing 5 2 Some(Account{id: 1, balance: 15})
}
```

- **A name inside a variant or tuple pattern** is, in this order: a variant, if the type of
  that part is an enum (or a pointer to one) that has it; a constant, if a `const` of that
  name exists; otherwise a new variable of the arm. Where the part is an enum, a new variable
  must start with a lower-case letter: a misspelled variant (`Some(Crcle(r))`, `Un(Dref, x)`)
  is an error, not a binding that matches everything. To compare a part with a variable, bind
  it and use a guard (`Some(x) if x == limit => ...`).
- **An arm's pattern itself** (not nested) is never a binding: a name there is a variant of the
  matched enum, or an expression compared with the matched value (a constant, a variable). For
  "everything else" write `_` and use the matched expression (`_ if n > 10 => ...`).
- **Bindings.** `name` holds a copy; assigning to it does not change the matched value. `&name`
  points at the part inside the matched value, to modify it in place (match on a place: a
  variable, `x.f`, `a[i]`, `*p`).
- **Pointers.** A variant or tuple pattern also matches a *pointer* to an enum or tuple, if it is
  not `nil` and the value it points to matches. `nil` is matched by the constant `nil` or `_`.
- **Alternatives** (`p1, p2 => body`) must bind the same names with the same types. A **guard**
  (`pattern if cond => body`) is evaluated after the pattern matched; if it is false, matching
  continues with the next arm.
- **Exhaustiveness.** A `match` used as a statement may leave values unmatched: then no arm
  runs. A `match` used as a value must cover every possible value; the error lists what is
  missing (`missing: Some(Rect(_, _))`). An arm with a guard covers nothing. Integers, floats,
  strings and pointers are never covered by constants alone: end with `_`.
- **Unreachable arms.** A pattern that an earlier arm without a guard already covers (the same
  constant or variant, or `_`) is an error that names the line of that arm.

## Expressions

Operators, from tightest to loosest binding (all binary operators are left-associative):

| Operators | Notes |
|-----------|-------|
| `f(x)  a[i]  a[i..j]  x.f  T{...}` | postfix |
| `-x  !b  ~x  &x  *p` | unary: negate, logical not, bitwise not, address-of, dereference |
| `*  /  %` | integer division truncates toward zero; `%` (integers only; floats: `fmod(x, y)`) has the sign of the left operand |
| `+  -` | |
| `<<  >>` | `>>` is arithmetic for signed types; the count (any integer type) is taken modulo the bit width |
| `&`, then `^`, then `\|` | bitwise; they bind tighter than comparisons: `x & 1 == 0` is `(x & 1) == 0` |
| `==  !=  <  <=  >  >=` | |
| `&&`, then `\|\|` | short-circuit |

- `==` / `!=` work on numbers, `bool`, pointers (the address), and **by content** on `str`,
  slices, arrays, structs, tuples and enums. `<  <=  >  >=` work on numbers only; strings are
  ordered with `cmp(a, b) < 0`.
- `p.field` dereferences pointers automatically. `a[i]` works on slices, arrays, `Vec`s and
  pointers to them; the index may have any integer type. `s.len` and `len(s)` give the length
  of a slice, array, string or `Vec`, and the number of entries of a `Map`.
- `a[i..j]` is the sub-slice `i <= index < j` (bounds may be omitted: `a[..n]`, `a[i..]`, `a[..]`);
  it shares storage with `a`.
- `if c { a } else { b }` and `match` are expressions.

Literals for aggregates:

```
Point{x: 1.0, y: 2.0}      Point{1.0, 2.0}       // struct: by name or by position; missing fields are zero
Pair[i64, str]{1, "one"}                         // generic struct
(1, "one", 2.5)                                  // tuple;  fields are t.0, t.1, t.2
[4]i64{1, 2, 3}            [_]i64{1, 2, 3}       // array: missing elements are zero; `[_]`: as long as the list
[]f64{1.0, 2.0}            []f64{}               // slice literal: allocates its elements; empty slice
&Node{value: 1, next: nil}                       // allocates a struct in the arena, yields a pointer
Circle(center, 2.0)      Empty                   // enum values;  qualified: Shape.Circle(c, 2.0)
```

**In the header of `if` / `while` / `for` / `match`, a `{` after a name starts the body**: a
`Name{...}` literal there needs parentheses (`if p == (Point{1, 2}) { ... }`, `match (Point{5, 6}).y
{ ... }`). A literal that starts with `[` needs none (`for x in []i64{1, 2, 3} { ... }`).

**Method-call syntax**: `x.f(a, b)` means `f(x, a, b)` for any function `f`, also overloaded,
generic and library functions. (If `x` has a field `f` that holds a function, that is called.)
Two adjustments apply to the receiver only, never to other arguments or in a plain call:

- If `f` expects a `*T` and `x` is a `T`, the address of `x` is passed when `x` is a place (a
  variable, a field, an element, a dereference: `g.adj[u].push(e)` changes the stored `Vec`).
  For any other `x` (a call result, a literal, a constant) a temporary copy is passed and
  writes to it are lost.
- If `f` expects a `T` and `x` is a `*T`, the pointer is dereferenced.

With `fn incr(p: *i64)`: `x.incr()` passes `&x` (the plain call is `incr(&x)`), and
`self.count.incr()`, `self.ops[1].incr()` reach the field and the element. The builtins `len`,
`clone`, `hash`, `ptr`, `sqrt`, `fabs`, `fmin`, `fmax`, `popcnt`, `ctz`, `clz`, `bswap`, `rotl`,
`rotr` have a method form too (`s.len()`, `x.clone()`).

## Generics

Functions, structs and enums can take type parameters in square brackets. Generic code is
compiled and type-checked per combination of types it is used with (like templates; unused, it is
only parsed), so any operation valid for the concrete type may be used. Type arguments are inferred
from the arguments or the expected type, or written out: `sum[i64](nil)`, `alloc[u32](16)`, `Stack[i64]{}`.

```
struct Stack[T] { items: Vec[T] }                  // the zero value is an empty stack

fn push[T](s: *Stack[T], x: T) { s.items.push(x) } // next to the library's push for Vec
fn pop[T](s: *Stack[T]) -> (T, bool) {
    if s.items.is_empty() {
        zero: T
        return (zero, false)
    }
    (s.items.pop(), true)
}
fn len[T](s: *Stack[T]) -> i64 { s.items.len }     // next to the builtin len

fn sum[T](xs: []T) -> T {
    total: T
    for x in xs { total += x }
    total
}

fn main() {
    s: Stack[str]
    s.push("a")                                    // method call: passes &s  (plain: push(&s, "a"))
    s.push("b")
    top, ok := s.pop()
    o: Opt[i64] = None                             // type arguments from the expected type
    print(top, ok, s.len(), sum([]f64{1.5, 2.5}), sum[i64](nil), o)   // b true 1 4.0 0 None
}
```

## Errors

There are no exceptions and no error type. A function that can fail returns a tuple:
**`(T, bool)`** (value and success, like `parse_i64`, `read_file`, `m.get`), or **`(T, str)`**
with a message, where `""` means success. File functions additionally record the Linux error
number in `io_error()`. `Opt[T]` is for *data* that may be absent (a field, an element), not
for errors. Programming errors stop the program: `assert`, `panic("msg")`.

```
fn parse_port(s: str) -> (i64, str) {
    n, ok := parse_i64(s)
    if !ok { return (0, fmt("not a number: ", s)) }
    if n < 1 || n > 65535 { return (0, fmt("port out of range: ", n)) }
    (n, "")
}

fn main() -> i64 {
    port, err := parse_port("8080")
    if err != "" {
        eprint(err)                                // to standard error
        return 1
    }
    _, ok := read_file("no/such/file")
    if !ok { print("cannot read:", error_text(io_error())) }   // cannot read: no such file or directory
    print(port, parse_port("http").1)              // 8080 not a number: http
    0
}
```

## Memory

Local variables (including arrays and structs) live on the stack. All dynamic memory comes
from an arena and is zero-initialized:

```
xs := alloc[f64](n)          // slice of n elements
p  := new[Node]()            // pointer to a zeroed Node;  q := &Node{value: 1}: to an initialized one
s  := []i64{1, 2, 3}         // slice literal
```

`Vec`, `Map`, `fmt`, `concat`, `split`, `clone` and the other library functions allocate from
the arena too. There is no `free`. Short programs never release anything; long-running loops
reclaim memory in bulk, with a mark or a region:

```
m := mark()                  // remember the current arena position
... allocate freely ...
release(m)                   // everything allocated since mark() is gone (and must not be used)
```

### Copies share storage

A slice, `str`, `Vec` or `Map` refers to storage; copying the value (assignment, passing,
returning, a struct that contains it) copies the reference, not the elements.

```
struct State { names: Vec[str], turn: i64 }

fn main() {
    a := State{}
    a.names.push("x")
    b := a                               // copies turn, the length and the buffer reference
    b.names[0] = "changed"               // the slot is shared: a sees it
    b.names.push("y")                    // b's length is 2, a's is still 1
    snap := clone(a)                     // deep copy: an independent snapshot (undo, search states)
    snap.names[0] = "snap"
    print(a.names[..], b.names[..], snap.names[..])   // [changed] [changed, y] [snap]
}
```

- Pass a `Vec` / `Map` / struct that a function should change as a pointer (`s: *State`); a
  by-value parameter is a copy as above (pushes into it are not seen by the caller).
- **A slice `v[a..b]`, `v.items()` or pointer `&v[i]` into a `Vec` refers to its current
  buffer**: after a `push` (or `reserve`, `insert`, `extend`, `resize`) that grows the `Vec`
  it refers to the old buffer. Keep an index instead of a pointer while a `Vec` grows. The same
  holds for `m.ptr(k)` when a new key is set.

### `clone(x)`

`clone(x)` (or `x.clone()`) returns a deep copy of `x` that shares no storage with it, allocated
from the arena in use at the call. Slices, `str`, `Vec` and `Map` get new storage with cloned
elements; arrays, tuples, structs and enum payloads are cloned part by part. **A pointer (`*T`)
inside the value is copied as it is: what it points to stays shared.** `clone(p)` of a pointer
itself is a compile error (write `clone(*p)` for a copy of the value). Copy linked structures by
hand, or declare a `clone` function for the type.

### Regions

A `Region` is a further, independent arena. Between `enter(&r)` and the matching `leave()`
everything that allocates (also inside library functions) takes its memory from `r`, and
`reset(&r)` gives all of it back in one step. Use it for work whose temporary data should not
stay: do the work inside, `leave()`, `clone` the result out, `reset`.

```
region() -> Region               // an empty region (the same as the zero value of Region)
enter(r: *Region)                // allocations now come from r
leave()                          // back to the arena that was in use before the matching enter
reset(r: *Region)                // empties r: everything allocated from it is gone
used(r: *Region) -> i64          // bytes of r in use
region_free(r: *Region)          // returns r's memory to the operating system (r must not be entered)
```

```
struct Token { text: str, line: i64 }

scratch: Region                          // a global: its address never changes

fn longest(src: str) -> Token {
    enter(&scratch)                      // everything below allocates from scratch
    toks := vec[Token]()
    for i, w in split(src, ' ') {
        toks.push(Token{to_upper(w), i})
    }
    best := toks[0]
    for t in toks {
        if len(t.text) > len(best.text) { best = t }
    }
    leave()                              // back to the arena of the caller
    result := clone(best)                // deep copy into it
    reset(&scratch)                      // now the temporary data may go
    result
}

fn main() {
    print(longest("a bb cccc dd"), used(&scratch))   // Token{text: CCCC, line: 2} 0
}
```

- `enter` / `leave` nest like brackets (up to 64 deep; a region cannot be entered twice):
  `defer { leave() }` right after `enter` leaves on every path, also on an early `return`.
- `mark()` / `release(m)` act on the arena in use; a mark belongs to the arena it was taken in.
- Leaving does not reset: data in a region stays valid after `leave()` until `reset`.
- Use a `Region` through a pointer and never copy one that has memory: keep it in a global, or
  a local of the function that brackets the work. More (frame memory, pools): [std/mem.md](std/mem.md).
- **A `Vec` or `Map` that grows while a region is in use moves its storage into that region,
  even if it was created elsewhere, and is invalid after the reset.** Containers that must
  survive are grown outside the region, or cloned out.

## Run-time errors

These stop the program with exit status 1 and a message on standard error (buffered output is
written first):

| Situation | Message |
|-----------|---------|
| index or slice bound out of range | `panic: index out of bounds at file:line` |
| integer division or remainder by zero | `panic: division by zero at file:line` |
| `assert` fails | `assertion failed at file:line: message` |
| `panic("msg")` | `panic at file:line: msg` |
| `nil` dereference, stack overflow (deep recursion), write to a string literal or constant | `panic: memory fault (nil dereference, stack overflow or use of released memory)` |
| `pop` / `unwrap` on nothing | `panic: pop from an empty Vec at file:line`, `panic: unwrap of None` |
| `last` of an empty `Vec`; `insert` / `remove` / `swap_remove` / `truncate` / `resize` out of range | `assertion failed at file:line: last of an empty Vec` (the line of the call) |
| non-positive run-time `by` step; arena exhausted; misuse of `enter` / `leave`; a library function called wrongly (empty `sub` in `count`, base 1) | `panic: loop step must be positive at file:line`, `panic: out of memory`, `panic: leave without enter`, `panic at file:line: count: empty substring` (the line of the call), ... |

Signed overflow wraps; `MIN / -1` yields `MIN`. `alc build --unchecked` removes index and
division checks (out-of-range behaviour is then undefined); `assert` and `panic` are kept.

## Builtin functions

| Builtin | Meaning |
|---------|---------|
| `print(a, b, ...)` | writes the values to standard output, separated by one space, then a newline; any number of arguments of any type |
| `put(a, b, ...)` | same without separators and newline |
| `fmt(a, b, ...) -> str` | like `put`, but returns the text: the way to build a string from values |
| `len(x) -> i64` | length of a slice, array, string or `Vec`; number of entries of a `Map` |
| `hash(x) -> u64` | hash of any value that supports `==` |
| `clone(x) -> T` | independent deep copy (see [`clone`](#clonex)) |
| `sizeof[T]() -> i64` | size of `T` in bytes |
| `sqrt(x)`, `fabs(x)`, `fmin(a, b)`, `fmax(a, b)` | on `f64`, `f32` and vectors |
| `popcnt(x) ctz(x) clz(x) bswap(x)`, `rotl(x, n)`, `rotr(x, n)`, `mulhi(a, b)` | integers: bit counting, byte swap, rotation, high half of the double-width product |
| `panic(msg: str) -> never` | stop with a message |
| `embed("file") -> str` | content of a file, read at compile time (a constant) |
| `syscall(nr, a, b, ...) -> i64` | raw Linux system call (up to 6 arguments) |
| `cast[T](x)` | reinterpret: pointer↔pointer, pointer↔`i64`/`u64`, `f64`↔`i64`/`u64` bits, slice↔slice |
| `ptr(s) -> *T`, `mkslice[T](p, n) -> []T`, `memcopy(dst, src, nbytes)`, `memfill(dst, byte, nbytes)` | pointer to the first element of a slice or array; slice from a pointer and a length; raw copy / fill |

**How values print** (`print`, `put`, `fmt`): integers in decimal (a `u8` too: `put(s[0])` writes
`104`; a character is written with `putc(c)` or as the slice `s[i..i + 1]`); floats as the shortest
text that reads back exactly in their type, always with a point or an exponent (`3.0`, `1e21`,
`inf`, `nan`; `1.0 / 3.0` is `0.33333334`, as an `f64` `0.3333333333333333`; fixed decimals:
`fmtf(x, 2)`); `bool` as `true` / `false`; `str` as its text, without quotes, also inside other
values; other slices and arrays as `[a, b]`; structs as `Name{field: value}`; tuples as `(a, b)`;
enums as `Variant(fields)`; a `Map` as `{key: value, key: value}` in insertion order; pointers as
hexadecimal addresses. Print a `Vec` as `v[..]` (`print(v)` shows the struct with its whole buffer).

## Standard library

Always available, no `use`. Every function below can also be called as a method on its first
argument (`v.push(x)`, `s.trim()`). `alc sigs file.al -- std` prints every library signature,
including the math, random and time functions described in [STDLIB.md](STDLIB.md).

```
// ---- output: standard output is buffered and written at exit, at exit(), before a panic, before eprint / eput, and when
//      64 KiB have gathered. A closed pipe ends the program (SIGPIPE, as in Unix tools); any other error writing standard
//      output stops it with `panic: cannot write to standard output: ...`; errors writing standard error are ignored
putc(c: u8)    flush()                     // one byte; write the buffered output now (before waiting or reading a reply)
putf(x: f64, digits: i64)    fmtf(x: f64, digits: i64) -> str   // fixed notation like C "%.Nf": fmtf(3.14159, 2) is "3.14"; digits < 0: assertion failure; also for f32 (its exact value)
fmtf(x: f64, digits: i64, width: i64) -> str   // the same, right-aligned in width characters: fmtf(3.14159, 2, 8) is "    3.14"; also for f32
eprint(s: str)    eput(s: str)             // s to standard error, unbuffered, with / without a newline: eprint(fmt("bad: ", x))
exit(code: i64) -> never                   // flush, end the program with this exit status

// ---- numbers
min(a: T, b: T) -> T    max(a: T, b: T) -> T    abs(x: T) -> T   // min / max: any numeric type or str (both arguments the same type), NaN if either is NaN; abs: any signed integer or float type
swap(a: *T, b: *T)    floor ceil round trunc pow fmod sin cos tan atan2 exp log ...   // swap(&x, &y), swap(&v[i], &v[j]); the math functions exist for f32 and f64 (the argument type picks one): std/math.md
clock_ns() -> i64                          // monotonic clock in nanoseconds; there are no integer limit constants: the largest i64 is 0x7FFF_FFFF_FFFF_FFFF

// ---- slices (for a Vec pass v[..])
sort(a: []T)                               // ascending, in place; T is a number type or str (bytewise, like cmp)
sort_by(a: []T, less: fn(T, T) -> bool)    // stable; descending: sort_by(xs, fn(a: i64, b: i64) -> bool { a > b })
sort_by(a: []T, ctx: C, less: fn(C, T, T) -> bool)   // `ctx` is handed to every comparison (there are no closures)
index_of(s: []T, x: T) -> i64    contains(s: []T, x: T) -> bool    reverse(s: []T)   // position of the first element == x, or -1; reverse works in place
copy(dst: []T, src: []T) -> i64    fill(a: []T, x: T)   // copies min(len(dst), len(src)) elements (they may overlap), returns that number; every element = x

// ---- Vec[T]: growable array.  struct Vec[T] { buf: []T, len: i64 }
vec[T]() -> Vec[T]                         // the zero value is an empty, usable Vec too: a field `xs: Vec[T]` needs no vec[T]()
vec_of(s: []T) -> Vec[T]    vec_fill(n: i64, x: T) -> Vec[T]   // a Vec of copies of the elements of s: vec_of([]i64{1, 2}); of n times x
v.len    len(v)    v[i]    v[a..b]    for x in v    for i, x in v     // checked against v.len
v.push(x: T)    v.pop() -> T               // appends; removes and returns the last element (empty: panic)
v.last() -> T    v.is_empty() -> bool      // the last element (stays in the Vec); empty: assertion failure (failures name the caller's line; called through a function value: `at ?`)
v.items() -> []T                           // = v[..]: the elements as a slice (empty Vec: empty slice)
v.clear()                                  // length 0, capacity kept
v.truncate(n: i64)                         // keeps the first n elements; nothing happens if n >= v.len; n < 0: assertion failure
v.resize(n: i64, x: T)                     // exactly n elements: cuts, or appends copies of x; n < 0: assertion failure
v.reserve(n: i64)                          // capacity for n elements in total (not n more); length unchanged
v.extend(s: []T)                           // appends all elements of s; another Vec: v.extend(w[..])
v.insert(i: i64, x: T)                     // x becomes element i (0 <= i <= v.len), the rest moves up; else assertion failure
v.remove(i: i64) -> T                      // removes and returns element i, the rest moves down (order kept)
v.swap_remove(i: i64) -> T                 // removes and returns element i, the last element takes its place (fast)
v.contains(x: T) -> bool    v.dedup()      // (position: index_of(v[..], x)); removes adjacent equal elements (sort first to remove all duplicates)

// ---- Map[K, V]: hash map that keeps the order of insertion. K is any type with == (numbers, str, structs, tuples, enums); a NaN key equals nothing (each set adds an entry that cannot be found)
map[K, V]() -> Map[K, V]                   // the zero value is an empty, usable Map too
m.set(k: K, v: V)                          // inserts (as the last entry) or replaces the value (the entry keeps its place)
m.get(k: K) -> (V, bool)                   // a COPY of the value and true; (zero value, false) if k is missing
m.get_or(k: K, default: V) -> V    m.has(k: K) -> bool    m.del(k: K) -> bool   // del removes k; false if it was missing
m.ptr(k: K) -> *V                          // pointer to the stored value (nil if missing) to change it in place; valid until a new key is set
m.keys() -> []K    m.values() -> []V       // new slices of all keys / values in the order in which the keys were first set (a deleted key that is set again is the last)
m.len    len(m)    m.clear()               // number of entries; remove every entry

// ---- strings.  str = []u8: s[i] is a byte, s[a..b] a view (no copy), len(s) counts bytes, == compares content
concat(a: str, b: str) -> str    repeat(s: str, n: i64) -> str   // new strings: a then b (more parts: fmt(a, b, c)); n copies of s ("" if n <= 0)
find(s: str, sub: str) -> i64    rfind(s: str, sub: str) -> i64  // index of the first / last occurrence of sub, or -1 (empty sub: 0 / len(s))
find(s: str, sub: str, from: i64) -> i64   // the first occurrence at from or later, or -1; from is checked like s[from..] (0..=len(s))
find_any(s: str, chars: str, from: i64) -> i64   // index of the first byte at from or later that is one of chars, or -1
count(s: str, sub: str) -> i64             // occurrences, taken left to right without overlap: count("aaaa", "aa") is 2
replace(s: str, old: str, new: str) -> str // a new string with each of these occurrences of old replaced: replace("a-b-c", "-", "+")
starts_with(s: str, p: str) -> bool        ends_with(s: str, p: str) -> bool
trim(s: str) -> str    trim_left(s: str) -> str    trim_right(s: str) -> str   // views without the white space (' ', '\t', '\n', '\r', '\x0b', '\x0c') at both ends / the start / the end
trim(s: str, chars: str) -> str    trim_left, trim_right the same   // without the bytes of chars there: trim_right("a//", "/") is "a"
split(s: str, sep: u8) -> []str            // views of the pieces between separators: "a  b" gives ["a", "", "b"], "" gives [""]; always (number of separators + 1) pieces
split(s: str, sep: str) -> []str           // the same for a separator string: split("a, b", ", "). Empty sep, and empty sub / old in count / replace: panic
fields(s: str) -> []str                    // views of the pieces between runs of white space, none empty: "  a \t b " gives ["a", "b"], "" gives []
lines(s: str) -> []str                     // split at '\n' after dropping ONE final '\n'; a '\r' stays; "" gives [""]
join(parts: []str, sep: str) -> str        // join(names[..], ", ")
cmp(a: str, b: str) -> i64                 // negative / 0 / positive: a before / equal / after b, bytewise; "a" < "ab"
to_upper(s: str) -> str    to_lower(s: str) -> str     // new string; ASCII letters only
pad_left(s: str, width: i64, fill: u8) -> str    // right-aligns: pad_left("ab", 4, ' ') is "  ab"; never cuts (as everything with a width)
pad_right(s: str, width: i64, fill: u8) -> str   // left-aligns
fmti(x: T, width: i64, fill: u8) -> str    // an integer of any type right-aligned: fmti(42, 5, ' ') is "   42"; fill '0' follows the sign: fmti(-42, 5, '0') is "-0042"
hex(x: u64) -> str    hex(x: u64, width: i64) -> str   // lower case, no prefix: hex(255) is "ff", hex(255, 4) "00ff" (zeros up to width); other types: hex(u64(n))
to_base(x: u64, base: i64) -> str          // the digits in base 2..36 (0-9, a-z), no prefix: to_base(5, 2) is "101"; any other base: panic
parse_i64(s: str) -> (i64, bool)           // the whole of s must be [+-]digits (no spaces, no 0x, no _) and fit in an i64; else (0, false)
parse_i64(s: str, base: i64) -> (i64, bool)   // the same in base 2..36 (letters of either case; no prefix): parse_i64("ff", 16). Base 0: 0x / 0b / 0o after the sign decide, else decimal ("-0x1F", "017" is 17); other bases: panic
parse_f64(s: str) -> (f64, bool)           // [+-]digits[.digits][e[+-]digits] (also ".5", "5.", "1e3"); no spaces, inf, nan. parse_f32: the same to f32, rounded once from the text
is_digit(c: u8) -> bool   is_alpha  is_alnum  is_upper  is_lower  is_space: the same   // ASCII; '_' is none of them; is_space: the white space of trim

// ---- Opt[T]: a value that may be absent.  enum Opt[T] { None, Some(T) }  (zero value: None)
is_some(o: Opt[T]) -> bool   is_none(o: Opt[T]) -> bool   unwrap(o: Opt[T]) -> T   or(o: Opt[T], default: T) -> T   // unwrap / or: the value; if None: "panic: unwrap of None" / default

// ---- files and process
read_file(path: str) -> (str, bool)        // the whole file; ("", false) if it cannot be opened or read
write_file(path: str, data: str) -> bool   // creates or replaces the file; false on failure
read_all(fd: i64) -> str                   // everything up to end of input; read_all(0) reads standard input
io_error() -> i64                          // Linux error number (on Windows too) of the last read_file / write_file / read_all; 0 after success
error_text(e: i64) -> str                  // "no such file or directory" (2), "permission denied" (13), "is a directory" (21), "file exists" (17), ...; "no error" for 0; "os error N" for other numbers
args() -> []str                            // args()[0] is the program's path; `alc run f.al -- a "b c"` gives ["./f", "a", "b c"]; started with an empty argv (execve): [""] (Linux supplies an empty argv[0]; before 5.18: [])
env_get(name: str) -> (str, bool)          // an environment variable; ("", false) if it is not set
```

| C `printf` | AL | C `printf` | AL |
|------------|----|------------|----|
| `%d`, `%s`, `%g` | `fmt(x)` | `%x`, `%08x`, `%X` | `hex(x)`, `hex(x, 8)`, `to_upper(hex(x))` |
| `%5d`, `%05d` | `fmti(x, 5, ' ')`, `fmti(x, 5, '0')` | `%10s`, `%-10s` | `pad_left(s, 10, ' ')`, `pad_right(s, 10, ' ')` |
| `%-5d` | `pad_right(fmt(x), 5, ' ')` | `%.2f`, `%8.2f` | `fmtf(x, 2)`, `fmtf(x, 2, 8)` |

Idioms:

```
struct Enemy { hp: i64, loot: Vec[str] }

fn main() {
    // build a string: fmt for a few parts; a Vec[u8] (or a Vec[str] and join) in a loop
    b := vec[u8]()
    for i in 0..3 {
        b.extend(fmt(i, ","))
        b.push(';')
    }
    text := b.items()                                  // a str
    // change a struct stored in a Map: through ptr, or get a copy / change it / set it back
    m := map[str, Enemy]()
    m.set("orc", Enemy{hp: 10})
    m.ptr("orc").loot.push("axe")
    e, _ := m.get("orc")
    e.hp -= 3
    m.set("orc", e)
    for k in m.keys() { print(k, m.get_or(k, Enemy{}).hp) }    // orc 7  (the keys in insertion order)
    // order by something outside the elements: the context argument
    scores := []i64{70, 95, 80}
    order := []i64{0, 1, 2}
    sort_by(order, scores, fn(scores: []i64, a: i64, b: i64) -> bool { scores[a] > scores[b] })
    print(text, m.ptr("orc").loot[..], order, fmti(42, 6, ' '))   // 0,;1,;2,; [axe] [1, 2, 0]     42
}
```

## Tooling

```
alc build file.al [-o out]     compile; the executable is the source path without `.al`
alc run file.al [-- args...]   compile (writing the executable as build does) and run; exit status of the program
alc test file.al               compile and run all `test` blocks, each in its own process (`main` is not run and
                               need not exist); per test its output, then `ok   name` / `FAIL name`; status 1 if any failed;
                               the test runner is written to `file.test`
alc check file.al              type-check only
alc sigs file.al [-- std]      one line per declaration: `file:line: signature`; `-- std` adds the library's
options: --unchecked  -O0  --json  --emit-ir  --emit-asm  --target linux|windows (windows: a console `file.exe`; run/test use Wine if ALC_WINE=1; DETAILS.md#windows)
```

Diagnostics list every error found, sorted by position: `file:line:col: error: message` (`col`
counts bytes from 1). With `--json` they are printed to standard output as `[{"file":"f.al",
"line":3,"col":7,"message":"..."}]`; errors without a position (unreadable file) have line 0.

## Unsafe corners

Everything else is checked. These are not:
- Using memory after `release()`, `reset()` or `region_free()` gave it back (slices, pointers,
  `Vec`s, `Map`s into it), or a slice or pointer into a local of a function that has returned.
- A slice or pointer into a `Vec` (or `m.ptr(k)`) used after the container grew; a `Vec` / `Map`
  that grew inside a region and is used after its reset (see [Memory](#memory)).
- Copying a `Region` that holds memory; unbalanced `enter` / `leave`.
- A `&name` pattern binding kept after the matched enum value was overwritten with another
  variant (it then points at storage that holds something else); a guard that modifies the
  value being matched.
- `cast`, `mkslice`, `ptr`, `memcopy`, `memfill`, `syscall`, indexing a raw pointer `p[i]`,
  `extern` functions (the declared signature is trusted), `--unchecked` builds. Typed memory:
  a location written as one scalar type must not be read as another (except through `u8`).
- `priv` is a naming rule, not protection.

## f32, vectors, matrices

`vec2 vec3 vec4` are vectors of 2 / 3 / 4 `f32` (C-compatible: 8 / 12 / 16 bytes), `quat` is
`(x, y, z, w)`, `mat4` four `vec4` columns. A float literal is an `f32` unless an `f64` is expected.

```
x := 1.5                         // an f32 (the default); f32 and f64 never mix: f32(n), f64(x)
a := vec3(1.0, 2.0, 3.0)         // constructors: components, vec3(0.5) for all lanes, vec4(a, 1.0)
c := a + a * 2.0 - a / a         // + - * / work lane-wise; a vector combines with an f32
a.y = 4.0                        // components x y z w (or r g b a), a[i]; swizzles (read-only): a.zyx
p := mat4(1.0) * vec4(a, 1.0)    // mat4(1.0) is the identity; mat4 * vec4, mat4 * mat4, quat * vec3
```

All operators, constructors and conversions of these types, and the functions on them (`dot
cross length normalize lerp`, matrices, quaternions): [std/math.md](std/math.md).

## C interop

```
extern "libc.so.6" fn getenv(name: *u8) -> *u8
extern "libm.so.6" fn cosf(x: f32) -> f32
extern "libc.so.6" environ: **u8           // a C variable: read, assign, `&environ`; no initializer

home := from_cstr(getenv(ptr("HOME")))     // string literals are NUL-terminated in memory
p := cstr(path)                            // NUL-terminated copy of any str
```

Parameters and results are integers, `bool`, floats, pointers or function values (C `int` is
`i32`, `long` is `i64`, `char*` is `*u8`; structs go by pointer). A program that reaches an
`extern` function is dynamically linked; every other program is static. More:
[DETAILS.md](DETAILS.md#c-interop).
