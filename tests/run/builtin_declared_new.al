// The builtins added late (offsetof, ...) shadow nothing: a program that declares functions of
// those names uses its own wherever they accept the arguments, also in constants, and the
// builtin elsewhere (see tests/run/builtin_overload.al for the older builtins).
struct Vertex { pos: vec3, uv: vec2 }
struct Cb { pos: vec4, uv: vec2 }
enum Dir { N, E, S, W }

fn offsetof(s: str) -> i64 { len(s) * 100 }
fn hlsl_cbuffer_size[T](n: i64) -> i64 { sizeof[T]() * n }
fn variant_count(s: str) -> i64 { len(split(s, ',')) }

const UV = offsetof[Vertex](uv)          // the builtin: the declared offsetof takes no type argument
const CB = hlsl_cbuffer_size[Cb]()   // the builtin: the declared one takes an argument
const DIRS = variant_count[Dir]()

fn main() {
    print(offsetof("ab"), offsetof[Vertex](uv), UV)
    print(hlsl_cbuffer_size[Cb](2), hlsl_cbuffer_size[Cb](), CB)
    print(variant_count("a,b"), variant_count[Dir](), DIRS, Dir(2))
}
