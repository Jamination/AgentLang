# Bug hunt: lower (types.al, lower*.al, lint.al, ir.al)

| id | severity | description | fixed | test |
|----|----------|-------------|-------|------|
| 01 | miscompile | `u64(x)` for float x >= 2^63 saturated to 2^63 (cvttsd2si is signed); `lower_expr.al convert` | y | tests/run/conv_float_u64 |
| 02 | doc mismatch | `hash(x)` / Map keys of vec2/vec3/vec4/quat/mat4 rejected (error inside the prelude) though `==` works; `lower_call.al hash_val` | y | tests/run/hash_vectors |
| 03 | hang | generic recursion with growing type args (`fn f[T](x: T) { f([]T{x}) }`, `struct B[T] { x: *B[(T, T)] }`, enum, mutual g/h) never terminates; `lower.al inst_fn/inst_struct/inst_enum`; now an error when a type argument is >40 deep or >4000 nodes (`types.al intern` tracks shape) | y | tests/fail/generic_explosion |

## For other areas

## Checked and found correct

## Suspicions not confirmed
