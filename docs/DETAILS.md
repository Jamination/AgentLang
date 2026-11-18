# AL language details

Read on demand. [LANGUAGE.md](LANGUAGE.md) is the reference an agent reads in full; this file
holds the fine print that only a minority of programs needs: the exact rules of name
resolution (overloading, builtin names, enum variants, `priv`), details of constants, `match`,
method calls and nested functions, `when` and `-D`, bounds checks, region limits, `clone` cost,
C interop, programs for Windows, and the grammar.

Contents: [Overloading and builtin names](#overloading-and-builtin-names) ·
[Enum variants](#enum-variants) · [Constants](#constants) · [Float literals](#float-literals) · [priv](#priv) ·
[Labelled loops](#labelled-loops) · [Nested functions](#nested-functions) · [match](#match) ·
[Method calls](#method-calls) · [when and -D](#when-and--d) · [Bounds checks](#bounds-checks) · [Stack traces](#stack-traces) · [Debug information](#debug-information) · [Regions](#regions) ·
[clone](#clone) · [mulhi](#mulhi) · [C interop](#c-interop) · [Windows](#windows) · [Files of a program](#files-of-a-program) · [alc fmt](#alc-fmt) · [Grammar](#grammar)

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
- **Numbers.** `i64(e)` (or any integer type) is the number of `e`'s variant, counted from 0
  in declaration order. For an enum without data the reverse is a conversion written with the
  enum's name: `Color(i)` (also `Mode[T](i)`) takes any integer type and is the variant with
  number `i`; a number that is no variant's stops the program (`panic: not a variant at
  file:line: Color(7): Color has 3 variants, numbered 0 to 2`), or the compilation when `i` is
  a literal or untyped constant. `variant_count[E]()` is the number of variants of any enum.
  Both are constants where their arguments are: `const LAST = Kind(variant_count[Kind]() - 1)`,
  `names: [variant_count[Kind]()]str`. All variants in order:
  `for i in 0..variant_count[Kind]() { k := Kind(i) ... }`; a number read from a file is
  checked first: `if n >= 0 && n < variant_count[Kind]() { kind = Kind(n) }`. A variant's name
  as text is `fmt(k)`.

## Constants

- Allowed in an initialiser: number, `bool` and string constants and constant expressions of
  them; `T{...}` literals and tuples (nested as needed); `vec2/vec3/vec4/quat/mat4(...)` with
  constant components; names of non-generic functions (for elements of function type, or the
  whole value: `const F = double`, called as `F(x)`; an overloaded name needs the annotated
  type `const F: fn(i64) -> i64 = inc`); `nil`; variants of enums without data (as elements or
  fields of a typed literal, or the whole value when no variant of the enum has data:
  `const MODE = Mode.Fast`, `const M: Mode = Fast`); `embed("file")`; names of other
  constants. A constant cannot depend on itself. The address of an `extern` function is not a
  constant.
- The builtins `sizeof[T]()`, `offsetof[T](field)`, `std140_size[T]()`, `std430_size[T]()`
  and `hlsl_cbuffer_size[T]()` are untyped integer constants there (`const UV = offsetof[Vertex](uv)` can stand where a `u32`
  is expected); in a function body they are `i64` values (`u32(offsetof[Vertex](uv))`). The
  argument of `offsetof` names a field and is never evaluated: a field (`uv`), a field of a
  field (`light.dir`), an element of an array field with a constant index (`lights[2]`,
  `lights[N - 1].dir`); it does not follow pointers. A wrong name is a compile error that lists
  the struct's fields. A program's own function of the name with one type parameter and one
  parameter takes the call (in a constant too, where it is then not constant).
- Of the library's functions only `rgba8(r, g, b, a)` and `rgb8(r, g, b)` (std.math) are constant
  with constant bytes, as `u32` values: `const WALL = rgb8(120, 90, 60)`. A byte beyond 0..255, or
  a typed argument that is not a `u8`, is a compile error; a program's own function of the name
  and number of parameters takes the call.
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
- **Cost.** Where the optimiser can see which function a function value is (a named, nested
  or anonymous function passed straight to `retain`, `sort_by` or a generic of the program,
  or kept in a local variable), it calls that function directly and inlines it when it is
  small. A function too big to inline that calls such an argument gets a copy for it (at
  most 8 per function and 64 per program; `--emit-ir` and the symbol table name it
  `name~argument`, stack traces `name`). A function value chosen at run time is called
  indirectly.
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

## when and -D

`when cond { ... } else when cond { ... } else { ... }` chooses at compile time. The first
branch whose condition holds is part of the program; the others are parsed (their syntax
errors are reported) and then dropped: nothing else in them is checked, a file they `use` is
not read, and they leave no code or data in the executable.

- **Where.** At top level a branch holds declarations, also `use`, `test`, `priv` and generic
  ones, which belong to the file as if written outside the `when`. In a function body it holds
  statements, which take the place of the `when` in the enclosing block: like the top-level
  form it opens no scope (`when W { sep := "\\" } else { sep := "/" }` declares `sep` for the
  rest of the block, a `defer` in a branch belongs to that block, and a `when` that is the
  last statement of a function gives its value). `when` is not an expression.
- **Conditions** are made of literals, constants, `==`, `!=`, `&&`, `||`, `!` and parentheses;
  the result is a `bool`. Anything else is an error at the condition: a variable (also a
  local one), a function call, another operator (`<`, `+`: declare a constant for the
  result, `const BIG = LEVEL > 2`), an operand of the wrong type, a name that is not declared.
  A misspelt name is never false. Every condition of a chain is checked, also those after the
  taken branch.
- **Which constants.** The built-in `TARGET_OS` (`enum Os { Linux, Windows }`, declared by the
  OS layer of the run-time library for `--target`) and `TARGET_ARCH` (`enum Arch { X86_64 }`),
  and the constants of the program declared at top level outside every `when`, in any file. A
  name of the condition's file means its private constant first, then a public one of the
  program, then one of the library (the library's own `when`s see only the library's). Such a
  constant may be computed from others with any operator (`const VERBOSE = LEVEL >= 2`) and may
  be a variant (`const MODE = Mode.Fast`; a bare variant in a condition takes its enum from the
  other operand: `MODE == Fast`), but not with a conversion, a call or an aggregate. A constant
  declared inside a `when` is not available to conditions (it is to everything else).
- **Order.** The files the program includes without `when` are loaded first; then the
  conditions of their `when`s are decided, a taken branch may include more files, whose
  `when`s are decided next, until nothing changes. Because conditions only see constants
  declared outside `when`, the order does not change the result: a constant is known before
  any condition can use it or not at all (then: "unknown name"). The one exception is checked:
  a constant of the program that hides a library constant of the same name, declared in a file
  that only a `when` includes, is reported if it would have changed a decision. The bundled
  modules decide theirs as soon as they are read (TARGET_OS is always known by then).
- `alc sigs` lists the declarations of the taken branches only.

**`-D NAME=VALUE`** (`alc build`, `run`, `test`, `check`; also written `-DNAME=VALUE`) gives the
program's constant `NAME` the value instead of the declared one, for `when` and for every other
use. `-D NAME` alone is `-D NAME=true`, for a `bool` constant only.

- `NAME` must be a constant of the program (in any file and branch that is part of it; every
  declaration of that name, also private ones of several files, gets the value). A name that
  is no constant of the program is an error that names it, also a constant of the library:
  `TARGET_OS` and the bundled modules' constants cannot be set.
- The value is read as a literal of the constant's type, the declared one or else the type of
  its value: `true` / `false`; an integer literal (`42`, `-1`, `0xFF`, `1_000`) that fits the
  type (an untyped integer constant: `i64`); a float or integer literal for a float; for `str`
  the text as it is, without quotes or escapes (`-D NAME=hello world` in one shell word); for a
  constant of an enum without data, a variant name (`-D MODE=Slow`). Anything else is an error
  at the declaration. A constant whose type cannot be told from its value needs a declared type.

**`if` on a constant.** An `if` whose condition (or an operand of its `&&`, `||`, `!`) is a
constant expression without local variables (`if DEBUG`, `if TARGET_OS == Windows`,
`if !DEMO && LEVEL == 2`) is decided while it is lowered, at every optimisation level (`-O0`
too). Unlike `when`, both branches are type-checked; the other one is compiled to nothing, so
the functions only it calls and the string literals and constant tables only it uses are not
in the executable. (In general the linker leaves out every read-only data item that no code in
the executable refers to.)

**`alc check --all-targets f.al`** type-checks the program once for every target (Linux,
Windows), each with its own branches of `when`. An error that not every target reports ends in
the targets that do: `(--target windows)`. `tests/run.sh` runs it for the examples, the
bundled modules (`tests/check/std_targets.al`) and the tests that use `when`.

```
const DEMO = false                          // alc build -D DEMO game.al
const LEVELS: i32 = 12

when TARGET_OS == Windows {
    extern "kernel32.dll" fn GetTickCount64() -> u64
    fn uptime_ms() -> i64 { i64(GetTickCount64()) }
} else {
    fn uptime_ms() -> i64 { clock_ns() / 1000000 }
}

fn main() {
    when DEMO {
        last := 3
    } else {
        last := LEVELS
    }
    if DEMO { print("demo: levels 1 to", last) }     // not in the full game's executable
    print(uptime_ms() >= 0, last)                    // true 12
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

## Stack traces

Every panic (failed check, `assert`, `panic`, `unwrap`, a library function called wrongly, a
memory or arithmetic fault, stack overflow) writes the call stack to standard error after its
message, which stays the first line:

```
panic: index out of bounds at main.al:12
  at main.al:12 in load_level
  at main.al:40 in start
  at main.al:55 in main
```

- **Format.** One line per frame, innermost first: two spaces, `at FILE:LINE in NAME`; the file
  as in diagnostics, the line of the call (innermost: of the failing operation). `at ? in NAME`
  where the line is unknown. Names as written: `outer.name` and `outer.fn@line:col` for nested
  and anonymous functions, `name[T]` for generic instances, `priv` names plain, `test "name"`
  for a test block (`alc test` shows the trace of a failing test).
- **Library frames.** Frames of the always-loaded run-time library (files `<prelude>`, its OS
  layer, the core modules `<std/math.al>`, `rand`, `time`, `mem`) before the first frame of the
  program are left out: the first line is the program's call, the line a caller-location
  message names (`pop`, `insert`, ...). So are the library frames after the program's last one
  (start-up, test runner). Library frames between frames of the program (`sort_by` calling a
  comparison) are shown; a run of more than 7 as its first 4 and last 3 around
  `  ... N more frames in the library`. Modules loaded with `use std.name` count as the
  program: `  at <std/image.al>:1095 in image_new` shows where a call failed inside one.
- **C code.** The trace goes on through frames of C libraries (a callback called by `qsort`
  that panics, a fault inside `strlen`), one line each: `  at LIBRARY SYMBOL`, the library's
  file name and the function (Linux: its dynamic symbol; Windows: its export), or
  `  at LIBRARY+0xOFFSET` where the function has no name (an address for `addr2line`). Linux
  unwinds them by the libraries' DWARF call frame information (`.eh_frame`), Windows by their
  unwind data (`RtlVirtualUnwind`); a frame without it ends the trace. C frames after the
  program's last frame (process start-up) are left out.
- **Inlining.** Optimised builds show the same frames as `-O0`: code inlined from a function of
  the program is reported as a frame of that function at its line, with the call it was inlined
  at as the next frame. A library function inlined into the program shows as the line of the
  call.
- **Length.** More than 25 lines (deep recursion, stack overflow): the first 20, `  ... N more`,
  the last 5.
- **Corrupted stacks.** Every step is checked (return address inside a function of the
  program or a C library, frame inside the stack and above the previous one, call frame data
  inside the library); the trace ends at the first step that fails.
- **`ALC_BACKTRACE=0`** in the environment turns the trace off (the message stays). Nothing
  of it runs unless the program panics; its table costs about 1-2 KB in a small program and 5%
  of the compiler's executable.

## Debug information

`alc build -g` (also `run` and `test`) adds debug information, so a program can be stepped in
a debugger and profiled with symbols:

- **Linux**: DWARF 4 in the ELF file (`.debug_info`, `.debug_abbrev`, `.debug_line`,
  `.debug_str`, `.debug_aranges`, `.debug_ranges`, `.debug_loc`, `.debug_frame`), for gdb,
  lldb, perf and the like.
- **Windows**: the same DWARF in the PE file (gdb, lldb) and a PDB next to the executable
  (`game.exe` -> `game.pdb`, found through the executable's debug directory) for Visual Studio,
  WinDbg / cdb and the Windows profilers.

What is described: one compile unit for the program; every function with its address range,
its file and line, its parameters and variables (with their scopes: a variable is visible from
its declaration to the end of its block; the variable of a `for` loop and the bindings of a
`match` arm inside their body), the types of these, the line table (a row per statement and
expression, the line of code inlined from another function being that function's line; a row
with `prologue_end` where the prologue and the parameters' stores end), the global variables
(not the thread-local ones; a C variable, `extern`, in DWARF only, where its import slot
points), the functions inlined into each function (DWARF: `inlined_subroutine`; PDB:
`S_INLINESITE` with its lines, so gdb and cdb / Visual Studio show inlined calls as frames of
their own) and the call frames (`.debug_frame`; the PE file also has its `.pdata`).

- **`-O0 -g`**: every statement has code and its line: a breakpoint on any line stops there,
  `next` / `step` go statement by statement, and every variable lives in a frame slot of its own
  for its whole scope (the compiler keeps named variables in memory at `-O0 -g`, as C compilers
  do at `-O0`; without `-g` it keeps them in registers). The code is otherwise the same.
- **With optimisation** `-g` does not change the code (Linux: the code and data of the
  executable are byte for byte those of the build without `-g`; Windows: the same
  instructions, but `.rdata` gains the debug directory, which may move the sections after it
  and so change displacements). Lines are exact for every instruction (each
  keeps the location of the statement it comes from), but statements are merged, moved and
  removed, so stepping jumps; inlined calls show as frames of their own. Variables that stay
  in memory (their address is taken, or an aggregate that is not split up) are in their frame
  slots. The others are described by location lists (DWARF `.debug_loc`; PDB `S_LOCAL` with
  `S_DEFRANGE_REGISTER` / `S_DEFRANGE_FRAMEPOINTER_REL`): per range of code, the register or
  spill slot that holds the variable's value, or (DWARF) its constant value; elsewhere the
  debugger says "optimized out" / "value unavailable". The ranges are worked out on the final
  machine code (`src/debug.al`): a variable is shown at an instruction only where the value it
  has at that source line is known and a register or slot provably holds that value (the
  latest one: a value from an earlier loop iteration never counts); when in doubt it is not
  shown. Not described: variables whose storage is only promoted to registers after inlining,
  structs split into their fields, the variables of inlined functions, and the lines of code
  that unrolling copied.
- **AL types** as a debugger shows them (the language of the compile unit is C, the closest a
  debugger knows): integers, `f32` / `f64` and `bool` are base types (`u8` an unsigned char, so
  a `*u8` prints as text); `str` and `[]T` are a struct `{ptr, len}` (gdb prints the text of a
  string literal through `ptr`; others have no terminating zero); a tuple a struct `{_0, _1,
  ...}`; `vec2`..`vec4` and `quat` `{x, y, z, w}`, `mat4` `{cols: [4]vec4}`; an enum without
  data an enumeration; an enum with data a struct of the tag and the payload of the variant in
  use (DWARF: a variant part, `{tag = Some, Some = {_0 = 4}}`; PDB: the tag and a union of one
  struct per variant); `Vec`, `Map` and the other library types are the structs they are. A
  parameter passed by reference (a struct on Windows) shows as its value (DWARF: a location
  with a dereference; PDB: a reference type, which cdb's `dv` prints as a pointer and `dx` /
  `??` as the value).
- **Source files** are named as on the command line, relative to the working directory of the
  build (DWARF: the compile unit's directory; PDB: made absolute). The run-time library and the
  bundled modules are inside the compiler: their frames have lines (`<prelude>:62`), but there
  is no file a debugger could show.
- **Frames.** AL code keeps no frame pointer. `.debug_frame` describes every prologue (the
  pushes, then one `sub rsp`; on Windows the probe loop of a frame of a page or more, whose
  CFA is an expression of r11), every epilogue and the entry stub of a Linux executable (the
  outermost frame). The frame base of a function is its CFA (Linux), or rsp plus the frame
  (Windows, where gdb unwinds with `.pdata`, not with DWARF), so variables in the frame are
  right from the end of the prologue to the start of an epilogue. The parameters are right from
  the first instruction: until the prologue has stored them they are described in the
  registers (or stack slots) they arrive in, so a debugger that stops on a function's first
  instruction (cdb's `bp name`, gdb's `break *name`) shows them; gdb's `break name` stops after
  the prologue (the second line row), the PDB's debug start is the same place.
- **Size and time.** Nothing changes without `-g`. The compiler built with `-g`: 4.9 -> 11.3 MB
  (Linux, optimised), 4.3 -> 6.2 MB at `-O0`; for Windows 5.2 -> 10.3 MB plus a 5.9 MB PDB.
  `-g` makes the self-compile about 30 % slower when optimising (the location analysis) and
  about 20 % at `-O0` (the variables in memory, the tables).

**Not described**: thread-local globals; C variables in the PDB; columns (source locations
have none: adding them would change the stack-trace tables of builds without `-g`). The PDB's
file checksums are the MD5 of each source file (not of the files inside the compiler), and its
GUID is a hash of the code and data (the same program gives the same PDB).

The implementation: `src/debug.al` (what lowering and the back end record), `src/dwarf.al`,
`src/pdb.al`. Tests: `tests/run/debug_info.al` reads the DWARF of its own executable (ELF or
PE), `tests/sys/win_pdb.al` its own PDB, both with parsers written in AL.

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

- **The library as a constant.** After `extern` stands the library name or the name of a `str`
  constant: `extern LIBC fn strlen(s: *u8) -> u64`. A `when` chooses the constant per system,
  so one set of declarations serves every system:
  `when TARGET_OS == Windows { priv const LIBC = "msvcrt.dll" } else { priv const LIBC =
  "libc.so.6" }` (std.libc and std.vk do this). Another kind of constant, or a name that is
  no constant, is a compile error.
- Parameters and results must be integers, `bool`, `f32`/`f64`, pointers or function values;
  C structs are passed by pointer (AL structs have C layout: natural alignment). C `int` is
  `i32`, `long`/`size_t` are `i64`/`u64`, `char*` is `*u8`, opaque handles are `*u8`.
- An AL enum without data is exactly a C `int` (4 bytes, the variant number): it may stand for a C
  enum numbered 0, 1, 2, ...; other C enums are bound as integer constants (`VK_FORMAT_...: i32`).
- `cstr(s: str) -> *u8` is a NUL-terminated copy of `s`; `from_cstr(p: *u8) -> str` is the text
  of a C string (not copied; `""` for `nil`). String literals are NUL-terminated already:
  `ptr("literal")` can be passed directly.
- A plain AL function (also a nested or anonymous one) can be passed where C expects a callback
  (`fn(*u8, *u8) -> i32`), as long as its parameters are scalars. It may also be called on a
  thread that the C library created: see [Threads](#threads).
- **Variadic C functions.** The parameter list of an `extern` function may end in `...` after
  at least one named parameter: `extern "libc.so.6" fn printf(format: *u8, ...) -> i32`. The
  named parameters are checked and passed as usual; each further argument is passed with the
  C default argument promotions, as a C compiler passes it:
  - `i8`, `i16`, `u8`, `u16` become `i32`, sign-extended from a signed type and zero-extended
    from an unsigned one (what C's `va_arg(ap, int)` reads); `bool` becomes the `i32` 0 or 1;
  - `f32` becomes `f64` (its exact value: `f32(1.1)` arrives as 1.100000023841858);
  - `i32`, `u32`, `i64`, `u64`, `f64`, pointers, function values (a code pointer, as for a
    callback) and enums without data (a C `int`) are passed as they are;
  - an untyped integer literal or constant is an `i32` if its value fits, else an `i64` (a
    decimal literal above the `i64` range a `u64`): `%ld` wants `i64(42)`, as `long` wants
    `42L` in C; an untyped float literal is an `f64`; `nil` is a `*u8`.

  Structs, tuples, arrays, slices (`str` too: pass `ptr(s)`, which is NUL-terminated for
  literals, or `cstr(s)`), vectors and matrices, enums with data and `()` are errors that name
  the argument and its type. A variadic `extern` function cannot be used as a function value,
  and `...` stands nowhere else: an AL function, nested or anonymous function or function type
  takes a slice (`xs: []T`) instead. Defining a variadic function in AL (one that C calls,
  reading its arguments with `va_list`) is not supported. Linux: `al` holds the number of
  vector registers used, as the System V convention asks of every call of a variadic function.
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
- Raw memory from C (a mapped buffer, a returned array): wrap it once with
  `mem := mkslice[u8](p, nbytes)` and work with slices, which are bounds-checked: a typed view at
  a byte offset is `cast[[]T](mem[a..b])` (its length is `(b - a) / sizeof(T)`; leftover bytes
  are dropped), a pointer at an offset for C is `ptr(mem[a..])`. Alignment is not checked: keep
  views of `T` at offsets that are multiples of `T`'s alignment.
- A plain `extern` binds a library's default symbol version as the loader resolves an
  unversioned reference, which for some versioned C symbols is the OLDEST one (ALSA's pre-1.0
  `snd_pcm_hw_params_get_*`): check the library's documentation when a function has versions.
- Vectors are single values in SSE registers; `vec3` in memory is exactly 12 bytes, so `[]vec3`
  or a struct of vectors can be handed to a GPU API as is.
- Typed memory: the optimizer assumes a location written as one scalar type is not read as a
  different scalar type (except through `u8`), as in C.

**arm64 Linux** (`--target linux-arm64`, experimental): C functions are called by the Arm
procedure call standard (AAPCS64), as GCC and Clang call them there:

- `extern` functions may also take and return structs, tuples, arrays and enums with data by
  value: a struct of one to four `f32` (or of one to four `f64`) members, nothing else, in
  floating-point registers; any other of up to 16 bytes as its bytes in one or two integer
  registers; a larger one as a pointer to a copy the caller makes; results the same way, a
  larger one in memory the caller provides. When the registers run out, the argument goes to
  the stack (it is never split between registers and the stack). A struct with a vector member,
  an empty struct and a vector type cannot cross the C boundary. A C function that takes or
  returns a struct cannot be used as a function value: call it directly.
- Variadic arguments are passed like named ones (no `al`, unlike x86-64).
- Callbacks: any AL function with scalar parameters (integers, floats, pointers, function
  values) and a scalar result can be called by C, on any thread, as on x86-64.
- The program is dynamically linked against `/lib/ld-linux-aarch64.so.1` (glibc's loader; on
  musl a link of that name is needed), its threads are the C library's (`pthread_create`).
- A stack trace ends at the first frame of C code (x86-64 continues through C frames).
- Verified under the project's emulator against C built by clang only; see
  [ARM64_TEST.md](ARM64_TEST.md#5-c-libraries-and-dynamic-linking).

**macOS** (`--target macos`, experimental, arm64, never run): as arm64 Linux above, with
Apple's variant of the convention (stack arguments packed, variadic arguments on the stack).
Libraries are dylibs or frameworks by path: `extern "/usr/lib/libobjc.A.dylib" fn ...`,
`extern "/System/Library/Frameworks/Metal.framework/Metal" fn ...`; the run-time library uses
`/usr/lib/libSystem.B.dylib`. See [MACOS_TEST.md](MACOS_TEST.md).

**Windows** (`--target windows`):

- `alc build --target windows f.al` writes `f.exe` (`f.test.exe` for `alc test`), a Windows x86-64
  console executable (`--gui`: a GUI one, see [Windows](#windows)). On Linux, `alc run` / `alc test` run it under Wine when `ALC_WINE=1` and
  `WINEPREFIX` are set (no display: no window can open); otherwise they only build it.
- Functions and variables are imported from DLLs (`extern "kernel32.dll" fn GetStdHandle(n: u32) ->
  *u8`, `extern "abi.dll" counter: i32`), through the executable's import address table: the
  slot of each holds the address of the function or variable (a variable is not copied). The
  library name is taken as written; a Linux library name (`libc.so.6`) is a build error.
- Every function, AL or C, uses the Microsoft x64 calling convention: the first four
  arguments by position in rcx, rdx, r8, r9 or xmm0-xmm3, the rest on the stack above 32 bytes
  of shadow space. So an AL function is a C callback whatever its parameters are.
- `extern` functions may also take and return structs (and tuples, enums with data) by value,
  as C does there: one of 1, 2, 4 or 8 bytes travels as an integer of that size, any other is
  passed as a pointer to a copy the caller makes and returned through a hidden pointer. Vector
  types (`vec2` ... `quat`) cannot cross the C boundary.
- Calls of variadic C functions (`...`, above) pass a floating-point argument in one of the
  first four slots in both its xmm register and the slot's integer register, as the convention
  asks (`va_arg` reads it from the integer register's home in the shadow space).

## Threads

The API (`thread_spawn`, `thread_join`, `thread_id`, `cpu_count`, `Mutex`, `Cond`) is in
[std/os.md](std/os.md#threads); the atomic builtins are in the language reference.

- **What is shared.** One address space: globals and everything any thread allocated can be
  read and written by every thread. Per thread are the arena in use and the thread's base
  arena, the region stack (`enter` / `leave`, marks), `frame_begin` / `frame_end`, the output
  buffer, `io_error()`, the stack and its signal stack. `args()` and the environment are shared
  (read-only). The default generator of std.rand (`rand_*`) is one shared value: using it from
  several threads at once is a data race; give each thread its own `Rng`.
- **Data races.** Two accesses to the same memory from different threads, at least one a write
  and not both atomic, without an order between them (a `Mutex` held around both, a
  `thread_join`, an atomic store seen by an atomic load, `thread_spawn` before the start of
  the thread) are undefined behaviour, as in C: the optimiser treats plain memory as
  single-threaded code. There is no race detector (nothing like ThreadSanitizer).
- **Memory model.** Every atomic operation is sequentially consistent (C11 `seq_cst`): there is
  one total order of all atomic operations that agrees with the program order of each thread,
  and a load sees the last store before it in that order. An atomic operation is a barrier for
  the optimiser: plain loads and stores are not moved across it, a loop around `atomic_load`
  keeps loading. x86-64: loads `mov`, stores and swaps `xchg`, add / sub `lock xadd`, cas
  `lock cmpxchg`, and / or / xor a `lock cmpxchg` loop, fence `mfence`.
- **Memory of a thread.** A thread allocates from a base arena of its own (16 GiB of address
  space, committed as used). `thread_join(&t)` moves it into `t.region`, an ordinary region of
  the joiner: what the thread allocated stays valid and can be used without a copy until
  `region_free(&t.region)` (or `reset`); `enter(&t.region)` allocates more there. A long-running
  thread bounds its memory with `mark` / `release`, regions or `frame_begin` / `frame_end`. The
  memory of a thread that is never joined stays until the process ends. A region the thread
  still has entered when it ends is left (no longer entered by anyone).
- **Regions** are entered by one thread at a time (`Region` records the thread). Run-time errors:
  `panic: enter: this region is entered by thread N`, the same for `reset` and `region_free`
  (the message names the thread that panicked too: `panic in thread M: ...`).
- **Output.** Each thread buffers its output. While the program has one thread the main thread
  writes its buffer when it is full, at `flush()` and at the end, as always. From the first
  `thread_spawn` on, a thread's complete lines go to a shared buffer under a lock whenever it
  writes a newline (also lines built from several `put` calls): lines of different threads
  never mix, and a line of up to 64 KiB is never split. `flush()` writes the shared buffer and
  the calling thread's partial line; `exit` and the end of `main` write the shared buffer and
  the main thread's output. A thread's partial line (a `put` without a newline) is written
  when it ends, flushes or writes the newline; it is lost if the process ends first. `eprint`,
  `eput` and panic messages take the same lock.
- **Panics** in any thread end the process with status 1 (the C `abort` / Rust panic-abort
  behaviour) after the message and the stack trace of the thread that panicked. The main
  thread's messages are unchanged; another thread's name it: `panic in thread 3: index out of
  bounds at f.al:7`, `panic in thread 3 at f.al:9: msg`, `assertion failed in thread 3 at
  ...`. Memory faults (nil dereference, stack overflow on the thread's guard page) are reported
  the same way. Only the first thread that panics reports; others that panic meanwhile wait
  for the end.
- **The end.** When `main` returns (or `exit` is called) the process ends, threads still
  running included, as in C.
- **Run-time checks** (always on, each a load and a compare): a region entered, reset or freed
  by another thread than the one that entered it; `thread_join` of a thread joined before (also
  through a copy of the `Thread`), of `Thread{}` or of the calling thread; `unlock` or `wait`
  with a mutex the thread does not hold; `lock` of a mutex the thread holds already. Not checked:
  data races, memory of a region used by another thread after its reset, a `Mutex`, `Cond` or
  `Region` copied while in use.
- **Threads that C libraries create** (a callback from a driver or audio thread) run AL code too:
  on first use the thread gets an id (the next number), a base arena (never freed), an output
  buffer (line by line); panics and stack traces work. Output of the main thread that is still
  in its buffer when such a thread first prints may come after that thread's lines (`flush()`
  first if the order matters). Its last partial line is lost unless it calls `flush()`.
- **How threads are made.** Linux: in a dynamically linked program with the C library's
  `pthread_create` (looked up at run time, so the C library's per-thread state is set up and a
  program never depends on it just because it could start threads); if the program's libraries
  lack it, `thread_spawn` fails with `io_error()` 38 (`function not implemented`). A static
  program uses `clone` directly. Windows: `CreateThread`. Each thread has a guard page below its
  stack (8 MiB unless given).

## Windows

`alc build --target windows f.al` writes `f.exe`, a Windows x86-64 console program (PE32+);
with `--gui` a GUI program (below).
The run-time library (`src/prelude_windows.al`) calls only `kernel32.dll`; there is no C
run-time library. The same program prints the same output and ends with the same status on
both systems, except where this section says otherwise.

- **ABI and libraries**: [C interop](#c-interop) above. Frames of a page or more probe the
  stack; the stack is 16 MiB. `syscall` is a build error.
- **Text.** Arguments, environment variables, paths and console text are UTF-16 for Windows
  and UTF-8 for the program: unpaired surrogates in Windows names come out as their 3-byte
  (WTF-8) form and go back unchanged; invalid UTF-8 becomes U+FFFD. Output to a console is
  written with `WriteConsoleW` (so UTF-8 displays), output to a file or pipe byte for byte.
  Console input arrives as UTF-8 with `"\r\n"` as `"\n"`; Ctrl+Z at the start of a line ends it.
- **`args()`** is `GetCommandLineW` split by the rules of the Microsoft C library (quotes,
  backslashes before quotes, `""` inside quotes); `args()[0]` is the program as the command
  line names it. **`env_get`** compares names without regard to case.
- **Paths** may use `\` as well as `/`, a drive (`C:/x`, `C:x`) or `\\server\share\`; the
  path functions of std.asset know these roots and build paths with `/`. Long paths work
  without `LongPathsEnabled`: the run-time library hands Windows a path of 248 UTF-16 units
  or more (once made absolute) in the extended-length form `\\?\C:\dir\file`, made absolute first
  ([std/asset.md](std/asset.md#windows)).
  `current_dir()` is in Windows form (`C:\Users\me`).
- **Errors.** `io_error()` is the Linux errno of the same meaning (file not found 2, access
  denied 13, a directory where a file is expected 21, file exists 17, directory not empty 39,
  disk full 28, broken pipe 32, ...); a Windows error without one is 0x10000 + its code, and
  `error_text` says `windows error N`.
- **Status and panics.** The exit status is the low 8 bits of the code, as on Linux
  (`exit(300)` ends with 44). Panics write the same messages and end with status 1; access
  violations, stack overflow and integer division faults (`--unchecked`) are reported as the
  Linux signal handler reports them: in the program's code by a vectored exception handler;
  in a DLL only if the DLL does not handle the exception itself (unhandled exception filter). Standard
  output that cannot be written (a closed pipe) stops the program with `panic: cannot write
  to standard output: broken pipe` (Linux: the program ends silently through SIGPIPE).
- **`alc test`.** Each `test` block runs in a process of its own, as with `fork` on Linux:
  the test runner starts itself again (`AL_TEST_ONE=k`) for every block.
- **Memory.** Arenas reserve the same address space (64 GiB, 16 GiB per region) and commit it
  in steps as it is used; committed memory counts against the system's commit limit.
- **Not available** for `--target windows` (a compile error that names the module):
  `std.x11`, `std.wayland`, `std.alsa` (a program for both systems includes them with
  `when TARGET_OS == Linux { use std.x11 }`). `std.libc` binds `msvcrt.dll` there
  ([std/libc.md](std/libc.md)), `std.vk` `vulkan-1.dll` ([std/vk.md](std/vk.md)) and
  `std.shaderc` `shaderc_shared.dll`, the DLL of the Vulkan SDK
  ([std/shaderc.md](std/shaderc.md)). In
  std.os, signals do not exist (`kill` with any signal but 0 ends the process; see
  [std/os.md](std/os.md)).
- **`alc run` / `alc test`** of a Windows program on Linux build it and stop, unless
  `ALC_WINE=1` (with `WINEPREFIX`) runs it under Wine.
- **GUI programs (`--gui`).** `alc build --target windows --gui f.al` gives the executable the
  GUI subsystem instead of the console one (the only difference in the file), so a game started
  from Explorer gets no console window. `--gui` for a Linux target (`--target linux`, or no
  `--target` on Linux) is a usage error; on Windows, where `--target windows` is the default,
  `alc build --gui f.al` is enough. `--icon` and `--version-info` follow the same rule.
  At run time such a program (it reads the subsystem from its own image header):
  - started from a console (cmd, PowerShell, a terminal) attaches to it
    (`AttachConsole(ATTACH_PARENT_PROCESS)`), so `print` and panics show there; the shell does
    not wait for it. Standard handles redirected to a file or pipe (`game.exe > log.txt`) are
    kept; standard input is never taken from the console (empty unless redirected);
  - a standard handle that does not exist (started from Explorer) reads as empty and swallows
    output without an error;
  - a panic writes its message to standard error as always and, if standard error is a console
    or nothing, also shows it in a message box (`MessageBoxW` of user32.dll, loaded only then)
    titled with the executable's name, so a game that stops says why; with standard error
    redirected to a file or pipe there is no box.
- **The image.** The executable is relocatable: Windows loads it at a random address (ASLR
  with high entropy; the preferred base is 0x140000000), so it also starts where "Mandatory
  ASLR" is enforced. The address of a global or a function differs from run to run and does
  not fit in 32 bits: keep it in a pointer or an `i64`.
- **Manifest.** Every executable carries an application manifest (resource 1 of type 24):
  `asInvoker` (no elevation prompt, whatever the file is called), Windows 10/11 as supported
  systems, long-path aware, per-monitor (v2) DPI aware, and UTF-8 as the active code page.
  The last two change what Windows does for the whole process, from its start:
  - sizes and positions are physical pixels and Windows scales nothing, also for windows a
    program makes with its own `user32.dll` calls (std.window asks for the same at run time);
  - from Windows 10 1903 the `A` functions of Windows (`MessageBoxA`, `CreateFileA`) and of C
    libraries a program declares (`fopen`) take and return UTF-8, as AL strings are; on
    older versions they use the system's code page, so declare the `W` functions for text that
    is not ASCII. The run-time library uses `W` functions only and behaves the same everywhere.
- **Icon and version information.** `--icon app.ico` puts the images of an icon file into the
  executable (every size in the file; bitmap and PNG images) as its icon: Explorer and the
  taskbar show it, and std.window gives it to its windows (`LoadIconW(instance, 1)` for other
  windows). `--version-info NAME=VALUE`, once per name, sets what the file's Properties show:
  `FileDescription`, `ProductName`, `CompanyName`, `LegalCopyright`, `FileVersion` (also
  `ProductVersion`, `Comments`, `InternalName`, `OriginalFilename`, `LegalTrademarks`,
  `PrivateBuild`, `SpecialBuild`). `FileVersion` and `ProductVersion` are up to four numbers
  below 65536 (`1.2.3`); `ProductVersion` is `FileVersion` unless given. Values are UTF-8.
  A file that cannot be read or is not an icon is an error (status 1); a bad or repeated
  name, and either option without `--target windows`, is a usage error (status 2), like
  `--gui`. `alc build --target windows --gui --icon game.ico --version-info "FileDescription=My
  Game" --version-info FileVersion=1.0.2 game.al`.
- **The compiler on Windows.** `alc build --target windows src/main.al -o alc.exe` (or
  `build/alc.exe` of `./build.sh`) is the compiler for Windows. It writes the same executables
  as the Linux compiler, for both targets; its default `--target` is `windows`. `alc run` /
  `alc test` run the program directly (a `--target linux` executable is only built); paths may
  use `\` and drive or UNC roots, and appear in diagnostics as written. It runs on a thread
  with a 1 GiB stack and compiles functions in parallel worker threads as on Linux
  (`ALC_JOBS=n` sets the number); see [BOOTSTRAP.md](BOOTSTRAP.md#the-compiler-on-windows).

## Files of a program

A program is the file given to `alc` and the files it includes with `use`, in one namespace
(except `priv` declarations). A path in `use "path"` is relative to the file that contains it,
so a file includes the same files whether it is given to `alc` or included by another one.

`alc build` and `alc run` need `fn main()`; `alc check` and `alc test` do not (they build no
program that starts there). So `alc check part.al` type-checks one file of a program alone,
with the files it includes, while the program is written file by file. Names that only the
including file declares are unknown then: a file that includes what it uses checks alone.

Every command type-checks every function of the program's own files, called or not. The
bundled modules (`use std.name`, and the core modules every program has) are type-checked in
full by `alc check`; `alc build` / `run` / `test` compile only what the program reaches of
them (checking the rest would make building a program on std.gfx 40-70% slower). The
repository's tests check every module for every target, so this never hides an error, except
in a module being written: one read from `ALC_STD_DIR` is checked in full by every command.

## alc fmt

`alc fmt` gives source files the one layout of the repository's own sources, so that two
agents who write the same code write the same text and diffs show only real changes.

```
alc fmt game.al src/            rewrite the files in place (a directory: every .al file in it)
alc fmt --check src/            change nothing; print the files that would change, status 1 if any
alc fmt --stdout game.al        print the result instead of writing it
alc fmt - < game.al             standard input to standard output (for editors and filters)
alc fmt --check --json src/     diagnostics as one JSON array on standard output (as alc check --json)
```

The status is 0 when everything was formatted (`--check`: nothing would change), 1 when a file
would change (`--check`) or has an error, 2 for a usage error. A file with a syntax error is not
changed: its diagnostics are printed as `alc check` prints them, and the other files are still
formatted (`--stdout` / `-` print such a file as it is). With `--json` (not with `--stdout` or
`-`) the diagnostics of all files are one array, nothing when there are none; with `--check` a
file that would change is an entry too, at its first line that would change, instead of its name.

**Leaving a file alone.** A comment `// alc fmt: off` (alone on its line or after code; more text
may follow it) leaves its line and every line after it as written; the lines above it are
formatted. Put it on the first line to keep the whole file, for a test whose layout is what it
tests (trailing spaces, columns in expected diagnostics). There is no `on`: move such code to the
end of the file or into a file of its own.

**What it changes: white space only.** Tokens stay as written and on their lines: no line is
joined or broken, so a newline that ends a statement can never move (see [Grammar](#grammar)),
and a long line stays long; break it yourself after an operator, a comma or an opening bracket.
Comments keep their text and their line.

- **Indentation**: 4 spaces per bracket left open by the lines above (several opened on one line
  count once); a line that starts with `}`, `)` or `]` stands at the indentation of the line
  that opened it. A line that continues a statement after a line ending in an operator (or, in a
  block or a `match`, in a `,`: the patterns of an arm) gets 4 more; further lines of that
  statement keep that indentation. A comment line is indented like code in its place.
- **Spaces in a line**: one around binary operators, `=`, `:=`, `op=`, `->`, `=>`; none after a
  unary operator (`-x`, `*p`, `&v`, `!ok`), around `.`, `..`, `..=`, inside `( )` and `[ ]`,
  before `,` `;` `:` and before the `(` of a call or the `[` of an index or type argument; one
  after `,` `;` `:`. A type is written closed up: `[]*T`, `[4]u8`, `fn(i64) -> i64`. A literal has
  no spaces inside its braces (`Point{1, 2}`, `[]i64{}`), a block one (`{ x * 2 }`, `struct P {
  x: i64 }`), an empty block none (`{}`).
- **Comments after code** keep their column (moved with their line's indentation), so aligned
  comments stay aligned; where the code now reaches the column, one space separates them. A
  comment line right below one in the same column continues it and stays in that column.
- **Blank lines**: at most one in a row; none at the start or the end of the file, after a line
  that ends in an opening bracket, or before a line that starts with a closing one.
- **Line ends**: none of the lines keeps trailing white space; the file ends in one line end. A
  file whose first line ends in CRLF gets CRLF everywhere, otherwise LF; a byte order mark stays;
  raw strings keep their bytes as they are.

**Checked every time.** Before a result is written, `alc fmt` lexes and parses it again: it
must give the same tokens (the newlines that end statements included) and the same comments,
and formatting it once more must not change it. If not (a bug of the formatter), the file is
left as it is with an `internal error of alc fmt` diagnostic. The test `fmt/tree` of
`tests/run.al` formats copies of every `.al` file of the repository, checks that the result does
not change again, that the compiler built from the formatted sources reproduces itself and
compiles `src/main.al` to the same executable, and that scrambling the layout of every file
(indentation, spaces, blank lines, line ends) formats back to the same text. A file marked
`alc fmt: off` must keep the marked lines byte for byte and is not scrambled.

## Grammar

Statements end at a newline or `;`; the arms of a `match` are separated the same way. In the
header of `if` / `while` / `for` / `match` a `{` after a name starts the body (a `Name{...}`
literal there is written in parentheses).

```
file      = { decl }
decl      = ["priv"] ["inline" | "noinline"] "fn" IDENT [tparams] params ["->" type] block
          | ["priv"] "extern" STRING "fn" IDENT cparams ["->" type]
          | "extern" STRING IDENT ":" type
          | ["priv"] "struct" IDENT [tparams] "{" { IDENT ":" type [","] } "}"
          | ["priv"] "enum" IDENT [tparams] "{" { IDENT ["(" type {"," type} ")"] [","] } "}"
          | ["priv"] "const" IDENT [":" type] "=" expr
          | ["priv"] IDENT (":" type ["=" expr] | ":=" expr)
          | "test" STRING block
          | "use" (STRING | IDENT {"." IDENT})
          | "when" expr "{" { decl } "}" { "else" "when" expr "{" { decl } "}" } [ "else" "{" { decl } "}" ]
tparams   = "[" IDENT {"," IDENT} "]"
params    = "(" [IDENT ":" type {"," IDENT ":" type}] ")"
cparams   = "(" [IDENT ":" type {"," IDENT ":" type} ["," "..."]] ")"
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
          | "when" expr block { "else" "when" expr block } [ "else" block ]
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

`in`, `by` and `test` are keywords only where the grammar has them and ordinary names (`IDENT`)
everywhere else: a `for` header has `in` right after its loop variables, and `by` after a
complete range expression, which no name can continue; a declaration that starts with the
name `test` is a variable when `:` or `:=` follows, else a test. A line may end after the
keyword `in`, `by` or `test`: the header or declaration continues on the next line.

In a literal `[_]T{...}` the length is the number of elements written (`_` is allowed as a
length only there). In a pattern, `expr` is a constant, `Variant`, `Enum.Variant`, or (inside another pattern) a new
name; `&` IDENT is allowed only inside another pattern.

`t.0.1` is the field `1` of `t.0` (after `.` a number is a field, never a float literal). Nesting
is limited to 2000 levels (blocks, statements, `else if` chains, parentheses, operators and
links of `a + b`, `x.f(a)[i]` chains, counted through the parentheses around a chain's first
operand, types): deeper programs get an error instead of exhausting the compiler's stack. If
the stack limit cannot be raised to 512 MB, the limit is one level per 256 KB of stack.
