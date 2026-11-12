// std.os: running other programs, and what a process knows about itself. `use std.os`.
// For tools and build scripts. Raw Linux system calls (no libc): a program using this module
// stays a static executable. The file and directory functions (file_exists, is_dir, make_dir,
// list_dir, rename, remove_file, remove_dir, file_size, modified_time, path_join, ...) are those
// of std.asset, which this module loads.
use std.asset

// ---------- processes ----------
// The three `run` functions start the program argv[0] with the arguments argv[1..] and the
// environment of this process, and wait until it has ended. A name without '/' is looked up in
// the directories of PATH. The status is the program's exit status (0..255), or 128 + the
// signal number if a signal ended it, or -1 if it could not be started: then `io_error()` is
// the reason (2: no such program, 13: not executable, ...). After a start io_error() is 0.
// The program reads the standard input of this process.

// runs a program; its output goes where the output of this process goes
fn run(argv: []str) -> i64 {
    m := mark()
    _, status := spawn(argv, 0)
    e := io_error()
    release(m)
    __io_result(-e)
    return status
}

// runs a program and returns what it wrote to standard output (its standard error goes where
// that of this process goes), and the status. The output is "" if it could not be started.
fn run_capture(argv: []str) -> (str, i64) {
    return spawn(argv, 1)
}

// the same with standard output and standard error together, in the order they were written
fn run_capture_all(argv: []str) -> (str, i64) {
    return spawn(argv, 2)
}

priv const DEFAULT_PATH = "/usr/local/bin:/usr/bin:/bin"

// the file to execute for `name`: the name itself if it has a '/', else the first executable
// file of that name in the directories of PATH; ("", error number) if there is none
priv fn locate(name: str) -> (str, i64) {
    if len(name) == 0 {
        return ("", 2)
    }
    if find(name, "/") >= 0 {
        return (name, 0)
    }
    path, has := env_get("PATH")
    if !has {
        path = DEFAULT_PATH
    }
    e := 2
    for dir in split(path, ':') {
        file := if len(dir) == 0 { name } else { path_join(dir, name) }
        // access(file, X_OK); a directory is "executable" too
        r := syscall(21, cstr(file), 1)
        if r == 0 && !is_dir(file) {
            return (file, 0)
        }
        if r == -13 {
            e = 13
        }
    }
    return ("", e)
}

// capture: 0 nothing, 1 standard output, 2 standard output and standard error
priv fn spawn(argv: []str, capture: i64) -> (str, i64) {
    if len(argv) == 0 {
        __io_result(-22)
        return ("", -1)
    }
    file, e := locate(argv[0])
    if e != 0 {
        __io_result(-e)
        return ("", -1)
    }
    flush()
    cargs := alloc[i64](len(argv) + 1)
    for i, a in argv {
        cargs[i] = cast[i64](cstr(a))
    }
    cfile := cstr(file)
    envp := __argv + 8 * (__argc + 1)
    // `note` tells whether execve worked: it is closed by a successful execve (O_CLOEXEC),
    // and carries the error number otherwise. `pipe` takes the output.
    fds: [4]i32
    if __io_result(syscall(293, ptr(fds), 0x80000)) < 0 {
        return ("", -1)
    }
    note_r := i64(fds[0])
    note_w := i64(fds[1])
    if capture != 0 && __io_result(syscall(293, &fds[2], 0)) < 0 {
        syscall(3, note_r)
        syscall(3, note_w)
        return ("", -1)
    }
    pipe_r := i64(fds[2])
    pipe_w := i64(fds[3])
    pid := __io_result(syscall(57))
    if pid == 0 {
        if capture != 0 {
            syscall(33, pipe_w, 1)
            if capture == 2 {
                syscall(33, pipe_w, 2)
            }
            syscall(3, pipe_r)
            syscall(3, pipe_w)
        }
        failed: [1]i64
        failed[0] = -syscall(59, cfile, ptr(cargs), envp)
        syscall(1, note_w, ptr(failed), 8)
        syscall(231, 127)
    }
    syscall(3, note_w)
    if capture != 0 {
        syscall(3, pipe_w)
    }
    if pid < 0 {
        syscall(3, note_r)
        if capture != 0 {
            syscall(3, pipe_r)
        }
        return ("", -1)
    }
    failed: [1]i64
    loop {
        r := syscall(0, note_r, ptr(failed), 8)
        if r != -4 {
            break
        }
    }
    syscall(3, note_r)
    out := ""
    if capture != 0 {
        out = read_all(pipe_r)
        syscall(3, pipe_r)
    }
    status: [1]i32
    loop {
        r := syscall(61, pid, ptr(status), 0, 0)
        if r != -4 {
            break
        }
    }
    if failed[0] != 0 {
        __io_result(-failed[0])
        return ("", -1)
    }
    __io_result(0)
    st := i64(status[0])
    if st & 0x7F == 0 {
        return (out, (st >> 8) & 0xFF)
    }
    return (out, 128 + (st & 0x7F))
}

// ---------- this process ----------
// (program arguments: args(); environment variables: env_get(name); ending: exit(code))

// the process id
fn process_id() -> i64 {
    return syscall(39)
}

// the absolute path of the working directory ("" if it cannot be told: see io_error())
fn current_dir() -> str {
    buf: [4096]u8
    n := __io_result(syscall(79, ptr(buf), 4096))
    if n <= 0 {
        return ""
    }
    return concat(from_cstr(ptr(buf)), "")
}
