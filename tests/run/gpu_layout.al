// std140_size / std430_size: the size of a struct or array in a GLSL buffer block, for the
// structs whose AL layout is that of the rules (the mismatches are tests/fail/gpu_layout.al)
struct Light {
    dir: vec3
    power: f32              // packs into the 16 bytes of the vec3, as in GLSL
    color: vec4
}

struct Ubo {
    view: mat4
    lights: [4]Light
    tint: vec3
    time: f32
    uv: vec2                // std140 rounds the block up to 16: 216 -> 224
}

struct Particle {
    pos: vec4
    vel: vec2
    life: f32
    seed: u32
}

struct Wide {
    a: u64
    b: f64
    c: i32
}

const UBO_SIZE = std140_size[Ubo]()
const PARTICLES = std430_size[[64]Particle]()

fn main() {
    print(UBO_SIZE, sizeof[Ubo](), std430_size[Ubo]())
    print(PARTICLES, std140_size[[64]Particle](), std430_size[Particle](), sizeof[Particle]())
    print(std140_size[Light](), std430_size[[8]vec4](), std430_size[[8]vec2](), std430_size[[3]f32]())
    print(std140_size[Wide](), std430_size[Wide](), sizeof[Wide]())
}
