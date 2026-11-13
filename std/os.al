// std.os: running other programs (to their end or in the background), shared memory, and what a
// process knows about itself. `use std.os`.
// For tools and build scripts. The system calls are those of the OS layer of the prelude (no
// libc): a program using this module stays a static executable on Linux and imports only
// kernel32.dll on Windows. The file and directory functions (file_exists, is_dir, make_dir,
// list_dir, rename, remove_file, remove_dir, file_size, modified_time, path_join, ...) are those
// of std.asset, which this module loads.
use std.asset

// ---------- processes ----------
// The three `run` functions start the program argv[0] with the arguments argv[1..] and the
// environment of this process, and wait until it has ended. A name without '/' is looked up in
// the directories of PATH (Windows: a name without '/' or '\', in the directories of PATH
// separated by ';', with ".exe" appended if it has no extension). The status is the program's
// exit status (0..255), or 128 + the signal number if a signal ended it (Windows: an
// exception, see docs/std/os.md), or -1 if it could not be started: then `io_error()` is the
// reason (2: no such program, 13: not executable, ...). After a start io_error() is 0.
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
    status: u8              // 0..255: exit status or 128 + signal
    handle: i64             // what the OS layer knows the process by (Windows: its handle)
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
    pid, handle, _ := __os_spawn(argv, 0)
    e := io_error()
    release(m)
    __io_result(-e)
    if pid < 0 {
        return (Process{}, false)
    }
    state.handle = handle
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
        st := __os_wait(p.id, p.state.handle, true)
        if st < 0 {
            return -1
        }
        p.state.done = true
        p.state.status = u8(st)
    }
    __io_result(0)
    return i64(p.state.status)
}

// Does not wait: (status, true) if the process has ended (it is waited for then), (0, false)
// while it runs; (-1, true) if it cannot be waited for (see io_error()).
fn try_wait(p: Process) -> (i64, bool) {
    if p.state == nil {
        __io_result(-10)
        return (-1, true)
    }
    if !p.state.done {
        st := __os_wait(p.id, p.state.handle, false)
        if st == -1 {
            return (-1, true)
        }
        if st == -2 {
            return (0, false)
        }
        p.state.done = true
        p.state.status = u8(st)
    }
    __io_result(0)
    return (i64(p.state.status), true)
}

// Sends a signal (15 SIGTERM: asks to end, 9 SIGKILL: ends it, 2 SIGINT, 0: none, only checks
// that the process is there). false if that fails (io_error()), also once the process has been
// waited for (3: no such process); a process that has ended but was not waited for takes
// signals without effect. Windows has no signals: any signal but 0 ends the process at once,
// and its status is 128 + the signal.
fn kill(p: Process, signal: i64) -> bool {
    if p.state == nil || p.state.done {
        __io_result(-3)
        return false
    }
    return __io_result(__os_kill(p.id, p.state.handle, signal)) >= 0
}

// runs to the end; capture: 0 nothing, 1 standard output, 2 standard output and standard error
// go to a pipe whose content is returned
priv fn start(argv: []str, capture: i64) -> (str, i64) {
    pid, handle, pipe_r := __os_spawn(argv, capture)
    if pid < 0 {
        return ("", -1)
    }
    out := ""
    if pipe_r >= 0 {
        out = read_all(pipe_r)
        __os_close(pipe_r)
    }
    st := __os_wait(pid, handle, true)
    __io_result(0)
    return (out, max(st, 0))
}

// ---------- shared memory and file descriptors ----------
// Memory that another process maps too: a Wayland compositor (wl_shm), a child process. The
// file descriptor is what is handed over; the memory stays valid until `unmap`, also after
// the descriptor is closed. (Windows: the "descriptor" is a handle of a file mapping object,
// or of a file for map_readonly.)

// A new anonymous file of `size` bytes (zeros) in memory: (descriptor, true), or (-1, false)
// with the reason in io_error(). It is closed when a program is started (close-on-exec).
fn shm_create(size: i64) -> (i64, bool) {
    fd := __io_result(__os_shm_create(size))
    if fd < 0 {
        return (-1, false)
    }
    return (fd, true)
}

// The first `size` bytes of the file `fd` as memory that is shared with every other mapping of
// the file (writes are seen by the other process): (bytes, true), or (empty, false) with the
// reason in io_error(). Give it back with `unmap`.
fn map_shared(fd: i64, size: i64) -> ([]u8, bool) {
    return map(fd, size, true)
}

// The first `size` bytes of the file `fd`, read-only and private to this process (for a file
// the other side may have opened read-only, like the keymap of wl_keyboard.keymap).
fn map_readonly(fd: i64, size: i64) -> ([]u8, bool) {
    return map(fd, size, false)
}

priv fn map(fd: i64, size: i64, write: bool) -> ([]u8, bool) {
    empty: []u8
    if size <= 0 {
        __io_result(-22)
        return (empty, false)
    }
    mem := __os_map_fd(fd, size, write)
    if mem < 0 && mem > -4096 {
        __io_result(mem)
        return (empty, false)
    }
    __io_result(0)
    return (mkslice[u8](cast[*u8](mem), size), true)
}

// Gives back memory of `map_shared` / `map_readonly` (the whole slice that it returned).
fn unmap(s: []u8) -> bool {
    return __io_result(__os_unmap(cast[i64](ptr(s)), len(s))) >= 0
}

// Closes a file descriptor (of `shm_create`, or one received from another process).
fn close_fd(fd: i64) -> bool {
    return __io_result(__os_close(fd)) >= 0
}

// ---------- this process ----------
// (program arguments: args(); environment variables: env_get(name); ending: exit(code))

// the process id
fn process_id() -> i64 {
    return __os_process_id()
}

// the absolute path of the working directory ("" if it cannot be told: see io_error())
fn current_dir() -> str {
    return __os_current_dir()
}
