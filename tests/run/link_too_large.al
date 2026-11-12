// Global variables that do not fit below 2 GiB (the code reaches them with 32-bit
// displacements) are reported; the linker used to stop with "assertion failed at
// src/elf.al: relocation out of range".
use std.os

fn main() {
    src := fmt("/tmp/al_link_too_large_", syscall(39), ".al")
    exe := src[..len(src) - 3]
    write_file(src, "g1: [200000000]i64\ng2: [200000000]i64\nfn main() { g1[5] = 1; g2[5] = 2; print(g1[5] + g2[5]) }\n")
    out, status := run_capture_all([]str{"./build/alc", "build", src, "-o", exe})
    print(status, find(out, "error: the program's code and global variables take") >= 0, find(out, "assertion") >= 0)
    remove_file(src)
    remove_file(exe)
}
