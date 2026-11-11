// C interop and module errors
P :: struct { x: i64, y: i64 }
extern "libc.so.6" takes_struct :: (p: P) -> i32
extern "libc.so.6" returns_vec :: () -> vec3
area :: (a: vec2) -> f32 { a.x * a.y }
area :: (a: vec2) -> f32 { a.y }
main :: () {
    p: P
    takes_struct(p)
    v := returns_vec()
    w := vec3(1.0, 2.0)
    x := v.q
    d: f64 = 1.0
    y := v * d
    z := &v.x
    print(area("no"))
}
