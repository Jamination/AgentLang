// a struct (or tuple, array) cannot be passed to the `...` of a C function
extern "libc.so.6" fn printf(format: *u8, ...) -> i32
struct Point { x: i32, y: i32 }
fn main() {
    p := Point{x: 1, y: 2}
    printf(ptr("%d %d\n"), p)
    printf(ptr("%d %d\n"), (1, 2))
    a := [2]i32{1, 2}
    printf(ptr("%d\n"), p.x, a)
}
