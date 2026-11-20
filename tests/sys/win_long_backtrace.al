// A stack trace through a DLL whose path is over 260 units: the frames of the DLL are named by
// its file name, which came from GetModuleFileNameW with a buffer of 260 units, so the name was
// the end of a path cut short (a directory's name, or part of it). The program copies itself and
// its DLL (win_long_backtrace.c, built next to it by the test runner) into a directory over 260
// units deep, runs the copy, whose callback panics, and checks the trace.
use std.os

extern "win_long_backtrace.dll" fn run_each(f: fn(i32) -> i32, n: i32) -> i32
extern "kernel32.dll" fn GetModuleFileNameA(module: i64, buf: *u8, n: u32) -> u32
extern "kernel32.dll" fn GetModuleHandleA(name: *u8) -> i64
extern "kernel32.dll" fn GetProcAddress(module: i64, name: *u8) -> i64

fn item(i: i32) -> i32 {
    assert i != 3, "item 3 is bad"
    return i * 2
}

fn main() -> i64 {
    // Wine (11.22) starts no program whose path is 260 units or more, in any form (as written
    // or extended-length): only Windows itself can run this test
    if GetProcAddress(GetModuleHandleA(cstr("ntdll.dll")), cstr("wine_get_version")) != 0 {
        print("Wine starts no program whose path is over MAX_PATH: runs on Windows (tests\\run.bat)")
        exit(77)
    }
    a := args()
    if len(a) > 1 && a[1] == "child" {
        print(run_each(item, 6))
        return 0
    }
    buf: [1024]u8
    n := i64(GetModuleFileNameA(0, &buf[0], 1024))
    exe := buf[..n]
    self, ok := read_file(exe)
    dll, dok := read_file(path_join(path_dir(exe), "win_long_backtrace.dll"))
    print("self and DLL", ok, dok)

    root := current_dir()
    base := fmt("tmp\\win_long_backtrace_", process_id())
    make_dir("tmp")
    make_dir(base)
    dir := base
    k := 0
    while len(root) + 1 + len(dir) < 290 {
        dir = fmt(dir, "\\", repeat(fmt(k % 10), 40))
        make_dir(dir)
        k += 1
    }
    copy := fmt(root, "\\", dir, "\\child.exe")
    lib := fmt(root, "\\", dir, "\\win_long_backtrace.dll")
    print("copies", write_file(copy, self), write_file(lib, dll), len(lib) > 260)
    out, st := run_capture_all([]str{copy, "child"})
    print("status", st)
    print("assertion", find(out, "assertion failed at ") >= 0 && find(out, "item 3 is bad") >= 0)
    print("DLL frames named", find(out, "  at win_long_backtrace.dll each\n") >= 0, find(out, "  at win_long_backtrace.dll run_each\n") >= 0)
    if find(out, "  at win_long_backtrace.dll each\n") < 0 {
        eprint(out)
    }

    remove_file(copy)
    remove_file(lib)
    for i in 0..k {
        remove_dir(dir)
        dir = path_dir(dir)
    }
    print("cleanup", remove_dir(base))
    0
}
