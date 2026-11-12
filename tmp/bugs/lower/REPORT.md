# Bug hunt: lower (types.al, lower*.al, lint.al, ir.al)

| id | severity | description | fixed | test |
|----|----------|-------------|-------|------|
| 01 | miscompile | `u64(x)` for float x >= 2^63 saturated to 2^63 (cvttsd2si is signed); `lower_expr.al convert` | y | tests/run/conv_float_u64 |
| 02 | doc mismatch | `hash(x)` / Map keys of vec2/vec3/vec4/quat/mat4 rejected (error inside the prelude) though `==` works; `lower_call.al hash_val` | y | tests/run/hash_vectors |

## For other areas

## Checked and found correct

## Suspicions not confirmed
