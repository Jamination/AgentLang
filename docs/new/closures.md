# Closures

Reference text for the closure feature, ready to be merged into `docs/LANGUAGE.md`. Every
example below is part of `tests/run/closures_doc.al` (compiled in the default mode, with `-O0`
and with `--unchecked`). The last section lists the places of the existing reference that
need a small change.

## Closures

A **closure** is an anonymous function written inside another function. It can read *and
assign* the local variables and parameters of the function it is written in.

```
scores := []i64{70, 95, 80}
names := []str{"ann", "bob", "cy"}
order := []i64{0, 1, 2}
sort_by(order, |a i64, b i64| bool { scores[a] > scores[b] })   // uses the local `scores`
for i in order {
    put(names[i], " ")
}
print("")                                    // bob cy ann
```

### Closure types

| Type | Meaning |
|------|---------|
| `\|A, B\| R` | closure taking `A` and `B`, returning `R` |
| `\|A\|` | closure without a result |
| `\|\| R`, `\|\|` | closure without parameters |
| `fn(A, B) R` | plain function value (unchanged: a code pointer, 8 bytes, C-compatible) |

- A closure type is written wherever a type is: parameters, results, variables, struct
  fields, enum payloads, type arguments (`vec[|i64| bool]()`, `Map[str, |i64| i64]`).
- It lists **types only**, without parameter names (`|i64, i64| bool`, not `|a i64, b i64| bool`).
- A closure value is **16 bytes** (alignment 8): a code pointer and an environment pointer.
  It is passed, returned, stored and copied like a struct of two words; a copy refers to
  the same environment.
- The zero value (`var f |i64| i64`, a zeroed struct field, `nil`) is the **nil closure**;
  calling it is a memory fault, like calling a nil function value.
- Closures cannot be compared (`==`, `!=`, also not with `nil`) and cannot be hashed, so a
  struct or tuple that contains one cannot be compared or used as a map key either.
  `print` shows a closure as `<closure>`.
- The result type, if any, follows the closing `|` on the same line. A `|` that ends a line
  ends the type (`var f |i64|` followed by a new statement; a struct field `on_click |i64|`).

### Closure literals

```
less := |a i64, b i64| bool { a < b }        // two parameters, result bool
show := |x i64| { print("value", x) }        // no result
count := 0
tick := || { count += 1 }                    // no parameters
sign := |x i64| i64 {
    if x < 0 {
        return -1                            // returns from the closure
    }
    1
}
show(sign(-5))                               // value -1
tick()
tick()
print(less(1, 2), count)                     // true 2
```

- Form: `|name Type, ...| Result { body }`. Every parameter has a type; the result type is
  written out (it is never inferred) and omitted when the closure yields no value. `||`
  starts a literal without parameters.
- The body is a block, as for a function: its last expression is the value, `return`
  returns **from the closure**, `defer` blocks run when the closure returns.
- `break` and `continue` cannot leave the closure (a loop around the literal is not a loop
  of the closure).
- A literal is an expression: it can be stored, passed, returned, or called at once
  (`|x i64| i64 { x + 1 }(41)`).
- The type of a literal is the closure type of its written parameter and result types,
  whatever the context expects (`|a i64, b i64| bool { .. }` has the type `|i64, i64| bool`).

### Captured variables

Inside the body, the local variables and parameters of the enclosing function that are in
scope at the literal are visible **by reference**: the closure works on the variable itself,
not on a copy. Globals, constants, functions and types are visible as everywhere.

```
total := 0
add := |x i64| { total += x }
add(5)
total = 100                                  // the closure sees later changes
add(1)
print(total)                                 // 101
p := Point{1, 2}
move := |dx i64| { p.x += dx }
move(10)
print(p)                                     // Point{x: 11, y: 2}
```

- Variables of any type can be captured: scalars, structs, arrays, slices, tuples, vectors,
  loop variables, `match` bindings, parameters.
- Literals nest; an inner literal sees the variables of all enclosing literals and of the
  function:

  ```
  hits := 0
  outer := |n i64| {
      inner := |k i64| { hits += n * k }       // `n` of outer, `hits` of main
      inner(1)
      inner(2)
  }
  outer(10)
  print(hits)                                  // 30
  ```
- Parameters of the literal and variables declared in its body shadow outer names.
- A variable declared *after* the literal is not visible in it. That includes the variable
  the literal is assigned to, so a closure that calls itself is declared first:

  ```
  var fact |i64| i64
  fact = |n i64| i64 { if n <= 1 { 1 } else { n * fact(n - 1) } }
  print(fact(10))                              // 3628800
  ```
- Every local variable is one stack slot per call of the function. Closures made in a loop
  therefore share the loop variable and the variables of the loop body: after
  `for i in 0..3 { fs.push(|| i64 { i }) }` all three closures yield the same value.
- In a generic function a literal may use the type parameters (`|x T| { acc += x }`); it is
  compiled once per instantiation.
- Creating a closure does not allocate from the arena: the environment lives in the stack
  frame of the enclosing function. See [unsafe corners](#unsafe-corners-of-closures) for
  what follows from that.

### Calling

A closure value is called like a function: `c(args)`. A struct field that holds a closure
is called as `s.field(args)` (this takes precedence over method-call syntax, as for function
fields). An expression that yields a closure can be called directly: `handlers[i](x)`,
`make()(x)`. (An element of a tuple is copied to a variable first: `g := t.0`, then `g(x)`.)

### Conversions

Where a closure type is expected (an argument, also of a method call or an overloaded
function; an assignment; `var` with a type; `return`; an element of a struct, array, slice
or tuple literal; a global initializer), these are accepted and converted, provided the
parameter and result types are the same:

- a function name (also a generic one: its type arguments are taken from the closure type,
  or written as `name[T]`),
- a value of the function type `fn(A) R`,
- a closure literal.

In the other direction only one case exists: a closure **literal that captures nothing** is
accepted where `fn(A) R` is expected, so it can be a C callback or an element of a
`fn` table. A closure *value* never converts to `fn`.

```
var f |i64| i64 = double                     // function name
fv := double                                 // fv has the type fn(i64) i64
f = fv                                       // fn value
f = |x i64| i64 { x + count }                // literal
print(f(1), apply(4, double), apply(4, |x i64| str { fmt("<", x, ">") }))   // 3 8 <4>
print(call_plain(|x i64| i64 { x + 1 }, 41)) // 42: a literal without captures is a plain function
var g |i64| i64 = ident                      // generic function: T = i64 from the closure type
print(g(7), describe(|s str| str { s }), describe(double))   // 7 text numbers
```

(with `fn apply[T, U](x T, f |T| U) U`, `fn call_plain(f fn(i64) i64, x i64) i64`,
`fn ident[T](x T) T`, and `describe` defined for `|i64| i64` and for `|str| str`.)

- **Generic inference** works through closure types: in `apply(4, double)` and
  `apply(4, |x i64| str { .. })` the parameter type `|T| U` binds `T` and `U` from the
  function or the literal.
- **Overloads**: an argument that is a closure literal is matched by the closure type of
  its written types (first against closure parameters, then against `fn` parameters); a
  function value is accepted by a closure parameter with the same types.
- A global variable of a closure type can be initialized with a function name or `nil`,
  not with a literal (assign the literal in a function).
- Without an expected type, a function name is a `fn` value: `h := double` declares
  `h` as `fn(i64) i64`; write `var h |i64| i64 = double` for a closure variable.

### Closures in data and in generic code

```
clicked := 0
b := Button{label: "ok", on_click: |n i64| { clicked += n }}
b.on_click(2)
b.on_click(3)
handlers := vec[|i64| i64]()
handlers.push(double)
handlers.push(|x i64| i64 { x + clicked })
print(clicked, handlers.buf[1](1), b)        // 5 6 Button{label: ok, on_click: <closure>}
```

```
fn largest[T](items []T, less |T, T| bool) T {
    best := items[0]
    for x in items {
        if less(best, x) {
            best = x
        }
    }
    best
}

// calls `visit` for every number below `limit` that has the property `keep`
fn walk(limit i64, keep |i64| bool, visit |i64|) {
    for i in 0..limit {
        if keep(i) {
            visit(i)
        }
    }
}

print(largest([]f64{1.5, 9.25, 3.0}, |a f64, b f64| bool { a < b }))        // 9.25
seen := vec[i64]()
walk(20, |i i64| bool { i % 7 == 0 }, |i i64| { seen.push(i) })
print(seen.items())                          // [0, 7, 14]
```

### Syntax details

- `|` and `||` start a closure literal or type only where an expression or a type starts;
  after an operand they remain the operators "or" (`a | b`, `a || b`), also at the end of a line.
- In the parameter list of a closure type or literal a `|` always closes the list. Two
  consequences:
  - a parameter that is itself a closure type is written after a space when it comes
    first in a *type*: `| |i64| bool, i64| bool` (`||` would mean "no parameters");
  - inside the list, a function or closure type cannot have a result type that starts
    with `|` (there is no way to write "a parameter that is a function returning a
    closure" inline; name the type through a struct field or a generic parameter).
- `|f |i64||` is fine: the final `||` closes both lists.
- A result type that is a struct name is followed by the body as usual:
  `|x i64| Point { Point{x, 0} }`.
- Common mistakes are reported with the correct form: untyped parameters (`|a, b| ..`), a
  body that is not a block (`|x i64| x * 2`), a missing result type (`|x i64| { x * 2 }`),
  `fn(a i64) i64 { .. }` as an anonymous function, names in a closure type.

### Library

`sort_by` takes a closure, and the core library has a few slice helpers that do:

```
sort_by(a []T, less |T, T| bool)             // stable; `less` may be a function name as before

any(s []T, p |T| bool) bool                  // is p true for some element
all(s []T, p |T| bool) bool                  // ... for every element (true for an empty slice)
count_if(s []T, p |T| bool) i64              // number of elements for which p is true
index_where(s []T, p |T| bool) i64           // first such index, or -1
filter(s []T, p |T| bool) []T                // new slice of the elements for which p is true
map_to(s []T, f |T| U) []U                   // new slice of f(x)   (`map` is the hash map constructor)
each(s []T, f |T|)                           // calls f(x) for every element, in order
```

```
xs := []i64{3, 8, 1, 6}
limit := 5
print(xs.any(|x i64| bool { x > limit }), xs.all(|x i64| bool { x > limit }))      // true false
print(xs.count_if(|x i64| bool { x > limit }), xs.index_where(|x i64| bool { x > limit }))   // 2 1
print(xs.filter(|x i64| bool { x > limit }), xs.map_to(|x i64| str { fmt(x, "!") }))   // [8, 6] [3!, 8!, 1!, 6!]
sum := 0
xs.each(|x i64| { sum += x })
print(sum)                                   // 18
```

For a `Vec`, pass `v.items()`. `filter` and `map_to` allocate their result from the arena.

### Unsafe corners of closures

- **A closure that captures variables is valid only while the call of the function that
  created it is active.** Its environment and the captured variables live in that
  function's stack frame. Returning such a closure, or storing it somewhere that outlives
  the call (a global, a longer-lived struct, a `Vec` owned by the caller), and calling it
  later is undefined behaviour — nothing checks this. Passing it *down* to functions you call
  (`sort_by`, `each`, your own) is always fine, also recursively.
- A closure that captures nothing (a literal that uses no local variables, or a converted
  function) is valid forever and may be returned and stored freely.
- A captured variable whose block has ended (a closure assigned to a variable of an outer
  block, called after the inner block) still refers to the variable's slot; in a loop that
  slot is reused by the next iteration.
- Calling the nil closure faults.
- C functions cannot receive closures (`extern` parameters must be scalars); pass a
  function or a capture-free literal as `fn(...)`.

### Grammar additions

```
type      = ... | "|" [type {"," type}] "|" [type] | "||" [type]
primary   = ... | "|" [IDENT type {"," IDENT type}] "|" [type] block | "||" [type] block
```

## Notes for the other parts of the reference

- **Types table**: `fn(A, B) R` is "function value (a plain code pointer)"; add the row
  `|A, B| R` — "closure: function value with an environment (16 bytes)". The sentence "there
  are no closures" goes away.
- **Lexical structure**: "A newline does not end a statement when the line ends in an
  operator" — except a `|` that closes a closure type (`var f |i64|`).
- **Expressions**: `==` / `!=` do not work on closures (nor on aggregates containing one).
- **Builtins**: `print` renders a closure as `<closure>`; `hash` rejects closures.
- **Standard library**: `sort_by(a []T, less |T, T| bool)`; add the helpers above.
- **C interop**: "A plain AL function *or a closure literal that captures nothing* can be
  passed where C expects a callback".
- **Unsafe corners**: add the first bullet of the list above.
- **Quick tour**: `largest` can take `less |T, T| bool` and be called with a literal.

## Implementation notes (for docs/BOOTSTRAP.md)

- `src/lower_closure.al` holds the feature: the capture walk, literal lowering, closure
  values. Type kind `TyKClosure(params, result)`; AST `TypeAstClosure`, `EKClosure`.
- Calling convention: a call through a closure value is an indirect call that passes the
  environment pointer as one extra integer argument **after** the declared arguments. A
  literal with captures becomes a function whose last parameter is the environment (an array
  of the addresses of the captured variables, allocated in the frame of the enclosing
  function and filled when the literal is evaluated). A literal without captures becomes a
  plain function, and a plain function converted to a closure has a nil environment and
  ignores the extra argument: it arrives in the next free integer argument register or in
  the caller's outgoing-argument area above the declared stack arguments
  (`src/x86/isel.al`, `call` and `params`), neither of which the callee looks at.
- The literal's function is lowered immediately, by `lower_fn_lower_body` (the part of
  function lowering shared with declared functions), with the type environment of the
  enclosing function; captured names are declared in its outermost scope as
  `(type, address loaded from the environment)`.
- The optimizer never turns an indirect call into a direct one, and the inliner and the
  tail-recursion pass only look at direct calls, so no pass sees a call whose argument
  count differs from the callee's parameter count. A pass that devirtualizes
  `CallInd(FAddr f, args..)` must drop the last argument when `f` has one parameter less.
