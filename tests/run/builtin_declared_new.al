// The builtins added late (offsetof, ...) shadow nothing: a program that declares functions of
// those names uses its own wherever they accept the arguments, also in constants, and the
// builtin elsewhere (see tests/run/builtin_overload.al for the older builtins).
struct Vertex { pos: vec3, uv: vec2 }
struct Cb { pos: vec4, uv: vec2 }
enum Dir { N, E, S, W }

fn offsetof(s: str) -> i64 { len(s) * 100 }
fn hlsl_cbuffer_size[T](n: i64) -> i64 { sizeof[T]() * n }
fn variant_count(s: str) -> i64 { len(split(s, ',')) }
fn rgba8(r: i64, g: i64, b: i64, a: i64) -> i64 { r + g + b + a }     // the program's: not constant
fn rgb8(name: str) -> u32 { if name == "red" { 0xFF0000FF } else { 0 } }

const UV = offsetof[Vertex](uv)          // the builtin: the declared offsetof takes no type argument
const CB = hlsl_cbuffer_size[Cb]()   // the builtin: the declared one takes an argument
const DIRS = variant_count[Dir]()
const RED = rgb8(255, 0, 0)               // the library's rgb8: the program's takes a str

fn main() {
    print(offsetof("ab"), offsetof[Vertex](uv), UV)
    print(hlsl_cbuffer_size[Cb](2), hlsl_cbuffer_size[Cb](), CB)
    print(variant_count("a,b"), variant_count[Dir](), DIRS, Dir(2))
    print(rgba8(1, 2, 3, 4), rgb8("red") == RED, RED)
}
