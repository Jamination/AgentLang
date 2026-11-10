// C interop and module errors
struct P { x i64, y i64 }
extern "libc.so.6" fn takes_struct(p P) i32
extern "libc.so.6" fn returns_vec() vec3
fn area(a vec2) f32 { a.x * a.y }
fn area(a vec2) f32 { a.y }
fn main() {
    var p P
    takes_struct(p)
    v := returns_vec()
    w := vec3(1.0, 2.0)
    x := v.q
    var d f64 = 1.0
    y := v * d
    z := &v.x
    print(area("no"))
}
