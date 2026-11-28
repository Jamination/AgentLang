# Defined behaviour

The questions a C programmer has to look up, and AL's answer to each. None of them is undefined
or left to the target in AL, except where the table says so. `alc capabilities` prints the same
table as JSON (`semantics`); the full rules are in the [language reference](LANGUAGE.md).

| Question | AL's answer | Example |
|---|---|---|
| Signed integer overflow | Wraps around (two's complement). `sat_add` / `sat_sub` saturate instead | `0x7FFF_FFFF_FFFF_FFFF + 1` is the smallest `i64` |
| Unsigned integer overflow | Wraps around | `u8(250) + 10` is 4 |
| Integer division | Truncates toward zero; `%` has the sign of the left operand | `-7 / 2` is -3, `-7 % 2` is -1, `7 % -2` is 1 |
| Integer division or remainder by zero | `panic: division by zero at file:line`, exit status 1 | |
| MIN / -1 | Yields MIN; no trap | |
| Shift count not less than the bit width | The count is taken modulo the bit width | `1 << 65` is 2 for an `i64` |
| Right shift of a negative number | Arithmetic for signed types, logical for unsigned | `-16 >> 2` is -4 |
| Index or slice bound out of range | `panic: index out of bounds at file:line`, exit status 1 | |
| Nil dereference, stack overflow | `panic: memory fault`, exit status 1, with a stack trace | |
| Uninitialized variable or memory | Cannot be read: every variable and every allocation starts zeroed | `x: i64` is 0 |
| Order of evaluation | Operands and arguments left to right, each once; `&&` and `\|\|` short-circuit | `f(a(), b())` calls `a` first |
| Implicit conversions | None between types. An untyped literal takes the type its context asks for | `i + 1.5` with `i: i64` is a compile error |
| Integer to narrower integer | Keeps the low bits | `i8(200)` is -56 |
| Integer to wider integer | The source type decides: signed sign-extends, unsigned zero-extends | `i64(u8(200))` is 200 |
| Float to integer | Truncates toward zero; NaN and values beyond `i64` give `0x8000000000000000` | `i64(-3.9)` is -3 |
| Char signedness | There is no char type: a character literal and a byte of a `str` are `u8` | |
| Size of int | There is no `int`. `i8` to `i64` and `u8` to `u64` have the same size on every target; an untyped integer literal is `i64`, a float literal `f32` | |
| Missing return | Compile error | |
| Non-exhaustive match | Compile error when the `match` is used as a value, a warning (`-W`) when it is a statement | |

## What is not defined

| Question | AL's answer |
|---|---|
| Use of released memory | Not detected in a normal run: the memory reads as zeroes or as whatever was allocated there next. With `ALC_CHECK_MEMORY=1` it is a panic. See [MEMORY.md](MEMORY.md) |
| Data race | Undefined. Nothing checks that shared data is guarded |
| Out-of-range index, division by zero with `--unchecked` | Undefined: the option removes the checks |

The examples of the first table were run with the compiler.
