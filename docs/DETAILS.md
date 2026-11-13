# AL language details

Read on demand. [LANGUAGE.md](LANGUAGE.md) is the reference an agent reads in full; this file
holds the fine print that only a minority of programs needs: the exact rules of name
resolution (overloading, builtin names, enum variants, `priv`), details of constants, `match`,
method calls and nested functions, bounds checks, region limits, `clone` cost, C interop, and
the grammar.

Contents: [Overloading and builtin names](#overloading-and-builtin-names) ·
[Enum variants](#enum-variants) · [Constants](#constants) · [Float literals](#float-literals) · [priv](#priv) ·
[Labelled loops](#labelled-loops) · [Nested functions](#nested-functions) · [match](#match) ·
[Method calls](#method-calls) · [Bounds checks](#bounds-checks) · [Regions](#regions) ·
[clone](#clone) · [mulhi](#mulhi) · [C interop](#c-interop) · [Grammar](#grammar)

## Overloading and builtin names

- A call looks at the receiver (`x.f()`) and then at the arguments from left to right until one
  definition is left: a typed argument must have the parameter's type, an untyped literal must
  be acceptable to it. If literals leave a tie, the definition whose parameters are the
  literals' default types (`i64`, `f32`) wins, unless another one returns the expected type
  (`floor(2.5)` is the `f32` one, `floor(x)` with an `f64` `x` the `f64` one).
  User definitions are considered before library definitions of the same name.
- A function may have the name of a builtin (`len`, `ptr`, `clone`, `hash`, `print`, `fmt`,
  `sqrt`, ...). A call (also `x.f(a)`) uses the declared functions first, by the overloading
  rules; when none of them accepts the number or types of the arguments, the builtin is used.
  A declared function thus extends a builtin to new argument types, or replaces it for exactly
  the types it declares.
- The arguments are evaluated once, left to right, before the function is chosen (the builtin
  `print` / `put` normally writes each argument as soon as it is evaluated; a call with as many
  arguments as a declared `print` takes evaluates all of them first).
- If exactly one non-generic function of the name is declared, its parameter types are the
  expected types of the arguments as in any call (`f(Some(1))` builds an `Opt[u8]` for
  `fn f(o: Opt[u8])`), and an argument that cannot be built for that type is an error at the
  argument, not a reason to use the builtin. When nothing fits, the builtin's message is shown
  and names the declared candidates.
- Library code is not affected: inside the library `len`, `hash`, ... always mean the builtins.
- A call of an overloaded function looks at a bare variant argument like at a literal: the
  definitions whose parameter is an enum with that variant remain; if the expected result type
  does not decide between them, write `f(Color.Red)`.

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

## Enum variants

- The qualified form `Enum.Variant`, `Enum.Variant(args)`, `Enum[T].Variant(args)` is allowed
  wherever a variant can be written, in expressions and patterns. For a generic enum without
  written type arguments they come from the expected type, else from the payload. `Enum` must
  not be a local variable (`e.b` stays a field access).
- A variant cannot have the name of a function, constant, global or enum of the program (the
  error names that declaration and its position), and an enum cannot declare a variant twice.
  It may have the name of a struct: a struct name is only ever a type (`x: Expr`,
  `Expr{...}`, `sizeof[Expr]()`), a variant never is, so `Expr` / `Expr(e)` in an expression
  or pattern is the variant.
- `==` / `!=` on an enum with data compare the variant and then its payload values with the
  rules of struct fields (pointers by address, slices by content). A comparison with a
  variant without data (`t == Nl`, `Tk.Nl != t`) only looks at which variant it is. Such
  enums can be `Map` keys and arguments of `hash`.
- A value-`match` arm, whose value is a variant that needs its type from the context (a name
  that several enums have, a variant of a generic enum such as `None`), is typed after the
  other arms: `m := match o { Shl => Shl; AShr => Sar; _ => Ror }` is a `MOp` if only `MOp`
  has `Sar`. If no arm has a type of its own, each such arm is reported.
- A variant of the program may have the name of a library declaration; in the program the name
  then means the variant (`enum Cmd { push, pop }`: `push` is `Cmd.push`; `v.push(1)` still
  calls the library function). Conversely a function, constant, global or type of the program
  hides a *library* variant of that name (`Opt.Some(x)` still reaches it).
- In a call, the name of a builtin function or type stays the builtin (`len(x)`, `i64(x)`)
  even if an enum has such a variant (construct it as `Enum.len(..)`); without parentheses the
  name is the variant.
- Library code resolves bare variants among its own enums first.
- A program may declare its own `Opt`, `Some`, `None` or helpers of the library's names; they
  are then used in the program. The library's `Opt[T]` and the program's are different types,
  and the library's helpers accept only the library's.
- `print` shows a variant by its bare name. A payload is evaluated exactly once.

## Constants

- Allowed in an initialiser: number, `bool` and string constants and constant expressions of
  them; `T{...}` literals and tuples (nested as needed); `vec2/vec3/vec4/quat/mat4(...)` with
  constant components; names of non-generic functions (for elements of function type, or the
  whole value: `const F = double`, called as `F(x)`; an overloaded name needs the annotated
  type `const F: fn(i64) -> i64 = inc`); `nil`; variants of enums without data (as elements or
  fields of a typed literal); `embed("file")`; names of other constants. A constant cannot
  depend on itself. The address of an `extern` function is not a constant.
- An annotated type must match the value (`const UNIT: Point = Point{1, 1}`).
- An aggregate (array, struct, tuple) or vector / matrix constant is stored once in read-only
  memory. Assigning to it or to a part of it, and `&` on it or on a part of it are compile
  errors. As the receiver of a method call that takes a pointer, a constant is copied to a
  temporary.
- Writing through a slice of an aggregate constant (`TABLE[..]`) or a string inside one is not
  caught at compile time: the write stops the program with a memory fault, like a write into a
  string literal.
- `embed("file")`: the path is relative to the source file that contains the call; the file is
  read once per path.

```
struct Point { x: i64, y: i64 }
struct Unit { name: str, at: Point, f: fn(i64) -> i64 }
enum Op { Add, Sub }

const N = 3
const TABLE = [4]i64{1, 2, 4, 8}
const UNITS = [2]Unit{Unit{"one", Point{0, 0}, double}, Unit{name: "two", at: Point{N, N * 2}, f: double}}
const OPS = ([2]Op{Sub, Add}, "ops", vec3(0.0, 1.0, 0.0))
table := TABLE                             // a global initialised from a constant

fn double(x: i64) -> i64 { x * 2 }

fn main() {
    print(TABLE[2], UNITS[1].at.y, UNITS[0].f(21), OPS)   // 4 6 42 ([Sub, Add], ops, vec3(0.0, 1.0, 0.0))
    t := TABLE                             // an independent copy
    t[0] = 100
    table[0] = 9
    print(t, table, TABLE[1..3])           // [100, 2, 4, 8] [9, 2, 4, 8] [2, 4]
}
```

## Float literals

An untyped float (a literal, a constant declared without a type whose value has none, or a
constant expression of them) takes the float type its context expects; without one it is an
`f32`. Integer literals keep `i64` as their default.

- **Expected types** are those of untyped integers: a declared variable, an assignment, an
  argument, a returned value, a field, an element, a payload, a conversion `f64(..)`. An
  untyped operand takes the type of the other operand (`y * 0.1`), an untyped `if` branch or
  `match` arm the type of the other branches (`if c { 0.0 } else { y }`), also when the untyped
  side is an `if` of untyped values or the builtin `sqrt` / `fabs` / `fmin` / `fmax` of untyped
  arguments (`sqrt(2.0) * y`). In a generic call a literal binds `T` to `f32` (`max(1.5, 2.5)`);
  with overloads it prefers the `f32` definition.
- **Rounding.** A literal is rounded once from its text to the type it gets: `f64(0.1)` is the
  f64 nearest to 0.1, `x := 0.1` the f32 nearest to it (not the f64 rounded again). A constant
  expression (`1.0 / 3.0` in a `const`) is computed in f64 and then rounded to f32 where an f32
  is needed; written in an expression with no `f64` in it, the same operation is done in f32.
- **Typed constants.** A constant whose value has a type is typed even without an annotation:
  `const DT = f64(1) / 60.0` is an `f64` (an operation with a typed operand has its type), so
  `x := DT` is an `f64`. `const PI = 3.141592653589793` stays untyped: `f32` alone, `f64` next
  to an `f64`.
- **To an integer.** Converting an untyped float to an integer uses its exact value, as a
  constant does: `i64(16777217.0)` is 16777217 (the f32 nearest to it would be 16777216).

```
const H = 1.00000005960464477539062500000001

fn main() {
    y: f64 = 2.0
    a := 0.1                                 // f32
    b := if y > 1.0 { 0.5 } else { y }       // f64: the other branch
    print(a, f64(a), y * 0.1, b, sqrt(2.0) * y, H, f64(H), i64(16777217.0))
    // 0.1 0.10000000149011612 0.2 0.5 2.8284271247461903 1.0000001 1.0000000596046448 16777217
}
```

## priv

`priv` in front of `fn` (also `inline` / `noinline` / `extern` functions), `struct`, `enum`,
`const` or a global variable takes the declaration out of the program-wide namespace: it is
visible only inside the file that contains it.

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
  private declaration wins. A private struct, enum, constant or global hides every public
  declaration of that name, of whatever kind.
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
  tried first in its file, and the builtin is used when it does not accept the arguments.
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
  private declarations under their written names. `alc sigs` marks them `priv` and
  `alc sigs file.al -- std` omits the library's.
- `priv` is a naming rule, not protection: a private global or function can still be reached
  through a pointer or function value that a public function hands out, and values of a private
  struct type can be returned to, stored by and printed in other files (they just cannot name
  the type).

## Labelled loops

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

## Nested functions

- **Forms.** `fn name(params) -> Result { body }` as a statement; `fn(params) -> Result { body }`
  as an expression. Neither has type parameters of its own or takes `inline` / `noinline` /
  `priv` / `extern`. They may contain further nested functions.
- **Scope of the name.** From the declaration to the end of its block. There it hides
  top-level functions and builtins of that name, also in method-call syntax (`x.name()`). A
  block cannot declare the name twice or use it for a variable as well; nested functions
  are not overloaded and not assignable.
- **Control flow.** `return` returns from the nested function. `break`, `continue` and labels
  cannot reach a loop of the enclosing function, and `defer` blocks belong to the function
  they are written in.
- A nested or anonymous function can be given to C as a callback.
- Diagnostics, `--emit-ir` and the symbol table name them `outer.name` and `outer.fn@line:col`.

## match

- Sub-patterns nest to any depth: `Some(Circle(r))`, `(Some(a), None)`, `Node(Leaf(x), &rest)`.
  Parts of enums and tuples can have any type.
- A name inside a variant or tuple pattern that is a variant of some *other* enum than the
  part's type is a binding; a binding hides an outer variable of that name. Where the part is
  an enum (or a pointer to one), a name that is neither one of its variants nor a constant
  must start with a lower-case letter or `_`; `Some(Crcle)` is an error that lists the variants.
- **Unreachable patterns.** A pattern (also one alternative of an arm) is an error if an
  earlier arm without a guard, or an earlier alternative of the same unguarded arm, has a
  pattern that covers it by shape: one that matches everything (`_`, a binding, a tuple of
  them); the same constant (compared by value: `1` and `2 - 1`, `LIMIT` and `3`); the same
  variant or a tuple whose sub-patterns cover the other's one by one (`Un(_, x)` covers
  `Un(Neg, 1)`; `P("+")` covers `P("+")`). Nothing else is detected: several arms that
  together cover a later one do not make it an error, nor does a variable used as a pattern.
- **`&name`.** If the matched expression is a place (a variable, `x.f`, `a[i]`, `*p`) the
  pointer points into that place; otherwise (a call result, `match (a, b)`) into a temporary of
  the enclosing function, valid until the function returns. If the enum value is later
  overwritten with another variant (or the element it lives in is replaced or released), the
  pointer still points at that storage, which now holds something else.
- **Pointers.** A binding of a pointer-typed part is the pointer itself; `&name` inside a
  pattern that looked through a pointer points into the target. Patterns through pointers
  dereference a non-nil pointer; a pointer to released memory is not detected. `nil` is also
  matched by a binding.
- **Guards.** If a guard is false, the other alternatives of the same arm are not tried. If a
  guard changes the variable being matched, the following arms still see the value as it was
  when the `match` began, except with `&name` and through pointers: there the target is read
  when each arm is tested, so a guard that overwrites it confuses the arms after it.
- **Exhaustiveness.** `_`, a binding, and tuple patterns made of them cover everything; variant
  patterns are combined (`Some(Circle(_))`, `Some(Rect(_, _))`, `Some(Empty)` and `None` cover
  `Opt[Shape]`; `(true, _)` and `(false, _)` cover `(bool, T)`; `true` and `false` cover
  `bool`). Through a pointer `nil` must be covered separately.

## Method calls

- Order of lookup for `x.f(a)`: a field `f` of `x` that holds a function (also a tuple element:
  `t.1(a)`); a nested function `f` in scope; the top-level functions `f` (overloading rules).
- The receiver adjustments (`&x` for a `*T` parameter, dereference for a `T` parameter) hold for
  overloaded and generic functions too: a parameter `p: *T` takes the address, a generic
  parameter `T` alone takes the receiver by value.
- Addressable receivers: a variable, parameter or global, a field, an element, a tuple element,
  a dereference, of any type. A vector component (`v.x`) has no address and is rejected as a
  receiver of a `*f32` parameter.
- The address of the receiver is taken before the arguments are evaluated and the callee reads
  through it afterwards; a scalar receiver passed by value is read before the arguments.
- The builtins with a method form (`len`, `clone`, `hash`, `ptr`, `sqrt`, `fabs`, `fmin`,
  `fmax`, `popcnt`, `ctz`, `clz`, `bswap`, `rotl`, `rotr`) pass their receiver as it is (no
  automatic `&` or `*`). The other builtins have no method form.

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

## Bounds checks

- `v[i]` on a `Vec` is checked against the **length** `v.len`, and `v[a..b]` requires
  `a <= b <= v.len`. `v.buf[i]` addresses the raw buffer including the spare capacity and is
  checked against the capacity only. A user struct named `Vec` is an ordinary struct.
- Bounds checks never let an out-of-range access happen, but in loops that contain no calls the
  check may be performed *before* the loop instead of at the failing iteration (the program
  would have stopped anyway; only which of several failing accesses is reported can differ).
- A check that cannot fail is removed: in `for i in k..n` (constant `k >= 0`) an access `a[i]`
  needs none when `n` is the length of `a` itself (`for i in 0..len(s)`, `for i in 0..v.len`).
  The length of a `Vec` lives in memory, so this holds only if the loop contains no call and no
  store that could reach it (a store of an `i64`/`u64`/8-bit element may); where that matters,
  take the slice once (`xs := v[..]`) or use `for x in v`.
- `alc build --unchecked` removes index and division checks (out-of-range behaviour is then
  undefined); `assert` and `panic` are kept.

## Regions

- **Nesting.** `enter` / `leave` form a stack with the main arena at the bottom; up to 64
  regions can be entered at the same time, and a region cannot be entered twice.
- **Marks.** A mark belongs to the arena it was taken in; releasing it while another arena is
  in use does nothing. (A mark taken before the first allocation of an arena means "everything
  in the arena in use".)
- **`reset(&r)`** may be called whether `r` is in use, entered further down the stack, or not
  entered. The region keeps its memory and hands it out again, zeroed as always.
- **`region_free(&r)`** unmaps the memory; `r` is empty afterwards and can be entered again. The
  region must not be entered.
- **`used(&r)`**: sizes are rounded up to 16 bytes.
- **Sizes.** A region reserves address space on its first allocation and commits memory only
  as it is used: 16 GiB per region (the main arena: 64 GiB). If the system refuses the
  reservation, smaller sizes down to 16 MiB are tried and the region is limited to what it
  got. A region that is never allocated from costs nothing.
- A `Region`'s fields are internal. Never copy a `Region` that has memory or is entered: both
  copies would hand out the same memory.

```
fn main() {
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

Run-time errors of regions and arenas (exit status 1, message on standard error):

| Situation | Message |
|-----------|---------|
| arena exhausted | `panic: out of memory` |
| `enter` of a region that is already entered | `panic: enter: this region is already entered` |
| more than 64 regions entered | `panic: enter: more than 64 regions are entered (is a leave() missing?)` |
| `leave()` without `enter` | `panic: leave without enter` |
| `region_free` of an entered region | `panic: region_free: this region is entered (leave() first)` |

`Arena` and `frame_begin()` / `frame_end()` of the library are compared with regions in
[std/mem.md](std/mem.md).

## clone

- `clone(p)` with a pointer `p` is a compile error (the result would be the same pointer; write
  `clone(*p)`), except inside a generic function, where a type parameter may happen to be a
  pointer type: there the pointer is copied, as a pointer inside a cloned value is.
- Data that refers to itself through slices (`struct Node { kids: []Node }`) is copied
  completely. Data linked through pointers is not followed.
- `Vec[T]`: a `Vec` of the same length with cloned elements (capacity = length). `Map[K, V]`: an
  independent map with cloned keys and values in the same order. A user struct that happens to be named `Vec` or
  `Map` is cloned field by field.
- The clone of a string literal is ordinary writable memory.
- Cost: a type without any slice inside is a plain copy (no allocation); a slice or `Vec` whose
  elements contain no slice is one allocation and one memory copy; otherwise one allocation
  per slice.

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

## mulhi

`mulhi(a, b)` is the high half of the double-width product of two integers of the same type
(signed for `i8`..`i64`, unsigned for `u8`..`u64`); with `a * b` it gives the whole product. An
untyped literal takes the type of the other operand; two literals the expected type, else `i64`.

```
fn main() {
    big: u64 = 0xFFFFFFFFFFFFFFFF
    print(mulhi(big, big), mulhi(i64(-1), i64(1)), mulhi(u8(200), u8(200)))   // 18446744073709551614 -1 156
}
```

## C interop

```
extern "libc.so.6" fn getenv(name: *u8) -> *u8
extern "libm.so.6" fn cosf(x: f32) -> f32
extern "libc.so.6" optind: i32                 // a C variable of the library

fn main() {
    home := from_cstr(getenv(ptr("HOME")))     // string literals are NUL-terminated in memory
    p := cstr("some/path")                     // NUL-terminated copy of any str
    optind = 1                                 // read and written like an AL global
    q: *i32 = &optind
    print(len(home) > 0, p != nil, cosf(0.0), *q)  // true true 1.0 1
}
```

- Parameters and results must be integers, `bool`, `f32`/`f64`, pointers or function values;
  C structs are passed by pointer (AL structs have C layout: natural alignment). C `int` is
  `i32`, `long`/`size_t` are `i64`/`u64`, `char*` is `*u8`, opaque handles are `*u8`.
- C enums are bound as integer constants (`const VK_FORMAT_R8G8B8A8_UNORM: i32 = 37`): an AL enum
  is 1 or 2 bytes, not C's 4. An AL enum in an `extern` signature is passed as a C `int`.
- `cstr(s: str) -> *u8` is a NUL-terminated copy of `s`; `from_cstr(p: *u8) -> str` is the text
  of a C string (not copied; `""` for `nil`). String literals are NUL-terminated already:
  `ptr("literal")` can be passed directly.
- A plain AL function (also a nested or anonymous one) can be passed where C expects a callback
  (`fn(*u8, *u8) -> i32`), as long as its parameters are scalars. Code running on a foreign
  thread must not allocate.
- `extern "lib" name: T` declares a global variable (or constant) `name` of the C library,
  with the C type written as `T` (a C struct as an AL struct of the same layout: `extern
  "libwayland-client.so.0" wl_surface_interface: WlInterface`). It is read, assigned and
  addressed like an AL global; `&name` is its address in the library. The program refers to
  it through an import slot that the loader fills with its address (R_X86_64_GLOB_DAT; the
  variable is not copied into the program), so the library's own code and the program see
  the same variable. It has no initializer, cannot be `priv` and stands at top level. Writing
  a C constant (in read-only memory) stops the program with a memory fault.
- A program that uses at least one `extern` function or variable becomes a dynamically linked
  executable (the system loader maps the libraries at start-up); every other program stays a
  static, libc-free executable. Only the libraries of functions and variables that are
  actually reachable are needed.
- The declared signature of an `extern` function and the type of an `extern` variable are trusted.
- Vectors are single values in SSE registers; `vec3` in memory is exactly 12 bytes, so `[]vec3`
  or a struct of vectors can be handed to a GPU API as is.
- Typed memory: the optimizer assumes a location written as one scalar type is not read as a
  different scalar type (except through `u8`), as in C.

## Grammar

Statements end at a newline or `;`; the arms of a `match` are separated the same way. In the
header of `if` / `while` / `for` / `match` a `{` after a name starts the body (a `Name{...}`
literal there is written in parentheses).

```
file      = { decl }
decl      = ["priv"] ["inline" | "noinline"] "fn" IDENT [tparams] params ["->" type] block
          | ["priv"] "extern" STRING "fn" IDENT params ["->" type]
          | "extern" STRING IDENT ":" type
          | ["priv"] "struct" IDENT [tparams] "{" { IDENT ":" type [","] } "}"
          | ["priv"] "enum" IDENT [tparams] "{" { IDENT ["(" type {"," type} ")"] [","] } "}"
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

In a literal `[_]T{...}` the length is the number of elements written (`_` is allowed as a
length only there). In a pattern, `expr` is a constant, `Variant`, `Enum.Variant`, or (inside another pattern) a new
name; `&` IDENT is allowed only inside another pattern.

`t.0.1` is the field `1` of `t.0` (after `.` a number is a field, never a float literal). Nesting
is limited to 2000 levels (blocks, statements, `else if` chains, parentheses, operators and
links of `a + b`, `x.f(a)[i]` chains, counted through the parentheses around a chain's first
operand, types): deeper programs get an error instead of exhausting the compiler's stack. If
the stack limit cannot be raised to 512 MB, the limit is one level per 256 KB of stack.
