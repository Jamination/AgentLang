// The builtins added late (offsetof, ...) shadow nothing: a program that declares functions of
// those names uses its own wherever they accept the arguments, also in constants, and the
// builtin elsewhere (see tests/run/builtin_overload.al for the older builtins).
struct Vertex { pos: vec3, uv: vec2 }

fn offsetof(s: str) -> i64 { len(s) * 100 }

const UV = offsetof[Vertex](uv)          // the builtin: the declared offsetof takes no type argument

fn main() {
    print(offsetof("ab"), offsetof[Vertex](uv), UV)
}
