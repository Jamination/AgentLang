// The compiler's host on Linux: the functions src/base.al lists, by system calls. Included by
// base.al when the compiler is built for Linux.

// the environment this process was started with: the addresses of its `NAME=value` C strings
priv fn environ() -> []i64 {
    envp := cast[*i64](__argv + 8 * (__argc + 1))
    n := 0
    while envp[n] != 0 {
        n += 1
    }
    return mkslice[i64](envp, n)
}

// the soft stack limit in bytes, -1 if it is unlimited or not known
fn stack_size() -> i64 {
    lim: [2]i64
    if syscall(97, 3, ptr(lim)) != 0 || lim[0] < 0 {
        return -1
    }
    return lim[0]
}

// If the stack limit is lower than `bytes` (and not unlimited: -1), raises it and starts the
// compiler again first (the limit only applies to a new process image), with the marker
// ALC_STACK_SET=<original limit> in the environment (removed again for the programs
// run_program_env starts). Without a way to raise it, f runs with the stack there is.
fn with_stack(bytes: i64, f: fn() -> i64) -> i64 {
    lim: [2]i64
    if syscall(97, 3, ptr(lim)) != 0 || lim[0] == -1 || lim[0] >= bytes {
        return f()
    }
    // already restarted once: do not loop if the limit cannot be raised
    _, restarted := env_get("ALC_STACK_SET")
    want := if lim[1] != -1 { min(bytes, lim[1]) } else { bytes }
    if restarted || want <= lim[0] {
        return f()
    }
    orig := lim[0]
    lim[0] = want
    if syscall(160, 3, ptr(lim)) != 0 {
        return f()
    }
    // the environment plus the marker, which holds the original limit (for run_program_env)
    env := environ()
    nenv := alloc[i64](len(env) + 2)
    copy(nenv, env)
    nenv[len(env)] = cast[i64](cstr(fmt("ALC_STACK_SET=", orig)))
    syscall(59, ptr("/proc/self/exe"), __argv, ptr(nenv))
    return f()
}

// The program gets the stack limit the compiler was started with: the marker of with_stack
// is not passed on, the child sets the limit back to its value.
fn run_program_env(path: str, argv: []str, drop: []str, add: []str) -> i64 {
    flush()
    cargs := alloc[i64](len(argv) + 2)
    cargs[0] = cast[i64](cstr(path))
    for i, a in argv {
        cargs[i + 1] = cast[i64](cstr(a))
    }
    env := environ()
    envp := alloc[i64](len(env) + len(add) + 1)
    k := 0
    orig := -2
    next: for p in env {
        e := from_cstr(cast[*u8](p))
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
        envp[k] = p
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
    return __os_wait(pid, pid, true)
}

fn make_executable(path: str) -> bool {
    return syscall(90, cstr(path), 0o755) == 0
}

// "device:inode" of the file that path names (following links)
fn file_id(path: str) -> (str, bool) {
    st: [18]i64
    if syscall(4, cstr(path), ptr(st)) != 0 {
        return ("", false)
    }
    return (fmt(st[0], ":", st[1]), true)
}

// the CPUs this process may run on (sched_getaffinity), limited by a cgroup v2 CPU quota
// (/sys/fs/cgroup/cpu.max: "quota period", or "max period" without a limit)
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

fn shared_map(bytes: i64) -> i64 {
    // PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS | MAP_NORESERVE
    r := syscall(9, 0, bytes, 3, 0x4021, -1, 0)
    return if r < 0 && r > -4096 { 0 } else { r }
}

fn fork_worker(quiet: bool) -> i64 {
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

// (close-on-exec)
fn pipe_open() -> (i64, i64) {
    fds: [1]i64
    if syscall(293, ptr(fds), 0x80000) != 0 {
        return (-1, -1)
    }
    return (fds[0] & 0xFFFFFFFF, fds[0] >> 32)
}
