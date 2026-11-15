// Processes on Windows: what only Windows has. The command line (arguments quoted so that the
// Microsoft C library splits them as args() does), programs found with ".exe" added and
// through PATH, batch files, the status of a program that an exception ended, kill, a closed
// standard output, environment names without regard to case. The children are this program.
// (What every target has is in std/os_run, std/os_spawn and std/portable_process.)
use std.os

extern "kernel32.dll" fn ExitProcess(code: u32)
extern "kernel32.dll" fn CreatePipe(r: *i64, w: *i64, security: i64, size: u32) -> i32
extern "kernel32.dll" fn CloseHandle(h: i64) -> i32
extern "kernel32.dll" fn SetStdHandle(which: u32, h: i64) -> i32
extern "kernel32.dll" fn WideCharToMultiByte(cp: u32, flags: u32, w: *u16, n: i32, out: *u8, cap: i32, def: i64, used: i64) -> i32
// the arguments as a C program's main gets them
extern "msvcrt.dll" fn __wgetmainargs(argc: *i32, argv: ***u16, env: ***u16, wildcards: i32, startinfo: *i32) -> i32

fn why() -> str { error_text(io_error()) }

fn num(s: str) -> i64 {
    n, _ := parse_i64(s)
    n
}

// what the program does as a child
fn child(a: []str) -> i64 {
    if a[0] == "args" {                     // the arguments as args() has them
        for x in a[1..] { print(fmt("[", x, "]")) }
        return 0
    }
    if a[0] == "crt" {                      // the arguments as the C library splits the command line
        argc: i32
        argv: **u16
        env: **u16
        si: i32
        __wgetmainargs(&argc, &argv, &env, 0, &si)
        for i in 3..i64(argc) {
            buf: [4096]u8
            n := WideCharToMultiByte(65001, 0, argv[i], -1, &buf[0], 4096, 0, 0)
            print(fmt("[", buf[..i64(n) - 1], "]"))
        }
        return 0
    }
    if a[0] == "name" {                     // the program as the command line names it
        print(args()[0])
        return 0
    }
    if a[0] == "code" {                     // ends with this exit code (hexadecimal)
        n, _ := parse_u64(a[1], 16)
        ExitProcess(u32(n))
    }
    if a[0] == "closed" {                   // prints to a pipe that nobody reads any more
        r: i64
        w: i64
        CreatePipe(&r, &w, 0, 0)
        CloseHandle(r)
        SetStdHandle(0xFFFFFFF5, w)
        for i in 0..100000 { print("line", i) }
        return 0
    }
    if a[0] == "nil" {
        p: *i64 = nil
        print(*p)
        return 0
    }
    if a[0] == "sleep" {
        sleep_ms(num(a[1]))
        return 0
    }
    if a[0] == "run" {                      // runs the rest as a program
        return run(a[1..])
    }
    return 99
}

// the command line that runs this program as a child
fn me(what: []str) -> []str {
    argv := vec_of([]str{args()[0], "child"})
    argv.extend(what)
    argv.items()
}

fn with(first: str, rest: []str) -> []str {
    v := vec_of([]str{first})
    v.extend(rest)
    v.items()
}

fn main() -> i64 {
    if len(args()) > 2 && args()[1] == "child" {
        return child(args()[2..])
    }
    // ---- arguments
    tricky := []str{"a b", "", "q\"uote", "back\\slash\\", "end\\\\", "tab\there", "\xc3\xbcn\xc3\xaf \xe6\x97\xa5\xe6\x9c\xac", "\\\\\"x", "-", "\"", "\"\"", "a\"b\"c", "\\", "\\\\", "a\\\\\"b", "a\\\\\\\"b", "\\\" \\\\", "*.al", "?", "%PATH%", "^&|<>", "'single'", "sp ace\\", "\xf0\x9f\x98\x80", "new\nline", " ", "\t", "a  b", "C:\\Program Files\\x\\", "/flag:\"v w\"", "--k=v", "@file"}
    al, s1 := run_capture(me(with("args", tricky)))
    crt, s2 := run_capture(me(with("crt", tricky)))
    want := vec[u8]()
    for t in tricky { want.extend(fmt("[", t, "]\n")) }
    print("arguments arrive unchanged:", al == want.items(), s1)
    print("the C library splits the command line as args() does:", crt == al, s2)
    if al != want.items() || crt != al {
        print(al)
        print(crt)
    }
    print("invalid UTF-8 becomes U+FFFD:", run_capture(me([]str{"args", "a\xffb", "\xc3"})).0 == "[a\xef\xbf\xbdb]\n[\xef\xbf\xbd]\n")
    print("an unpaired surrogate stays (WTF-8):", run_capture(me([]str{"args", "x\xed\xa0\x80y"})).0 == "[x\xed\xa0\x80y]\n")

    // ---- the program: a path with spaces and non-ASCII text, with / or \, without .exe
    d := fmt("tmp/win_process_", process_id(), "_\xc3\xbc")
    make_dir(d)
    exe, _ := read_bytes(if ends_with(to_lower(args()[0]), ".exe") { args()[0] } else { fmt(args()[0], ".exe") })
    prog := path_join(d, "pr\xc3\xb6g name.exe")
    bare := prog[..len(prog) - 4]
    print("copy:", len(exe) > 1000, write_bytes(prog, exe), write_bytes(path_join(d, "tool_\xc3\xbc.exe"), exe))
    print("by path:", run_capture([]str{prog, "child", "args", "1"}), run_capture([]str{replace(prog, "/", "\\"), "child", "args", "2"}), run_capture([]str{bare, "child", "args", "3"}), run_capture([]str{path_join(current_dir(), prog), "child", "args", "4"}), run_capture([]str{fmt(bare, ".EXE"), "child", "args", "5"}), run_capture([]str{fmt("\\\\?\\", current_dir(), "\\", prog), "child", "args", "6"}))
    print("args()[0] is the name as given:", run_capture([]str{bare, "child", "name"}).0 == fmt(bare, "\n"), run_capture([]str{replace(prog, "/", "\\"), "child", "name"}).0 == fmt(replace(prog, "/", "\\"), "\n"))
    // a name is looked up in PATH, with ".exe" added: a child with a longer PATH runs it
    here := replace(path_join(current_dir(), d), "/", "\\")
    set := fmt("set PATH=", here, ";%PATH%&&", replace(args()[0], "/", "\\"), " child run ")
    print("through PATH:", run_capture([]str{"cmd", "/c", fmt(set, "tool_\xc3\xbc child args found")}), run_capture([]str{"cmd", "/c", fmt(set, "TOOL_\xc3\x9c.exe child args upper")}), run([]str{"tool_\xc3\xbc"}), why())
    print("a name with a dot gets no .exe:", write_bytes(path_join(d, "tool.v2.exe"), exe), run([]str{path_join(d, "tool.v2")}), why(), run([]str{path_join(d, "tool.v2.exe"), "child", "args"}))
    // not programs: a text file, a directory, a batch file (cmd runs those)
    write_file(path_join(d, "noext"), "text")
    write_file(path_join(d, "text.exe"), "text")
    write_bytes(path_join(d, "prog.bin"), exe)
    print("a text file:", run([]str{path_join(d, "noext")}), why(), run([]str{path_join(d, "text.exe")}), why(), run([]str{path_join(d, "text")}), why())
    print("a program under another extension:", run_capture([]str{path_join(d, "prog.bin"), "child", "args", "bin"}))
    print("missing:", run([]str{path_join(d, "missing")}), why(), run([]str{path_join(d, "missing.exe")}), why(), run([]str{"Q:\\missing"}), why(), run([]str{d}), why())
    bat := path_join(d, "b.bat")
    write_file(bat, "@echo off\r\necho batch %1 %2\r\nexit /b 4\r\n")
    write_file(path_join(d, "c.CMD"), "@echo cmd\r\n")
    print("a batch file:", run([]str{bat, "x"}), why(), run([]str{replace(bat, "/", "\\")}), why(), run([]str{path_join(d, "c.CMD")}), why(), run([]str{fmt(bat, ". ")}), why())
    print("through cmd:", run_capture([]str{"cmd", "/c", replace(bat, "/", "\\"), "one", "two"}), run_capture([]str{"cmd", "/c", "echo", "%OS%"}))

    // ---- the status of a program that an exception ended: 128 + the Linux signal
    for code in []str{"C0000005", "C00000FD", "C0000006", "C0000094", "C000008E", "C000001D", "C0000096", "C0000409", "C000013A", "40010005", "1234", "FFFFFFFF", "100"} {
        put(run(me([]str{"code", code})), " ")
    }
    print()
    out, st := run_capture_all(me([]str{"nil"}))
    print("a fault in the program:", st, lines(out)[0])
    // standard output that cannot be written
    out, st = run_capture_all(me([]str{"closed"}))
    print("closed standard output:", st, lines(out)[0])

    // ---- kill: any signal ends the process with status 128 + signal
    p, _ := spawn(me([]str{"sleep", "30000"}))
    print("kill:", kill(p, 65), why(), kill(p, -1), why(), kill(p, 0), kill(p, 1), wait(p), kill(p, 1), why(), kill(p, 0))
    q, _ := spawn(me([]str{"sleep", "30000"}))
    print("kill 64:", kill(q, 64), wait(q), try_wait(q))
    z, _ := spawn(me([]str{"args"}))
    sleep_ms(300)
    print("kill after the end:", kill(z, 9), wait(z))

    // ---- the environment: names without regard to case
    p1, _ := env_get("PATH")
    p2, ok2 := env_get("path")
    p3, _ := env_get("Path")
    print("environment:", p1 == p2, p2 == p3, ok2, len(p1) > 0, env_get("windir").1, env_get("WINDIR").1, env_get("al_no_such_variable").1, env_get("").1, env_get("A=B").1)

    for name in list_dir(d) { remove_file(path_join(d, name)) }
    print("cleanup:", list_dir(d), remove_dir(d))
    return 0
}
