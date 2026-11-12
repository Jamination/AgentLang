// length / normalize of f32 vectors whose squared length overflows or underflows f32:
// length(vec3(1e20, 0, 0)) was inf, normalize(vec3(1e20, 0, 0)) the zero vector, length(vec3(3e-25, 4e-25, 0)) 0.
// expected: 1e20 vec3(1.0, 0.0, 0.0) 5e-25   actual (before the fix): inf vec3(0.0, 0.0, 0.0) 0.0
fn main() {
    print(length(vec3(1e20, 0.0, 0.0)), normalize(vec3(1e20, 0.0, 0.0)), length(vec3(3e-25, 4e-25, 0.0)))
}
