// `extern LIB fn`: the library is a str constant, chosen per system with `when`. One declaration
// serves both systems (here the C library of each).
when TARGET_OS == Windows {
    priv const LIBC = "msvcrt.dll"
} else {
    priv const LIBC = "libc.so.6"
}
extern LIBC fn strlen(s: *u8) -> u64
extern LIBC fn abs(x: i32) -> i32
// a literal name is used for every target (here only called on its system)
extern "kernel32.dll" fn GetCurrentProcessId() -> u32
extern "libc.so.6" fn getpid() -> i32

fn main() {
    print(strlen(ptr("hello")), abs(-7))
    pid := if TARGET_OS == Windows { i64(GetCurrentProcessId()) } else { i64(getpid()) }
    print(pid > 0)
}
