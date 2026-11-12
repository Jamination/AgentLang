# Bug hunt: lower (types.al, lower*.al, lint.al, ir.al)

| id | severity | description | fixed | test |
|----|----------|-------------|-------|------|
| 01 | miscompile | `u64(x)` for float x >= 2^63 saturated to 2^63 (cvttsd2si is signed); `lower_expr.al convert` | y | tests/run/conv_float_u64 |
| 02 | doc mismatch | `hash(x)` / Map keys of vec2/vec3/vec4/quat/mat4 rejected (error inside the prelude) though `==` works; `lower_call.al hash_val` | y | tests/run/hash_vectors |
| 03 | hang | generic recursion with growing type args (`fn f[T](x: T) { f([]T{x}) }`, `struct B[T] { x: *B[(T, T)] }`, enum, mutual g/h) never terminates; `lower.al inst_fn/inst_struct/inst_enum`; now an error when a type argument is >40 deep or >4000 nodes (`types.al intern` tracks shape) | y | tests/fail/generic_explosion |
| 04 | miscompile | `match x { 0.0 => ..}` on a float scrutinee used integer `Eq` (bitwise): -0.0 did not match `0.0`; at -O0 even `1.5` did not match `1.5`; `lower_match.al pat_test` | y | tests/run/match_float_const |
| 05 | wrong output | `--emit-ir` printed op names with two letters cut off (`ram` for Param, `` for Eq), relic of when enums printed with a prefix; `ir.al ir_print_func` | y | (manual) |
| 06 | miscompile | constant folding ignored the type of typed constants: `const A: u64 = 0xFFFF_FFFF_FFFF_FFFF`, then `A / 2` = 0, `A > 5` = false, `A >> 1` = -1, `L % 3` negative, `f64(A)` = -1.0, `-G`/`~G` of a u8 not wrapped, `S8 >> 9` count mod 64 not 8; `u64(1.5e19)` saturated; out-of-range float->int differed from run time; an unannotated constant whose value has a fixed integer type (`const C = u64(x)`, `const D = A / 2`) is now of that type; `lower.al const_eval`/`const_named` (`const_int_ty`, `const_bin_typed`) | y | tests/run/const_typed_fold |
| 07 | invalid accepted | `const U: u8 = 256`, `U: u8 = 256` (global), `[2]u8{1, 300}` in constants/globals, `[2]u8{N, 1}` / `const F: f64 = N` with `N: i64` were silently truncated/converted; in a function they are errors; `lower.al const_named`/`const_init` | y | tests/fail/const_typed_range |

## For other areas

## Checked and found correct

## Suspicions not confirmed
