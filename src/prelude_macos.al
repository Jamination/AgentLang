// AL run-time library, macOS layer (--target macos, arm64): libSystem functions, since macOS
// has no stable system call interface. The same functions as src/prelude_linux_arm64.al, which
// this file follows; results are a value or -errno with the Linux error numbers of the same
// meaning (`linux_errno`), as on every target. Never run: written against Apple's headers
// (<sys/stat.h>, <dirent.h>, <sys/signal.h>, <sys/_types/_ucontext64.h>, <mach/arm/_structs.h>)
// and checked by the type checker and tests/macho/check.al only (docs/MACOS_TEST.md).
//
// The entry stub of src/macho.al calls __entry with argv (dyld calls it as main). Thread-local
// globals are reached through the program's thread-local variable descriptor (dyld makes the
// block of each thread on its first use, also for threads that C code starts). Locks and
// condition variables wait with __ulock_wait / __ulock_wake (what libc++ uses for
// std::atomic::wait; os_sync_wait_on_address is the public form from macOS 14.4).

priv const SYS = "/usr/lib/libSystem.B.dylib"

priv extern SYS fn __error() -> *i32
priv extern SYS fn _exit(code: i32)
priv extern SYS fn write(fd: i32, p: i64, n: u64) -> i64
priv extern SYS fn read(fd: i32, p: i64, n: u64) -> i64
priv extern SYS fn open(path: *u8, flags: i32, ...) -> i32
priv extern SYS fn close(fd: i32) -> i32
priv extern SYS fn fstat(fd: i32, st: *u8) -> i32
priv extern SYS fn stat(path: *u8, st: *u8) -> i32
priv extern SYS fn mmap(addr: i64, n: u64, prot: i32, flags: i32, fd: i32, off: i64) -> i64
priv extern SYS fn munmap(addr: i64, n: u64) -> i32
priv extern SYS fn fork() -> i32
priv extern SYS fn waitpid(pid: i32, status: *i32, options: i32) -> i32
priv extern SYS fn kill(pid: i32, sig: i32) -> i32
priv extern SYS fn getpid() -> i32
priv extern SYS fn getcwd(buf: *u8, n: u64) -> *u8
priv extern SYS fn clock_gettime(clock: i32, ts: *i64) -> i32
priv extern SYS fn nanosleep(req: *i64, rem: *i64) -> i32
priv extern SYS fn unlink(path: *u8) -> i32
priv extern SYS fn rmdir(path: *u8) -> i32
priv extern SYS fn mkdir(path: *u8, mode: u16) -> i32
priv extern SYS fn rename(from: *u8, to: *u8) -> i32
priv extern SYS fn opendir(path: *u8) -> i64
priv extern SYS fn readdir(d: i64) -> i64
priv extern SYS fn closedir(d: i64) -> i32
priv extern SYS fn access(path: *u8, mode: i32) -> i32
priv extern SYS fn pipe(fds: *i32) -> i32
priv extern SYS fn fcntl(fd: i32, cmd: i32, ...) -> i32
priv extern SYS fn dup2(from: i32, to: i32) -> i32
priv extern SYS fn execve(path: *u8, argv: *i64, envp: i64) -> i32
priv extern SYS fn setpgid(pid: i32, group: i32) -> i32
priv extern SYS fn shm_open(name: *u8, flags: i32, ...) -> i32
priv extern SYS fn shm_unlink(name: *u8) -> i32
priv extern SYS fn ftruncate(fd: i32, size: i64) -> i32
priv extern SYS fn sysconf(name: i32) -> i64
priv extern SYS fn sigaction(sig: i32, act: *i64, old: *i64) -> i32
priv extern SYS fn sigaltstack(ss: *i64, old: *i64) -> i32
priv extern SYS fn poll(fds: *i32, n: u32, timeout_ms: i32) -> i32
priv extern SYS fn pthread_attr_init(attr: *i64) -> i32
priv extern SYS fn pthread_attr_setstacksize(attr: *i64, size: u64) -> i32
priv extern SYS fn pthread_attr_destroy(attr: *i64) -> i32
priv extern SYS fn pthread_create(t: *i64, attr: *i64, f: fn(i64) -> i64, arg: i64) -> i32
priv extern SYS fn pthread_join(t: i64, ret: i64) -> i32
priv extern SYS fn __ulock_wait(op: u32, addr: *u32, value: u64, timeout_us: u32) -> i32
priv extern SYS fn __ulock_wake(op: u32, addr: *u32, value: u64) -> i32

__argc: i64
__argv: i64
// the main thread's signal stack (every other thread maps its own: __os_thread_setup)
__sigstack: [32768]u8

// the stack of this thread, for stack traces
__tls_stack_lo: i64
__tls_stack_hi: i64
// a fault is being reported by this thread
__tls_in_fault: bool

// the Linux number of a macOS error number (the same below 35 but EDEADLK), 0x20000 + it for one
// without a Linux equivalent
fn linux_errno(e: i64) -> i64 {
    if e < 35 {
        return if e == 11 { 35 } else { e }
    }
    t := [_](i64, i64){(35, 11), (36, 115), (37, 114), (38, 88), (39, 89), (40, 90), (41, 91),
        (42, 92), (43, 93), (44, 94), (45, 95), (46, 96), (47, 97), (48, 98), (49, 99), (50, 100),
        (51, 101), (52, 102), (53, 103), (54, 104), (55, 105), (56, 106), (57, 107), (58, 108),
        (59, 109), (60, 110), (61, 111), (62, 40), (63, 36), (64, 112), (65, 113), (66, 39),
        (69, 122), (77, 37), (78, 38), (84, 75), (89, 125), (92, 84)}
    for p in t {
        if p.0 == e {
            return p.1
        }
    }
    return 0x20000 + e
}

// r, or -errno (Linux numbers) if r is -1
priv fn sys(r: i64) -> i64 {
    return if r == -1 { -linux_errno(i64(*__error())) } else { r }
}

// uc: the interrupted state (ucontext64: uc_mcontext, a pointer, at byte 48; the arm64
// mcontext: the exception state (16 bytes), then x0-x28, fp, lr, sp, pc)
noinline fn __on_fault(sig: i64, info: i64, uc: i64) -> never {
    __panic_enter()
    if __tls_in_fault || __bt_busy {
        if __bt_busy {
            __err("  ... (the stack trace stopped at a fault)\n")
        }
        __os_exit(1)
    }
    __tls_in_fault = true
    mc := cast[*i64](uc + 48)[0]
    regs := cast[*i64](mc + 16)
    pc := regs[32]
    if cast[*u32](pc)[0] == 0xA9BF7BFD {
        pc = regs[30] - 4
    }
    __bt_fault_pc = pc
    __bt_fault_regs.r[4] = regs[31]
    if sig == 8 || sig == 5 {
        __die("panic: arithmetic fault (division by zero or overflow)", "", "")
    }
    __die_fault(cast[*i64](info + 24)[0])            // si_addr
}

// argv: from the entry stub (dyld's argv: the arguments, a null, the environment, a null)
fn __rt_init(argv: i64) {
    __argv = argv
    n := 0
    while cast[*i64](argv)[n] != 0 {
        n += 1
    }
    __argc = n
    __thread_init_main()
    __tls_stack_hi = argv
    __tls_stack_lo = argv - (1 << 36)
    // crashes as panics, on a stack of their own (stack_t: ss_sp, ss_size, ss_flags)
    ss: [3]i64
    ss[0] = cast[i64](ptr(__sigstack))
    ss[1] = 32768
    sigaltstack(&ss[0], cast[*i64](0))
    // struct sigaction: the handler, sa_mask (4 bytes), sa_flags (4 bytes):
    // SA_ONSTACK | SA_NODEFER | SA_SIGINFO
    sa: [2]i64
    sa[0] = cast[i64](__on_fault)
    sa[1] = (0x1 | 0x10 | 0x40) << 32
    for s in []i32{11, 10, 8, 5} {
        sigaction(s, &sa[0], cast[*i64](0))
    }
}

fn __os_stack_range() -> (i64, i64) {
    if __tls_stack_hi == 0 {
        here := 0
        a := cast[i64](&here)
        return (a - (1 << 36), a + (1 << 36))
    }
    return (__tls_stack_lo, __tls_stack_hi)
}

fn __os_backtrace_off() -> bool {
    v, set := env_get("ALC_BACKTRACE")
    return set && v == "0"
}

fn __os_check_memory() -> bool {
    v, set := env_get("ALC_CHECK_MEMORY")
    return set && v != "" && v != "0"
}

fn __os_page_off(p: i64, n: i64) {
    // PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED | MAP_NORESERVE
    mmap(p, u64(n), 0, 0x2 | 0x1000 | 0x10 | 0x40, -1, 0)
}

// ---------- stack traces through C libraries: not yet (the trace ends at a C frame) ----------
const __BT_SAVED = 0

noinline fn __os_bt_foreign(pc: i64) -> bool {
    return false
}

noinline fn __os_bt_unwind(pc: i64, fault: bool, g: *__BtRegs, hi: i64) -> i64 {
    return 0
}

noinline fn __os_bt_where(q: i64) -> (str, str, i64) {
    return ("", "", q)
}

inline fn __os_exit(code: i64) {
    _exit(i32(code))
}

inline fn __os_panic(kind: str, loc: str, msg: str) {}

fn __write_all(fd: i64, p: i64, n: i64) -> i64 {
    while n > 0 {
        r := sys(write(i32(fd), p, u64(n)))
        if r == -4 {
            continue
        }
        if r == -11 {
            // struct pollfd { fd, events = POLLOUT (4), revents }
            pfd: [2]i32
            pfd[0] = i32(fd)
            pfd[1] = 4
            poll(&pfd[0], 1, -1)
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

inline fn __os_read(fd: i64, p: i64, n: i64) -> i64 {
    loop {
        r := sys(read(i32(fd), p, u64(n)))
        if r != -4 {
            return r
        }
    }
}

// O_RDONLY | O_CLOEXEC, or O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC with mode 0644
inline fn __os_open(path: *u8, write: bool) -> i64 {
    if write {
        return sys(i64(open(path, 0x1 | 0x200 | 0x400 | 0x1000000, 420)))
    }
    return sys(i64(open(path, 0x1000000)))
}

inline fn __os_close(fd: i64) -> i64 {
    return sys(i64(close(i32(fd))))
}

// struct stat: st_mode (2 bytes) at 4, st_mtimespec at 48, st_size at 96
inline fn __os_fstat(fd: i64) -> (i64, bool) {
    st: [18]i64
    if fstat(i32(fd), cast[*u8](&st[0])) != 0 {
        return (-1, false)
    }
    mode := (st[0] >> 32) & 0xF000
    return (st[12], mode == 0x8000)
}

noinline fn __heap_grow(n: i64) -> i64 {
    if __heap_base == 0 {
        size := if __region_depth == 0 && __tls_id == 1 { 1 << 36 } else { 1 << 34 }
        while size >= (1 << 24) {
            // PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE
            p := mmap(0, u64(size), 3, 0x2 | 0x1000 | 0x40, -1, 0)
            if p != -1 {
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

inline fn __os_map(n: i64) -> i64 {
    return sys(mmap(0, u64(n), 3, 0x2 | 0x1000, -1, 0))
}

inline fn __os_unmap(p: i64, n: i64) -> i64 {
    return sys(i64(munmap(p, u64(n))))
}

inline fn __os_test(f: fn()) -> i64 {
    pid := fork()
    if pid == 0 {
        f()
        exit(0)
    }
    status: i32
    waitpid(pid, &status, 0)
    return if status == 0 { 1 } else { 0 }
}

inline fn __os_error_text(e: i64) -> str {
    return fmt("os error ", e)
}

fn clock_ns() -> i64 {
    ts: [2]i64
    clock_gettime(6, &ts[0])                          // CLOCK_MONOTONIC
    return ts[0] * 1000000000 + ts[1]
}

fn args() -> []str {
    out := alloc[str](__argc)
    for i in 0..__argc {
        out[i] = from_cstr(cast[*u8](cast[*i64](__argv)[i]))
    }
    return out
}

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
inline fn __os_is_sep(c: u8) -> bool {
    return c == '/'
}

fn __os_path_root(p: str) -> i64 {
    return if len(p) > 0 && p[0] == '/' { 1 } else { 0 }
}

fn __os_stat(path: *u8) -> (i64, i64, i64) {
    st: [18]i64
    if stat(path, cast[*u8](&st[0])) != 0 {
        return (-1, 0, 0)
    }
    kind := match (st[0] >> 32) & 0xF000 {
        0x8000 => 1
        0x4000 => 2
        _ => 0
    }
    return (kind, st[12], st[6] * 1000000000 + st[7])
}

fn __os_remove_file(path: *u8) -> i64 {
    return sys(i64(unlink(path)))
}

fn __os_remove_dir(path: *u8) -> i64 {
    return sys(i64(rmdir(path)))
}

fn __os_make_dir(path: *u8) -> i64 {
    return sys(i64(mkdir(path, 493)))
}

fn __os_rename(from: *u8, to: *u8) -> i64 {
    return sys(i64(rename(from, to)))
}

// struct dirent: d_reclen at 16, d_namlen at 18, d_type at 20, d_name at 21
fn __os_list_dir(path: *u8, names: *Vec[str]) -> i64 {
    d := opendir(path)
    if d == 0 {
        return sys(-1)
    }
    loop {
        e := readdir(d)
        if e == 0 {
            break
        }
        name := from_cstr(cast[*u8](e + 21))
        if name != "." && name != ".." {
            names.push(clone(name))
        }
    }
    closedir(d)
    return 0
}

// ---------- std.time ----------
fn __os_wall_time() -> i64 {
    ts: [2]i64
    clock_gettime(0, &ts[0])                          // CLOCK_REALTIME
    return ts[0]
}

fn __os_sleep_ns(ns: i64) {
    ts: [2]i64
    ts[0] = ns / 1000000000
    ts[1] = ns % 1000000000
    while nanosleep(&ts[0], &ts[0]) == -1 && *__error() == 4 {
    }
}

// ---------- std.os: processes ----------
priv const DEFAULT_PATH = "/usr/local/bin:/usr/bin:/bin"

priv fn locate(name: str) -> (str, i64) {
    if len(name) == 0 {
        return ("", 2)
    }
    if contains(name, '/') {
        return (name, 0)
    }
    path, has := env_get("PATH")
    if !has {
        path = DEFAULT_PATH
    }
    e := 2
    for dir in split(path, ':') {
        file := if len(dir) == 0 { name } else if ends_with(dir, "/") { concat(dir, name) } else { fmt(dir, "/", name) }
        r := sys(i64(access(cstr(file), 1)))
        kind, _, _ := __os_stat(cstr(file))
        if r == 0 && kind != 2 {
            return (file, 0)
        }
        if r == -13 {
            e = 13
        }
    }
    return ("", e)
}

priv fn decode_status(st: i64) -> i64 {
    if st & 0x7F == 0 {
        return (st >> 8) & 0xFF
    }
    return 128 + (st & 0x7F)
}

// a pipe whose two ends are closed in programs this one starts (FD_CLOEXEC); 0 or -errno
priv fn cloexec_pipe(fds: *i32) -> i64 {
    if pipe(fds) != 0 {
        return sys(-1)
    }
    fcntl(fds[0], 2, 1)                                 // F_SETFD, FD_CLOEXEC
    fcntl(fds[1], 2, 1)
    return 0
}

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
    fds: [4]i32
    if __io_result(cloexec_pipe(&fds[0])) < 0 {
        return (-1, -1, -1)
    }
    note_r := fds[0]
    note_w := fds[1]
    if capture != 0 && __io_result(cloexec_pipe(&fds[2])) < 0 {
        close(note_r)
        close(note_w)
        return (-1, -1, -1)
    }
    pipe_r := if capture != 0 { fds[2] } else { -1 }
    pipe_w := fds[3]
    pid := __io_result(sys(i64(fork())))
    if pid == 0 {
        if capture != 0 {
            dup2(pipe_w, 1)
            if capture == 2 {
                dup2(pipe_w, 2)
            }
        }
        execve(cfile, &cargs[0], envp)
        failed: [1]i64
        failed[0] = linux_errno(i64(*__error()))
        write(note_w, cast[i64](ptr(failed)), 8)
        _exit(127)
    }
    close(note_w)
    if capture != 0 {
        close(pipe_w)
    }
    if pid < 0 {
        close(note_r)
        if pipe_r >= 0 {
            close(pipe_r)
        }
        return (-1, -1, -1)
    }
    failed: [1]i64
    __os_read(i64(note_r), cast[i64](ptr(failed)), 8)
    close(note_r)
    if failed[0] != 0 {
        __os_wait(pid, pid, true)
        if pipe_r >= 0 {
            close(pipe_r)
        }
        __io_result(-failed[0])
        return (-1, -1, -1)
    }
    __io_result(0)
    return (pid, pid, i64(pipe_r))
}

fn __os_wait(pid: i64, handle: i64, block: bool) -> i64 {
    status: i32
    r := 0
    loop {
        r = sys(i64(waitpid(i32(pid), &status, if block { 0 } else { 1 })))   // WNOHANG
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
    return decode_status(i64(status))
}

fn __os_kill(pid: i64, handle: i64, signal: i64) -> i64 {
    return sys(i64(kill(i32(pid), i32(signal))))
}

// ---------- std.os: shared memory, this process ----------
priv shm_count: i64

// a POSIX shared memory object, unlinked at once (macOS has no memfd)
fn __os_shm_create(size: i64) -> i64 {
    name := cstr(fmt("/al.", getpid(), ".", atomic_add(&shm_count, 1)))
    fd := sys(i64(shm_open(name, 0x2 | 0x200 | 0x800, 384)))   // O_RDWR | O_CREAT | O_EXCL, 0600
    if fd < 0 {
        return fd
    }
    shm_unlink(name)
    fcntl(i32(fd), 2, 1)
    r := sys(i64(ftruncate(i32(fd), size)))
    if r < 0 {
        close(i32(fd))
        return r
    }
    return fd
}

fn __os_map_fd(fd: i64, size: i64, write: bool) -> i64 {
    if write {
        return sys(mmap(0, u64(size), 3, 1, i32(fd), 0))      // MAP_SHARED
    }
    return sys(mmap(0, u64(size), 1, 2, i32(fd), 0))          // MAP_PRIVATE
}

fn __os_process_id() -> i64 {
    return i64(getpid())
}

fn __os_current_dir() -> str {
    buf: [4096]u8
    if getcwd(&buf[0], 4096) == cast[*u8](0) {
        __io_result(sys(-1))
        return ""
    }
    __io_result(0)
    return clone(from_cstr(ptr(buf)))
}

// the target of this layer (see `enum Os` in prelude.al)
const TARGET_OS = Os.MacOS

// ---------- threads ----------
// A lock word (the low 4 bytes of the 8 at p) is 0 unlocked, 1 locked, 2 locked with waiters;
// a condition variable's word counts its signals. UL_COMPARE_AND_WAIT (1), ULF_WAKE_ALL (0x100).
fn __os_lock(p: *i64) {
    w := cast[*u32](p)
    _, ok := atomic_cas(w, 0, 1)
    if ok {
        return
    }
    while atomic_swap(w, 2) != 0 {
        __ulock_wait(1, w, 2, 0)
    }
}

fn __os_unlock(p: *i64) {
    w := cast[*u32](p)
    if atomic_swap(w, 0) == 2 {
        __ulock_wake(1, w, 0)
    }
}

fn __os_try_lock(p: *i64) -> bool {
    _, ok := atomic_cas(cast[*u32](p), 0, 1)
    return ok
}

fn __os_cond_wait(c: *i64, m: *i64, ns: i64) -> bool {
    s := cast[*u32](c)
    seq := atomic_load(s)
    __os_unlock(m)
    timed_out := false
    if ns < 0 {
        __ulock_wait(1, s, u64(seq), 0)
    } else {
        us := min(max(ns / 1000, 1), 0xFFFF_FFFF)
        timed_out = __ulock_wait(1, s, u64(seq), u32(us)) == -1 && *__error() == 60
    }
    __os_lock(m)
    return !timed_out
}

fn __os_cond_wake(c: *i64, all: bool) {
    s := cast[*u32](c)
    atomic_add(s, 1)
    __ulock_wake(if all { 0x101 } else { 1 }, s, 0)
}

fn __os_park() -> never {
    loop {
        __os_sleep_ns(1 << 40)
    }
}

fn __os_cpu_count() -> i64 {
    return max(sysconf(58), 1)                       // _SC_NPROCESSORS_ONLN
}

// threads are the C library's: pthread_create (c.os: [0] the pthread_t, [3] 1)
priv fn thread_entry(c: i64) -> i64 {
    __thread_main(cast[*__ThreadCtl](c))
    return 0
}

fn __os_thread_create(c: *__ThreadCtl) -> i64 {
    attr: [16]i64
    pthread_attr_init(&attr[0])
    pthread_attr_setstacksize(&attr[0], u64(c.stack))
    r := pthread_create(&c.os[0], &attr[0], thread_entry, cast[i64](c))
    pthread_attr_destroy(&attr[0])
    c.os[3] = 1
    return -linux_errno(i64(r))
}

fn __os_thread_join(c: *__ThreadCtl) {
    pthread_join(c.os[0], 0)
}

__tls_sigstack: i64

fn __os_thread_setup(c: *__ThreadCtl) {
    here := 0
    __tls_stack_hi = cast[i64](&here) + (1 << 20)
    __tls_stack_lo = __tls_stack_hi - c.stack - (1 << 21)
    p := __os_map(32768)
    if p > 0 || p < -4096 {
        ss := [3]i64{p, 32768, 0}
        sigaltstack(&ss[0], cast[*i64](0))
        __tls_sigstack = p
    }
}

fn __os_thread_cleanup() {
    if __tls_sigstack != 0 {
        ss := [3]i64{0, 0, 4}                          // SS_DISABLE
        sigaltstack(&ss[0], cast[*i64](0))
        __os_unmap(__tls_sigstack, 32768)
        __tls_sigstack = 0
    }
}

// ---------- std.os: programs with files as standard streams, groups, timed waits ----------
priv fn child_env(changes: []str) -> i64 {
    old := __argv + 8 * (__argc + 1)
    if len(changes) == 0 {
        return old
    }
    fn name_of(c: str) -> str {
        eq := index_of(c, '=')
        return if eq < 0 { c } else { c[..eq] }
    }
    envp := cast[*i64](old)
    out := vec[i64]()
    i := 0
    while envp[i] != 0 {
        p := cast[*u8](envp[i])
        n := 0
        while p[n] != 0 && p[n] != '=' {
            n += 1
        }
        keep := true
        for c in changes {
            if name_of(c) == mkslice[u8](p, n) {
                keep = false
                break
            }
        }
        if keep {
            out.push(envp[i])
        }
        i += 1
    }
    for j, c in changes {
        last := true
        for d in changes[j + 1..] {
            if name_of(d) == name_of(c) {
                last = false
            }
        }
        if last && contains(c, '=') {
            out.push(cast[i64](cstr(c)))
        }
    }
    out.push(0)
    return cast[i64](ptr(out.items()))
}

fn __os_spawn_files(argv: []str, sin: str, sout: str, serr: str, env: []str, group: bool) -> (i64, i64, i64) {
    if len(argv) == 0 {
        __io_result(-22)
        return (-1, -1, 0)
    }
    file, e := locate(argv[0])
    if e != 0 {
        __io_result(-e)
        return (-1, -1, 0)
    }
    flush()
    cargs := alloc[i64](len(argv) + 1)
    for i, a in argv {
        cargs[i] = cast[i64](cstr(a))
    }
    cfile := cstr(file)
    envp := child_env(env)
    fds: [3]i64
    paths := [3]str{sin, sout, serr}
    err := 0
    for k in 0..3 {
        fds[k] = -1
        if len(paths[k]) == 0 || err != 0 {
            continue
        }
        if k == 2 && serr == sout {
            fds[2] = fds[1]
            continue
        }
        r := __os_open(cstr(paths[k]), k != 0)
        if r < 0 {
            err = r
        } else {
            fds[k] = r
        }
    }
    note: [2]i32
    if err == 0 {
        err = min(cloexec_pipe(&note[0]), 0)
    }
    pid := -1
    if err == 0 {
        pid = sys(i64(fork()))
        if pid == 0 {
            if group {
                setpgid(0, 0)
            }
            for k in 0..3 {
                if fds[k] >= 0 {
                    dup2(i32(fds[k]), i32(k))
                }
            }
            execve(cfile, &cargs[0], envp)
            failed: [1]i64
            failed[0] = linux_errno(i64(*__error()))
            write(note[1], cast[i64](ptr(failed)), 8)
            _exit(127)
        }
        close(note[1])
        if pid > 0 && group {
            setpgid(i32(pid), i32(pid))
        }
        if pid < 0 {
            err = pid
            close(note[0])
        }
    }
    for k in 0..3 {
        if fds[k] >= 0 && !(k == 2 && fds[2] == fds[1]) {
            close(i32(fds[k]))
        }
    }
    if err != 0 {
        __io_result(err)
        return (-1, -1, 0)
    }
    failed: [1]i64
    __os_read(i64(note[0]), cast[i64](ptr(failed)), 8)
    close(note[0])
    if failed[0] != 0 {
        __os_wait(pid, pid, true)
        __io_result(-failed[0])
        return (-1, -1, 0)
    }
    __io_result(0)
    return (pid, pid, if group { 1 } else { 0 })
}

fn __os_kill_group(pid: i64, handle: i64, group: i64, signal: i64) -> i64 {
    return sys(i64(kill(i32(-pid), i32(signal))))
}

fn __os_group_close(group: i64) {}

// (no process descriptors to wait on: the process is looked at every millisecond)
fn __os_wait_ns(pid: i64, handle: i64, ns: i64) -> i64 {
    end := sat_add(clock_ns(), ns)
    st := 0
    loop {
        st = __os_wait(pid, handle, false)
        left := end - clock_ns()
        if st != -2 || left <= 0 {
            break
        }
        __os_sleep_ns(min(left, 1000000))
    }
    return st
}

// the processor of this layer (see enum Arch in prelude.al)
const TARGET_ARCH = Arch.Arm64
