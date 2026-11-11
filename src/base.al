// Helpers shared by the compiler sources: optional values, Vec and Map conveniences,
// environment and process access.

Opt[T] :: enum { Some(T), None }

is_some[T] :: (o: Opt[T]) -> bool {
    match o {
        Some(x) => true
        None => false
    }
}

// ---------- Vec ----------
// a Vec holding a copy of the elements of s
vec_of[T] :: (s: []T) -> Vec[T] {
    n := len(s)
    buf := mkslice[T](__alloc_raw(n * sizeof[T]()), n)
    memcopy(ptr(buf), ptr(s), n * sizeof[T]())
    return Vec[T]{buf: buf, len: n}
}

// Vecs of one and two elements without an intermediate slice
vec_one[T] :: (a: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(sizeof[T]()), 1)
    buf[0] = a
    return Vec[T]{buf: buf, len: 1}
}

vec_two[T] :: (a: T, b: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(2 * sizeof[T]()), 2)
    buf[0] = a
    buf[1] = b
    return Vec[T]{buf: buf, len: 2}
}

// a Vec of n copies of x
vec_fill[T] :: (n: i64, x: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(n * sizeof[T]()), n)
    for i in 0..n {
        buf[i] = x
    }
    return Vec[T]{buf: buf, len: n}
}

// an independent copy (assigning a Vec shares its buffer)
clone[T] :: (v: Vec[T]) -> Vec[T] {
    return vec_of(v.buf[..v.len])
}

clone[T] :: (v: *Vec[T]) -> Vec[T] {
    return vec_of(v.buf[..v.len])
}

// element i, bounds-checked against the length (v.buf[i] is only checked against the capacity)
inline at[T] :: (v: *Vec[T], i: i64) -> T {
    assert i >= 0 && i < v.len, "Vec index out of range"
    return v.buf[i]
}

last[T] :: (v: *Vec[T]) -> T {
    assert v.len > 0, "last of an empty Vec"
    return v.buf[v.len - 1]
}

is_empty[T] :: (v: *Vec[T]) -> bool {
    return v.len == 0
}

clear[T] :: (v: *Vec[T]) {
    v.len = 0
}

truncate[T] :: (v: *Vec[T], n: i64) {
    if n < v.len {
        v.len = n
    }
}

// grows (with copies of x) or shrinks to exactly n elements
resize[T] :: (v: *Vec[T], n: i64, x: T) {
    reserve(v, n)
    for i in v.len..n {
        v.buf[i] = x
    }
    v.len = n
}

extend[T] :: (v: *Vec[T], s: []T) {
    reserve(v, v.len + len(s))
    memcopy(cast[i64](ptr(v.buf)) + v.len * sizeof[T](), ptr(s), len(s) * sizeof[T]())
    v.len += len(s)
}

// inserts x before position i
insert[T] :: (v: *Vec[T], i: i64, x: T) {
    assert i >= 0 && i <= v.len, "Vec insert position out of range"
    push(v, x)
    k := v.len - 1
    while k > i {
        v.buf[k] = v.buf[k - 1]
        k -= 1
    }
    v.buf[i] = x
}

// removes and returns element i, keeping the order of the rest
remove[T] :: (v: *Vec[T], i: i64) -> T {
    assert i >= 0 && i < v.len, "Vec remove position out of range"
    x := v.buf[i]
    for k in i..v.len - 1 {
        v.buf[k] = v.buf[k + 1]
    }
    v.len -= 1
    return x
}

// removes and returns element i, moving the last element into its place
swap_remove[T] :: (v: *Vec[T], i: i64) -> T {
    assert i >= 0 && i < v.len, "Vec swap_remove position out of range"
    x := v.buf[i]
    v.len -= 1
    v.buf[i] = v.buf[v.len]
    return x
}

// position of the first element equal to x, or -1
index_of[T] :: (s: []T, x: T) -> i64 {
    for i, y in s {
        if y == x {
            return i
        }
    }
    return -1
}

contains[T] :: (s: []T, x: T) -> bool {
    return index_of(s, x) >= 0
}

contains[T] :: (v: *Vec[T], x: T) -> bool {
    return index_of(v.buf[..v.len], x) >= 0
}

reverse[T] :: (s: []T) {
    i := 0
    j := len(s) - 1
    while i < j {
        t := s[i]
        s[i] = s[j]
        s[j] = t
        i += 1
        j -= 1
    }
}

// removes adjacent duplicates (use after sort)
dedup[T] :: (v: *Vec[T]) {
    if v.len == 0 {
        return
    }
    n := 1
    for i in 1..v.len {
        if v.buf[i] != v.buf[n - 1] {
            v.buf[n] = v.buf[i]
            n += 1
        }
    }
    v.len = n
}

// ---------- Map ----------
// removes every entry
clear[K, V] :: (m: *Map[K, V]) {
    *m = map[K, V]()
}

// ---------- text ----------
// an independent copy of s
str_copy :: (s: str) -> str {
    out := alloc[u8](len(s))
    memcopy(ptr(out), ptr(s), len(s))
    return out
}

is_digit :: (c: u8) -> bool {
    return c >= '0' && c <= '9'
}

is_alpha :: (c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_alnum :: (c: u8) -> bool {
    return is_digit(c) || is_alpha(c)
}

// ---------- process ----------
// the value of an environment variable; ("", false) if it is not set
env_get :: (name: str) -> (str, bool) {
    envp := cast[*i64](__argv + 8 * (__argc + 1))
    i := 0
    while envp[i] != 0 {
        p := cast[*u8](envp[i])
        n := 0
        while p[n] != 0 && p[n] != '=' {
            n += 1
        }
        if p[n] == '=' && mkslice[u8](p, n) == name {
            return (from_cstr(cast[*u8](envp[i] + n + 1)), true)
        }
        i += 1
    }
    return ("", false)
}

// writes to standard error
eprint :: (s: str) {
    flush()
    __write_all(2, cast[i64](ptr(s)), len(s))
}

// marks a file as executable (mode 0755)
make_executable :: (path: str) -> bool {
    return syscall(90, cstr(path), 0o755) == 0
}

// runs a program with arguments and the current environment, waits for it and returns its
// exit code (128 + signal number if a signal ended it, -1 if it could not be started)
run_program :: (path: str, argv: []str) -> i64 {
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
ensure_stack :: (bytes: i64) {
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

work_begin :: () {
    assert !base_working, "work_begin: already working"
    base_working = true
    enter(&base_work)
}

work_end :: () {
    assert base_working && !base_scratching, "work_end without work_begin"
    base_working = false
    leave()
    reset(&base_work)
    reset(&base_scratch)
}

// allocate from the main arena for a moment while working (for results that must stay)
work_pause :: () {
    assert base_working && !base_scratching, "work_pause without work_begin"
    leave()
}

work_resume :: () {
    enter(&base_work)
}

scratch_on :: () {
    assert !base_scratching, "scratch_on: already on"
    base_scratching = true
    enter(&base_scratch)
}

scratch_off :: () {
    assert base_scratching, "scratch_off without scratch_on"
    base_scratching = false
    leave()
}

scratch_reset :: () {
    assert !base_scratching, "scratch_reset while the scratch region is in use"
    reset(&base_scratch)
}

// the largest size the work region has had, in bytes (not to be called while working)
work_peak :: () -> i64 {
    return max(base_work.hwm, base_work.cur) - base_work.base
}
