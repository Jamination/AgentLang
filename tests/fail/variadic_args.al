// other arguments the `...` of a C function cannot take, too few arguments, and a variadic
// C function as a function value
extern "libc.so.6" fn printf(format: *u8, ...) -> i32
extern "libc.so.6" fn snprintf(buf: *u8, n: i64, format: *u8, ...) -> i32
enum Shape { Circle(f64), Empty }
fn nothing() {}
fn main() {
    xs := []i64{1, 2}
    printf(ptr("%p\n"), xs)
    printf(ptr("%f\n"), vec3(1.0, 2.0, 3.0))
    printf(ptr("%d\n"), Circle(1.0))
    printf(ptr("%d\n"), nothing())
    buf: [8]u8
    snprintf(&buf[0], 8)
    f := printf
    printf()
}
