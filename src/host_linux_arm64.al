// The compiler's host on Linux for AArch64: src/host_linux.al with the system calls of the
// generic Linux table that arm64 uses (getrlimit 163, setrlimit 164, execve 221, clone 220 in
// place of fork, exit_group 94, fchmodat 53, unlinkat 35, newfstatat 79, sched_getaffinity
// 123). Included by base.al when the compiler is built with `--target linux-arm64 -D
// HOST_ARM64=true`.

priv const AT_FDCWD = -100

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
    if syscall(163, 3, ptr(lim)) != 0 || lim[0] < 0 {
        return -1
    }
    return lim[0]
}

// as with_stack in host_linux.al: raises the stack limit and starts the compiler again
fn with_stack(bytes: i64, f: fn() -> i64) -> i64 {
    lim: [2]i64
    if syscall(163, 3, ptr(lim)) != 0 || lim[0] == -1 || lim[0] >= bytes {
        return f()
    }
    _, restarted := env_get("ALC_STACK_SET")
    want := if lim[1] != -1 { min(bytes, lim[1]) } else { bytes }
    if restarted || want <= lim[0] {
        return f()
    }
    orig := lim[0]
    lim[0] = want
    if syscall(164, 3, ptr(lim)) != 0 {
        return f()
    }
    env := environ()
    nenv := alloc[i64](len(env) + 2)
    copy(nenv, env)
    nenv[len(env)] = cast[i64](cstr(fmt("ALC_STACK_SET=", orig)))
    syscall(221, ptr("/proc/self/exe"), __argv, ptr(nenv))
    return f()
}

// as run_program_env in host_linux.al
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
    pid := syscall(220, 17, 0, 0, 0, 0)             // clone(SIGCHLD): fork
    if pid < 0 {
        return -1
    }
    if pid == 0 {
        lim: [2]i64
        if orig != -2 && syscall(163, 3, ptr(lim)) == 0 {
            lim[0] = orig
            syscall(164, 3, ptr(lim))
        }
        syscall(221, cargs[0], ptr(cargs), ptr(envp))
        syscall(94, 127)
    }
    return __os_wait(pid, pid, true)
}

fn make_executable(path: str) -> bool {
    return syscall(53, AT_FDCWD, cstr(path), 0o755) == 0
}

fn unlink_file(path: str) -> bool {
    return syscall(35, AT_FDCWD, cstr(path), 0) == 0
}

// "device:inode" of the file that path names (following links)
fn file_id(path: str) -> (str, bool) {
    st: [18]i64
    if syscall(79, AT_FDCWD, cstr(path), ptr(st), 0) != 0 {
        return ("", false)
    }
    return (fmt(st[0], ":", st[1]), true)
}

// as cpu_count in host_linux.al
fn cpu_count() -> i64 {
    mask: [16]u64
    n := syscall(123, 0, 128, ptr(mask))
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
