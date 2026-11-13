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
// the number of CPUs this process may run on (sched_getaffinity), at least 1
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
// it failed
fn fork_worker() -> i64 {
    flush()
    return syscall(57)
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
