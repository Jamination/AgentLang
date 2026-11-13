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

// the target of this layer (see `enum Os` in prelude.al)
const TARGET_OS = Os.Linux
