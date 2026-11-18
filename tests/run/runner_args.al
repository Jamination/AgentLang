// The test runner's command line (tests/run.al): `[path/to/alc] [filter]`, where one word
// alone is the filter unless it names a file (`tests\run.bat -j 4 -v shaderc` used to take
// `shaderc` for the compiler and fail every test with status 127), and a compiler that does not
// exist or does not run stops the run at once with one message. The runner runs in a directory
// of its own with an empty tests/run, so it finds no test of the repository.
use std.os

// the runner and the compiler for the system this program runs on, as the build scripts make them
when TARGET_OS == Windows {
    const RUNNER = "build/altest.exe"
    const ALC = "build/alc.exe"
    extern "kernel32.dll" fn SetCurrentDirectoryA(path: *u8) -> i32
    fn chdir(dir: str) -> bool { SetCurrentDirectoryA(cstr(dir)) != 0 }
} else {
    const RUNNER = "./build/altest"
    const ALC = "./build/alc"
    when TARGET_ARCH == Arch.Arm64 {
        fn chdir(dir: str) -> bool { syscall(49, cstr(dir)) == 0 }
    } else {
        fn chdir(dir: str) -> bool { syscall(80, cstr(dir)) == 0 }
    }
}

// the runner's output (standard output and error) and status; ALTEST_TMP (the directory of
// the run that runs this test, set by tests/run.sh) is not passed on
fn runner(runner: str, a: []str, out: str) -> (str, i64) {
    argv := vec[str]()
    argv.push(runner)
    argv.extend(a)
    p, ok := spawn(argv.items(), Launch{stdout: out, stderr: out, env: []str{"ALTEST_TMP"}})
    if !ok {
        return (fmt("cannot start ", runner, ": ", error_text(io_error())), -1)
    }
    st, ended := wait(p, 60_000_000_000)
    if !ended {
        kill(p, 9)
        wait(p)
        return ("the runner did not end in 60 s", -1)
    }
    text, _ := read_file(out)
    return (text, st)
}

fn main() {
    if !file_exists(RUNNER) || !file_exists(ALC) {
        print(fmt("no runner at ", RUNNER, " or no compiler at ", ALC, " (the build scripts build both)"))
        exit(77)
    }
    root := current_dir()
    run := path_join(root, RUNNER)
    alc := path_join(root, ALC)
    make_dir("tmp")
    dir := path_join(root, fmt("tmp/runner_args_", process_id()))
    make_dir(dir)
    make_dir(path_join(dir, "tests"))
    make_dir(path_join(dir, "tests/run"))
    out := path_join(dir, "out.txt")
    write_file(path_join(dir, "notes.txt"), "not a program\n")
    if !chdir(dir) {
        print("cannot enter", dir)
        exit(1)
    }
    none := "conformance: 0 passed, 0 failed\n"
    // the filter alone, with options before and after it: no build/alc here, so it is the
    // filter without a compiler
    t, st := runner(run, []str{"-j", "4", "-v", "shaderc"}, out)
    print("filter, no default compiler:", st, starts_with(t, "tests/run: shaderc is not a file, so it is the filter, but the default compiler "),
        len(lines(t)), find(t, "FAIL") < 0)
    // the compiler and the filter, in any order with the options
    t, st = runner(run, []str{alc, "shaderc"}, out)
    print("compiler and filter:", st, t == none)
    t, st = runner(run, []str{"-j", "2", alc, "shaderc", "-v"}, out)
    print("options after:", st, t == none)
    // a compiler that does not exist, given as a path: one message, no test
    t, st = runner(run, []str{"-j", "4", "no/such/alc", "shaderc"}, out)
    print("missing compiler:", st, starts_with(t, "tests/run: the compiler no/such/alc does not exist\n"), find(t, "FAIL") < 0, find(t, "conformance") < 0)
    // a file that is not a program: the compiler, which cannot be started
    t, st = runner(run, []str{"notes.txt", "shaderc"}, out)
    print("not a program:", st, starts_with(t, "tests/run: the compiler ./notes.txt cannot be started: "), find(t, "conformance") < 0)
    t, st = runner(run, []str{"notes.txt"}, out)
    print("not a program, alone:", st, starts_with(t, "tests/run: the compiler ./notes.txt cannot be started: "))
    // too many words, an unknown option
    t, st = runner(run, []str{alc, "a", "b"}, out)
    print("too many:", st, starts_with(t, "tests/run: too many arguments"))
    t, st = runner(run, []str{"-q", "shaderc"}, out)
    print("unknown option:", st, starts_with(t, "tests/run: unknown option -q\n"))

    chdir(root)
    remove_file(out)
    remove_file(path_join(dir, "notes.txt"))
    remove_dir(path_join(dir, "tests/run"))
    remove_dir(path_join(dir, "tests"))
    print("cleanup", remove_dir(dir))
}
