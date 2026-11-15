// Conformance test runner, for Linux and Windows. tests/run.sh and tests\run.bat build it
// (build/altest, build\altest.exe) and start it from the repository root.
// Usage: altest [-j N] [-v] [--target linux|windows [--host-wine path/to/alc.exe]] [path/to/alc] [filter]
// tests/run/NAME.al   must compile and print NAME.out (exit code from NAME.code, default 0;
//                     every line of NAME.err must appear in stderr; arguments from NAME.args,
//                     default `a1 b2`; standard input from NAME.in, then without arguments)
// tests/std/NAME.al   the same, for the standard library (static, libc-free programs)
// tests/sys/NAME.al   the same, for programs that need something from this machine (a GPU
//                     driver, a sound device, a display, a shared library). NAME.need holds a
//                     shell command that tells whether the prerequisite is there; if it fails
//                     the test is reported as SKIP together with the text of NAME.why.
//                     NAME.c is a C library for the test, built before it with the C compiler
//                     of the target (clang -O2, without frame pointers: libNAME.so, found
//                     through LD_LIBRARY_PATH; Windows: MinGW -O2, NAME.dll next to the
//                     program); without that compiler the test is reported as SKIP.
//                     A program of run/, std/ or sys/ that ends with status 77 (and does not
//                     expect it) is reported as SKIP with the first line of its standard output:
//                     for what only the program can find out (no Direct3D 12 device under Wine).
// tests/fail/NAME.al  must fail to compile; every line of NAME.err must appear in the diagnostics
// tests/check/NAME.al must pass `alc check` (bindings for platforms this machine cannot run;
//                     with NAME.target, `alc check --target <its content>`: a Windows program
//                     is then type-checked on Linux too)
// tests/unit/NAME.al  is run with `alc test`; stdout must equal NAME.out (exit code from NAME.code)
// tests/driver/NAME.sh is run with bash, the compiler as $1 and an empty scratch directory as
//                     $2; it tests the command line (files, paths, exit codes) and must exit 0
// NAME.flags          (run/, std/, sys/, fail/, check/) options for the compiler, e.g. `-D DEMO`
// NAME.checked        (run/, std/, sys/) the program is not built with --unchecked
// NAME.windows.err    (run/, std/, sys/) replaces NAME.err for --target windows
// all targets         (Linux target) `alc check --all-targets` must pass for the programs of
//                     examples/ (files with `fn main`), for tests/check/NAME.al without
//                     NAME.target and for the tests of run/ and std/ that use `when`, unless
//                     tests/one_target lists them with the reason: platform code of every
//                     target stays type-checked
// Programs run with the repository root as working directory, each of run/, std/ and sys/ in
// three build modes (default, -O0, --unchecked). Output: `FAIL name: reason` with the first
// lines of a diff or of the messages, `SKIP name: reason`, with -v also `ok   name`; then
// `conformance: N passed, M failed, K skipped`. The exit status is 0 if nothing failed.
//
// Tests run at the same time, one thread per CPU (-j N: N threads; -j 1: one test after the
// other), each in a directory of its own under the temporary directory; the three modes of a
// test run one after the other, and so do the tests of sys/ (they share the machine's devices).
// The lines are printed in the order of the tests whatever the order they finish in.
//
// The default target is the system the runner runs on.
// Linux, --target windows: builds the programs for Windows and runs them under Wine (in the
// prefix $WINEPREFIX, default tmp/win/prefix-tests, created if missing; DISPLAY and
// WAYLAND_DISPLAY are removed and the prefix uses Wine's null display driver: windows open and
// receive messages, nothing is shown; no sound can play: Wine's PulseAudio driver gets a server
// address where none listens and ALSA an empty configuration, so Wine finds no audio device).
// fail/ and check/ use `alc check --target windows`, unit/ runs `alc test` under Wine; driver/
// tests the Linux command line and is not run; the prerequisite checks (NAME.need) are Linux
// ones and are not run either. Tests that cannot run on Windows are listed with the reason in
// tests/windows.skip.
// Linux, --host-wine alc.exe (with --target windows) tests a compiler built for Windows:
// alc.exe runs under Wine and builds, checks and runs (`alc run` in the default mode,
// `alc test`) the programs there; [path/to/alc] is not given then, only the filter.
// Windows: the same tests as --target windows, with the compiler build\alc.exe and without
// Wine: the programs run directly, the default mode through `alc run` (as with --host-wine).
// Windows, --target linux: the programs are built for Linux (three modes) and checked, not run.
use std.os

priv const USAGE = "usage: tests/run.sh [-j N] [-v] [--target linux|windows [--host-wine path/to/alc.exe]] [path/to/alc] [filter]"

when TARGET_OS == Windows {
    priv const HOST_WIN = true
} else {
    priv const HOST_WIN = false
}

// what this run does: set by main before the threads start, then only read
priv struct Config {
    win: bool               // the programs are built for Windows
    can_run: bool           // this machine runs programs of the target (else they are only built)
    via_run: bool           // the default mode runs the program through `alc run`
    verbose: bool
    alc: []str              // the compiler, as the start of a command
    alc_abs: str            // its absolute path, for the driver tests
    target: []str           // the compiler's --target option, or nothing
    runner: []str           // what a built program is started with: nothing, or wine
    exe: str                // ".exe" for Windows programs
    wcc: str                // the C compiler for Windows DLLs
    filter: str
    tmp: str                // the directory of this run's files
    env: []str              // what the programs started get changed in their environment
}

priv cfg: Config

priv enum Kind { Prog, Check, Fail, Unit, All, Driver }

priv struct Job {
    kind: Kind
    dir: str                // tests/run, tests/std, tests/sys for a Prog
    name: str
    src: str
    skipped: bool           // listed in tests/windows.skip (for a Windows target)
    why: str                // its reason there
}

// what a job reports
priv struct Res { text: Vec[u8], pass: i64, fail: i64, skip: i64 }

priv fn say(r: *Res, line: str) {
    r.text.extend(line)
    r.text.push('\n')
}

// (text that already ends its lines)
priv fn show(r: *Res, text: str) {
    r.text.extend(text)
}

priv fn passed(r: *Res, label: str) {
    r.pass += 1
    if cfg.verbose {
        r.say(fmt("ok   ", label))
    }
}

// ---------- text helpers ----------
priv fn slurp(path: str) -> str {
    t, _ := read_file(path)
    return t
}

// the first n lines of text (`head -n`); a last line without a newline gets one
priv fn head(text: str, n: i64) -> str {
    at := 0
    for _ in 0..n {
        if at >= len(text) {
            break
        }
        nl := find(text, "\n", at)
        if nl < 0 {
            return concat(text, "\n")
        }
        at = nl + 1
    }
    return text[..at]
}

// the words of the first line of a file (bash `read -ra`); none if the file is missing
priv fn words(path: str) -> []str {
    t := slurp(path)
    nl := find(t, "\n")
    return fields(if nl < 0 { t } else { t[..nl] })
}

// the content of a file without the newlines at its end (bash `$(cat file)`)
priv fn content(path: str) -> str {
    return trim_right(slurp(path), "\n")
}

// the lines of a text without their newlines, and whether the last one had none
priv fn text_lines(t: str) -> ([]str, bool) {
    if len(t) == 0 {
        empty: []str
        return (empty, false)
    }
    return (lines(t), t[len(t) - 1] != '\n')
}

priv fn span(lo: i64, hi: i64) -> str {
    return if lo == hi { fmt(lo) } else { fmt(lo, ",", hi) }
}

// The first `limit` lines of `diff a b` (the normal format: "3c3", "< old", "---", "> new"):
// a is the expected text, b what the program wrote.
priv fn diff(a: str, b: str, limit: i64) -> str {
    la, open_a := text_lines(a)
    lb, open_b := text_lines(b)
    na := len(la)
    nb := len(lb)
    // a last line without a newline equals only a last line without a newline
    fn same(la: []str, lb: []str, i: i64, j: i64, open_a: bool, open_b: bool) -> bool {
        return la[i] == lb[j] && (open_a && i == len(la) - 1) == (open_b && j == len(lb) - 1)
    }
    pre := 0
    while pre < na && pre < nb && same(la, lb, pre, pre, open_a, open_b) {
        pre += 1
    }
    post := 0
    while post < na - pre && post < nb - pre && same(la, lb, na - 1 - post, nb - 1 - post, open_a, open_b) {
        post += 1
    }
    n := na - pre - post
    m := nb - pre - post
    // the edit script of the middle: 'm' a common line, 'd' a line only in a, 'i' only in b
    ops := vec[u8]()
    if n * m > 4_000_000 {
        // (too large for the table below: everything changed)
        for _ in 0..n { ops.push('d') }
        for _ in 0..m { ops.push('i') }
    } else {
        // lcs[i * (m + 1) + j]: the longest common subsequence of a[pre + i..] and b[pre + j..]
        lcs := alloc[i32]((n + 1) * (m + 1))
        for i in n - 1..=0 by -1 {
            for j in m - 1..=0 by -1 {
                lcs[i * (m + 1) + j] = if same(la, lb, pre + i, pre + j, open_a, open_b) {
                    lcs[(i + 1) * (m + 1) + j + 1] + 1
                } else {
                    max(lcs[(i + 1) * (m + 1) + j], lcs[i * (m + 1) + j + 1])
                }
            }
        }
        i := 0
        j := 0
        while i < n || j < m {
            if i < n && j < m && same(la, lb, pre + i, pre + j, open_a, open_b) {
                ops.push('m')
                i += 1
                j += 1
            } else if j == m || (i < n && lcs[(i + 1) * (m + 1) + j] >= lcs[i * (m + 1) + j + 1]) {
                ops.push('d')
                i += 1
            } else {
                ops.push('i')
                j += 1
            }
        }
    }
    out := vec[str]()
    i := pre
    j := pre
    k := 0
    while k < ops.len && out.len < limit {
        if ops[k] == 'm' {
            i += 1
            j += 1
            k += 1
            continue
        }
        i0 := i
        j0 := j
        while k < ops.len && ops[k] != 'm' {
            if ops[k] == 'd' { i += 1 } else { j += 1 }
            k += 1
        }
        if i > i0 && j > j0 {
            out.push(fmt(span(i0 + 1, i), "c", span(j0 + 1, j)))
        } else if i > i0 {
            out.push(fmt(span(i0 + 1, i), "d", j0))
        } else {
            out.push(fmt(i0, "a", span(j0 + 1, j)))
        }
        for x in i0..i {
            out.push(concat("< ", la[x]))
            if open_a && x == na - 1 {
                out.push("\\ No newline at end of file")
            }
        }
        if i > i0 && j > j0 {
            out.push("---")
        }
        for x in j0..j {
            out.push(concat("> ", lb[x]))
            if open_b && x == nb - 1 {
                out.push("\\ No newline at end of file")
            }
        }
    }
    out.truncate(limit)
    if out.len == 0 {
        return ""
    }
    return concat(join(out.items(), "\n"), "\n")
}

// ---------- programs and files ----------
// whether the directories of PATH have a program of that name (bash `command -v`)
priv fn have(name: str) -> bool {
    path, _ := env_get("PATH")
    sep: u8 = if HOST_WIN { ';' } else { ':' }
    for d in split(path, sep) {
        if len(d) == 0 {
            continue
        }
        f := path_join(d, name)
        if (file_exists(f) && !is_dir(f)) || (HOST_WIN && file_exists(concat(f, ".exe"))) {
            return true
        }
    }
    return false
}

// Runs argv to its end, with files as its standard streams ("": those of this process) and
// the environment of the run changed by `env` too. The status is what a shell reports: the
// exit status, 128 + the signal, 127 / 126 if the program is missing / cannot be started
// (the reason is written to the file of standard error), 124 if it ran longer than limit_s
// seconds (0: no limit) and was ended.
priv fn exec(argv: []str, sin: str, sout: str, serr: str, limit_s: i64, env: []str) -> i64 {
    all := cfg.env
    if len(env) > 0 {
        v := vec_of(cfg.env)
        v.extend(env)
        all = v.items()
    }
    p, ok := spawn(argv, Launch{stdin: sin, stdout: sout, stderr: serr, env: all})
    if !ok {
        e := io_error()
        if len(serr) > 0 && serr != NULL_DEVICE {
            write_file(serr, fmt(argv[0], ": ", error_text(e), "\n"))
        }
        return if e == 2 { 127 } else { 126 }
    }
    if limit_s <= 0 {
        return wait(p)
    }
    st, ended := wait(p, limit_s * 1_000_000_000)
    if ended {
        return st
    }
    kill(p, 15)
    _, gone := wait(p, 5 * 1_000_000_000)
    if !gone {
        kill(p, 9)
        wait(p)
    }
    return 124
}

priv fn exec(argv: []str, sin: str, sout: str, serr: str) -> i64 {
    none: []str
    return exec(argv, sin, sout, serr, 0, none)
}

// removes a file, or a directory with everything in it (a link is removed, not followed)
priv fn remove_tree(path: str) {
    if remove_file(path) {
        return
    }
    for n in list_dir(path) {
        remove_tree(path_join(path, n))
    }
    remove_dir(path)
}

// `path` as an absolute path without "." and ".." components (Linux)
priv fn absolute(path: str) -> str {
    parts := vec[str]()
    for c in split(path_join(current_dir(), path), '/') {
        if c == "" || c == "." {
            continue
        }
        if c == ".." {
            if parts.len > 0 {
                parts.pop()
            }
            continue
        }
        parts.push(c)
    }
    return concat("/", join(parts.items(), "/"))
}

// the names `stem` of the files stem.ext of a directory, in the order of their file names
priv fn stems(dir: str, ext: str) -> []str {
    out := vec[str]()
    for n in list_dir(dir) {
        if ends_with(n, ext) && n[0] != '.' {
            out.push(n[..len(n) - len(ext)])
        }
    }
    return out.items()
}

// "key reason" lines of a list file (tests/windows.skip, tests/one_target)
priv fn read_list(path: str) -> Map[str, str] {
    m := map[str, str]()
    for line in lines(slurp(path)) {
        t := trim(line)
        if len(t) == 0 || t[0] == '#' {
            continue
        }
        sp := find_any(t, " \t", 0)
        if sp < 0 {
            m.set(t, "")
        } else {
            m.set(t[..sp], trim(t[sp..]))
        }
    }
    return m
}

// whether a line of the text starts with `prefix`, after white space if `indented`
priv fn has_line(text: str, prefix: str, indented: bool) -> bool {
    for line in lines(text) {
        l := if indented { trim_left(line) } else { line }
        if starts_with(l, prefix) {
            return true
        }
    }
    return false
}

// ---------- the tests ----------
// every non-empty line of the file `expected` must be in `got`: reports each missing one as
// "FAIL label: what: line" (followed by the first lines of got, indented, if `quote`)
priv fn lines_present(r: *Res, label: str, what: str, expected: str, got: str, quote: bool) -> bool {
    ok := true
    for line in lines(slurp(expected)) {
        if len(line) == 0 || find(got, line) >= 0 {
            continue
        }
        r.say(fmt("FAIL ", label, ": ", what, ": ", line))
        if quote && len(got) > 0 {
            for l in lines(head(got, 5)) {
                r.say(concat("    ", l))
            }
        }
        ok = false
    }
    return ok
}

// a program of tests/run, tests/std or tests/sys, in its build modes
priv fn prog(j: Job, jd: str, r: *Res) {
    name := j.name
    base := path_join(j.dir, name)
    bin := path_join(jd, concat("bin", cfg.exe))
    out := path_join(jd, "out")
    err := path_join(jd, "err")
    cerr := path_join(jd, "cerr")
    cout := path_join(jd, "cout")
    if !cfg.win && cfg.can_run && file_exists(concat(base, ".need")) &&
        exec([]str{"bash", concat(base, ".need")}, "", NULL_DEVICE, NULL_DEVICE) != 0 {
        why := "prerequisite missing"
        if file_exists(concat(base, ".why")) {
            why = content(concat(base, ".why"))
        }
        r.say(fmt("SKIP ", name, ": ", why))
        r.skip += 1
        return
    }
    if cfg.can_run && file_exists(concat(base, ".c")) {
        cc := vec[str]()
        if cfg.win {
            cc.extend([]str{cfg.wcc, "-O2", "-shared", "-o", path_join(jd, concat(name, ".dll"))})
        } else {
            cc.extend([]str{"clang", "-O2", "-fomit-frame-pointer", "-shared", "-fPIC", "-o",
                path_join(cfg.tmp, fmt("clib/lib", name, ".so"))})
        }
        if !have(cc[0]) {
            r.say(fmt("SKIP ", name, ": ", cc[0], " is not installed (it builds the test's C library)"))
            r.skip += 1
            return
        }
        cc.push(concat(base, ".c"))
        st := exec(cc.items(), "", cout, cerr)
        r.show(slurp(cout))
        if st != 0 {
            r.say(fmt("FAIL ", name, ": the C library does not build"))
            r.show(head(slurp(cerr), 5))
            r.fail += 1
            return
        }
    }
    exp_err := concat(base, ".err")
    if cfg.win && file_exists(concat(base, ".windows.err")) {
        exp_err = concat(base, ".windows.err")
    }
    exp_code := "0"
    if file_exists(concat(base, ".code")) {
        exp_code = content(concat(base, ".code"))
    }
    flags := words(concat(base, ".flags"))
    modes := []str{"", "-O0", "--unchecked"}
    if file_exists(concat(base, ".checked")) {
        modes = modes[..2]
    }
    for mode in modes {
        label := fmt(name, " [", if mode == "" { "default" } else { mode }, "]")
        build := vec_of(cfg.alc)
        build.push("build")
        build.extend(cfg.target)
        build.extend(flags)
        build.push(j.src)
        if mode != "" {
            build.push(mode)
        }
        build.extend([]str{"-o", bin})
        st := exec(build.items(), "", cout, cerr)
        r.show(slurp(cout))
        if st != 0 {
            r.say(fmt("FAIL ", label, ": compile error"))
            r.show(head(slurp(cerr), 5))
            r.fail += 1
            continue
        }
        if !cfg.can_run {
            r.passed(label)
            continue
        }
        // (with via_run the default mode runs the program through `alc run`: arguments, input
        // and exit status pass through the compiler)
        cmd := vec_of(cfg.runner)
        cmd.push(bin)
        if cfg.via_run && mode == "" {
            cmd = vec_of(cfg.alc)
            cmd.push("run")
            cmd.extend(cfg.target)
            cmd.extend(flags)
            cmd.extend([]str{j.src, "-o", bin, "--"})
        }
        none: []str
        code := 0
        if file_exists(concat(base, ".in")) {
            code = exec(cmd.items(), concat(base, ".in"), out, err, 60, none)
        } else {
            if file_exists(concat(base, ".args")) {
                cmd.extend(words(concat(base, ".args")))
            } else {
                cmd.extend([]str{"a1", "b2"})
            }
            code = exec(cmd.items(), NULL_DEVICE, out, err, 60, none)
        }
        got := slurp(out)
        if code == 77 && exp_code != "77" {
            r.say(fmt("SKIP ", label, ": ", trim_right(head(got, 1), "\n")))
            r.skip += 1
            break
        }
        ok := true
        want := slurp(concat(base, ".out"))
        if got != want {
            r.say(fmt("FAIL ", label, ": stdout differs"))
            r.show(diff(want, got, 10))
            ok = false
        }
        if fmt(code) != exp_code {
            r.say(fmt("FAIL ", label, ": exit code ", code, ", expected ", exp_code))
            r.show(head(slurp(err), 3))
            ok = false
        }
        if file_exists(exp_err) && !lines_present(r, label, "stderr lacks", exp_err, slurp(err), false) {
            ok = false
        }
        if ok {
            r.passed(label)
        } else {
            r.fail += 1
        }
    }
}

priv fn run_job(j: Job, index: i64) -> Res {
    r := Res{}
    if j.skipped {
        r.say(fmt("SKIP ", j.dir[len("tests/")..], "/", j.name, ": ", j.why))
        r.skip += 1
        return r
    }
    jd := path_join(cfg.tmp, fmt("j", index))
    make_dir(jd)
    cerr := path_join(jd, "cerr")
    out := path_join(jd, "out")
    bin := path_join(jd, concat("bin", cfg.exe))
    base := j.src[..len(j.src) - len(path_ext(j.src)) - 1]
    match j.kind {
        Prog => prog(j, jd, &r)
        Check => {
            cmd := vec_of(cfg.alc)
            cmd.push("check")
            if file_exists(concat(base, ".target")) {
                cmd.extend([]str{"--target", content(concat(base, ".target"))})
            } else {
                cmd.extend(cfg.target)
            }
            cmd.extend(words(concat(base, ".flags")))
            cmd.push(j.src)
            if exec(cmd.items(), "", NULL_DEVICE, cerr) == 0 {
                r.passed(concat("check/", j.name))
            } else {
                r.say(fmt("FAIL check/", j.name, ": does not type-check"))
                r.show(head(slurp(cerr), 5))
                r.fail += 1
            }
        }
        Fail => {
            cmd := vec_of(cfg.alc)
            cmd.push("check")
            cmd.extend(cfg.target)
            cmd.extend(words(concat(base, ".flags")))
            cmd.push(j.src)
            if exec(cmd.items(), "", NULL_DEVICE, cerr) == 0 {
                r.say(fmt("FAIL ", j.name, ": expected a compile error"))
                r.fail += 1
            } else if lines_present(&r, j.name, "diagnostics lack", concat(base, ".err"), slurp(cerr), true) {
                r.passed(concat("fail/", j.name))
            } else {
                r.fail += 1
            }
        }
        Unit => {
            exp_code := "0"
            if file_exists(concat(base, ".code")) {
                exp_code = content(concat(base, ".code"))
            }
            cmd := vec_of(cfg.alc)
            cmd.push("test")
            cmd.extend(cfg.target)
            cmd.extend([]str{j.src, "-o", bin})
            env: []str
            if !HOST_WIN {
                env = []str{if cfg.win { "ALC_WINE=1" } else { "ALC_WINE=0" }}
            }
            code := exec(cmd.items(), "", out, path_join(jd, "err"), 0, env)
            label := concat("unit/", j.name)
            if !cfg.can_run {
                // (`alc test` builds the test program and says that this machine cannot run
                // it: that the program was written is all there is to check)
                if file_exists(bin) {
                    r.passed(label)
                } else {
                    r.say(fmt("FAIL ", label, ": compile error"))
                    r.show(head(slurp(path_join(jd, "err")), 5))
                    r.fail += 1
                }
            } else {
                ok := true
                got := slurp(out)
                want := slurp(concat(base, ".out"))
                if got != want {
                    r.say(fmt("FAIL ", label, ": stdout differs"))
                    r.show(diff(want, got, 10))
                    ok = false
                }
                if fmt(code) != exp_code {
                    r.say(fmt("FAIL ", label, ": exit code ", code, ", expected ", exp_code))
                    ok = false
                }
                if ok {
                    r.passed(label)
                } else {
                    r.fail += 1
                }
            }
        }
        All => {
            cmd := vec_of(cfg.alc)
            cmd.extend([]str{"check", "--all-targets"})
            cmd.extend(words(concat(base, ".flags")))
            cmd.push(j.src)
            if exec(cmd.items(), "", NULL_DEVICE, cerr) == 0 {
                r.passed(concat("all-targets ", j.src))
            } else {
                r.say(fmt("FAIL all-targets ", j.src, ": does not type-check for every target"))
                r.show(head(slurp(cerr), 5))
                r.fail += 1
            }
        }
        Driver => {
            scratch := path_join(cfg.tmp, concat("driver_", j.name))
            make_dir(scratch)
            if exec([]str{"bash", j.src, cfg.alc_abs, scratch}, "", out, out) == 0 {
                r.passed(concat("driver/", j.name))
            } else {
                r.say(concat("FAIL driver/", j.name))
                r.show(head(slurp(out), 10))
                r.fail += 1
            }
            remove_tree(scratch)
        }
    }
    remove_tree(jd)
    return r
}

// ---------- running the jobs ----------
priv struct Done { text: str, pass: i64, fail: i64, skip: i64, ready: bool }

priv struct Pool {
    jobs: []Job
    done: []Done            // per job; written under `mu`
    mu: Mutex
    cv: Cond                // signalled when a job is done
}

// a thread that runs the jobs `list` (indices), sharing the position in it with the other
// threads of the same list
priv struct Lane { pool: *Pool, list: []i64, pos: *i64 }

priv fn lane(l: Lane) {
    // what a job allocates is given back when it is done; its report is copied out first
    scratch: Region
    loop {
        k := atomic_add(l.pos, 1)
        if k >= len(l.list) {
            break
        }
        i := l.list[k]
        enter(&scratch)
        r := run_job(l.pool.jobs[i], i)
        leave()
        d := Done{text: clone(r.text.items()), pass: r.pass, fail: r.fail, skip: r.skip, ready: true}
        reset(&scratch)
        lock(&l.pool.mu)
        l.pool.done[i] = d
        broadcast(&l.pool.cv)
        unlock(&l.pool.mu)
    }
    region_free(&scratch)
}

priv fn usage() -> never {
    print(USAGE)
    exit(2)
}

// the jobs of this run, in the order their lines are printed
priv fn collect() -> []Job {
    jobs := vec[Job]()
    wskip := map[str, str]()
    if cfg.win {
        wskip = read_list("tests/windows.skip")
    }
    fn add(jobs: *Vec[Job], wskip: *Map[str, str], kind: Kind, dir: str, name: str, ext: str, listed: bool) {
        if len(cfg.filter) > 0 && find(name, cfg.filter) < 0 {
            return
        }
        j := Job{kind: kind, dir: dir, name: name, src: path_join(dir, concat(name, ext))}
        if listed {
            key := fmt(dir[len("tests/")..], "/", name)
            j.why, j.skipped = wskip.get(key)
        }
        jobs.push(j)
    }
    for dir in []str{"tests/run", "tests/std", "tests/sys"} {
        for name in stems(dir, ".al") {
            add(&jobs, &wskip, Prog, dir, name, ".al", true)
        }
    }
    for name in stems("tests/check", ".al") {
        add(&jobs, &wskip, Check, "tests/check", name, ".al", true)
    }
    for name in stems("tests/fail", ".al") {
        add(&jobs, &wskip, Fail, "tests/fail", name, ".al", true)
    }
    for name in stems("tests/unit", ".al") {
        add(&jobs, &wskip, Unit, "tests/unit", name, ".al", true)
    }
    // every target: the programs whose code differs per target (`when`), see the top
    if !cfg.win {
        one := read_list("tests/one_target")
        dirs := vec[str]()
        dirs.push("examples")
        for n in list_dir("examples") {
            if n[0] != '.' && is_dir(path_join("examples", n)) {
                dirs.push(path_join("examples", n))
            }
        }
        dirs.extend([]str{"tests/check", "tests/run", "tests/std"})
        for dir in dirs {
            for name in stems(dir, ".al") {
                src := path_join(dir, concat(name, ".al"))
                if one.has(src) {
                    continue
                }
                if starts_with(dir, "examples") {
                    if !has_line(slurp(src), "fn main", false) {
                        continue
                    }
                } else if dir == "tests/check" {
                    if file_exists(path_join(dir, concat(name, ".target"))) {
                        continue
                    }
                } else if !has_line(slurp(src), "when ", true) {
                    continue
                }
                add(&jobs, &wskip, All, dir, name, ".al", false)
            }
        }
    }
    // the Linux command line, by bash scripts
    if !cfg.win && !HOST_WIN {
        for name in stems("tests/driver", ".sh") {
            add(&jobs, &wskip, Driver, "tests/driver", name, ".sh", false)
        }
    }
    return jobs.items()
}

// Wine for the programs of a Windows target on Linux: the environment (prefix, no display, no
// sound), the prefix itself with the null display driver, and one server for the whole run
priv fn wine_start() {
    env := vec_of(cfg.env)
    prefix, has := env_get("WINEPREFIX")
    if !has || len(prefix) == 0 {
        prefix = path_join(current_dir(), "tmp/win/prefix-tests")
    }
    write_file(path_join(cfg.tmp, "alsa-none.conf"), "")
    env.extend([]str{concat("WINEPREFIX=", prefix), "WINEDEBUG=-all", "WINEDLLOVERRIDES=mscoree=;mshtml=",
        "DISPLAY", "WAYLAND_DISPLAY", fmt("PULSE_SERVER=unix:", cfg.tmp, "/no-sound-server"),
        fmt("ALSA_CONFIG_PATH=", cfg.tmp, "/alsa-none.conf")})
    cfg.env = env.items()
    if !have("wine") {
        print("tests/run.sh: --target windows needs wine")
        remove_tree(cfg.tmp)
        exit(2)
    }
    null := NULL_DEVICE
    if !is_dir(prefix) {
        make_dir(prefix)
        exec([]str{"wineboot", "-i"}, "", null, null)
    }
    // one wine server for the whole run (a starting server writes noise to standard error); the
    // null display driver must be set before the server starts the desktop, hence the restart.
    // The server stays for a minute after its last program, so that it also ends after a run
    // that was interrupted.
    exec([]str{"wineserver", "-p60"}, "", "", "")
    exec([]str{"wine", "reg", "add", "HKCU\\Software\\Wine\\Drivers", "/v", "Graphics", "/d", "null", "/f"}, "", null, null)
    exec([]str{"wineserver", "-k"}, "", "", "")
    exec([]str{"wineserver", "-p60"}, "", "", "")
    exec([]str{"wine", "cmd", "/c", "exit"}, "", null, null)
}

fn main() -> i64 {
    a := args()[1..]
    win := HOST_WIN
    host_exe := ""
    threads := cpu_count()
    i := 0
    while i < len(a) {
        if a[i] == "-v" {
            cfg.verbose = true
            i += 1
            continue
        }
        if a[i] != "--target" && a[i] != "--host-wine" && a[i] != "-j" {
            break
        }
        if i + 1 >= len(a) || len(a[i + 1]) == 0 {
            usage()
        }
        v := a[i + 1]
        if a[i] == "--target" {
            if v != "windows" && v != "linux" {
                usage()
            }
            win = v == "windows"
        } else if a[i] == "-j" {
            n, ok := parse_i64(v)
            if !ok || n < 1 {
                usage()
            }
            threads = n
        } else {
            host_exe = if HOST_WIN { v } else { absolute(v) }
        }
        i += 2
    }
    a = a[i..]
    if len(host_exe) > 0 && (!win || HOST_WIN) {
        usage()
    }
    if !is_dir("tests/run") {
        print("tests/run: not in the repository root (tests/run.sh and tests\\run.bat start the runner there)")
        return 2
    }
    cfg.win = win
    cfg.can_run = win || !HOST_WIN
    cfg.via_run = win && (HOST_WIN || len(host_exe) > 0)
    cfg.exe = if win { ".exe" } else { "" }
    if win != HOST_WIN || win {
        cfg.target = []str{"--target", if win { "windows" } else { "linux" }}
    }
    if len(host_exe) > 0 {
        cfg.alc = []str{"wine", host_exe}
    } else {
        cfg.alc = []str{if len(a) > 0 && len(a[0]) > 0 { a[0] } else if HOST_WIN { "build/alc.exe" } else { "./build/alc" }}
        a = a[min(1, len(a))..]
    }
    cfg.alc_abs = if HOST_WIN { cfg.alc[0] } else { absolute(cfg.alc[0]) }
    if len(a) > 0 {
        cfg.filter = a[0]
    }
    // the directory of this run
    root := "/tmp"
    for v in []str{"TMPDIR", "TEMP", "TMP"} {
        d, has := env_get(v)
        if has && is_dir(d) {
            root = d
            break
        }
    }
    cfg.tmp = path_join(root, fmt("altest.", process_id()))
    remove_tree(cfg.tmp)
    if !make_dir(cfg.tmp) {
        print(fmt("tests/run: cannot make the directory ", cfg.tmp, ": ", error_text(io_error())))
        return 2
    }
    if !HOST_WIN {
        // (the C libraries of tests/sys, see NAME.c at the top)
        clib := path_join(cfg.tmp, "clib")
        make_dir(clib)
        old, has := env_get("LD_LIBRARY_PATH")
        cfg.env = []str{if has && len(old) > 0 { fmt("LD_LIBRARY_PATH=", clib, ":", old) } else { concat("LD_LIBRARY_PATH=", clib) }}
    }
    cfg.wcc = "x86_64-w64-mingw32-gcc"
    if HOST_WIN && !have(cfg.wcc) && have("gcc") {
        cfg.wcc = "gcc"
    }
    if win && !HOST_WIN {
        wine_start()
        cfg.runner = []str{"wine"}
    }
    if !cfg.can_run {
        print("tests/run: this machine cannot run Linux programs: they are built and checked, not run")
    }

    pool := Pool{jobs: collect()}
    n := len(pool.jobs)
    pool.done = alloc[Done](n)
    // the tests of tests/sys one after the other in a thread of their own, the others spread
    // over the worker threads
    spread := vec[i64]()
    single := vec[i64]()
    for k, j in pool.jobs {
        if j.dir == "tests/sys" && threads > 1 {
            single.push(k)
        } else {
            spread.push(k)
        }
    }
    spread_pos := 0
    single_pos := 0
    ts := vec[Thread]()
    for _ in 0..min(threads, spread.len) {
        t, ok := thread_spawn(lane, Lane{&pool, spread.items(), &spread_pos})
        if ok {
            ts.push(t)
        }
    }
    if ts.len == 0 {
        // (no thread could be started: this one does the work)
        lane(Lane{&pool, spread.items(), &spread_pos})
    }
    t, ok := thread_spawn(lane, Lane{&pool, single.items(), &single_pos})
    if ok {
        ts.push(t)
    } else {
        lane(Lane{&pool, single.items(), &single_pos})
    }
    pass := 0
    fail := 0
    skip := 0
    for k in 0..n {
        lock(&pool.mu)
        while !pool.done[k].ready {
            wait(&pool.cv, &pool.mu)
        }
        d := pool.done[k]
        unlock(&pool.mu)
        put(d.text)
        flush()
        pass += d.pass
        fail += d.fail
        skip += d.skip
    }
    for k in 0..ts.len {
        thread_join(&ts[k])
    }
    if win && !HOST_WIN {
        exec([]str{"wineserver", "-k"}, "", "", "")
    }
    remove_tree(cfg.tmp)
    if skip == 0 {
        print(fmt("conformance: ", pass, " passed, ", fail, " failed"))
    } else {
        print(fmt("conformance: ", pass, " passed, ", fail, " failed, ", skip, " skipped"))
    }
    return if fail == 0 { 0 } else { 1 }
}
