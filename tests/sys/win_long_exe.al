// Programs whose path is longer than MAX_PATH (260 units), started by run, run_capture,
// run_capture_all, spawn and spawn with a Launch (files, a group). The file functions took such
// paths (extended-length `\\?\` paths, see sys/win_files and sys/win_long_cwd), and so did the
// search for the program, but CreateProcessW got the path as written and failed. The program is
// a copy of this one, as a path over 260 units written out (absolute and relative), and as a
// short relative path from a deep working directory that becomes one over 260 units.
use std.os

extern "kernel32.dll" fn SetCurrentDirectoryA(path: *u8) -> i32
extern "kernel32.dll" fn GetModuleFileNameA(module: i64, buf: *u8, n: u32) -> u32
extern "kernel32.dll" fn GetModuleHandleA(name: *u8) -> i64
extern "kernel32.dll" fn GetProcAddress(module: i64, name: *u8) -> i64

fn why() -> str { error_text(io_error()) }

// what the copies do: print their arguments and end with status 3
fn child(a: []str) -> i64 {
    print(fmt("child ", join(a, "|")))
    return 3
}

// starts the program at `exe` in every way std.os has; `out` is a scratch file
fn start_all(what: str, exe: str, out: str) {
    full := if len(exe) > 1 && exe[1] == ':' { len(exe) } else { len(current_dir()) + 1 + len(exe) }
    print(what, "written", if len(exe) > 260 { "over" } else { "under" }, "260 units, absolute over 260:", full > 260)
    // (the copy prints to this program's standard output: its line comes first)
    st := run([]str{exe, "child", "run"})
    print("  run", st, why())
    text, cst := run_capture([]str{exe, "child", "a b"})
    print("  run_capture", cst, why(), trim_right(text, "\n"))
    text, cst = run_capture_all([]str{exe, "child", "all"})
    print("  run_capture_all", cst, why(), trim_right(text, "\n"))
    p, ok := spawn([]str{exe, "child", "spawn"})
    e := why()
    st = wait(p)
    print("  spawn", ok, e, st)
    for group in []bool{false, true} {
        remove_file(out)
        q, qok := spawn([]str{exe, "child", "launch"}, Launch{stdout: out, group: group})
        e := why()
        st := wait(q)
        text, _ := read_file(out)
        print("  spawn with Launch, group", group, qok, e, st, trim_right(text, "\n"))
    }
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
        return child(a[2..])
    }
    buf: [1024]u8
    n := i64(GetModuleFileNameA(0, &buf[0], 1024))
    self, ok := read_file(buf[..n])
    print("self", ok, len(self) > 0)

    root := current_dir()
    base := fmt("tmp\\win_long_exe_", process_id())
    make_dir("tmp")
    make_dir(base)
    // directories of 40 units below base until the relative path is over 260 units long
    dir := base
    k := 0
    while len(dir) < 270 {
        dir = fmt(dir, "\\", repeat(fmt(k % 10), 40))
        make_dir(dir)
        k += 1
    }
    rel := fmt(dir, "\\child.exe")
    abs := fmt(root, "\\", rel)
    print("copy", write_file(rel, self), why(), file_exists(abs))
    out := fmt(base, "\\out.txt")
    start_all("absolute:", abs, out)
    start_all("relative:", rel, out)

    // a working directory of about 210 units (its own limit is 258 without LongPathsEnabled)
    // and a short relative path below it: about 70 units, over 260 once absolute
    cwd := base
    c := 0
    while len(root) + 1 + len(cwd) < 210 {
        cwd = fmt(cwd, "\\", repeat("w", max(1, min(40, 210 - (len(root) + 2 + len(cwd))))))
        make_dir(cwd)
        c += 1
    }
    print("deep working directory", SetCurrentDirectoryA(cstr(cwd)) != 0, len(current_dir()) >= 210 && len(current_dir()) < 258)
    sub := repeat("s", 40)
    short := fmt(sub, "\\", repeat("e", 25), ".exe")
    make_dir(sub)
    print("copy", write_file(short, self), why(), len(current_dir()) + 1 + len(short) > 260)
    start_all("short relative:", short, "out.txt")
    remove_file("out.txt")
    remove_file(short)
    remove_dir(sub)
    print("back", SetCurrentDirectoryA(cstr(root)) != 0)

    for i in 0..c {
        remove_dir(cwd)
        cwd = path_dir(cwd)
    }
    remove_file(rel)
    remove_file(out)
    for i in 0..k {
        remove_dir(dir)
        dir = path_dir(dir)
    }
    print("cleanup", remove_dir(base), why())
    0
}
