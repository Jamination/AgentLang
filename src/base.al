// Helpers shared by the compiler sources: Vec conveniences, processes, working memory.

// ---------- Vec ----------
// Vecs of one and two elements without an intermediate slice (`succs` in ir.al is hot:
// vec_of([]i64{t}) there costs 15 % of the whole compile time)
fn vec_one[T](a: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(sizeof[T]()), 1)
    buf[0] = a
    return Vec[T]{buf: buf, len: 1}
}

fn vec_two[T](a: T, b: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(2 * sizeof[T]()), 2)
    buf[0] = a
    buf[1] = b
    return Vec[T]{buf: buf, len: 2}
}

// ---------- process ----------
// The system the compiler runs on (its host) is TARGET_OS: the target the compiler was built
// for. src/host_linux.al and src/host_windows.al define for it:
//   make_executable(path) -> bool  marks a file as executable (mode 0755; nothing to do on
//                                  Windows)
//   run_program_env(path, argv, drop, add) -> i64
//                                  runs a program with arguments and the current environment
//                                  without the variables named in `drop` and with the
//                                  `NAME=value` entries of `add`, waits for it and returns its
//                                  exit status (128 + signal number if a signal ended it, -1 if
//                                  it could not be started); it gets the stack limit and the
//                                  environment the compiler was started with (see with_stack)
//   with_stack(bytes, f) -> i64    deep recursion needs a big stack: calls f with a stack of at
//                                  least `bytes` and returns its result. Linux raises the stack
//                                  limit and starts the compiler again; Windows runs f on a
//                                  thread with a stack of that size. Call first in main.
//   stack_size() -> i64            the stack the compiler has (its limit), -1 if it is
//                                  unlimited or not known
//   file_id(path) -> (str, bool)   the identity of an existing file (device and inode, or
//                                  volume and file index), or false
//   cpu_count() -> i64             the number of CPUs this process may use, at least 1
//   shared_map, fork_worker, queue_new, pipe_open: worker processes (below)
// The rest goes through the OS layer of the run-time library (the `__os_*` functions of
// src/prelude_linux.al / prelude_windows.al).
when TARGET_OS == Windows {
    use "host_windows.al"
} else {
    use "host_linux.al"
}

// the compiler runs on Windows (else on Linux)
inline fn host_windows() -> bool {
    return TARGET_OS == Windows
}

// run_program_env without changes to the environment
fn run_program(path: str, argv: []str) -> i64 {
    return run_program_env(path, argv, nil, nil)
}

// a byte that separates path components on the host: `/`, on Windows also `\`
fn host_sep(c: u8) -> bool {
    return __os_is_sep(c)
}

// the length of the root at the start of a path on the host ("/" 1; on Windows also "C:\" 3,
// "C:" 2, "\\server\share\" its length, "\" 1), 0 for a relative path
fn host_root(p: str) -> i64 {
    return __os_path_root(p)
}

// ---------- worker processes (the parallel back end) ----------
// The host files also define:
//   shared_map(bytes) -> i64       a zeroed mapping of `bytes` that forked children share with
//                                  this process (pages are only allocated when touched): its
//                                  address, or 0
//   fork_worker(quiet) -> i64      fork after flushing standard output: 0 in the child, the
//                                  child's pid in the parent, < 0 if it failed. A quiet child
//                                  writes its standard error to /dev/null (the parent redoes
//                                  the work of a child that fails, so its messages would only
//                                  confuse).
//   queue_new(items) -> i64        a work queue that forked workers share: a pipe filled with
//                                  the items (each below 2^32) and closed for writing before
//                                  the workers are forked. A read of a pipe is atomic, so every
//                                  item is taken (queue_take) by one process only, in the order
//                                  of the items. Items that do not fit into the pipe are left
//                                  out. Returns the read end, or -1.
//   pipe_open() -> (i64, i64)      a pipe through which forked workers report that they are
//                                  done: (read end, write end), or (-1, -1). Every worker
//                                  closes its copy of the write end when it is done (a process
//                                  that ends closes it too); once this process has closed its
//                                  own, pipe_wait_closed returns when all are.

// whether workers can be forked (not on Windows: the back end is sequential there)
inline fn can_fork() -> bool {
    return TARGET_OS != Windows
}

fn shared_unmap(addr: i64, bytes: i64) {
    __os_unmap(addr, bytes)
}

// ends a forked worker at once (its copy of the buffered output is not written)
fn worker_exit(code: i64) {
    __os_exit(code)
}

// waits for a forked worker: its exit status, 128 + the signal that ended it, or -1
fn wait_worker(pid: i64) -> i64 {
    return __os_wait(pid, pid, true)
}

// the next item of the queue at fd, or -1 if it is empty
fn queue_take(fd: i64) -> i64 {
    x: [1]u32
    if __os_read(fd, cast[i64](ptr(x)), 4) != 4 {
        return -1
    }
    return i64(x[0])
}

fn fd_close(fd: i64) {
    if fd >= 0 {
        __os_close(fd)
    }
}

// waits until every copy of the write end of the pipe whose read end is fd is closed
fn pipe_wait_closed(fd: i64) {
    buf: [8]u8
    while __os_read(fd, cast[i64](ptr(buf)), 8) > 0 {
    }
}

// ---------- working memory ----------
// The compiler never frees: everything lives in an arena. Passes over one function create a
// lot of short-lived data, so besides the main arena the compiler uses two regions:
//   work     one function being optimised or compiled. work_begin() makes every allocation
//            come from it, work_end() goes back and empties it. Whatever must survive is
//            copied (deep `clone`) right after work_end(): the discarded memory stays readable
//            until the next work_begin().
//   scratch  tables that a pass rebuilds on every round of a loop (predecessors, orderings,
//            use counts). scratch_on() / scratch_off() bracket their construction and
//            scratch_reset() at the top of the next round discards them. Nothing reachable
//            from the function may be allocated between scratch_on() and scratch_off().
priv work: Region
priv scratch: Region
priv working: bool
priv scratching: bool

fn work_begin() {
    assert !working, "work_begin: already working"
    working = true
    enter(&work)
}

fn work_end() {
    assert working && !scratching, "work_end without work_begin"
    working = false
    leave()
    reset(&work)
    reset(&scratch)
}

// allocate from the main arena for a moment while working (for results that must stay)
fn work_pause() {
    assert working && !scratching, "work_pause without work_begin"
    leave()
}

fn work_resume() {
    enter(&work)
}

fn scratch_on() {
    assert !scratching, "scratch_on: already on"
    scratching = true
    enter(&scratch)
}

fn scratch_off() {
    assert scratching, "scratch_off without scratch_on"
    scratching = false
    leave()
}

fn scratch_reset() {
    assert !scratching, "scratch_reset while the scratch region is in use"
    reset(&scratch)
}

// the largest size the work region has had, in bytes (not to be called while working)
fn work_peak() -> i64 {
    return max(work.hwm, work.cur) - work.base
}
