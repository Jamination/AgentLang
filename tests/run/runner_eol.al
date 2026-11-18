// The test runner (tests/run.al) compares expected files byte for byte; an expected file that
// differs only by CRLF line endings or a byte order mark (as PowerShell's Set-Content writes
// them) is named as such instead of "stdout differs" with a diff of identical-looking lines.
// The runner runs in a directory of its own, on tests made here.
use std.os

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

const BOM = "\xEF\xBB\xBF"

fn main() {
    if !file_exists(RUNNER) || !file_exists(ALC) {
        print(fmt("no runner at ", RUNNER, " or no compiler at ", ALC, " (the build scripts build both)"))
        exit(77)
    }
    root := current_dir()
    make_dir("tmp")
    dir := path_join(root, fmt("tmp/runner_eol_", process_id()))
    make_dir(dir)
    make_dir(path_join(dir, "tests"))
    t := path_join(dir, "tests/run")
    make_dir(t)
    two := "fn main() {\n    print(\"one\")\n    print(\"two\")\n}\n"
    files := [](str, str){
        // CRLF, a BOM, both: the output is right
        ("eol_crlf.al", two), ("eol_crlf.out", "one\r\ntwo\r\n"),
        ("eol_bom.al", two), ("eol_bom.out", concat(BOM, "one\ntwo\n")),
        ("eol_both.al", two), ("eol_both.out", concat(BOM, "one\r\ntwo\r\n")),
        // CRLF and a different line: a diff as before
        ("eol_diff.al", two), ("eol_diff.out", "one\r\nthree\r\n"),
        // the lines of NAME.err with CRLF
        ("eol_err.al", "fn main() { eprint(\"a warning\") }\n"), ("eol_err.out", ""), ("eol_err.err", "a warning\r\n"),
        // LF: passes
        ("eol_lf.al", two), ("eol_lf.out", "one\ntwo\n"),
    }
    for f in files {
        write_file(path_join(t, f.0), f.1)
    }
    out := path_join(dir, "out.txt")
    if !chdir(dir) {
        print("cannot enter", dir)
        exit(1)
    }
    // (ALTEST_TMP, the directory of the run that runs this test, is not passed on)
    p, ok := spawn([]str{path_join(root, RUNNER), "-j", "1", path_join(root, ALC), "eol_"},
        Launch{stdout: out, stderr: out, env: []str{"ALTEST_TMP"}})
    st := -1
    if ok {
        s, ended := wait(p, 60_000_000_000)
        if !ended {
            kill(p, 9)
            wait(p)
        }
        st = s
    }
    text, _ := read_file(out)
    put(replace(text, "\r", "\\r"))
    print("status", st)

    chdir(root)
    remove_file(out)
    for f in files {
        remove_file(path_join(t, f.0))
    }
    remove_dir(t)
    remove_dir(path_join(dir, "tests"))
    print("cleanup", remove_dir(dir))
}
