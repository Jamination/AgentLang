// as in C, `...` follows at least one named parameter
extern "libc.so.6" fn printf(...) -> i32
fn main() {
    printf(ptr("x"))
}
