// std.os: running programs (status, captured output, failures), the process itself, and the
// file and directory functions a tool needs (std.asset, loaded by std.os). Works inside a
// directory that it creates and removes.
use std.os

fn why() -> str { error_text(io_error()) }

fn sh(script: str) -> []str { []str{"/bin/sh", "-c", script} }

fn main() {
    root := current_dir()
    print(len(root) > 1 && root[0] == '/', is_dir(root), file_exists(path_join(root, "tests/std/os.al")))
    print(process_id() > 1, process_id() == process_id())
    d := fmt("tmp/os_test_", process_id())
    print("make_dir", make_dir(path_join(d, "a/b/c")), is_dir(path_join(d, "a/b")), make_dir(d), io_error())

    // ---- files and directories
    f := path_join(d, "a/one.txt")
    print("write", write_file(f, "hello\n"), file_exists(f), is_dir(f), file_size(f), modified_time(f) > 0)
    print("missing", file_exists(path_join(d, "nope")), is_dir(path_join(d, "nope")), file_size(path_join(d, "nope")), modified_time(path_join(d, "nope")))
    write_file(path_join(d, "a/Two.txt"), "2")
    write_file(path_join(d, "a/.hidden"), "")
    print("list", list_dir(path_join(d, "a")), list_dir(path_join(d, "a/b/c")), io_error())
    print("list missing", list_dir(path_join(d, "zzz")), why())
    print("list a file", list_dir(f), why())
    g := path_join(d, "a/b/moved.txt")
    print("rename", rename(f, g), io_error(), file_exists(f), read_file(g))
    print("rename over a file", rename(path_join(d, "a/Two.txt"), g), read_file(g), list_dir(path_join(d, "a")))
    print("rename missing", rename(f, g), why())
    print("rename into a missing directory", rename(g, path_join(d, "no/x")), why())
    print("rename a directory", rename(path_join(d, "a/b"), path_join(d, "B")), list_dir(d), list_dir(path_join(d, "B")))
    print("remove_file", remove_file(path_join(d, "B/moved.txt")), io_error(), remove_file(path_join(d, "B/moved.txt")), why())
    print("remove_dir not empty", remove_dir(path_join(d, "B")), why())
    print("remove_dir", remove_dir(path_join(d, "B/c")), remove_dir(path_join(d, "B")), remove_dir(path_join(d, "B")), why())
    print("make_dir below a file", make_dir(path_join(d, "a/.hidden/x")), why())

    // ---- run: exit status
    print("true", run([]str{"true"}), io_error())
    print("false", run([]str{"false"}), io_error())
    print("exit 7", run(sh("exit 7")), run([]str{"/bin/sh", "-c", "exit 300"}))
    print("arguments", run_capture([]str{"echo", "a b", "", "c"}))
    print("killed", run(sh("kill -9 $$")), run(sh("kill -TERM $$")), run_capture(sh("echo before; kill -9 $$; echo after")), io_error())
    // buffered output of this process comes before the child's
    put("parent, ")
    run(sh("echo child"))
    // the child reads this process's standard input (here: /dev/null) and has its environment
    print("stdin", run_capture(sh("wc -c")), run_capture(sh("test -n \"$PATH\" && echo has PATH")).0 == "has PATH\n")

    // ---- failures to start: -1 and the reason
    print("missing program", run([]str{"no-such-program-xyz"}), why())
    print("missing path", run([]str{"./no/such/program"}), why(), run_capture([]str{"/no/such"}), why(), run_capture_all([]str{"no-such-program-xyz", "x"}), why())
    print("a directory", run([]str{d}), why(), run([]str{"tmp/"}), why())
    script := path_join(d, "script")
    write_file(script, "#!/bin/sh\necho script $1\n")
    print("not executable", run([]str{script}), why())
    print("after a start", run([]str{"true"}), why())
    syscall(90, cstr(script), 0o755)
    print("executable", run_capture([]str{script, "arg"}))
    write_file(path_join(d, "garbage"), "\x01\x02\x03 not a program")
    syscall(90, cstr(path_join(d, "garbage")), 0o755)
    print("no program format", run([]str{path_join(d, "garbage")}), why())
    print("no name", run([]str{}), why(), run([]str{""}), why())

    // ---- captured output
    out, status := run_capture(sh("echo one; echo two >&2; echo three; exit 3"))
    print("stdout only", out, status)
    out, status = run_capture_all(sh("echo one; echo two >&2; echo three; exit 3"))
    print("both", out, status)
    out, status = run_capture(sh("exit 0"))
    print("nothing", len(out), status)
    // more than a pipe holds: 1 MB from each stream, the program must not stall
    big, st := run_capture(sh("head -c 1048576 /dev/zero | tr '\\0' 'x'; echo end"))
    print("1 MB", len(big), st, count(big, "x"), ends_with(big, "xend\n"))
    big, st = run_capture_all(sh("head -c 1048576 /dev/zero | tr '\\0' 'a'; head -c 1048576 /dev/zero | tr '\\0' 'b' >&2; echo end >&2"))
    print("2 MB from both", len(big), st, count(big, "a"), count(big, "b"), find(big, "b") == 1048576, ends_with(big, "bend\n"))
    // a program found through PATH
    cc, _ := run_capture(sh("command -v sh"))
    print("PATH lookup", run([]str{"sh", "-c", "exit 5"}), len(trim(cc)) > 0)

    // ---- clean up
    for name in list_dir(path_join(d, "a")) { remove_file(path_join(path_join(d, "a"), name)) }
    print("cleanup", remove_file(script), remove_file(path_join(d, "garbage")), remove_dir(path_join(d, "a")), remove_dir(d), file_exists(d))
}
