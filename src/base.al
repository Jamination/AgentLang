// Helpers shared by the compiler sources: optional values, Vec and Map conveniences,
// environment and process access.

enum Opt[T] { Some(T), None }

fn is_some[T](o Opt[T]) bool {
    match o {
        Some(x) => true
        None => false
    }
}

// ---------- Vec ----------
// a Vec holding a copy of the elements of s
fn vec_of[T](s []T) Vec[T] {
    v := vec[T]()
    reserve(&v, len(s))
    memcopy(ptr(v.buf), ptr(s), len(s) * sizeof[T]())
    v.len = len(s)
    return v
}

// a Vec of n copies of x
fn vec_fill[T](n i64, x T) Vec[T] {
    v := vec[T]()
    reserve(&v, n)
    for i in 0..n {
        v.buf[i] = x
    }
    v.len = n
    return v
}

// an independent copy (assigning a Vec shares its buffer)
fn clone[T](v Vec[T]) Vec[T] {
    return vec_of(v.buf[..v.len])
}

fn clone[T](v *Vec[T]) Vec[T] {
    return vec_of(v.buf[..v.len])
}

// element i, bounds-checked against the length (v.buf[i] is only checked against the capacity)
inline fn at[T](v *Vec[T], i i64) T {
    assert i >= 0 && i < v.len, "Vec index out of range"
    return v.buf[i]
}

fn last[T](v *Vec[T]) T {
    assert v.len > 0, "last of an empty Vec"
    return v.buf[v.len - 1]
}

fn is_empty[T](v *Vec[T]) bool {
    return v.len == 0
}

fn clear[T](v *Vec[T]) {
    v.len = 0
}

fn truncate[T](v *Vec[T], n i64) {
    if n < v.len {
        v.len = n
    }
}

// grows (with copies of x) or shrinks to exactly n elements
fn resize[T](v *Vec[T], n i64, x T) {
    reserve(v, n)
    for i in v.len..n {
        v.buf[i] = x
    }
    v.len = n
}

fn extend[T](v *Vec[T], s []T) {
    reserve(v, v.len + len(s))
    memcopy(cast[i64](ptr(v.buf)) + v.len * sizeof[T](), ptr(s), len(s) * sizeof[T]())
    v.len += len(s)
}

// inserts x before position i
fn insert[T](v *Vec[T], i i64, x T) {
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
fn remove[T](v *Vec[T], i i64) T {
    assert i >= 0 && i < v.len, "Vec remove position out of range"
    x := v.buf[i]
    for k in i..v.len - 1 {
        v.buf[k] = v.buf[k + 1]
    }
    v.len -= 1
    return x
}

// removes and returns element i, moving the last element into its place
fn swap_remove[T](v *Vec[T], i i64) T {
    assert i >= 0 && i < v.len, "Vec swap_remove position out of range"
    x := v.buf[i]
    v.len -= 1
    v.buf[i] = v.buf[v.len]
    return x
}

// position of the first element equal to x, or -1
fn index_of[T](s []T, x T) i64 {
    for i, y in s {
        if y == x {
            return i
        }
    }
    return -1
}

fn contains[T](s []T, x T) bool {
    return index_of(s, x) >= 0
}

fn contains[T](v *Vec[T], x T) bool {
    return index_of(v.buf[..v.len], x) >= 0
}

fn reverse[T](s []T) {
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
fn dedup[T](v *Vec[T]) {
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
fn clear[K, V](m *Map[K, V]) {
    *m = map[K, V]()
}

// ---------- text ----------
// an independent copy of s
fn str_copy(s str) str {
    out := alloc[u8](len(s))
    memcopy(ptr(out), ptr(s), len(s))
    return out
}

fn is_digit(c u8) bool {
    return c >= '0' && c <= '9'
}

fn is_alpha(c u8) bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

fn is_alnum(c u8) bool {
    return is_digit(c) || is_alpha(c)
}

// ---------- process ----------
// the value of an environment variable; ("", false) if it is not set
fn env_get(name str) (str, bool) {
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
fn eprint(s str) {
    flush()
    __write_all(2, cast[i64](ptr(s)), len(s))
}

// marks a file as executable (mode 0755)
fn make_executable(path str) bool {
    return syscall(90, cstr(path), 0o755) == 0
}

// runs a program with arguments and the current environment, waits for it and returns its
// exit code (128 + signal number if a signal ended it, -1 if it could not be started)
fn run_program(path str, argv []str) i64 {
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
    var status [1]i64
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
fn ensure_stack(bytes i64) {
    var lim [2]i64
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
