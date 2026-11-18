// The builtins added late (offsetof, ...) shadow nothing: a program that declares functions of
// those names uses its own wherever they accept the arguments, also in constants, and the
// builtin elsewhere (see tests/run/builtin_overload.al for the older builtins).
struct Vertex { pos: vec3, uv: vec2 }
struct Cb { pos: vec4, uv: vec2 }

fn offsetof(s: str) -> i64 { len(s) * 100 }
fn hlsl_cbuffer_size[T](n: i64) -> i64 { sizeof[T]() * n }

const UV = offsetof[Vertex](uv)          // the builtin: the declared offsetof takes no type argument
const CB = hlsl_cbuffer_size[Cb]()   // the builtin: the declared one takes an argument

fn main() {
    print(offsetof("ab"), offsetof[Vertex](uv), UV)
    print(hlsl_cbuffer_size[Cb](2), hlsl_cbuffer_size[Cb](), CB)
}
