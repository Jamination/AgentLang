// hlsl_cbuffer_size: an AL layout that differs from the HLSL packing rules is a compile error
// that names the first field that differs. tests/sys/hlsl_cbuffer.al has the layouts that
// match, and prints where D3DCompile puts the fields of these ones.
struct Pair { x: f32, y: f32 }
struct Inner { a: vec4, b: f32 }
struct Big { d: f64, f: f32 }             // AL size 16, HLSL 12

struct Straddle { a: f32, b: f32, c: f32, d: vec2 }     // d: AL 12, HLSL 16 (crosses a register)
struct FloatArray { ks: [4]f32, after: f32 }            // elements 16 bytes apart in HLSL
struct StructAfterFloat { a: f32, s: Pair }             // s: AL 4, HLSL 16
struct MatAfterFloat { a: f32, m: mat4 }                // m: AL 4, HLSL 16
struct Vec4AfterFloat { a: f32, v: vec4 }               // v: AL 4, HLSL 16
struct Vec3Array { vs: [2]vec3 }
struct InnerArray { items: [2]Inner }                   // elements 20 bytes apart in AL, 32 in HLSL
struct AfterPadded { s: Big, x: f32 }                   // x: AL 16, HLSL 12
struct Flag { on: bool }
struct Small { n: u16 }
struct Ptr { p: *u8 }

const STRADDLE = hlsl_cbuffer_size[Straddle]()

fn main() {
    print(hlsl_cbuffer_size[FloatArray]())
    print(hlsl_cbuffer_size[StructAfterFloat]())
    print(hlsl_cbuffer_size[MatAfterFloat]())
    print(hlsl_cbuffer_size[Vec4AfterFloat]())
    print(hlsl_cbuffer_size[Vec3Array]())
    print(hlsl_cbuffer_size[InnerArray]())
    print(hlsl_cbuffer_size[AfterPadded]())
    print(hlsl_cbuffer_size[Flag]())
    print(hlsl_cbuffer_size[Small]())
    print(hlsl_cbuffer_size[Ptr]())
    print(hlsl_cbuffer_size[Pair](1))
}
