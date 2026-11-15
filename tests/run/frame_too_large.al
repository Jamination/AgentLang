// A function whose locals need more than 2 GiB of stack is reported. The frame size used to
// wrap around in 32 bits: the function then did not reserve its frame at all and its locals
// overwrote the frames of its callers. (The frame is 2147483656 bytes on Linux and 2147483696 on Windows,
// which adds the 32 bytes that every call reserves for its callee.)
use std.os

// the compiler for the system this program runs on, as ./build.sh builds it
when TARGET_OS == Windows {
    const ALC = "build/alc.exe"
} else {
    const ALC = "./build/alc"
}

fn main() {
    if !file_exists(ALC) {
        print(fmt("no compiler at ", ALC, " (./build.sh builds it)"))
        exit(77)
    }
    make_dir("tmp")
    src := fmt("tmp/al_frame_too_large_", process_id(), ".al")
    exe := src[..len(src) - 3]
    write_file(src, "noinline fn big(n: i64) -> i64 {\n    a: [268435455]i64\n    a[n] = 5\n    a[n] + a[0]\n}\nfn main() { print(big(3)) }\n")
    out, status := run_capture_all([]str{ALC, "build", src, "-o", exe})
    print(status, find(out, "error: function `big` needs a stack frame of 21474836") >= 0, find(out, " bytes; at most 2 GiB are possible") >= 0)
    remove_file(src)
    remove_file(exe)
}
