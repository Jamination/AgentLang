# Small language improvements (slice `small`)

Reference text for seven additions. Every program in a block marked `al` was compiled and run
with the compiler of this branch; the expected output is shown in comments.

## Type aliases

```
type Reg = i64
type Callback = fn(*u8, i64) i32
type Grid = [8][8]u8
type Names = Vec[str]
```

`type Name = T` is a top-level declaration that gives the type `T` another name. Like all
top-level declarations it can be used before it is declared.

- An alias is **transparent**: `Name` and `T` are the same type everywhere (assignment,
  overload resolution, generic inference, `==`). Diagnostics show the underlying type
  (`expected i64, found str`, never `expected Reg`).
- The name can be used wherever a type name can: declarations, `var x Name`, conversions
  `Name(x)`, literals `Name{...}`, type arguments `vec[Name]()`, `sizeof[Name]()`.
- The target may be any type, also one that is declared later or one that refers back to the
  alias through a struct or enum (`type List = *Node` with `struct Node { next List }`).
- Aliases are not generic (`type Pair[T] = ...` is an error) and take no type arguments.
- `type` is only special at the start of a declaration; it stays usable as an identifier.
- A user alias may reuse a library type name (`type Ring = [4]i64`); the library keeps using
  its own type.
- `alc sigs` lists aliases as `type Name = T`.

Errors:

| Situation | Message |
|-----------|---------|
| `type A = B` with `type B = *A`, `type C = C` | ``type alias `A` refers to itself (a recursive type needs a struct or enum: `struct A { ... }`)`` |
| the name is already declared (function, struct, enum, constant, global, alias) | `` `Reg` is already declared at file:line:col `` |
| the name is an enum variant | ``enum variant `Red` conflicts with another declaration`` |
| unknown target | ``unknown type `Nope` `` |
| `Reg[i64]` | ``type alias `Reg` takes no type arguments (it stands for i64)`` |
| `type Pair[T] = ...` | `a type alias cannot have type parameters: expected `=`` |
| `fn f(x Reg)` next to `fn f(x i64)` | `` `f` is already declared with these parameter types at ... (i64 and Reg are the same types)`` |

```al
type Reg = i64
type Callback = fn(*u8, i64) i32
type Grid = [8][8]u8
type Names = Vec[str]
type List = *Node
struct Node { v Reg, next List }

fn cb(p *u8, n i64) i32 { return i32(n) + 1 }
fn total(l List) Reg {
    s := 0
    p := l
    while p != nil {
        s += p.v
        p = p.next
    }
    s
}

fn main() {
    var r Reg = 5
    var c Callback = cb
    var g Grid
    g[1][2] = 7
    n := Names{}
    n.push("ab")
    l := &Node{v: 1, next: &Node{v: 2, next: nil}}
    var plain i64 = r                  // Reg is i64
    print(plain + 2, c(nil, 4), g[1][2], n.len, total(l), Reg(3.7), sizeof[Grid]())   // 7 5 7 1 3 3 64
}
```

## Labelled loops

```
outer: for i in 0..n {
    for j in 0..m {
        if done(i, j) { break outer }       // leaves both loops
        if skip(i, j) { continue outer }    // next iteration of the outer loop
    }
}
```

- A label is `name:` directly before `for`, `while` or `loop` (it may also stand on the line
  before the loop). `break name` leaves that loop; `continue name` starts its next iteration
  (for a `for` loop: after advancing the loop variable; for a `while` loop: at the condition).
- `defer` blocks of all scopes that are left run, innermost first, exactly as for a plain
  `break` / `continue`.
- Labels have their own namespace: a label may have the name of a variable. A label is in scope
  inside its loop only; the same name may be used again for a later loop, but not for a loop
  nested inside one with that label.
- The label must be on the same line as `break` / `continue`. `break` at the end of a line is a
  plain `break`, and the next line is a new statement.
- `break` and `continue` take nothing but a label (`break 1` is an error).

Errors:

| Situation | Message |
|-----------|---------|
| no enclosing loop has that label | `` `break outr`: there is no loop labelled `outr` around this statement (labels in scope: `inner`, `outer`)`` |
| no labelled loop around at all | `` ...(label a loop with `outr: for ...`, `outr: while ...` or `outr: loop ...`)`` |
| nested loops with the same label | ``loop label `again` is already used by the enclosing loop at line N (give nested loops different labels)`` |
| `name: if ...`, `name: { ... }` | ``a label names a loop: expected `for`, `while` or `loop` after the label`` |

```al
fn find(grid [][]i64, want i64) (i64, i64) {
    r := -1
    c := -1
    rows: for i, row in grid {
        for j, x in row {
            if x == want {
                r = i
                c = j
                break rows
            }
        }
    }
    return (r, c)
}

fn main() {
    g := [][]i64{[]i64{1, 2, 3}, []i64{4, 5, 6}}
    print(find(g, 6), find(g, 9))            // (1, 2) (-1, -1)
    primes := vec[i64]()
    next: for i in 2..30 {
        for d in 2..i {
            if d * d > i { break }
            if i % d == 0 { continue next }
        }
        primes.push(i)
    }
    print(primes.items())                    // [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
    outer: for i in 0..3 {
        defer { print("leave", i) }          // runs on `continue outer` and `break outer` too
        loop {
            if i == 1 { break outer }
            continue outer
        }
    }                                        // leave 0, leave 1
}
```

## Constants that are not scalars

```
const TABLE = [4]i64{1, 2, 4, 8}
const ORIGIN = Point{x: 0, y: 0}
const NAMES = [2]str{"a", "b"}
const UP = vec3(0.0, 1.0, 0.0)
const LOGO = embed("logo.bin")
var shader = embed("blit.frag.spv")
```

A `const` whose value is an aggregate (array, struct, tuple; nested as needed) or a vector /
matrix is stored once in read-only memory. The type is taken from the value unless it is
annotated (`const UNIT Point = Point{1, 1}`).

- The initialiser must be a compile-time constant, by the rules of global initialisers:
  number, `bool` and string constants and constant expressions of them, `T{...}` literals,
  tuples, `vec2/vec3/vec4/quat/mat4(...)` constructors with constant components, names of
  non-generic functions (for elements of function type), `nil`, variants of enums without
  data (as elements or fields), and the names of other constants. Function calls are not
  constant.
- A constant can be read as a whole or in part, indexed (bounds-checked as usual), iterated,
  compared, passed and returned by value, copied into a variable (`t := TABLE` is an
  independent copy), and sliced (`TABLE[1..3]`, `TABLE[..]`).
- It cannot be modified: assigning to the constant or to a field / element of it, compound
  assignment, and `&` on it or on a part of it are compile errors:
  `` `TABLE` is a constant: it cannot be assigned to (copy it to a variable, or declare it
  with `var` to make it a global variable)`` and `` `TABLE` is a constant: its address cannot
  be taken (...)``. The same messages are used for scalar constants.
- As the receiver of a method call whose function takes a pointer (`TABLE.f()` with
  `fn f(t *[4]i64)`), a constant is copied to a temporary; the function works on the copy.
- `embed("file")` is a compile-time string constant: it is allowed in `const` and in global
  initialisers (also inside aggregates), with or without a type annotation. The path is
  relative to the source file that contains the call; the file is read once per path.
- Globals may be initialised from constants (`var table = TABLE`); they are ordinary
  variables afterwards.

Errors: ``value of constant `X` is not a compile-time constant of type T (allowed: ...)``,
``constant `X` is declared as [3]i64, but its value has type [4]i64``,
``cannot infer the type of constant `X`: ...``, ``constant `X` depends on itself``,
``cannot embed `path`: No such file or directory (os error 2)``.

Unsafe corners: a slice of an array constant (`TABLE[..]`) and the strings inside a constant
point into read-only memory. The compiler rejects writes whose target is written starting at
the constant's name (`NAMES[0][0] = 'x'`), but a write through such a slice after it was
copied to a variable or passed to a function faults at run time (SIGSEGV), like a write into
a string literal.

```al
struct Point { x i64, y i64 }
struct Unit { name str, at Point, f fn(i64) i64 }
enum Op { Add, Sub }

const N = 3
const TABLE = [4]i64{1, 2, 4, 8}
const ORIGIN = Point{x: 0, y: 0}
const NAMES = [2]str{"a", "bb"}
const GRID = [2][3]u8{[3]u8{1, 2, 3}, [3]u8{4, 5, 6}}
const UNITS = [2]Unit{Unit{"one", ORIGIN, double}, Unit{name: "two", at: Point{N, N * 2}, f: double}}
const PAIR = (N, "three")
const OPS = [2]Op{Sub, Add}
const UP = vec3(0.0, 1.0, 0.0)
var table = TABLE

fn double(x i64) i64 { x * 2 }
fn sum(xs []i64) i64 {
    t := 0
    for x in xs { t += x }
    t
}

fn main() {
    print(TABLE[2], len(TABLE), ORIGIN, NAMES[1], GRID[1][2], UNITS[1].at.y, UNITS[0].f(21), PAIR.1, OPS, UP.y)
    // 4 4 Point{x: 0, y: 0} bb 6 6 42 three [Sub, Add] 1.0
    print(sum(TABLE[..]), sum(TABLE[1..3]))       // 15 6
    t := TABLE                                    // a copy
    t[0] = 100
    table[0] = 9
    print(t, table, TABLE)                        // [100, 2, 4, 8] [9, 2, 4, 8] [1, 2, 4, 8]
}
```

## `mulhi`

| Builtin | Meaning |
|---------|---------|
| `mulhi(a, b)` | the high half of the full (double-width) product of two integers of the same type |

For a type of `w` bits the result is bits `w .. 2w-1` of the exact `2w`-bit product: signed
(`floor(a * b / 2^w)`) for `i8 .. i64`, unsigned for `u8 .. u64`. Together with `a * b` (the low
half) it gives the whole product. An untyped literal operand takes the type of the other
operand; two literals take the type the context expects, else `i64`. Operands of different
types are an error (``mulhi needs two integers of the same type, found i64 and u32``).
Constant operands are folded. On 64-bit operands it is one `mul` / `imul` instruction.

```al
fn main() {
    var big u64 = 0xFFFFFFFFFFFFFFFF
    print(mulhi(big, big), mulhi(i64(-1), i64(1)), mulhi(u8(200), u8(200)), mulhi(i32(-2147483648), i32(2)))
    // 18446744073709551614 -1 156 -1
    n := u64(1234567890123456789)
    print(mulhi(n, 0xCCCCCCCCCCCCCCCD) >> 3, n / 10)     // 123456789012345678 123456789012345678
}
```

## I/O error information

```
io_error() i64              // OS error number of the most recent failed file operation; 0 after a success
error_text(e i64) str       // "no such file or directory", "permission denied", ..., else "os error N"
```

`read_file`, `write_file` and `read_all` record the outcome of every call: after one of them
returned `false` (for `read_all`: returned early), `io_error()` is the Linux error number
(`errno`); after a success it is 0. The value stays until the next file operation, so read
it right after the failing call. The functions of `std.asset` that open, read, write, create
or delete (`read_bytes`, `write_bytes`, `remove_file`, `remove_dir`, `make_dir`, `list_dir`,
and the loader built on them) record it in the same way.

`error_text` knows: 1 operation not permitted, 2 no such file or directory, 4 interrupted
system call, 5 input/output error, 6 no such device or address, 9 bad file descriptor,
11 resource temporarily unavailable, 12 out of memory, 13 permission denied, 16 device or
resource busy, 17 file exists, 18 cross-device link, 19 no such device, 20 not a directory,
21 is a directory, 22 invalid argument, 23 too many open files in system, 24 too many open
files, 26 text file busy, 27 file too large, 28 no space left on device, 29 illegal seek,
30 read-only file system, 31 too many links, 32 broken pipe, 36 file name too long,
39 directory not empty, 40 too many levels of symbolic links, 122 disk quota exceeded;
0 is `no error`; anything else is `os error N`.

Changed behaviour: `read_file` (and `read_bytes`) now return `("", false)` when the file can
be opened but not read (reading a directory: error 21); before, they returned an empty
string and `true`. A path longer than 4095 bytes fails with error 36 in `std.asset`.

```al
fn main() {
    data, ok := read_file("no/such/file.txt")
    if !ok {
        print(len(data), io_error(), error_text(io_error()))     // 0 2 no such file or directory
    }
    if !write_file("no/such/dir/out.txt", "x") {
        print("cannot write:", error_text(io_error()))          // cannot write: no such file or directory
    }
    print(error_text(13), error_text(999))                       // permission denied os error 999
}
```

## Receivers are referenced automatically

`x.f(args)` means `f(x, args)`. If the first parameter of `f` is a pointer `*T` and `x` has
type `T`, the call passes the address of `x`:

- for every **addressable** `x`: a local variable, a parameter, a global, a field
  (`s.count`, also through a pointer: `self.mf`), an element (`a[i]`, `v.buf[i]`), a tuple
  element (`t.0`), a dereference (`*p`) — whatever the type of `x` is: integers, floats,
  `bool`, vectors, enums with and without data, pointers (`p.f()` with `fn f(pp **T)`),
  structs, arrays, slices. What `f` writes through the pointer reaches `x` itself.
- for a `x` that is **not addressable** (the result of a call or an operator, a literal, a
  constant or a part of one, an enum variant name) the call passes the address of a temporary
  copy; writes through the pointer are lost.
- a component of a vector (`v.x`, `v[1]` with a constant index) has no address:
  ``cannot pass a vector component by pointer to `f` (copy it to a variable first)``.

The other direction is unchanged: if `f` expects a `T` and `x` is a `*T`, the pointer is
dereferenced. Both adjustments apply to the receiver only, never to other arguments
(`f(x)` with `fn f(p *i64)` is an error that suggests `&x`), and they work the same for
overloaded functions (a definition is a candidate if it accepts `T`, `*T` or the pointee of
the receiver) and for generic functions (`fn set_to[T](p *T, x T)`: `x.set_to(3)`; a generic
parameter `T` alone takes the receiver by value).

Order of evaluation: the address of the receiver is taken before the arguments are evaluated;
the callee reads through it afterwards. A receiver of scalar type that is passed by value is
read before the arguments are evaluated.

```al
enum Op { Add, Sub, Jmp }
struct MFunc { n i64 }
struct Sel { mf MFunc, count i64, ops [2]Op }

fn is_pure(self *Op) bool { *self != Jmp }
fn next(self *Op) { *self = if *self == Add { Sub } else { Jmp } }
fn incr(p *i64) { *p += 1 }
fn new_vreg(f *MFunc, c u8) i64 {
    f.n += 1
    return f.n
}
fn set_to[T](p *T, x T) { *p = x }
fn go(self *Sel) i64 {
    self.count.incr()             // a field through a pointer
    self.ops[1].next()            // an element
    return self.mf.new_vreg(0)    // a struct field through a pointer
}
fn make() i64 { 41 }

fn main() {
    op := Add
    op.next()                     // &op
    x := 5
    x.incr()
    x.set_to(x + 10)
    s := Sel{}
    print(op, op.is_pure(), x, s.go(), s.go(), s.count, s.ops)    // Sub true 16 1 2 2 [Add, Jmp]
    make().incr()                 // a temporary: nothing to see afterwards
}
```

## `T{...}` literals in the header of `for`, `if`, `while`, `match`

In a header, `{` normally starts the body, so `for x in xs { ... }` iterates over `xs`. A
literal is now recognised without parentheses in these cases:

| Header | A `{` after a type is a literal when ... | Example |
|--------|------------------------------------------|---------|
| any | the type is written with `[`: `[]T{...}`, `[N]T{...}` | `for s in []i64{1, 2, 3} { }` |
| `for`, `if`, `while` | the type is a name (`Name`, `Name[T]`) and the matching `}` is directly followed by `{`, `.`, `[` or a binary operator | `for n in Names{"a", "b"} { }`, `if p == Point{1, 2} { }`, `while Range{0, 3}.hi > j { }` |
| `match` scrutinee | the type is a name and the braces contain something but no `=>` of their own | `match Point{5, 6}.y { ... }` |

Everything else keeps its meaning: `for x in xs { ... }`, `if flag { ... }`,
`match v { ... }.len`. Rationale: a type alone is never a value, so `[]T {` can only be a
literal; after the body of `for` / `if` / `while` the statement ends (or `else` follows), so
a `}` followed by `{`, `.`, `[` or an operator cannot be the end of a body; the body of a
`match` always contains `=>`. Parentheses are still accepted everywhere, and still needed where none of the rules applies:
an empty named literal in a `match` scrutinee (`match (Point{}).x { ... }`), or a named
literal in an `if` / `while` / `for` header that is followed by something other than `{`, `.`,
`[` or a binary operator. A block that follows a loop or `if` body on the same line without
`;` (never valid) is now reported as ``expected a type before `{` ``.

```al
struct Point { x i64, y i64 }
struct Box[T] { items []T }
type Names = [2]str

fn main() {
    for s in []i64{1, 2, 3} { put(s, " ") }                         // 1 2 3
    for n in Names{"a", "b"} { put(n, " ") }                        // a b
    for x in Box[i64]{items: []i64{7, 8}}.items { put(x, " ") }     // 7 8
    p := Point{1, 2}
    if p == Point{1, 2} { put("same ") }                            // same
    if Point{3, 4}.y == 4 { put("field ") }                         // field
    print(match Point{5, 6}.y {
        6 => "six"
        _ => "other"
    })                                                               // six
}
```
