# math

Always available (no `use`). Scalar functions for `f32` and `f64`, vector / quaternion / matrix
functions on the built-in types, geometry tests, easing curves and colour helpers. Everything
is written in AL: no libm, so programs stay static.

Every function exists for each type it makes sense for; the call picks by argument type
(`length(v2)`, `length(v3)`, `sin(x32)`, `sin(x64)`). A literal next to an `f32` is an `f32`.

```
// examples/math_demo.al
eye := vec3(3.0, 2.0, 5.0)
view := look_at(eye, vec3(0.0), vec3(0.0, 1.0, 0.0))
proj := perspective(radians(60.0), 16.0 / 9.0, 0.1, 100.0)
spin := quat_axis_angle(vec3(0.0, 1.0, 0.0), radians(45.0))
model := mat4_trs(vec3(0.0, 0.5, 0.0), spin, vec3(1.0))
mvp := proj * view * model
ndc := project_point(mvp, vec3(1.0, 1.0, 1.0))             // 0.237 0.411 0.981
t, hit := ray_hit(Ray{origin: eye, dir: normalize(vec3(0.0) - eye)}, Aabb{min: vec3(-1.0), max: vec3(1.0)})
```

Output of the full example:

```
corner in clip space: 0.237 0.411 0.981
ray hits the cube: true at distance 4.932
halfway rotation: 22.5 degrees around y=1.0
sin(30 deg) = 0.500000  atan2(1, 1) = 0.785398
```

## Constants

`PI`, `TAU`, `HALF_PI`, `E`, `DEG2RAD`, `RAD2DEG`, `EPSILON` (1e-6), `INF`, `NAN`. They are
untyped: they become `f32` or `f64` from context.

## Scalars (`f32` and `f64`)

| Functions | |
|-----------|---|
| `sin cos tan asin acos atan atan2(y, x)` | radians; `sin_cos(x)` returns `(sin, cos)` in one go |
| `exp log log2 pow(x, y) fmod(x, y)` | C semantics for zero, negative, infinite and NaN arguments |
| `sqrt fabs fmin fmax` | built in (one instruction) |
| `floor ceil round trunc fract` | exact; `round` rounds halves away from zero |
| `sign clamp saturate` | `saturate` clamps to 0..1; `clamp` also for `i64` |
| `lerp(a, b, t) inv_lerp(a, b, v) remap(x, in_lo, in_hi, out_lo, out_hi)` | |
| `smoothstep(e0, e1, x) step(edge, x)` | |
| `radians degrees wrap_angle` | `wrap_angle` brings an angle into [-PI, PI] |
| `approx_eq(a, b)`, `approx_eq(a, b, eps)` | relative tolerance `EPSILON * max(1, \|a\|, \|b\|)` or a given absolute one |
| `is_pow2 next_pow2 align_up` | `i64` helpers |

Accuracy, measured by `tests/std/math_scalar.al` against the C library on 160 inputs per
function and precision (including huge arguments, denormals, infinities and NaN): every
transcendental function is within 1 ulp in both `f32` and `f64`; `fmod` is exact. The test
allows 2 ulp. The `f32` versions are single-precision kernels, not `f64` round trips.

## Vectors (`vec2`, `vec3`, `vec4`)

| Functions | |
|-----------|---|
| `dot cross length length_sq distance` | `cross` of two `vec2` is the z of the 3D cross product |
| `normalize` | the zero vector stays zero |
| `lerp min max clamp abs floor ceil fract` | lane-wise |
| `min_component max_component` | |
| `reflect(v, n) refract(v, n, eta) project(a, b) angle_between(a, b)` | `refract` returns zero on total internal reflection |
| `perp(v) rotate(v, angle)` | `vec2`: counter-clockwise |
| `approx_eq` | every lane |

They are written with vector operators and compile to packed SSE code.

## Quaternions

`quat` is `(x, y, z, w)`; `q * r` composes (r first), `q * v` rotates a `vec3`.

| Functions | |
|-----------|---|
| `quat_identity()` `quat_axis_angle(axis, angle)` | axis must be unit length |
| `quat_euler(pitch, yaw, roll)` / `to_euler(q)` | roll around Z first, then pitch around X, then yaw around Y |
| `quat_look_rotation(forward, up)` | turns -Z into `forward` |
| `normalize conjugate inverse dot` | |
| `slerp(a, b, t)` `nlerp(a, b, t)` | shorter arc; `nlerp` is cheaper but not constant speed |
| `axis_angle(q)` | returns `(axis, angle)` |

## Matrices

`mat4` is column-major: `m[c]` is a column, `m * v` transforms a column vector, and
`a * b` applies `b` first.

| Functions | |
|-----------|---|
| `mat4_identity()` `translate(v)` `scale(v)` | |
| `rotate_x(a)` `rotate_y(a)` `rotate_z(a)` `rotate_axis(axis, a)` `mat4_from_quat(q)` | right-handed, counter-clockwise looking down the axis |
| `mat4_trs(t, r, s)` | translate * rotate * scale |
| `transpose determinant inverse inverse_affine` | `inverse_affine` for matrices whose last row is 0 0 0 1 |
| `look_at(eye, target, up)` | view space: +X right, +Y up, -Z forward |
| `perspective(fovy, aspect, near, far)` | clip depth 0 at near, 1 at far (D3D / Metal / Vulkan range), +Y up |
| `perspective_vk(...)` | the same with Y flipped: Vulkan's clip space has +Y down |
| `ortho(left, right, bottom, top, near, far)` | depth 0..1 |
| `transform_point(m, p)` `transform_dir(m, d)` | w = 1 / w = 0, no divide |
| `project_point(m, p)` | with the perspective divide |

## Geometry

```
struct Aabb { min: vec3, max: vec3 }      struct Ray { origin: vec3, dir: vec3 }
struct Sphere { center: vec3, radius: f32 }   struct Plane { normal: vec3, d: f32 }         // dot(normal, p) == d
```

| Functions | |
|-----------|---|
| `contains(aabb, p)` `contains(sphere, p)` | |
| `intersects(aabb, aabb)` `intersects(sphere, sphere)` | touching counts |
| `aabb_union(a, b)` | |
| `closest_point(aabb \| sphere \| plane \| ray, p)` | |
| `ray_hit(ray, aabb \| sphere \| plane) -> (f32, bool)` | distance along the ray (0 if it starts inside) and whether it hits |

## Easing (`f32`, t in 0..1)

`ease_in_quad ease_out_quad ease_in_out_quad ease_in_cubic ease_out_cubic ease_in_out_cubic
ease_out_elastic ease_out_bounce ease_out_back`. All map 0 to 0 and 1 to 1.

## Colour

`rgb_to_hsv(vec3) hsv_to_rgb(vec3)` (all components 0..1), `srgb_to_linear linear_to_srgb`
(`f32` or `vec3`), `color_u32(vec4) -> u32` (RGBA8, red in the lowest byte, which is the byte
order of an RGBA framebuffer) and `color_vec4(u32)`.

## Tests

`tests/std/math_scalar.al` (generated by `tests/gen/math_ref.py`), `math_basic.al`,
`math_linalg.al`, `math_geom.al`.
