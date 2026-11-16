// `extern "a", "b" fn`: one library per system, one declaration for both. A build for Windows
// imports from the DLL, a Linux build from the other name (here the C library of each system).
extern "libc.so.6", "msvcrt.dll" fn strlen(s: *u8) -> u64
extern "libc.so.6", "msvcrt.dll" fn abs(x: i32) -> i32
// a lone name is used for every target (here only called on its system)
extern "kernel32.dll" fn GetCurrentProcessId() -> u32
extern "libc.so.6" fn getpid() -> i32

fn main() {
    print(strlen(ptr("hello")), abs(-7))
    pid := if TARGET_OS == Windows { i64(GetCurrentProcessId()) } else { i64(getpid()) }
    print(pid > 0)
}
