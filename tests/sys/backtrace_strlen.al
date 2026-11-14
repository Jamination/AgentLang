// a memory fault inside the C library (a bad pointer passed to strlen): the trace starts in the C
// library and goes on with the frames of the program
use std.libc

noinline fn measure(p: *u8) -> i64 {
    return strlen(p) + 1
}

fn main() {
    print("start")
    print(measure(cast[*u8](8 * len(args()))))
}
