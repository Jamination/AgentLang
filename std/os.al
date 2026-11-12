// std.os: running other programs (to their end or in the background), shared memory, and what a
// process knows about itself. `use std.os`.
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
    _, status := start(argv, 0)
    e := io_error()
    release(m)
    __io_result(-e)
    return status
}

// runs a program and returns what it wrote to standard output (its standard error goes where
// that of this process goes), and the status. The output is "" if it could not be started.
fn run_capture(argv: []str) -> (str, i64) {
    return start(argv, 1)
}

// the same with standard output and standard error together, in the order they were written
fn run_capture_all(argv: []str) -> (str, i64) {
    return start(argv, 2)
}

// ---------- background processes ----------
// A program started by `spawn` that runs alongside this process. Copies of a Process are the
// same process.
struct Process {
    id: i64                 // the process id; 0 for a Process that was not started
    state: *ProcessState
}

priv struct ProcessState {
    done: bool              // waited for: `status` is final and the id may belong to another process
    status: i64
}

// Starts the program argv[0] (looked up in PATH as by `run`) with the arguments argv[1..], the
// environment, standard input, output and error of this process, and returns at once:
// (the process, true), or (Process{}, false) if it could not be started (`io_error()` is the
// reason). Wait for it with `wait` (or `try_wait` until it has ended): a process that has
// ended stays in the process table (a zombie) until it is waited for, or until this process
// exits.
fn spawn(argv: []str) -> (Process, bool) {
    state := new[ProcessState]()
    m := mark()
    pid, _ := launch(argv, 0)
    e := io_error()
    release(m)
    __io_result(-e)
    if pid < 0 {
        return (Process{}, false)
    }
    return (Process{id: pid, state: state}, true)
}

// the process id
fn pid(p: Process) -> i64 {
    return p.id
}

// Waits until the process has ended and returns its status, as `run` does (exit status, or
// 128 + the signal number). Waiting again returns the same status. -1 with io_error() 10 for a
// Process that was not started.
fn wait(p: Process) -> i64 {
    if p.state == nil {
        __io_result(-10)
        return -1
    }
    if !p.state.done {
        status: [1]i32
        r := 0
        loop {
            r = syscall(61, p.id, ptr(status), 0, 0)    // wait4
            if r != -4 {
                break
            }
        }
        if __io_result(r) < 0 {
            return -1
        }
        p.state.done = true
        p.state.status = decode_status(i64(status[0]))
    }
    __io_result(0)
    return p.state.status
}

// Does not wait: (status, true) if the process has ended (it is waited for then), (0, false)
// while it runs; (-1, true) if it cannot be waited for (see io_error()).
fn try_wait(p: Process) -> (i64, bool) {
    if p.state == nil {
        __io_result(-10)
        return (-1, true)
    }
    if !p.state.done {
        status: [1]i32
        r := 0
        loop {
            r = syscall(61, p.id, ptr(status), 1, 0)    // wait4(WNOHANG)
            if r != -4 {
                break
            }
        }
        if __io_result(r) < 0 {
            return (-1, true)
        }
        if r == 0 {
            return (0, false)
        }
        p.state.done = true
        p.state.status = decode_status(i64(status[0]))
    }
    __io_result(0)
    return (p.state.status, true)
}

// Sends a signal (15 SIGTERM: asks to end, 9 SIGKILL: ends it, 2 SIGINT, 0: none, only checks
// that the process is there). false if that fails (io_error()), also once the process has been
// waited for (3: no such process); a process that has ended but was not waited for takes
// signals without effect.
fn kill(p: Process, signal: i64) -> bool {
    if p.state == nil || p.state.done {
        __io_result(-3)
        return false
    }
    return __io_result(syscall(62, p.id, signal)) >= 0
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

// the status of `run` from the status word of wait4
priv fn decode_status(st: i64) -> i64 {
    if st & 0x7F == 0 {
        return (st >> 8) & 0xFF
    }
    return 128 + (st & 0x7F)
}

// Starts argv; capture: 0 nothing, 1 standard output, 2 standard output and standard error go to
// a pipe. Returns (process id, read end of the pipe or -1) once the program runs, (-1, -1) if
// it could not be started (io_error(); a child that could not execute the program is waited for).
priv fn launch(argv: []str, capture: i64) -> (i64, i64) {
    if len(argv) == 0 {
        __io_result(-22)
        return (-1, -1)
    }
    file, e := locate(argv[0])
    if e != 0 {
        __io_result(-e)
        return (-1, -1)
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
        return (-1, -1)
    }
    note_r := i64(fds[0])
    note_w := i64(fds[1])
    if capture != 0 && __io_result(syscall(293, &fds[2], 0x80000)) < 0 {
        syscall(3, note_r)
        syscall(3, note_w)
        return (-1, -1)
    }
    pipe_r := if capture != 0 { i64(fds[2]) } else { -1 }
    pipe_w := i64(fds[3])
    pid := __io_result(syscall(57))
    if pid == 0 {
        if capture != 0 {
            // (dup2 clears O_CLOEXEC on the copies)
            syscall(33, pipe_w, 1)
            if capture == 2 {
                syscall(33, pipe_w, 2)
            }
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
        if pipe_r >= 0 {
            syscall(3, pipe_r)
        }
        return (-1, -1)
    }
    failed: [1]i64
    loop {
        r := syscall(0, note_r, ptr(failed), 8)
        if r != -4 {
            break
        }
    }
    syscall(3, note_r)
    if failed[0] != 0 {
        // the child exits at once: wait for it
        status: [1]i32
        loop {
            if syscall(61, pid, ptr(status), 0, 0) != -4 {
                break
            }
        }
        if pipe_r >= 0 {
            syscall(3, pipe_r)
        }
        __io_result(-failed[0])
        return (-1, -1)
    }
    __io_result(0)
    return (pid, pipe_r)
}

// runs to the end; capture as in `launch`
priv fn start(argv: []str, capture: i64) -> (str, i64) {
    pid, pipe_r := launch(argv, capture)
    if pid < 0 {
        return ("", -1)
    }
    out := ""
    if pipe_r >= 0 {
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
    __io_result(0)
    return (out, decode_status(i64(status[0])))
}

// ---------- shared memory and file descriptors ----------
// Memory that another process maps too: a Wayland compositor (wl_shm), a child process. The
// file descriptor is what is handed over; the memory stays valid until `unmap`, also after
// the descriptor is closed.

// A new anonymous file of `size` bytes (zeros) in memory: (descriptor, true), or (-1, false)
// with the reason in io_error(). It is closed when a program is started (close-on-exec).
fn shm_create(size: i64) -> (i64, bool) {
    fd := __io_result(syscall(319, ptr("al-shm"), 1))   // memfd_create(name, MFD_CLOEXEC)
    if fd < 0 {
        return (-1, false)
    }
    if __io_result(syscall(77, fd, size)) < 0 {          // ftruncate
        e := io_error()
        syscall(3, fd)
        __io_result(-e)
        return (-1, false)
    }
    return (fd, true)
}

// The first `size` bytes of the file `fd` as memory that is shared with every other mapping of
// the file (writes are seen by the other process): (bytes, true), or (empty, false) with the
// reason in io_error(). Give it back with `unmap`.
fn map_shared(fd: i64, size: i64) -> ([]u8, bool) {
    return map(fd, size, 3, 1)                           // PROT_READ | PROT_WRITE, MAP_SHARED
}

// The first `size` bytes of the file `fd`, read-only and private to this process (for a file
// the other side may have opened read-only, like the keymap of wl_keyboard.keymap).
fn map_readonly(fd: i64, size: i64) -> ([]u8, bool) {
    return map(fd, size, 1, 2)                           // PROT_READ, MAP_PRIVATE
}

priv fn map(fd: i64, size: i64, prot: i64, flags: i64) -> ([]u8, bool) {
    empty: []u8
    if size <= 0 {
        __io_result(-22)
        return (empty, false)
    }
    mem := syscall(9, 0, size, prot, flags, fd, 0)       // mmap
    if mem < 0 && mem > -4096 {
        __io_result(mem)
        return (empty, false)
    }
    __io_result(0)
    return (mkslice[u8](cast[*u8](mem), size), true)
}

// Gives back memory of `map_shared` / `map_readonly` (the whole slice that it returned).
fn unmap(s: []u8) -> bool {
    return __io_result(syscall(11, ptr(s), len(s))) >= 0    // munmap
}

// Closes a file descriptor (of `shm_create`, or one received from another process).
fn close_fd(fd: i64) -> bool {
    return __io_result(syscall(3, fd)) >= 0
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
