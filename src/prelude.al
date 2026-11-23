// AL runtime prelude. Compiled together with every program.
//
// Everything that depends on the operating system is in the OS layer of the target, compiled
// right after this file: src/prelude_linux.al (system calls) or src/prelude_windows.al
// (kernel32.dll). Each layer defines the same functions:
//   __rt_init(sp)                  called first by the generated entry point
//   __os_exit(code) -> never       ends the process (output is flushed by the callers)
//   __os_panic(kind, loc, msg)     after a panic message was written to standard error (Windows
//                                  GUI programs: a message box)
//   __write_all(fd, p, n) -> errno writes everything (fd 1 / 2: standard output / error)
//   __os_read(fd, p, n)            bytes read, 0 at the end, or -errno
//   __os_open(path, write)         a descriptor or -errno (path: NUL-terminated)
//   __os_close(fd), __os_fstat(fd) -> (size, is a regular file)
//   __heap_grow(n)                 the slow path of the arena allocator (see below)
//   __os_map(n), __os_unmap(p, n)  memory outside the arena (address or -errno; 0 or -errno)
//   __os_test(f) -> 1 / 0 / -1     runs one `test` block in a process of its own: passed,
//                                  failed, or not run by this process
//   __os_error_text(e)             error_text for numbers it does not know
//   __os_stack_range() -> (lo, hi) the stack of the running thread, for stack traces
//   __os_backtrace_off() -> bool   ALC_BACKTRACE=0 is set (without allocating)
//   __os_check_memory() -> bool    ALC_CHECK_MEMORY is set and not 0 (without allocating)
//   __os_page_off(p, n)            takes the pages [p, p + n) of an arena away: an access faults
//   __os_bt_foreign, __os_bt_unwind, __os_bt_where, __BT_SAVED
//                                  stack traces through C libraries (see __bt_c_init)
//   __os_thread_create(c) -> errno starts a thread that calls __thread_main(c); 0 or -errno
//   __os_thread_join(c)            waits until it has ended and frees what the layer made
//   __os_thread_setup(), __os_thread_cleanup()
//                                  in a new thread first (stack bounds, signal stack) / last
//   __os_lock(p), __os_unlock(p), __os_try_lock(p) -> bool
//                                  a lock in the 8 bytes at p (zero: unlocked)
//   __os_cond_wait(c, m, ns) -> bool, __os_cond_wake(c, all)
//                                  a condition variable in the 8 bytes at c (zero: usable);
//                                  ns < 0: no time limit; false: timed out
//   __os_park() -> never           waits forever (a thread while another one panics)
//   __os_cpu_count()               the CPUs the process may use
//   clock_ns, args, env_get        the public functions of that name
// plus the __os_* functions used by std.asset, std.time and std.os. Error numbers are
// Linux errno values on every target (the Windows layer maps its error codes to them).
//
// Threads: every thread has its own copy of the globals named __tls_*, __heap_* and
// __region_* (thread-local, always zero at the start of a thread; the compiler puts them in
// the thread block of each thread: see layout_tls in src/objwrite.al), so each thread
// allocates from its own arena and has its own region stack, output buffer, io_error and
// stack bounds. A thread that a C library created starts with all of them zero: it gets an
// id, an arena and an output buffer when it first needs them. The other globals are shared:
// read-only after the start, or protected by the output lock or the panic lock (see below).

__heap_cur: i64
__heap_end: i64
__heap_base: i64
__heap_hwm: i64
__tests_failed: i64

// this thread's id + 1 (0: not known yet, a thread a C library created; see __thread_key)
__tls_id: i64
// the next id + 1 to hand out (the main thread has id 0)
__thread_next: i64

// ---------- process ----------
// ends the program with exit status `code` (standard output is flushed first)
fn exit(code: i64) -> never {
    flush()
    __os_exit(code)
}

// standard output that cannot be written stops the program (a closed pipe normally ends it
// before, with SIGPIPE)
noinline fn __out_write(p: i64, n: i64) {
    e := __write_all(1, p, n)
    if e != 0 {
        __tls_olen = 0
        __out_len = 0
        __die("panic: cannot write to standard output: ", error_text(e), "")
    }
}

fn __err(s: str) {
    __write_all(2, cast[i64](ptr(s)), len(s))
}

// A panic ends the process (exit status 1) after its message and the stack trace of the
// thread that panicked. Only one thread reports: the first to take the panic lock; another
// thread that panics (or faults) meanwhile waits for the end. In the main thread the message
// is as it always was, in another one it names the thread: "panic in thread 3: ...",
// "assertion failed in thread 3 at ...".
fn __die(kind: str, loc: str, msg: str) -> never {
    __panic_enter()
    __out_panic()
    id := __thread_id()
    if id == 0 {
        __err(kind)
    } else {
        k := if starts_with(kind, "assertion failed") { 16 } else if starts_with(kind, "panic") { 5 } else { 0 }
        __err(kind[..k])
        __err(" in thread ")
        b: [24]u8
        i := 24
        x := id
        loop {
            i -= 1
            b[i] = u8(x % 10) + '0'
            x = x / 10
            if x == 0 {
                break
            }
        }
        __err(b[i..24])
        __err(kind[k..])
    }
    __err(loc)
    if len(msg) > 0 {
        __err(": ")
        __err(msg)
    }
    __err("\n")
    __bt_print()
    __os_panic(kind, loc, msg)
    __os_exit(1)
}

// the thread that holds the panic lock: its id + 1, 0 if none
__panic_owner: i64

// takes the panic lock, or waits forever if another thread holds it (the process is ending);
// returns at once in the thread that holds it (a panic while a panic is reported)
fn __panic_enter() {
    me := __thread_key()
    prev, ok := atomic_cas(&__panic_owner, 0, me)
    if !ok && prev != me {
        __os_park()
    }
}

noinline fn __bounds_fail(loc: str) -> never {
    __die("panic: index out of bounds at ", loc, "")
}

noinline fn __div_fail(loc: str) -> never {
    __die("panic: division by zero at ", loc, "")
}

noinline fn __step_fail(loc: str) -> never {
    __die("panic: loop step must be positive at ", loc, "")
}

noinline fn __assert_fail(loc: str, msg: str) -> never {
    __die("assertion failed at ", loc, if msg == "assertion failed" { "" } else { msg })
}

noinline fn __panic(loc: str, msg: str) -> never {
    __die("panic at ", loc, msg)
}

// ---------- stack traces ----------
// After the message of a panic __bt_print writes the call stack, innermost frame first, one
// line per function: "  at FILE:LINE in NAME" ("  at ? in NAME" where the line is unknown), a
// frame of C code as "  at LIBRARY SYMBOL" ("  at LIBRARY+0xOFFSET" without a symbol).
// Code inlined into a function shows as the frames it came from. The frames of the library
// before the first frame of the program and after its last one (the start of the program, the
// test runner) are left out, and so are frames of C code after it; a run of more than 7 library
// frames between frames of the program shows its first 4 and last 3 around "  ... N more frames
// in the library"; a trace of more than 25 lines its first 20 and last 5 around "  ... N more".
// ALC_BACKTRACE=0 in the environment turns it off.
//
// The compiler adds a table to every executable (its layout: src/backtrace.al) and stores its
// address in __bt_table. A frame is found from the return address its callee pushed: the table
// gives the function that contains the address, the size of its frame (the code keeps the stack
// pointer fixed after the prologue) and the source location of the call. Every step is checked
// (the address must be in a function, the frame inside the stack and above the previous one),
// so a corrupted stack ends the trace early instead of crashing or looping. A return address in
// a C library is a frame the OS layer unwinds (__os_bt_unwind: DWARF call frame information on
// Linux, RtlVirtualUnwind on Windows); C code may keep its frames through any callee-saved
// register, so the walk follows them too: the values a frame of the program pushed in its
// prologue are its caller's. That part of the walk is reached through function values that
// __bt_c_init sets, which the entry point calls only in a program that declares C functions:
// other programs, where no C code can run, do not contain it.
__bt_table: i64
// set by the fault handlers of the OS layers before they call __die: the faulting instruction
// and the registers there (see __BtRegs; r11 counts the pages of a Windows stack probe); pc 0:
// no fault
__bt_fault_pc: i64
__bt_fault_regs: __BtRegs
// a trace is being written (a fault now is a fault of the walk itself)
__bt_busy: bool

// the registers of a frame of the walk, by x86 number (rax 0, rcx 1, rdx 2, rbx 3, rsp 4, rbp
// 5, rsi 6, rdi 7, r8-r15 8-15); bit k of `known`: r[k] is known
struct __BtRegs {
    r: [16]i64
    known: i64
}

// the OS layer's functions for frames of C code (nil: no C code can run)
priv bt_c_foreign: fn(i64) -> bool
priv bt_c_unwind: fn(i64, bool, *__BtRegs, i64) -> i64
priv bt_c_where: fn(i64) -> (str, str, i64)

fn __bt_c_init() {
    bt_c_foreign = __os_bt_foreign
    bt_c_unwind = __os_bt_unwind
    bt_c_where = __os_bt_where
}

// is pc in the code of a C library?
priv fn bt_foreign(pc: i64) -> bool {
    return cast[i64](bt_c_foreign) != 0 && bt_c_foreign(pc)
}

priv struct BtWalk {
    base: i64 // the address of the first function
    nfuncs: i64
    funcs: i64 // addresses of the parts of the table
    nscopes: i64
    scopes: i64
    data: i64
    data_end: i64
    strs: i64
    lo: i64 // the stack: [lo, hi)
    hi: i64
    // the frame: its function (-1: C code), an address in it, the stack pointer there
    f: i64
    pc: i64
    sp: i64
    fault: bool // pc is the faulting instruction (else a return address)
    g: __BtRegs // the registers there (r[4] is set from sp when it is used)
    // the last location found (for deep recursion: the same address again and again)
    memo_pc: i64
    memo_loc: i64
}

// the lines of the trace (two passes: counting, then writing): library frames held back, the
// number of lines so far
priv struct BtOut {
    print: bool
    total: i64
    n: i64
    started: bool
    // a run of library lines after a line of the program: the first 4, the last 3, how many
    head: [4]i64
    tail: [3]i64
    run: i64
    // the lines of the walk so far; lines of C code after line `last` are left out (writing
    // pass); the last line of the program and n after it (counting pass)
    raw: i64
    last: i64
    prog: i64
    n_prog: i64
}

// a line of the trace: inlined location k of function f as 1 + f * 2^32 + k; a line of
// function f itself as -1 - (f * 2^32 + line) (line 0: unknown); BT_C + address: a frame of C
// code (the faulting instruction or the last byte of the call); BT_LIB_MORE + N: "N more
// frames in the library"
priv const BT_C = 1 << 61
priv const BT_LIB_MORE = 1 << 62
// the size of a function's entry in the table
priv const BT_FN = 24

priv fn bt_u32(a: i64) -> i64 {
    return i64(cast[*u32](a)[0])
}

priv fn bt_u8(a: i64) -> i64 {
    return i64(cast[*u8](a)[0])
}

priv fn bt_uleb(p0: i64) -> (i64, i64) {
    p := p0
    x := 0
    s := 0
    loop {
        b := bt_u8(p)
        p += 1
        x |= (b & 0x7F) << s
        s += 7
        if b < 0x80 || s > 56 {
            return (x, p)
        }
    }
}

// the function that contains address pc, or -1
priv fn bt_find(w: *BtWalk, pc: i64) -> i64 {
    if w.nfuncs == 0 {
        return -1
    }
    lo := 0
    hi := w.nfuncs
    while hi - lo > 1 {
        mid := (lo + hi) / 2
        if w.base + bt_u32(w.funcs + BT_FN * mid) <= pc {
            lo = mid
        } else {
            hi = mid
        }
    }
    start := w.base + bt_u32(w.funcs + BT_FN * lo)
    if pc < start || pc >= start + bt_u32(w.funcs + BT_FN * lo + 4) {
        return -1
    }
    return lo
}

// the bytes between the stack pointer of the frame and its return address (-1 if unknown) and
// how many registers the prologue has pushed. The prologue pushes registers (1 or 2 bytes
// each), then allocates (Windows: a probe for a page or more, see stack_probe in
// src/x86/emit.al); only a faulting instruction can be inside it.
priv fn bt_frame_bytes(w: *BtWalk) -> (i64, i64) {
    rec := w.funcs + BT_FN * w.f
    start := w.base + bt_u32(rec)
    alloc := bt_u32(rec + 12)
    npush := bt_u8(rec + 16)
    push_end := bt_u8(rec + 17)
    alloc_end := bt_u8(rec + 18)
    if !w.fault {
        return (8 * npush + alloc, npush)
    }
    off := w.pc - start
    if off < push_end {
        n := 0
        i := 0
        while i < off {
            i += if bt_u8(start + i) == 0x41 { 2 } else { 1 }
            n += 1
        }
        return (8 * n, n)
    }
    if off < alloc_end {
        pages := alloc / 4096
        r11 := w.g.r[11]
        if off == push_end + 13 && r11 >= 1 && r11 <= pages {
            // `test [rsp], rsp` in the loop: r11 pages were left before this one
            return (8 * npush + (pages - r11 + 1) * 4096, npush)
        }
        if off == alloc_end - 4 {
            return (8 * npush + alloc, npush)
        }
        return (-1, 0)
    }
    return (8 * npush + alloc, npush)
}

// the registers that the first n pushes of function f's prologue saved below its return address
// at `at`: the values of its caller
priv noinline fn bt_saved(w: *BtWalk, f: i64, at: i64, n: i64) {
    p := w.base + bt_u32(w.funcs + BT_FN * f)
    for k in 0..n {
        r := 0
        if bt_u8(p) == 0x41 {
            r = 8
            p += 1
        }
        b := bt_u8(p) - 0x50
        if b < 0 || b > 7 {
            return
        }
        w.g.r[r + b] = cast[*i64](at - 8 * (k + 1))[0]
        w.g.known |= 1 << (r + b)
        p += 1
    }
}

// to the caller's frame; false at the end of the stack or where a step cannot be trusted
priv fn bt_step(w: *BtWalk) -> bool {
    ra := 0
    sp := 0
    if w.f >= 0 {
        d, n := bt_frame_bytes(w)
        if d < 0 {
            return false
        }
        at := w.sp + d
        if at < w.sp || at % 8 != 0 || at + 8 > w.hi {
            return false
        }
        bt_saved(w, w.f, at, n)
        w.g.known &= __BT_SAVED
        ra = cast[*i64](at)[0]
        sp = at + 8
    } else {
        w.g.r[4] = w.sp
        w.g.known |= 16
        ra = bt_c_unwind(w.pc, w.fault, &w.g, w.hi)
        sp = w.g.r[4]
        if ra == 0 || sp <= w.sp || sp % 8 != 0 || sp > w.hi {
            return false
        }
    }
    f := bt_find(w, ra)
    if f < 0 && !bt_foreign(ra) {
        return false
    }
    w.f = f
    w.pc = ra
    w.sp = sp
    w.fault = false
    return true
}

// the line data of function f: (where its inlined locations start, how many, the end)
priv fn bt_data(w: *BtWalk, f: i64) -> (i64, i64, i64) {
    rec := w.funcs + BT_FN * f
    p := w.data + bt_u32(rec + 20)
    end := if f + 1 < w.nfuncs { w.data + bt_u32(rec + BT_FN + 20) } else { w.data_end }
    n, q := bt_uleb(p)
    return (q, n, end)
}

// inlined location k of function f: (scope, line, location of its call); (-1, 0, 0) if none
priv fn bt_inlined(w: *BtWalk, f: i64, k: i64) -> (i64, i64, i64) {
    p, n, _ := bt_data(w, f)
    if k < 0 || k >= n {
        return (-1, 0, 0)
    }
    s := 0
    line := 0
    at := 0
    for i in 0..=k {
        s, p = bt_uleb(p)
        line, p = bt_uleb(p)
        at, p = bt_uleb(p)
    }
    return (s, line, at)
}

// the location (see src/backtrace.al) of the frame's address; a line of the function itself
// as 2 * line (0: unknown)
priv fn bt_loc(w: *BtWalk) -> i64 {
    if w.pc == w.memo_pc {
        return w.memo_loc
    }
    // a return address is right after the call
    q := w.pc - (w.base + bt_u32(w.funcs + BT_FN * w.f)) - (if w.fault { 0 } else { 1 })
    p, n, end := bt_data(w, w.f)
    x := 0
    for i in 0..3 * n {
        x, p = bt_uleb(p)
    }
    off := 0
    line := 0
    loc := 0
    while p < end {
        d := 0
        v := 0
        d, p = bt_uleb(p)
        v, p = bt_uleb(p)
        off += d
        if off > q {
            break
        }
        if v % 2 == 0 {
            z := v / 2
            line += (z >> 1) ^ -(z & 1)
            loc = 2 * line
        } else {
            loc = v
        }
    }
    if loc < 0 || loc % 2 == 1 && loc / 2 >= n {
        loc = 0
    }
    w.memo_pc = w.pc
    w.memo_loc = loc
    return loc
}

// the scope of line `id` and its line number
priv fn bt_scope(w: *BtWalk, id: i64) -> (i64, i64) {
    if id > 0 {
        x := id - 1
        s, line, _ := bt_inlined(w, x >> 32, x & 0xFFFFFFFF)
        return (s, line)
    }
    x := -1 - id
    return (bt_u32(w.funcs + BT_FN * (x >> 32) + 8), x & 0xFFFFFFFF)
}

// word k (0: file, 1: name) of scope s, -1 if there is no such scope
priv fn bt_scope_word(w: *BtWalk, s: i64, k: i64) -> i64 {
    if s < 0 || s >= w.nscopes {
        return -1
    }
    return bt_u32(w.scopes + 8 * s + 4 * k)
}

priv fn bt_is_lib(w: *BtWalk, id: i64) -> bool {
    s, _ := bt_scope(w, id)
    return bt_scope_word(w, s, 1) >= (1 << 31)
}

// string number `off` of the table ("?" for -1)
priv fn bt_str(w: *BtWalk, off: i64) -> str {
    if off < 0 {
        return "?"
    }
    n, p := bt_uleb(w.strs + (off & 0x7FFFFFFF))
    return mkslice[u8](cast[*u8](p), n)
}

// the state of the walk and the line being written: globals, not locals, because after a stack
// overflow the handler may have little stack (Windows: what SetThreadStackGuarantee leaves;
// under Wine about 4 KiB)
priv bt_start: BtWalk
priv bt_cur: BtWalk
priv bt_count: BtOut
priv bt_out: BtOut
priv bt_buf: [512]u8
priv bt_len: i64

// the line being written in bt_buf: s, a number, a number in hexadecimal ("0x...") added
priv noinline fn bt_put(s: str) {
    for c in s {
        if bt_len < 511 {
            bt_buf[bt_len] = c
            bt_len += 1
        }
    }
}

priv noinline fn bt_num(x0: i64) {
    d: [20]u8
    k := 0
    x := x0
    loop {
        d[k] = u8('0' + x % 10)
        k += 1
        x /= 10
        if x == 0 {
            break
        }
    }
    for i in k - 1..=0 by -1 {
        if bt_len < 511 {
            bt_buf[bt_len] = d[i]
            bt_len += 1
        }
    }
}

priv noinline fn bt_hex(x: i64) {
    bt_put("0x")
    for i in 15..=0 by -1 {
        // (from the first digit that is not 0)
        if (x >> (4 * i) != 0 || i == 0) && bt_len < 511 {
            bt_buf[bt_len] = "0123456789abcdef"[(x >> (4 * i)) & 15]
            bt_len += 1
        }
    }
}

// writes line `id` of the trace (or "... N more" if `more` > 0) to standard error (no
// allocation: the panic may be "out of memory")
priv fn bt_write(w: *BtWalk, id: i64, more: i64) {
    bt_len = 0
    if more > 0 {
        bt_put("  ... ")
        bt_num(more)
        bt_put(if id >= BT_LIB_MORE { " more frames in the library" } else { " more" })
    } else if id >= BT_C {
        // C code: its library and function (Linux: of the dynamic symbols), else its offset
        lib, sym, off := bt_c_where(id - BT_C)
        bt_put("  at ")
        if len(lib) == 0 {
            bt_hex(id - BT_C)
        } else {
            bt_put(lib)
            if len(sym) != 0 {
                bt_put(" ")
                bt_put(sym)
            } else {
                bt_put("+")
                bt_hex(off)
            }
        }
    } else {
        s, line := bt_scope(w, id)
        bt_put("  at ")
        if line == 0 {
            bt_put("?")
        } else {
            bt_put(bt_str(w, bt_scope_word(w, s, 0)))
            bt_put(":")
            bt_num(line)
        }
        bt_put(" in ")
        bt_put(bt_str(w, bt_scope_word(w, s, 1)))
    }
    bt_buf[bt_len] = '\n'
    __write_all(2, cast[i64](ptr(bt_buf)), bt_len + 1)
}

// line number o.n of the trace: written if it is one of the first 20 or the last 5
priv fn bt_line(o: *BtOut, w: *BtWalk, id: i64) {
    k := o.n
    o.n += 1
    if !o.print {
        return
    }
    if k < 20 || k >= o.total - 5 {
        bt_write(w, id, if id >= BT_LIB_MORE { id - BT_LIB_MORE } else { 0 })
    } else if k == 20 {
        bt_write(w, 0, o.total - 25)
    }
}

// the next line of the walk, before library frames are left out (a line of C code is one of
// the program unless it comes after the program's last)
priv fn bt_add(o: *BtOut, w: *BtWalk, id: i64) {
    r := o.raw
    o.raw += 1
    c := id >= BT_C && id < BT_LIB_MORE
    if c && r > o.last {
        return
    }
    lib := !c && bt_is_lib(w, id)
    if !o.started {
        if lib {
            return
        }
        o.started = true
    }
    if lib {
        if o.run < 4 {
            o.head[o.run] = id
        } else {
            o.tail[(o.run - 4) % 3] = id
        }
        o.run += 1
        return
    }
    if o.run > 0 {
        for i in 0..min(o.run, 4) {
            bt_line(o, w, o.head[i])
        }
        if o.run > 7 {
            bt_line(o, w, BT_LIB_MORE + o.run - 7)
        }
        rest := max(min(o.run - 4, 3), 0)
        for i in 0..rest {
            bt_line(o, w, o.tail[(o.run - 4 - rest + i) % 3])
        }
        o.run = 0
    }
    bt_line(o, w, id)
    if !c {
        o.prog = r
        o.n_prog = o.n
    }
}

priv fn bt_walk(w0: *BtWalk, o: *BtOut) {
    bt_cur = *w0
    w := &bt_cur
    loop {
        if w.f < 0 {
            bt_add(o, w, BT_C + w.pc - (if w.fault { 0 } else { 1 }))
        } else {
            // the frames inlined at the address, innermost first, then the function's own
            v := bt_loc(w)
            depth := 0
            while v % 2 == 1 && depth < 1000 {
                k := v / 2
                bt_add(o, w, 1 + ((w.f << 32) | k))
                s, line, at := bt_inlined(w, w.f, k)
                v = if s < 0 { 0 } else { at }
                depth += 1
            }
            bt_add(o, w, -1 - ((w.f << 32) | (if v % 2 == 0 { (v / 2) & 0xFFFFFFFF } else { 0 })))
        }
        if !bt_step(w) {
            return
        }
    }
}

// writes the call stack of the panic being reported (see above)
noinline fn __bt_print() {
    t := __bt_table
    if t == 0 || __bt_busy {
        return
    }
    // (from here on a fault ends the program: the environment and the stack may be corrupted)
    __bt_busy = true
    if __os_backtrace_off() {
        return
    }
    w := &bt_start
    w.base = cast[*i64](t)[0]
    w.nfuncs = bt_u32(t + 8)
    w.nscopes = bt_u32(t + 12)
    w.funcs = t + bt_u32(t + 16)
    w.scopes = t + bt_u32(t + 20)
    w.data = t + bt_u32(t + 24)
    w.strs = t + bt_u32(t + 28)
    w.data_end = w.data + bt_u32(t + 32)
    w.memo_pc = -1
    w.lo, w.hi = __os_stack_range()
    if __bt_fault_pc != 0 {
        w.pc = __bt_fault_pc
        w.g = __bt_fault_regs
        w.g.known = 0xFFFF
        w.sp = w.g.r[4]
        w.fault = true
    } else {
        // from the frame of the caller (__die), with the registers it had: this function saves
        // them all (as every function using __ra_addr)
        at := __ra_addr()
        w.pc = cast[*i64](at)[0]
        w.sp = at + 8
        me := bt_find(w, cast[i64](__bt_print))
        if me >= 0 {
            bt_saved(w, me, at, bt_u8(w.funcs + BT_FN * me + 16))
        }
    }
    w.f = bt_find(w, w.pc)
    if w.f < 0 && !(w.fault && bt_foreign(w.pc)) || w.sp < w.lo || w.sp >= w.hi || w.sp % 8 != 0 {
        return
    }
    bt_count.last = 1 << 62
    bt_count.prog = -1
    bt_walk(w, &bt_count)
    bt_out.print = true
    bt_out.total = bt_count.n_prog
    bt_out.last = bt_count.prog
    bt_walk(w, &bt_out)
    __bt_busy = false
}

// ---------- memory ----------
// The arena that allocations come from is described by __heap_cur / __heap_end / __heap_base /
// __heap_hwm. A thread starts in its base arena; enter(&r) makes a Region the arena in use.
// The state of an arena that is not in use is kept in its Region struct (the base arena's in
// __heap_main), so the allocation paths below never look at regions. All of these are
// per thread: threads allocate independently, without locks. `owner` of an entered region is
// the id + 1 of the thread that entered it (one thread at a time: see enter).

// an arena of its own, for memory with one lifetime: region(), enter / leave, reset, region_free
struct Region { cur: i64, end: i64, base: i64, hwm: i64, owner: i64 }

__heap_main: Region
__region_stack: [64]*Region
__region_depth: i64

// __heap_grow(n) (OS layer) hands out n bytes when they do not fit between __heap_cur and
// __heap_end, or stops the program with "out of memory". The first call for an arena reserves
// its address space: 64 GiB for the main arena, 16 GiB for a region (thousands of regions
// fit), less if refused. __heap_end is the end of the memory that may be used without asking
// the system again (Linux: the whole reservation; Windows: the committed part).

// uninitialized memory, 16-byte aligned; never freed individually (see mark/release). A size
// that is negative (also one that overflowed) is refused by __heap_grow.
inline fn __alloc_raw(n: i64) -> i64 {
    n = (n + 15) & ~15
    p := __heap_cur
    if u64(n) > u64(__heap_end - p) {
        return __heap_grow(n)
    }
    __heap_cur = p + n
    return p
}

// the bytes of n elements of `size` bytes; stops the program if n is negative or the result
// does not fit in an i64
inline fn __alloc_size(n: i64, size: i64) -> i64 {
    if n < 0 || mulhi(u64(n), u64(size)) != 0 || n * size < 0 {
        __size_fail(n)
    }
    return n * size
}

noinline fn __size_fail(n: i64) -> never {
    if n < 0 {
        __die("panic: negative allocation size", "", "")
    }
    __die("panic: out of memory", "", "")
}

// zeroed memory: only memory that was handed out before (below the high-water mark) is dirty
inline fn __alloc(n: i64) -> i64 {
    p := __alloc_raw(n)
    if p < __heap_hwm {
        d := __heap_hwm - p
        memfill(p, 0, if d < n { d } else { n })
    }
    return p
}

// a + b for sizes that are not negative; stops the program if the sum does not fit
inline fn __add_size(a: i64, b: i64) -> i64 {
    if a + b < 0 {
        __size_fail(0)
    }
    return a + b
}

// n zeroed elements from the arena in use (they live until it is released: no free)
fn alloc[T](n: i64) -> []T {
    return mkslice[T](__alloc(__alloc_size(n, sizeof[T]())), n)
}

// one zeroed T from the arena in use
fn new[T]() -> *T {
    return cast[*T](__alloc(sizeof[T]()))
}

// arena control: everything allocated after mark() is released by release()
fn mark() -> i64 {
    if __check_mem != 1 && __mem_checked() {
        __mark_page()
    }
    return __heap_cur
}

// (ALC_CHECK_MEMORY) a mark starts a page, so that everything allocated after it can be taken
// away by its release
noinline fn __mark_page() {
    p := (__heap_cur + 4095) & ~4095
    if p > __heap_cur && p <= __heap_end {
        __heap_cur = p
    }
}

// gives back everything allocated from the arena in use since mark() returned m
fn release(m: i64) {
    // a mark taken before the first allocation (the heap is mapped lazily) means "everything"
    if m == 0 {
        m = __heap_base
    }
    if m >= __heap_base && m < __heap_cur {
        if __heap_cur > __heap_hwm {
            __heap_hwm = __heap_cur
        }
        if __check_mem != 1 && __mem_checked() {
            __heap_cur = __released(m, __heap_cur, __heap_end)
            return
        }
        __heap_cur = m
    }
}

// ---------- ALC_CHECK_MEMORY: catching the use of released memory ----------
// With ALC_CHECK_MEMORY=1 in the environment (read at the first release), memory that is
// released (release, frame_end, reset of a Region) is never handed out again: its whole pages
// are taken away from the program, so that the next access faults and the fault names what
// released it, and the rest is filled with 0xDE bytes (a pointer read from it is
// 0xDEDEDEDEDEDEDEDE, not an address). A Vec or Map stored outside the innermost
// frame_begin()/frame_end() scope that grows inside it stops the program at once: its new
// storage would be released by frame_end(). A mode for finding bugs: the memory in use
// (mem_used) only grows, by at least the rest of a page per release.
__check_mem: i64                    // 0: not read yet, 1: off, 2: on
// what the next release is (set by frame_end and reset): 0 release(), 1 frame_end(), 2 reset()
__tls_release_kind: i64
// the innermost frame scope of std.mem: its mark (0: none) and its arena
__tls_frame_floor: i64
__tls_frame_arena: *Region
// the last released ranges [lo, hi) and their kinds, for the report of a fault
__released_lo: [1024]i64
__released_hi: [1024]i64
__released_kind: [1024]i64
__released_n: i64

fn __mem_checked() -> bool {
    if __check_mem == 0 {
        __check_mem = if __os_check_memory() { 2 } else { 1 }
    }
    return __check_mem == 2
}

// (ALC_CHECK_MEMORY) gives back [m, cur) of an arena that ends at `end` without handing it out
// again: the new cursor
noinline fn __released(m: i64, cur: i64, end: i64) -> i64 {
    kind := __tls_release_kind
    __tls_release_kind = 0
    lo := (m + 4095) & ~4095
    top := cur
    if lo < cur {
        top = min((cur + 4095) & ~4095, end)
        __os_page_off(lo, top - lo)
    } else {
        lo = cur
    }
    memfill(m, 0xDE, lo - m)
    i := __released_n % 1024
    __released_lo[i] = m
    __released_hi[i] = top
    __released_kind[i] = kind
    __released_n += 1
    return top
}

// (ALC_CHECK_MEMORY) the Vec or Map whose header is at `at` gets new storage: it must not
// outlive the frame scope the storage belongs to
noinline fn __grow_check(at: i64) {
    if __tls_frame_floor == 0 || __tls_frame_arena != __region_top() {
        return
    }
    if at >= __tls_frame_floor && at < __heap_end {
        return                      // allocated inside the scope: released with its storage
    }
    lo, hi := __os_stack_range()
    if at >= lo && at < hi {
        return                      // a local variable (one of the scope or not: not known)
    }
    __die("panic: a Vec or Map stored outside the innermost frame_begin()/frame_end() scope grew inside it", "",
        "its new storage is released by frame_end() while the Vec or Map is still used (ALC_CHECK_MEMORY); reserve its room before frame_begin(), or build it in a Region or an Arena")
}

// the report of a memory fault at `addr` (0: not known)
noinline fn __die_fault(addr: i64) -> never {
    if __check_mem == 2 {
        for i in 0..min(__released_n, 1024) {
            if addr >= __released_lo[i] && addr < __released_hi[i] {
                what := match __released_kind[i] {
                    1 => "the memory was released by frame_end(): it was allocated inside a frame_begin()/frame_end() scope (also the new storage of a Vec or Map that grew there) and used after the scope ended (ALC_CHECK_MEMORY)"
                    2 => "the memory was released by reset() of a Region and used afterwards (ALC_CHECK_MEMORY)"
                    _ => "the memory was released by release() of a mark taken before it was allocated, and used afterwards (ALC_CHECK_MEMORY)"
                }
                __die("panic: use of released memory", "", what)
            }
        }
        for k in 0..16 {
            if u64(__bt_fault_regs.r[k]) == 0xDEDEDEDEDEDEDEDE {
                __die("panic: memory fault", "", "a register holds 0xDEDEDEDEDEDEDEDE: most likely a pointer read from released memory (ALC_CHECK_MEMORY fills it with 0xDE bytes)")
            }
        }
    }
    // (not near nil and not on the stack: perhaps a pointer into memory that was released)
    lo, hi := __os_stack_range()
    hint := __check_mem != 2 && u64(addr) >= 0x10000 && !(addr >= lo - 0x100000 && addr < hi)
    __die("panic: memory fault (nil dereference, stack overflow or use of released memory)", "",
        if hint { "run with ALC_CHECK_MEMORY=1 in the environment to find a use of released memory" } else { "" })
}

// ---------- regions: independent arenas ----------
// A Region is an arena of its own. The zero value is a valid empty region. Between enter(&r)
// and the matching leave() everything that allocates (alloc, new, Vec, Map, fmt, slice
// literals, clone, ...) takes its memory from r; reset(&r) empties it in one step. A region
// is used through a pointer and must not be copied while it holds memory or is entered.
fn region() -> Region {
    return Region{}
}

fn __region_save(r: *Region) {
    r.cur = __heap_cur
    r.end = __heap_end
    r.base = __heap_base
    r.hwm = __heap_hwm
}

fn __region_load(r: *Region) {
    __heap_cur = r.cur
    __heap_end = r.end
    __heap_base = r.base
    __heap_hwm = r.hwm
}

// the arena in use: the innermost entered region, or the base arena
fn __region_top() -> *Region {
    if __region_depth == 0 {
        return &__heap_main
    }
    return __region_stack[__region_depth - 1]
}

// a region another thread has entered was entered, reset or freed (`what`)
noinline fn __region_other(what: str, owner: i64) -> never {
    __die(fmt("panic: ", what, ": this region is entered by thread ", owner - 1), "", "")
}

// allocations now come from r, until the matching leave(); calls nest up to 64 deep. A region
// is entered by one thread at a time.
fn enter(r: *Region) {
    if __region_depth == 64 {
        __die("panic: enter: more than 64 regions are entered (is a leave() missing?)", "", "")
    }
    me := __thread_key()
    prev, ok := atomic_cas(&r.owner, 0, me)
    if !ok {
        if prev == me {
            __die("panic: enter: this region is already entered", "", "")
        }
        __region_other("enter", prev)
    }
    __region_save(__region_top())
    __region_load(r)
    __region_stack[__region_depth] = r
    __region_depth += 1
}

// back to the arena that was in use before the matching enter()
fn leave() {
    if __region_depth == 0 {
        __die("panic: leave without enter", "", "")
    }
    r := __region_stack[__region_depth - 1]
    __region_save(r)
    atomic_store(&r.owner, 0)
    __region_depth -= 1
    __region_load(__region_top())
}

// empties r: everything allocated from it is gone. Its memory is kept and handed out again
// (zeroed) by later allocations. r may be the region in use.
fn reset(r: *Region) {
    if __region_depth > 0 && __region_stack[__region_depth - 1] == r {
        if __heap_cur > __heap_hwm {
            __heap_hwm = __heap_cur
        }
        if __heap_cur > __heap_base && __check_mem != 1 && __mem_checked() {
            __tls_release_kind = 2
            __heap_cur = __released(__heap_base, __heap_cur, __heap_end)
            return
        }
        __heap_cur = __heap_base
        return
    }
    o := atomic_load(&r.owner)
    if o != 0 && o != __thread_key() {
        __region_other("reset", o)
    }
    if r.cur > r.hwm {
        r.hwm = r.cur
    }
    if r.cur > r.base && __check_mem != 1 && __mem_checked() {
        __tls_release_kind = 2
        r.cur = __released(r.base, r.cur, r.end)
        return
    }
    r.cur = r.base
}

// bytes of r in use
fn used(r: *Region) -> i64 {
    if __region_depth > 0 && __region_stack[__region_depth - 1] == r {
        return __heap_cur - __heap_base
    }
    return r.cur - r.base
}

// gives the memory of r back to the operating system; r is empty afterwards and can be used
// again. The region must not be entered.
fn region_free(r: *Region) {
    o := atomic_load(&r.owner)
    if o != 0 {
        if o == __thread_key() {
            __die("panic: region_free: this region is entered (leave() first)", "", "")
        }
        __region_other("region_free", o)
    }
    if r.base != 0 {
        __os_unmap(r.base, r.end - r.base)
    }
    *r = Region{}
}

// ---------- output ----------
// Standard output is buffered per thread (__tls_obuf; the main thread's is __obuf). While the
// program has one thread, the main thread writes its buffer to the file when it is full, at
// flush() and at exit: the fast path of __put_str and putc. Once a thread was spawned (or a
// thread a C library created printed: __threaded), output goes line by line: whenever a
// thread writes a newline, its complete lines move to the shared buffer __out_buf under the
// output lock (a line longer than the 64 KiB buffer in parts), so lines of different threads
// never mix; flush() moves all of the calling thread's output and writes the shared buffer;
// exit() flushes. A thread's last line without a newline is written when it ends, flushes or
// writes the newline, and is lost if the process ends before. eprint, eput and panic messages
// take the output lock too. (__tls_ocap is the room of the fast path: 0 in line mode.)
priv const OBUF = 65536
__obuf: [65536]u8
__tls_obuf: i64
__tls_olen: i64
__tls_ocap: i64
__threaded: bool
__out_buf: i64
__out_len: i64
__out_lock: i64
__out_owner: i64

// writes out what print and put have buffered for standard output (exit does it too)
fn flush() {
    if __tls_ocap != 0 && !__threaded {
        if __tls_olen > 0 {
            n := __tls_olen
            __tls_olen = 0
            __out_write(__tls_obuf, n)
        }
        return
    }
    __out_acquire()
    __out_commit(true)
    __out_drain()
    __out_release()
}

noinline fn __put_str(s: str) {
    if __tls_cap_on != 0 {
        __cap_put(s)
        return
    }
    n := len(s)
    if n > __tls_ocap - __tls_olen {
        __put_slow(s)
        return
    }
    memcopy(__tls_obuf + __tls_olen, ptr(s), n)
    __tls_olen += n
}

// writes one byte to standard output (buffered like put)
fn putc(c: u8) {
    if __tls_cap_on != 0 || __tls_olen >= __tls_ocap {
        one: [1]u8
        one[0] = c
        __put_slow(one[..])
        return
    }
    cast[*u8](__tls_obuf + __tls_olen)[0] = c
    __tls_olen += 1
}

noinline fn __put_slow(s: str) {
    if __tls_cap_on != 0 {
        __cap_put(s)
        return
    }
    if __tls_obuf == 0 {
        // a thread that has not printed yet: its buffer (line mode)
        p := __os_map(OBUF)
        if p < 0 && p > -4096 {
            __die("panic: out of memory", "", "")
        }
        __tls_obuf = p
        __tls_ocap = 0
        atomic_store(&__threaded, true)
    }
    n := len(s)
    if __tls_ocap != 0 {
        if !__threaded {
            // the only thread, its buffer is full
            flush()
            if n >= OBUF {
                __out_write(cast[i64](ptr(s)), n)
                return
            }
            memcopy(__tls_obuf + __tls_olen, ptr(s), n)
            __tls_olen += n
            return
        }
        __tls_ocap = 0
    }
    i := 0
    while i < n {
        if __tls_olen == OBUF {
            __out_acquire()
            __out_commit(false)
            __out_release()
        }
        k := min(n - i, OBUF - __tls_olen)
        memcopy(__tls_obuf + __tls_olen, cast[i64](ptr(s)) + i, k)
        __tls_olen += k
        i += k
    }
    j := n - 1
    while j >= 0 && s[j] != '\n' {
        j -= 1
    }
    if j >= 0 {
        __out_acquire()
        __out_commit(false)
        __out_release()
    }
}

fn __out_acquire() {
    __os_lock(&__out_lock)
    __out_owner = __thread_key()
}

fn __out_release() {
    __out_owner = 0
    __os_unlock(&__out_lock)
}

// (holding the output lock) moves this thread's complete lines (all: everything) to the shared
// buffer; a full buffer without a newline goes as it is
fn __out_commit(all: bool) {
    n := __tls_olen
    if n == 0 {
        return
    }
    p := __tls_obuf
    cut := n
    if !all {
        cut = n
        while cut > 0 && cast[*u8](p + cut - 1)[0] != '\n' {
            cut -= 1
        }
        if cut == 0 {
            if n < OBUF {
                return
            }
            cut = n
        }
    }
    if __out_buf == 0 {
        b := __os_map(OBUF)
        if b < 0 && b > -4096 {
            // no shared buffer: written at once
            __tls_olen = 0
            __out_write(p, n)
            return
        }
        __out_buf = b
    }
    if cut > OBUF - __out_len {
        __out_drain()
    }
    memcopy(__out_buf + __out_len, p, cut)
    __out_len += cut
    // (an overlapping copy to a lower address is a forward copy)
    memcopy(p, p + cut, n - cut)
    __tls_olen = n - cut
}

// (holding the output lock) writes the shared buffer
fn __out_drain() {
    if __out_len > 0 {
        n := __out_len
        __out_len = 0
        __out_write(__out_buf, n)
    }
}

// the output before a panic message (holding the panic lock): everything buffered is written
// and the output lock is kept to the end. The lock is waited for at most about a second: the
// thread that holds it may have faulted.
fn __out_panic() {
    if __tls_ocap != 0 && !__threaded {
        flush()
        return
    }
    if __out_owner != __thread_key() {
        for k in 0..1000 {
            if __os_try_lock(&__out_lock) {
                break
            }
            __os_sleep_ns(1000000)
        }
        __out_owner = __thread_key()
    }
    __out_commit(true)
    __out_drain()
}

fn __put_u64(x: u64) {
    b: [24]u8
    i := 24
    loop {
        i -= 1
        b[i] = u8(x % 10) + '0'
        x = x / 10
        if x == 0 {
            break
        }
    }
    __put_str(b[i..24])
}

fn __put_i64(x: i64) {
    if x < 0 {
        putc('-')
        __put_u64(u64(0) - u64(x))
    } else {
        __put_u64(u64(x))
    }
}

fn __put_bool(b: bool) {
    if b {
        __put_str("true")
    } else {
        __put_str("false")
    }
}

fn __put_ptr(x: i64) {
    b: [18]u8
    i := 18
    v := u64(x)
    loop {
        i -= 1
        d := u8(v & 15)
        b[i] = if d < 10 { d + '0' } else { d - 10 + 'a' }
        v = v >> 4
        if v == 0 {
            break
        }
    }
    i -= 1
    b[i] = 'x'
    i -= 1
    b[i] = '0'
    __put_str(b[i..18])
}

// ---------- exact float formatting ----------
// Exact decimal digits of m * 2^e written to buf (no leading/trailing zeros).
// Returns (n, pos): value = 0.d1..dn * 10^pos.
fn __dec_expand(m: u64, e: i64, buf: []u8) -> (i64, i64) {
    limbs: [40]u32
    n := 0
    pos := 0
    if m == 0 {
        return (0, 0)
    }
    if e >= 0 {
        sh := e & 31
        w := e >> 5
        t := (m & 0xFFFFFFFF) << u64(sh)
        limbs[w] = u32(t)
        t = (t >> 32) + ((m >> 32) << u64(sh))
        limbs[w + 1] = u32(t)
        limbs[w + 2] = u32(t >> 32)
        nl := w + 3
        tmp: [340]u8
        tn := 0
        while nl > 0 && limbs[nl - 1] == 0 {
            nl -= 1
        }
        while nl > 0 {
            rem: u64 = 0
            i := nl - 1
            while i >= 0 {
                cur := (rem << 32) | u64(limbs[i])
                limbs[i] = u32(cur / 1000000000)
                rem = cur % 1000000000
                i -= 1
            }
            while nl > 0 && limbs[nl - 1] == 0 {
                nl -= 1
            }
            for k in 0..9 {
                if nl == 0 && rem == 0 {
                    break
                }
                tmp[tn] = u8(rem % 10) + '0'
                tn += 1
                rem = rem / 10
            }
        }
        start := 0
        while start < tn && tmp[start] == '0' {
            start += 1
        }
        n = tn - start
        for j in 0..n {
            buf[j] = tmp[tn - 1 - j]
        }
        return (n, tn)
    }
    k := -e
    ip: u64 = 0
    fr := m
    if k < 64 {
        ip = m >> u64(k)
        fr = m & ((u64(1) << u64(k)) - 1)
    }
    if ip != 0 {
        tmp: [24]u8
        tn := 0
        while ip != 0 {
            tmp[tn] = u8(ip % 10) + '0'
            tn += 1
            ip = ip / 10
        }
        for j in 0..tn {
            buf[j] = tmp[tn - 1 - j]
        }
        n = tn
        pos = tn
    }
    kw := k >> 5
    kb := u32(k & 31)
    nl := kw + 2
    limbs[0] = u32(fr)
    limbs[1] = u32(fr >> 32)
    nonzero := fr != 0
    while nonzero {
        carry: u64 = 0
        for i in 0..nl {
            cur := u64(limbs[i]) * 10 + carry
            limbs[i] = u32(cur)
            carry = cur >> 32
        }
        d := (u64(limbs[kw]) | (u64(limbs[kw + 1]) << 32)) >> u64(kb)
        d = d & 15
        limbs[kw] = limbs[kw] & ((u32(1) << kb) - 1)
        limbs[kw + 1] = 0
        nonzero = false
        for i in 0..kw + 1 {
            if limbs[i] != 0 {
                nonzero = true
            }
        }
        if n == 0 && d == 0 {
            pos -= 1
        } else {
            buf[n] = u8(d) + '0'
            n += 1
        }
    }
    while n > 0 && buf[n - 1] == '0' {
        n -= 1
    }
    return (n, pos)
}

// (mantissa, exponent) with value = m * 2^e; class: 0 finite, 1 inf, 2 nan
fn __f64_parts(x: f64) -> (u64, i64, i64) {
    bits := cast[u64](x)
    ex := i64((bits >> 52) & 2047)
    man := bits & 0xFFFFFFFFFFFFF
    if ex == 2047 {
        return (man, 0, if man == 0 { 1 } else { 2 })
    }
    if ex == 0 {
        return (man, -1074, 0)
    }
    return (man | (u64(1) << 52), ex - 1075, 0)
}

fn __copy_str(out: []u8, o: i64, s: str) -> i64 {
    return o + copy(out[o..], s)
}

// printf("%.*f") semantics: exact value, round half to even. Returns the length written to out.
fn __fmt_fixed(x: f64, prec: i64, out: []u8) -> i64 {
    if prec < 0 {
        prec = 0
    }
    // every f64 has at most 1074 digits after the point: more precision only adds zeros, which
    // the callers append (__fmt_extra)
    if prec > 1100 {
        prec = 1100
    }
    m, e, cls := __f64_parts(x)
    neg := (cast[u64](x) >> 63) != 0
    o := 0
    if cls == 2 {
        return __copy_str(out, o, "nan")
    }
    if neg {
        out[o] = '-'
        o += 1
    }
    if cls == 1 {
        return __copy_str(out, o, "inf")
    }
    d: [1600]u8
    n, pos := __dec_expand(m, e, d[..])
    keep := pos + prec
    up := false
    if keep < n && keep >= 0 {
        c := d[keep]
        if c > '5' {
            up = true
        } else if c == '5' {
            if n > keep + 1 {
                up = true
            } else if keep > 0 && ((d[keep - 1] - '0') & 1) == 1 {
                up = true
            }
        }
    }
    if keep < 0 {
        keep = 0
    }
    for i in n..keep {
        d[i] = '0'
    }
    if up {
        i := keep - 1
        while i >= 0 && d[i] == '9' {
            d[i] = '0'
            i -= 1
        }
        if i >= 0 {
            d[i] += 1
        } else {
            // carry out: 0.99.. -> 1.00..
            d[keep] = '0'
            d[0] = '1'
            pos += 1
            keep += 1
        }
    }
    if pos <= 0 {
        out[o] = '0'
        o += 1
    } else {
        o += copy(out[o..], d[..pos])
    }
    if prec > 0 {
        out[o] = '.'
        o += 1
        for j in 0..prec {
            idx := pos + j
            out[o] = if idx >= 0 && idx < keep { d[idx] } else { '0' }
            o += 1
        }
    }
    return o
}

fn __dec_cmp(a: []u8, an: i64, ap: i64, b: []u8, bn: i64, bp: i64) -> i64 {
    if ap != bp {
        return if ap < bp { -1 } else { 1 }
    }
    mx := if an > bn { an } else { bn }
    for i in 0..mx {
        x := if i < an { a[i] } else { '0' }
        y := if i < bn { b[i] } else { '0' }
        if x != y {
            return if x < y { -1 } else { 1 }
        }
    }
    return 0
}

// shortest decimal that parses back to exactly x. Returns the length written to out.
fn __fmt_shortest(x: f64, out: []u8) -> i64 {
    m, e, cls := __f64_parts(x)
    neg := (cast[u64](x) >> 63) != 0
    return __fmt_short_parts(neg, m, e, cls, m == (u64(1) << 52) && e > -1074, out)
}

fn __fmt_shortest32(x: f32, out: []u8) -> i64 {
    bits := cast[u32](x)
    ex := i64((bits >> 23) & 255)
    man := u64(bits & 0x7FFFFF)
    neg := (bits >> 31) != 0
    if ex == 255 {
        return __fmt_short_parts(neg, man, 0, if man == 0 { 1 } else { 2 }, false, out)
    }
    if ex == 0 {
        return __fmt_short_parts(neg, man, -149, 0, false, out)
    }
    return __fmt_short_parts(neg, man | (u64(1) << 23), ex - 150, 0, man == 0 && ex > 1, out)
}

// value = m * 2^e; `closer`: the gap to the next smaller float is half the usual one
fn __fmt_short_parts(neg: bool, m: u64, e: i64, cls: i64, closer: bool, out: []u8) -> i64 {
    o := 0
    if cls == 2 {
        return __copy_str(out, o, "nan")
    }
    if neg {
        out[o] = '-'
        o += 1
    }
    if cls == 1 {
        return __copy_str(out, o, "inf")
    }
    if m == 0 {
        return __copy_str(out, o, "0.0")
    }
    d: [1100]u8
    dh: [1100]u8
    dl: [1100]u8
    n, pos := __dec_expand(m, e, d[..])
    nh, ph := __dec_expand(2 * m + 1, e - 1, dh[..])
    nl := 0
    pl := 0
    if closer {
        nl, pl = __dec_expand(4 * m - 1, e - 2, dl[..])
    } else {
        nl, pl = __dec_expand(2 * m - 1, e - 1, dl[..])
    }
    even := (m & 1) == 0
    c: [24]u8
    cn := 0
    cp := 0
    found := false
    for p in 1..19 {
        if p >= n {
            copy(c[..], d[..n])
            cn = n
            cp = pos
            break
        }
        // the p-digit numbers below and above x: the nearer one first; the other one counts
        // too, since below a power of two the interval is closer on one side
        nearer_up := d[p] > '5' || (d[p] == '5' && (n > p + 1 || ((d[p - 1] - '0') & 1) == 1))
        for t in 0..2 {
            up := if t == 0 { nearer_up } else { !nearer_up }
            copy(c[..], d[..p])
            cn = p
            cp = pos
            if up {
                i := p - 1
                while i >= 0 && c[i] == '9' {
                    i -= 1
                }
                if i >= 0 {
                    c[i] += 1
                    cn = i + 1
                } else {
                    c[0] = '1'
                    cn = 1
                    cp = pos + 1
                }
            }
            while cn > 1 && c[cn - 1] == '0' {
                cn -= 1
            }
            lo := __dec_cmp(c[..], cn, cp, dl[..], nl, pl)
            hi := __dec_cmp(c[..], cn, cp, dh[..], nh, ph)
            if (lo > 0 || (even && lo == 0)) && (hi < 0 || (even && hi == 0)) {
                found = true
                break
            }
        }
        if found {
            break
        }
    }
    if cp > 0 && cp <= 21 {
        for i in 0..cp {
            out[o] = if i < cn { c[i] } else { '0' }
            o += 1
        }
        out[o] = '.'
        o += 1
        if cn > cp {
            o += copy(out[o..], c[cp..cn])
        } else {
            out[o] = '0'
            o += 1
        }
        return o
    }
    if cp <= 0 && cp > -6 {
        out[o] = '0'
        out[o + 1] = '.'
        o += 2
        fill(out[o..o - cp], '0')
        o -= cp
        o += copy(out[o..], c[..cn])
        return o
    }
    out[o] = c[0]
    o += 1
    if cn > 1 {
        out[o] = '.'
        o += 1
        o += copy(out[o..], c[1..cn])
    }
    out[o] = 'e'
    o += 1
    ex := cp - 1
    if ex < 0 {
        out[o] = '-'
        o += 1
        ex = -ex
    }
    t: [8]u8
    tn := 0
    loop {
        t[tn] = u8(ex % 10) + '0'
        tn += 1
        ex = ex / 10
        if ex == 0 {
            break
        }
    }
    for i in 0..tn {
        out[o] = t[tn - 1 - i]
        o += 1
    }
    return o
}

fn __put_f32(x: f32) {
    b: [40]u8
    n := __fmt_shortest32(x, b[..])
    __put_str(b[..n])
}

// ---------- matrix / quaternion operators ----------
fn __mat4_mulv(m: mat4, v: vec4) -> vec4 {
    return m[0] * v.x + m[1] * v.y + m[2] * v.z + m[3] * v.w
}

fn __mat4_mul(a: mat4, b: mat4) -> mat4 {
    return mat4(__mat4_mulv(a, b[0]), __mat4_mulv(a, b[1]), __mat4_mulv(a, b[2]), __mat4_mulv(a, b[3]))
}

fn __mat4_diag(s: f32) -> mat4 {
    return mat4(vec4(s, 0.0, 0.0, 0.0), vec4(0.0, s, 0.0, 0.0), vec4(0.0, 0.0, s, 0.0), vec4(0.0, 0.0, 0.0, s))
}

// Hamilton product; components are (x, y, z, w) with w the scalar part
fn __quat_mul(a: quat, b: quat) -> quat {
    return quat(
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
}

// rotate v by the unit quaternion q: v + 2w(u x v) + 2 u x (u x v)
fn __quat_rotate(q: quat, v: vec3) -> vec3 {
    u := q.xyz
    t := (u.yzx * v.zxy - u.zxy * v.yzx) * 2.0
    return v + t * q.w + (u.yzx * t.zxy - u.zxy * t.yzx)
}

fn __put_f64(x: f64) {
    b: [40]u8
    n := __fmt_shortest(x, b[..])
    __put_str(b[..n])
}

// the zeros beyond the 1100 digits that __fmt_fixed writes (x finite)
fn __fmt_extra(x: f64, prec: i64) -> i64 {
    return if prec > 1100 && x - x == 0.0 { prec - 1100 } else { 0 }
}

// print x with exactly `prec` digits after the decimal point (like printf "%.Nf")
fn putf(x: f64, prec: i64) {
    __at_putf(x, prec, "?")
}

fn __at_putf(x: f64, prec: i64, at: str) {
    __check_digits(prec, at)
    b: [1420]u8
    n := __fmt_fixed(x, prec, b[..])
    __put_str(b[..n])
    for i in 0..__fmt_extra(x, prec) {
        putc('0')
    }
}

fn __check_digits(prec: i64, at: str) {
    if prec < 0 {
        __assert_fail(at, "fmtf: negative number of digits")
    }
}

// x as text with exactly `prec` digits after the decimal point (like printf "%.Nf")
fn fmtf(x: f64, prec: i64) -> str {
    return __at_fmtf(x, prec, "?")
}

fn __at_fmtf(x: f64, prec: i64, at: str) -> str {
    __check_digits(prec, at)
    b: [1420]u8
    n := __fmt_fixed(x, prec, b[..])
    s := alloc[u8](n + __fmt_extra(x, prec))
    copy(s, b[..n])
    fill(s[n..], '0')
    return s
}

// fmtf(x, prec) right-aligned in `width` characters (like printf "%W.Nf")
fn fmtf(x: f64, prec: i64, width: i64) -> str {
    return __at_fmtf(x, prec, width, "?")
}

fn __at_fmtf(x: f64, prec: i64, width: i64, at: str) -> str {
    return pad_left(__at_fmtf(x, prec, at), width, ' ')
}

// the f32 versions: an f32 converts to f64 exactly, so the digits are those of the exact value
fn putf(x: f32, prec: i64) {
    __at_putf(f64(x), prec, "?")
}

fn __at_putf(x: f32, prec: i64, at: str) {
    __at_putf(f64(x), prec, at)
}

// fmtf of the f32's exact value
fn fmtf(x: f32, prec: i64) -> str {
    return __at_fmtf(f64(x), prec, "?")
}

fn __at_fmtf(x: f32, prec: i64, at: str) -> str {
    return __at_fmtf(f64(x), prec, at)
}

// fmtf of the f32's exact value, right-aligned in `width` characters
fn fmtf(x: f32, prec: i64, width: i64) -> str {
    return __at_fmtf(f64(x), prec, width, "?")
}

fn __at_fmtf(x: f32, prec: i64, width: i64, at: str) -> str {
    return __at_fmtf(f64(x), prec, width, at)
}

fn __put_slice[T](s: []T) {
    putc('[')
    for i, x in s {
        if i > 0 {
            __put_str(", ")
        }
        put(x)
    }
    putc(']')
}

fn __str_eq(a: str, b: str) -> bool {
    n := len(a)
    if n != len(b) {
        return false
    }
    if n >= 8 {
        return __mem_eq(cast[i64](ptr(a)), cast[i64](ptr(b)), n)
    }
    for i in 0..n {
        if a[i] != b[i] {
            return false
        }
    }
    return true
}

// ---------- bytes, a word at a time ----------
// These read 8 bytes per step with u64 loads (unaligned: fine on x86-64 and arm64; both are
// little-endian, so the byte at the lowest address is the low byte of a word), and never
// outside the bytes they are given. The loads are u64 reads of memory that may have been
// written as another type (a byte view of typed data): the functions that do them are not
// inlined, so that no such load can be moved across a store in the caller.

inline fn __ld64(p: i64) -> u64 {
    return *cast[*u64](p)
}

inline fn __ld32(p: i64) -> u64 {
    return u64(*cast[*u32](p))
}

inline fn __ld8(p: i64) -> u64 {
    return u64(*cast[*u8](p))
}

// bit 7 of each byte is set where that byte of v is zero, all other bits are clear (exact:
// no carry crosses a byte)
inline fn __zero_bytes(v: u64) -> u64 {
    return ~(((v & 0x7F7F7F7F7F7F7F7F) + 0x7F7F7F7F7F7F7F7F) | v) & 0x8080808080808080
}

// the byte number (0..7) of the lowest byte of a non-zero mask
inline fn __low_byte(z: u64) -> i64 {
    return i64(ctz(z)) >> 3
}

// the n bytes at a equal the n bytes at b (inlined only into the functions below)
inline fn __mem_eq_k(a: i64, b: i64, n: i64) -> bool {
    if n >= 8 {
        i := 0
        while i + 16 < n {
            if ((__ld64(a + i) ^ __ld64(b + i)) | (__ld64(a + i + 8) ^ __ld64(b + i + 8))) != 0 {
                return false
            }
            i += 16
        }
        if i + 8 < n {
            if __ld64(a + i) != __ld64(b + i) {
                return false
            }
        }
        // the last 8 bytes (they may overlap bytes already compared)
        return __ld64(a + n - 8) == __ld64(b + n - 8)
    }
    if n >= 4 {
        return __ld32(a) == __ld32(b) && __ld32(a + n - 4) == __ld32(b + n - 4)
    }
    for i in 0..n {
        if __ld8(a + i) != __ld8(b + i) {
            return false
        }
    }
    return true
}

noinline fn __mem_eq(a: i64, b: i64, n: i64) -> bool {
    return __mem_eq_k(a, b, n)
}

// the first position where the n bytes at a and b differ, or n
noinline fn __mem_diff(a: i64, b: i64, n: i64) -> i64 {
    i := 0
    while i + 8 <= n {
        x := __ld64(a + i) ^ __ld64(b + i)
        if x != 0 {
            return i + __low_byte(x)
        }
        i += 8
    }
    if i < n && n >= 8 {
        // the last 8 bytes; those before i are equal
        x := __ld64(a + n - 8) ^ __ld64(b + n - 8)
        return if x != 0 { n - 8 + __low_byte(x) } else { n }
    }
    while i < n {
        if __ld8(a + i) != __ld8(b + i) {
            return i
        }
        i += 1
    }
    return n
}

// the position of the first byte c among the n bytes at p, or -1
noinline fn __mem_chr(p: i64, n: i64, c: u8) -> i64 {
    if n < 8 {
        for i in 0..n {
            if __ld8(p + i) == u64(c) {
                return i
            }
        }
        return -1
    }
    pat := u64(c) * 0x0101010101010101
    i := 0
    while i + 8 <= n {
        z := __zero_bytes(__ld64(p + i) ^ pat)
        if z != 0 {
            return i + __low_byte(z)
        }
        i += 8
    }
    if i < n {
        // the last 8 bytes; none of those before i is c
        z := __zero_bytes(__ld64(p + n - 8) ^ pat)
        if z != 0 {
            return n - 8 + __low_byte(z)
        }
    }
    return -1
}

// how many of the n bytes at p are c
noinline fn __mem_count(p: i64, n: i64, c: u8) -> i64 {
    pat := u64(c) * 0x0101010101010101
    k := 0
    i := 0
    while i + 8 <= n {
        k += i64(popcnt(__zero_bytes(__ld64(p + i) ^ pat)))
        i += 8
    }
    while i < n {
        if __ld8(p + i) == u64(c) {
            k += 1
        }
        i += 1
    }
    return k
}

// ---------- tests ----------
fn __run_test(name: str, f: fn()) {
    flush()
    r := __os_test(f)
    if r < 0 {
        // (a process that runs one test of the program, on Windows: not this one)
        return
    }
    if r == 1 {
        put("ok   ", name, "\n")
    } else {
        put("FAIL ", name, "\n")
        __tests_failed += 1
    }
    flush()
}

fn __tests_done() -> i64 {
    if __tests_failed > 0 {
        put(__tests_failed, " test(s) failed\n")
        return 1
    }
    return 0
}

// ---------- capture output into a string: fmt(...) ----------
// The capture buffer (per thread) lives outside the arena (release() must not take it away): a
// block of the thread block first, then mappings of its own.
__tls_cap_on: i64
__tls_cap_static: [1024]u8
__tls_cap_buf: []u8
__tls_cap_len: i64

// captures nest: each fmt() takes the text appended after its starting position
fn __cap_begin() -> i64 {
    if len(__tls_cap_buf) == 0 {
        __tls_cap_buf = __tls_cap_static[..]
    }
    __tls_cap_on += 1
    return __tls_cap_len
}

fn __cap_put(s: str) {
    n := len(s)
    if __tls_cap_len + n > len(__tls_cap_buf) {
        if n > (1 << 46) - __tls_cap_len {
            __die("panic: out of memory", "", "")
        }
        cap := len(__tls_cap_buf) * 2
        while cap < __tls_cap_len + n {
            cap = cap * 2
        }
        p := __os_map(cap)
        if p < 0 && p > -4096 {
            __die("panic: out of memory", "", "")
        }
        memcopy(p, ptr(__tls_cap_buf), __tls_cap_len)
        if len(__tls_cap_buf) > 1024 {
            __os_unmap(cast[i64](ptr(__tls_cap_buf)), len(__tls_cap_buf))
        }
        __tls_cap_buf = mkslice[u8](p, cap)
    }
    memcopy(cast[i64](ptr(__tls_cap_buf)) + __tls_cap_len, ptr(s), n)
    __tls_cap_len += n
}

fn __cap_end(start: i64) -> str {
    n := __tls_cap_len - start
    out := alloc[u8](n)
    memcopy(ptr(out), cast[i64](ptr(__tls_cap_buf)) + start, n)
    __tls_cap_len = start
    __tls_cap_on -= 1
    return out
}

// ---------- hashing and equality helpers ----------
fn __hash_u64(x: u64) -> u64 {
    x = (x ^ (x >> 33)) * 0xff51afd7ed558ccd
    x = (x ^ (x >> 33)) * 0xc4ceb9fe1a85ec53
    return x ^ (x >> 33)
}

// 8 bytes per step (see "bytes, a word at a time"): the words of s in order, the last one
// partial, each multiplied into the state, then __hash_u64
noinline fn __hash_str(s: str) -> u64 {
    n := len(s)
    p := cast[i64](ptr(s))
    h: u64 = 0xcbf29ce484222325 ^ u64(n)
    i := 0
    while i + 8 <= n {
        h = (h ^ __ld64(p + i)) * 0x9E3779B97F4A7C15
        h ^= h >> 32
        i += 8
    }
    r := n - i
    if r > 0 {
        // the r < 8 remaining bytes as a little-endian number, read without going past the end
        w: u64 = 0
        if n >= 8 {
            w = __ld64(p + n - 8) >> u64(64 - 8 * r)
        } else if r >= 4 {
            w = __ld32(p) | (__ld32(p + r - 4) << u64(8 * (r - 4)))
        } else {
            w = __ld8(p) | (__ld8(p + (r >> 1)) << u64(8 * (r >> 1))) | (__ld8(p + r - 1) << u64(8 * (r - 1)))
        }
        h = (h ^ w) * 0x9E3779B97F4A7C15
    }
    return __hash_u64(h)
}

fn __hash_mix(a: u64, b: u64) -> u64 {
    return __hash_u64(a ^ (b + 0x9e3779b97f4a7c15 + (a << 6) + (a >> 2)))
}

fn __hash_slice[T](s: []T) -> u64 {
    h: u64 = u64(len(s))
    for x in s {
        h = __hash_mix(h, hash(x))
    }
    return h
}

fn __slice_eq[T](a: []T, b: []T) -> bool {
    if len(a) != len(b) {
        return false
    }
    for i in 0..len(a) {
        if a[i] != b[i] {
            return false
        }
    }
    return true
}

// ---------- small generic helpers ----------
// the smaller of a and b; a NaN argument makes the result NaN, whatever its position (`b != b`:
// only a NaN)
fn min[T](a: T, b: T) -> T {
    if b < a || b != b { b } else { a }
}

// the larger of a and b; a NaN argument makes the result NaN
fn max[T](a: T, b: T) -> T {
    if b > a || b != b { b } else { a }
}

// the string that comes first in byte order (as `cmp` orders them)
fn min(a: str, b: str) -> str {
    if cmp(b, a) < 0 { b } else { a }
}

// the string that comes last in byte order
fn max(a: str, b: str) -> str {
    if cmp(b, a) > 0 { b } else { a }
}

// the absolute value (abs(-0.0) is 0.0; the most negative integer of a type stays negative)
fn abs[T](x: T) -> T {
    // `0 - x`, not `-x`: the absolute value of -0.0 is 0.0
    if x <= 0 { 0 - x } else { x }
}

// a + b of any integer type, limited to the type's range instead of wrapping
fn sat_add[T](a: T, b: T) -> T {
    s := a + b
    zero: T
    if ~zero < zero {
        // signed: overflow when both operands have one sign and the sum the other
        if (a < 0) == (b < 0) && (s < 0) != (a < 0) {
            return __sat_limit(a, a < 0)
        }
        return s
    }
    if s < a { ~zero } else { s }
}

// a - b of any integer type, limited to the type's range instead of wrapping (unsigned: 0 when
// b > a)
fn sat_sub[T](a: T, b: T) -> T {
    d := a - b
    zero: T
    if ~zero < zero {
        // signed: overflow when the operands have different signs and the difference has b's
        if (a < 0) != (b < 0) && (d < 0) != (a < 0) {
            return __sat_limit(a, a < 0)
        }
        return d
    }
    if b > a { zero } else { d }
}

// the smallest (low) or largest value of the signed integer type of x
fn __sat_limit[T](x: T, low: bool) -> T {
    m: T = 1
    m = m << (sizeof[T]() * 8 - 1)
    if low { m } else { ~m }
}

// exchanges the values that a and b point to
inline fn swap[T](a: *T, b: *T) {
    t := *a
    *a = *b
    *b = t
}

// copies the first min(len(dst), len(src)) elements of src into dst (they may overlap) and
// returns that number
inline fn copy[T](dst: []T, src: []T) -> i64 {
    n := min(len(dst), len(src))
    d := cast[i64](ptr(dst))
    s := cast[i64](ptr(src))
    if d > s && d < s + n * sizeof[T]() {
        // overlapping, the destination after the source (copy(a[1..], a)): from the end
        k := n - 1
        while k >= 0 {
            dst[k] = src[k]
            k -= 1
        }
        return n
    }
    memcopy(ptr(dst), ptr(src), n * sizeof[T]())
    return n
}

// sets every element of a to x
inline fn fill[T](a: []T, x: T) {
    n := len(a)
    if sizeof[T]() == 1 {
        memfill(ptr(a), *cast[*u8](&x), n)
        return
    }
    // (a memory fill starts slowly: worth it from some 64 bytes on)
    if n * sizeof[T]() >= 64 {
        b := __uniform_byte(x)
        if b >= 0 {
            memfill(ptr(a), u8(b), n * sizeof[T]())
            return
        }
        if n * sizeof[T]() >= 512 {
            __fill_doubling(a, x)
            return
        }
    }
    for i in 0..n {
        a[i] = x
    }
}

// the byte that every byte of x is (zero of any type, a fill of 0xFF ...), or -1
fn __uniform_byte[T](x: T) -> i64 {
    p := cast[*u8](&x)
    b := p[0]
    for i in 1..sizeof[T]() {
        if p[i] != b {
            return -1
        }
    }
    return i64(b)
}

// fill of a long slice: a few elements, then copies of what is already filled, doubling in
// length (memory copies of separate ranges)
noinline fn __fill_doubling[T](a: []T, x: T) {
    n := len(a)
    k := min(n, 8)
    for i in 0..k {
        a[i] = x
    }
    sz := sizeof[T]()
    p := cast[i64](ptr(a))
    while k < n {
        c := min(k, n - k)
        memcopy(p + k * sz, p, c * sz)
        k += c
    }
}

// the largest whole number <= x (NaN, infinities and -0.0 stay as they are)
fn floor(x: f64) -> f64 {
    // (x == 0: keeps the sign of -0.0, as C's floor)
    if x != x || x == 0.0 || fabs(x) >= 4503599627370496.0 {
        return x
    }
    t := f64(i64(x))
    if t > x { t - 1.0 } else { t }
}

// the smallest whole number >= x (NaN, infinities and -0.0 stay as they are)
fn ceil(x: f64) -> f64 {
    if x != x || x == 0.0 || fabs(x) >= 4503599627370496.0 {
        return x
    }
    if x < 0.0 && x > -1.0 {
        return -0.0
    }
    t := f64(i64(x))
    if t < x { t + 1.0 } else { t }
}

// ---------- growable vector ----------
// a growable array: vec[T](), vec_of(s) or vec_fill(n, x) make one; `v.items()` is its slice
struct Vec[T] { buf: []T, len: i64 }

// an empty Vec (it allocates on the first push)
fn vec[T]() -> Vec[T] {
    return Vec[T]{buf: mkslice[T](__heap_cur, 0), len: 0}
}

// a Vec holding a copy of the elements of s
fn vec_of[T](s: []T) -> Vec[T] {
    n := len(s)
    buf := mkslice[T](__alloc_raw(__alloc_size(n, sizeof[T]())), n)
    memcopy(ptr(buf), ptr(s), n * sizeof[T]())
    return Vec[T]{buf: buf, len: n}
}

// a Vec of n copies of x
fn vec_fill[T](n: i64, x: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(__alloc_size(n, sizeof[T]())), n)
    fill(buf, x)
    return Vec[T]{buf: buf, len: n}
}

// makes room for n elements in all, so that pushes up to that length do not move the elements
fn reserve[T](v: *Vec[T], n: i64) {
    if n > len(v.buf) {
        if __check_mem == 2 {
            __grow_check(cast[i64](v))
        }
        cap := max(len(v.buf) * 2, max(n, 8))
        // the spare capacity is never read before it is written: no need to zero it
        nb := mkslice[T](__alloc_raw(__alloc_size(cap, sizeof[T]())), cap)
        memcopy(ptr(nb), ptr(v.buf), v.len * sizeof[T]())
        v.buf = nb
    }
}

// appends x; when the Vec is full its elements move to a larger buffer (slices of the old one
// go stale)
fn push[T](v: *Vec[T], x: T) {
    // the common case small enough to inline: room in the buffer (the unsigned compare also
    // sends a negative length to the checked path)
    n := v.len
    if u64(n) < u64(len(v.buf)) {
        *cast[*T](cast[i64](ptr(v.buf)) + n * sizeof[T]()) = x
        v.len = n + 1
        return
    }
    __push_grow(v, x)
}

// push into a full Vec: out of line
noinline fn __push_grow[T](v: *Vec[T], x: T) {
    reserve(v, v.len + 1)
    v.buf[v.len] = x
    v.len += 1
}

// A function `f` with a twin `__at_f`: the compiler turns every call `f(args)` into
// `__at_f(args, "file:line" of the call)`, so that a failure names the caller's line. The
// plain function is what `f` denotes as a function value.

// removes and returns the last element; panics if the Vec is empty
fn pop[T](v: *Vec[T]) -> T {
    return __at_pop(v, "?")
}

fn __at_pop[T](v: *Vec[T], at: str) -> T {
    n := v.len - 1
    if u64(n) < u64(len(v.buf)) {
        v.len = n
        return *cast[*T](cast[i64](ptr(v.buf)) + n * sizeof[T]())
    }
    return __pop_slow(v, at)
}

// pop from an empty (or inconsistent) Vec: the checks, out of line
noinline fn __pop_slow[T](v: *Vec[T], at: str) -> T {
    if v.len == 0 {
        __die("panic: pop from an empty Vec at ", at, "")
    }
    v.len -= 1
    return v.buf[v.len]
}

// the live elements of a Vec as a slice (valid until the next push that grows it)
fn items[T](v: *Vec[T]) -> []T {
    return v.buf[..v.len]
}

// the last element; panics if the Vec is empty
fn last[T](v: *Vec[T]) -> T {
    return __at_last(v, "?")
}

fn __at_last[T](v: *Vec[T], at: str) -> T {
    if v.len <= 0 {
        __assert_fail(at, "last of an empty Vec")
    }
    return v.buf[v.len - 1]
}

fn is_empty[T](v: *Vec[T]) -> bool {
    return v.len == 0
}

// removes every element (the capacity is kept)
fn clear[T](v: *Vec[T]) {
    v.len = 0
}

// shrinks to n elements if it is longer (n must not be negative)
fn truncate[T](v: *Vec[T], n: i64) {
    __at_truncate(v, n, "?")
}

fn __at_truncate[T](v: *Vec[T], n: i64, at: str) {
    if n < 0 {
        __assert_fail(at, "Vec truncate to a negative length")
    }
    if n < v.len {
        v.len = n
    }
}

// grows (with copies of x) or shrinks to exactly n elements
fn resize[T](v: *Vec[T], n: i64, x: T) {
    __at_resize(v, n, x, "?")
}

fn __at_resize[T](v: *Vec[T], n: i64, x: T, at: str) {
    if n < 0 {
        __assert_fail(at, "Vec resize to a negative length")
    }
    reserve(v, n)
    if n > v.len {
        fill(v.buf[v.len..n], x)
    }
    v.len = n
}

// appends a copy of the elements of s (a str is a []u8: `b.extend("text")`)
fn extend[T](v: *Vec[T], s: []T) {
    n := v.len
    k := len(s)
    if k > len(v.buf) - n {
        // (growth out of line)
        __extend_grow(v, k)
    }
    __copy_short(cast[i64](ptr(v.buf)) + n * sizeof[T](), cast[i64](ptr(s)), k * sizeof[T]())
    v.len = n + k
}

noinline fn __extend_grow[T](v: *Vec[T], k: i64) {
    reserve(v, __add_size(v.len, k))
}

// copies n bytes from s to d (ranges that do not overlap): a few bytes one by one, since a
// memory copy takes a while to start
inline fn __copy_short(d: i64, s: i64, n: i64) {
    if n <= 16 {
        for i in 0..n {
            *cast[*u8](d + i) = *cast[*u8](s + i)
        }
    } else {
        memcopy(d, s, n)
    }
}

// inserts x before position i
fn insert[T](v: *Vec[T], i: i64, x: T) {
    __at_insert(v, i, x, "?")
}

fn __at_insert[T](v: *Vec[T], i: i64, x: T, at: str) {
    if i < 0 || i > v.len {
        __assert_fail(at, "Vec insert position out of range")
    }
    push(v, x)
    copy(v.buf[i + 1..v.len], v.buf[i..v.len - 1])
    v.buf[i] = x
}

// removes and returns element i, keeping the order of the rest
fn remove[T](v: *Vec[T], i: i64) -> T {
    return __at_remove(v, i, "?")
}

fn __at_remove[T](v: *Vec[T], i: i64, at: str) -> T {
    if i < 0 || i >= v.len {
        __assert_fail(at, "Vec remove position out of range")
    }
    x := v.buf[i]
    copy(v.buf[i..v.len - 1], v.buf[i + 1..v.len])
    v.len -= 1
    return x
}

// removes and returns element i, moving the last element into its place
fn swap_remove[T](v: *Vec[T], i: i64) -> T {
    return __at_swap_remove(v, i, "?")
}

fn __at_swap_remove[T](v: *Vec[T], i: i64, at: str) -> T {
    if i < 0 || i >= v.len {
        __assert_fail(at, "Vec swap_remove position out of range")
    }
    x := v.buf[i]
    v.len -= 1
    v.buf[i] = v.buf[v.len]
    return x
}

// position of the first element equal to x, or -1
fn index_of[T](s: []T, x: T) -> i64 {
    if sizeof[T]() == 1 && len(s) >= 16 {
        // bytes (u8, i8, bool): equal values are equal bytes
        return __mem_chr(cast[i64](ptr(s)), len(s), *cast[*u8](&x))
    }
    for i, y in s {
        if y == x {
            return i
        }
    }
    return -1
}

// true if an element of s equals x
fn contains[T](s: []T, x: T) -> bool {
    return index_of(s, x) >= 0
}

// true if an element of v equals x
fn contains[T](v: *Vec[T], x: T) -> bool {
    return index_of(v.buf[..v.len], x) >= 0
}

// reverses the order of the elements of s in place
fn reverse[T](s: []T) {
    i := 0
    j := len(s) - 1
    while i < j {
        swap(&s[i], &s[j])
        i += 1
        j -= 1
    }
}

// removes adjacent duplicates (use after sort)
fn dedup[T](v: *Vec[T]) {
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

// keeps the elements x with keep(x), in their order: one pass in place, keep is called once
// per element, first to last (the slots past the new length keep their old contents, as
// with truncate)
fn retain[T](v: *Vec[T], keep: fn(T) -> bool) {
    n := 0
    for x in v.buf[..v.len] {
        if keep(x) {
            v.buf[n] = x
            n += 1
        }
    }
    v.len = n
}

// the same with a context value that is handed to every call of keep
fn retain[T, C](v: *Vec[T], ctx: C, keep: fn(C, T) -> bool) {
    n := 0
    for x in v.buf[..v.len] {
        if keep(ctx, x) {
            v.buf[n] = x
            n += 1
        }
    }
    v.len = n
}

// ---------- hash map that keeps the insertion order ----------
// The entries live in three parallel arrays in the order of their first insertion: keys[e],
// vals[e], tags[e] for e < used (the slices are as long as the capacity; what lies beyond
// `used` is uninitialised). tags[e] is the upper half of the key's hash with the top bit set;
// 0 marks a deleted entry (a hole; `len` counts the live ones). `index` is the open-addressing
// table (linear probing, a power of two long) that finds an entry: the home slot of a key is
// tag & mask; a slot is 0 (free), or e + 1 in the bits of the mask and the tag in the others,
// or mask (its entry was deleted: equal to no tag in the upper bits). The entry arrays hold
// half of len(index) entries, so at least half of the slots are free. When they are full, the
// map is compacted in place if a quarter or more are holes, and grows otherwise.

// a hash map from K to V whose keys() come in the order of first insertion; map[K, V]() makes one
struct Map[K, V] { keys: []K, vals: []V, tags: []u32, index: []u32, len: i64, used: i64 }

// an empty Map (it allocates on the first set)
fn map[K, V]() -> Map[K, V] {
    return Map[K, V]{}
}

// the entry number of k, or -1
fn __map_find[K, V](m: *Map[K, V], k: K) -> i64 {
    n := len(m.index)
    if n == 0 {
        return -1
    }
    mask := u32(n - 1)
    tag := u32(hash(k) >> 32) | 0x8000_0000
    i := tag & mask
    loop {
        // (i <= mask < len(m.index): an unchecked read)
        s := *cast[*u32](cast[i64](ptr(m.index)) + i64(i) * 4)
        if s == 0 {
            return -1
        }
        if (s ^ tag) <= mask {
            e := i64(s & mask) - 1
            if m.keys[e] == k {
                return e
            }
        }
        i = (i + 1) & mask
    }
}

// enters entry e into a table that does not have it
fn __map_place(index: []u32, tag: u32, e: i64) {
    mask := u32(len(index) - 1)
    i := tag & mask
    while index[i] != 0 {
        i = (i + 1) & mask
    }
    index[i] = (tag & ~mask) | u32(e + 1)
}

// the live entries of s, moved to the front of dst (dst may be s)
fn __map_pack[T](dst: []T, s: []T, tags: []u32, used: i64) {
    n := 0
    for e in 0..used {
        if tags[e] != 0 {
            dst[n] = s[e]
            n += 1
        }
    }
}

// makes room for one more entry: removes the holes, in larger arrays unless the holes are a
// quarter of the entries (4 times the size while small: fewer steps for the many maps that
// stay small; twice later: less memory)
fn __map_grow[K, V](m: *Map[K, V]) {
    cap := len(m.index)
    keys := m.keys
    vals := m.vals
    tags := m.tags
    if cap == 0 || m.len * 4 > m.used * 3 {
        cap = if cap < 65536 { max(16, cap * 4) } else { cap * 2 }
        if cap > 0x8000_0000 {
            __die("panic: Map too large", "", "")
        }
        if __check_mem == 2 {
            __grow_check(cast[i64](m))
        }
        n := cap / 2
        // (the spare capacity is never read before it is written)
        keys = mkslice[K](__alloc_raw(__alloc_size(n, sizeof[K]())), n)
        vals = mkslice[V](__alloc_raw(__alloc_size(n, sizeof[V]())), n)
        tags = mkslice[u32](__alloc_raw(n * 4), n)
        m.index = alloc[u32](cap)
    } else {
        memfill(ptr(m.index), 0, cap * 4)
    }
    if m.len == m.used {
        if ptr(keys) != ptr(m.keys) {
            memcopy(ptr(keys), ptr(m.keys), m.used * sizeof[K]())
            memcopy(ptr(vals), ptr(m.vals), m.used * sizeof[V]())
            memcopy(ptr(tags), ptr(m.tags), m.used * 4)
        }
    } else {
        __map_pack(keys, m.keys, m.tags, m.used)
        __map_pack(vals, m.vals, m.tags, m.used)
        __map_pack(tags, m.tags, m.tags, m.used)
    }
    m.keys = keys
    m.vals = vals
    m.tags = tags
    m.used = m.len
    for e in 0..m.used {
        __map_place(m.index, tags[e], e)
    }
}

// stores v for k, replacing the value of a key that is present (a new key comes last in keys())
fn set[K, V](m: *Map[K, V], k: K, v: V) {
    tag := u32(hash(k) >> 32) | 0x8000_0000
    slot := -1              // where a new entry goes: the first reusable slot on the way
    if len(m.index) != 0 {
        mask := u32(len(m.index) - 1)
        i := tag & mask
        loop {
            // (i <= mask < len(m.index): an unchecked read)
            s := *cast[*u32](cast[i64](ptr(m.index)) + i64(i) * 4)
            if s == 0 {
                if slot < 0 {
                    slot = i64(i)
                }
                break
            }
            if (s ^ tag) <= mask {
                e := i64(s & mask) - 1
                if m.keys[e] == k {
                    m.vals[e] = v
                    return
                }
            } else if s == mask && slot < 0 {
                slot = i64(i)
            }
            i = (i + 1) & mask
        }
    }
    e := m.used
    if e == len(m.keys) {
        __map_grow(m)
        e = m.used
        slot = -1
    }
    m.keys[e] = k
    m.vals[e] = v
    m.tags[e] = tag
    m.used = e + 1
    m.len += 1
    if slot < 0 {
        __map_place(m.index, tag, e)
    } else {
        m.index[slot] = (tag & ~u32(len(m.index) - 1)) | u32(e + 1)
    }
}

// (the value stored for k, true), or (the zero value, false) if k is missing
fn get[K, V](m: *Map[K, V], k: K) -> (V, bool) {
    e := __map_find(m, k)
    if e < 0 {
        zero: V
        return (zero, false)
    }
    return (m.vals[e], true)
}

// the value stored for k, or `default` when k is missing
fn get_or[K, V](m: *Map[K, V], k: K, default: V) -> V {
    e := __map_find(m, k)
    if e < 0 {
        return default
    }
    return m.vals[e]
}

// true if a value is stored for k
fn has[K, V](m: *Map[K, V], k: K) -> bool {
    return __map_find(m, k) >= 0
}

// removes k (false if it was missing): its entry becomes a hole, its slot stays taken
fn del[K, V](m: *Map[K, V], k: K) -> bool {
    n := len(m.index)
    if n == 0 {
        return false
    }
    mask := u32(n - 1)
    tag := u32(hash(k) >> 32) | 0x8000_0000
    i := tag & mask
    loop {
        // (i <= mask < len(m.index): an unchecked read)
        s := *cast[*u32](cast[i64](ptr(m.index)) + i64(i) * 4)
        if s == 0 {
            return false
        }
        if (s ^ tag) <= mask {
            e := i64(s & mask) - 1
            if m.keys[e] == k {
                m.index[i] = mask
                m.tags[e] = 0
                m.len -= 1
                return true
            }
        }
        i = (i + 1) & mask
    }
}

// removes every entry
fn clear[K, V](m: *Map[K, V]) {
    *m = Map[K, V]{}
}

// a pointer to the value stored for k (nil if k is missing), to change it in place; valid
// until the next `set` of a new key
fn ptr[K, V](m: *Map[K, V], k: K) -> *V {
    e := __map_find(m, k)
    if e < 0 {
        return nil
    }
    return &m.vals[e]
}

// a new slice of the live entries of s
fn __map_live[K, V, T](m: *Map[K, V], s: []T) -> []T {
    out := mkslice[T](__alloc_raw(__alloc_size(m.len, sizeof[T]())), m.len)
    if m.len == m.used {
        memcopy(ptr(out), ptr(s), m.len * sizeof[T]())
    } else {
        __map_pack(out, s, m.tags, m.used)
    }
    return out
}

// all keys, in the order in which they were first inserted (a new slice)
fn keys[K, V](m: *Map[K, V]) -> []K {
    return __map_live(m, m.keys)
}

// all values, in the order of keys()
fn values[K, V](m: *Map[K, V]) -> []V {
    return __map_live(m, m.vals)
}

// print(m): {key: value, key: value} in insertion order
fn __put_map[K, V](m: *Map[K, V]) {
    putc('{')
    n := 0
    for e in 0..m.used {
        if m.tags[e] != 0 {
            if n > 0 {
                __put_str(", ")
            }
            put(m.keys[e])
            __put_str(": ")
            put(m.vals[e])
            n += 1
        }
    }
    putc('}')
}

// ---------- clone ----------
// The builtin `clone(x)` copies x member by member and calls these for the parts that own
// storage. All copies are allocated from the arena in use.

// a slice of elements that own nothing: one allocation, one memory copy
fn __clone_plain[T](s: []T) -> []T {
    n := len(s)
    out := mkslice[T](__alloc_raw(__alloc_size(n, sizeof[T]())), n)
    memcopy(ptr(out), ptr(s), n * sizeof[T]())
    return out
}

fn __clone_slice[T](s: []T) -> []T {
    n := len(s)
    out := mkslice[T](__alloc_raw(__alloc_size(n, sizeof[T]())), n)
    for i in 0..n {
        out[i] = clone(s[i])
    }
    return out
}

// the elements of an array, cloned into another array of the same length
fn __clone_elems[T](dst: []T, src: []T) {
    for i in 0..len(src) {
        dst[i] = clone(src[i])
    }
}

// a Vec with the same live elements; the spare capacity (uninitialised memory) is not copied
fn __clone_vec_plain[T](v: Vec[T]) -> Vec[T] {
    return Vec[T]{buf: __clone_plain(v[..]), len: v.len}
}

fn __clone_vec[T](v: Vec[T]) -> Vec[T] {
    return Vec[T]{buf: __clone_slice(v[..]), len: v.len}
}

// the keys or values of a Map with the same capacity: only live entries hold a value
// (`plain`: T owns no storage)
fn __clone_slots[T](s: []T, tags: []u32, used: i64, plain: bool) -> []T {
    out := mkslice[T](__alloc_raw(__alloc_size(len(s), sizeof[T]())), len(s))
    if plain {
        memcopy(ptr(out), ptr(s), used * sizeof[T]())
    } else {
        for e in 0..used {
            if tags[e] != 0 {
                out[e] = clone(s[e])
            }
        }
    }
    return out
}

fn __clone_map[K, V](m: *Map[K, V], kplain: bool, vplain: bool) -> Map[K, V] {
    return Map[K, V]{
        keys: __clone_slots(m.keys, m.tags, m.used, kplain),
        vals: __clone_slots(m.vals, m.tags, m.used, vplain),
        tags: __clone_slots(m.tags, m.tags, m.used, true),
        index: __clone_plain(m.index),
        len: m.len,
        used: m.used,
    }
}

// ---------- sorting ----------
// quicksort; after `depth` levels of bad pivots the rest of the range is heap-sorted, so that
// no input takes more than n log n steps
fn __sort_range[T](a: []T, lo: i64, hi: i64, depth: i64) {
    while hi - lo > 16 {
        if depth == 0 {
            __heap_sort(a, lo, hi)
            return
        }
        depth -= 1
        p := a[lo + (hi - lo) / 2]
        i := lo
        j := hi
        while i <= j {
            while a[i] < p {
                i += 1
            }
            while p < a[j] {
                j -= 1
            }
            if i <= j {
                swap(&a[i], &a[j])
                i += 1
                j -= 1
            }
        }
        // recurse into the smaller half, loop on the larger one
        if j - lo < hi - i {
            __sort_range(a, lo, j, depth)
            lo = i
        } else {
            __sort_range(a, i, hi, depth)
            hi = j
        }
    }
    for i in lo + 1..=hi {
        x := a[i]
        j := i - 1
        while j >= lo && x < a[j] {
            a[j + 1] = a[j]
            j -= 1
        }
        a[j + 1] = x
    }
}

// a[lo..=hi] sorted with a heap
fn __heap_sort[T](a: []T, lo: i64, hi: i64) {
    n := hi - lo + 1
    for r in 0..n / 2 {
        __sift_down(a, lo, n / 2 - 1 - r, n)
    }
    end := n - 1
    while end > 0 {
        swap(&a[lo], &a[lo + end])
        __sift_down(a, lo, 0, end)
        end -= 1
    }
}

fn __sift_down[T](a: []T, lo: i64, root: i64, n: i64) {
    loop {
        c := 2 * root + 1
        if c >= n {
            return
        }
        if c + 1 < n && a[lo + c] < a[lo + c + 1] {
            c += 1
        }
        if !(a[lo + root] < a[lo + c]) {
            return
        }
        swap(&a[lo + root], &a[lo + c])
        root = c
    }
}

// ascending sort of numbers (anything comparable with `<`)
fn sort[T](a: []T) {
    depth := 0
    k := len(a)
    while k > 0 {
        depth += 2
        k = k >> 1
    }
    __sort_range(a, 0, len(a) - 1, depth)
}

// ascending byte order (as `cmp` orders strings)
fn sort(a: []str) {
    sort_by(a, fn(x: str, y: str) -> bool { cmp(x, y) < 0 })
}

// stable merge sort with a user-supplied "less than"
fn sort_by[T](a: []T, less: fn(T, T) -> bool) {
    n := len(a)
    if n < 2 {
        return
    }
    tmp := alloc[T](n)
    src := a
    dst := tmp
    width := 1
    while width < n {
        lo := 0
        while lo < n {
            mid := min(lo + width, n)
            hi := min(lo + 2 * width, n)
            i := lo
            j := mid
            k := lo
            while i < mid && j < hi {
                if less(src[j], src[i]) {
                    dst[k] = src[j]
                    j += 1
                } else {
                    dst[k] = src[i]
                    i += 1
                }
                k += 1
            }
            while i < mid {
                dst[k] = src[i]
                i += 1
                k += 1
            }
            while j < hi {
                dst[k] = src[j]
                j += 1
                k += 1
            }
            lo = hi
        }
        t := src
        src = dst
        dst = t
        width = width * 2
    }
    if ptr(src) != ptr(a) {
        copy(a, src)
    }
}

// the same with a context value that is handed to every comparison (the state a
// comparison needs, since a function value cannot refer to local variables)
fn sort_by[T, C](a: []T, ctx: C, less: fn(C, T, T) -> bool) {
    n := len(a)
    if n < 2 {
        return
    }
    tmp := alloc[T](n)
    src := a
    dst := tmp
    width := 1
    while width < n {
        lo := 0
        while lo < n {
            mid := min(lo + width, n)
            hi := min(lo + 2 * width, n)
            i := lo
            j := mid
            k := lo
            while i < mid && j < hi {
                if less(ctx, src[j], src[i]) {
                    dst[k] = src[j]
                    j += 1
                } else {
                    dst[k] = src[i]
                    i += 1
                }
                k += 1
            }
            while i < mid {
                dst[k] = src[i]
                i += 1
                k += 1
            }
            while j < hi {
                dst[k] = src[j]
                j += 1
                k += 1
            }
            lo = hi
        }
        t := src
        src = dst
        dst = t
        width = width * 2
    }
    if ptr(src) != ptr(a) {
        copy(a, src)
    }
}

// ---------- strings ----------
// a new string: a followed by b (fmt(...) joins any number of values)
fn concat(a: str, b: str) -> str {
    out := alloc[u8](__add_size(len(a), len(b)))
    memcopy(ptr(out), ptr(a), len(a))
    memcopy(cast[i64](ptr(out)) + len(a), ptr(b), len(b))
    return out
}

// index of the first occurrence of sub in s, or -1
fn find(s: str, sub: str) -> i64 {
    n := len(s)
    m := len(sub)
    if m == 0 {
        return 0
    }
    if m > n {
        return -1
    }
    if m == 1 {
        return __mem_chr(cast[i64](ptr(s)), n, sub[0])
    }
    return __find_words(s, sub)
}

// find for 2 <= len(sub) <= len(s): the positions whose first and last byte match those of
// sub, 8 positions per step (see "bytes, a word at a time"), then a comparison of the bytes
// between; when it may have compared too many bytes in vain, as with "aaa...aba" in
// "aaaa...", the rest of s is searched in linear time: __kmp_find
noinline fn __find_words(s: str, sub: str) -> i64 {
    n := len(s)
    m := len(sub)
    p := cast[i64](ptr(s))
    q := cast[i64](ptr(sub))
    c0 := sub[0]
    c1 := sub[m - 1]
    first := u64(c0) * 0x0101010101010101
    last := u64(c1) * 0x0101010101010101
    work := 0
    i := 0
    while i + m + 7 <= n {
        z := __zero_bytes(__ld64(p + i) ^ first) & __zero_bytes(__ld64(p + i + m - 1) ^ last)
        while z != 0 {
            k := i + __low_byte(z)
            if __mem_eq_k(p + k + 1, q + 1, m - 2) {
                return k
            }
            // (at most m bytes compared)
            work += m
            if work > 8 * k + 1024 {
                return __kmp_find(s, sub, k + 1, false)
            }
            z &= z - 1
        }
        i += 8
    }
    while i + m <= n {
        if s[i] == c0 && s[i + m - 1] == c1 {
            if __mem_eq_k(p + i + 1, q + 1, m - 2) {
                return i
            }
            work += m
            if work > 8 * i + 1024 {
                return __kmp_find(s, sub, i + 1, false)
            }
        }
        i += 1
    }
    return -1
}

// Knuth-Morris-Pratt: the first occurrence of sub in s at `from` or later, or -1; with `rev`
// both strings are read backwards (s[len(s) - 1 - i]): the result is then the start of the
// last occurrence that ends at len(s) - from or earlier, counted from the front
fn __kmp_find(s: str, sub: str, from: i64, rev: bool) -> i64 {
    n := len(s)
    m := len(sub)
    mk := mark()
    // border[k]: length of the longest proper border of the first k + 1 bytes of sub
    border := alloc[i64](m)
    j := 0
    for k in 1..m {
        ck := if rev { sub[m - 1 - k] } else { sub[k] }
        while j > 0 && ck != (if rev { sub[m - 1 - j] } else { sub[j] }) {
            j = border[j - 1]
        }
        if ck == (if rev { sub[m - 1 - j] } else { sub[j] }) {
            j += 1
        }
        border[k] = j
    }
    r := -1
    j = 0
    for i in from..n {
        ci := if rev { s[n - 1 - i] } else { s[i] }
        while j > 0 && ci != (if rev { sub[m - 1 - j] } else { sub[j] }) {
            j = border[j - 1]
        }
        if ci == (if rev { sub[m - 1 - j] } else { sub[j] }) {
            j += 1
        }
        if j == m {
            r = if rev { n - 1 - i } else { i - m + 1 }
            break
        }
    }
    // the table was the last allocation: give it back
    release(mk)
    return r
}

// the first occurrence that starts at `from` or later; `from` is checked like s[from..]
fn find(s: str, sub: str, from: i64) -> i64 {
    return __at_find(s, sub, from, "?")
}

fn __at_find(s: str, sub: str, from: i64, at: str) -> i64 {
    if from < 0 || from > len(s) {
        __bounds_fail(at)
    }
    i := find(s[from..], sub)
    if i < 0 {
        return -1
    }
    return from + i
}

// index of the first byte at `from` or later that is one of `chars`, or -1
fn find_any(s: str, chars: str, from: i64) -> i64 {
    return __at_find_any(s, chars, from, "?")
}

fn __at_find_any(s: str, chars: str, from: i64, at: str) -> i64 {
    if from < 0 || from > len(s) {
        __bounds_fail(at)
    }
    for i in from..len(s) {
        if contains(chars, s[i]) {
            return i
        }
    }
    return -1
}

// index of the last occurrence of sub in s, or -1
fn rfind(s: str, sub: str) -> i64 {
    n := len(s)
    m := len(sub)
    if m == 0 {
        return n
    }
    c := sub[m - 1]
    work := 0
    i := n - m
    while i >= 0 {
        if s[i + m - 1] == c {
            if s[i..i + m] == sub {
                return i
            }
            work += m
            if work > 8 * (n - m - i) + 1024 {
                return __kmp_find(s, sub, n - m - i, true)
            }
        }
        i -= 1
    }
    return -1
}

// how often sub occurs in s (occurrences that do not overlap, counted from the left)
fn count(s: str, sub: str) -> i64 {
    return __at_count(s, sub, "?")
}

fn __at_count(s: str, sub: str, at: str) -> i64 {
    if len(sub) == 0 {
        __panic(at, "count: empty substring")
    }
    n := 0
    i := find(s, sub)
    while i >= 0 {
        n += 1
        i = __at_find(s, sub, i + len(sub), at)
    }
    return n
}

// s with every occurrence of old (left to right, not overlapping) replaced by new
fn replace(s: str, old: str, new: str) -> str {
    return __at_replace(s, old, new, "?")
}

fn __at_replace(s: str, old: str, new: str, at: str) -> str {
    if len(old) == 0 {
        __panic(at, "replace: empty substring")
    }
    cnt := __at_count(s, old, at)
    out := alloc[u8](if len(new) >= len(old) { __add_size(len(s), __alloc_size(cnt, len(new) - len(old))) } else { len(s) - cnt * (len(old) - len(new)) })
    k := 0
    start := 0
    loop {
        i := __at_find(s, old, start, at)
        end := if i < 0 { len(s) } else { i }
        memcopy(cast[i64](ptr(out)) + k, cast[i64](ptr(s)) + start, end - start)
        k += end - start
        if i < 0 {
            return out
        }
        memcopy(cast[i64](ptr(out)) + k, ptr(new), len(new))
        k += len(new)
        start = i + len(old)
    }
}

// n copies of s (none if n <= 0)
fn repeat(s: str, n: i64) -> str {
    if n <= 0 || len(s) == 0 {
        return ""
    }
    total := __alloc_size(n, len(s))
    out := alloc[u8](total)
    // one copy of s, then copies of what is written, doubling in length
    p := cast[i64](ptr(out))
    memcopy(p, ptr(s), len(s))
    k := len(s)
    while k < total {
        c := min(k, total - k)
        memcopy(p + k, p, c)
        k += c
    }
    return out
}

fn starts_with(s: str, p: str) -> bool {
    return len(s) >= len(p) && s[..len(p)] == p
}

fn ends_with(s: str, p: str) -> bool {
    return len(s) >= len(p) && s[len(s) - len(p)..] == p
}

// white space: ' ', '\t', '\n', '\r', vertical tab, form feed
fn is_space(c: u8) -> bool {
    return c == ' ' || (c >= '\t' && c <= '\r')
}

// views of s without white space at both ends / at the start / at the end
fn trim(s: str) -> str {
    return trim_right(trim_left(s))
}

// s without white space at the start (a view)
fn trim_left(s: str) -> str {
    lo := 0
    while lo < len(s) && is_space(s[lo]) {
        lo += 1
    }
    return s[lo..]
}

// s without white space at the end (a view)
fn trim_right(s: str) -> str {
    hi := len(s)
    while hi > 0 && is_space(s[hi - 1]) {
        hi -= 1
    }
    return s[..hi]
}

// the same for the bytes of `chars` instead of white space
fn trim(s: str, chars: str) -> str {
    return trim_right(trim_left(s, chars), chars)
}

// s without the bytes of `chars` at the start (a view)
fn trim_left(s: str, chars: str) -> str {
    lo := 0
    while lo < len(s) && contains(chars, s[lo]) {
        lo += 1
    }
    return s[lo..]
}

// s without the bytes of `chars` at the end (a view)
fn trim_right(s: str, chars: str) -> str {
    hi := len(s)
    while hi > 0 && contains(chars, s[hi - 1]) {
        hi -= 1
    }
    return s[..hi]
}

// pieces of s between occurrences of sep (views into s, no copying)
fn split(s: str, sep: u8) -> []str {
    p := cast[i64](ptr(s))
    n := __mem_count(p, len(s), sep) + 1
    out := alloc[str](n)
    start := 0
    for k in 0..n - 1 {
        i := start + __mem_chr(p + start, len(s) - start, sep)
        out[k] = s[start..i]
        start = i + 1
    }
    out[n - 1] = s[start..]
    return out
}

// pieces of s between occurrences of sep (left to right, not overlapping)
fn split(s: str, sep: str) -> []str {
    return __at_split(s, sep, "?")
}

fn __at_split(s: str, sep: str, at: str) -> []str {
    if len(sep) == 0 {
        __panic(at, "split: empty separator")
    }
    out := alloc[str](__at_count(s, sep, at) + 1)
    k := 0
    start := 0
    loop {
        i := __at_find(s, sep, start, at)
        if i < 0 {
            out[k] = s[start..]
            return out
        }
        out[k] = s[start..i]
        k += 1
        start = i + len(sep)
    }
}

// the pieces of s between runs of white space (views; none is empty)
fn fields(s: str) -> []str {
    n := 0
    for i, c in s {
        if !is_space(c) && (i == 0 || is_space(s[i - 1])) {
            n += 1
        }
    }
    out := alloc[str](n)
    k := 0
    i := 0
    while k < n {
        while is_space(s[i]) {
            i += 1
        }
        start := i
        while i < len(s) && !is_space(s[i]) {
            i += 1
        }
        out[k] = s[start..i]
        k += 1
    }
    return out
}

// the lines of s without their '\n' (views; a '\r' before it stays): "a\nb\n" gives "a", "b"
fn lines(s: str) -> []str {
    if ends_with(s, "\n") {
        return split(s[..len(s) - 1], '\n')
    }
    return split(s, '\n')
}

// lexicographic comparison: negative, zero or positive
fn cmp(a: str, b: str) -> i64 {
    n := min(len(a), len(b))
    i := __mem_diff(cast[i64](ptr(a)), cast[i64](ptr(b)), n)
    if i < n {
        return i64(a[i]) - i64(b[i])
    }
    return len(a) - len(b)
}

// decimal digits with an optional '+' or '-', nothing else (no spaces, no '_'); (0, false) if
// s is not that or does not fit in an i64
fn parse_i64(s: str) -> (i64, bool) {
    v, ok := __parse_int(s, 10, false)
    return (i64(v), ok)
}

// an integer in another base (2..36; digits beyond 9 are letters of either case). Base 0: the
// text says it with 0x, 0b or 0o after the sign, and is decimal without one. With a base
// given, a prefix is not accepted.
fn parse_i64(s: str, base: i64) -> (i64, bool) {
    return __at_parse_i64(s, base, "?")
}

fn __at_parse_i64(s: str, base: i64, at: str) -> (i64, bool) {
    if base != 0 && (base < 2 || base > 36) {
        __panic(at, "parse_i64: the base must be 0 or 2..36")
    }
    v, ok := __parse_int(s, base, false)
    return (i64(v), ok)
}

// the same conventions for the whole range of u64 (0 ..= 2^64 - 1): an optional '+', no '-'
fn parse_u64(s: str) -> (u64, bool) {
    return __parse_int(s, 10, true)
}

// a u64 in another base, as parse_i64(s, base) reads it (no '-')
fn parse_u64(s: str, base: i64) -> (u64, bool) {
    return __at_parse_u64(s, base, "?")
}

fn __at_parse_u64(s: str, base: i64, at: str) -> (u64, bool) {
    if base != 0 && (base < 2 || base > 36) {
        __panic(at, "parse_u64: the base must be 0 or 2..36")
    }
    return __parse_int(s, base, true)
}

// parse_i64 (the bits of the i64) or, if unsigned, parse_u64; (0, false) for bad text or a
// value out of range
fn __parse_int(s: str, base: i64, unsigned: bool) -> (u64, bool) {
    n := len(s)
    i := 0
    neg := false
    if n > 0 && (s[0] == '-' || s[0] == '+') {
        neg = s[0] == '-'
        if neg && unsigned {
            return (0, false)
        }
        i = 1
    }
    if base == 0 {
        base = 10
        if i + 1 < n && s[i] == '0' {
            p := s[i + 1] | 0x20
            base = if p == 'x' { 16 } else if p == 'b' { 2 } else if p == 'o' { 8 } else { 10 }
            if base != 10 {
                i += 2
            }
        }
    }
    if i == n {
        return (0, false)
    }
    v: u64 = 0
    // the largest magnitude: 2^63 - 1, or 2^63 after a minus sign, or 2^64 - 1 unsigned
    limit: u64 = if unsigned { 0xFFFF_FFFF_FFFF_FFFF } else if neg { 0x8000_0000_0000_0000 } else { 0x7FFF_FFFF_FFFF_FFFF }
    b := u64(base)
    q := limit / b
    r := limit % b
    while i < n {
        c := s[i]
        d: u64 = 99
        if c >= '0' && c <= '9' {
            d = u64(c - '0')
        } else if (c | 0x20) >= 'a' && (c | 0x20) <= 'z' {
            d = u64((c | 0x20) - 'a') + 10
        }
        if d >= b || v > q || (v == q && d > r) {
            return (0, false)
        }
        v = v * b + d
        i += 1
    }
    if neg {
        return (0 - v, true)
    }
    return (v, true)
}

// ---- exact decimal to binary conversion: big integers as little-endian u32 limbs ----
const __BIG_LIMBS = 224

fn __big_mul_small(a: []u32, n: i64, k: u32) -> i64 {
    carry: u64 = 0
    for i in 0..n {
        t := u64(a[i]) * u64(k) + carry
        a[i] = u32(t)
        carry = t >> 32
    }
    if carry != 0 {
        a[n] = u32(carry)
        n += 1
    }
    return n
}

fn __big_add_small(a: []u32, n: i64, k: u32) -> i64 {
    carry: u64 = u64(k)
    i := 0
    while carry != 0 {
        if i == n {
            a[n] = 0
            n += 1
        }
        t := u64(a[i]) + carry
        a[i] = u32(t)
        carry = t >> 32
        i += 1
    }
    return n
}

fn __big_mul_pow10(a: []u32, n: i64, e: i64) -> i64 {
    while e >= 9 {
        n = __big_mul_small(a, n, 1000000000)
        e -= 9
    }
    k: u32 = 1
    while e > 0 {
        k = k * 10
        e -= 1
    }
    if k != 1 {
        n = __big_mul_small(a, n, k)
    }
    return n
}

fn __big_shl(a: []u32, n: i64, bits: i64) -> i64 {
    if n == 0 || bits == 0 {
        return n
    }
    words := bits >> 5
    sh := u32(bits & 31)
    i := n - 1
    if sh != 0 {
        a[n + words] = a[n - 1] >> (32 - sh)
    }
    while i >= 0 {
        lo := if i > 0 && sh != 0 { a[i - 1] >> (32 - sh) } else { u32(0) }
        a[i + words] = (a[i] << sh) | lo
        i -= 1
    }
    fill(a[..words], 0)
    n += words
    if sh != 0 && a[n] != 0 {
        n += 1
    }
    return n
}

fn __big_cmp(a: []u32, an: i64, b: []u32, bn: i64) -> i64 {
    if an != bn {
        return if an < bn { -1 } else { 1 }
    }
    i := an - 1
    while i >= 0 {
        if a[i] != b[i] {
            return if a[i] < b[i] { -1 } else { 1 }
        }
        i -= 1
    }
    return 0
}

// compares the decimal value num * 10^e10 (num: n limbs, already multiplied by 10^e10 when
// e10 > 0) with mm * 2^q
fn __dec_cmp_bin(num: []u32, n: i64, e10: i64, mm: u64, q: i64) -> i64 {
    a: [__BIG_LIMBS]u32
    b: [__BIG_LIMBS]u32
    copy(a[..n], num[..n])
    an := n
    b[0] = u32(mm)
    b[1] = u32(mm >> 32)
    bn := if b[1] != 0 { 2 } else { if b[0] != 0 { 1 } else { 0 } }
    if e10 < 0 {
        bn = __big_mul_pow10(b[..], bn, -e10)
    }
    if q >= 0 {
        bn = __big_shl(b[..], bn, q)
    } else {
        an = __big_shl(a[..], an, -q)
    }
    return __big_cmp(a[..], an, b[..], bn)
}

// decimal text to the nearest f64 (ties to even), exactly as a C compiler reads a literal:
// [+-] digits [. digits] [e [+-] digits]; (0, false) if s is not a number
fn parse_f64(s: str) -> (f64, bool) {
    num: [__BIG_LIMBS]u32
    v, ok, _, _ := __parse_dec(s, num[..])
    return (v, ok)
}

// decimal text to the nearest f32 (ties to even), rounded once from the text: the nearest f64
// can only mislead when it lies exactly halfway between two f32s, and then the exact decimal
// value decides
fn parse_f32(s: str) -> (f32, bool) {
    num: [__BIG_LIMBS]u32
    v, ok, nn, exp10 := __parse_dec(s, num[..])
    r := f32(v)
    if !ok || nn == 0 || f64(r) == v || v != v {
        return (r, ok)
    }
    // lo: the largest f32 below |v|, hi: the next one (2^128 above the largest finite f32)
    av := fabs(v)
    lb := cast[u32](f32(av))
    if f64(cast[f32](lb)) > av {
        lb -= 1
    }
    lo := f64(cast[f32](lb))
    hi := if lb + 1 == 0x7F800000 { cast[f64](u64(0x47F0000000000000)) } else { f64(cast[f32](lb + 1)) }
    if av != (lo + hi) * 0.5 {
        return (r, true)
    }
    m, e, _ := __f64_parts(av)
    c := __dec_cmp_bin(num[..], nn, exp10, m, e)
    if c == 0 {
        return (r, true)
    }
    x := cast[f32](if c > 0 { lb + 1 } else { lb })
    return (if v < 0.0 { -x } else { x }, true)
}

// parse_f64 with the digits as a big integer: (value, ok, nn, exp10) where num[..nn] * 10^exp10
// is the exact value (num already multiplied when exp10 > 0); nn is 0 for zero, overflow,
// underflow and errors
fn __parse_dec(s: str, num: []u32) -> (f64, bool, i64, i64) {
    n := len(s)
    i := 0
    neg := false
    if n > 0 && (s[0] == '-' || s[0] == '+') {
        neg = s[0] == '-'
        i = 1
    }
    // significant digits as a big integer (at most 800 are kept; more only set a sticky digit)
    nn := 0
    mant: u64 = 0
    digits := 0
    mdigits := 0
    exp10 := 0
    mexp := 0
    seen := false
    sticky := false
    frac := false
    loop {
        if i < n && s[i] == '.' && !frac {
            frac = true
            i += 1
            continue
        }
        if i >= n || s[i] < '0' || s[i] > '9' {
            break
        }
        d := u32(s[i] - '0')
        seen = true
        if digits < 800 {
            if digits > 0 || d != 0 {
                nn = __big_mul_small(num[..], nn, 10)
                nn = __big_add_small(num[..], nn, d)
                digits += 1
            }
            if frac {
                exp10 -= 1
            }
        } else {
            sticky = sticky || d != 0
            if !frac {
                exp10 += 1
            }
        }
        if mdigits < 19 {
            mant = mant * 10 + u64(d)
            if mant != 0 {
                mdigits += 1
            }
            if frac {
                mexp -= 1
            }
        } else if !frac {
            mexp += 1
        }
        i += 1
    }
    if !seen {
        return (0.0, false, 0, 0)
    }
    if i < n && (s[i] == 'e' || s[i] == 'E') {
        i += 1
        eneg := false
        if i < n && (s[i] == '-' || s[i] == '+') {
            eneg = s[i] == '-'
            i += 1
        }
        if i == n {
            return (0.0, false, 0, 0)
        }
        e := 0
        while i < n && s[i] >= '0' && s[i] <= '9' {
            // saturates far beyond any digit count a string can have (no overflow)
            if e < 100_000_000_000_000_000 {
                e = e * 10 + i64(s[i] - '0')
            }
            i += 1
        }
        exp10 += if eneg { -e } else { e }
        mexp += if eneg { -e } else { e }
    }
    if i != n {
        return (0.0, false, 0, 0)
    }
    inf := cast[f64](u64(0x7FF0000000000000))
    if nn == 0 {
        return (if neg { -0.0 } else { 0.0 }, true, 0, 0)
    }
    if digits + exp10 > 310 {
        return (if neg { -inf } else { inf }, true, 0, 0)
    }
    if digits + exp10 < -326 {
        return (if neg { -0.0 } else { 0.0 }, true, 0, 0)
    }
    if sticky {
        // the dropped digits only matter as "a little more": one extra non-zero digit
        nn = __big_mul_small(num[..], nn, 10)
        nn = __big_add_small(num[..], nn, 1)
        exp10 -= 1
    }
    if exp10 > 0 {
        nn = __big_mul_pow10(num[..], nn, exp10)
    }
    // a first guess in floating point (within a few units in the last place)
    x := f64(mant)
    e := if mexp < 0 { -mexp } else { mexp }
    while e > 0 {
        step := if e > 300 { 300 } else { e }
        scale: f64 = 1.0
        p: f64 = 10.0
        k := step
        while k > 0 {
            if k & 1 == 1 {
                scale = scale * p
            }
            p = p * p
            k = k >> 1
        }
        x = if mexp < 0 { x / scale } else { x * scale }
        e -= step
    }
    bits: u64 = cast[u64](x)
    if bits >= 0x7FF0000000000000 {
        bits = 0x7FEFFFFFFFFFFFFF
    }
    // correct the guess: move while the exact value lies beyond the midpoint to a neighbour
    loop {
        ex := i64(bits >> 52)
        fr := bits & 0xFFFFFFFFFFFFF
        m := if ex == 0 { fr } else { fr | (u64(1) << 52) }
        q := if ex == 0 { -1074 } else { ex - 1075 }
        hi := __dec_cmp_bin(num[..], nn, exp10, 2 * m + 1, q - 1)
        if hi > 0 || (hi == 0 && m & 1 == 1) {
            bits += 1
            if bits >= 0x7FF0000000000000 {
                break
            }
            if hi == 0 {
                break
            }
            continue
        }
        if hi == 0 || m == 0 {
            break
        }
        lo := 0
        if fr == 0 && ex > 1 {
            // the double below a power of two is only half as far away
            lo = __dec_cmp_bin(num[..], nn, exp10, 4 * m - 1, q - 2)
        } else {
            lo = __dec_cmp_bin(num[..], nn, exp10, 2 * m - 1, q - 1)
        }
        if lo < 0 || (lo == 0 && m & 1 == 1) {
            bits -= 1
            if lo == 0 {
                break
            }
            continue
        }
        break
    }
    r := cast[f64](bits)
    return (if neg { -r } else { r }, true, nn, exp10)
}

// ---------- files and arguments ----------
fn __cstr(s: str) -> i64 {
    p := __alloc(len(s) + 1)
    memcopy(p, ptr(s), len(s))
    return p
}

// opens path for reading or (created or emptied) for writing; a path with a NUL byte would
// name another file: EINVAL
fn __open(path: str, write: bool) -> i64 {
    if index_of(path, 0) >= 0 {
        return __io_result(-22)
    }
    return __io_result(__os_open(cast[*u8](__cstr(path)), write))
}

// the error number of the most recent failed file operation of this thread (0 after a success)
__tls_io_errno: i64

// records the outcome of a system call: a negative result is `-errno`; returns `r`
fn __io_result(r: i64) -> i64 {
    if r < 0 {
        __tls_io_errno = -r
    } else {
        __tls_io_errno = 0
    }
    return r
}

// The OS error number (Linux errno) of the most recent failed file operation of the library
// (`read_file`, `write_file`, `read_all`, and the file functions of std.asset) in this thread;
// 0 if the most recent one succeeded. Read it right after the call that returned `false`.
fn io_error() -> i64 {
    return __tls_io_errno
}

// a short text for an OS error number, e.g. for `io_error()`
fn error_text(e: i64) -> str {
    match e {
        0 => "no error"
        1 => "operation not permitted"
        2 => "no such file or directory"
        3 => "no such process"
        4 => "interrupted system call"
        5 => "input/output error"
        6 => "no such device or address"
        7 => "argument list too long"
        8 => "exec format error"
        9 => "bad file descriptor"
        10 => "no child processes"
        11 => "resource temporarily unavailable"
        12 => "out of memory"
        13 => "permission denied"
        16 => "device or resource busy"
        17 => "file exists"
        18 => "cross-device link"
        19 => "no such device"
        20 => "not a directory"
        21 => "is a directory"
        22 => "invalid argument"
        23 => "too many open files in system"
        24 => "too many open files"
        26 => "text file busy"
        27 => "file too large"
        28 => "no space left on device"
        29 => "illegal seek"
        30 => "read-only file system"
        31 => "too many links"
        32 => "broken pipe"
        36 => "file name too long"
        39 => "directory not empty"
        40 => "too many levels of symbolic links"
        122 => "disk quota exceeded"
        _ if e >= 88 && e <= 115 || e > 0x20000 && e < 0x20010 => __net_error_text(e)
        _ => __os_error_text(e)
    }
}

// everything readable from a file descriptor (0 = standard input); what was read before an
// error is returned, and `io_error()` tells whether there was one
fn read_all(fd: i64) -> str {
    // a regular file: room for its size and one more byte (to see the end); /proc files
    // report 0. Other inputs (pipes, terminals): 64 KiB first. The buffer doubles as needed.
    size := 65536
    fsize, regular := __os_fstat(fd)
    if regular {
        size = if fsize > 0 { fsize + 1 } else { 4096 }
    }
    buf := alloc[u8](size)
    n := 0
    loop {
        if n == len(buf) {
            nb := alloc[u8](len(buf) * 2)
            memcopy(ptr(nb), ptr(buf), n)
            buf = nb
        }
        r := __os_read(fd, cast[i64](ptr(buf)) + n, len(buf) - n)
        __io_result(r)
        if r <= 0 {
            break
        }
        n += r
    }
    return buf[..n]
}

// the content of a file; ("", false) if it cannot be opened or read (see `io_error()`)
fn read_file(path: str) -> (str, bool) {
    fd := __open(path, false)
    if fd < 0 {
        return ("", false)
    }
    data := read_all(fd)
    __os_close(fd)
    if __tls_io_errno != 0 {
        return ("", false)
    }
    return (data, true)
}

// creates or replaces a file; false if that failed (see `io_error()`)
fn write_file(path: str, data: str) -> bool {
    fd := __open(path, true)
    if fd < 0 {
        return false
    }
    e := __write_all(fd, cast[i64](ptr(data)), len(data))
    if e != 0 {
        __tls_io_errno = e
    }
    __os_close(fd)
    return e == 0
}

// ---------- text helpers ----------
// s right-aligned in a field of `width` characters (padded on the left with `fill`)
fn pad_left(s: str, width: i64, fill: u8) -> str {
    if len(s) >= width {
        return s
    }
    out := alloc[u8](width)
    k := width - len(s)
    for i in 0..k {
        out[i] = fill
    }
    memcopy(cast[i64](ptr(out)) + k, ptr(s), len(s))
    return out
}

// s left-aligned in a field of `width` characters
fn pad_right(s: str, width: i64, fill: u8) -> str {
    if len(s) >= width {
        return s
    }
    out := alloc[u8](width)
    memcopy(ptr(out), ptr(s), len(s))
    for i in len(s)..width {
        out[i] = fill
    }
    return out
}

// lower-case hexadecimal digits of x (no prefix)
fn hex(x: u64) -> str {
    return __to_base(x, 16)
}

// at least `width` digits (zeros in front)
fn hex(x: u64, width: i64) -> str {
    return pad_left(__to_base(x, 16), width, '0')
}

// the digits of x in a base of 2..36 (0-9, then a-z; no prefix)
fn to_base(x: u64, base: i64) -> str {
    return __at_to_base(x, base, "?")
}

fn __at_to_base(x: u64, base: i64, at: str) -> str {
    if base < 2 || base > 36 {
        __panic(at, "to_base: the base must be 2..36")
    }
    return __to_base(x, u64(base))
}

fn __to_base(x: u64, base: u64) -> str {
    b: [64]u8
    i := 64
    loop {
        i -= 1
        d := u8(x % base)
        b[i] = if d < 10 { d + '0' } else { d - 10 + 'a' }
        x = x / base
        if x == 0 {
            break
        }
    }
    out := alloc[u8](64 - i)
    memcopy(ptr(out), cast[i64](ptr(b)) + i, 64 - i)
    return out
}

// an integer right-aligned in `width` characters; with fill '0' the zeros follow the sign:
// fmti(-42, 5, '0') is "-0042"
fn fmti[T](x: T, width: i64, fill: u8) -> str {
    s := fmt(x)
    if fill == '0' && len(s) < width && s[0] == '-' {
        out := pad_left(s[1..], width, '0')
        out[0] = '-'
        return out
    }
    return pad_left(s, width, fill)
}

// a copy of s with the ASCII letters a-z in upper case (other bytes as they are)
fn to_upper(s: str) -> str {
    out := alloc[u8](len(s))
    for i, c in s {
        out[i] = if c >= 'a' && c <= 'z' { c - 32 } else { c }
    }
    return out
}

// a copy of s with the ASCII letters A-Z in lower case (other bytes as they are)
fn to_lower(s: str) -> str {
    out := alloc[u8](len(s))
    for i, c in s {
        out[i] = if c >= 'A' && c <= 'Z' { c + 32 } else { c }
    }
    return out
}

// concatenation of all parts with sep between them
fn join(parts: []str, sep: str) -> str {
    n := 0
    for p in parts {
        n = __add_size(n, len(p))
    }
    if len(parts) > 1 {
        n = __add_size(n, __alloc_size(len(parts) - 1, len(sep)))
    }
    out := alloc[u8](n)
    k := 0
    for i, p in parts {
        if i > 0 {
            __copy_short(cast[i64](ptr(out)) + k, cast[i64](ptr(sep)), len(sep))
            k += len(sep)
        }
        __copy_short(cast[i64](ptr(out)) + k, cast[i64](ptr(p)), len(p))
        k += len(p)
    }
    return out
}

// a NUL-terminated copy of s, for C functions (string literals are NUL-terminated already:
// `ptr("literal")` can be passed directly)
fn cstr(s: str) -> *u8 {
    return cast[*u8](__cstr(s))
}

// the text of a NUL-terminated C string (not copied)
fn from_cstr(p: *u8) -> str {
    if p == nil {
        return ""
    }
    n := 0
    while p[n] != 0 {
        n += 1
    }
    return mkslice[u8](p, n)
}

// ---------- characters, environment, standard error ----------
// '0'..'9' (the character classes are ASCII: a byte >= 0x80 is in none of them)
fn is_digit(c: u8) -> bool {
    return c >= '0' && c <= '9'
}

fn is_alpha(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

fn is_alnum(c: u8) -> bool {
    return is_digit(c) || is_alpha(c)
}

fn is_upper(c: u8) -> bool {
    return c >= 'A' && c <= 'Z'
}

fn is_lower(c: u8) -> bool {
    return c >= 'a' && c <= 'z'
}

// ---------- standard error ----------
// (environment variables: env_get(name) of the OS layer)

// like print, to standard error
fn eprint(s: str) {
    eput2(s, true)
}

// like put (no newline), to standard error
fn eput(s: str) {
    eput2(s, false)
}

// (with threads, under the output lock: lines of standard error do not mix either)
priv fn eput2(s: str, nl: bool) {
    threads := __threaded || __tls_ocap == 0
    if threads {
        __out_acquire()
        __out_commit(true)
        __out_drain()
    } else {
        flush()
    }
    __err(s)
    if nl {
        __err("\n")
    }
    if threads {
        __out_release()
    }
}

// ---------- threads ----------
// The run-time library's side of std.os threads. A thread is started with a control block
// (__ThreadCtl), which the OS layer hands to the new thread (__os_thread_create); there
// __thread_main gives it its id and stack bounds, runs `body`, and at the end commits its
// output and leaves its base arena in the control block, where __thread_join takes it for
// the joiner. Control blocks are kept in a free list, never unmapped: a stale copy of a
// handle finds another generation (`gen`) instead of unmapped memory.
struct __ThreadCtl {
    body: fn(*__ThreadCtl)
    arg: i64        // for body
    id: i64         // the thread's id + 1
    gen: i64        // counts the uses of the block
    joining: i64    // 1 once a thread_join started
    stack: i64      // bytes of stack
    os: [4]i64      // the OS layer's (handle, mapping, ...)
    tid: i32        // the OS layer's (Linux: the kernel's thread id, 0 once it has ended)
    region: Region  // after the end: the thread's base arena
    next: *__ThreadCtl
}

priv thr_lock: i64
priv thr_free: *__ThreadCtl

// this thread's id + 1, given now to a thread a C library created
fn __thread_key() -> i64 {
    k := __tls_id
    if k == 0 {
        k = atomic_add(&__thread_next, 1) + 1
        __tls_id = k
    }
    return k
}

// this thread's id: 0 for the main thread, then 1, 2, ... in the order of thread_spawn (and of
// the first use of the library by threads that C libraries created)
fn __thread_id() -> i64 {
    return __thread_key() - 1
}

// the main thread (called first by the OS layer's __rt_init)
fn __thread_init_main() {
    __tls_id = 1
    __thread_next = 1
    __tls_obuf = cast[i64](ptr(__obuf))
    __tls_ocap = OBUF
}

// a thread that runs body(c) (c.arg for its use) on `stack` bytes of stack: its control block,
// or nil if it could not be started (io_error() says why)
fn __thread_spawn(body: fn(*__ThreadCtl), arg: i64, stack: i64) -> *__ThreadCtl {
    // from now on output goes line by line (see "output")
    if __tls_ocap != 0 {
        flush()
        __tls_ocap = 0
    }
    atomic_store(&__threaded, true)
    __os_lock(&thr_lock)
    if thr_free == nil {
        n := sizeof[__ThreadCtl]()
        p := __os_map(65536)
        if p < 0 && p > -4096 {
            __os_unlock(&thr_lock)
            __io_result(p)
            return nil
        }
        for k in 0..65536 / n {
            c := cast[*__ThreadCtl](p + k * n)
            c.next = thr_free
            thr_free = c
        }
    }
    c := thr_free
    thr_free = c.next
    __os_unlock(&thr_lock)
    c.body = body
    c.arg = arg
    c.joining = 0
    c.stack = (max(stack, 65536) + 4095) & ~4095
    c.os = [4]i64{}
    c.tid = 0
    c.region = Region{}
    c.id = atomic_add(&__thread_next, 1) + 1
    e := __os_thread_create(c)
    if e != 0 {
        thr_release(c)
        __io_result(e)
        return nil
    }
    __io_result(0)
    return c
}

// what a new thread of __thread_start needs: the function and the copy of its context
struct __ThreadArgs[C] {
    f: fn(C)
    ctx: C
}

// a thread that runs f(ctx) (ctx copied): its control block, or nil (io_error() says why)
fn __thread_start[C](f: fn(C), ctx: C, stack: i64) -> *__ThreadCtl {
    n := sizeof[__ThreadArgs[C]]()
    p := __os_map(n)
    if p < 0 && p > -4096 {
        __io_result(p)
        return nil
    }
    a := cast[*__ThreadArgs[C]](p)
    a.f = f
    a.ctx = ctx
    c := __thread_spawn(__thread_body[C], p, stack)
    if c == nil {
        __os_unmap(p, n)
    }
    return c
}

// the body of a thread of __thread_start (in the new thread)
fn __thread_body[C](c: *__ThreadCtl) {
    a := cast[*__ThreadArgs[C]](c.arg)
    f := a.f
    ctx := a.ctx
    __os_unmap(c.arg, sizeof[__ThreadArgs[C]]())
    f(ctx)
}

priv fn thr_release(c: *__ThreadCtl) {
    __os_lock(&thr_lock)
    c.gen += 1
    c.next = thr_free
    thr_free = c
    __os_unlock(&thr_lock)
}

// the start of a thread made by __thread_spawn (the OS layer calls it on the new thread)
fn __thread_main(c: *__ThreadCtl) {
    __tls_id = c.id
    __os_thread_setup(c)
    f := c.body
    f(c)
    // the end: the output, the arena (regions still entered are given up), the OS layer's
    if __tls_obuf != 0 {
        __out_acquire()
        __out_commit(true)
        __out_release()
        __os_unmap(__tls_obuf, OBUF)
        __tls_obuf = 0
    }
    if len(__tls_cap_buf) > 1024 {
        __os_unmap(cast[i64](ptr(__tls_cap_buf)), len(__tls_cap_buf))
    }
    __region_save(__region_top())
    for k in 0..__region_depth {
        atomic_store(&__region_stack[k].owner, 0)
    }
    c.region = __heap_main
    __os_thread_cleanup()
}

// waits until the thread of c has ended; its base arena, which belongs to the caller now
fn __thread_join(c: *__ThreadCtl) -> Region {
    __os_thread_join(c)
    r := c.region
    thr_release(c)
    return r
}

// ---------- optional values ----------
// a value that may be absent
// (`None` first: the zero value of an Opt is None)
enum Opt[T] { None, Some(T) }

fn is_some[T](o: Opt[T]) -> bool {
    match o {
        Some(_) => true
        None => false
    }
}

fn is_none[T](o: Opt[T]) -> bool {
    match o {
        Some(_) => false
        None => true
    }
}

// the value of `o`; stops the program if there is none
fn unwrap[T](o: Opt[T]) -> T {
    match o {
        Some(x) => x
        None => __die("panic: unwrap of None", "", "")
    }
}

// the value of `o`, or `default` if there is none
fn or[T](o: Opt[T], default: T) -> T {
    match o {
        Some(x) => x
        None => default
    }
}

// ---------- target ----------
// The system and processor the program is built for, constants for `when` and `if`:
// `when TARGET_OS == Windows { ... }`. TARGET_OS and TARGET_ARCH are declared by the OS layer.
enum Os { Linux, Windows, MacOS }
enum Arch { X86_64, Arm64 }

// (TARGET_ARCH is declared by the OS layer, at its end; this line keeps the lines below)

// ---------- network error texts (std.net) ----------
// error_text of the socket errors (88..115) and of std.net's name resolution errors
fn __net_error_text(e: i64) -> str {
    match e {
        88 => "socket operation on non-socket"
        89 => "destination address required"
        90 => "message too long"
        91 => "protocol wrong type for socket"
        92 => "protocol not available"
        93 => "protocol not supported"
        94 => "socket type not supported"
        95 => "operation not supported"
        96 => "protocol family not supported"
        97 => "address family not supported by protocol"
        98 => "address already in use"
        99 => "cannot assign requested address"
        100 => "network is down"
        101 => "network is unreachable"
        102 => "network dropped connection on reset"
        103 => "software caused connection abort"
        104 => "connection reset by peer"
        105 => "no buffer space available"
        106 => "transport endpoint is already connected"
        107 => "transport endpoint is not connected"
        108 => "cannot send after transport endpoint shutdown"
        109 => "too many references"
        110 => "connection timed out"
        111 => "connection refused"
        112 => "host is down"
        113 => "no route to host"
        114 => "operation already in progress"
        115 => "operation now in progress"
        0x20001 => "host not found"
        0x20002 => "name server failure"
        0x20003 => "temporary failure in name resolution"
        _ => __os_error_text(e)
    }
}

// Color(i) with an i that is no variant's number
noinline fn __enum_fail(loc: str, i: i64, name: str, n: i64) -> never {
    __die("panic: not a variant at ", loc, fmt(name, "(", i, "): ", name, " has ", n, " variants, numbered 0 to ", n - 1))
}
