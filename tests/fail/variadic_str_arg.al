// a str is a slice (pointer and length): C wants `ptr(s)`
extern "libc.so.6" fn printf(format: *u8, ...) -> i32
fn main() {
    name := "world"
    printf(ptr("hello %s\n"), name)
    printf(ptr("%s\n"), "literal")
}
