// AL run-time library, Windows layer: kernel32.dll only (no C run-time library). Compiled after
// src/prelude.al into every program built with --target windows; the functions it has to
// define are listed at the top of src/prelude.al.
//
// - Descriptors: 0, 1, 2 are the standard handles (GetStdHandle); every other "descriptor" is a
//   Windows handle.
// - Text: AL strings are UTF-8. Paths, arguments, environment variables and console text are
//   converted from and to UTF-16; unpaired surrogates of Windows names come out as the 3-byte
//   (WTF-8) sequences that are converted back to them, so every file name survives a round trip.
//   Invalid UTF-8 becomes U+FFFD.
// - Errors: Windows error codes are mapped to the Linux errno of the same meaning
//   (errno_of); a code without one becomes 0x10000 + the code ("windows error N").
// - Exit status: the low 8 bits of the code, as on Linux.

priv extern "kernel32.dll" fn GetStdHandle(which: u32) -> i64
priv extern "kernel32.dll" fn GetConsoleMode(h: i64, mode: *u32) -> i32
priv extern "kernel32.dll" fn WriteConsoleW(h: i64, buf: *u16, n: u32, written: *u32, reserved: i64) -> i32
priv extern "kernel32.dll" fn ReadConsoleW(h: i64, buf: *u16, n: u32, got: *u32, control: i64) -> i32
priv extern "kernel32.dll" fn WriteFile(h: i64, buf: i64, n: u32, written: *u32, overlapped: i64) -> i32
priv extern "kernel32.dll" fn ReadFile(h: i64, buf: i64, n: u32, got: *u32, overlapped: i64) -> i32
priv extern "kernel32.dll" fn CreateFileW(name: *u16, access: u32, share: u32, security: i64, disposition: u32, flags: u32, template: i64) -> i64
priv extern "kernel32.dll" fn CloseHandle(h: i64) -> i32
priv extern "kernel32.dll" fn GetFileType(h: i64) -> u32
priv extern "kernel32.dll" fn GetFileSizeEx(h: i64, size: *i64) -> i32
priv extern "kernel32.dll" fn GetLastError() -> u32
priv extern "kernel32.dll" fn SetLastError(e: u32)
priv extern "kernel32.dll" fn ExitProcess(code: u32)
priv extern "kernel32.dll" fn SetErrorMode(mode: u32) -> u32
priv extern "kernel32.dll" fn AddVectoredExceptionHandler(first: u32, handler: fn(i64) -> i32) -> i64
priv extern "kernel32.dll" fn SetThreadStackGuarantee(size: *u32) -> i32
priv extern "kernel32.dll" fn SetUnhandledExceptionFilter(filter: fn(i64) -> i32) -> i64
priv extern "kernel32.dll" fn GetModuleHandleW(name: *u16) -> i64
priv extern "kernel32.dll" fn VirtualAlloc(addr: i64, size: i64, kind: u32, protect: u32) -> i64
priv extern "kernel32.dll" fn VirtualFree(addr: i64, size: i64, kind: u32) -> i32
priv extern "kernel32.dll" fn VirtualQuery(addr: i64, info: *i64, size: i64) -> i64
priv extern "kernel32.dll" fn QueryPerformanceCounter(c: *i64) -> i32
priv extern "kernel32.dll" fn QueryPerformanceFrequency(f: *i64) -> i32
priv extern "kernel32.dll" fn GetSystemTimeAsFileTime(ft: *i64)
priv extern "kernel32.dll" fn GetCommandLineW() -> *u16
priv extern "kernel32.dll" fn GetEnvironmentVariableW(name: *u16, buf: *u16, n: u32) -> u32
priv extern "kernel32.dll" fn SetEnvironmentVariableW(name: *u16, value: *u16) -> i32
priv extern "kernel32.dll" fn GetModuleFileNameW(module: i64, buf: *u16, n: u32) -> u32
priv extern "kernel32.dll" fn CreateProcessW(app: *u16, cmd: *u16, psec: i64, tsec: i64, inherit: i32, flags: u32, env: i64, dir: i64, si: *i64, pi: *i64) -> i32
priv extern "kernel32.dll" fn WaitForSingleObject(h: i64, ms: u32) -> u32
priv extern "kernel32.dll" fn GetExitCodeProcess(h: i64, code: *u32) -> i32
priv extern "kernel32.dll" fn TerminateProcess(h: i64, code: u32) -> i32
priv extern "kernel32.dll" fn CreatePipe(r: *i64, w: *i64, security: i64, size: u32) -> i32
priv extern "kernel32.dll" fn DuplicateHandle(from_process: i64, h: i64, to_process: i64, out: *i64, access: u32, inherit: i32, options: u32) -> i32
priv extern "kernel32.dll" fn GetCurrentProcess() -> i64
priv extern "kernel32.dll" fn GetCurrentProcessId() -> u32
priv extern "kernel32.dll" fn GetCurrentDirectoryW(n: u32, buf: *u16) -> u32
priv extern "kernel32.dll" fn GetFileAttributesW(name: *u16) -> u32
priv extern "kernel32.dll" fn GetFileAttributesExW(name: *u16, level: i32, info: *u32) -> i32
priv extern "kernel32.dll" fn GetFileInformationByHandle(h: i64, info: *u32) -> i32
priv extern "kernel32.dll" fn DeleteFileW(name: *u16) -> i32
priv extern "kernel32.dll" fn RemoveDirectoryW(name: *u16) -> i32
priv extern "kernel32.dll" fn CreateDirectoryW(name: *u16, security: i64) -> i32
priv extern "kernel32.dll" fn MoveFileExW(from: *u16, to: *u16, flags: u32) -> i32
priv extern "kernel32.dll" fn FindFirstFileW(pattern: *u16, data: *u32) -> i64
priv extern "kernel32.dll" fn FindNextFileW(h: i64, data: *u32) -> i32
priv extern "kernel32.dll" fn FindClose(h: i64) -> i32
priv extern "kernel32.dll" fn Sleep(ms: u32)
priv extern "kernel32.dll" fn CreateWaitableTimerExW(security: i64, name: i64, flags: u32, access: u32) -> i64
priv extern "kernel32.dll" fn SetWaitableTimer(h: i64, due: *i64, period: i32, routine: i64, arg: i64, resume: i32) -> i32
priv extern "kernel32.dll" fn CreateFileMappingW(h: i64, security: i64, protect: u32, size_hi: u32, size_lo: u32, name: i64) -> i64
priv extern "kernel32.dll" fn MapViewOfFile(h: i64, access: u32, off_hi: u32, off_lo: u32, size: i64) -> i64
priv extern "kernel32.dll" fn UnmapViewOfFile(p: i64) -> i32

priv const INVALID_HANDLE = -1
priv const INFINITE: u32 = 0xFFFFFFFF
priv const WAIT_TIMEOUT: u32 = 0x102
// 1601-01-01 to 1970-01-01 in 100 ns units (FILETIME)
priv const EPOCH_FT = 116444736000000000

// ---------- errors ----------
// the Linux errno for a Windows error code (0x10000 + the code if there is none)
priv fn errno_of(e: u32) -> i64 {
    return match e {
        2, 3, 15, 53, 67, 161 => 2           // file, path, drive, network path or name not found
        4 => 24                              // too many open files
        5, 1920 => 13                        // access denied
        6 => 9                               // invalid handle
        8, 14, 1450, 1455 => 12              // not enough memory / commitment limit
        17 => 18                             // not the same device
        19 => 30                             // write protected
        21 => 19                             // device not ready
        23, 1117, 1392 => 5                  // CRC error, device I/O error, corrupt file
        32 => 16                             // sharing violation
        33 => 11                             // lock violation
        39, 112 => 28                        // disk full
        80, 183 => 17                        // file exists
        87, 123 => 22                        // invalid parameter, invalid name
        109, 232 => 32                       // broken pipe, pipe being closed
        145 => 39                            // directory not empty
        193, 216 => 8                        // not a valid executable
        206 => 36                            // file name too long
        267 => 20                            // not a directory
        995 => 4                             // operation aborted (Ctrl+C)
        1314 => 1                            // privilege not held
        1921 => 40                           // too many links to follow
        _ => 0x10000 + i64(e)
    }
}

// -errno of the last error
priv fn last_error() -> i64 {
    return -errno_of(GetLastError())
}

fn __os_error_text(e: i64) -> str {
    if e > 0x10000 && e <= 0x1FFFF {
        return fmt("windows error ", e - 0x10000)
    }
    return fmt("os error ", e)
}

// ---------- start, end, faults ----------
// Faults become the panics of the Linux signal handler. A vectored handler takes those in the
// program's own code (and stack overflow anywhere) before anything else sees them; a fault
// in a DLL is left to the DLL's own exception handlers, and reaches the unhandled exception
// filter (which walks the stack through AL frames by their unwind information) only if none
// of them takes it.
priv in_fault: bool
// the program's image: [image_lo, image_hi)
priv image_lo: i64
priv image_hi: i64

priv fn fault(info: i64, anywhere: bool) -> i32 {
    rec := cast[*i64](info)[0]
    code := cast[*u32](rec)[0]
    at := cast[*i64](rec)[2]
    mine := at >= image_lo && at < image_hi
    match code {
        0xC0000094, 0xC0000095, 0xC0000005, 0xC0000006 => {
            // integer division by zero / overflow, access violation, in-page error
            if !mine && !anywhere {
                return 0                     // EXCEPTION_CONTINUE_SEARCH
            }
        }
        0xC00000FD => {}                     // stack overflow
        _ => return 0
    }
    if in_fault {
        ExitProcess(1)
    }
    in_fault = true
    if code == 0xC0000094 || code == 0xC0000095 {
        __die("panic: arithmetic fault (division by zero or overflow)", "", "")
    }
    __die("panic: memory fault (nil dereference, stack overflow or use of released memory)", "", "")
}

priv fn on_exception(info: i64) -> i32 {
    return fault(info, false)
}

priv fn on_unhandled(info: i64) -> i32 {
    return fault(info, true)
}

// sp: what the loader passes (the PEB), not used
fn __rt_init(sp: i64) {
    // no error dialogs: SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX
    SetErrorMode(0x8003)
    // the image: e_lfanew at 0x3C, SizeOfImage at 24 + 56 after the PE signature
    image_lo = GetModuleHandleW(nil)
    pe := image_lo + i64(cast[*u32](image_lo + 0x3C)[0])
    image_hi = image_lo + i64(cast[*u32](pe + 80)[0])
    // room for the handler after a stack overflow
    g: u32 = 0x10000
    SetThreadStackGuarantee(&g)
    AddVectoredExceptionHandler(1, on_exception)
    SetUnhandledExceptionFilter(on_unhandled)
}

fn __os_exit(code: i64) -> never {
    ExitProcess(u32(code & 0xFF))
}

// ---------- text conversion ----------
// the code point at s[i..n] and its length in bytes (WTF-8: encoded surrogates are accepted);
// (0xFFFD, k) for k invalid bytes; (-1, 0) if a sequence is cut off by the end
priv fn utf8_at(s: *u8, i: i64, n: i64) -> (i64, i64) {
    c := i64(s[i])
    if c < 0x80 {
        return (c, 1)
    }
    need := 0
    cp := 0
    least := 0
    if c >= 0xC2 && c < 0xE0 {
        need = 1
        cp = c & 0x1F
        least = 0x80
    } else if c >= 0xE0 && c < 0xF0 {
        need = 2
        cp = c & 0x0F
        least = 0x800
    } else if c >= 0xF0 && c < 0xF5 {
        need = 3
        cp = c & 0x07
        least = 0x10000
    } else {
        return (0xFFFD, 1)
    }
    for k in 1..need + 1 {
        if i + k >= n {
            return (-1, 0)
        }
        d := i64(s[i + k])
        if d & 0xC0 != 0x80 {
            return (0xFFFD, k)
        }
        cp = (cp << 6) | (d & 0x3F)
    }
    if cp < least || cp > 0x10FFFF {
        return (0xFFFD, need + 1)
    }
    return (cp, need + 1)
}

// converts n bytes of UTF-8 at s to UTF-16 at out (room for n units): (units, bytes used).
// stream: stops before a sequence that is cut off by the end (else it becomes U+FFFD)
priv fn to_utf16(s: *u8, n: i64, out: *u16, stream: bool) -> (i64, i64) {
    i := 0
    k := 0
    while i < n {
        cp, l := utf8_at(s, i, n)
        if l == 0 {
            if stream {
                break
            }
            cp = 0xFFFD
            l = n - i
        }
        if cp >= 0x10000 {
            cp -= 0x10000
            out[k] = u16(0xD800 + (cp >> 10))
            out[k + 1] = u16(0xDC00 + (cp & 0x3FF))
            k += 2
        } else {
            out[k] = u16(cp)
            k += 1
        }
        i += l
    }
    return (k, i)
}

// appends the UTF-8 bytes of cp to out at k; returns the new k
priv fn put_utf8(out: *u8, k: i64, cp: i64) -> i64 {
    if cp < 0x80 {
        out[k] = u8(cp)
        return k + 1
    }
    if cp < 0x800 {
        out[k] = u8(0xC0 | (cp >> 6))
        out[k + 1] = u8(0x80 | (cp & 0x3F))
        return k + 2
    }
    if cp < 0x10000 {
        out[k] = u8(0xE0 | (cp >> 12))
        out[k + 1] = u8(0x80 | ((cp >> 6) & 0x3F))
        out[k + 2] = u8(0x80 | (cp & 0x3F))
        return k + 3
    }
    out[k] = u8(0xF0 | (cp >> 18))
    out[k + 1] = u8(0x80 | ((cp >> 12) & 0x3F))
    out[k + 2] = u8(0x80 | ((cp >> 6) & 0x3F))
    out[k + 3] = u8(0x80 | (cp & 0x3F))
    return k + 4
}

// the code point of the UTF-16 units at w[i..n] and how many units it takes
priv fn utf16_at(w: *u16, i: i64, n: i64) -> (i64, i64) {
    u := i64(w[i])
    if u >= 0xD800 && u < 0xDC00 && i + 1 < n {
        v := i64(w[i + 1])
        if v >= 0xDC00 && v < 0xE000 {
            return (0x10000 + ((u - 0xD800) << 10) + (v - 0xDC00), 2)
        }
    }
    return (u, 1)
}

// the UTF-8 text of n UTF-16 units (allocated)
priv fn narrow(w: *u16, n: i64) -> str {
    out := alloc[u8](3 * n)
    k := 0
    i := 0
    while i < n {
        cp, l := utf16_at(w, i, n)
        k = put_utf8(ptr(out), k, cp)
        i += l
    }
    return out[..k]
}

priv fn wcslen(w: *u16) -> i64 {
    n := 0
    while w[n] != 0 {
        n += 1
    }
    return n
}

// s as NUL-terminated UTF-16 (allocated)
priv fn wide(s: str) -> *u16 {
    out := alloc[u16](len(s) + 1)
    k, _ := to_utf16(ptr(s), len(s), ptr(out), false)
    out[k] = 0
    return ptr(out)
}

// the C string p as NUL-terminated UTF-16, in buf if it fits there, else allocated
priv fn wide_c(buf: []u16, p: *u8) -> *u16 {
    n := 0
    while p[n] != 0 {
        n += 1
    }
    out := if n < len(buf) { buf } else { alloc[u16](n + 1) }
    k, _ := to_utf16(p, n, ptr(out), false)
    out[k] = 0
    return ptr(out)
}

// ---------- standard handles, reading and writing ----------
// 0 / 1 / 2: the standard handles; anything else is a handle
priv fn handle(fd: i64) -> i64 {
    return match fd {
        0 => GetStdHandle(0xFFFFFFF6)
        1 => GetStdHandle(0xFFFFFFF5)
        2 => GetStdHandle(0xFFFFFFF4)
        _ => fd
    }
}

// whether standard handle fd (0..2) is a console: 0 not known yet, 1 yes, 2 no
priv con_kind: [3]i64

priv fn is_console(fd: i64, h: i64) -> bool {
    if fd < 0 || fd > 2 {
        return false
    }
    if con_kind[fd] == 0 {
        mode: u32
        con_kind[fd] = if GetConsoleMode(h, &mode) != 0 { 1 } else { 2 }
    }
    return con_kind[fd] == 1
}

// console output: UTF-8 is converted to UTF-16 for WriteConsoleW; the bytes of a character that
// is cut off at the end of a write wait for the next write (per handle: 1 and 2)
priv con_stage: [16400]u8
priv con_wide: [16400]u16
priv con_pend: [8]u8
priv con_pend_n: [2]i64

priv fn console_write(fd: i64, h: i64, p: i64, n: i64) -> i64 {
    slot := fd - 1
    while n > 0 {
        k := con_pend_n[slot]
        memcopy(ptr(con_stage), cast[i64](ptr(con_pend)) + 4 * slot, k)
        c := min(n, 16384)
        memcopy(cast[i64](ptr(con_stage)) + k, p, c)
        p += c
        n -= c
        units, used := to_utf16(ptr(con_stage), k + c, ptr(con_wide), true)
        con_pend_n[slot] = k + c - used
        memcopy(cast[i64](ptr(con_pend)) + 4 * slot, cast[i64](ptr(con_stage)) + used, k + c - used)
        off := 0
        while off < units {
            done: u32
            if WriteConsoleW(h, &con_wide[off], u32(min(units - off, 8192)), &done, 0) == 0 {
                return errno_of(GetLastError())
            }
            if done == 0 {
                return 5
            }
            off += i64(done)
        }
    }
    return 0
}

// writes n bytes at p to fd; returns 0 or the error number of the failed write
fn __write_all(fd: i64, p: i64, n: i64) -> i64 {
    h := handle(fd)
    if (fd == 1 || fd == 2) && is_console(fd, h) {
        return console_write(fd, h, p, n)
    }
    while n > 0 {
        done: u32
        if WriteFile(h, p, u32(min(n, 1 << 30)), &done, 0) == 0 {
            return errno_of(GetLastError())
        }
        if done == 0 {
            return 5
        }
        p += i64(done)
        n -= i64(done)
    }
    return 0
}

// console input: ReadConsoleW, converted to UTF-8 with "\r\n" as "\n"; Ctrl+Z at the start of
// a read is the end of the input
priv cin: [4096]u8
priv cin_pos: i64
priv cin_len: i64
priv cin_w: [1026]u16
priv cin_hi: u16

priv fn console_read(h: i64, p: i64, n: i64) -> i64 {
    while cin_pos == cin_len {
        start := 0
        if cin_hi != 0 {
            cin_w[0] = cin_hi
            cin_hi = 0
            start = 1
        }
        got: u32
        if ReadConsoleW(h, &cin_w[start], 1024, &got, 0) == 0 {
            return last_error()
        }
        total := start + i64(got)
        if got == 0 || cin_w[start] == 0x1A {
            return 0
        }
        // a high surrogate at the end waits for its other half
        if cin_w[total - 1] >= 0xD800 && cin_w[total - 1] < 0xDC00 {
            total -= 1
            cin_hi = cin_w[total]
        }
        k := 0
        i := 0
        while i < total {
            if cin_w[i] == 13 && i + 1 < total && cin_w[i + 1] == 10 {
                i += 1
                continue
            }
            cp, l := utf16_at(ptr(cin_w), i, total)
            k = put_utf8(ptr(cin), k, cp)
            i += l
        }
        cin_pos = 0
        cin_len = k
    }
    c := min(n, cin_len - cin_pos)
    memcopy(p, cast[i64](ptr(cin)) + cin_pos, c)
    cin_pos += c
    return c
}

// bytes read, 0 at the end (also of a pipe whose writer is gone), or -errno
fn __os_read(fd: i64, p: i64, n: i64) -> i64 {
    h := handle(fd)
    if fd == 0 && is_console(0, h) {
        return console_read(h, p, n)
    }
    got: u32
    if ReadFile(h, p, u32(min(n, 1 << 30)), &got, 0) == 0 {
        e := GetLastError()
        if e == 109 || e == 38 {
            return 0
        }
        return -errno_of(e)
    }
    return i64(got)
}

priv fn is_dir_w(w: *u16) -> bool {
    a := GetFileAttributesW(w)
    return a != 0xFFFFFFFF && a & 0x10 != 0
}

// opens a file for reading, or creates or empties it for writing: a handle or -errno
fn __os_open(path: *u8, write: bool) -> i64 {
    buf: [1024]u16
    w := wide_c(buf[..], path)
    // GENERIC_WRITE / GENERIC_READ, FILE_SHARE_READ | WRITE | DELETE, CREATE_ALWAYS / OPEN_EXISTING
    h := CreateFileW(w, if write { 0x40000000 } else { 0x80000000 }, 7, 0, if write { 2 } else { 3 }, 0x80, 0)
    if h == INVALID_HANDLE {
        e := GetLastError()
        // a directory cannot be opened as a file (Linux: EISDIR)
        if e == 5 && is_dir_w(w) {
            return -21
        }
        return -errno_of(e)
    }
    return h
}

fn __os_close(fd: i64) -> i64 {
    if CloseHandle(handle(fd)) == 0 {
        return last_error()
    }
    return 0
}

// (size, true) for a file on disk, (0, false) for a pipe or console, (-1, false) on failure
fn __os_fstat(fd: i64) -> (i64, bool) {
    h := handle(fd)
    if GetFileType(h) != 1 {
        return (if GetLastError() == 0 { 0 } else { -1 }, false)
    }
    size: i64
    if GetFileSizeEx(h, &size) == 0 {
        return (-1, false)
    }
    return (size, true)
}

// ---------- memory ----------
// An arena reserves its address space once and commits it in steps as it is used: the
// committed part ends at __heap_end; the rest of the reservation follows it.
noinline fn __heap_grow(n: i64) -> i64 {
    if n < 0 {
        __die("panic: out of memory", "", "")
    }
    if __heap_base == 0 {
        size := if __region_depth == 0 { 1 << 36 } else { 1 << 34 }
        while size >= (1 << 24) {
            p := VirtualAlloc(0, size, 0x2000, 1)          // MEM_RESERVE, PAGE_NOACCESS
            if p != 0 {
                __heap_base = p
                __heap_cur = p
                __heap_end = p
                break
            }
            size = size >> 1
        }
        if __heap_base == 0 {
            __die("panic: out of memory", "", "")
        }
    }
    // the reserved, uncommitted rest of the arena: MEMORY_BASIC_INFORMATION at __heap_end
    mbi: [6]i64
    rest := 0
    if VirtualQuery(__heap_end, &mbi[0], 48) == 48 && mbi[1] == __heap_base && mbi[4] & 0xFFFFFFFF == 0x2000 {
        rest = mbi[3]
    }
    need := n - (__heap_end - __heap_cur)
    if need > rest {
        __die("panic: out of memory", "", "")
    }
    // what is needed, plus as much again as the arena has (between 1 and 64 MiB)
    c := (need + 0xFFFF) & ~0xFFFF
    more := min(c + min(max(__heap_end - __heap_base, 1 << 20), 1 << 26), rest)
    if VirtualAlloc(__heap_end, more, 0x1000, 4) != 0 {      // MEM_COMMIT, PAGE_READWRITE
        __heap_end += more
    } else if VirtualAlloc(__heap_end, min(c, rest), 0x1000, 4) != 0 {
        __heap_end += min(c, rest)
    } else {
        __die("panic: out of memory", "", "")
    }
    p := __heap_cur
    __heap_cur = p + n
    return p
}

// n bytes of zeroed memory outside the arena: the address, or -errno
fn __os_map(n: i64) -> i64 {
    p := VirtualAlloc(0, n, 0x3000, 4)          // MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE
    return if p == 0 { last_error() } else { p }
}

// gives back memory of __os_map, of an arena or a view of a mapped file: 0 or -errno
fn __os_unmap(p: i64, n: i64) -> i64 {
    mbi: [6]i64
    if VirtualQuery(p, &mbi[0], 48) != 48 {
        return -22
    }
    ok := if (mbi[5] & 0xFFFFFFFF) == 0x40000 {
        UnmapViewOfFile(mbi[1])                       // MEM_MAPPED
    } else {
        VirtualFree(mbi[1], 0, 0x8000)                // MEM_RELEASE
    }
    return if ok == 0 { last_error() } else { 0 }
}

// ---------- processes ----------
// starts app with the command line cmd and the three standard handles: (process handle,
// process id), or (0, -errno)
priv fn create_process(app: *u16, cmd: *u16, hin: i64, hout: i64, herr: i64) -> (i64, i64) {
    // the child gets inheritable copies of the three handles
    me := GetCurrentProcess()
    src: [3]i64
    src[0] = hin
    src[1] = hout
    src[2] = herr
    dup: [3]i64
    for i in 0..3 {
        if src[i] != 0 && src[i] != INVALID_HANDLE {
            DuplicateHandle(me, src[i], me, &dup[i], 0, 1, 2)    // DUPLICATE_SAME_ACCESS
        }
    }
    // STARTUPINFOW (104 bytes): cb, ..., dwFlags = STARTF_USESTDHANDLES, ..., the handles
    si: [13]i64
    si[0] = 104
    si[7] = 0x100 << 32
    si[10] = dup[0]
    si[11] = dup[1]
    si[12] = dup[2]
    // PROCESS_INFORMATION: process, thread, process id, thread id
    pi: [3]i64
    ok := CreateProcessW(app, cmd, 0, 0, 1, 0, 0, 0, &si[0], &pi[0])
    e := GetLastError()
    for i in 0..3 {
        if dup[i] != 0 {
            CloseHandle(dup[i])
        }
    }
    if ok == 0 {
        return (0, -errno_of(e))
    }
    if pi[0] == 0 {
        // (Wine starts a Linux program without a Windows process)
        return (0, -8)
    }
    CloseHandle(pi[1])
    return (pi[0], pi[2] & 0xFFFFFFFF)
}

// the status of a process as on Linux: the low 8 bits of its exit code, or 128 + the signal
// that corresponds to the exception that ended it
priv fn status_of(code: u32) -> i64 {
    return match code {
        0xC0000005, 0xC00000FD => 139             // SIGSEGV
        0xC0000006 => 135                         // SIGBUS
        0xC0000094, 0xC0000095, 0xC000008E, 0xC0000090, 0xC0000091, 0xC0000093 => 136  // SIGFPE
        0xC000001D, 0xC0000096 => 132             // SIGILL
        0xC0000409 => 134                         // SIGABRT (fail fast)
        0xC000013A => 130                         // SIGINT (Ctrl+C)
        _ => i64(code & 0xFF)
    }
}

// which test of the program this process runs (env AL_TEST_ONE, set by the parent): -1 for
// the parent, -2 not looked at yet
priv test_one: i64 = -2
priv test_next: i64

// runs a test block in a new process of this program that runs only that block: 1 if it
// ended with status 0, 0 otherwise; -1 in such a process for the other blocks
fn __os_test(f: fn()) -> i64 {
    if test_one == -2 {
        v, set := env_get("AL_TEST_ONE")
        k, ok := parse_i64(v)
        test_one = if set && ok { k } else { -1 }
    }
    k := test_next
    test_next += 1
    if test_one >= 0 {
        if k == test_one {
            f()
            exit(0)
        }
        return -1
    }
    m := mark()
    defer { release(m) }
    exe := alloc[u16](32768)
    if GetModuleFileNameW(0, ptr(exe), 32768) == 0 {
        return 0
    }
    name := wide("AL_TEST_ONE")
    SetEnvironmentVariableW(name, wide(fmt(k)))
    // (CreateProcessW may write into the command line)
    line := GetCommandLineW()
    cmd := alloc[u16](wcslen(line) + 1)
    memcopy(ptr(cmd), line, 2 * wcslen(line))
    h, _ := create_process(ptr(exe), ptr(cmd), handle(0), handle(1), handle(2))
    SetEnvironmentVariableW(name, nil)
    if h == 0 {
        return 0
    }
    WaitForSingleObject(h, INFINITE)
    code: u32 = 1
    GetExitCodeProcess(h, &code)
    CloseHandle(h)
    return if code == 0 { 1 } else { 0 }
}

// ---------- time, arguments, environment ----------
priv qpc_freq: i64

fn clock_ns() -> i64 {
    if qpc_freq == 0 {
        f: i64
        QueryPerformanceFrequency(&f)
        qpc_freq = f
    }
    c: i64
    QueryPerformanceCounter(&c)
    return c / qpc_freq * 1000000000 + c % qpc_freq * 1000000000 / qpc_freq
}

// command line arguments (args()[0] is the program name): GetCommandLineW split by the rules
// of the Microsoft C run-time library
fn args() -> []str {
    line := GetCommandLineW()
    n := wcslen(line)
    out := vec[str]()
    buf := alloc[u16](n + 1)
    i := 0
    k := 0
    // the program name: up to the next quote if it starts with one, else up to white space
    if n > 0 && line[0] == 34 {
        i = 1
        while i < n && line[i] != 34 {
            buf[k] = line[i]
            k += 1
            i += 1
        }
        if i < n {
            i += 1
        }
    } else {
        while i < n && line[i] != 32 && line[i] != 9 {
            buf[k] = line[i]
            k += 1
            i += 1
        }
    }
    out.push(narrow(ptr(buf), k))
    loop {
        while i < n && (line[i] == 32 || line[i] == 9) {
            i += 1
        }
        if i >= n {
            break
        }
        k = 0
        quoted := false
        while i < n {
            c := line[i]
            if (c == 32 || c == 9) && !quoted {
                break
            }
            if c == 92 {
                // backslashes: 2n + 1 before a quote are n and a literal quote, 2n before a
                // quote are n (the quote counts as one), otherwise they are literal
                b := 0
                while i < n && line[i] == 92 {
                    b += 1
                    i += 1
                }
                lit := if i < n && line[i] == 34 { b / 2 } else { b }
                for _ in 0..lit {
                    buf[k] = 92
                    k += 1
                }
                if i < n && line[i] == 34 && b % 2 == 1 {
                    buf[k] = 34
                    k += 1
                    i += 1
                }
                continue
            }
            if c == 34 {
                if quoted && i + 1 < n && line[i + 1] == 34 {
                    // "" inside quotes: a quote
                    buf[k] = 34
                    k += 1
                    i += 2
                    continue
                }
                quoted = !quoted
                i += 1
                continue
            }
            buf[k] = c
            k += 1
            i += 1
        }
        out.push(narrow(ptr(buf), k))
    }
    return out.items()
}

// the value of an environment variable; ("", false) if it is not set (names are compared
// without regard to case, as Windows does)
fn env_get(name: str) -> (str, bool) {
    if len(name) == 0 || index_of(name, '=') >= 0 || index_of(name, 0) >= 0 {
        return ("", false)
    }
    w := wide(name)
    size := 256
    loop {
        buf := alloc[u16](size)
        SetLastError(0)
        r := i64(GetEnvironmentVariableW(w, ptr(buf), u32(size)))
        if r == 0 {
            // (0 is also the length of an empty value)
            return ("", GetLastError() != 203)
        }
        if r < size {
            return (narrow(ptr(buf), r), true)
        }
        size = r
    }
}

// ---------- std.asset: files, directories, paths ----------
// Paths are NUL-terminated UTF-8; `/` and `\` both separate components.
inline fn __os_is_sep(c: u8) -> bool {
    return c == '/' || c == '\\'
}

// the length of the root at the start of p: "C:\" 3, "C:" 2 (relative to the drive's working
// directory), "\\server\share\" its length, "\" 1, else 0
fn __os_path_root(p: str) -> i64 {
    n := len(p)
    if n >= 2 && is_alpha(p[0]) && p[1] == ':' {
        return if n >= 3 && __os_is_sep(p[2]) { 3 } else { 2 }
    }
    if n >= 2 && __os_is_sep(p[0]) && __os_is_sep(p[1]) {
        i := 2
        while i < n && !__os_is_sep(p[i]) {
            i += 1
        }
        if i < n {
            i += 1
            while i < n && !__os_is_sep(p[i]) {
                i += 1
            }
            if i < n {
                i += 1
            }
        }
        return i
    }
    return if n >= 1 && __os_is_sep(p[0]) { 1 } else { 0 }
}

// nanoseconds since 1970 of the FILETIME at d[at] (u32 units)
priv fn ft_ns(d: *u32, at: i64) -> i64 {
    ft := i64(d[at]) | (i64(d[at + 1]) << 32)
    return (ft - EPOCH_FT) * 100
}

// (kind, size, modification time in ns since 1970) of what path names, following links; kind
// is 1 for a file, 2 for a directory, 0 for a device, -1 if there is nothing
fn __os_stat(path: *u8) -> (i64, i64, i64) {
    buf: [4096]u16
    w := wide_c(buf[..], path)
    // WIN32_FILE_ATTRIBUTE_DATA: attributes, 3 FILETIMEs (creation, access, write), size high, low
    d: [13]u32
    if GetFileAttributesExW(w, 0, &d[0]) == 0 {
        return (-1, 0, 0)
    }
    attrs := d[0]
    mtime := ft_ns(&d[0], 5)
    size := (i64(d[7]) << 32) | i64(d[8])
    if attrs & 0x400 != 0 {
        // a link: what it points to (BY_HANDLE_FILE_INFORMATION: attributes, 3 FILETIMEs,
        // volume, size high, low, ...)
        h := CreateFileW(w, 0, 7, 0, 3, 0x02000000, 0)     // FILE_FLAG_BACKUP_SEMANTICS
        if h == INVALID_HANDLE {
            return (-1, 0, 0)
        }
        ok := GetFileInformationByHandle(h, &d[0])
        CloseHandle(h)
        if ok == 0 {
            return (-1, 0, 0)
        }
        attrs = d[0]
        mtime = ft_ns(&d[0], 5)
        size = (i64(d[8]) << 32) | i64(d[9])
    }
    kind := if attrs & 0x10 != 0 { 2 } else if attrs & 0x40 != 0 { 0 } else { 1 }
    return (kind, size, mtime)
}

fn __os_remove_file(path: *u8) -> i64 {
    buf: [4096]u16
    w := wide_c(buf[..], path)
    if DeleteFileW(w) == 0 {
        e := GetLastError()
        if e == 5 && is_dir_w(w) {
            return -21
        }
        return -errno_of(e)
    }
    return 0
}

fn __os_remove_dir(path: *u8) -> i64 {
    buf: [4096]u16
    if RemoveDirectoryW(wide_c(buf[..], path)) == 0 {
        return last_error()
    }
    return 0
}

fn __os_make_dir(path: *u8) -> i64 {
    buf: [4096]u16
    if CreateDirectoryW(wide_c(buf[..], path), 0) == 0 {
        return last_error()
    }
    return 0
}

fn __os_rename(from: *u8, to: *u8) -> i64 {
    a: [4096]u16
    b: [4096]u16
    if MoveFileExW(wide_c(a[..], from), wide_c(b[..], to), 1) == 0 {      // MOVEFILE_REPLACE_EXISTING
        return last_error()
    }
    return 0
}

// appends the names of the entries of a directory except "." and ".." to names
fn __os_list_dir(path: *u8, names: *Vec[str]) -> i64 {
    if path[0] == 0 {
        return -2
    }
    buf: [4100]u16
    w := wide_c(buf[..4096], path)
    // the pattern dir\*
    n := wcslen(w)
    pat := if n + 3 <= len(buf) { buf[..] } else { alloc[u16](n + 3) }
    if ptr(pat) != w {
        memcopy(ptr(pat), w, 2 * n)
    }
    if n > 0 && pat[n - 1] != 47 && pat[n - 1] != 92 && !(n == 2 && pat[1] == 58) {
        pat[n] = 92
        n += 1
    }
    pat[n] = 42
    pat[n + 1] = 0
    // WIN32_FIND_DATAW (592 bytes): attributes, 3 FILETIMEs, size, 2 reserved, the name at 44
    fd: [148]u32
    h := FindFirstFileW(ptr(pat), &fd[0])
    if h == INVALID_HANDLE {
        e := GetLastError()
        // no entry at all (only possible in a drive's root directory)
        if e == 2 && is_dir_w(w) {
            return 0
        }
        return -errno_of(e)
    }
    loop {
        np := cast[*u16](cast[i64](ptr(fd)) + 44)
        name := narrow(np, wcslen(np))
        if name != "." && name != ".." {
            names.push(name)
        }
        if FindNextFileW(h, &fd[0]) == 0 {
            break
        }
    }
    FindClose(h)
    return 0
}

// ---------- std.time ----------
// seconds since 1970-01-01 UTC
fn __os_wall_time() -> i64 {
    ft: i64
    GetSystemTimeAsFileTime(&ft)
    return (ft - EPOCH_FT) / 10000000
}

// a waitable timer for sleeping (high resolution where the system has it); -1: none
priv sleep_timer: i64

fn __os_sleep_ns(ns: i64) {
    if sleep_timer == 0 {
        // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS
        t := CreateWaitableTimerExW(0, 0, 2, 0x1F0003)
        if t == 0 {
            t = CreateWaitableTimerExW(0, 0, 0, 0x1F0003)
        }
        sleep_timer = if t == 0 { -1 } else { t }
    }
    if sleep_timer > 0 {
        // relative time: negative, in 100 ns units
        due := -(ns / 100 + if ns % 100 != 0 { 1 } else { 0 })
        if SetWaitableTimer(sleep_timer, &due, 0, 0, 0, 0) != 0 {
            WaitForSingleObject(sleep_timer, INFINITE)
            return
        }
    }
    ms := ns / 1000000 + if ns % 1000000 != 0 { 1 } else { 0 }
    while ms > 0 {
        k := min(ms, 0x7FFFFFFF)
        Sleep(u32(k))
        ms -= k
    }
}

// ---------- std.os: processes ----------
// the file to execute for `name`: the name itself if it has a separator or a drive, else the
// first file of that name in the directories of PATH; ".exe" is tried after the name if it
// has no extension. ("", error number) if there is none.
priv fn locate(name: str) -> (str, i64) {
    if len(name) == 0 {
        return ("", 2)
    }
    base := len(name)
    while base > 0 && !__os_is_sep(name[base - 1]) && name[base - 1] != ':' {
        base -= 1
    }
    cands := vec[str]()
    cands.push(name)
    if index_of(name[base..], '.') < 0 {
        cands.push(concat(name, ".exe"))
    }
    if base > 0 {
        for c in cands {
            kind, _, _ := __os_stat(cstr(c))
            if kind == 1 {
                return (c, 0)
            }
        }
        return ("", 2)
    }
    path, _ := env_get("PATH")
    for dir in split(path, ';') {
        if len(dir) == 0 {
            continue
        }
        for c in cands {
            file := if __os_is_sep(dir[len(dir) - 1]) { concat(dir, c) } else { fmt(dir, "\\", c) }
            kind, _, _ := __os_stat(cstr(file))
            if kind == 1 {
                return (file, 0)
            }
        }
    }
    return ("", 2)
}

// appends a as one argument of a command line, quoted so that the Microsoft rules (`args`)
// give it back unchanged
priv fn quote_arg(out: *Vec[u8], a: str) {
    plain := len(a) > 0
    for c in a {
        if c == ' ' || c == '\t' || c == '\n' || c == 0x0B || c == '"' {
            plain = false
        }
    }
    if plain {
        out.extend(a)
        return
    }
    out.push('"')
    b := 0
    for c in a {
        if c == '\\' {
            b += 1
            continue
        }
        if c == '"' {
            for _ in 0..2 * b + 1 {
                out.push('\\')
            }
        } else {
            for _ in 0..b {
                out.push('\\')
            }
        }
        out.push(c)
        b = 0
    }
    for _ in 0..2 * b {
        out.push('\\')
    }
    out.push('"')
}

// Starts argv; capture: 0 nothing, 1 standard output, 2 standard output and standard error go to
// a pipe. Returns (process id, process handle, read end of the pipe or -1) once the program
// runs, (-1, -1, -1) if it could not be started (io_error()).
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
    // the program name has no escapes: quotes around it if it has white space
    line := vec[u8]()
    if find(argv[0], " ") >= 0 || find(argv[0], "\t") >= 0 {
        line.push('"')
        line.extend(argv[0])
        line.push('"')
    } else {
        line.extend(argv[0])
    }
    for a in argv[1..] {
        line.push(' ')
        quote_arg(&line, a)
    }
    pipe_r := -1
    pipe_w := 0
    if capture != 0 {
        r: i64
        w: i64
        if CreatePipe(&r, &w, 0, 0) == 0 {
            __io_result(last_error())
            return (-1, -1, -1)
        }
        pipe_r = r
        pipe_w = w
    }
    flush()
    hout := if capture != 0 { pipe_w } else { handle(1) }
    herr := if capture == 2 { pipe_w } else { handle(2) }
    h, pid := create_process(wide(file), wide(line.items()), handle(0), hout, herr)
    if capture != 0 {
        CloseHandle(pipe_w)
    }
    if h == 0 {
        if pipe_r >= 0 {
            CloseHandle(pipe_r)
        }
        __io_result(pid)
        return (-1, -1, -1)
    }
    __io_result(0)
    return (pid, h, pipe_r)
}

// Waits for a process of __os_spawn (block) or looks whether it has ended: its status, -2 if
// it still runs (only without block), -1 if it cannot be waited for (io_error()). After a
// status the handle is closed.
fn __os_wait(pid: i64, handle: i64, block: bool) -> i64 {
    r := WaitForSingleObject(handle, if block { INFINITE } else { 0 })
    if r == WAIT_TIMEOUT {
        return -2
    }
    if r != 0 {
        __io_result(last_error())
        return -1
    }
    code: u32
    if GetExitCodeProcess(handle, &code) == 0 {
        __io_result(last_error())
        return -1
    }
    CloseHandle(handle)
    __io_result(0)
    return status_of(code)
}

// "sends a signal": 0 only checks the process; any other ends it with the exit code
// 128 + signal (the status of a Linux process ended by that signal). 0 or -errno
fn __os_kill(pid: i64, handle: i64, signal: i64) -> i64 {
    if signal < 0 || signal > 64 {
        return -22
    }
    if signal == 0 {
        return 0
    }
    if TerminateProcess(handle, u32(128 + signal)) == 0 {
        // a process that has ended already takes signals without effect
        if WaitForSingleObject(handle, 0) == 0 {
            return 0
        }
        return last_error()
    }
    return 0
}

// ---------- std.os: shared memory, this process ----------
// a file mapping object of `size` bytes in the paging file (not inherited): a handle or -errno
fn __os_shm_create(size: i64) -> i64 {
    if size < 0 {
        return -22
    }
    // PAGE_READWRITE
    h := CreateFileMappingW(INVALID_HANDLE, 0, 4, u32(size >> 32), u32(size & 0xFFFFFFFF), 0)
    if h == 0 {
        return last_error()
    }
    return h
}

// maps the first `size` bytes of a file mapping object (or of a file) fd: shared and writable,
// or read-only; the address, or -errno
fn __os_map_fd(fd: i64, size: i64, write: bool) -> i64 {
    h := handle(fd)
    access: u32 = if write { 6 } else { 4 }            // FILE_MAP_WRITE | FILE_MAP_READ, FILE_MAP_READ
    p := MapViewOfFile(h, access, 0, 0, size)
    if p != 0 {
        return p
    }
    e := GetLastError()
    if e != 6 {
        return -errno_of(e)
    }
    // a file: map it through a mapping object of its own (PAGE_READWRITE / PAGE_READONLY)
    m := CreateFileMappingW(h, 0, if write { 4 } else { 2 }, u32(size >> 32), u32(size & 0xFFFFFFFF), 0)
    if m == 0 {
        return last_error()
    }
    p = MapViewOfFile(m, access, 0, 0, size)
    e = GetLastError()
    CloseHandle(m)
    if p == 0 {
        return -errno_of(e)
    }
    return p
}

fn __os_process_id() -> i64 {
    return i64(GetCurrentProcessId())
}

// the working directory ("" if it cannot be told: see io_error())
fn __os_current_dir() -> str {
    n := i64(GetCurrentDirectoryW(0, nil))
    if n == 0 {
        __io_result(last_error())
        return ""
    }
    buf := alloc[u16](n + 1)
    k := i64(GetCurrentDirectoryW(u32(n + 1), ptr(buf)))
    if k == 0 || k > n {
        __io_result(last_error())
        return ""
    }
    __io_result(0)
    return narrow(ptr(buf), k)
}
