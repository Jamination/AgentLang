// length / normalize / distance of f32 vectors whose squared length overflows (|v| > 1.8e19) or
// underflows (|v| < 1.1e-19): they used to give inf / the zero vector, and 0 / the zero vector
fn main() {
    print(length(vec3(1e20, 0.0, 0.0)), length(vec2(3e30, 4e30)), length(vec4(0.0, 0.0, 0.0, -2e25)))
    print(normalize(vec3(1e20, 0.0, 0.0)), normalize(vec2(3e30, 4e30)), normalize(vec4(1e-30, 0.0, 0.0, 0.0)))
    print(length(vec3(3e-25, 4e-25, 0.0)), normalize(vec3(3e-25, 0.0, 4e-25)), distance(vec3(-1e20, 0.0, 0.0), vec3(1e20, 0.0, 0.0)))
    print(length(vec3(1e-45, 0.0, 0.0)), normalize(vec2(0.0, -1e-45)), length(vec3(3.0e38, 3.0e38, 0.0)))
    print(normalize(vec3(0.0)), length(vec3(0.0)), normalize(vec3(1.0, 2.0, 2.0)), length(vec3(1.0, 2.0, 2.0)))
}
