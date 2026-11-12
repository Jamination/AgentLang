// A function whose locals need more than 2 GiB of stack is reported. The frame size used to
// wrap around in 32 bits: the function then did not reserve its frame at all and its locals
// overwrote the frames of its callers.
use std.os

fn main() {
    src := fmt("/tmp/al_frame_too_large_", syscall(39), ".al")
    exe := src[..len(src) - 3]
    write_file(src, "noinline fn big(n: i64) -> i64 {\n    a: [268435455]i64\n    a[n] = 5\n    a[n] + a[0]\n}\nfn main() { print(big(3)) }\n")
    out, status := run_capture_all([]str{"./build/alc", "build", src, "-o", exe})
    print(status, find(out, "error: function `big` needs a stack frame of 2147483656 bytes") >= 0)
    remove_file(src)
    remove_file(exe)
}
