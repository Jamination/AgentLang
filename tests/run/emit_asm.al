// `alc build --emit-asm` prints the machine code with the mnemonics of the instructions
// (it used to cut the first three letters off every mnemonic and crash on `or`).
use std.os

fn main() {
    src := fmt("/tmp/al_emit_asm_", syscall(39), ".al")
    exe := src[..len(src) - 3]
    write_file(src, "noinline fn f(a: i64, b: i64) -> i64 { (a | b) - (a ^ b) }\nfn main() { print(f(6, 3)) }\n")
    for o0 in []bool{false, true} {
        argv := []str{"./build/alc", "build", "--emit-asm", src, "-o", exe}
        if o0 {
            argv = []str{"./build/alc", "build", "-O0", "--emit-asm", src, "-o", exe}
        }
        out, status := run_capture(argv)
        print(status, find(out, "\n    or8 ") >= 0, find(out, "\n    xor8 ") >= 0, find(out, "\n    sub8 ") >= 0, find(out, "\n    ret0") >= 0)
    }
    remove_file(src)
    remove_file(exe)
}
