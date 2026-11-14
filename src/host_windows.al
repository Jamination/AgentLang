// The compiler's host on Windows: the functions src/base.al lists, by kernel32.dll and the
// `__win_*` functions of the run-time library's Windows layer. Included by base.al when the
// compiler is built for Windows (alc.exe).

priv extern "kernel32.dll" fn CloseHandle(h: i64) -> i32
priv extern "kernel32.dll" fn CreateFileW(name: *u16, access: u32, share: u32, security: i64, disposition: u32, flags: u32, template: i64) -> i64
priv extern "kernel32.dll" fn GetFileInformationByHandle(h: i64, info: *u32) -> i32
priv extern "kernel32.dll" fn WaitForSingleObject(h: i64, ms: u32) -> u32
priv extern "kernel32.dll" fn CreateThread(security: i64, stack: i64, start: fn(i64) -> u32, arg: i64, flags: u32, id: i64) -> i64
priv extern "kernel32.dll" fn SetThreadStackGuarantee(size: *u32) -> i32
priv extern "kernel32.dll" fn GetCurrentThreadStackLimits(low: *i64, high: *i64)
priv extern "kernel32.dll" fn GetEnvironmentStringsW() -> *u16
priv extern "kernel32.dll" fn FreeEnvironmentStringsW(block: *u16) -> i32
priv extern "kernel32.dll" fn GetActiveProcessorCount(group: u16) -> u32
priv extern "kernel32.dll" fn DeleteFileW(name: *u16) -> i32

priv const INVALID_HANDLE = -1
priv const INFINITE: u32 = 0xFFFFFFFF

// the size of this thread's stack (its reservation) in bytes, -1 if it is not known
fn stack_size() -> i64 {
    lo: i64
    hi: i64
    GetCurrentThreadStackLimits(&lo, &hi)
    return if hi > lo { hi - lo } else { -1 }
}

priv big_stack_fn: fn() -> i64
priv big_stack_result: i64

// (the run-time library gives this thread, which it did not start, a context of its own on
// first use: arena, id, line-buffered output; its last partial line is written here)
priv fn big_stack_thread(arg: i64) -> u32 {
    // the same room for the handler after a stack overflow as on the first thread
    g: u32 = 0x10000
    SetThreadStackGuarantee(&g)
    f := big_stack_fn
    big_stack_result = f()
    flush()
    return 0
}

// f runs on a new thread whose stack reserves `bytes` (committed as it is used), while this
// thread waits for it without doing anything else. If the thread cannot be created, f runs
// here, with the stack there is.
fn with_stack(bytes: i64, f: fn() -> i64) -> i64 {
    big_stack_fn = f
    // STACK_SIZE_PARAM_IS_A_RESERVATION
    h := CreateThread(0, bytes, big_stack_thread, 0, 0x10000, 0)
    if h == 0 {
        return f()
    }
    WaitForSingleObject(h, INFINITE)
    CloseHandle(h)
    return big_stack_result
}

// whether the name of the environment entry e (k units) is d, without regard to case
priv fn same_name(e: *u16, k: i64, d: str) -> bool {
    if len(d) != k {
        return false
    }
    for i in 0..k {
        a := i64(e[i])
        b := i64(d[i])
        if a >= 97 && a <= 122 {
            a -= 32
        }
        if b >= 97 && b <= 122 {
            b -= 32
        }
        if a != b {
            return false
        }
    }
    return true
}

// the environment block of this process (UTF-16) without the variables named in `drop`
// (compared without regard to case) and with the `NAME=value` entries of `add`; 0 (this
// process's environment) if there is nothing to change
priv fn env_block(drop: []str, add: []str) -> i64 {
    if len(drop) == 0 && len(add) == 0 {
        return 0
    }
    out := vec[u16]()
    blk := GetEnvironmentStringsW()
    if blk != nil {
        at := cast[i64](blk)
        next: loop {
            e := cast[*u16](at)
            n := __win_wcslen(e)
            if n == 0 {
                break
            }
            at += 2 * (n + 1)
            // the name ends at the first '=' after the first unit ("=C:=C:\x" names the
            // working directory of drive C)
            k := 1
            while k < n && e[k] != 61 {
                k += 1
            }
            for d in drop {
                if same_name(e, k, d) {
                    continue next
                }
            }
            out.extend(mkslice[u16](e, n + 1))
        }
        FreeEnvironmentStringsW(blk)
    }
    for a in add {
        w := __win_wide(a)
        out.extend(mkslice[u16](w, __win_wcslen(w) + 1))
    }
    // the block ends with an empty entry (an empty block: two NULs)
    if out.len == 0 {
        out.push(0)
    }
    out.push(0)
    return cast[i64](ptr(out.items()))
}

fn run_program_env(path: str, argv: []str, drop: []str, add: []str) -> i64 {
    flush()
    m := mark()
    defer { release(m) }
    h := __win_start(path, argv, env_block(drop, add))
    if h == 0 {
        return -1
    }
    return __os_wait(0, h, true)
}

// nothing to do: whether a file can be executed does not depend on a mode
fn make_executable(path: str) -> bool {
    return true
}

fn unlink_file(path: str) -> bool {
    return DeleteFileW(__win_wide(path)) != 0
}

// "volume serial number:file index" of the file that path names (following links)
fn file_id(path: str) -> (str, bool) {
    // no access needed; FILE_FLAG_BACKUP_SEMANTICS also opens directories
    h := CreateFileW(__win_wide(path), 0, 7, 0, 3, 0x02000000, 0)
    if h == INVALID_HANDLE {
        return ("", false)
    }
    // BY_HANDLE_FILE_INFORMATION: ..., volume serial number at 7, file index high, low at 11, 12
    d: [13]u32
    ok := GetFileInformationByHandle(h, &d[0])
    CloseHandle(h)
    if ok == 0 {
        return ("", false)
    }
    return (fmt(i64(d[7]), ":", (i64(d[11]) << 32) | i64(d[12])), true)
}

// the number of processors of the system
fn cpu_count() -> i64 {
    // ALL_PROCESSOR_GROUPS
    return max(i64(GetActiveProcessorCount(0xFFFF)), 1)
}
