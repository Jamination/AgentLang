// offsetof[T](field): the offset of a field in bytes, a constant like sizeof[T]() (the
// mistakes are tests/fail/offsetof.al)
struct Vertex {
    pos: vec3
    uv: vec2
    color: u32
}

struct Light {
    dir: vec3
    power: f32
}

struct Scene {
    flags: u8
    lights: [4]Light
    tint: vec4
    pair: Pair[u8, f64]
}

struct Pair[A, B] {
    first: A
    second: B
}

priv fn helper() -> i64 { 1 }

struct Desc { offset: u32 }

struct Uses {
    a: u8
    helper: i64             // a field named like a private function of the file
}

const UV = offsetof[Vertex](uv)
const N = 2
const LAST = offsetof[Scene](lights[N + 1].power)
const OFFSETS = [3]u32{u32(offsetof[Vertex](pos)), u32(UV), u32(offsetof[Vertex](color))}
priv const COLOR_END = offsetof[Vertex](color) + 4

fn main() {
    print(OFFSETS, sizeof[Vertex](), COLOR_END == sizeof[Vertex]())
    print(offsetof[Scene](lights), offsetof[Scene](lights[1]), offsetof[Scene](lights[1].dir), LAST, offsetof[Scene](tint))
    print(offsetof[Scene](pair), offsetof[Scene](pair.second), offsetof[Pair[u8, f64]](second), offsetof[Pair[u8, u16]](second))
    pos := 7                 // a local of the field's name: the argument is a field, never evaluated
    print(offsetof[Vertex](pos), pos, offsetof[Uses](helper), helper())
    a: [offsetof[Vertex](color)]u8
    print(len(a), Desc{offset: UV}, Desc{offset: u32(offsetof[Vertex](color))})
}
