// std140_size / std430_size: an AL layout that differs from the rules is a compile error that
// names the field (tests/run/gpu_layout.al has the structs that match)
struct Shift {
    scale: f32
    offset: vec3            // AL: offset 4; std140 and std430: 16
}

struct Floats {
    ks: [4]f32              // std140: elements 16 bytes apart
}

struct Flag {
    on: bool
}

struct Inner {
    a: vec4
    b: f32                  // AL size 20; an array element of 32 bytes in std430
}

struct Outer {
    items: [2]Inner
}

struct Ptr {
    p: *u8
}

const A = std140_size[Shift]()

fn main() {
    print(A)
    print(std430_size[Shift]())
    print(std140_size[Floats]())
    print(std430_size[Flag]())
    print(std430_size[Outer]())
    print(std430_size[[3]vec3]())
    print(std140_size[Ptr]())
    print(std430_size[u8]())
}
