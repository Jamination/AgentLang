// hlsl_cbuffer_size: the size of a struct as an HLSL constant buffer, for structs whose AL
// layout is the HLSL one (tests/sys/hlsl_cbuffer.al compares with D3DCompile on Windows,
// tests/fail/hlsl_cbuffer.al has the layouts that differ)
struct Pair { x: f32, y: f32 }

struct Consts {
    mvp: mat4
    tint: vec3
    time: f32           // packs into the register of tint
    scale: vec2
    pad: vec2
    pair: Pair          // a struct starts a register: 96
    z: f32              // right after the struct, in its register
    pad2: f32
    lights: [2]vec4     // an array starts a register: 112
    count: u32
}

struct Small { a: f32, b: vec2 }    // a vec2 at 4 does not cross 16 bytes

const CONSTS_SIZE = hlsl_cbuffer_size[Consts]()

fn main() {
    print(CONSTS_SIZE, sizeof[Consts](), offsetof[Consts](pair), offsetof[Consts](z), offsetof[Consts](count))
    print(hlsl_cbuffer_size[Small](), sizeof[Small](), hlsl_cbuffer_size[[3]vec4](), hlsl_cbuffer_size[f64]())
}
