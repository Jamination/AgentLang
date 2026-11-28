// AL run-time library, Linux layer for AArch64 (--target linux-arm64): raw system calls (no
// libc). The same functions as src/prelude_linux.al (the x86-64 layer, which this file
// follows), with the system call numbers of the generic Linux table that arm64 uses (no open,
// stat, pipe, fork, dup2, poll, rename, mkdir, unlink, access: their *at forms), the arm64
// layout of `struct stat` (st_mode at byte 16) and of the signal context, and TLS variant I
// (TPIDR_EL0 points to a 16-byte thread control block followed by the thread block, made by
// the entry stub of src/elf_arm64.al or the C loader). Results of system calls are the kernel's:
// a value, or -errno. The open flags O_DIRECTORY and O_NOFOLLOW differ from x86-64 (0x4000,
// 0x8000); the others used here are the same.

__argc: i64
__argv: i64
// the main thread's signal stack (every other thread maps its own: __os_thread_setup)
__sigstack: [32768]u8

// the stack of this thread, for stack traces (the main thread: below the initial stack
// pointer)
__tls_stack_lo: i64
__tls_stack_hi: i64
// a fault is being reported by this thread
__tls_in_fault: bool

priv const AT_FDCWD = -100

// uc: the interrupted state (the kernel's ucontext: uc_mcontext at byte 176, a struct
// sigcontext of fault_address, x0-x30, sp, pc, pstate), where a stack trace would start (the
// arm64 back end makes no stack-trace table yet). A fault while one is reported ends the
// program at once; a fault in another thread waits (the panic lock).
noinline fn __on_fault(sig: i64, info: i64, uc: i64) -> never {
    __panic_enter()
    if __tls_in_fault || __bt_busy {
        if __bt_busy {
            __err("  ... (the stack trace stopped at a fault)\n")
        }
        __os_exit(1)
    }
    __tls_in_fault = true
    // the stack walk's registers: sp in r[4] (the slot of x86-64's rsp)
    regs := cast[*i64](uc + 176 + 8)
    pc := regs[32]
    sp := regs[31]
    addr := cast[*i64](info + 16)[0]
    // a fault on the first instruction of a function (`stp x29, x30, [sp, #-16]!`: a stack
    // that overflows) has no frame of the function yet: the walk starts at its call
    if sig != 8 && sig != 5 && pc != addr && (pc & 3) == 0 && u64(pc) >= 0x10000 && cast[*u32](pc)[0] == 0xA9BF7BFD {
        pc = regs[30] - 4
    }
    __bt_fault_pc = pc
    __bt_fault_regs.r[4] = sp
    // (SIGTRAP: the BRK #1 of a division by zero, see DivTrap in src/arm64)
    if sig == 8 || sig == 5 {
        __die("panic: arithmetic fault (division by zero or overflow)", "", "")
    }
    __die_fault(addr)            // si_addr
}
priv page_size: i64

// the program headers (AT_PHDR, AT_PHNUM of the auxiliary vector, which follows the
// environment on the initial stack): (address, count); also records AT_PAGESZ
priv fn phdrs() -> (i64, i64) {
    p := __argv + 8 * (__argc + 1)
    while cast[*i64](p)[0] != 0 {
        p += 8
    }
    p += 8
    phdr := 0
    phnum := 0
    while cast[*i64](p)[0] != 0 {
        a := cast[*i64](p)
        if a[0] == 3 {
            phdr = a[1]
        } else if a[0] == 5 {
            phnum = a[1]
        } else if a[0] == 6 {
            page_size = a[1]
        }
        p += 16
    }
    return (phdr, min(phnum, 64))
}

// the size of the thread block (PT_TLS, a multiple of 16; see layout_tls in the compiler)
priv tls_size: i64

// a thread block (TLS variant I) at p: the 16-byte thread control block, then the block; the
// thread pointer is p (the memory is fresh from mmap: zero)
priv fn tls_place(p: i64) -> i64 {
    return p
}

// sp: the initial stack pointer (argc, argv..., 0, envp..., 0); the entry stub has set the
// main thread's thread pointer already
fn __rt_init(sp: i64) {
    __argc = cast[*i64](sp)[0]
    __argv = sp + 8
    ph, n := phdrs()
    for k in 0..n {
        if cast[*u32](ph + 56 * k)[0] == 7 {
            tls_size = (cast[*i64](ph + 56 * k + 40)[0] + 15) & ~15
        }
    }
    __thread_init_main()
    __tls_stack_lo = sp - (1 << 36)
    __tls_stack_hi = sp
    // report crashes as panics: handlers run on their own stack so that stack overflow works too
    ss: [3]i64
    ss[0] = cast[i64](ptr(__sigstack))
    ss[2] = 32768
    syscall(132, ptr(ss), 0)                         // sigaltstack
    sa: [4]i64
    sa[0] = cast[i64](__on_fault)
    // SA_ONSTACK | SA_NODEFER | SA_SIGINFO (the handler never returns: no restorer)
    sa[1] = 0x08000000 | 0x40000000 | 4
    syscall(134, 11, ptr(sa), 0, 8)                  // rt_sigaction: SIGSEGV, SIGBUS, SIGFPE
    syscall(134, 7, ptr(sa), 0, 8)
    syscall(134, 8, ptr(sa), 0, 8)
    syscall(134, 5, ptr(sa), 0, 8)                   // SIGTRAP: division by zero
}
// the frames of this thread lie in its stack (the lower end only bounds a stack pointer that
// is nonsense); a thread a C library created: around the current stack pointer (the walk's
// other checks end the trace)
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

// ALC_CHECK_MEMORY is set and not "0" (see __released in prelude.al)
fn __os_check_memory() -> bool {
    v, set := env_get("ALC_CHECK_MEMORY")
    return set && v != "" && v != "0"
}

// system page size in bytes (from AT_PAGESZ, falling back to 4 KiB)
fn __os_page_size() -> i64 {
    if page_size >= 4096 && (page_size & (page_size - 1)) == 0 {
        return page_size
    }
    return 4096
}

// takes the pages [p, p + n) of an arena away (ALC_CHECK_MEMORY): a new mapping without access
// in their place gives their memory back and makes every access fault
fn __os_page_off(p: i64, n: i64) {
    // PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED|MAP_NORESERVE
    syscall(222, p, n, 0, 0x4032, -1, 0)
}

// ---------- stack traces through C libraries ----------
// Not yet on arm64: a trace ends at the first frame of C code (there is no CFI interpreter for
// arm64 here). The functions the prelude names:
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

// (not `-> never`: so that it is inlined; its callers are `never` functions)
inline fn __os_exit(code: i64) {
    syscall(94, code)
}

// nothing to add to the message on standard error
inline fn __os_panic(kind: str, loc: str, msg: str) {}

// writes n bytes at p to fd, also after interruptions and, on a non-blocking fd, waiting
// until it takes more (EAGAIN: poll); returns 0 or the error number of the failed write
fn __write_all(fd: i64, p: i64, n: i64) -> i64 {
    while n > 0 {
        r := syscall(64, fd, p, n)
        if r == -4 {
            continue
        }
        if r == -11 {
            // struct pollfd { fd, events = POLLOUT, revents }
            pfd: [2]i32
            pfd[0] = i32(fd)
            pfd[1] = 4
            syscall(73, ptr(pfd), 1, 0, 0, 8)            // ppoll
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
        r := syscall(63, fd, p, n)
        if r != -4 {
            return r
        }
    }
}

// O_RDONLY | O_CLOEXEC, or O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC with mode 0644
inline fn __os_open(path: *u8, write: bool) -> i64 {
    if write {
        return syscall(56, AT_FDCWD, path, 0x80241, 420)
    }
    return syscall(56, AT_FDCWD, path, 0x80000, 0)
}

inline fn __os_close(fd: i64) -> i64 {
    return syscall(57, fd)
}

// (size, true) for a regular file, (size, false) for anything else, (-1, false) on failure
inline fn __os_fstat(fd: i64) -> (i64, bool) {
    st: [18]i64
    if syscall(80, fd, ptr(st)) != 0 {
        return (-1, false)
    }
    return (st[6], (st[2] & 0xF000) == 0x8000)
}

// the address space of an arena is reserved once; the kernel commits memory as it is touched
noinline fn __heap_grow(n: i64) -> i64 {
    if __heap_base == 0 {
        // (64 GiB for the main thread's base arena; every other thread's becomes a region)
        size := if __region_depth == 0 && __tls_id == 1 { 1 << 36 } else { 1 << 34 }
        while size >= (1 << 24) {
            // PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE
            p := syscall(222, 0, size, 3, 0x4022, -1, 0)
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
    return syscall(222, 0, n, 3, 0x22, -1, 0)
}

// gives back memory of __os_map, of an arena or of a mapped file: 0 or -errno
inline fn __os_unmap(p: i64, n: i64) -> i64 {
    return syscall(215, p, n)
}

// runs a test block in a child process: 1 if it ended with status 0, else 0
inline fn __os_test(f: fn()) -> i64 {
    pid := syscall(220, 17, 0, 0, 0, 0)
    if pid == 0 {
        f()
        exit(0)
    }
    status: i32
    syscall(260, pid, &status, 0, 0)
    return if status == 0 { 1 } else { 0 }
}

inline fn __os_error_text(e: i64) -> str {
    return fmt("os error ", e)
}

fn clock_ns() -> i64 {
    ts: [2]i64
    syscall(113, 1, ptr(ts))
    return ts[0] * 1000000000 + ts[1]
}

// command line arguments (args()[0] is the program name)
fn args() -> []str {
    out := alloc[str](__argc)
    for i in 0..__argc {
        out[i] = from_cstr(cast[*u8](cast[*i64](__argv)[i]))
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
    if syscall(79, AT_FDCWD, path, ptr(st), 0) != 0 {
        return (-1, 0, 0)
    }
    kind := match st[2] & 0xF000 {
        0x8000 => 1
        0x4000 => 2
        _ => 0
    }
    return (kind, st[6], st[11] * 1000000000 + st[12])
}

fn __os_remove_file(path: *u8) -> i64 {
    return syscall(35, AT_FDCWD, path, 0)
}

fn __os_remove_dir(path: *u8) -> i64 {
    return syscall(35, AT_FDCWD, path, 0x200)
}

fn __os_make_dir(path: *u8) -> i64 {
    return syscall(34, AT_FDCWD, path, 493)
}

fn __os_rename(from: *u8, to: *u8) -> i64 {
    return syscall(38, AT_FDCWD, from, AT_FDCWD, to)
}

// appends the names of the entries of a directory except "." and ".." to names
fn __os_list_dir(path: *u8, names: *Vec[str]) -> i64 {
    // O_RDONLY | O_DIRECTORY | O_CLOEXEC
    fd := syscall(56, AT_FDCWD, path, 0x84000, 0)
    if fd < 0 {
        return fd
    }
    buf: [8192]u8
    loop {
        n := syscall(61, fd, ptr(buf), 8192)
        if n <= 0 {
            break
        }
        // struct linux_dirent64: u64 ino, i64 off, u16 reclen, u8 type, char name[]
        off := 0
        while off < n {
            reclen := i64(buf[off + 16]) | i64(buf[off + 17]) << 8
            name := from_cstr(cast[*u8](cast[i64](ptr(buf)) + off + 19))
            if name != "." && name != ".." {
                names.push(clone(name))
            }
            off += reclen
        }
    }
    syscall(57, fd)
    return 0
}

// ---------- std.time ----------
// seconds since 1970-01-01 UTC
fn __os_wall_time() -> i64 {
    ts: [2]i64
    syscall(113, 0, ptr(ts))
    return ts[0]
}

fn __os_sleep_ns(ns: i64) {
    ts: [2]i64
    ts[0] = ns / 1000000000
    ts[1] = ns % 1000000000
    // nanosleep stores the remaining time back into ts when a signal interrupts it (EINTR)
    while syscall(101, ptr(ts), ptr(ts)) == -4 {
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
        // access(file, X_OK); a directory is "executable" too
        r := syscall(48, AT_FDCWD, cstr(file), 1, 0)
        st: [18]i64
        if r == 0 && !(syscall(79, AT_FDCWD, cstr(file), ptr(st), 0) == 0 && st[2] & 0xF000 == 0x4000) {
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
    if __io_result(syscall(59, ptr(fds), 0x80000)) < 0 {
        return (-1, -1, -1)
    }
    note_r := i64(fds[0])
    note_w := i64(fds[1])
    if capture != 0 && __io_result(syscall(59, &fds[2], 0x80000)) < 0 {
        syscall(57, note_r)
        syscall(57, note_w)
        return (-1, -1, -1)
    }
    pipe_r := if capture != 0 { i64(fds[2]) } else { -1 }
    pipe_w := i64(fds[3])
    pid := __io_result(syscall(220, 17, 0, 0, 0, 0))
    if pid == 0 {
        if capture != 0 {
            // (dup2 clears O_CLOEXEC on the copies)
            syscall(24, pipe_w, 1, 0)
            if capture == 2 {
                syscall(24, pipe_w, 2, 0)
            }
        }
        failed: [1]i64
        failed[0] = -syscall(221, cfile, ptr(cargs), envp)
        syscall(64, note_w, ptr(failed), 8)
        syscall(94, 127)
    }
    syscall(57, note_w)
    if capture != 0 {
        syscall(57, pipe_w)
    }
    if pid < 0 {
        syscall(57, note_r)
        if pipe_r >= 0 {
            syscall(57, pipe_r)
        }
        return (-1, -1, -1)
    }
    failed: [1]i64
    __os_read(note_r, cast[i64](ptr(failed)), 8)
    syscall(57, note_r)
    if failed[0] != 0 {
        // the child exits at once: wait for it
        __os_wait(pid, pid, true)
        if pipe_r >= 0 {
            syscall(57, pipe_r)
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
        r = syscall(260, pid, ptr(status), if block { 0 } else { 1 }, 0)    // wait4(WNOHANG)
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
    return syscall(129, pid, signal)
}

// ---------- std.os: shared memory, this process ----------
// a new anonymous file of `size` bytes in memory (close-on-exec): a descriptor or -errno
fn __os_shm_create(size: i64) -> i64 {
    fd := syscall(279, ptr("al-shm"), 1)       // memfd_create(name, MFD_CLOEXEC)
    if fd < 0 {
        return fd
    }
    r := syscall(46, fd, size)                 // ftruncate
    if r < 0 {
        syscall(57, fd)
        return r
    }
    return fd
}

// maps the first `size` bytes of the file fd: shared and writable, or private and read-only;
// the address, or -errno
fn __os_map_fd(fd: i64, size: i64, write: bool) -> i64 {
    if write {
        return syscall(222, 0, size, 3, 1, fd, 0)       // PROT_READ | PROT_WRITE, MAP_SHARED
    }
    return syscall(222, 0, size, 1, 2, fd, 0)           // PROT_READ, MAP_PRIVATE
}

fn __os_process_id() -> i64 {
    return syscall(172)
}

// the working directory ("" if it cannot be told: see io_error())
fn __os_current_dir() -> str {
    buf: [4096]u8
    n := __io_result(syscall(17, ptr(buf), 4096))
    if n <= 0 {
        return ""
    }
    return clone(from_cstr(ptr(buf)))
}

// the target of this layer (see `enum Os` in prelude.al)
const TARGET_OS = Os.Linux
const TARGET_ARCH = Arch.Arm64

// ---------- threads ----------
// Locks and condition variables are futexes (system calls: with or without the C library).
// A lock word (the low 4 bytes of the 8 at p) is 0 unlocked, 1 locked, 2 locked with waiters;
// a condition variable's word counts its signals.
fn __os_lock(p: *i64) {
    w := cast[*u32](p)
    _, ok := atomic_cas(w, 0, 1)
    if ok {
        return
    }
    while atomic_swap(w, 2) != 0 {
        syscall(98, w, 128, 2, 0)                    // FUTEX_WAIT_PRIVATE
    }
}

fn __os_unlock(p: *i64) {
    w := cast[*u32](p)
    if atomic_swap(w, 0) == 2 {
        syscall(98, w, 129, 1)                       // FUTEX_WAKE_PRIVATE
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
    r := 0
    if ns < 0 {
        r = syscall(98, s, 128, seq, 0)
    } else {
        ts := [2]i64{ns / 1000000000, ns % 1000000000}
        r = syscall(98, s, 128, seq, ptr(ts))        // (a relative time)
    }
    __os_lock(m)
    return r != -110                                  // ETIMEDOUT
}

fn __os_cond_wake(c: *i64, all: bool) {
    s := cast[*u32](c)
    atomic_add(s, 1)
    syscall(98, s, 129, if all { 0x7FFFFFFF } else { 1 })
}

fn __os_park() -> never {
    loop {
        syscall(73, 0, 0, 0, 0, 8)                    // ppoll without descriptors: forever
    }
}

// the CPUs of the affinity mask
fn __os_cpu_count() -> i64 {
    mask: [16]u64
    r := syscall(123, 0, 128, ptr(mask))              // sched_getaffinity
    n := 0
    for k in 0..min(max(r, 0) / 8, 16) {
        n += i64(popcnt(mask[k]))
    }
    return max(n, 1)
}

// A thread is made with clone: one mapping holds a guard page, the stack and the thread block
// (see tls_place), and the kernel clears `tid` when the thread has ended (the join waits for
// that). A program that declares C functions uses the C library's threads (see the end of the
// file).
// the start of a thread made by clone: ends the thread (not the process) when it is done
priv fn thread_entry_raw(c: i64) {
    __thread_main(cast[*__ThreadCtl](c))
    syscall(93, 0)
}

// c.os: [0] the mapping, [1] its size, [3] 2 (clone)
fn __os_thread_create(c: *__ThreadCtl) -> i64 {
    total := 4096 + c.stack + tls_size + 64
    // PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_STACK
    p := syscall(222, 0, total, 3, 0x22 | 0x4000 | 0x20000, -1, 0)
    if p < 0 && p > -4096 {
        return p
    }
    syscall(226, p, 4096, 0)                           // the guard page: PROT_NONE
    top := p + 4096 + c.stack
    tp := tls_place(top)
    // the child pops its argument and its function from the new stack (see __clone)
    sp := top - 16
    cast[*i64](sp)[0] = cast[i64](c)
    f := thread_entry_raw
    memcopy(sp + 8, &f, 8)
    c.os[0] = p
    c.os[1] = total
    c.os[3] = 2
    // CLONE_VM | FS | FILES | SIGHAND | THREAD | SYSVSEM | SETTLS | PARENT_SETTID | CHILD_CLEARTID
    flags := 0x100 | 0x200 | 0x400 | 0x800 | 0x10000 | 0x40000 | 0x80000 | 0x100000 | 0x200000
    tid := cast[i64](&c.tid)
    r := __clone(flags, sp, tid, tid, tp)
    if r < 0 {
        syscall(215, p, total)
        return r
    }
    return 0
}

fn __os_thread_join(c: *__ThreadCtl) {
    loop {
        t := atomic_load(&c.tid)
        if t == 0 {
            break
        }
        syscall(98, &c.tid, 0, t, 0)                 // FUTEX_WAIT (the kernel's wake is shared)
    }
    syscall(215, c.os[0], c.os[1])
}

// this thread's signal stack (sigaltstack is per thread)
__tls_sigstack: i64

fn __os_thread_setup(c: *__ThreadCtl) {
    if c.os[3] == 2 {
        __tls_stack_hi = c.os[0] + 4096 + c.stack
    } else {
        // (the C library's stack: its top is a little above this frame)
        here := 0
        __tls_stack_hi = cast[i64](&here) + (1 << 20)
    }
    __tls_stack_lo = __tls_stack_hi - c.stack - (1 << 21)
    p := __os_map(32768)
    if p > 0 || p < -4096 {
        ss := [3]i64{p, 0, 32768}
        syscall(132, ptr(ss), 0)
        __tls_sigstack = p
    }
}

fn __os_thread_cleanup() {
    if __tls_sigstack != 0 {
        ss := [3]i64{0, 2, 0}                          // SS_DISABLE
        syscall(132, ptr(ss), 0)
        __os_unmap(__tls_sigstack, 32768)
        __tls_sigstack = 0
    }
}

// ---------- std.os: programs with files as standard streams, groups, timed waits ----------
// (at the end of the file: nothing above moves, so programs that use none of this are built
// the same, source lines of their stack traces included)

// the environment of a started program: this process's, changed by `changes` ("NAME=value"
// sets a variable, "NAME" removes it; the last change of a name counts)
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

// Starts argv like __os_spawn, with files in place of the standard streams and a changed
// environment: `sin` is read as standard input, `sout` and `serr` (created or emptied) take
// standard output and standard error ("" each: that of this process; serr the same path as
// sout: one open file takes both); `env` as for child_env; `group`: the program leads a new
// process group. Returns (process id, process id, 1 for a group else 0), or (-1, -1, 0) with
// io_error() (also if a file cannot be opened).
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
    // the files (close-on-exec: the child's copies on 0, 1 and 2 are not), then the pipe that
    // tells whether execve worked, as in __os_spawn
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
        // O_RDONLY, or O_WRONLY | O_CREAT | O_TRUNC; both with O_CLOEXEC
        r := syscall(56, AT_FDCWD, cstr(paths[k]), if k == 0 { 0x80000 } else { 0x80241 }, 0o666)
        if r < 0 {
            err = r
        } else {
            fds[k] = r
        }
    }
    note: [2]i32
    if err == 0 {
        err = min(syscall(59, ptr(note), 0x80000), 0)
    }
    pid := -1
    if err == 0 {
        pid = syscall(220, 17, 0, 0, 0, 0)
        if pid == 0 {
            if group {
                syscall(154, 0, 0)                          // setpgid
            }
            for k in 0..3 {
                if fds[k] >= 0 {
                    syscall(24, fds[k], k, 0)
                }
            }
            failed: [1]i64
            failed[0] = -syscall(221, cfile, ptr(cargs), envp)
            syscall(64, i64(note[1]), ptr(failed), 8)
            syscall(94, 127)
        }
        syscall(57, i64(note[1]))
        if pid > 0 && group {
            // (here too: a signal to the group may come before the child has run)
            syscall(154, pid, pid)
        }
        if pid < 0 {
            err = pid
            syscall(57, i64(note[0]))
        }
    }
    for k in 0..3 {
        if fds[k] >= 0 && !(k == 2 && fds[2] == fds[1]) {
            syscall(57, fds[k])
        }
    }
    if err != 0 {
        __io_result(err)
        return (-1, -1, 0)
    }
    failed: [1]i64
    __os_read(i64(note[0]), cast[i64](ptr(failed)), 8)
    syscall(57, i64(note[0]))
    if failed[0] != 0 {
        __os_wait(pid, pid, true)
        __io_result(-failed[0])
        return (-1, -1, 0)
    }
    __io_result(0)
    return (pid, pid, if group { 1 } else { 0 })
}

// sends a signal to every process of the group that a process of __os_spawn_files leads: 0
// or -errno
fn __os_kill_group(pid: i64, handle: i64, group: i64, signal: i64) -> i64 {
    return syscall(129, -pid, signal)
}

// the group of a process that has been waited for is no longer needed
fn __os_group_close(group: i64) {}

// Waits at most ns nanoseconds for a process of __os_spawn: its status, -2 if it still runs
// then, -1 if it cannot be waited for (io_error()), as __os_wait.
fn __os_wait_ns(pid: i64, handle: i64, ns: i64) -> i64 {
    end := sat_add(clock_ns(), ns)
    // a descriptor of the process that is readable once it has ended (pidfd_open, Linux 5.3;
    // without it the process is looked at every millisecond)
    fd := syscall(434, pid, 0)
    st := 0
    loop {
        st = __os_wait(pid, handle, false)
        left := end - clock_ns()
        if st != -2 || left <= 0 {
            break
        }
        if fd >= 0 {
            // struct pollfd: fd, events = POLLIN; ppoll with a timespec
            pfd: [1]i64
            pfd[0] = fd | 1 << 32
            ts: [2]i64
            ts[0] = left / 1000000000
            ts[1] = left % 1000000000
            syscall(73, ptr(pfd), 1, ptr(ts), 0, 8)
        } else {
            __os_sleep_ns(min(left, 1000000))
        }
    }
    if fd >= 0 {
        syscall(57, fd)
    }
    return st
}

// ---------- threads of a program that declares C functions ----------
// Such a program is dynamically linked (if it reaches a C function): the C library's loader owns
// TPIDR_EL0 and has made the main thread's thread block, and threads must be made by the C
// library, whose thread functions set up its state of the thread (which the C code it calls
// needs). pthread_create and friends are looked up when a thread starts, in the libraries the
// loader mapped, so that no program depends on them just because it could start threads (as the
// x86-64 layer does). The driver (`program` in src/main.al) renames these two functions to
// __os_thread_create / __os_thread_join in a program that declares C functions, and the two
// above to __os_clone_thread_create / __os_clone_thread_join; other programs never refer to
// what follows, which is therefore not even compiled for them (they are built as before). A
// program that declares C functions but reaches none is static (it has no r_debug): clone.

// the loader's r_debug (0: none): DT_DEBUG of the program's dynamic section, found through the
// program headers named by the auxiliary vector (AT_PHDR, AT_PHNUM: read here, not with phdrs(),
// which a reference from here would number earlier: -O0 lays functions out by their numbers)
priv noinline fn r_debug() -> i64 {
    p := __argv + 8 * (__argc + 1)
    while cast[*i64](p)[0] != 0 {
        p += 8
    }
    p += 8
    phdr := 0
    phnum := 0
    while cast[*i64](p)[0] != 0 {
        a := cast[*i64](p)
        if a[0] == 3 {
            phdr = a[1]
        } else if a[0] == 5 {
            phnum = a[1]
        }
        p += 16
    }
    bias := 0
    dyn := 0
    for k in 0..min(phnum, 64) {
        h := phdr + 56 * k
        t := cast[*u32](h)[0]
        if t == 6 {
            bias = phdr - cast[*i64](h + 16)[0]  // PT_PHDR: where the headers were meant to be
        } else if t == 2 {
            dyn = cast[*i64](h + 16)[0]          // PT_DYNAMIC
        }
    }
    if dyn == 0 {
        return 0
    }
    d := cast[*i64](dyn + bias)
    i := 0
    while d[i] != 0 && i < 2000 {
        if d[i] == 21 {
            return d[i + 1]
        }
        i += 2
    }
    return 0
}

// the address of the C function `name` in the libraries the loader mapped (the default version
// of a versioned one), 0 if none: the loader's list of link maps (l_addr, l_name, l_ld, l_next)
priv fn c_symbol(name: str) -> i64 {
    rd := r_debug()
    if rd == 0 {
        return 0
    }
    m := cast[*i64](rd)[1]
    n := 0
    while m != 0 && n < 10000 {
        l := cast[*i64](m)
        if l[0] != 0 {
            a := lib_symbol(l[0], l[2], name)
            if a != 0 {
                return a
            }
        }
        m = l[3]
        n += 1
    }
    return 0
}

// `name` in the library at load address base with the dynamic section dyn (DT_GNU_HASH)
priv fn lib_symbol(base: i64, dyn: i64, name: str) -> i64 {
    strtab := 0
    symtab := 0
    gnuhash := 0
    versym := 0
    d := cast[*i64](dyn)
    i := 0
    while d[i] != 0 && i < 1000 {
        v := d[i + 1]
        // (the loader may have relocated these addresses or not)
        if v != 0 && v < base {
            v += base
        }
        match d[i] {
            5 => strtab = v
            6 => symtab = v
            0x6ffffef5 => gnuhash = v
            0x6ffffff0 => versym = v
            _ => {}
        }
        i += 2
    }
    if strtab == 0 || symtab == 0 || gnuhash == 0 {
        return 0
    }
    h := cast[*u32](gnuhash)
    nb := i64(h[0])
    symoff := i64(h[1])
    buckets := gnuhash + 16 + 8 * i64(h[2])
    chain := buckets + 4 * nb
    hv: u32 = 5381
    for c in name {
        hv = hv * 33 + u32(c)
    }
    if nb == 0 {
        return 0
    }
    k := i64(cast[*u32](buckets)[i64(hv % u32(nb))])
    if k < symoff {
        return 0
    }
    found := 0
    loop {
        ch := cast[*u32](chain)[k - symoff]
        if ch | 1 == hv | 1 {
            sym := symtab + 24 * k
            nm := cast[*u8](strtab + i64(cast[*u32](sym)[0]))
            same := nm[len(name)] == 0
            for j in 0..len(name) {
                if nm[j] != name[j] {
                    same = false
                    break
                }
            }
            if same && cast[*u16](sym + 6)[0] != 0 {
                a := base + cast[*i64](sym + 8)[0]
                if versym == 0 || cast[*u16](versym)[k] & 0x8000 == 0 {
                    return a
                }
                if found == 0 {
                    found = a
                }
            }
        }
        if ch & 1 != 0 {
            break
        }
        k += 1
    }
    return found
}

// the start of a thread of the C library (pthread_create)
// the start of a thread of the C library (pthread_create)
priv fn thread_entry_c(c: i64) -> i64 {
    __thread_main(cast[*__ThreadCtl](c))
    return 0
}

// c.os: [0] the pthread_t, [3] 1 (C library); without the C library's thread functions a
// thread cannot start (clone would leave it without the C library's state of the thread). The
// functions are looked up for every thread (a thread start costs far more than the lookup).
fn __os_c_thread_create(c: *__ThreadCtl) -> i64 {
    if r_debug() == 0 {
        return __os_clone_thread_create(c)
    }
    create := c_symbol("pthread_create")
    attr_init := c_symbol("pthread_attr_init")
    attr_stack := c_symbol("pthread_attr_setstacksize")
    attr_destroy := c_symbol("pthread_attr_destroy")
    if create == 0 || attr_init == 0 || attr_stack == 0 || attr_destroy == 0 || c_symbol("pthread_join") == 0 {
        return -38                                    // ENOSYS
    }
    // (pthread_attr_t: 64 bytes on aarch64 glibc, 56 on musl)
    attr: [16]i64
    cast[fn(*i64) -> i32](attr_init)(&attr[0])
    cast[fn(*i64, i64) -> i32](attr_stack)(&attr[0], c.stack)
    r := cast[fn(*i64, *i64, fn(i64) -> i64, i64) -> i32](create)(&c.os[0], &attr[0], thread_entry_c, cast[i64](c))
    cast[fn(*i64) -> i32](attr_destroy)(&attr[0])
    c.os[3] = 1
    return -i64(r)
}

fn __os_c_thread_join(c: *__ThreadCtl) {
    if c.os[3] != 1 {
        __os_clone_thread_join(c)
        return
    }
    cast[fn(i64, i64) -> i32](c_symbol("pthread_join"))(c.os[0], 0)
}
