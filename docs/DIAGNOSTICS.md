# Diagnostics

Every error and warning of `alc` has a code that names the kind of mistake. The code is stable:
the message of a kind may be reworded, the code stays. `alc explain <code>` prints the entry
below, and `alc capabilities` prints all of them as JSON.

## The JSON form

`alc check --json -W file.al` (and `build`, `run`, `test`, `fmt` with `--json`) writes one
JSON array to standard output:

```json
[{"file":"t.al","line":3,"col":11,
  "message":"unknown identifier `coutn` (did you mean `count`?)",
  "severity":"error","code":"E0301","end_line":3,"end_col":16,
  "fix":"write `count`"}]
```

| Field | Meaning |
|---|---|
| `file` | the path as it was given; `""` for a mistake in the command line |
| `line`, `col` | where the mistake is, from 1, the column in bytes; 0 if there is no position |
| `message` | the whole message, as it is printed without `--json` |
| `severity` | `"error"` or `"warning"` |
| `code` | the kind of mistake: one of the codes below |
| `end_line`, `end_col` | the end of the token at the position: its line and the column after its last character |
| `fix` | what the message says to do, without the description of the mistake. Absent if the message gives no advice |

The exit status is 1 if an error was reported (with `--deny-warnings`: also a warning), 2 for a
mistake in the command line, 0 otherwise.

`E0000` and `W0000` are for messages that have no kind of their own yet. No diagnostic of the
test suite (`tests/fail`) has one; `tests/driver/diag_codes.sh` holds the code of each.

## Literals and characters

### E0101 invalid-number-literal

A number literal is malformed: a digit outside its base, no digits, too large for any integer type, or a float without digits on both sides of the point.

### E0102 invalid-escape

A string or char literal has an escape that does not exist. The escapes are \n \r \t \0 \\ \" \' and \xHH.

### E0103 unterminated-literal

A string, raw string or char literal has no closing quote on its line, or a char literal is not exactly one byte.

### E0104 unexpected-character

A character that no token starts with (often a non-ASCII character outside a string).

## Syntax

### E0201 unclosed-delimiter

A `(`, `[` or `{` is not closed. The message gives the position where it was opened.

### E0202 keyword-as-name

A keyword stands where a name is expected. Choose another name.

### E0203 unexpected-token

The parser expected one token and found another. The message names both, and often what was probably meant.

### E0204 misplaced-declaration

A declaration stands where it is not allowed: `const`, `struct`, `enum`, `test` and `extern` are top-level only; `inline` and `noinline` apply to top-level functions.

### E0205 misplaced-priv

`priv` or `pub` is used where it has no meaning or is contradictory: on `main`, a test, a field, a variant, an `extern` variable, twice, or on only some definitions of one name.

### E0206 nesting-too-deep

Blocks, operators, calls or parentheses are nested deeper than the compiler's limit (see `limits` in `alc capabilities`).

### E0207 function-syntax

A function declaration is malformed: `-> ()`, modifiers in the wrong place, `...` outside an `extern` C function, an anonymous function without named and typed parameters, or type parameters where none are allowed.

### E0208 loop-syntax

A loop is malformed: `for` without `in` (a loop on a condition is `while`), a label that names no loop, or `break`/`continue` followed by something other than a label.

## Names

### E0301 unknown-identifier

No variable, constant or function with this name is visible here. A `priv` declaration of another file is not visible.

### E0302 unknown-function

No function has this name (or none can be called as a method on this type). The message suggests a close name if there is one.

### E0303 unknown-type

No type has this name. The message suggests the AL name of types known from other languages (`int`, `string`, `float`).

### E0304 unknown-module

`use std.<name>` names a module that does not exist or is not available for the target.

### E0305 unknown-field

The type has no field (or vector component) with this name. The message lists the fields.

### E0306 unknown-variant

The enum has no variant with this name. The message lists the variants.

### E0307 duplicate-declaration

A name is declared twice in one scope, or takes the name of a builtin type, or a loop label repeats that of an enclosing loop.

### E0308 ambiguous-variant

A variant name belongs to several enums and the context does not say which. Write `Enum.Variant`.

### E0309 captured-variable

A nested or anonymous function uses a variable of the enclosing function. Functions do not capture: pass the value as a parameter.

## Types

### E0401 type-mismatch

A value has another type than the place it is used in expects. The message gives both types.

### E0402 operand-types

The operands of an operator have different types, or a type the operator does not work on. AL has no implicit conversions: convert one operand explicitly.

### E0403 value-out-of-range

An integer literal or constant does not fit in the type it is used as, or a float literal stands where an integer is expected.

### E0404 cannot-infer-type

The type of an expression cannot be inferred here. Annotate the variable (`x: T = ...`) or write the type arguments.

### E0405 invalid-conversion

A conversion `T(x)` between these types does not exist. `cast[T](x)` reinterprets bits; an enum converts from an integer only if no variant has data.

### E0406 invalid-operation

A value is indexed, sliced, iterated or called and its type does not allow it; or an index is not an integer or is known to be out of range.

### E0407 type-arguments

A generic type or function has the wrong number of type arguments, needs them written out, or instantiates itself without end.

### E0408 missing-value

A function that declares a result does not return one on every path, or an expression without a value is used as one.

### E0409 condition-not-bool

The condition of `if`, `while` or `assert` is not a `bool`. Integers are not truthy: write `x != 0`.

## Calls

### E0501 argument-count

A call or a variant has the wrong number of arguments.

### E0502 no-matching-definition

A name has several definitions and none accepts these arguments. The message lists the candidates.

### E0503 argument-type

An argument has another type than the parameter. The message gives both types; AL has no implicit conversions, so convert explicitly (`i64(x)`, `f32(x)`) or pass an address with `&`.

### E0504 function-as-value

A function is used as a value where that is not possible (it is generic or overloaded), or a nested function is assigned to.

## Match and patterns

### E0601 non-exhaustive-match

A `match` used as a value does not cover every case. The message lists the missing ones; an arm with a guard does not count.

### E0602 unreachable-pattern

An arm of a `match` can never be taken because an earlier arm has the same pattern.

### E0603 invalid-pattern

A pattern does not fit the matched value: a variant of another enum, the wrong number of fields, a tuple pattern for a non-tuple, a name bound twice or not in every alternative, or a part that is not a constant.

## Constants and compile time

### E0701 constant-not-assignable

A constant is assigned to or its address is taken. Copy it to a variable, or declare it without `const`.

### E0702 not-a-compile-time-constant

The value of a `const` is not a compile-time constant, has another type than declared, or depends on itself.

### E0703 when-condition

A `when` condition uses something that is not known at compile time. A condition is made of constants declared outside every `when`, literals, and the operators `==`, `!=`, `&&`, `||`, `!`.

### E0704 invalid-define

A `-D NAME=VALUE` option names no constant of the program, or gives a value that is not of the constant's type.

### E0705 invalid-embed

`embed` cannot read its file, or was not given a string literal path.

## Statements

### E0801 no-effect

A statement is an expression whose value is not used. Often `==` was written for `=`, or a line starts with an operator and so begins a new statement.

### E0802 loop-control

`break` or `continue` stands outside a loop, or names a label that no enclosing loop has.

### E0803 not-addressable

The address of something that has none is taken or needed: a temporary, a vector component, or the left side of `:=` is not a name.

### E0804 clone-of-pointer

`clone` of a pointer would copy the pointer, not what it points to. Write `clone(*p)`.

## The C interface and GPU layouts

### E0901 c-interface

A value or declaration cannot cross the boundary to C: a type C has no equivalent of, a variadic or struct-passing function used as a value, or a malformed `extern` declaration.

### E0902 layout-mismatch

A compile-time layout check failed: `offsetof`, `variant_count`, `std140_size`, `std430_size` or `hlsl_cbuffer_size` was given a type or field whose layout in AL differs from the one asked for.

## The program and the command line

### E1001 invalid-main

The program has no `fn main()`, or `main` is not declared as `fn main()` or `fn main() -> i64`.

### E1002 driver

A mistake in the command line, or a file that cannot be read or written. These have no position (`line` and `col` are 0).

### E1003 format

`alc fmt --check` found a file that is not in the canonical layout, or `alc fmt` could not format a file.

## Other

### E0000 other

An error that has no code of its own yet. The message says what is wrong.

## Warnings (with `-W`)

### W0000 other

A warning that has no code of its own yet.

### W0001 unused-variable

A local variable is never read. Prefix its name with `_` if that is intended.

### W0002 unreachable-code

A statement follows `return`, `break`, `continue` or a call that never returns.

### W0003 self-assignment

A variable is assigned to itself.

### W0004 non-exhaustive-match

A `match` statement does not cover every case. Add `_ => {}` if that is intended.

### W0005 no-effect

A statement computes a value that is not used.
