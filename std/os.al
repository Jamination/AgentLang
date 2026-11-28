// std.os: running other programs (to their end or in the background), shared memory, what a
// process knows about itself, and threads with mutexes and condition variables. `use std.os`.
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

priv tmp_seq: i64

// Returns the system temporary directory (TMPDIR / TEMP / TMP, falling back to /tmp or .).
fn temp_dir() -> str {
    when TARGET_OS == Windows {
        for k in []str{"TEMP", "TMP", "TMPDIR"} {
            v, ok := env_get(k)
            if ok && len(v) > 0 {
                return v
            }
        }
        return "."
    } else {
        for k in []str{"TMPDIR", "TMP", "TEMP"} {
            v, ok := env_get(k)
            if ok && len(v) > 0 {
                return v
            }
        }
        return "/tmp"
    }
}

// Runs `argv` and captures standard output and standard error separately: (stdout, stderr, status).
fn run_capture_split(argv: []str) -> (str, str, i64) {
    return run_with_stdin(argv, "")
}

// Runs `argv` feeding `stdin_data` as standard input and capturing stdout and stderr separately:
// (stdout, stderr, status). Status is -1 on launch failure (see io_error()).
fn run_with_stdin(argv: []str, stdin_data: str) -> (str, str, i64) {
    seq := atomic_add(&tmp_seq, 1)
    tag := fmt("al_proc_", process_id(), "_", seq)
    dir := temp_dir()
    p_in := path_join(dir, concat(tag, ".in"))
    p_out := path_join(dir, concat(tag, ".out"))
    p_err := path_join(dir, concat(tag, ".err"))
    has_in := len(stdin_data) > 0
    if has_in && !write_file(p_in, stdin_data) {
        return ("", "", -1)
    }
    defer {
        if has_in {
            remove_file(p_in)
        }
        remove_file(p_out)
        remove_file(p_err)
    }
    st := run(argv, Launch{stdin: if has_in { p_in } else { "" }, stdout: p_out, stderr: p_err})
    e := io_error()
    out, _ := read_file(p_out)
    err, _ := read_file(p_err)
    __io_result(-e)
    return (out, err, st)
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
    group: i64              // and, not 0, its group of Launch.group by (Windows: the job)
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
        ended(p.state, st)
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
        ended(p.state, st)
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
    if p.state.group != 0 { return __io_result(__os_kill_group(p.id, p.state.handle, p.state.group, signal)) >= 0 }
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
    if st < 0 {
        __io_result(st)
        return (out, -1)
    }
    __io_result(0)
    return (out, st)
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

// ---------- threads ----------
// Threads run AL code at the same time in this process; docs/std/os.md has the rules. A
// thread allocates from an arena of its own; when it has been joined, that arena is the
// joiner's region `t.region` (results stay valid without a copy; region_free(&t.region) gives
// the memory back). A panic in any thread ends the process.

// A started thread. Copies of a Thread are the same thread; only one of them is joined.
struct Thread {
    id: i64                 // its thread_id(); 0 for a Thread that was not started
    region: Region          // after thread_join: the memory the thread allocated (the caller's)
    ctl: *__ThreadCtl
    gen: i64
}

// the stack of a thread of thread_spawn without a size: 8 MiB (reserved, used as it grows)
priv const STACK = 8 << 20

// Starts a thread that runs f(ctx); ctx is copied (what its slices and pointers refer to is
// shared). (the thread, true), or (Thread{}, false) if it could not be started: io_error()
// says why (12: not enough memory; 38: a dynamically linked program whose libraries lack the
// C library's threads).
fn thread_spawn[C](f: fn(C), ctx: C) -> (Thread, bool) {
    return thread_spawn(f, ctx, STACK)
}

// the same with a stack of `stack` bytes (at least 64 KiB)
fn thread_spawn[C](f: fn(C), ctx: C, stack: i64) -> (Thread, bool) {
    c := __thread_start(f, ctx, stack)
    if c == nil {
        return (Thread{}, false)
    }
    return (Thread{id: c.id - 1, ctl: c, gen: c.gen}, true)
}

// Waits until the thread has ended; its memory becomes t.region. Joining a thread twice (also
// through a copy), joining Thread{} or the calling thread itself stops the program.
fn thread_join(t: *Thread) {
    __at_thread_join(t, "?")
}

fn __at_thread_join(t: *Thread, at: str) {
    c := t.ctl
    if c == nil || c.gen != t.gen {
        __panic(at, "thread_join: the thread was joined already (or never started)")
    }
    if c.id == __thread_key() {
        __panic(at, "thread_join: a thread cannot join itself")
    }
    _, ok := atomic_cas(&c.joining, 0, 1)
    if !ok {
        __panic(at, "thread_join: the thread was joined already (or never started)")
    }
    t.region = __thread_join(c)
    t.ctl = nil
}

// the calling thread's id: 0 in the main thread, 1, 2, ... for the threads in the order they
// were started (a thread a C library created gets the next one when it first needs one)
fn thread_id() -> i64 {
    return __thread_id()
}

// the number of CPUs this process may run on (Linux: its affinity mask)
fn cpu_count() -> i64 {
    return __os_cpu_count()
}

// A mutual exclusion lock; the zero value is unlocked. Locked by at most one thread at a
// time; only that thread may unlock it. Not recursive. Must not be copied while in use.
struct Mutex {
    state: i64              // the OS layer's lock
    owner: i64              // the id + 1 of the thread that holds it, 0 if none
}

// waits until m is free and locks it (locking it again in the thread that holds it panics)
fn lock(m: *Mutex) {
    __at_lock(m, "?")
}

fn __at_lock(m: *Mutex, at: str) {
    me := __thread_key()
    if atomic_load(&m.owner) == me {
        __panic(at, "lock: this thread holds the mutex already")
    }
    __os_lock(&m.state)
    atomic_store(&m.owner, me)
}

// locks m if it is free; false if another thread holds it (or this one)
fn try_lock(m: *Mutex) -> bool {
    me := __thread_key()
    if atomic_load(&m.owner) == me || !__os_try_lock(&m.state) {
        return false
    }
    atomic_store(&m.owner, me)
    return true
}

// unlocks m, which this thread must hold
fn unlock(m: *Mutex) {
    __at_unlock(m, "?")
}

fn __at_unlock(m: *Mutex, at: str) {
    if atomic_load(&m.owner) != __thread_key() {
        __panic(at, "unlock: this thread does not hold the mutex")
    }
    atomic_store(&m.owner, 0)
    __os_unlock(&m.state)
}

// A condition variable: threads wait on it (with a Mutex) until another one signals it. The
// zero value is usable. Must not be copied while in use.
struct Cond {
    state: i64              // the OS layer's condition variable
}

// Unlocks m (which this thread must hold), waits until c is signalled, locks m again. It may
// also return without a signal: wait in a loop that checks the condition.
fn wait(c: *Cond, m: *Mutex) {
    __at_wait(c, m, "?")
}

fn __at_wait(c: *Cond, m: *Mutex, at: str) {
    cond_wait(c, m, -1, at)
}

// the same, waiting at most timeout_ns nanoseconds: false if the time ran out
fn wait(c: *Cond, m: *Mutex, timeout_ns: i64) -> bool {
    return __at_wait(c, m, timeout_ns, "?")
}

fn __at_wait(c: *Cond, m: *Mutex, timeout_ns: i64, at: str) -> bool {
    return cond_wait(c, m, max(timeout_ns, 0), at)
}

priv fn cond_wait(c: *Cond, m: *Mutex, ns: i64, at: str) -> bool {
    me := __thread_key()
    if atomic_load(&m.owner) != me {
        __panic(at, "wait: this thread does not hold the mutex")
    }
    atomic_store(&m.owner, 0)
    r := __os_cond_wait(&c.state, &m.state, ns)
    atomic_store(&m.owner, me)
    return r
}

// wakes one thread that waits on c (none if none waits)
fn signal(c: *Cond) {
    __os_cond_wake(&c.state, false)
}

// wakes every thread that waits on c
fn broadcast(c: *Cond) {
    __os_cond_wake(&c.state, true)
}

// ---------- files as standard streams, a changed environment, groups, time limits ----------
// (At the end of the file, and the lines above it are where they were (one field more, one
// statement more in `kill`, one less in each `wait`): a program that uses no process of its
// own is built as before, source lines of its stack traces included.)

// How `run` and `spawn` start a program whose streams or environment are not those of this
// process, or that is to be ended together with what it starts. The zero value changes
// nothing.
struct Launch {
    stdin: str              // the file it reads as standard input ("": that of this process)
    stdout: str             // the file that takes its standard output, created or emptied
    stderr: str             // the same for standard error; the same path as stdout: one file
                            // takes both, in the order written
    env: []str              // "NAME=value" sets a variable for the program, "NAME" removes it
    group: bool             // the program starts a process group of its own (Windows: a job),
                            // which the processes it starts belong to as well: `kill` then
                            // reaches all of them
}

// the file that is always empty when read and drops what is written to it: as Launch.stdin
// the program has nothing to read, as stdout / stderr its output is discarded
when TARGET_OS == Windows {
    const NULL_DEVICE = "NUL"
} else {
    const NULL_DEVICE = "/dev/null"
}

// the process has ended with the status st and was waited for
priv fn ended(s: *ProcessState, st: i64) {
    s.done = true
    s.status = u8(st)
    if s.group != 0 {
        __os_group_close(s.group)
        s.group = 0
    }
}

// `spawn` with the streams, environment and group of `how`: (Process{}, false) also if one
// of its files cannot be opened (io_error()). The program is looked up in the PATH of this
// process. `kill` of a process with a group sends the signal to every process of the group
// (Windows: ends them all).
fn spawn(argv: []str, how: Launch) -> (Process, bool) {
    state := new[ProcessState]()
    m := mark()
    pid, handle, group := __os_spawn_files(argv, how.stdin, how.stdout, how.stderr, how.env, how.group)
    e := io_error()
    release(m)
    __io_result(-e)
    if pid < 0 {
        return (Process{}, false)
    }
    state.handle = handle
    state.group = group
    return (Process{id: pid, state: state}, true)
}

// `run` with the streams and environment of `how`: the status, -1 if the program could not
// be started (io_error())
fn run(argv: []str, how: Launch) -> i64 {
    p, ok := spawn(argv, how)
    if !ok {
        return -1
    }
    return wait(p)
}

// Waits until the process has ended, but at most timeout_ns nanoseconds: (status, true) once
// it has ended (it is waited for then), (0, false) if it still runs when the time is over;
// (-1, true) if it cannot be waited for (see io_error()). wait(p, 0) is try_wait(p).
fn wait(p: Process, timeout_ns: i64) -> (i64, bool) {
    if p.state == nil {
        __io_result(-10)
        return (-1, true)
    }
    if !p.state.done {
        st := __os_wait_ns(p.id, p.state.handle, max(timeout_ns, 0))
        if st == -1 {
            return (-1, true)
        }
        if st == -2 {
            return (0, false)
        }
        ended(p.state, st)
    }
    __io_result(0)
    return (i64(p.state.status), true)
}
