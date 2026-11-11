# File-private declarations (`priv`)

Reference text for `docs/LANGUAGE.md`. Places it touches: the keyword list (add `priv`), the
section "Declarations", the grammar summary (`decl`), "Tooling" (`alc sigs`).

## Declarations: `priv`

All top-level names of a program share one namespace, whatever file they are in. `priv` in
front of a declaration takes it out of that namespace: the declaration is visible only inside
the file that contains it.

```
priv fn find(key str) i64 { ... }          // also: priv inline fn, priv noinline fn,
priv struct Slot { key str, val i64 }      //       priv extern "lib" fn
priv enum Mode { Idle, Busy(i64) }
priv const LIMIT = 4
priv var slots Vec[Slot]
```

```
// stack.al
priv const LIMIT = 4                       // only this file sees LIMIT, Slot, slots, find
priv struct Slot { key str, val i64 }
priv var slots Vec[Slot]

priv fn find(key str) i64 {                // the library's find(s, sub) is still there for text
    for i in 0..slots.len {
        if slots.buf[i].key == key {
            return i
        }
    }
    -1
}

fn stack_set(key str, val i64) bool {      // public: the interface of the file
    i := find(key)
    if i >= 0 {
        slots.buf[i].val = val
        return true
    }
    if slots.len == LIMIT {
        return false
    }
    slots.push(Slot{key, val})
    true
}

fn stack_get(key str) i64 {
    i := key.find()                        // method-call syntax works on private functions
    if i < 0 { 0 } else { slots.buf[i].val }
}

fn stack_dump() {
    print(slots.items(), find("a=b", "="))
}
```

```
// main.al
use "stack.al"

priv const LIMIT = "none"                  // another LIMIT: each file has its own
priv fn find(xs []i64, x i64) bool {
    for v in xs {
        if v == x {
            return true
        }
    }
    false
}

fn main() {
    stack_set("a", 1)
    stack_set("b", 2)
    stack_set("a", 3)
    print(stack_get("a"), stack_get("zz"), LIMIT, find([]i64{1, 2}, 2))    // 3 0 none true
    stack_dump()        // [Slot{key: a, val: 3}, Slot{key: b, val: 2}] 1
}
```

Rules:

- **Visibility.** A private declaration can be used anywhere in its own file (before or after
  the declaration, in functions, types, constants, global initializers and `test` blocks) and
  nowhere else. `use` does not change that: neither the including file nor the included file
  sees the other's private declarations. In other files the name is unknown, or it means
  whatever other declaration of that name they can see:

  ```
  err.al:3:11: error: unknown identifier `LIMIT` (`LIMIT` is declared `priv` in stack.al, line 2: a private declaration is visible only inside its own file; remove `priv` there to use it from other files)
  ```

- **Same name in several places.** Any number of files may each declare a private `name`; a
  private name may also equal a public declaration of another file or a library name. Inside
  the file the private declaration wins: every use of the name in that file means the private
  one (but see functions below).
- **One file, one meaning.** Within one file a name cannot be declared both with and without
  `priv`. Functions overload as usual, but all definitions of a function name in one file are
  either private or public. An enum variant cannot have the name of a private declaration of
  the same file. Two private declarations of one name in a file are an error exactly as two
  public ones are (except function overloads with different parameter types).
- **Functions: private first, then public.** A call `f(args)` or `x.f(args)` in a file with
  private definitions of `f` considers them together with the public definitions of `f`
  (other files, then the library), as one overloaded name. The usual selection by receiver and
  argument types applies, with one addition: **if a private definition fits the call, a public
  one is never chosen**, not even one that would fit "better" (a non-generic public definition
  against a generic private one, or an untyped literal that matches a public parameter type
  more naturally). So a private `fn min(a Meters, b Meters)` leaves `min(3, 4)` to the
  library, and a private `fn max[T](a T, b T) T` replaces the library's `max` in its file
  completely. The same holds for a private function used as a value (`f := name`).
- **Builtins.** A private function named like a builtin (`len`, `print`, `hash`, `sqrt`, ...:
  the table in "Builtin functions") replaces the builtin in its file for every call, just as a
  public function of that name replaces it in the whole program; builtins do not take part in
  overloading. Builtin type names (`i64`, `str`, `vec3`, ...) cannot be declared, with or
  without `priv`.
- **Other kinds.** A private struct, enum, constant or global hides every public declaration
  of that name in its file, of whatever kind.
- **Method calls.** `x.f(args)` finds private functions of the file like any other function.
  A field of `x` that holds a function is still called first (`j.run(21)` below calls the
  field); field names and the field labels of struct literals are never private names, so a
  struct may have a field called like a private function, constant or type.
- **Local names.** Local variables, parameters, loop variables, `match` bindings and type
  parameters may have the name of a private declaration; they shadow it in their scope as they
  would shadow a public one.
- **Enums.** `priv enum` makes the *type name* private. Its variants are ordinary global names
  (they must be unique in the program and other files can construct and match them).
- **Generics.** Private functions and structs can be generic. A public generic function of
  another file that is instantiated with a private type is still checked in *its own* file:
  it cannot call the private functions of the file that uses it.
- **Not allowed.** `priv fn main` (the program's entry point), `priv test`, `priv use`; `priv`
  inside a function, on a struct field or on an enum variant; `priv priv`.
- **What the user sees.** Diagnostics, `print` (`Slot{key: a, val: 3}`), `--emit-ir` /
  `--emit-asm` and the symbol table of the executable show private declarations under the name
  written in the source. Two files can therefore produce the same struct name in output.
  `alc sigs` marks them: `stack.al:6: priv fn find(key str) i64`; `alc sigs file.al -- std`
  omits the private declarations of the library.

```
priv struct Meters { v f64 }
priv fn min(a Meters, b Meters) Meters { if a.v < b.v { a } else { b } }
priv fn max[T](a T, b T) T { a }          // fits everything: the library's max is never called here
priv fn hash(m Meters) u64 { 7 }           // `hash` is a builtin: replaced in this file

struct Job { run fn(i64) i64 }
priv fn run(j Job, x i64) i64 { -1 }
priv fn double(x i64) i64 { x * 2 }

fn main() {
    print(min(Meters{2.0}, Meters{1.0}), min(3, 4))     // Meters{v: 1.0} 3
    print(max(3, 4), hash(Meters{1.0}))                  // 3 7
    j := Job{run: double}
    print(j.run(21), run(j, 21))                         // 42 -1
    double := 5                                          // a local may reuse a private name
    print(double)                                        // 5
}
```

Use `priv` for everything that is not the interface of a file: helpers get their natural short
names (`find`, `Ctx`, `LIMIT`) instead of file prefixes, and no other file can come to depend
on them. The bundled modules do this (`std/rand.al`, `std/image.al`): a program may declare
its own `splitmix`, `Inflate` or `rgba` although the library has internals of those names.

Diagnostics:

| Misuse | Message |
|--------|---------|
| name of another file's private declaration | `unknown identifier/function/type/variable ... (`X` is declared `priv` in f.al, line N: a private declaration is visible only inside its own file; remove `priv` there to use it from other files)` |
| `priv fn f` and `fn f` in one file | ``function `f` is defined both with and without `priv` in this file (the other definition is at line N): the definitions of one name in a file are all private or all public; write `priv` in front of every one, or of none`` |
| `priv const X` and `var X` (any two kinds) in one file | `` `X` is declared both with and without `priv` in this file (the other declaration is at line N): inside the file the name would be ambiguous; rename one of them`` |
| private name equal to a variant of an enum of the same file | ``enum variant `Red` conflicts with the `priv` declaration `Red` of this file (variants are never private); rename one of them`` |
| `priv fn main` | `` `fn main` cannot be `priv`: it is where the program starts, which is outside this file; remove `priv` `` |
| `priv test "..."` | ``a `test` block cannot be `priv` (nothing refers to a test by name): remove `priv` `` |
| `priv use ...` | `` `use` cannot be `priv` (a file is included into the whole program): remove `priv` `` |
| `priv x := 1` in a function | `` `priv` applies to top-level declarations only (...); a local declaration is visible only in its block anyway`` |
| `priv` on a struct field / enum variant | ``a struct field cannot be `priv` ...: write `priv struct` ...`` / ``an enum variant cannot be `priv` ...: write `priv enum` ...`` |

## Lexical structure

`priv` is a keyword (it can no longer be used as an identifier).

## Grammar summary

```
decl      = ["priv"] ["inline" | "noinline"] "fn" IDENT [tparams] "(" [param {"," param}] ")" [type] block
          | ["priv"] "extern" STRING "fn" IDENT "(" [param {"," param}] ")" [type]
          | ["priv"] "struct" IDENT [tparams] "{" { IDENT type [","] } "}"
          | ["priv"] "enum" IDENT [tparams] "{" { IDENT ["(" type {"," type} ")"] [","] } "}"
          | ["priv"] "const" IDENT [type] "=" expr
          | ["priv"] "var" IDENT (type ["=" expr] | "=" expr)
          | "test" STRING block
          | "use" STRING
```

The parser accepts `priv` in front of any declaration and then decides per kind
(`parser_set_priv`); a new kind of declaration (for example a type alias) becomes private-capable
by adding one case there and one in `priv_decl_info` / `priv_rewrite` (`src/priv.al`).

## Unsafe corners / things to know

- Privacy is a compile-time naming rule, not protection: a private global or function can
  still be reached through a pointer or function value that a public function hands out, and
  values of a private struct type can be returned to, stored by and printed in other files
  (they just cannot name the type: `q := queue_make()` works, `var q Ctx` does not).
- Because variants of a private enum are global, other files can construct them; only the
  type name is hidden.
- A private function named like a builtin disables that builtin in the file (`priv fn len(q
  Queue) i64` makes `len("text")` an error there; `s.len` without parentheses still works).
  Choose another name (`size`, `count`) when the file also needs the builtin.

## How it is implemented (for `docs/BOOTSTRAP.md`)

`src/priv.al`. Right after a file is parsed (`add_text` in `src/main.al`), `priv_apply`
collects the file's private names and renames each to `name` + byte 1 + the file's index (a
spelling that cannot occur in source), in the declaration and in every identifier of that
spelling in the file: expressions, call targets, method names of calls (private functions
only), type names, constant patterns, and local declarations (variables, parameters, loop
variables, `match` bindings, type parameters). Field names, field labels and variant names
are left alone. The rest of the compiler works on one flat namespace as before. The places
that know about internal names:

- `ast_plain`, `ast_is_private`, `ast_plain_text` (`src/ast.al`);
- `main_report` and `main_print_sigs` (`src/main.al`) pass every message / signature through
  `ast_plain_text`;
- `inst_struct`, `inst_enum`, `inst_fn`, `global` (`src/lower.al`) give types, functions,
  globals and C imports their plain names;
- `fn_candidates` (`src/lower.al`) appends the public candidates of the written name to the
  private ones; `call_overloaded` (`src/lower_call.al`) drops public candidates when a private
  one is still alive after the argument checks;
- `call` (`src/lower_call.al`, function-valued field before method) and `field_of`
  (`src/lower_expr.al`) compare field names with the plain name;
- `Cx.priv_decls` / `priv_hint` (`src/lower.al`) produce the "is declared `priv` in ..." hint.
