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
// marks a file as executable (mode 0755)
fn make_executable(path: str) -> bool {
    return syscall(90, cstr(path), 0o755) == 0
}

// runs a program with arguments and the current environment, waits for it and returns its
// exit code (128 + signal number if a signal ended it, -1 if it could not be started). The
// program gets the stack limit and environment the compiler was started with (see
// ensure_stack).
fn run_program(path: str, argv: []str) -> i64 {
    flush()
    cargs := alloc[i64](len(argv) + 2)
    cargs[0] = cast[i64](cstr(path))
    for i, a in argv {
        cargs[i + 1] = cast[i64](cstr(a))
    }
    // the environment without the marker of ensure_stack, whose value is the original limit
    env := cast[*i64](__argv + 8 * (__argc + 1))
    n := 0
    while env[n] != 0 {
        n += 1
    }
    envp := alloc[i64](n + 1)
    k := 0
    orig := -2
    for i in 0..n {
        e := from_cstr(cast[*u8](env[i]))
        if starts_with(e, "ALC_STACK_SET=") {
            v, ok := parse_i64(e[14..])
            if ok {
                orig = v
            }
            continue
        }
        envp[k] = env[i]
        k += 1
    }
    pid := syscall(57)
    if pid < 0 {
        return -1
    }
    if pid == 0 {
        lim: [2]i64
        if orig != -2 && syscall(97, 3, ptr(lim)) == 0 {
            lim[0] = orig
            syscall(160, 3, ptr(lim))
        }
        syscall(59, cargs[0], ptr(cargs), ptr(envp))
        syscall(231, 127)
    }
    status: [1]i64
    loop {
        r := syscall(61, pid, ptr(status), 0, 0)
        if r == -4 {
            continue
        }
        if r < 0 {
            return -1
        }
        break
    }
    st := status[0] & 0xFFFFFFFF
    if st & 0x7F == 0 {
        return (st >> 8) & 0xFF
    }
    return 128 + (st & 0x7F)
}

// ---------- worker processes (the parallel back end) ----------
// the number of CPUs this process may use, at least 1: those it may run on
// (sched_getaffinity), limited by a cgroup v2 CPU quota (/sys/fs/cgroup/cpu.max:
// "quota period", or "max period" without a limit)
fn cpu_count() -> i64 {
    mask: [16]u64
    n := syscall(204, 0, 128, ptr(mask))
    if n <= 0 {
        return 1
    }
    c := 0
    for i in 0..min(n / 8, 16) {
        c += i64(popcnt(mask[i]))
    }
    text, ok := read_file("/sys/fs/cgroup/cpu.max")
    if ok {
        parts := fields(text)
        if parts.len == 2 {
            q, qok := parse_i64(parts[0])
            p, pok := parse_i64(parts[1])
            if qok && pok && q > 0 && p > 0 {
                c = min(c, (q + p - 1) / p)
            }
        }
    }
    return max(c, 1)
}

// a zeroed mapping of `bytes` that forked children share with this process (pages are only
// allocated when touched): its address, or 0
fn shared_map(bytes: i64) -> i64 {
    // PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS | MAP_NORESERVE
    r := syscall(9, 0, bytes, 3, 0x4021, -1, 0)
    if r < 0 && r > -4096 {
        return 0
    }
    return r
}

fn shared_unmap(addr: i64, bytes: i64) {
    syscall(11, addr, bytes)
}

// fork after flushing standard output: 0 in the child, the child's pid in the parent, < 0 if
// it failed. A quiet child writes its standard error to /dev/null (the parent redoes the work
// of a child that fails, so its messages would only confuse).
fn fork_worker(quiet: bool) -> i64 {
    flush()
    pid := syscall(57)
    if pid == 0 && quiet {
        fd := syscall(2, cstr("/dev/null"), 1)
        if fd >= 0 {
            syscall(33, fd, 2)
        }
    }
    return pid
}

// ends a forked worker at once (its copy of the buffered output is not written)
fn worker_exit(code: i64) {
    syscall(231, code)
}

// waits for a forked worker: its exit status, 128 + the signal that ended it, or -1
fn wait_worker(pid: i64) -> i64 {
    status: [1]i64
    loop {
        r := syscall(61, pid, ptr(status), 0, 0)
        if r == -4 {
            continue
        }
        if r < 0 {
            return -1
        }
        break
    }
    st := status[0] & 0xFFFFFFFF
    if st & 0x7F == 0 {
        return (st >> 8) & 0xFF
    }
    return 128 + (st & 0x7F)
}

// A work queue that forked workers share: a pipe filled with the items (each below 2^32) and
// closed for writing before the workers are forked. A read of a pipe is atomic, so every item
// is taken (queue_take) by one process only, in the order of the items. Items that do not fit
// into the pipe are left out. Returns the read end, or -1.
fn queue_new(items: []i64) -> i64 {
    fds: [1]i64
    // O_CLOEXEC | O_NONBLOCK: a full pipe ends the filling (no waiting for a reader), and an
    // empty one without a writer reads as end of file
    if syscall(293, ptr(fds), 0x80800) != 0 {
        return -1
    }
    rd := fds[0] & 0xFFFFFFFF
    wr := fds[0] >> 32
    n := len(items)
    // room for all items if the system allows it (F_SETPIPE_SZ)
    syscall(72, wr, 1031, 4 * n)
    buf := alloc[u32](max(n, 1))
    for i, x in items {
        buf[i] = u32(x)
    }
    // a page at a time, until the pipe is full (what a short write leaves of an item is
    // ignored by queue_take)
    k := 0
    while k < n {
        c := min(1024, n - k)
        if syscall(1, wr, cast[i64](ptr(buf)) + 4 * k, 4 * c) != 4 * c {
            break
        }
        k += c
    }
    syscall(3, wr)
    return rd
}

// the next item of the queue at fd, or -1 if it is empty
fn queue_take(fd: i64) -> i64 {
    x: [1]u32
    loop {
        r := syscall(0, fd, ptr(x), 4)
        if r == -4 {
            continue
        }
        if r != 4 {
            return -1
        }
        return i64(x[0])
    }
}

// A pipe through which forked workers report that they are done: (read end, write end), or
// (-1, -1). Every worker closes its copy of the write end when it is done (a process that ends
// closes it too); once this process has closed its own, pipe_wait_closed returns when all are.
fn pipe_open() -> (i64, i64) {
    fds: [1]i64
    if syscall(293, ptr(fds), 0x80000) != 0 {
        return (-1, -1)
    }
    return (fds[0] & 0xFFFFFFFF, fds[0] >> 32)
}

fn fd_close(fd: i64) {
    if fd >= 0 {
        syscall(3, fd)
    }
}

// waits until every copy of the write end of the pipe whose read end is fd is closed
fn pipe_wait_closed(fd: i64) {
    buf: [8]u8
    loop {
        r := syscall(0, fd, ptr(buf), 8)
        if r == -4 {
            continue
        }
        if r <= 0 {
            return
        }
    }
}

// Deep recursion needs a big stack: if the stack limit is below `bytes`, raise it and start
// the program again (the limit only applies to a new process image). Call first in main.
fn ensure_stack(bytes: i64) {
    lim: [2]i64
    if syscall(97, 3, ptr(lim)) != 0 {
        return
    }
    unlimited := lim[0] == -1
    if unlimited || lim[0] >= bytes {
        return
    }
    // already restarted once: do not loop if the limit cannot be raised
    done, restarted := env_get("ALC_STACK_SET")
    if restarted {
        return
    }
    want := bytes
    if lim[1] != -1 && lim[1] < want {
        want = lim[1]
    }
    if want <= lim[0] {
        return
    }
    orig := lim[0]
    lim[0] = want
    if syscall(160, 3, ptr(lim)) != 0 {
        return
    }
    // envp plus the marker, which holds the original limit (for run_program)
    envp := cast[*i64](__argv + 8 * (__argc + 1))
    n := 0
    while envp[n] != 0 {
        n += 1
    }
    nenv := alloc[i64](n + 2)
    for i in 0..n {
        nenv[i] = envp[i]
    }
    nenv[n] = cast[i64](cstr(fmt("ALC_STACK_SET=", orig)))
    syscall(59, ptr("/proc/self/exe"), __argv, ptr(nenv))
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
