// AL run-time library, Linux layer: raw system calls (no libc). Compiled after src/prelude.al
// into every program built for Linux; the functions it has to define are listed at the top of
// src/prelude.al. Results of system calls are the kernel's: a value, or -errno.

__argc: i64
__argv: i64
__sigstack: [32768]u8

noinline fn __on_fault(sig: i64) -> never {
    if sig == 8 {
        __die("panic: arithmetic fault (division by zero or overflow)", "", "")
    }
    __die("panic: memory fault (nil dereference, stack overflow or use of released memory)", "", "")
}

// sp: the initial stack pointer (argc, argv..., 0, envp..., 0)
fn __rt_init(sp: i64) {
    __argc = cast[*i64](sp)[0]
    __argv = sp + 8
    // report crashes as panics: handlers run on their own stack so that stack overflow works too
    ss: [3]i64
    ss[0] = cast[i64](ptr(__sigstack))
    ss[2] = 32768
    syscall(131, ptr(ss), 0)
    sa: [4]i64
    sa[0] = cast[i64](__on_fault)
    // SA_ONSTACK | SA_RESTORER | SA_NODEFER
    sa[1] = 0x08000000 | 0x04000000 | 0x40000000
    sa[2] = cast[i64](__on_fault)
    syscall(13, 11, ptr(sa), 0, 8)
    syscall(13, 7, ptr(sa), 0, 8)
    syscall(13, 8, ptr(sa), 0, 8)
}

// (not `-> never`: so that it is inlined; its callers are `never` functions)
inline fn __os_exit(code: i64) {
    syscall(231, code)
}

// nothing to add to the message on standard error
inline fn __os_panic(kind: str, loc: str, msg: str) {}

// writes n bytes at p to fd, also after interruptions and, on a non-blocking fd, waiting
// until it takes more (EAGAIN: poll); returns 0 or the error number of the failed write
fn __write_all(fd: i64, p: i64, n: i64) -> i64 {
    while n > 0 {
        r := syscall(1, fd, p, n)
        if r == -4 {
            continue
        }
        if r == -11 {
            // struct pollfd { fd, events = POLLOUT, revents }
            pfd: [2]i32
            pfd[0] = i32(fd)
            pfd[1] = 4
            syscall(7, ptr(pfd), 1, -1)
            continue
        }
        if r < 0 {
            return -r
        }
        if r == 0 {
            return 5
        }
        p += r
        n -= r
    }
    return 0
}

// read(2), again after an interruption
inline fn __os_read(fd: i64, p: i64, n: i64) -> i64 {
    loop {
        r := syscall(0, fd, p, n)
        if r != -4 {
            return r
        }
    }
}

// O_RDONLY | O_CLOEXEC, or O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC with mode 0644
inline fn __os_open(path: *u8, write: bool) -> i64 {
    if write {
        return syscall(2, path, 0x80241, 420)
    }
    return syscall(2, path, 0x80000, 0)
}

inline fn __os_close(fd: i64) -> i64 {
    return syscall(3, fd)
}

// (size, true) for a regular file, (size, false) for anything else, (-1, false) on failure
inline fn __os_fstat(fd: i64) -> (i64, bool) {
    st: [18]i64
    if syscall(5, fd, ptr(st)) != 0 {
        return (-1, false)
    }
    return (st[6], (st[3] & 0xF000) == 0x8000)
}

// the address space of an arena is reserved once; the kernel commits memory as it is touched
noinline fn __heap_grow(n: i64) -> i64 {
    if __heap_base == 0 {
        size := if __region_depth == 0 { 1 << 36 } else { 1 << 34 }
        while size >= (1 << 24) {
            // PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE
            p := syscall(9, 0, size, 3, 0x4022, -1, 0)
            if p > 0 || p < -4096 {
                __heap_base = p
                __heap_cur = p
                __heap_end = p + size
                break
            }
            size = size >> 1
        }
        if __heap_base != 0 && n >= 0 && n <= __heap_end - __heap_cur {
            p := __heap_cur
            __heap_cur = p + n
            return p
        }
    }
    __die("panic: out of memory", "", "")
}

// n bytes of zeroed memory outside the arena: the address, or -errno
inline fn __os_map(n: i64) -> i64 {
    // PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS
    return syscall(9, 0, n, 3, 0x22, -1, 0)
}

// gives back memory of __os_map, of an arena or of a mapped file: 0 or -errno
inline fn __os_unmap(p: i64, n: i64) -> i64 {
    return syscall(11, p, n)
}

// runs a test block in a child process: 1 if it ended with status 0, else 0
inline fn __os_test(f: fn()) -> i64 {
    pid := syscall(57)
    if pid == 0 {
        f()
        exit(0)
    }
    status: i32
    syscall(61, pid, &status, 0, 0)
    return if status == 0 { 1 } else { 0 }
}

inline fn __os_error_text(e: i64) -> str {
    return fmt("os error ", e)
}

fn clock_ns() -> i64 {
    ts: [2]i64
    syscall(228, 1, ptr(ts))
    return ts[0] * 1000000000 + ts[1]
}

// command line arguments (args()[0] is the program name)
fn args() -> []str {
    out := alloc[str](__argc)
    for i in 0..__argc {
        p := cast[*i64](__argv)[i]
        n := 0
        while cast[*u8](p)[n] != 0 {
            n += 1
        }
        out[i] = mkslice[u8](p, n)
    }
    return out
}

// the value of an environment variable; ("", false) if it is not set
fn env_get(name: str) -> (str, bool) {
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

// ---------- std.asset: files, directories, paths ----------
// Paths are NUL-terminated. Results: 0 or -errno.

// a byte that separates path components
inline fn __os_is_sep(c: u8) -> bool {
    return c == '/'
}

// the length of the root at the start of p ("/"), 0 for a relative path
fn __os_path_root(p: str) -> i64 {
    return if len(p) > 0 && p[0] == '/' { 1 } else { 0 }
}

// (kind, size, modification time in ns since 1970) of what path names, following links; kind
// is 1 for a regular file, 2 for a directory, 0 for anything else, -1 if there is nothing
fn __os_stat(path: *u8) -> (i64, i64, i64) {
    st: [18]i64
    if syscall(4, path, ptr(st)) != 0 {
        return (-1, 0, 0)
    }
    kind := match st[3] & 0xF000 {
        0x8000 => 1
        0x4000 => 2
        _ => 0
    }
    return (kind, st[6], st[11] * 1000000000 + st[12])
}

fn __os_remove_file(path: *u8) -> i64 {
    return syscall(87, path)
}

fn __os_remove_dir(path: *u8) -> i64 {
    return syscall(84, path)
}

fn __os_make_dir(path: *u8) -> i64 {
    return syscall(83, path, 493)
}

fn __os_rename(from: *u8, to: *u8) -> i64 {
    return syscall(82, from, to)
}

// appends the names of the entries of a directory except "." and ".." to names
fn __os_list_dir(path: *u8, names: *Vec[str]) -> i64 {
    // O_RDONLY | O_DIRECTORY | O_CLOEXEC
    fd := syscall(2, path, 0x90000, 0)
    if fd < 0 {
        return fd
    }
    buf: [8192]u8
    loop {
        n := syscall(217, fd, ptr(buf), 8192)
        if n <= 0 {
            break
        }
        // struct linux_dirent64: u64 ino, i64 off, u16 reclen, u8 type, char name[]
        off := 0
        while off < n {
            reclen := i64(buf[off + 16]) | i64(buf[off + 17]) << 8
            name := from_cstr(cast[*u8](cast[i64](ptr(buf)) + off + 19))
            if name != "." && name != ".." {
                names.push(concat(name, ""))
            }
            off += reclen
        }
    }
    syscall(3, fd)
    return 0
}

// ---------- std.time ----------
// seconds since 1970-01-01 UTC
fn __os_wall_time() -> i64 {
    ts: [2]i64
    syscall(228, 0, ptr(ts))
    return ts[0]
}

fn __os_sleep_ns(ns: i64) {
    ts: [2]i64
    ts[0] = ns / 1000000000
    ts[1] = ns % 1000000000
    // nanosleep stores the remaining time back into ts when a signal interrupts it (EINTR)
    while syscall(35, ptr(ts), ptr(ts)) == -4 {
    }
}

// ---------- std.os: processes ----------
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
        file := if len(dir) == 0 { name } else if ends_with(dir, "/") { concat(dir, name) } else { fmt(dir, "/", name) }
        // access(file, X_OK); a directory is "executable" too
        r := syscall(21, cstr(file), 1)
        st: [18]i64
        if r == 0 && !(syscall(4, cstr(file), ptr(st)) == 0 && st[3] & 0xF000 == 0x4000) {
            return (file, 0)
        }
        if r == -13 {
            e = 13
        }
    }
    return ("", e)
}

// the status of a process from the status word of wait4: the exit status, or 128 + the signal
priv fn decode_status(st: i64) -> i64 {
    if st & 0x7F == 0 {
        return (st >> 8) & 0xFF
    }
    return 128 + (st & 0x7F)
}

// Starts argv; capture: 0 nothing, 1 standard output, 2 standard output and standard error go to
// a pipe. Returns (process id, process id, read end of the pipe or -1) once the program runs,
// (-1, -1, -1) if it could not be started (io_error(); a child that could not execute the
// program is waited for).
fn __os_spawn(argv: []str, capture: i64) -> (i64, i64, i64) {
    if len(argv) == 0 {
        __io_result(-22)
        return (-1, -1, -1)
    }
    file, e := locate(argv[0])
    if e != 0 {
        __io_result(-e)
        return (-1, -1, -1)
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
        return (-1, -1, -1)
    }
    note_r := i64(fds[0])
    note_w := i64(fds[1])
    if capture != 0 && __io_result(syscall(293, &fds[2], 0x80000)) < 0 {
        syscall(3, note_r)
        syscall(3, note_w)
        return (-1, -1, -1)
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
        return (-1, -1, -1)
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
        return (-1, -1, -1)
    }
    __io_result(0)
    return (pid, pid, pipe_r)
}

// Waits for a process of __os_spawn (block) or looks whether it has ended: its status (exit
// status or 128 + signal), -2 if it still runs (only without block), -1 if it cannot be
// waited for (io_error()). After a status the process is gone.
fn __os_wait(pid: i64, handle: i64, block: bool) -> i64 {
    status: [1]i32
    r := 0
    loop {
        r = syscall(61, pid, ptr(status), if block { 0 } else { 1 }, 0)    // wait4(WNOHANG)
        if r != -4 {
            break
        }
    }
    if __io_result(r) < 0 {
        return -1
    }
    if r == 0 {
        return -2
    }
    return decode_status(i64(status[0]))
}

// sends a signal: 0 or -errno
fn __os_kill(pid: i64, handle: i64, signal: i64) -> i64 {
    return syscall(62, pid, signal)
}

// ---------- std.os: shared memory, this process ----------
// a new anonymous file of `size` bytes in memory (close-on-exec): a descriptor or -errno
fn __os_shm_create(size: i64) -> i64 {
    fd := syscall(319, ptr("al-shm"), 1)       // memfd_create(name, MFD_CLOEXEC)
    if fd < 0 {
        return fd
    }
    r := syscall(77, fd, size)                 // ftruncate
    if r < 0 {
        syscall(3, fd)
        return r
    }
    return fd
}

// maps the first `size` bytes of the file fd: shared and writable, or private and read-only;
// the address, or -errno
fn __os_map_fd(fd: i64, size: i64, write: bool) -> i64 {
    if write {
        return syscall(9, 0, size, 3, 1, fd, 0)       // PROT_READ | PROT_WRITE, MAP_SHARED
    }
    return syscall(9, 0, size, 1, 2, fd, 0)           // PROT_READ, MAP_PRIVATE
}

fn __os_process_id() -> i64 {
    return syscall(39)
}

// the working directory ("" if it cannot be told: see io_error())
fn __os_current_dir() -> str {
    buf: [4096]u8
    n := __io_result(syscall(79, ptr(buf), 4096))
    if n <= 0 {
        return ""
    }
    return concat(from_cstr(ptr(buf)), "")
}

// ---------- the compiler's host ----------
// What alc (src/base.al) needs of the system it runs on. Only the compiler uses these.

// the system the program runs on: Windows (else Linux)
inline fn __os_is_windows() -> bool {
    return false
}

// the soft stack limit in bytes, -1 if it is unlimited or not known
fn __os_stack_size() -> i64 {
    lim: [2]i64
    if syscall(97, 3, ptr(lim)) != 0 || lim[0] < 0 {
        return -1
    }
    return lim[0]
}

// Calls f with a stack of at least `bytes` (deep recursion) and returns its result: if the
// stack limit is lower, raises it and starts the program again first (the limit only applies
// to a new process image), with the marker ALC_STACK_SET=<original limit> in the environment
// (removed again for the programs __os_run starts). Without a way to raise it, f runs with the
// stack there is.
fn __os_big_stack(bytes: i64, f: fn() -> i64) -> i64 {
    lim: [2]i64
    if syscall(97, 3, ptr(lim)) != 0 {
        return f()
    }
    unlimited := lim[0] == -1
    if unlimited || lim[0] >= bytes {
        return f()
    }
    // already restarted once: do not loop if the limit cannot be raised
    _, restarted := env_get("ALC_STACK_SET")
    if restarted {
        return f()
    }
    want := bytes
    if lim[1] != -1 && lim[1] < want {
        want = lim[1]
    }
    if want <= lim[0] {
        return f()
    }
    orig := lim[0]
    lim[0] = want
    if syscall(160, 3, ptr(lim)) != 0 {
        return f()
    }
    // envp plus the marker, which holds the original limit (for __os_run)
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
    return f()
}

// Runs the program at path with arguments argv and the environment of this process, without
// the variables named in `drop` and with the `NAME=value` entries of `add`; waits for it.
// Returns its exit status (128 + signal number if a signal ended it), -1 if it could not be
// started. It gets the stack limit and environment this process was started with (see
// __os_big_stack).
fn __os_run(path: str, argv: []str, drop: []str, add: []str) -> i64 {
    flush()
    cargs := alloc[i64](len(argv) + 2)
    cargs[0] = cast[i64](cstr(path))
    for i, a in argv {
        cargs[i + 1] = cast[i64](cstr(a))
    }
    // the environment without the marker of __os_big_stack, whose value is the original limit
    env := cast[*i64](__argv + 8 * (__argc + 1))
    n := 0
    while env[n] != 0 {
        n += 1
    }
    envp := alloc[i64](n + len(add) + 1)
    k := 0
    orig := -2
    next: for i in 0..n {
        e := from_cstr(cast[*u8](env[i]))
        if starts_with(e, "ALC_STACK_SET=") {
            v, ok := parse_i64(e[14..])
            if ok {
                orig = v
            }
            continue
        }
        for d in drop {
            if len(e) > len(d) && e[len(d)] == '=' && starts_with(e, d) {
                continue next
            }
        }
        envp[k] = env[i]
        k += 1
    }
    for a in add {
        envp[k] = cast[i64](cstr(a))
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
    return decode_status(status[0] & 0xFFFFFFFF)
}

// marks a file as executable (mode 0755)
fn __os_make_executable(path: *u8) -> bool {
    return syscall(90, path, 0o755) == 0
}

// (device, inode, true) of the file that path names (following links), or (0, 0, false)
fn __os_file_id(path: *u8) -> (i64, i64, bool) {
    st: [18]i64
    if syscall(4, path, ptr(st)) != 0 {
        return (0, 0, false)
    }
    return (st[0], st[1], true)
}

// the number of CPUs this process may use, at least 1: those it may run on
// (sched_getaffinity), limited by a cgroup v2 CPU quota (/sys/fs/cgroup/cpu.max:
// "quota period", or "max period" without a limit)
fn __os_cpu_count() -> i64 {
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

// Worker processes of the parallel back end (src/x86/mod.al) are forked: they share memory
// mapped by __os_map_shared and take work from a queue (__os_queue_new); __os_pipe tells when
// they are done.

// a zeroed mapping of `bytes` that forked children share with this process (pages are only
// allocated when touched): its address, or -errno
fn __os_map_shared(bytes: i64) -> i64 {
    // PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS | MAP_NORESERVE
    return syscall(9, 0, bytes, 3, 0x4021, -1, 0)
}

// fork after flushing standard output: 0 in the child, the child's pid in the parent, -errno
// if it failed. A quiet child writes its standard error to /dev/null.
fn __os_fork(quiet: bool) -> i64 {
    flush()
    pid := syscall(57)
    if pid == 0 && quiet {
        fd := syscall(2, ptr("/dev/null"), 1)
        if fd >= 0 {
            syscall(33, fd, 2)
        }
    }
    return pid
}

// A work queue that forked workers share: a pipe filled with the items (each below 2^32) and
// closed for writing before the workers are forked. A read of a pipe is atomic, so every item
// is taken (4 bytes read with __os_read) by one process only, in the order of the items.
// Items that do not fit into the pipe are left out. Returns the read end, or -1.
fn __os_queue_new(items: []i64) -> i64 {
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
    // ignored by the reader)
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

// a pipe (close-on-exec): (read end, write end), or (-1, -1)
fn __os_pipe() -> (i64, i64) {
    fds: [1]i64
    if syscall(293, ptr(fds), 0x80000) != 0 {
        return (-1, -1)
    }
    return (fds[0] & 0xFFFFFFFF, fds[0] >> 32)
}

// the target of this layer (see `enum Os` in prelude.al)
const TARGET_OS = Os.Linux
