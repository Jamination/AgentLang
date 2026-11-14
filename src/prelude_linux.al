// AL run-time library, Linux layer: raw system calls (no libc). Compiled after src/prelude.al
// into every program built for Linux; the functions it has to define are listed at the top of
// src/prelude.al. Results of system calls are the kernel's: a value, or -errno.

__argc: i64
__argv: i64
__sigstack: [32768]u8

// the initial stack pointer: the top of the stack, above every frame
priv stack_top: i64
priv in_fault: bool

// uc: the interrupted state (ucontext_t: the general registers from byte 40: r8-r15, rdi, rsi,
// rbp, rbx, rdx, rax, rcx, rsp, rip), where the stack trace starts. A fault while one is
// reported (the stack trace of a corrupted stack, ...) ends the program at once.
noinline fn __on_fault(sig: i64, info: i64, uc: i64) -> never {
    if in_fault || __bt_busy {
        if __bt_busy {
            __err("  ... (the stack trace stopped at a fault)\n")
        }
        __os_exit(1)
    }
    in_fault = true
    g := cast[*i64](uc + 40)
    r := &__bt_fault_regs.r
    for k in 0..8 {
        r[8 + k] = g[k]
    }
    r[7] = g[8]
    r[6] = g[9]
    r[5] = g[10]
    r[3] = g[11]
    r[2] = g[12]
    r[0] = g[13]
    r[1] = g[14]
    r[4] = g[15]
    __bt_fault_pc = g[16]
    if sig == 8 {
        __die("panic: arithmetic fault (division by zero or overflow)", "", "")
    }
    __die("panic: memory fault (nil dereference, stack overflow or use of released memory)", "", "")
}

// the program headers (AT_PHDR, AT_PHNUM of the auxiliary vector, which follows the
// environment on the initial stack): (address, count)
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
        }
        p += 16
    }
    return (phdr, min(phnum, 64))
}

// the size of the thread block (PT_TLS, a multiple of 16; see layout_tls in the compiler)
priv tls_size: i64

// a thread block with the TCB after it (x86-64 TLS variant II: the thread-local globals lie
// below the thread pointer, whose first word points to itself) in the n bytes at p: the
// thread pointer
priv fn tls_place(p: i64) -> i64 {
    tp := p + tls_size
    cast[*i64](tp)[0] = tp
    return tp
}

// sp: the initial stack pointer (argc, argv..., 0, envp..., 0)
fn __rt_init(sp: i64) {
    __argc = cast[*i64](sp)[0]
    __argv = sp + 8
    ph, n := phdrs()
    for k in 0..n {
        if cast[*u32](ph + 56 * k)[0] == 7 {
            tls_size = (cast[*i64](ph + 56 * k + 40)[0] + 15) & ~15
        }
    }
    // the main thread's thread block: the C library's loader made it in a dynamically linked
    // program (FS is set); a static program starts with FS 0 and makes its own. Nothing
    // before this point touches a thread-local global.
    fs := 0
    syscall(158, 0x1003, &fs)                // arch_prctl(ARCH_GET_FS)
    if fs == 0 {
        p := __os_map(tls_size + 64)
        if p < 0 && p > -4096 {
            __os_exit(127)
        }
        syscall(158, 0x1002, tls_place(p))   // arch_prctl(ARCH_SET_FS)
    }
    stack_top = sp
    // report crashes as panics: handlers run on their own stack so that stack overflow works too
    ss: [3]i64
    ss[0] = cast[i64](ptr(__sigstack))
    ss[2] = 32768
    syscall(131, ptr(ss), 0)
    sa: [4]i64
    sa[0] = cast[i64](__on_fault)
    // SA_ONSTACK | SA_RESTORER | SA_NODEFER | SA_SIGINFO
    sa[1] = 0x08000000 | 0x04000000 | 0x40000000 | 4
    sa[2] = cast[i64](__on_fault)
    syscall(13, 11, ptr(sa), 0, 8)
    syscall(13, 7, ptr(sa), 0, 8)
    syscall(13, 8, ptr(sa), 0, 8)
}

// the frames lie below the initial stack pointer (the lower end only bounds a stack pointer that
// is nonsense)
fn __os_stack_range() -> (i64, i64) {
    return (stack_top - (1 << 36), stack_top)
}

fn __os_backtrace_off() -> bool {
    v, set := env_get("ALC_BACKTRACE")
    return set && v == "0"
}

// ---------- stack traces through C libraries ----------
// A stack trace that reaches code of a C library (a callback called by qsort, a fault inside
// strlen) goes on through its frames by the library's DWARF call frame information (.eh_frame,
// found through .eh_frame_hdr): C code keeps no frame shape the walk could rely on. The
// libraries are those of the dynamic loader's list (r_debug, whose address the loader puts into
// DT_DEBUG of the program's dynamic section; static programs have none); the program headers of
// a library, in memory at its load address, give its segments, .eh_frame_hdr and dynamic
// symbols (the names of the frames). Every address read is checked against the library's
// segments or the stack: bad data ends the trace, it does not fault. The interpreter knows the
// instructions GCC and Clang emit for x86-64 (a register saved by an expression becomes
// unknown; a CFA computed by one ends the trace).
const __BT_SAVED = 0xF028 // rbx, rbp, r12-r15: the registers a call preserves

// the library of the last lookup: load address, name (a C string), the code segment holding the
// address looked up, the segments that can be read (start, end), .eh_frame_hdr, the dynamic
// section (0: none)
priv bl_base: i64
priv bl_name: i64
priv bl_xlo: i64
priv bl_xhi: i64
priv bl_seg: [16]i64
priv bl_nseg: i64
priv bl_ehdr: i64
priv bl_dyn: i64

// the loader's r_debug (0: none): DT_DEBUG of the program's dynamic section, found through the
// program headers named by the auxiliary vector (AT_PHDR, AT_PHNUM), which follows the
// environment on the initial stack
priv noinline fn bl_r_debug() -> i64 {
    phdr, phnum := phdrs()
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

// makes the library at load address `base` (its ELF header there) the library of the lookups if
// pc is in its code
priv noinline fn bl_load(base: i64, name: i64, pc: i64) -> bool {
    if cast[*u32](base)[0] != 0x464C457F {
        return false
    }
    ph := base + cast[*i64](base + 32)[0]
    n := min(i64(cast[*u16](base + 56)[0]), 64)
    xlo := 0
    xhi := 0
    for k in 0..n {
        h := ph + 56 * k
        va := base + cast[*i64](h + 16)[0]
        end := va + cast[*i64](h + 40)[0]
        // PT_LOAD, executable
        if cast[*u32](h)[0] == 1 && cast[*u32](h + 4)[0] & 1 != 0 && pc >= va && pc < end {
            xlo = va
            xhi = end
        }
    }
    if xhi == 0 {
        return false
    }
    bl_base = base
    bl_name = name
    bl_xlo = xlo
    bl_xhi = xhi
    bl_nseg = 0
    bl_ehdr = 0
    bl_dyn = 0
    for k in 0..n {
        h := ph + 56 * k
        t := cast[*u32](h)[0]
        va := base + cast[*i64](h + 16)[0]
        if t == 1 && cast[*u32](h + 4)[0] & 4 != 0 && bl_nseg < 8 {
            bl_seg[2 * bl_nseg] = va
            bl_seg[2 * bl_nseg + 1] = va + cast[*i64](h + 40)[0]
            bl_nseg += 1
        } else if t == 0x6474E550 {
            bl_ehdr = va                             // PT_GNU_EH_FRAME
        } else if t == 2 {
            bl_dyn = va
        }
    }
    return true
}

// is pc in the code of a library the loader mapped? (it becomes the library of the lookups)
noinline fn __os_bt_foreign(pc: i64) -> bool {
    if pc >= bl_xlo && pc < bl_xhi {
        return true
    }
    rd := bl_r_debug()
    if rd == 0 {
        return false
    }
    // r_debug.r_map: the list of link_map { l_addr, l_name, l_ld, l_next, ... } (the program
    // itself, at l_addr 0, is not a library)
    m := cast[*i64](rd)[1]
    n := 0
    while m != 0 && n < 10000 {
        l := cast[*i64](m)
        if l[0] != 0 && bl_load(l[0], l[1], pc) {
            return true
        }
        m = l[3]
        n += 1
    }
    return false
}

// the end of the library's segment that holds address a, 0 if none
priv noinline fn bl_end(a: i64) -> i64 {
    for k in 0..bl_nseg {
        if a >= bl_seg[2 * k] && a < bl_seg[2 * k + 1] {
            return bl_seg[2 * k + 1]
        }
    }
    return 0
}

// can the n bytes at a be read (inside one segment of the library)?
priv noinline fn bl_ok(a: i64, n: i64) -> bool {
    return n >= 0 && a + n <= bl_end(a)
}

// reading call frame information: from cf_p up to cf_end, which ends it (cf_bad) when crossed
priv cf_p: i64
priv cf_end: i64
priv cf_bad: bool

priv noinline fn cf_u8() -> i64 {
    if cf_p >= cf_end {
        cf_bad = true
        return 0
    }
    cf_p += 1
    return i64(cast[*u8](cf_p - 1)[0])
}

// n bytes, little endian
priv noinline fn cf_un(n: i64) -> i64 {
    x := 0
    for k in 0..n {
        x |= cf_u8() << (8 * k)
    }
    return x
}

priv noinline fn cf_leb(signed: bool) -> i64 {
    x := 0
    s := 0
    loop {
        b := cf_u8()
        if s < 64 {
            x |= (b & 0x7F) << s
        }
        s += 7
        if b < 0x80 || cf_bad {
            if signed && s < 64 && b & 0x40 != 0 {
                x |= -1 << s
            }
            return x
        }
    }
}

// a pointer in encoding `enc` (DW_EH_PE_*: its size, relative to its own address (pcrel) or to
// `data` (datarel)); an encoding the walk does not know ends the reading
priv noinline fn cf_ptr(enc: i64, data: i64) -> i64 {
    at := cf_p
    x := match enc & 0x0F {
        0, 4, 12 => cf_un(8)
        1 => cf_leb(false)
        2 => cf_un(2)
        3 => cf_un(4)
        9 => cf_leb(true)
        10 => i64(i16(cf_un(2)))
        11 => i64(i32(cf_un(4)))
        _ => {
            cf_bad = true
            0
        }
    }
    h := (enc >> 4) & 7
    if h == 1 {
        x += at
    } else if h == 3 {
        x += data
    } else if h != 0 {
        cf_bad = true
    }
    return x
}

// a row of the table the instructions describe: the CFA (the stack pointer before the call) is
// register cfa_reg (DWARF number, -1: unknown) + cfa_off; per register (DWARF 0-16, 16: the
// return address) how its value in the caller is found: 0 unchanged, 1 saved at CFA + val, 2 in
// register val, 3 unknown
priv struct CfRow {
    cfa_reg: i64
    cfa_off: i64
    how: [17]u8
    val: [17]i64
}

priv cf_row: CfRow
priv cf_first: CfRow // after the CIE's instructions (what DW_CFA_restore goes back to)
priv cf_stack: [4]CfRow // DW_CFA_remember_state
priv cf_depth: i64
// of the CIE: code and data alignment, the encoding of the FDE's addresses, whether FDEs have
// augmentation data, its instructions [cf_init, cf_init_end)
priv cf_caf: i64
priv cf_daf: i64
priv cf_fenc: i64
priv cf_aug: bool
priv cf_init: i64
priv cf_init_end: i64

priv noinline fn cf_set(reg: i64, how: i64, val: i64) {
    if reg >= 0 && reg < 17 {
        cf_row.how[reg] = u8(how)
        cf_row.val[reg] = val
    }
}

priv noinline fn cf_restore(reg: i64) {
    if reg >= 0 && reg < 17 {
        cf_row.how[reg] = cf_first.how[reg]
        cf_row.val[reg] = cf_first.val[reg]
    }
}

// runs the instructions [cf_p, cf_end) from code address loc while the row applies to address q;
// false on an instruction the walk does not know or bad data
priv noinline fn cf_run(loc0: i64, q: i64) -> bool {
    loc := loc0
    while cf_p < cf_end && !cf_bad {
        op := cf_u8()
        lo := op & 0x3F
        if op >> 6 == 1 {
            loc += lo * cf_caf                          // DW_CFA_advance_loc
            if loc > q {
                return true
            }
        } else if op >> 6 == 2 {
            cf_set(lo, 1, cf_leb(false) * cf_daf)       // DW_CFA_offset
        } else if op >> 6 == 3 {
            cf_restore(lo)                              // DW_CFA_restore
        } else {
            match lo {
                0 => {}                                 // nop
                1, 2, 3, 4 => {
                    // set_loc, advance_loc1, 2, 4
                    if lo == 1 {
                        loc = cf_ptr(cf_fenc, 0)
                    } else {
                        loc += cf_un(if lo == 4 { 4 } else { lo - 1 }) * cf_caf
                    }
                    if loc > q {
                        return true
                    }
                }
                5, 17, 0x2F => {
                    // offset_extended, offset_extended_sf, GNU_negative_offset_extended
                    reg := cf_leb(false)
                    off := if lo == 17 { cf_leb(true) } else { cf_leb(false) }
                    cf_set(reg, 1, (if lo == 0x2F { -off } else { off }) * cf_daf)
                }
                6 => cf_restore(cf_leb(false))           // restore_extended
                7 => cf_set(cf_leb(false), 3, 0)         // undefined
                8 => cf_set(cf_leb(false), 0, 0)         // same_value
                9 => {
                    reg := cf_leb(false)                 // register
                    cf_set(reg, 2, cf_leb(false))
                }
                10 => {
                    if cf_depth == 4 {                   // remember_state
                        return false
                    }
                    cf_stack[cf_depth] = cf_row
                    cf_depth += 1
                }
                11 => {
                    if cf_depth == 0 {                   // restore_state
                        return false
                    }
                    cf_depth -= 1
                    cf_row = cf_stack[cf_depth]
                }
                12, 18 => {
                    cf_row.cfa_reg = cf_leb(false)       // def_cfa, def_cfa_sf
                    cf_row.cfa_off = if lo == 18 { cf_leb(true) * cf_daf } else { cf_leb(false) }
                }
                13 => {
                    cf_row.cfa_reg = cf_leb(false)       // def_cfa_register
                }
                14 => {
                    cf_row.cfa_off = cf_leb(false)       // def_cfa_offset
                }
                19 => {
                    cf_row.cfa_off = cf_leb(true) * cf_daf // def_cfa_offset_sf
                }
                15 => {
                    cf_row.cfa_reg = -1                  // def_cfa_expression
                    cf_p += cf_leb(false)
                }
                16, 20, 21, 22 => {
                    // expression, val_offset, val_offset_sf, val_expression
                    cf_set(cf_leb(false), 3, 0)
                    n := cf_leb(lo == 21)
                    if lo == 16 || lo == 22 {
                        cf_p += n
                    }
                }
                0x2E => {
                    cf_leb(false)                        // GNU_args_size
                }
                _ => return false
            }
        }
    }
    return !cf_bad
}

// reads the CIE at c (cf_caf, cf_daf, cf_fenc, cf_aug, cf_init...); false if it is not one the
// walk can use
priv noinline fn cf_cie(c: i64) -> bool {
    if !bl_ok(c, 9) {
        return false
    }
    n := i64(cast[*u32](c)[0])
    if n >= 0xFFFFFFF0 || !bl_ok(c, 4 + n) || cast[*u32](c + 4)[0] != 0 {
        return false
    }
    cf_p = c + 8
    cf_end = c + 4 + n
    ver := cf_u8()
    aug := cast[*u8](cf_p)
    while cf_u8() != 0 && !cf_bad {}
    cf_caf = cf_leb(false)
    cf_daf = cf_leb(true)
    ra := if ver == 1 { cf_u8() } else { cf_leb(false) }
    cf_fenc = 0
    cf_aug = aug[0] == 'z'
    if cf_bad || ra != 16 {
        return false
    }
    if cf_aug {
        end := cf_leb(false)
        end += cf_p
        k := 1
        while aug[k] != 0 {
            a := aug[k]
            if a == 'R' {
                cf_fenc = cf_u8()
            } else if a == 'L' {
                cf_u8()
            } else if a == 'P' {
                cf_ptr(cf_u8() & 0x7F, 0)
            } else if a != 'S' {
                return false
            }
            k += 1
        }
        cf_p = end
    } else if aug[0] != 0 {
        return false
    }
    cf_init = cf_p
    cf_init_end = cf_end
    return !cf_bad && cf_p <= cf_end
}

// the row of the library's code at address q in cf_row; false if there is none or it cannot be
// read
priv noinline fn cf_find(q: i64) -> bool {
    h := bl_ehdr
    if h == 0 || !bl_ok(h, 4) {
        return false
    }
    // .eh_frame_hdr: version 1, the encodings of the pointer to .eh_frame, of the count and of
    // the table (only the usual one: pairs of 4-byte offsets from the header, sorted by address)
    b := cast[*u8](h)
    if b[0] != 1 || b[3] != 0x3B {
        return false
    }
    cf_p = h + 4
    cf_end = bl_end(h)
    cf_bad = false
    cf_ptr(i64(b[1]), h)
    n := cf_ptr(i64(b[2]), h)
    t := cf_p
    if cf_bad || n <= 0 || !bl_ok(t, 8 * n) || h + i64(cast[*i32](t)[0]) > q {
        return false
    }
    lo := 0
    hi := n
    while hi - lo > 1 {
        mid := (lo + hi) / 2
        if h + i64(cast[*i32](t + 8 * mid)[0]) <= q {
            lo = mid
        } else {
            hi = mid
        }
    }
    // the FDE: its length, the distance back to its CIE, its code (start, size), augmentation
    // data, instructions
    fde := h + i64(cast[*i32](t + 8 * lo + 4)[0])
    if !bl_ok(fde, 8) {
        return false
    }
    len := i64(cast[*u32](fde)[0])
    if len < 8 || len >= 0xFFFFFFF0 || !bl_ok(fde, 4 + len) || !cf_cie(fde + 4 - i64(cast[*u32](fde + 4)[0])) {
        return false
    }
    cf_p = fde + 8
    cf_end = fde + 4 + len
    start := cf_ptr(cf_fenc, 0)
    size := cf_ptr(cf_fenc & 0x0F, 0)
    if cf_aug {
        cf_p += cf_leb(false)
    }
    if cf_bad || q < start || q - start >= size {
        return false
    }
    p := cf_p
    end := cf_end
    cf_row.cfa_reg = -1
    for r in 0..17 {
        cf_row.how[r] = 0
    }
    cf_depth = 0
    cf_p = cf_init
    cf_end = cf_init_end
    if !cf_run(start, q) {
        return false
    }
    cf_first = cf_row
    cf_p = p
    cf_end = end
    return cf_run(start, q)
}

// x86 register numbers of the DWARF ones (rax, rdx, rcx, rbx, rsi, rdi, rbp, rsp, r8-r15), as bytes
priv const DW_X86 = "\x00\x02\x01\x03\x06\x07\x05\x04\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F"

// the caller of the frame of C code at pc (a return address, or the faulting instruction if
// `fault`) with registers g: its return address (0: unknown, or the end of the stack), g becomes
// its registers (r[4]: its stack pointer). The stack is read only in [g.r[4], hi).
noinline fn __os_bt_unwind(pc: i64, fault: bool, g: *__BtRegs, hi: i64) -> i64 {
    q := if fault { pc } else { pc - 1 }
    if !__os_bt_foreign(q) || !cf_find(q) {
        return 0
    }
    c := cf_row.cfa_reg
    if c < 0 || c > 15 || g.known & (1 << i64(DW_X86[c])) == 0 {
        return 0
    }
    sp := g.r[4]
    cfa := g.r[i64(DW_X86[c])] + cf_row.cfa_off
    if cfa <= sp || cfa > hi {
        return 0
    }
    old := *g
    ra := 0
    for d in 0..17 {
        how := cf_row.how[d]
        v := 0
        ok := false
        if how == 1 {
            a := cfa + cf_row.val[d]
            if a < sp || a + 8 > hi {
                return 0
            }
            v = cast[*i64](a)[0]
            ok = true
        } else if how == 2 && cf_row.val[d] >= 0 && cf_row.val[d] < 16 {
            s := i64(DW_X86[cf_row.val[d]])
            v = old.r[s]
            ok = old.known & (1 << s) != 0
        }
        if d == 16 {
            if !ok {
                return 0
            }
            ra = v
        } else if d != 7 && how != 0 {
            x := i64(DW_X86[d])
            g.r[x] = v
            g.known = if ok { g.known | (1 << x) } else { g.known & ~(1 << x) }
        }
    }
    g.r[4] = cfa
    g.known = (g.known & __BT_SAVED) | 16
    return ra
}

// a C string of at most n bytes at p
priv noinline fn bl_str(p: i64, n: i64) -> str {
    k := 0
    while k < n && cast[*u8](p + k)[0] != 0 {
        k += 1
    }
    return mkslice[u8](cast[*u8](p), k)
}

// the name of the library's dynamic symbol for the function that holds address `base + off`:
// the nearest before it, if its size reaches it; "" if none
priv noinline fn bl_symbol(off: i64) -> str {
    syms := 0
    strs := 0
    strsz := 0
    hash := 0
    gnu := 0
    d := bl_dyn
    while d != 0 && bl_ok(d, 16) && cast[*i64](d)[0] != 0 {
        t := cast[*i64](d)[0]
        v := cast[*i64](d)[1]
        // (glibc's loader has relocated the addresses in place, others have not)
        a := if v < bl_base { v + bl_base } else { v }
        if t == 4 {
            hash = a
        } else if t == 5 {
            strs = a
        } else if t == 6 {
            syms = a
        } else if t == 10 {
            strsz = v
        } else if t == 0x6FFFFEF5 {
            gnu = a
        }
        d += 16
    }
    // the number of symbols: of DT_HASH, or after the last chain of DT_GNU_HASH
    n := 0
    if hash != 0 && bl_ok(hash, 8) {
        n = i64(cast[*u32](hash + 4)[0])
    } else if gnu != 0 && bl_ok(gnu, 16) {
        g := cast[*u32](gnu)
        nb := i64(g[0])
        first := i64(g[1])
        buckets := gnu + 16 + 8 * i64(g[2])
        if !bl_ok(buckets, 4 * nb) {
            return ""
        }
        for k in 0..nb {
            n = max(n, i64(cast[*u32](buckets + 4 * k)[0]))
        }
        if n < first {
            n = first
        } else {
            chain := buckets + 4 * nb - 4 * first
            while bl_ok(chain + 4 * n, 4) && cast[*u32](chain + 4 * n)[0] & 1 == 0 {
                n += 1
            }
            n += 1
        }
    }
    if syms == 0 || strs == 0 || !bl_ok(syms, 24 * n) || !bl_ok(strs, strsz) {
        return ""
    }
    // the nearest function (STT_FUNC, STT_GNU_IFUNC) defined at or before the address
    best := -1
    at := 0
    for i in 1..n {
        e := syms + 24 * i
        t := cast[*u8](e + 4)[0] & 15
        v := cast[*i64](e + 8)[0]
        if (t == 2 || t == 10) && cast[*u16](e + 6)[0] != 0 && v <= off && (best < 0 || v > at) {
            best = i
            at = v
        }
    }
    // (a function of the library without a dynamic symbol may follow it)
    size := if best < 0 { 0 } else { cast[*i64](syms + 24 * best + 16)[0] }
    if best < 0 || size != 0 && off - at >= size {
        return ""
    }
    o := i64(cast[*u32](syms + 24 * best)[0])
    if o >= strsz {
        return ""
    }
    return bl_str(strs + o, strsz - o)
}

// the frame of C code at address q: (the file name of its library, the name of its function or
// "", q's offset in the library); ("", "", q) outside every library
noinline fn __os_bt_where(q: i64) -> (str, str, i64) {
    if !__os_bt_foreign(q) {
        return ("", "", q)
    }
    name := bl_str(bl_name, 4096)
    k := len(name)
    while k > 0 && name[k - 1] != '/' {
        k -= 1
    }
    return (name[k..], bl_symbol(q - bl_base), q - bl_base)
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
                names.push(clone(name))
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
    __os_read(note_r, cast[i64](ptr(failed)), 8)
    syscall(3, note_r)
    if failed[0] != 0 {
        // the child exits at once: wait for it
        __os_wait(pid, pid, true)
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
    return clone(from_cstr(ptr(buf)))
}

// the target of this layer (see `enum Os` in prelude.al)
const TARGET_OS = Os.Linux
