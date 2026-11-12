// misuse of `extern "lib" name: T` (C variables)
extern "libc.so.6" optind: i32 = 3
extern "libc.so.6" opterr := 1
priv extern "libc.so.6" environ: **u8
fn main() {
    extern "libc.so.6" stdin: *u8
    print(optind, opterr, environ)
}
