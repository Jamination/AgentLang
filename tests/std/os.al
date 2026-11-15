// std.os on Linux: what needs a shell, signals or file permissions. (Everything else, with
// the same output on every target, is in std/os_files, std/os_run and std/os_spawn.)
// Programs found through PATH, a program that a signal ends, the standard input and
// environment of a shell, files without the execute permission, `#!` scripts, files that
// are no program, pipelines.
use std.os

fn why() -> str { error_text(io_error()) }

fn sh(script: str) -> []str { []str{"/bin/sh", "-c", script} }

fn main() {
    d := fmt("tmp/os_test_", process_id())
    print("make_dir", make_dir(d), io_error())

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
    script := path_join(d, "script")
    write_file(script, "#!/bin/sh\necho script $1\n")
    print("not executable", run([]str{script}), why())
    print("after a start", run([]str{"true"}), why())
    syscall(90, cstr(script), 0o755)
    print("executable", run_capture([]str{script, "arg"}))
    write_file(path_join(d, "garbage"), "\x01\x02\x03 not a program")
    syscall(90, cstr(path_join(d, "garbage")), 0o755)
    print("no program format", run([]str{path_join(d, "garbage")}), why())

    // ---- captured output of a pipeline
    out, status := run_capture_all(sh("echo one; echo two >&2; echo three; exit 3"))
    print("both", out, status)
    big, st := run_capture_all(sh("head -c 1048576 /dev/zero | tr '\\0' 'a'; head -c 1048576 /dev/zero | tr '\\0' 'b' >&2; echo end >&2"))
    print("2 MB from both", len(big), st, count(big, "a"), count(big, "b"), find(big, "b") == 1048576, ends_with(big, "bend\n"))
    // a program found through PATH
    cc, _ := run_capture(sh("command -v sh"))
    print("PATH lookup", run([]str{"sh", "-c", "exit 5"}), len(trim(cc)) > 0)

    // ---- clean up
    print("cleanup", remove_file(script), remove_file(path_join(d, "garbage")), remove_dir(d), file_exists(d))
}
