// std.os: running programs (status, captured output, failures to start), with the same
// output on every target: the programs are this one, started again with `child ...`
// (what needs a shell, signals or file permissions is in std/os, for Linux).
use std.os

fn why() -> str { error_text(io_error()) }

fn num(s: str) -> i64 {
    n, _ := parse_i64(s)
    n
}

// what the program does as a child
fn child(a: []str) -> i64 {
    if a[0] == "exit" {                     // exit N
        return num(a[1])
    }
    if a[0] == "echo" {                     // echo ARGS: the arguments, separated by spaces
        print(join(a[1..], " "))
        return 0
    }
    if a[0] == "streams" {                  // lines on both streams, status 3
        print("one")
        eprint("two")
        print("three")
        return 3
    }
    if a[0] == "big" {                      // big N: N times 'x' and "end" on standard output
        put(repeat("x", num(a[1])))
        print("end")
        return 0
    }
    if a[0] == "big2" {                     // big2 N: N times 'a' on standard output, then N times 'b' and "end" on standard error
        put(repeat("a", num(a[1])))
        eput(repeat("b", num(a[1])))
        eprint("end")
        return 0
    }
    if a[0] == "stdin" {                    // the number of bytes of standard input
        print(len(read_all(0)))
        return 0
    }
    if a[0] == "env" {                      // env NAME: whether the variable is set
        v, set := env_get(a[1])
        print(set && len(v) > 0)
        return 0
    }
    if a[0] == "cwd" {
        print(current_dir())
        return 0
    }
    if a[0] == "chain" {                    // chain N: runs itself N levels deep; the status counts them
        n := num(a[1])
        if n == 0 {
            return 0
        }
        return run([]str{args()[0], "child", "chain", fmt(n - 1)}) + 1
    }
    return 99
}

// the command line that runs this program as a child
fn me(what: []str) -> []str {
    argv := vec_of([]str{args()[0], "child"})
    argv.extend(what)
    argv.items()
}

fn main() -> i64 {
    if len(args()) > 2 && args()[1] == "child" {
        return child(args()[2..])
    }
    d := fmt("tmp/os_run_", process_id())
    make_dir(d)

    // ---- run: exit status
    print("exit 0", run(me([]str{"exit", "0"})), io_error())
    print("exit 1", run(me([]str{"exit", "1"})), io_error())
    print("exit 7", run(me([]str{"exit", "7"})), run(me([]str{"exit", "300"})), run(me([]str{"exit", "255"})), run(me([]str{"exit", "-1"})))
    print("arguments", run_capture(me([]str{"echo", "a b", "", "c"})))
    // buffered output of this process comes before the child's
    put("parent, ")
    run(me([]str{"echo", "child"}))
    // the child reads this process's standard input (here: nothing), has its environment
    // and its working directory
    print("stdin", run_capture(me([]str{"stdin"})), run_capture(me([]str{"env", "PATH"})).0 == "true\n", run_capture(me([]str{"env", "OS_RUN_NOT_SET"})).0 == "false\n")
    print("working directory", run_capture(me([]str{"cwd"})).0 == fmt(current_dir(), "\n"))
    print("children of children", run(me([]str{"chain", "5"})))

    // ---- failures to start: -1 and the reason
    print("missing program", run([]str{"no-such-program-xyz"}), why())
    print("missing path", run([]str{"./no/such/program"}), why(), run_capture([]str{"/no/such"}), why(), run_capture_all([]str{"no-such-program-xyz", "x"}), why())
    print("a directory", run([]str{d}), why(), run([]str{"tmp/"}), why())
    print("below a file", run([]str{"tests/std/os_run.al/x"}), io_error() == 2 || io_error() == 20)
    print("after a start", run(me([]str{"exit", "0"})), why())
    print("no name", run([]str{}), why(), run([]str{""}), why())
    print("a failure leaves no output", run_capture([]str{"no-such-program-xyz"}), run_capture_all([]str{}))

    // ---- captured output
    out, status := run_capture(me([]str{"streams"}))
    print("stdout only", out, status)
    out, status = run_capture_all(me([]str{"streams"}))
    print("both", out, status)
    out, status = run_capture(me([]str{"exit", "0"}))
    print("nothing", len(out), status)
    out, status = run_capture_all(me([]str{"exit", "9"}))
    print("nothing from both", len(out), status)
    // more than a pipe holds: 1 MB from each stream, the program must not stall
    big, st := run_capture(me([]str{"big", "1048576"}))
    print("1 MB", len(big), st, count(big, "x"), ends_with(big, "xend\n"))
    big, st = run_capture_all(me([]str{"big2", "1048576"}))
    print("2 MB from both", len(big), st, count(big, "a"), count(big, "b"), find(big, "b") == 1048576, ends_with(big, "bend\n"))
    // captured text is bytes: nothing is translated
    bytes, _ := run_capture(me([]str{"echo", "a\r", "\xc3\xa9\x01\x7f"}))
    print("bytes", len(bytes), bytes == "a\r \xc3\xa9\x01\x7f\n")
    // a program found through PATH (Windows: with ".exe" added to the name)
    when TARGET_OS == Windows {
        print("PATH lookup", run([]str{"cmd", "/c", "exit 5"}), run_capture([]str{"cmd", "/c", "echo found"}).0 == "found\r\n")
    } else {
        print("PATH lookup", run([]str{"sh", "-c", "exit 5"}), run_capture([]str{"sh", "-c", "echo found"}).0 == "found\n")
    }
    // many in a row: no handle or process is left behind
    sum := 0
    for i in 0..40 {
        o, s := run_capture(me([]str{"echo", fmt(i)}))
        sum += num(trim(o)) + s
    }
    print("40 in a row", sum)

    print("cleanup", remove_dir(d), file_exists(d))
    return 0
}
