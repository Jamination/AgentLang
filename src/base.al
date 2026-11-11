// Helpers shared by the compiler sources: optional values, Vec and Map conveniences,
// environment and process access.

enum Opt[T] { Some(T), None }

fn is_some[T](o: Opt[T]) -> bool {
    match o {
        Some(x) => true
        None => false
    }
}

// ---------- Vec ----------
// a Vec holding a copy of the elements of s
fn vec_of[T](s: []T) -> Vec[T] {
    n := len(s)
    buf := mkslice[T](__alloc_raw(n * sizeof[T]()), n)
    memcopy(ptr(buf), ptr(s), n * sizeof[T]())
    return Vec[T]{buf: buf, len: n}
}

// Vecs of one and two elements without an intermediate slice
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

// a Vec of n copies of x
fn vec_fill[T](n: i64, x: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(n * sizeof[T]()), n)
    for i in 0..n {
        buf[i] = x
    }
    return Vec[T]{buf: buf, len: n}
}

// an independent copy (assigning a Vec shares its buffer)
fn clone[T](v: Vec[T]) -> Vec[T] {
    return vec_of(v.buf[..v.len])
}

fn clone[T](v: *Vec[T]) -> Vec[T] {
    return vec_of(v.buf[..v.len])
}

// element i, bounds-checked against the length (v.buf[i] is only checked against the capacity)
inline fn at[T](v: *Vec[T], i: i64) -> T {
    assert i >= 0 && i < v.len, "Vec index out of range"
    return v.buf[i]
}

// ---------- text ----------
// an independent copy of s
fn str_copy(s: str) -> str {
    out := alloc[u8](len(s))
    memcopy(ptr(out), ptr(s), len(s))
    return out
}

// ---------- process ----------
// marks a file as executable (mode 0755)
fn make_executable(path: str) -> bool {
    return syscall(90, cstr(path), 0o755) == 0
}

// runs a program with arguments and the current environment, waits for it and returns its
// exit code (128 + signal number if a signal ended it, -1 if it could not be started)
fn run_program(path: str, argv: []str) -> i64 {
    flush()
    cargs := alloc[i64](len(argv) + 2)
    cargs[0] = cast[i64](cstr(path))
    for i, a in argv {
        cargs[i + 1] = cast[i64](cstr(a))
    }
    envp := __argv + 8 * (__argc + 1)
    pid := syscall(57)
    if pid < 0 {
        return -1
    }
    if pid == 0 {
        syscall(59, cargs[0], ptr(cargs), envp)
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
    lim[0] = want
    if syscall(160, 3, ptr(lim)) != 0 {
        return
    }
    // envp plus the marker
    envp := cast[*i64](__argv + 8 * (__argc + 1))
    n := 0
    while envp[n] != 0 {
        n += 1
    }
    nenv := alloc[i64](n + 2)
    for i in 0..n {
        nenv[i] = envp[i]
    }
    nenv[n] = cast[i64](ptr("ALC_STACK_SET=1"))
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
base_work: Region
base_scratch: Region
base_working: bool
base_scratching: bool

fn work_begin() {
    assert !base_working, "work_begin: already working"
    base_working = true
    enter(&base_work)
}

fn work_end() {
    assert base_working && !base_scratching, "work_end without work_begin"
    base_working = false
    leave()
    reset(&base_work)
    reset(&base_scratch)
}

// allocate from the main arena for a moment while working (for results that must stay)
fn work_pause() {
    assert base_working && !base_scratching, "work_pause without work_begin"
    leave()
}

fn work_resume() {
    enter(&base_work)
}

fn scratch_on() {
    assert !base_scratching, "scratch_on: already on"
    base_scratching = true
    enter(&base_scratch)
}

fn scratch_off() {
    assert base_scratching, "scratch_off without scratch_on"
    base_scratching = false
    leave()
}

fn scratch_reset() {
    assert !base_scratching, "scratch_reset while the scratch region is in use"
    reset(&base_scratch)
}

// the largest size the work region has had, in bytes (not to be called while working)
fn work_peak() -> i64 {
    return max(base_work.hwm, base_work.cur) - base_work.base
}
