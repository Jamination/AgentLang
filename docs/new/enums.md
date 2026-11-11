# Enums: variant names, patterns, `Opt` and `Res`

Reference text for `docs/LANGUAGE.md`. Every example was compiled and run with the compiler
of this branch; the comments show what it prints.

Places of `docs/LANGUAGE.md` this replaces or extends:

- *Declarations*: the bullet "Enum variant names live in the global namespace ... must be
  unique" is replaced by the section **Variant names** below.
- *Statements / match*: replaced by the section **match**.
- *Expressions / Literals for aggregates*: add `Shape.Circle(c, 2.0)`, `Opt[i64].None`.
- *Standard library*: add the section **Opt and Res**.
- *Unsafe corners*: add the two entries of **Unsafe corners** below.
- *Grammar summary*: replace the `match` and `pattern` lines by those of **Grammar**.
- `docs/BOOTSTRAP.md` says "enum variants carry the enum name (`OpAdd`, `TermJmp`), because
  variants are global"; the reason is gone (the compiler sources keep their names until the
  seed compiler is replaced).

## Variant names

A variant belongs to its enum. Two enums may have variants with the same name, also an enum
of the program and one of the standard library.

```
enum Color { Red, Green, Blue }
enum Light { Red, Amber, Green }
enum Shape { Circle(f64), Rect(f64, f64), Empty }
enum Tree[T] { Leaf(T), Node(*Tree[T], *Tree[T]), Empty }
struct Lamp { colour Light, on bool }

fn warn(l Light) bool { l == Amber }
fn next(l Light) Light {
    match l {
        Red => Green                    // patterns: variants of Light, the matched type
        Green => Amber
        Light.Amber => Red              // the qualified form is always allowed
    }
}

fn main() {
    a := Color.Red                      // qualified: always allowed
    b := Blue                           // only Color has Blue
    var c Light = Red                   // the declared type decides
    c = Green                           // assignment: the type of the destination
    lamp := Lamp{colour: Red, on: true} // field type
    lights := []Light{Red, Amber}       // element type of a typed literal
    print(warn(Amber), next(Red), c == Green, Red != c)      // true Green true true
    s := Shape.Rect(2.0, 3.0)
    var e Tree[i64] = Empty             // Tree[i64].Empty, not Shape.Empty
    l := Tree[i64].Leaf(1)              // type arguments written out
    m := Tree.Leaf("x")                 // type arguments inferred from the payload: Tree[str]
    n := Tree[f64].Empty
    print(a, b, c, lamp, lights, s, e, l, m, n)
    // Red Blue Green Lamp{colour: Red, on: true} [Red, Amber] Rect(2.0, 3.0) Empty Leaf(1) Leaf(x) Empty
}
```

**Qualified form.** `Enum.Variant`, `Enum.Variant(args)`, and for a generic enum
`Enum[T].Variant(args)` or `Enum.Variant(args)` (type arguments from the expected type, else
inferred from the payload). It is allowed wherever a variant can be written, in expressions
and in patterns. `Enum` must name an enum and must not be a local variable (a variable
`e` with a field `b` keeps meaning `e.b`).

**Bare form.** `Variant` or `Variant(args)` in an expression is resolved in this order:

1. If a local variable has that name, it is the variable.
2. If the **expected type** is an enum that has a variant of that name, it is that variant.
   The expected type is known for: the initializer of `var x T = ...`, the right side of an
   assignment, an argument (the parameter type), a returned value and the last expression of
   a function, a field in a struct literal, an element of a typed array / slice / tuple
   literal, a payload value of a variant, and the operand of `==` / `!=` whose other operand
   has a type.
3. Otherwise the enums of the program are searched: if exactly one has the variant, it is
   that one. Only if no enum of the program has it are the enums of the standard library
   searched in the same way (so a program's own `Some` / `None` hide the library's).
4. If several enums remain, it is an error that lists them:
   ``error: `Red` is a variant of several enums (`Color`, `Light`) and the expected type
   does not say which; write `Color.Red` or `Light.Red` ``.

A call of an overloaded function looks at a bare variant argument like at a literal: the
definitions whose parameter is an enum with that variant remain. If two remain and the
expected result type does not decide, it is an error (`f(Red)` with `f(Color)` and
`f(Light)`): write `f(Color.Red)`.

**In a pattern** the type of the matched value decides: a bare variant name is looked up in
that enum only (see below).

**Name conflicts.**

- Within the program, a variant cannot have the name of a function, constant, global, struct
  or enum of the program (``enum variant `X` conflicts with another declaration``), and an
  enum cannot declare a variant twice.
- A variant of the program may have the name of something the standard library declares; in
  the program the name then means the variant (`enum Cmd { push, pop }`: `push` is
  `Cmd.push`; the method call `v.push(1)` still calls the library function).
- A function, constant, global or type of the program with the name of a variant of a
  *library* enum hides that bare variant name in the program; `Opt.Some(x)` still reaches it.
- In a call, the name of a builtin function or builtin type stays the builtin (`len(x)`,
  `i64(x)`), also if an enum has a variant of that name; construct such a variant with
  payload as `Enum.len(..)`. Without parentheses (`len`, `i64`) the name is the variant.
- The code of the standard library resolves bare variant names among its own enums first and
  is not affected by the enums of a program.

```
enum Cmd { push, pop, len }
enum Tok { Some(str), Eof }
fn main() {
    v := vec[i64]()
    v.push(1)                        // method call: the library function
    c := push                        // the variant Cmd.push
    t := Some("x")                   // Tok.Some: the program's enum is preferred
    var o Opt[i64] = Some(1)         // the expected type decides: the library's Opt
    o2 := Opt.Some(2)                // qualified
    n := len(v.items())              // a call of a builtin stays the builtin
    l := Cmd.len
    print(c, t, o, o2, n, l)         // push Some(x) Some(1) Some(2) 1 len
}
```

`print` shows a variant by its bare name (`Red`, `Circle(2.0)`), as before. A variant
payload is evaluated exactly once (also when type arguments are inferred from it).

## match

```
match value {
    pattern => body
    pattern, pattern => body               // alternatives
    pattern if condition => body           // guard
}
```

The arms are tried from top to bottom; the first arm whose pattern matches (and whose guard,
if any, is true) is taken. The body is a statement or a block; `match` is an expression when
every arm yields a value.

The matched value can be an integer, `bool`, `str`, a float, a pointer, an enum, or a tuple;
parts of enums and tuples can have any type.

### Patterns

| Pattern | Matches |
|---------|---------|
| `_` | anything |
| constant: `0`, `-1`, `'a'`, `"text"`, `true`, `1.5`, `nil`, `LIMIT`, `LIMIT + 1` | a value equal to it |
| `Variant`, `Enum.Variant` | that variant (it must have no payload) |
| `Variant(p1, p2)`, `Enum.Variant(p1, p2)`, `Enum[T].Variant(p1, p2)` | that variant, if each payload field matches its sub-pattern (one sub-pattern per field) |
| `(p1, p2, ...)` | a tuple whose elements match the sub-patterns |
| `name` (only inside a variant or tuple pattern) | anything; binds `name` to a **copy** of that part |
| `&name` (only inside a variant or tuple pattern) | anything; binds `name` to a **pointer** (`*T`) to that part |

Sub-patterns nest to any depth: `Some(Circle(r))`, `Two(0, _)`, `(Some(a), None)`,
`Node(Leaf(x), &rest)`.

**What a name means inside a variant or tuple pattern**, in this order:

1. a variant, if the type of the matched part is an enum (or a pointer to one) with a variant
   of that name;
2. a constant, if a `const` of that name exists;
3. otherwise a new variable (a binding). It hides an outer variable of the same name inside
   the arm. A name that is a variant of some *other* enum is a binding too.

An **arm's pattern itself** (not nested) is never a binding: a name there is a variant of the
matched enum, or an expression that is compared with the matched value: a constant, or (as
before) any expression such as a variable, `x.f(a)` or `&x`. To handle "everything else" and
still use the value, write `_` and use the matched expression: `_ if n > 10 => ...`.

Anything else inside a pattern must be a compile-time constant (literals, `const` names,
arithmetic on them). To compare with a variable, bind the part and use a guard:
`Some(x) if x == limit => ...`.

**Bindings.** `name` is a variable of the arm that holds a copy of the matched part;
assigning to it does not change the matched value. `&name` has type `*T` and points at the
part inside the matched value, so it can be used to modify the value in place or be stored:

```
enum Shape { Circle(f64), Rect(f64, f64), Empty }
enum Expr { Num(i64), Neg(*Expr), Add(*Expr, *Expr) }
struct Account { id i64, balance i64 }
const MAX = 100

fn describe(o Opt[Shape]) str {
    match o {
        Some(Circle(r)) if r > 10.0 => "big circle"      // guard
        Some(Circle(_)) => "circle"
        Some(Rect(w, h)) if w == h => "square"
        Some(Rect(_, _)) => "rectangle"
        Some(Empty) => "empty shape"
        None => "nothing"
    }
}

fn eval(e *Expr) i64 {
    match *e {
        Num(n) => n
        Neg(x) => -eval(x)
        Add(a, b) => eval(a) + eval(b)
    }
}

// 0 + x and x + 0 become x, in place
fn simplify(e *Expr) {
    match *e {
        Add(&a, &b) => {                 // a and b have type **Expr: they point into *e
            simplify(*a)
            simplify(*b)
        }
        Neg(x) => simplify(x)
        Num(_) => {}
    }
    match *e {
        Add(Num(0), x), Add(x, Num(0)) => { *e = *x }   // both alternatives bind x
        _ => {}
    }
}

fn sign(p (i64, i64)) str {
    match p {
        (0, 0) => "origin"
        (x, 0), (0, x) => fmt("on an axis at ", x)
        (x, y) if x == y => "on the diagonal"
        (MAX, _) => "at the right edge"
        _ => "elsewhere"
    }
}

fn both(a Opt[i64], b Opt[i64]) i64 {
    match (a, b) {
        (Some(x), Some(y)) => x + y
        (Some(x), None), (None, Some(x)) => x
        (None, None) => 0
    }
}

fn deposit(o *Opt[Account], amount i64) bool {
    match *o {
        Some(&acc) => {                  // acc is a *Account into *o
            acc.balance += amount
            true
        }
        None => false
    }
}

fn main() {
    print(describe(Some(Circle(12.0))), describe(Some(Rect(1.0, 1.0))), describe(None))
    // big circle square nothing
    zero := Num(0)
    five := Num(5)
    sum := Add(&zero, &five)
    neg := Neg(&sum)
    simplify(&neg)
    print(eval(&neg), match neg { Neg(Num(n)) => n; _ => -1 })           // -5 5
    print(sign((0, 0)), sign((3, 0)), sign((2, 2)), sign((100, 1)), sign((1, 2)))
    // origin on an axis at 3 on the diagonal at the right edge elsewhere
    print(both(Some(1), Some(2)), both(None, Some(5)), both(None, None))   // 3 5 0
    var acct Opt[Account] = Some(Account{id: 1, balance: 10})
    deposit(&acct, 5)
    print(acct)                                                            // Some(Account{id: 1, balance: 15})
}
```

**Where `&name` points.** If the matched expression is a place (a variable, `x.f`, `a[i]`,
`*p`), the pointer points into that place. Otherwise (a call result, a tuple expression such
as `match (a, b)`, ...) the value is first stored in a temporary of the enclosing function
and the pointer points into the temporary; it stays valid until the function returns, but
changes through it reach nothing else.

**Pointers.** A variant or tuple pattern (or the name of a variant) also matches a *pointer*
to an enum or tuple: the pattern matches if the pointer is not `nil` and the value it points
to matches. `nil` matches no such pattern; it is matched by the constant `nil` (or `_`, or a
binding). This is what makes patterns useful for linked structures:

```
enum List { Cons(i64, *List), End }

fn sum(l *List) i64 {
    match l {
        Cons(x, rest) => x + sum(rest)   // l is not nil and *l is a Cons
        End => 0
        nil => 0                         // without this arm the match would not be exhaustive
    }
}

fn second(l *List) Opt[i64] {
    match l {
        Cons(_, Cons(x, _)) => Some(x)
        _ => None
    }
}

fn main() {
    end := End
    b := Cons(2, &end)
    a := Cons(1, &b)
    print(sum(&a), second(&a), second(&b))    // 3 Some(2) None
}
```

A binding of a pointer-typed part (`rest` above) is the pointer itself; `&name` inside a
pattern that looked through a pointer points into the target.

**Alternatives.** `p1, p2 => body` takes the arm if any of the patterns matches. All
alternatives of an arm must bind the same names with the same types (error otherwise, naming
the binding); `_` binds nothing.

**Guards.** `pattern if cond => body`: `cond` (a `bool`) is evaluated after the pattern
matched and its bindings exist. If it is false, matching continues with the **next arm**
(with alternatives the guard is evaluated once, for the alternative that matched; the other
alternatives of that arm are not tried). The guard may call functions. If a guard changes
the variable that is being matched, the following arms still look at the value as it was
when the `match` began (exceptions: a `match` that uses `&name`, and values reached through
a pointer; see Unsafe corners).

**Order of evaluation.** The matched expression is evaluated once. Patterns are tested in
order; constants inside patterns have no effects.

### Exhaustiveness

A `match` used as a statement may leave values unmatched: then no arm runs. A `match` used
as a **value** must cover every possible value, otherwise it is a compile error that lists
what is missing in pattern form:

```
error: match used as a value must be exhaustive; missing: Some(Rect(_, _))
error: match used as a value must be exhaustive; missing: (Some(_), Some(false))
error: match used as a value must be exhaustive; missing: Circle(_), Empty (an arm with a guard does not count: add an arm without a guard or `_ =>`)
error: match used as a value must be exhaustive; missing: nil, Rect(_, _)
error: match used as a value must be exhaustive (add a `_ =>` arm)
```

Rules:

- An arm with a **guard** covers nothing.
- `_`, a binding, and a tuple pattern made of such patterns cover everything.
- A variant pattern whose sub-patterns cover everything covers its variant. Patterns with
  constants or variants inside are combined: `Some(Circle(_))`, `Some(Rect(_, _))`,
  `Some(Empty)` and `None` together cover `Opt[Shape]`; `(true, _)` and `(false, _)` cover
  `(bool, T)`. (The check is the usual one for pattern matching: a match is exhaustive if no
  value exists that every unguarded arm rejects.)
- Integers, floats, strings and pointer values are never covered by constants alone: such a
  position needs `_` or a binding. `true` and `false` cover `bool`.
- Through a pointer, `nil` must be covered separately (`nil =>` or `_ =>`).

For an enum, each variant that is not fully covered is listed (with what is missing inside
it); for other types one missing value is shown.

## Opt and Res

Declared by the standard library (always available):

```
enum Opt[T] { Some(T), None }          // a value that may be absent
enum Res[T] { Ok(T), Err(str) }        // a value, or the message of the error that prevented it

is_some(o Opt[T]) bool      is_none(o Opt[T]) bool
unwrap(o Opt[T]) T          // the value; stops the program with "panic: unwrap of None"
or(o Opt[T], default T) T   // the value, or `default`

is_ok(r Res[T]) bool        is_err(r Res[T]) bool
unwrap(r Res[T]) T          // the value; stops with "panic: unwrap of Err: <message>"
or(r Res[T], default T) T   // the value, or `default`
error(r Res[T]) str         // the message, "" if r is Ok
```

All of them can be called as methods: `o.unwrap()`, `r.is_ok()`, `o.or(0)`.

```
fn find(xs []str, x str) Opt[i64] {
    for i, s in xs {
        if s == x {
            return Some(i)
        }
    }
    None
}

fn parse_port(s str) Res[i64] {
    n, ok := parse_i64(s)
    if !ok {
        return Err(fmt("not a number: ", s))
    }
    if n < 1 || n > 65535 {
        return Err(fmt("port out of range: ", n))
    }
    Ok(n)
}

fn main() {
    names := []str{"ada", "bob"}
    print(find(names, "bob"), find(names, "eve"))            // Some(1) None
    print(find(names, "bob").unwrap(), find(names, "eve").or(-1), find(names, "eve").is_none())   // 1 -1 true
    match parse_port("8080") {
        Ok(p) if p < 1024 => print("privileged port", p)
        Ok(p) => print("port", p)                            // port 8080
        Err(msg) => print("error:", msg)
    }
    bad := parse_port("http")
    print(bad.is_err(), bad.error(), bad.or(80))             // true not a number: http 80
    var cache Opt[str] = None                                // the type gives None its T
    cache = Some("warm")
    first := Some(1.5)                                       // Opt[f64], from the payload
    none := Opt[u8].None                                     // written out
    print(cache, first, none)                                // Some(warm) Some(1.5) None
    print(parse_port("0").unwrap())                          // panic: unwrap of Err: port out of range: 0
}
```

- `None` (and `Err("..")` for `Res[T]`) need a type from the context: a declared type, a
  parameter, the result type, or `Opt[T].None`. `x := None` is an error
  (``cannot infer type arguments of enum `Opt` for `None`; annotate the destination type or
  write `Opt[T].None` ``).
- Like every enum with payload, `Opt` and `Res` values cannot be compared with `==`; use
  `match` or the helpers.
- A program may declare its own `Opt`, `Res`, `Some`, `None`, `Ok`, `Err` or helper functions
  of these names. Its declarations are then used in the program (see Variant names); the
  library's `Opt[T]` and the program's `Opt[T]` are different types, and the library's
  helpers only accept the library's type (the diagnostic says so:
  ``expected Opt[i64], found Opt[i64] (two different types have this name: ...)``).

## Unsafe corners

Add to the list of unchecked features:

- **`&name` in a pattern.** The pointer points into the payload of the variant that was
  matched. If the enum value is later overwritten with another variant (or the tuple or
  container element it lives in is replaced or released), the pointer still points at that
  storage, which now holds something else, possibly of another type. Do not keep such a
  pointer beyond the next assignment to the matched value. When a `match` uses `&name` on a
  place, a guard of that `match` that modifies the matched place has the same effect on the
  arms that follow.
- **Patterns through pointers** dereference the pointer when it is not `nil`; a pointer to
  released memory is not detected (as with `*p`). The target is read when each arm is
  tested: a guard that overwrites the target with another variant confuses the arms after it.

## Grammar

```
primary   = ... | "match" expr "{" { arm } "}"
arm       = pattern {"," pattern} ["if" expr] "=>" (block | stmt)
pattern   = "_"
          | expr                                           constant; `Variant`; `Enum.Variant`;
                                                           inside another pattern also a new name
          | [qual "."] IDENT "(" [pattern {"," pattern}] ")"   variant with payload
          | "(" pattern "," pattern {"," pattern} ")"          tuple
          | "&" IDENT                                      pointer binding (inside another pattern)
qual      = IDENT ["[" type {"," type} "]"]
postfix   = ... | qual "." IDENT ["(" [expr {"," expr}] ")"]   variant by qualified name
```

A pattern is read with the grammar of expressions (`Some(x)` like a call, `(a, b)` like a
tuple, `&x` like address-of), so everything that follows an expression's syntax is accepted
by the parser; what is not a pattern is rejected with a message when the `match` is checked.
