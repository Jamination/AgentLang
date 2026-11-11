# AL language reference

AL is a small, statically typed, compiled language designed to be written by AI agents.
`alc` compiles it directly to static x86-64 Linux executables (no LLVM, no assembler, no linker,
no libc).

Design rules that shaped it:

- **One obvious way** to write each thing; a regular grammar with few special cases.
- **No undefined arithmetic**: integers wrap, shift counts are reduced modulo the width,
  division by zero and out-of-bounds indexing stop the program with a `file:line` message.
- **No hidden work**: no implicit conversions, no constructors/destructors, no exceptions.
- **Everything checked at once**: the compiler reports all errors in a file (also functions
  that are never called), as `file:line:col: error: ...` or as JSON (`--json`).
- **Whole program, no build system**: `alc build main.al`; declarations may appear in any order.
- **Cheap memory management**: bump allocation from arenas: `mark()` / `release()`, and regions
  that are emptied in one step.

Contents: [Quick tour](#quick-tour) · [Lexical structure](#lexical-structure) · [Types](#types) ·
[Declarations](#declarations) · [Statements](#statements) · [Expressions](#expressions) ·
[Generics](#generics) · [Memory](#memory) · [Run-time errors](#run-time-errors) ·
[Builtins](#builtin-functions) · [Standard library](#standard-library) · [Tooling](#tooling) ·
[Unsafe corners](#unsafe-corners) · [Grammar](#grammar-summary)

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
        if less(best, x) {
            best = x
        }
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
    often := 0
    fn tally(w: str, counts: *Map[str, i64], often: *i64) {    // a nested function
        if counts.get_or(w, 0) > 1 { *often += 1 }
    }
    for w in words { tally(w, &counts, &often) }
    print(counts.get_or("a", 0), counts.len, words[1], often)   // 3 3 b 3
}

test "areas" {
    assert area(Empty) == 0.0
    assert area(Rect(Point{0.0, 0.0}, Point{2.0, 3.0})) == 6.0, "rect"
}
```

```
alc run tour.al        # build + run
alc test tour.al       # run the test blocks
```

## Lexical structure

- Source is UTF-8 text; identifiers are ASCII: `[A-Za-z_][A-Za-z0-9_]*`.
- Comments: `//` to the end of the line.
- **Statements end at a newline** (or `;`). A newline does *not* end a statement when the line
  ends in an operator, a comma or an opening bracket, or anywhere inside `( )` / `[ ]`.
  A line cannot *start* with a binary operator.
- Keywords: `fn struct enum const test use priv extern inline noinline if else while loop for
  in by return break continue assert match defer true false nil`. `type` is special only at the
  start of a declaration and stays usable as an identifier.
- Integer literals: `42`, `1_000_000`, `0xFF`, `0b1010`, `0o17`, character literals `'a'`, `'\n'`,
  `'\x41'` (a character literal is an integer).
- Float literals: `1.5`, `1e9`, `2.5e-3` (a digit is required on both sides of the point).
- String literals: `"text"` with escapes `\n \t \r \0 \\ \" \' \xHH`. A string is a `str`
  (`[]u8`); literals are read-only.
- Raw string literals: text between backquotes, taken as is (no escapes) and allowed to span
  lines; meant for embedded shader source and other multi-line text.

## Types

| Type | Meaning |
|------|---------|
| `i8 i16 i32 i64`, `u8 u16 u32 u64` | integers; arithmetic wraps around |
| `f64`, `f32` | IEEE-754 double / single |
| `vec2 vec3 vec4` | vectors of 2 / 3 / 4 `f32` (8 / 12 / 16 bytes, C-compatible); held in one SSE register |
| `quat` | quaternion `(x, y, z, w)` of `f32`, `w` is the scalar part |
| `mat4` | 4x4 `f32` matrix: four `vec4` columns (column-major, 64 bytes) |
| `bool` | `true` / `false` |
| `*T` | pointer to `T` (may be `nil`) |
| `[]T` | slice: pointer + length, a view of elements stored elsewhere |
| `[N]T` | array of `N` elements stored inline (`N` is a constant expression) |
| `str` | another name for `[]u8` |
| `(A, B, ...)` | tuple |
| `fn(A, B) -> R` | function value: a plain code pointer (8 bytes, C-compatible); `fn(A)` returns nothing |
| `Name`, `Name[T, U]` | struct or enum, possibly generic; or a type alias |

There are no implicit conversions between types. Untyped numeric literals take the type the
context asks for (`x: u8 = 200`, `x * 2`, `f(3)`); without context an integer literal is
`i64` and a float literal is `f64`. An integer literal is accepted where a float is expected,
and a literal next to an `f32` or a vector is an `f32` (`v * 2.0`, `x + 1`).

Structs, tuples, arrays and enums are values: assignment, argument passing and returning copy
them. Slices and pointers are references to shared storage, so a copy shares what the slices
inside it (and every `str`, `Vec` and `Map`) refer to; [`clone(x)`](#clonex) makes an
independent copy.

A copy is a value of its own: after `a := v[0]`, assigning to `a.x` does not change `v[0]`.
The one form of this that is always a mistake is a compile error: a variable declared with
`:=` from a field or element of struct type (`v[i]`, `w.one`, `p.items[i].pos`, ...) whose only
uses in the rest of its block are field assignments (`a.x = ...`, `a.x += ...`), so that the
copy is written and never read.

```
a := v[0]                 // a copy of the element
a.x = 10                  // error: `a` is a copy of `v[0]` ... To change the original write
                          //   `v[0].x = ...`, or take a pointer: `a := &v[0]`
```

```
v[0].x = 10               // writes the element
p := &v[0]                // or work through a pointer
p.y = 20
b := v[0]                 // a copy that is read afterwards is fine
b.x = 0
print(v[0], b)            // P{x: 10, y: 20} P{x: 0, y: 20}
```

Layout follows the usual C rules (natural alignment); `sizeof[T]()` gives the size in bytes.

## Declarations

Top-level declarations can appear in any order. **A declaration that starts with a keyword
(`fn`, `struct`, `enum`, `type`, `const`) declares something fixed at compile time; one that
starts with a name declares a variable** (`name := value`, `name: Type = value`, `name: Type`),
the same at top level and inside functions. Inside a function only variables and functions can
be declared. A result type follows `->`; a function without a result has no arrow.

```
fn name(a: i64, b: f64) -> i64 { ... }     // function; omit the result type for "no value"
fn pick[T](a: T, b: T) -> T { ... }        // generic function
inline fn tiny(x: i64) -> i64 { x + 1 }    // inlining hint; `noinline fn` forbids inlining
struct Pair[A, B] { first: A, second: B }   // struct (fields separated by `,` or newlines)
enum Color { Red, Green, Blue }            // enum without data: an integer-like value
enum Tree[T] { Leaf(T), Node(*Tree[T], *Tree[T]) }   // enum with data ("tagged union")
type Reg = i64                             // type alias: another name for a type
const LIMIT = 1000                         // compile-time constant (untyped unless annotated)
const MASK: u32 = 0xFF00
const TABLE = [4]i64{1, 2, 4, 8}           // aggregate constant, stored once in read-only memory
const LOGO = embed("logo.bin")             // content of a file as a str, read at compile time
counter: i64                               // global variable, zero-initialized
table := [4]i64{1, 2, 4, 8}                // global with a constant initializer
ops := [2]fn(i64) -> i64{double, negate}   //   (function names are constants too)
test "name" { ... }                        // unit test, run by `alc test`
use "other.al"                             // include another file (path relative to this file)
use std.window                             // a module bundled with the compiler (see docs/STDLIB.md)
extern "libc.so.6" fn getpid() -> i32      // a C function from a shared library (no body)
priv fn helper(x: i64) -> i64 { ... }      // `priv`: visible only inside this file (see below)
```

- The program starts at `fn main()`; `fn main() -> i64` returns the exit status.
- A function whose result type is `never` does not return (`exit`, `panic`).
- All top-level names of a program share one namespace, whatever file they are in, except
  declarations marked [`priv`](#priv-file-private-declarations).
- A variant belongs to its enum (`Color.Red`, or just `Red` where that is unambiguous): see
  [Enum variants](#enum-variants).
- A user declaration may reuse a standard-library name (for example your own `push` or `Vec`);
  the library keeps using its own definitions internally.
- **Overloading**: a function name may be defined several times with different parameter types
  (`fn area(c: Circle) -> f32` and `fn area(r: Rect) -> f32`; `fn length(v: vec3) -> f32` and
  `fn length(v: vec2) -> f32`).
  A call looks at the receiver (`x.f()`) and then at the arguments from left to right until one
  definition is left: a typed argument must have the parameter's type, an untyped literal must
  be acceptable to it. If literals leave a tie, the definition whose parameters are the
  literals' default types (`i64`, `f64`) wins, unless another one returns the expected type.
  User definitions are considered before library definitions of the same name.
- **Builtin names**: a function may have the name of a builtin (`len`, `ptr`, `clone`, `hash`,
  `print`, `fmt`, `sqrt`, ...). A call (also `x.f(a)`) uses the declared functions first, by the
  overloading rules; when none of them accepts the number or types of the arguments, the
  builtin is used. A declared function thus extends a builtin to new argument types, or
  replaces it for exactly the types it declares. The arguments are evaluated once, left to
  right, before the function is chosen (the builtin `print` / `put` normally writes each
  argument as soon as it is evaluated; a call with as many arguments as a declared `print`
  takes evaluates all of them first). If exactly one non-generic function of the name is
  declared, its parameter types are the expected types of the arguments as in any call
  (`f(Some(1))` builds an `Opt[u8]` for `fn f(o: Opt[u8])`), and an argument that cannot be
  built for that type is an error at the argument, not a reason to use the builtin. When
  nothing fits, the builtin's message is shown and names the declared candidates. Library
  code is not affected: inside the library `len`, `hash`, ... always mean the builtins.

  ```
  struct Money { cents: i64 }

  fn len(m: Money) -> i64 { m.cents }                // next to the builtin len
  fn print(m: Money) { put("$", m.cents / 100, ".", m.cents % 100, "\n") }

  fn main() {
      m := Money{250}
      xs := []i64{7, 8}
      print(len(m), len(xs), m.len(), xs.len())      // 250 2 250 2
      print(m)                                       // $2.50      (declared)
      print(m, xs)                                   // Money{cents: 250} [7, 8]   (builtin: two arguments)
  }
  ```
- `f[T](args)` and `x.f[T](args)` pass type arguments explicitly. `f[T]` alone, or `f` where a
  function type is expected, is the function value of that instantiation.

### Enum variants

Two enums may have variants of the same name, also an enum of the program and one of the
library.

```
enum Color { Red, Green, Blue }
enum Light { Red, Amber, Green }
enum Tree[T] { Leaf(T), Node(*Tree[T], *Tree[T]), Empty }

fn next(l: Light) -> Light {
    match l {
        Red => Green                    // pattern: the matched type decides
        Green => Amber
        Light.Amber => Red              // the qualified form is always allowed
    }
}

fn main() {
    a := Color.Red                      // qualified
    b := Blue                           // only Color has Blue
    c: Light = Red                      // the declared type decides
    lights := []Light{Red, Amber}       // element type of a typed literal
    l := Tree[i64].Leaf(1)              // type arguments written out
    m := Tree.Leaf("x")                 // inferred from the payload: Tree[str]
    print(a, b, next(c), c == Red, lights, l, m, Opt[u8].None)   // Red Blue Green true [Red, Amber] Leaf(1) Leaf(x) None
}
```

**Qualified form**: `Enum.Variant`, `Enum.Variant(args)`; for a generic enum `Enum[T].Variant(args)`
or `Enum.Variant(args)` (type arguments from the expected type, else inferred from the
payload). It is allowed wherever a variant can be written, in expressions and patterns.
`Enum` must not be a local variable (`e.b` stays a field access).

**Bare form**: `Variant` or `Variant(args)` in an expression is resolved in this order:

1. A local variable of that name is the variable.
2. If the **expected type** is an enum with a variant of that name, it is that variant. The
   expected type is known for: a variable declared with a type, the right side of an
   assignment, an argument, a returned value and the last expression of a function, a field
   of a struct literal, an element of a typed array / slice / tuple literal, a payload value
   of a variant, and an operand of `==` / `!=` whose other operand has a type.
3. Otherwise, if exactly one enum of the program has the variant, it is that one. Only if
   none has it are the library's enums searched in the same way (so a program's own `Some` /
   `None` hide the library's).
4. If several remain, it is an error that lists them (`` `Red` is a variant of several enums
   (`Color`, `Light`) and the expected type does not say which; write `Color.Red` or
   `Light.Red` ``).

In a pattern the type of the matched value decides. A call of an overloaded function looks at
a bare variant argument like at a literal: the definitions whose parameter is an enum with
that variant remain; if the expected result type does not decide between them, write
`f(Color.Red)`.

Name conflicts:

- A variant cannot have the name of a function, constant, global, struct or enum of the
  program, and an enum cannot declare a variant twice.
- A variant of the program may have the name of a library declaration; in the program the name
  then means the variant (`enum Cmd { push, pop }`: `push` is `Cmd.push`; `v.push(1)` still
  calls the library function). Conversely a function, constant, global or type of the program
  hides a *library* variant of that name (`Opt.Some(x)` still reaches it).
- In a call, the name of a builtin function or type stays the builtin (`len(x)`, `i64(x)`)
  even if an enum has such a variant (construct it as `Enum.len(..)`); without parentheses the
  name is the variant.
- Library code resolves bare variants among its own enums first.

`print` shows a variant by its bare name. A payload is evaluated exactly once.

### Type aliases

`type Name = T` gives the type `T` another name.

- An alias is **transparent**: `Name` and `T` are the same type everywhere (assignment,
  overloading, generic inference, `==`); diagnostics show the underlying type. `fn f(x: Reg)`
  next to `fn f(x: i64)` is therefore a duplicate definition.
- The name works wherever a type name does: `x: Name`, conversions `Name(x)`, literals
  `Name{...}`, type arguments `vec[Name]()`, `sizeof[Name]()`.
- The target may be any type, also one declared later or one that refers back to the alias
  through a struct or enum. An alias that refers to itself without one (`type A = *A`, or
  through other aliases) is an error: a recursive type needs a struct or enum.
- Aliases are not generic and take no type arguments (`type Pair[T] = ...`, `Reg[i64]` are errors).
- An alias may reuse a library type name; its name must differ from every other declaration
  and enum variant of the program.

```
type Reg = i64
type List = *Node                          // may refer to later declarations
struct Node { v: Reg, next: List }

fn main() {
    l := &Node{v: 1, next: &Node{v: 2, next: nil}}
    plain: i64 = l.next.v                  // Reg is i64
    print(plain, Reg(3.7), sizeof[List]()) // 2 3 8
}
```

### Constants

A `const` is a compile-time constant. Its initialiser may be: number, `bool` and string
constants and constant expressions of them; `T{...}` literals and tuples (nested as needed);
`vec2/vec3/vec4/quat/mat4(...)` with constant components; names of non-generic functions (for
elements of function type); `nil`; variants of enums without data (as elements or fields of a
typed literal); `embed("file")`; names of other constants. Function calls are not constant.
Global initialisers (`x := ...`) follow the same rules and may name constants.

- The type is taken from the value unless annotated (`const UNIT: Point = Point{1, 1}`; a
  mismatch is an error). A constant cannot depend on itself.
- An aggregate (array, struct, tuple) or vector / matrix constant is stored once in read-only
  memory. It can be read as a whole or in part, indexed (bounds-checked), iterated, compared,
  sliced (`TABLE[1..3]`), passed and returned by value, and copied (`t := TABLE` is an
  independent copy).
- No constant can be modified: assigning to it or to a field / element of it, and `&` on it or
  on a part of it are compile errors (`` `TABLE` is a constant: it cannot be assigned to (copy
  it to a variable, or declare it without `const`, as `TABLE := value` or `TABLE: T = value`,
  to make it a global variable)``). As the receiver of a method call that takes a pointer, a
  constant is copied to a temporary.
- `embed("file")` is the content of a file as a `str` constant. The path is relative to the
  source file that contains the call; the file is read once per path.

```
struct Point { x: i64, y: i64 }
struct Unit { name: str, at: Point, f: fn(i64) -> i64 }
enum Op { Add, Sub }

const N = 3
const TABLE = [4]i64{1, 2, 4, 8}
const UNITS = [2]Unit{Unit{"one", Point{0, 0}, double}, Unit{name: "two", at: Point{N, N * 2}, f: double}}
const OPS = ([2]Op{Sub, Add}, "ops", vec3(0.0, 1.0, 0.0))
const LOGO = embed("logo.bin")
table := TABLE                             // a global initialised from a constant

fn double(x: i64) -> i64 { x * 2 }

fn main() {
    print(TABLE[2], UNITS[1].at.y, UNITS[0].f(21), OPS, len(LOGO))   // 4 6 42 ([Sub, Add], ops, vec3(0.0, 1.0, 0.0)) 5
    t := TABLE                             // an independent copy
    t[0] = 100
    table[0] = 9
    print(t, table, TABLE[1..3])           // [100, 2, 4, 8] [9, 2, 4, 8] [2, 4]
}
```

### `priv`: file-private declarations

`priv` in front of `fn` (also `inline` / `noinline` / `extern` functions), `struct`, `enum`,
`type`, `const` or a global variable takes the declaration out of the program-wide namespace:
it is visible only inside the file that contains it.

```
// stack.al
priv const LIMIT = 2                       // only this file sees LIMIT, Slot, slots, find
priv struct Slot { key: str, val: i64 }
priv slots: Vec[Slot]

priv fn find(key: str) -> i64 {            // the library's find(s, sub) stays usable
    for i, s in slots {
        if s.key == key { return i }
    }
    -1
}

fn stack_set(key: str, val: i64) -> bool {   // public: the interface of the file
    i := key.find()                        // method-call syntax finds private functions
    if i >= 0 {
        slots[i].val = val
    } else if slots.len < LIMIT {
        slots.push(Slot{key, val})
    }
    i >= 0
}

fn stack_dump() { print(slots[..], find("a=b", "=")) }
```

```
// main.al
use "stack.al"

priv const LIMIT = "none"                  // another LIMIT: each file has its own
priv fn find(xs: []i64, x: i64) -> bool {
    for v in xs {
        if v == x { return true }
    }
    false
}

fn main() {
    stack_set("a", 1)
    print(stack_set("a", 3), stack_set("b", 2), LIMIT, find([]i64{1, 2}, 2))   // true false none true
    stack_dump()                           // [Slot{key: a, val: 3}, Slot{key: b, val: 2}] 1
}
```

- **Visibility.** A private declaration can be used anywhere in its own file (before or after
  the declaration, also in `test` blocks) and nowhere else; `use` does not change that in
  either direction. In other files the name is unknown (the diagnostic says where it is
  declared `priv`), or means whatever other declaration of that name they can see.
- **Same name elsewhere.** Any number of files may each declare a private `name`, and a private
  name may equal a public declaration of another file or a library name. Inside the file the
  private declaration wins. A private struct, enum, constant, global or alias hides every
  public declaration of that name, of whatever kind.
- **One file, one meaning.** Within one file a name cannot be declared both with and without
  `priv`; all definitions of an overloaded function in one file are either private or public.
  An enum variant cannot have the name of a private declaration of the same file.
- **Functions: private first.** A call `f(args)` or `x.f(args)` in a file with private
  definitions of `f` considers them together with the public ones (other files, then the
  library) as one overloaded name, with one addition: if a private definition fits the call,
  a public one is never chosen, not even one that would fit better. So a private
  `fn min(a: Meters, b: Meters)` leaves `min(3, 4)` to the library, and a private
  `fn max[T](a: T, b: T) -> T` replaces the library's `max` in its file completely. The same
  holds for a private function used as a value.
- **Builtins.** A private function named like a builtin (`len`, `hash`, `clone`, ...) is
  tried first in its file, and the builtin is used when it does not accept the arguments, as
  for a public function: with `priv fn len(q: Queue) -> i64`, `len("text")` is still the
  builtin.
- **Fields and locals.** Field names and the field labels of struct literals are never private
  names; a field that holds a function is still called before a private function of that
  name. Local variables, parameters, `match` bindings and type parameters may have the name of
  a private declaration and shadow it.
- **Enums.** `priv enum` makes the *type name* private. Its variants are never private: other
  files can construct and match them by their bare names (not as `Enum.Variant`, which needs
  the type name).
- **Generics.** A public generic function of another file that is instantiated with a private
  type is still checked in its own file: it cannot call the private functions of the file
  that uses it.
- **Not allowed.** `priv fn main`, `priv test`, `priv use`; `priv` inside a function, on a
  struct field or on an enum variant.
- Diagnostics, `print`, `--emit-ir` / `--emit-asm` and the executable's symbol table show
  private declarations under their written names (two files can produce the same struct name
  in output). `alc sigs` marks them `priv` and `alc sigs file.al -- std` omits the library's.

Use `priv` for everything that is not the interface of a file: helpers get their natural short
names (`find`, `Ctx`, `LIMIT`) instead of file prefixes, and no other file can come to depend
on them. The bundled modules do this, so a program may declare its own `splitmix` or `rgba`
although the library has internals of those names.

## Statements

```
x := expr                    // declare a new variable (type inferred)
x: T                         // declare, zero-initialized
x: T = expr                  // declare with an explicit type
a, b := pair()               // declare from a tuple
a, b = b_and_a()             // assign to existing variables from a tuple
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
assert cond                                // stops the program if false
assert cond, "message"
defer { ... }                              // runs when the enclosing block is left
fn name(a: T) -> R { ... }                 // nested function (see below)
match value { ... }                        // see below
{ ... }                                    // nested block (new scope)
```

- Variables are mutable. Declaring a name that already exists **in the same scope** is an
  error; inner scopes may shadow outer names. `_` discards a value (`_, ok := m.get(k)`).
- The last expression of a function body is its result (`fn sq(x: i64) -> i64 { x * x }`).
  The same holds for the branches of `if`/`match` used as expressions.
- `defer` blocks run in reverse order when their scope ends, also on `break`, `continue` and
  `return` (the returned value is computed first).
- In `for i in a..b`, the bounds are evaluated once. The loop variable is an ordinary variable.
- `for x in v` over a `Vec` visits the live elements; it reads the length and the buffer once,
  when the loop starts (elements pushed during the loop are not visited).

### Labelled loops

- A label is `name:` directly before `for`, `while` or `loop` (it may stand on the line before
  the loop; before anything else it is an error). `break name` leaves that loop; `continue
  name` starts its next iteration (`for`: after advancing the loop variable; `while`: at the
  condition). `defer` blocks of all scopes that are left run, innermost first.
- Labels have their own namespace (a label may have the name of a variable). A label is in
  scope inside its loop only: the name may be used again for a later loop, but not for a loop
  nested inside one with that label. An unknown label is an error that lists the labels in scope.
- The label must be on the same line as `break` / `continue` (`break` at the end of a line is a
  plain `break`). They take nothing but a label.

```
fn main() {
    next: for i in 2..20 {
        defer { put(".") }                   // runs on `continue next` and `break next` too
        for d in 2..i {
            if d * d > i { break }
            if i % d == 0 { continue next }  // next iteration of the outer loop
            if i > 13 { break next }         // leaves both loops
        }
        put(i)
    }
    print()                                  // 2.3..5..7....11..13...
}
```

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

- **Forms.** `fn name(params) -> Result { body }` as a statement; `fn(params) -> Result { body }`
  as an expression. Neither has type parameters of its own or takes `inline` / `noinline` /
  `priv` / `extern`. They may contain further nested functions.
- **What the body sees.** Globals, constants, top-level functions, nested functions declared
  before it in the enclosing blocks, itself (recursion), and the type parameters of the
  enclosing function. Using a variable or parameter of an enclosing function is a compile
  error that names it: pass it as a parameter (`&x` if the function changes it). A callback
  that needs state takes it as a context argument, as in `sort_by(items, ctx, less)`.
- **Value.** The name of a nested function, and an anonymous function, is a plain `fn(A) -> R`
  value: it can be called, passed, stored, returned, and given to C as a callback. It stays
  valid after the enclosing function has returned.
- **Scope of the name.** From the declaration to the end of its block. There it hides
  top-level functions and builtins of that name, also in method-call syntax (`x.name()`). A
  block cannot declare the name twice or use it for a variable as well; nested functions
  are not overloaded and not assignable.
- **Control flow.** `return` returns from the nested function. `break`, `continue` and labels
  cannot reach a loop of the enclosing function, and `defer` blocks belong to the function
  they are written in.
- Diagnostics, `--emit-ir` and the symbol table name them `outer.name` and `outer.fn@line:col`.

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

The matched expression is evaluated once; the arms are tried from top to bottom, and the
first whose pattern matches (and whose guard, if any, is true) is taken. The matched value can
be an integer, `bool`, `str`, a float, a pointer, an enum or a tuple; parts of enums and tuples
can have any type.

| Pattern | Matches |
|---------|---------|
| `_` | anything |
| constant: `0`, `-1`, `'a'`, `"text"`, `true`, `1.5`, `nil`, `LIMIT`, `LIMIT + 1` | a value equal to it |
| `Variant`, `Enum.Variant` | that variant (it must have no payload) |
| `Variant(p1, p2)`, `Enum.Variant(p1, p2)`, `Enum[T].Variant(p1, p2)` | that variant, if each payload field matches its sub-pattern (one per field) |
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

- Sub-patterns nest to any depth: `Some(Circle(r))`, `(Some(a), None)`, `Node(Leaf(x), &rest)`.
- **A name inside a variant or tuple pattern** is, in this order: a variant, if the type of
  that part is an enum (or a pointer to one) that has it; a constant, if a `const` of that
  name exists; otherwise a new variable of the arm (it hides an outer variable; a variant of
  some *other* enum is a binding too). Anything else inside a pattern must be a compile-time
  constant: to compare with a variable, bind the part and use a guard
  (`Some(x) if x == limit => ...`).
- **An arm's pattern itself** (not nested) is never a binding: a name there is a variant of the
  matched enum, or an expression that is compared with the matched value (a constant, a
  variable, `x.f(a)`). For "everything else" write `_` and use the matched expression
  (`_ if n > 10 => ...`).
- **Bindings.** `name` holds a copy; assigning to it does not change the matched value. `&name`
  points at the part inside the matched value, to modify it in place. If the matched
  expression is a place (a variable, `x.f`, `a[i]`, `*p`) the pointer points into that place;
  otherwise (a call result, `match (a, b)`) into a temporary of the enclosing function, valid
  until the function returns.
- **Pointers.** A variant or tuple pattern also matches a *pointer* to an enum or tuple: if the
  pointer is not `nil` and the value it points to matches. `nil` is matched by the constant
  `nil`, `_` or a binding. A binding of a pointer-typed part is the pointer itself; `&name`
  inside a pattern that looked through a pointer points into the target.
- **Alternatives.** `p1, p2 => body`: all alternatives of an arm must bind the same names with
  the same types.
- **Guards.** `pattern if cond => body`: `cond` is evaluated after the pattern matched and its
  bindings exist; if it is false, matching continues with the next arm (the other alternatives
  of the same arm are not tried). If a guard changes the variable being matched, the following
  arms still see the value as it was when the `match` began (except with `&name` and through
  pointers: see [Unsafe corners](#unsafe-corners)).
- **Exhaustiveness.** A `match` used as a statement may leave values unmatched: then no arm
  runs. A `match` used as a value must cover every possible value; the error lists what is
  missing in pattern form (`missing: Some(Rect(_, _))`). An arm with a guard covers nothing.
  `_`, a binding, and tuple patterns made of them cover everything; variant patterns are
  combined (`Some(Circle(_))`, `Some(Rect(_, _))`, `Some(Empty)` and `None` cover `Opt[Shape]`;
  `(true, _)` and `(false, _)` cover `(bool, T)`). Integers, floats, strings and pointers are
  never covered by constants alone (`true` and `false` cover `bool`), and through a pointer
  `nil` must be covered separately.

## Expressions

Operators, from tightest to loosest binding (all binary operators are left-associative):

| Operators | Notes |
|-----------|-------|
| `f(x)  a[i]  a[i..j]  x.f  T{...}` | postfix |
| `-x  !b  ~x  &x  *p` | unary: negate, logical not, bitwise not, address-of, dereference |
| `*  /  %` | division truncates toward zero; `%` has the sign of the left operand |
| `+  -` | |
| `<<  >>` | `>>` is arithmetic for signed types; the count is taken modulo the bit width |
| `&` | |
| `^` | |
| `\|` | |
| `==  !=  <  <=  >  >=` | |
| `&&` | short-circuit |
| `\|\|` | short-circuit |

- Both operands of a binary operator must have the same type (shift counts excepted).
- `==` / `!=` work on numbers, `bool`, pointers, enums without data, and **by content** on
  `str`, slices, arrays, structs and tuples. Ordering operators work on numbers.
- `p.field` dereferences pointers automatically; `a[i]` works on slices, arrays, `Vec`s and
  pointers to them. `s.len` and `len(s)` give the length of a slice, array, string or `Vec`.
- `a[i..j]` is the sub-slice `i <= index < j` (bounds may be omitted: `a[..n]`, `a[i..]`, `a[..]`);
  it shares storage with `a`.
- The library's `Vec[T]` (and a pointer to one) is indexed and sliced like a slice: `v[i]` is a
  place (`v[i] = x`, `v[i] += x`, `&v[i]`, `v[i].field = x`) checked against the **length**
  `v.len`, and `v[a..b]` requires `a <= b <= v.len`. `v.buf[i]` addresses the raw buffer
  including the spare capacity and is checked against the capacity only. A slice `v[a..b]` and
  a pointer `&v[i]` refer to the current buffer: after a `push` / `reserve` that grows the
  `Vec` they refer to the old one. A user struct named `Vec` is an ordinary struct.
- `if c { a } else { b }` and `match` are expressions.
- Conversions are written like calls: `i64(x)`, `u8(x)`, `f64(n)`. Integer conversions
  truncate or extend; `f64` to integer truncates toward zero.

Literals for aggregates:

```
Point{x: 1.0, y: 2.0}      Point{1.0, 2.0}       // struct: by name or by position; missing fields are zero
Pair[i64, str]{1, "one"}                         // generic struct
(1, "one", 2.5)                                  // tuple;  fields are t.0, t.1, t.2
[4]i64{1, 2, 3}                                  // array (remaining elements are zero)
[]f64{1.0, 2.0}                                  // slice literal: allocates its elements
&Node{value: 1, next: nil}                       // allocates a struct, yields a pointer
Circle(center, 2.0)      Empty                   // enum values;  qualified: Shape.Circle(c, 2.0),
Opt[i64].None            Tree.Leaf("x")          //   with type arguments written out or inferred
```

In the header of `if` / `while` / `for` / `match` a `{` normally starts the body. A `{` after a
type is a literal there in these cases; anywhere else in a header, wrap the literal in
parentheses (for example an empty named literal as a `match` scrutinee: `match (Point{}).x`):

| Header | `T{` is a literal when ... | Example |
|--------|----------------------------|---------|
| any | the type is written with `[`: `[]T{...}`, `[N]T{...}` | `for s in []i64{1, 2, 3} { }` |
| `for`, `if`, `while` | the type is a name (`Name`, `Name[T]`) and the matching `}` is directly followed by `{`, `.`, `[` or a binary operator | `if p == Point{1, 2} { }`, `while Range{0, 3}.hi > j { }` |
| `match` scrutinee | the type is a name and the braces contain something but no `=>` of their own | `match Point{5, 6}.y { ... }` |

**Method-call syntax**: `x.f(a, b)` means `f(x, a, b)` for any function `f`. If `x` has a
field `f` that holds a function, that is called instead; otherwise a
[nested function](#nested-functions) `f` in scope comes before the top-level functions. Two
adjustments apply to
the receiver only, never to other arguments, also for overloaded and generic functions (a
parameter `p: *T` takes the address, a generic parameter `T` alone takes the receiver by value):

- If `f` expects a `*T` and `x` is a `T`, the address of `x` is passed when `x` is
  **addressable** (a variable, parameter or global, a field, an element, a tuple element, a
  dereference; of any type): what `f` writes through the pointer reaches `x` itself. For any
  other `x` (the result of a call or an operator, a literal, a constant or a part of one) the
  address of a temporary copy is passed, and writes through it are lost. A vector component
  (`v.x`) has no address and is rejected.
- If `f` expects a `T` and `x` is a `*T`, the pointer is dereferenced.

The address of the receiver is taken before the arguments are evaluated and the callee reads
through it afterwards; a scalar receiver passed by value is read before the arguments.

The builtins that take a value first have a method form too: `len`, `clone`, `hash`, `ptr`,
`sqrt`, `fabs`, `fmin`, `fmax`, `popcnt`, `ctz`, `clz`, `bswap`, `rotl`, `rotr` (`s.len()`,
`x.clone()`); their receiver is passed as it is (no automatic `&` or `*`). The other builtins
have none.

```
struct Sel { count: i64, ops: [2]i64 }

fn incr(p: *i64) { *p += 1 }
fn go(self: *Sel) -> i64 {
    self.count.incr()             // a field through a pointer
    self.ops[1].incr()            // an element
    self.count
}
fn make() -> i64 { 41 }

fn main() {
    x := 5
    x.incr()                      // passes &x
    s := Sel{}
    print(x, s.go(), s.go(), s.ops, "abc".len(), x.clone())    // 6 1 2 [0, 2] 3 6
    make().incr()                 // a temporary: the write is lost
}
```

## Generics

Functions, structs and enums can take type parameters in square brackets. Generic code is
compiled separately for each combination of types it is used with, and is type-checked per use
(like templates), so any operation that happens to be valid for the concrete type may be used.

```
fn sum[T](xs: []T) -> T {
    total: T
    for x in xs { total += x }
    total
}
sum([]f64{1.5, 2.5})          // T inferred from the arguments
alloc[u32](16)                // explicit type arguments
o: Opt[i64] = None            // inferred from the expected type (Opt is a library enum)
```

## Memory

All dynamic memory comes from an arena and is zero-initialized:

```
xs := alloc[f64](n)          // slice of n elements
p  := new[Node]()            // pointer to a zeroed Node
q  := &Node{value: 1}        // pointer to an initialized Node
s  := []i64{1, 2, 3}         // slice literal
```

There is no `free` and no garbage collector. Memory is reclaimed in bulk:

```
m := mark()                  // remember the current arena position
... allocate freely ...
release(m)                   // everything allocated since mark() is gone
```

Local variables (including arrays and structs) live on the stack and need no management. The
standard containers (`Vec`, `Map`, strings from `concat`/`fmt`) allocate from the arena too.
Typical use: short programs never release; long-running loops wrap each iteration in
`mark()`/`release()`, or do their work in a region.

### Regions

Memory comes from the **arena in use**. A program starts in the *main arena*. A `Region` is a
further, independent arena: between `enter(&r)` and the matching `leave()` everything that
allocates (`alloc`, `new`, `&T{...}`, slice literals, `Vec`, `Map`, `fmt`, `clone`, every
library function) takes its memory from `r`, and `reset(&r)` gives all of it back in one
step. Use a region for work whose temporary data should not stay: do the work inside it, copy
the result out with `clone`, reset it.

```
region() -> Region               // an empty region (the same as the zero value of Region)
enter(r: *Region)                // allocations now come from r
leave()                          // back to the arena that was in use before the matching enter
reset(r: *Region)                // empties r: everything allocated from it is gone
used(r: *Region) -> i64          // bytes of r in use (sizes are rounded up to 16)
region_free(r: *Region)          // returns r's memory to the operating system
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
        if len(t.text) > len(best.text) {
            best = t
        }
    }
    leave()                              // back to the arena of the caller
    result := clone(best)                // deep copy into it
    reset(&scratch)                      // now the temporary data may go
    result
}

fn main() {
    print(longest("a bb cccc dd"), used(&scratch))   // Token{text: CCCC, line: 2} 0
    a := region()
    enter(&a)
    defer { leave() }                    // leaves on every path out of the block
    xs := alloc[i64](4)                  // from a
    m := mark()
    alloc[u8](100)
    release(m)                           // mark / release act on the arena in use
    print(used(&a), len(xs))             // 32 4
}
```

- **Nesting.** `enter` / `leave` form a stack with the main arena at the bottom; up to 64
  regions can be entered at the same time, and a region cannot be entered twice. They must be
  balanced like brackets: `defer { leave() }` right after `enter` leaves on every path.
- **`mark()` / `release(m)` act on the arena in use.** A mark belongs to the arena it was taken
  in; releasing it while another arena is in use does nothing. (A mark taken before the first
  allocation of an arena means "everything in the arena in use".)
- **Leaving does not reset**: data in a region stays valid after `leave()` until the region is
  reset or freed. That is what makes "leave, `clone` the result, reset" work.
- **`reset(&r)`** may be called whether `r` is in use, entered further down the stack, or not
  entered. The region keeps its memory and hands it out again, zeroed as always.
- **`region_free(&r)`** unmaps the memory; `r` is empty afterwards and can be entered again. The
  region must not be entered.
- **Sizes.** A region reserves address space on its first allocation and commits memory only
  as it is used: 16 GiB per region (the main arena: 64 GiB). If the system refuses the
  reservation, smaller sizes down to 16 MiB are tried and the region is limited to what it
  got. A region that is never allocated from costs nothing.
- **A `Region` is used through a pointer.** Keep it in a variable that outlives its use (a
  global, a field of a long-lived struct, a local of the function that brackets the work) and
  never copy a `Region` that has memory or is entered: both copies would hand out the same
  memory. Its fields are internal.
- Everything allocated while a region is in use lives in it, also what library code allocates
  on your behalf. In particular **a `Vec` or `Map` that grows while a region is in use moves
  its storage into that region**, even if it was created elsewhere, and is invalid after the
  reset. Containers that must survive are grown outside the region, or cloned out.

`Arena` and `frame_begin()` / `frame_end()` of the library are compared with regions in
[std/mem.md](std/mem.md).

### `clone(x)`

`clone(x)` (or `x.clone()`) returns a deep copy of `x` that shares no storage with it,
allocated from the arena in use **at the call**: to move a result out of a region, `leave()`
first, then `clone`.

| Type of `x` | Result |
|-------------|--------|
| numbers, `bool`, vectors, `quat`, `mat4`, enums without data | the value |
| `str`, `[]T` | a new slice of the same length with cloned elements |
| `[N]T`, tuples, structs, enums with data | each element / field / payload cloned |
| `Vec[T]` | a `Vec` of the same length with cloned elements (capacity = length) |
| `Map[K, V]` | an independent map with cloned keys and values |
| `*T`, function values | **the pointer itself: what it points to is shared** |

```
struct Node { name: str, kids: []Node }
struct Doc { root: Node, words: Vec[str], owner: *Node }

fn main() {
    a := []i64{1, 2, 3}
    b := a                               // shares the elements
    c := clone(a)                        // its own elements
    b[0] = 10
    d := Doc{root: Node{"r", []Node{Node{"k", nil}}}, words: vec[str]()}
    d.owner = &d.root
    e := d.clone()                       // root (recursively) and words are copied, owner is shared
    e.root.kids[0].name = "changed"
    e.words.push("x")
    print(a, c, d.root.kids[0].name, d.words.len, e.words.len, e.owner == d.owner)   // [10, 2, 3] [1, 2, 3] k 0 1 true
}
```

- Data that refers to itself through slices (`struct Node { kids: []Node }`) is copied
  completely. Data linked through pointers is not followed (`clone(p)` copies the pointer;
  `clone(*p)` the value): copy such structures by hand, or declare a `clone` function for the
  type (see builtin names in [Declarations](#declarations)).
- The clone of a string literal is ordinary writable memory.
- Cost: a type without any slice inside is a plain copy (no allocation); a slice or `Vec` whose
  elements contain no slice is one allocation and one memory copy; otherwise one allocation
  per slice.
- A user struct that happens to be named `Vec` or `Map` is cloned field by field.

## Run-time errors

These stop the program with exit status 1 and a message on standard error:

| Situation | Message |
|-----------|---------|
| index or slice bound out of range | `panic: index out of bounds at file:line` |
| integer division or remainder by zero | `panic: division by zero at file:line` |
| `assert` fails | `assertion failed at file:line: message` |
| `panic("msg")` | `panic at file:line: msg` |
| non-positive run-time `by` step | `panic: loop step must be positive at file:line` |
| arena exhausted | `panic: out of memory` |
| `enter` of a region that is already entered | `panic: enter: this region is already entered` |
| more than 64 regions entered | `panic: enter: more than 64 regions are entered (is a leave() missing?)` |
| `leave()` without `enter` | `panic: leave without enter` |
| `region_free` of an entered region | `panic: region_free: this region is entered (leave() first)` |

Dereferencing `nil` faults (SIGSEGV). Signed overflow wraps; `MIN / -1` yields `MIN`.

Bounds checks never let an out-of-range access happen, but in loops that contain no calls the
check may be performed *before* the loop instead of at the failing iteration (the program would
have stopped anyway; only which of several failing accesses is reported can differ).
A check that cannot fail is removed: in `for i in k..n` (constant `k >= 0`) an access `a[i]`
needs none when `n` is the length of `a` itself (`for i in 0..len(s)`, `for i in 0..v.len`).
The length of a `Vec` lives in memory, so this holds only if the loop contains no call and no
store that could reach it (a store of an `i64`/`u64`/8-bit element may); where that matters,
take the slice once (`xs := v[..]`) or use `for x in v`.

`alc build --unchecked` removes index and division checks (out-of-range behaviour is then
undefined); `assert` and `panic` are kept.

## Builtin functions

| Builtin | Meaning |
|---------|---------|
| `print(a, b, ...)` | prints the values separated by spaces, then a newline; works for every type |
| `put(a, b, ...)` | same without separators and newline |
| `fmt(a, b, ...) -> str` | like `put`, but returns the text |
| `len(x)` | length of a slice, array, string or `Vec` |
| `hash(x) -> u64` | hash of any value that supports `==` |
| `clone(x) -> T` | independent deep copy of `x`, allocated from the arena in use (see [Memory](#clonex)) |
| `sizeof[T]() -> i64` | size of `T` in bytes |
| `sqrt(x)`, `fabs(x)` | `f64` square root / absolute value |
| `popcnt(x) ctz(x) clz(x) bswap(x)` | bit counting / byte swap on integers |
| `rotl(x, n)`, `rotr(x, n)` | rotate |
| `mulhi(a, b)` | high half of the double-width product of two integers of the same type (signed for `i8`..`i64`, unsigned for `u8`..`u64`); with `a * b` it gives the whole product. An untyped literal takes the type of the other operand; two literals the expected type, else `i64` |
| `panic(msg: str) -> never` | stop with a message |
| `syscall(nr, a, b, ...) -> i64` | raw Linux system call (up to 6 arguments) |
| `cast[T](x)` | reinterpret: pointer↔pointer, pointer↔`i64`/`u64`, `f64`↔`i64`/`u64` bits, slice↔slice |
| `ptr(s) -> *T` | pointer to the first element of a slice or array |
| `mkslice[T](p, n) -> []T` | slice from a pointer (or address) and a length |
| `memcopy(dst, src, nbytes)`, `memfill(dst, byte, nbytes)` | raw memory copy / fill |
| `embed("file") -> str` | content of a file, read at compile time (see [Constants](#constants)) |

`print` renders: integers in decimal, floats as the shortest text that reads back exactly
(`0.1`, `1e21`, `nan`), booleans as `true`/`false`, `str` as text, other slices and arrays as
`[a, b]`, structs as `Name{field: value}`, tuples as `(a, b)`, enums as `Variant(fields)`,
pointers as hexadecimal addresses.

```
big: u64 = 0xFFFFFFFFFFFFFFFF
print(mulhi(big, big), mulhi(i64(-1), i64(1)), mulhi(u8(200), u8(200)))   // 18446744073709551614 -1 156
```

## Standard library

Output is buffered and flushed at exit (and before a panic).

```
putc(c: u8)                      putf(x: f64, digits: i64)      // fixed notation, like printf("%.Nf")
fmtf(x: f64, digits: i64) -> str flush()                        exit(code: i64) -> never

alloc[T](n: i64) -> []T          new[T]() -> *T                 mark() -> i64    release(m: i64)
region() -> Region               enter(r: *Region)              leave()          reset(r: *Region)
used(r: *Region) -> i64          region_free(r: *Region)

min(a, b)   max(a, b)   abs(x)   swap(&a, &b)   floor(x)   ceil(x)   clock_ns() -> i64
copy(dst: []T, src: []T) -> i64  fill(a: []T, x: T)
sort(a: []T)                                                  // ascending, needs `<`
sort_by(a: []T, less: fn(T, T) -> bool)                       // stable
sort_by(a: []T, ctx: C, less: fn(C, T, T) -> bool)            // `ctx` is handed to every comparison

// strings (str = []u8; slicing gives views without copying)
concat(a, b) -> str     find(s, sub) -> i64     starts_with(s, p)        ends_with(s, p)
trim(s) -> str          split(s, sep: u8) -> []str   lines(s) -> []str   cmp(a, b) -> i64
join(parts: []str, sep) -> str                  to_upper(s) -> str       to_lower(s) -> str
pad_left(s, width, fill: u8) -> str             pad_right(s, width, fill: u8) -> str
hex(x: u64) -> str
parse_i64(s) -> (i64, bool)                     parse_f64(s) -> (f64, bool)

// Opt[T] { Some(T), None }: a value that may be absent;  Res[T] { Ok(T), Err(str) }: a value or an error message
is_some(o) -> bool   is_none(o) -> bool   is_ok(r) -> bool   is_err(r) -> bool
unwrap(o) -> T       unwrap(r) -> T       // the value; else "panic: unwrap of None" / "panic: unwrap of Err: <message>"
or(o, default: T) -> T               or(r, default: T) -> T         error(r) -> str   // the message, "" if Ok

// files and process
read_all(fd: i64) -> str        read_file(path) -> (str, bool)   write_file(path, data) -> bool
io_error() -> i64               error_text(e: i64) -> str        args() -> []str

// Vec[T]: growable array
v := vec[i64]()        v.push(x)        v.pop()        v.len  len(v)
v[i]                   v[a..b]          for x in v     for i, x in v          // the live elements
v.reserve(n)           v.items()  // = v[..]           v.buf[i]               // the raw buffer (capacity)

// Map[K, V]: hash map; keys can be any type that supports ==  (numbers, str, structs, tuples...)
m := map[str, i64]()   m.set(k, v)      m.get(k)  // (V, bool)    m.get_or(k, default)
m.has(k)               m.del(k)         m.len          m.keys()   // []K
```

`alc sigs file.al -- std` prints every library signature.

```
fn main() {
    scores := []i64{70, 95, 80}
    order := []i64{0, 1, 2}
    // the comparison gets `scores` as its first argument
    sort_by(order, scores, fn(scores: []i64, a: i64, b: i64) -> bool { scores[a] > scores[b] })
    print(order)                           // [1, 2, 0]
}
```

```
fn parse_port(s: str) -> Res[i64] {
    n, ok := parse_i64(s)
    if !ok {
        return Err(fmt("not a number: ", s))
    }
    if n < 1 || n > 65535 { Err(fmt("port out of range: ", n)) } else { Ok(n) }
}

fn main() {
    at: Opt[i64] = None                                      // the type gives None its T
    print(at.is_none(), at.or(-1), Some(1.5), Opt[u8].None)  // true -1 Some(1.5) None
    match parse_port("8080") {
        Ok(p) if p < 1024 => print("privileged port", p)
        Ok(p) => print("port", p)                            // port 8080
        Err(msg) => print("error:", msg)
    }
    bad := parse_port("http")
    print(bad.is_err(), bad.error(), bad.or(80))             // true not a number: http 80
    print(parse_port("0").unwrap())                          // panic: unwrap of Err: port out of range: 0
}
```

- `None` (and `Err("..")`) need a type from the context: a declared type, a parameter, the
  result type, or `Opt[T].None`; `x := None` is an error.
- Like every enum with data, `Opt` and `Res` values cannot be compared with `==`; use `match`
  or the helpers.
- A program may declare its own `Opt`, `Res`, `Some`, `None`, `Ok`, `Err` or helpers of these
  names; they are then used in the program. The library's `Opt[T]` and the program's are
  different types, and the library's helpers accept only the library's.

`read_file`, `write_file` and `read_all` record the outcome of every call: after a failure
(`read_file` gives `("", false)`, also for a file that opens but cannot be read, such as a
directory; `write_file` gives `false`; `read_all` returns early) `io_error()` is the Linux
error number, after a success 0. It stays until the next file operation. `error_text(e)` is
the usual text for the common numbers (`no such file or directory`, `permission denied`, ...),
`no error` for 0 and `os error N` otherwise.

```
data, ok := read_file("no/such/file.txt")
if !ok {
    print(len(data), io_error(), error_text(io_error()))     // 0 2 no such file or directory
}
```

This section is the core. The game-oriented library (math, random numbers, time and fixed
timestep, pools and frame memory, assets, images, input, window, audio, Vulkan / DX12 / Metal
bindings) is described in [STDLIB.md](STDLIB.md); how to structure a game on it in
[GAMES.md](GAMES.md). `floor`, `ceil`, `min`, `max`, `abs` above are joined there by the full
set of math functions for `f32`, `f64` and vectors.

## Tooling

```
alc build file.al [-o out]     compile (default output: file name without .al)
alc run file.al [-- args...]   compile and run
alc test file.al               compile and run all `test` blocks (each in its own process);
                               prints ok/FAIL per test, exit status 1 if any failed
alc check file.al              type-check only
alc sigs file.al               one line per declaration: file:line: signature (`priv fn f(a: A) -> R`,
                               `type Name = T`; `-- std` adds the library's public declarations)
options: --unchecked  -O0  --json  --emit-ir  --emit-asm
```

Diagnostics list every error found, sorted by position: `file:line:col: error: message`.
With `--json` they are printed to standard output as
`[{"file":"f.al","line":3,"col":7,"message":"..."}]`.

## Unsafe corners

Everything above is checked. These features are not, and exist for low-level code:

- `cast`, `mkslice`, `ptr`, `memcopy`, `memfill`, `syscall`, and indexing a raw pointer `p[i]`.
- Using memory after `release()`, `reset()` or `region_free()` gave it back (slices, pointers,
  `Vec`s and `Map`s into it), or a slice into a local array after its function returned.
- Copying a `Region` that holds memory or is entered; unbalanced `enter` / `leave` (an early
  `return` between them leaves the region entered).
- `&name` in a pattern points into the payload of the variant that was matched. If the enum
  value is later overwritten with another variant (or the element it lives in is replaced or
  released), the pointer still points at that storage, which now holds something else: do not
  keep it beyond the next assignment to the matched value. A guard that modifies the matched
  place of a `match` that uses `&name` confuses the arms that follow in the same way.
- Patterns through pointers dereference a non-nil pointer; a pointer to released memory is
  not detected. The target is read when each arm is tested, so a guard that overwrites it with
  another variant confuses the arms after it.
- Writing through a slice of an aggregate constant (`TABLE[..]`) or a string inside one: they
  point into read-only memory. Writes that start at the constant's name are compile errors;
  a write through a copy of the slice faults (SIGSEGV), like a write into a string literal.
- Typed memory: the optimizer assumes a location written as one scalar type is not read as a
  different scalar type (except through `u8`), as in C.
- `--unchecked` builds.
- `extern` functions: the declared signature is trusted.

`priv` is a naming rule, not protection: a private global or function can still be reached
through a pointer or function value that a public function hands out, and values of a private
struct type can be returned to, stored by and printed in other files (they just cannot name
the type).

## f32, vectors, matrices

```
x: f32 = 1.5                     // literals adapt; f32 and f64 never mix implicitly
y := f32(n) * x + f32(d)         // conversions: f32(i), f32(f64), f64(f32), i64(f32) (truncates)
a := vec3(1.0, 2.0, 3.0)         // constructors: components, one value for all lanes,
b := vec3(0.5)                   //   or smaller vectors plus components: vec4(a, 1.0)
c := a + b * 2.0 - a / b         // + - * / work lane-wise; a vector combines with an f32
a.y = 4.0                        // components x y z w (or r g b a); a[i] also works
d := a.zyx                       // swizzles (read-only), any 2-4 components: v.xy, v.xyzx
e := vec3(v4)                    // drop trailing lanes
a == b, a != b, -a               // comparisons are all-lanes; < > are not defined
m := mat4(1.0)                   // diagonal matrix; mat4(c0, c1, c2, c3) from columns
m[3] = vec4(1.0, 2.0, 3.0, 1.0)  // m[c] is a column, m[c][r] / m[c].x an element
p := m * vec4(a, 1.0)            // mat4 * vec4, mat4 * mat4
q := quat(0.0, 0.0, 0.0, 1.0)    // quat * quat composes, quat * vec3 rotates
```

- `sqrt`, `fabs`, `fmin`, `fmax` work on `f32`, `f64` and vectors (lane-wise).
- `cast[u32](x)` / `cast[f32](bits)` reinterpret an `f32`; `cast[u64]` / `cast[f64]` an `f64`.
- `print` shows the shortest decimal that reads back to the same value: `0.1`, `vec3(1.0, 2.0, 3.0)`.
  `putf(f64(x), n)` prints with `n` decimals like C's `%.nf`.
- Vectors are single values in SSE registers (`addps`, `mulps`, `shufps`); `vec3` in memory is
  exactly 12 bytes, so `[]vec3` or a struct of vectors can be handed to a GPU API as is.
- The address of a component (`&v.x`) cannot be taken; copy it to a variable.
- The math library (always available, see docs/STDLIB.md): `dot cross length normalize lerp ...`.

## C interop

```
extern "libc.so.6" fn getenv(name: *u8) -> *u8
extern "libm.so.6" fn cosf(x: f32) -> f32

home := from_cstr(getenv(ptr("HOME")))     // string literals are NUL-terminated in memory
p := cstr(path)                            // NUL-terminated copy of any str
```

- Parameters and results must be integers, `bool`, `f32`/`f64`, pointers or function values;
  C structs are passed by pointer (AL structs have C layout). C `int` is `i32`, `long`/`size_t`
  are `i64`/`u64`, `char*` is `*u8`, opaque handles are `*u8`.
- A plain AL function (also a nested or anonymous one)
  can be passed where C expects a callback (`fn(*u8, *u8) -> i32`), as long as its parameters are
  scalars. Code running on a foreign thread must not allocate.
- A program that calls at least one `extern` function becomes a dynamically linked executable
  (the system loader maps the libraries at start-up); every other program stays a static,
  libc-free executable. Only the libraries of functions that are actually reachable are needed.
- `embed("file.bin")` is the content of a file as a `str`, read at compile time (path relative
  to the source file); it is a constant, so it can initialise a `const` or a global.

## Grammar summary

```
file      = { decl }
decl      = ["priv"] ["inline" | "noinline"] "fn" IDENT [tparams] params ["->" type] block
          | ["priv"] "extern" STRING "fn" IDENT params ["->" type]
          | ["priv"] "struct" IDENT [tparams] "{" { IDENT ":" type [","] } "}"
          | ["priv"] "enum" IDENT [tparams] "{" { IDENT ["(" type {"," type} ")"] [","] } "}"
          | ["priv"] "type" IDENT "=" type
          | ["priv"] "const" IDENT [":" type] "=" expr
          | ["priv"] IDENT (":" type ["=" expr] | ":=" expr)
          | "test" STRING block
          | "use" (STRING | IDENT {"." IDENT})
tparams   = "[" IDENT {"," IDENT} "]"
params    = "(" [IDENT ":" type {"," IDENT ":" type}] ")"
type      = IDENT ["[" type {"," type} "]"] | "*" type | "[" "]" type | "[" expr "]" type
          | "fn" "(" [type {"," type}] ")" ["->" type] | "(" type {"," type} ")"
block     = "{" { stmt } "}"
stmt      = IDENT ":" type ["=" expr]
          | IDENT {"," IDENT} (":=" | "=") expr
          | expr [assignop expr]
          | "if" expr block ["else" (ifstmt | block)]
          | [IDENT ":"] ("while" expr block | "loop" block
                        | "for" IDENT ["," IDENT] "in" expr [(".." | "..=") expr] ["by" expr] block)
          | "return" [expr] | "break" [IDENT] | "continue" [IDENT]
          | "assert" expr ["," expr] | "defer" block | block
          | "fn" IDENT params ["->" type] block
expr      = unary { binop unary }
unary     = ("-" | "!" | "~" | "&" | "*") unary | postfix
postfix   = primary { "(" [expr {"," expr}] ")" | "[" expr {"," expr} "]" | "[" [expr] ".." [expr] "]"
                    | "." (IDENT | INT) | "{" [field {"," field}] "}" }
primary   = INT | FLOAT | STRING | CHAR | "true" | "false" | "nil" | IDENT | "(" expr {"," expr} ")"
          | "fn" params ["->" type] block
          | "[" "]" type | "[" expr "]" type | "if" expr block "else" block
          | "match" expr "{" { pattern {"," pattern} ["if" expr] "=>" (block | stmt) } "}"
          | qual "." IDENT ["(" [expr {"," expr}] ")"]
field     = [IDENT ":"] expr
pattern   = "_" | expr | [qual "."] IDENT "(" [pattern {"," pattern}] ")"
          | "(" pattern "," pattern {"," pattern} ")" | "&" IDENT
qual      = IDENT ["[" type {"," type} "]"]
```

In a pattern, `expr` is a constant, `Variant`, `Enum.Variant`, or (inside another pattern) a new
name; `&` IDENT is allowed only inside another pattern.
