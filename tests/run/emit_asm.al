// `alc build --emit-asm` prints the machine code with the mnemonics of the instructions
// (it used to cut the first three letters off every mnemonic and crash on `or`).
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
    src := fmt("tmp/al_emit_asm_", process_id(), ".al")
    exe := src[..len(src) - 3]
    write_file(src, "noinline fn f(a: i64, b: i64) -> i64 { (a | b) - (a ^ b) }\nfn main() { print(f(6, 3)) }\n")
    for o0 in []bool{false, true} {
        argv := []str{ALC, "build", "--emit-asm", src, "-o", exe}
        if o0 {
            argv = []str{ALC, "build", "-O0", "--emit-asm", src, "-o", exe}
        }
        out, status := run_capture(argv)
        print(status, find(out, "\n    or8 ") >= 0, find(out, "\n    xor8 ") >= 0, find(out, "\n    sub8 ") >= 0, find(out, "\n    ret0") >= 0)
    }
    remove_file(src)
    remove_file(exe)
}
