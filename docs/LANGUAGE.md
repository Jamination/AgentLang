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
- **Cheap memory management**: bump allocation from an arena with `mark()` / `release()`.

Contents: [Quick tour](#quick-tour) · [Lexical structure](#lexical-structure) · [Types](#types) ·
[Declarations](#declarations) · [Statements](#statements) · [Expressions](#expressions) ·
[Generics](#generics) · [Memory](#memory) · [Run-time errors](#run-time-errors) ·
[Builtins](#builtin-functions) · [Standard library](#standard-library) · [Tooling](#tooling) ·
[Unsafe corners](#unsafe-corners) · [Grammar](#grammar-summary)

## Quick tour

```
struct Point { x f64, y f64 }

enum Shape { Circle(Point, f64), Rect(Point, Point), Empty }

fn area(s Shape) f64 {
    match s {
        Circle(c, r) => 3.141592653589793 * r * r
        Rect(a, b) => (b.x - a.x) * (b.y - a.y)
        Empty => 0.0
    }
}

fn largest[T](items []T, less fn(T, T) bool) T {
    best := items[0]
    for x in items {
        if less(best, x) {
            best = x
        }
    }
    best
}

fn by_area(a Shape, b Shape) bool { area(a) < area(b) }

fn main() {
    shapes := []Shape{Circle(Point{0.0, 0.0}, 1.0), Rect(Point{0.0, 0.0}, Point{2.0, 3.0}), Empty}
    print("largest:", largest(shapes, by_area))        // largest: Rect(Point{x: 0.0, y: 0.0}, Point{x: 2.0, y: 3.0})
    counts := map[str, i64]()
    for w in split("a b a c a", ' ') {
        counts.set(w, counts.get_or(w, 0) + 1)
    }
    print(counts.get_or("a", 0), counts.len)             // 3 3
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
- Keywords: `fn struct enum const var test use if else while loop for in by return break continue
  assert match defer inline noinline true false nil`.
- Integer literals: `42`, `1_000_000`, `0xFF`, `0b1010`, `0o17`, character literals `'a'`, `'\n'`,
  `'\x41'` (a character literal is an integer).
- Float literals: `1.5`, `1e9`, `2.5e-3` (a digit is required on both sides of the point).
- String literals: `"text"` with escapes `\n \t \r \0 \\ \" \' \xHH`. A string is a `str`
  (`[]u8`); literals are read-only.

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
| `fn(A, B) R` | function value (a plain code pointer; there are no closures) |
| `Name`, `Name[T, U]` | struct or enum, possibly generic |

There are no implicit conversions between types. Untyped numeric literals take the type the
context asks for (`var x u8 = 200`, `x * 2`, `f(3)`); without context an integer literal is
`i64` and a float literal is `f64`. An integer literal is accepted where a float is expected,
and a literal next to an `f32` or a vector is an `f32` (`v * 2.0`, `x + 1`).

Structs, tuples, arrays and enums are values: assignment, argument passing and returning copy
them. Slices and pointers are references to shared storage.

Layout follows the usual C rules (natural alignment); `sizeof[T]()` gives the size in bytes.

## Declarations

Top-level declarations can appear in any order.

```
fn name(a i64, b f64) i64 { ... }          // function; omit the result type for "no value"
fn pick[T](a T, b T) T { ... }             // generic function
inline fn tiny(x i64) i64 { x + 1 }        // inlining hint; `noinline fn` forbids inlining
struct Pair[A, B] { first A, second B }    // struct (fields separated by `,` or newlines)
enum Color { Red, Green, Blue }            // enum without data: an integer-like value
enum Opt[T] { Some(T), None }              // enum with data ("tagged union")
const LIMIT = 1000                         // compile-time constant (untyped unless annotated)
const MASK u32 = 0xFF00
var counter i64                            // global variable, zero-initialized
var table = [4]i64{1, 2, 4, 8}             // global with a constant initializer
var ops = [2]fn(i64) i64{double, negate}   //   (function names are constants too)
test "name" { ... }                        // unit test, run by `alc test`
use "other.al"                             // include another file (path relative to this file)
use std.window                             // a module bundled with the compiler (see docs/STDLIB.md)
extern "libc.so.6" fn getpid() i32         // a C function from a shared library (no body)
```

- The program starts at `fn main()`; `fn main() i64` returns the exit status.
- A function whose result type is `never` does not return (`exit`, `panic`).
- Enum variant names live in the global namespace (`Red`, `Some(1)`), so they must be unique.
- A user declaration may reuse a standard-library name (for example your own `push` or `Vec`);
  the library keeps using its own definitions internally.
- **Overloading**: a function name may be defined several times with different parameter types.
  A call picks the definition whose parameter matches the type of the receiver (`x.f()`) or of
  the first argument that is not an untyped literal; with only literals, the definition that
  accepts the literal kind (and, if several do, returns the expected type) is chosen.
  `fn area(c Circle) f32`, `fn area(r Rect) f32`, `fn length(v vec3) f32`, `fn length(v vec2) f32`.

## Statements

```
x := expr                    // declare a new variable (type inferred)
var x T                      // declare, zero-initialized
var x T = expr               // declare with an explicit type
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
for x in items { ... }                     // elements of a slice, array or str (copied into x)
for i, x in items { ... }                  // index and element
break    continue    return    return expr
assert cond                                // stops the program if false
assert cond, "message"
defer { ... }                              // runs when the enclosing block is left
match value { ... }                        // see below
{ ... }                                    // nested block (new scope)
```

- Variables are mutable. Declaring a name that already exists **in the same scope** is an
  error; inner scopes may shadow outer names. `_` discards a value (`_, ok := m.get(k)`).
- The last expression of a function body is its result (`fn sq(x i64) i64 { x * x }`).
  The same holds for the branches of `if`/`match` used as expressions.
- `defer` blocks run in reverse order when their scope ends, also on `break`, `continue` and
  `return` (the returned value is computed first).
- In `for i in a..b`, the bounds are evaluated once. The loop variable is an ordinary variable.

### match

```
match n {
    0 => print("zero")
    1, 2, 3 => print("small")           // several constants
    _ => print("many")                   // default
}

label := match shape {                   // match is an expression when every arm yields a value
    Circle(c, r) => "circle"             // binds the variant's fields
    Rect(a, b) => { helper(); "rect" }   // a block: its last expression is the value
    Empty => "empty"
}
```

Scrutinees can be integers, `bool`, `str` and enums. A `match` used as a value must be
exhaustive (all variants, or a `_` arm).

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
- `p.field` dereferences pointers automatically; `a[i]` works on slices, arrays and pointers
  to them. `s.len` and `len(s)` give the length of a slice, array or string.
- `a[i..j]` is the sub-slice `i <= index < j` (bounds may be omitted: `a[..n]`, `a[i..]`, `a[..]`);
  it shares storage with `a`.
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
Circle(center, 2.0)      Empty                   // enum values
```

A type literal directly before `{` is not allowed in the condition of `if`/`while`/`for`/`match`
(wrap it in parentheses).

Method-call syntax: `x.f(a, b)` means `f(x, a, b)` for any function `f` (unless `x` has a
function-valued field `f`). If `f` expects a pointer and `x` is a variable, `&x` is passed
automatically, and a pointer is dereferenced automatically when `f` expects a value.

## Generics

Functions, structs and enums can take type parameters in square brackets. Generic code is
compiled separately for each combination of types it is used with, and is type-checked per use
(like templates), so any operation that happens to be valid for the concrete type may be used.

```
fn sum[T](xs []T) T {
    var total T
    for x in xs { total += x }
    total
}
sum([]f64{1.5, 2.5})          // T inferred from the arguments
alloc[u32](16)                // explicit type arguments
var o Opt[i64] = None         // inferred from the expected type
```

## Memory

All dynamic memory comes from one arena and is zero-initialized:

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
`mark()`/`release()`.

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

Dereferencing `nil` faults (SIGSEGV). Signed overflow wraps; `MIN / -1` yields `MIN`.

Bounds checks never let an out-of-range access happen, but in loops that contain no calls the
check may be performed *before* the loop instead of at the failing iteration (the program would
have stopped anyway; only which of several failing accesses is reported can differ).

`alc build --unchecked` removes index and division checks (out-of-range behaviour is then
undefined); `assert` and `panic` are kept.

## Builtin functions

| Builtin | Meaning |
|---------|---------|
| `print(a, b, ...)` | prints the values separated by spaces, then a newline; works for every type |
| `put(a, b, ...)` | same without separators and newline |
| `fmt(a, b, ...) str` | like `put`, but returns the text |
| `len(x)` | length of a slice, array or string |
| `hash(x) u64` | hash of any value that supports `==` |
| `sizeof[T]() i64` | size of `T` in bytes |
| `sqrt(x)`, `fabs(x)` | `f64` square root / absolute value |
| `popcnt(x) ctz(x) clz(x) bswap(x)` | bit counting / byte swap on integers |
| `rotl(x, n)`, `rotr(x, n)` | rotate |
| `panic(msg str) never` | stop with a message |
| `syscall(nr, a, b, ...) i64` | raw Linux system call (up to 6 arguments) |
| `cast[T](x)` | reinterpret: pointer↔pointer, pointer↔`i64`/`u64`, `f64`↔`i64`/`u64` bits, slice↔slice |
| `ptr(s) *T` | pointer to the first element of a slice or array |
| `mkslice[T](p, n) []T` | slice from a pointer (or address) and a length |
| `memcopy(dst, src, nbytes)`, `memfill(dst, byte, nbytes)` | raw memory copy / fill |

`print` renders: integers in decimal, floats as the shortest text that reads back exactly
(`0.1`, `1e21`, `nan`), booleans as `true`/`false`, `str` as text, other slices and arrays as
`[a, b]`, structs as `Name{field: value}`, tuples as `(a, b)`, enums as `Variant(fields)`,
pointers as hexadecimal addresses.

## Standard library

Output is buffered and flushed at exit (and before a panic).

```
putc(c u8)                     putf(x f64, digits i64)        // fixed notation, like printf("%.Nf")
fmtf(x f64, digits i64) str    flush()                        exit(code i64) never

alloc[T](n i64) []T            new[T]() *T                    mark() i64       release(m i64)

min(a, b)   max(a, b)   abs(x)   swap(&a, &b)   floor(x)   ceil(x)   clock_ns() i64
copy(dst []T, src []T) i64     fill(a []T, x T)
sort(a []T)                                                   // ascending, needs `<`
sort_by(a []T, less fn(T, T) bool)                            // stable

// strings (str = []u8; slicing gives views without copying)
concat(a, b) str        find(s, sub) i64        starts_with(s, p)        ends_with(s, p)
trim(s) str             split(s, sep u8) []str  lines(s) []str           cmp(a, b) i64
join(parts []str, sep) str                      to_upper(s) str          to_lower(s) str
pad_left(s, width, fill u8) str                 pad_right(s, width, fill u8) str
hex(x u64) str
parse_i64(s) (i64, bool)                        parse_f64(s) (f64, bool)

// files and process
read_all(fd i64) str            read_file(path) (str, bool)    write_file(path, data) bool
args() []str

// Vec[T]: growable array
v := vec[i64]()        v.push(x)        v.pop()        v.len        v.items()  // []T view
v.reserve(n)           v.buf[i]                                               // direct element access

// Map[K, V]: hash map; keys can be any type that supports ==  (numbers, str, structs, tuples...)
m := map[str, i64]()   m.set(k, v)      m.get(k)  // (V, bool)    m.get_or(k, default)
m.has(k)               m.del(k)         m.len          m.keys()   // []K
```

`alc sigs file.al -- std` prints every library signature.

## Tooling

```
alc build file.al [-o out]     compile (default output: file name without .al)
alc run file.al [-- args...]   compile and run
alc test file.al               compile and run all `test` blocks (each in its own process);
                               prints ok/FAIL per test, exit status 1 if any failed
alc check file.al              type-check only
alc sigs file.al               one line per declaration: file:line: signature
options: --unchecked  -O0  --json  --emit-ir  --emit-asm
```

Diagnostics list every error found, sorted by position: `file:line:col: error: message`.
With `--json` they are printed to standard output as
`[{"file":"f.al","line":3,"col":7,"message":"..."}]`.

## Unsafe corners

Everything above is checked. These features are not, and exist for low-level code:

- `cast`, `mkslice`, `ptr`, `memcopy`, `memfill`, `syscall`, and indexing a raw pointer `p[i]`.
- Using memory after `release()` gave it back, or a slice into a local array after its function
  returned.
- Typed memory: the optimizer assumes a location written as one scalar type is not read as a
  different scalar type (except through `u8`), as in C.
- `--unchecked` builds.
- `extern` functions: the declared signature is trusted.

## f32, vectors, matrices

```
var x f32 = 1.5                  // literals adapt; f32 and f64 never mix implicitly
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
extern "libc.so.6" fn getenv(name *u8) *u8
extern "libm.so.6" fn cosf(x f32) f32

home := from_cstr(getenv(ptr("HOME")))     // string literals are NUL-terminated in memory
p := cstr(path)                            // NUL-terminated copy of any str
```

- Parameters and results must be integers, `bool`, `f32`/`f64`, pointers or function values;
  C structs are passed by pointer (AL structs have C layout). C `int` is `i32`, `long`/`size_t`
  are `i64`/`u64`, `char*` is `*u8`, opaque handles are `*u8`.
- A plain AL function can be passed where C expects a callback (`fn(*u8, *u8) i32`), as long as
  its parameters are scalars. Code running on a foreign thread must not allocate.
- A program that calls at least one `extern` function becomes a dynamically linked executable
  (the system loader maps the libraries at start-up); every other program stays a static,
  libc-free executable. Only the libraries of functions that are actually reachable are needed.
- `embed("file.bin")` is the content of a file as a `str`, read at compile time (path relative
  to the source file).

## Grammar summary

```
file      = { decl }
decl      = ["inline" | "noinline"] "fn" IDENT [tparams] "(" [param {"," param}] ")" [type] block
          | "struct" IDENT [tparams] "{" { IDENT type [","] } "}"
          | "enum" IDENT [tparams] "{" { IDENT ["(" type {"," type} ")"] [","] } "}"
          | "const" IDENT [type] "=" expr
          | "var" IDENT (type ["=" expr] | "=" expr)
          | "test" STRING block
          | "use" STRING
tparams   = "[" IDENT {"," IDENT} "]"
param     = IDENT type
type      = IDENT ["[" type {"," type} "]"] | "*" type | "[" "]" type | "[" expr "]" type
          | "fn" "(" [type {"," type}] ")" [type] | "(" type {"," type} ")"
block     = "{" { stmt } "}"
stmt      = "var" IDENT (type ["=" expr] | "=" expr)
          | IDENT {"," IDENT} (":=" | "=") expr
          | expr [assignop expr]
          | "if" expr block ["else" (ifstmt | block)]
          | "while" expr block | "loop" block
          | "for" IDENT ["," IDENT] "in" expr [(".." | "..=") expr] ["by" expr] block
          | "return" [expr] | "break" | "continue"
          | "assert" expr ["," expr] | "defer" block | block
expr      = unary { binop unary }
unary     = ("-" | "!" | "~" | "&" | "*") unary | postfix
postfix   = primary { "(" [expr {"," expr}] ")" | "[" expr {"," expr} "]" | "[" [expr] ".." [expr] "]"
                    | "." (IDENT | INT) | "{" [field {"," field}] "}" }
primary   = INT | FLOAT | STRING | CHAR | "true" | "false" | "nil" | IDENT | "(" expr {"," expr} ")"
          | "[" "]" type | "[" expr "]" type | "if" expr block "else" block
          | "match" expr "{" { pattern {"," pattern} "=>" (block | stmt) } "}"
field     = [IDENT ":"] expr
pattern   = "_" | IDENT "(" [IDENT {"," IDENT}] ")" | expr
```
