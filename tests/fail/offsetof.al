// offsetof[T](field): a path that names no field is a compile error that names the fields of
// the struct (tests/run/offsetof.al has the valid forms)
struct Vertex {
    pos: vec3
    uv: vec2
    color: u32
}

struct Mesh {
    verts: [8]Vertex
    first: *Vertex
}

struct Empty {}

const BAD = offsetof[Vertex](normal)

fn main() {
    i := 1
    print(offsetof[Mesh](verts[1].uvs))
    print(offsetof[Mesh](verts[8]))
    print(offsetof[Mesh](verts[i]))
    print(offsetof[Mesh](first.pos))
    print(offsetof[Mesh](verts.pos))
    print(offsetof[Vertex](pos.x))
    print(offsetof[vec3](x))
    print(offsetof[Vertex]("uv"))
    print(offsetof[Empty](a))
    print(offsetof[Vertex]())
    print(offsetof(uv))
}
