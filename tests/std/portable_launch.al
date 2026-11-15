// std.os `Launch` (files as standard streams, a changed environment) and `wait` with a time
// limit, with the same output on every target (also run by `tests/run.sh --target windows`):
// the program starts copies of itself, also from several threads at once.
use std.os

struct Job { me: str, dir: str, k: i64, bad: *i64 }

// a child that copies its input to its output; each thread has files of its own
fn worker(j: Job) {
    for round in 0..8 {
        text := fmt("thread ", j.k, " round ", round, "\n")
        fin := path_join(j.dir, fmt("in", j.k))
        fout := path_join(j.dir, fmt("out", j.k))
        write_file(fin, text)
        st := run([]str{j.me, "cat"}, Launch{stdin: fin, stdout: fout})
        got, _ := read_file(fout)
        if st != 0 || got != text || !remove_file(fin) || !remove_file(fout) {
            atomic_add(j.bad, 1)
        }
    }
}

fn main() -> i64 {
    a := args()
    if len(a) > 1 && a[1] == "cat" {
        put(read_all(0))
        return 0
    }
    if len(a) > 1 && a[1] == "both" {
        put("out1 ")
        flush()
        eput("err1 ")
        put("out2\n")
        return 7
    }
    if len(a) > 1 && a[1] == "env" {
        for name in a[2..] {
            v, has := env_get(name)
            print(name, has, v)
        }
        return 0
    }
    if len(a) > 1 && a[1] == "sleep" {
        sleep_ms(20000)
        return 0
    }
    me := a[0]
    d := fmt("tmp/portable_launch_", process_id())
    make_dir(d)
    fin := path_join(d, "in")
    fout := path_join(d, "out")
    ferr := path_join(d, "err")
    fn show(path: str) -> str {
        t, ok := read_file(path)
        return if ok { fmt("[", replace(t, "\n", "|"), "]") } else { "(missing)" }
    }

    // files as the three streams
    write_file(fin, "line 1\nline 2\n")
    print("cat:", run([]str{me, "cat"}, Launch{stdin: fin, stdout: fout}), io_error(), show(fout))
    print("separate:", run([]str{me, "both"}, Launch{stdout: fout, stderr: ferr}), show(fout), show(ferr))
    print("one file:", run([]str{me, "both"}, Launch{stdout: fout, stderr: fout}), show(fout))
    print("stderr only:", run([]str{me, "both"}, Launch{stdout: NULL_DEVICE, stderr: ferr}), show(ferr))
    print("no input:", run([]str{me, "cat"}, Launch{stdin: NULL_DEVICE, stdout: fout}), show(fout))
    print("zero value:", run([]str{me, "env"}, Launch{}))

    // failures: a missing input file, an output file that cannot be made, a missing program
    print("missing input:", run([]str{me, "cat"}, Launch{stdin: path_join(d, "nope")}), io_error(), error_text(io_error()))
    _, ok := spawn([]str{me, "cat"}, Launch{stdout: path_join(d, "no/dir/out")})
    print("bad output:", ok, io_error())
    print("missing program:", run([]str{"no-such-program-al"}, Launch{stdout: fout}), io_error())
    empty: []str
    print("empty:", run(empty, Launch{}), io_error())

    // the environment: set, replace, remove; the last change of a name counts
    env := []str{"PL_NEW=new value", "PL_TWICE=first", "PL_TWICE=second", "PL_GONE=x", "PL_GONE", "PL_EMPTY="}
    print("env:", run([]str{me, "env", "PL_NEW", "PL_TWICE", "PL_GONE", "PL_EMPTY", "PL_NEVER"}, Launch{stdout: fout, env: env}))
    put(read_file(fout).0)
    _, mine := env_get("PL_NEW")
    print("this process:", mine)
    // what this process has is inherited, and can be removed or replaced for the program
    _, has_path := env_get("PATH")
    run([]str{me, "env", "PATH"}, Launch{stdout: fout})
    inherited := starts_with(read_file(fout).0, "PATH true")
    run([]str{me, "env", "PATH"}, Launch{stdout: fout, env: []str{"PATH"}})
    print("inherited, removed:", inherited == has_path, show(fout))
    run([]str{me, "env", "PATH"}, Launch{stdout: fout, env: []str{"PATH=only this"}})
    print("replaced:", show(fout))

    // a time limit
    p, _ := spawn([]str{me, "sleep"}, Launch{stdout: fout})
    t0 := clock_ns()
    st, done := wait(p, 50 * 1000000)
    ms := (clock_ns() - t0) / 1000000
    print("still running:", st, done, ms >= 50, ms < 5000)
    print("kill:", kill(p, 9), wait(p, 5000 * 1000000), wait(p, 0), wait(p))
    q, _ := spawn([]str{me, "both"}, Launch{stdout: fout, stderr: fout})
    print("ends in time:", wait(q, 20000 * 1000000), wait(q, -1))
    none: Process
    print("not started:", wait(none, 1000), io_error())

    // several threads start programs at the same time: every one gets its own files
    bad := 0
    ts := vec[Thread]()
    for k in 0..6 {
        t, _ := thread_spawn(worker, Job{me, d, k, &bad})
        ts.push(t)
    }
    for i in 0..ts.len {
        thread_join(&ts[i])
    }
    print("threads:", bad, list_dir(d))

    remove_file(fin)
    remove_file(fout)
    remove_file(ferr)
    print("clean:", remove_dir(d))
    return 0
}
