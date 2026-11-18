// arm64 (AAPCS64): structs cross the C boundary by value, vectors do not (also inside a
// struct); a C function that takes or returns a struct cannot be a function value
struct P { x: i64, y: i64 }
struct V { a: vec3 }
struct E {}
extern "libx.so" fn takes(p: P) -> i32
extern "libx.so" fn vec_in_struct(v: V) -> i32
extern "libx.so" fn empty(e: E) -> i32
extern "libx.so" fn returns() -> P
fn main() {
    f := takes
    g := returns
    print(vec_in_struct(V{}), empty(E{}), takes(P{x: 1, y: 2}))
}
