// A user-mode emulator for the static executables of --target linux-arm64, so that they can
// run on an x86-64 machine without an arm64 one (no QEMU here):
//
//   alc build tests/arm64/emu.al -o build/a64emu      (build/a64emu.exe on Windows)
//   build/a64emu program [args...]
//
// It runs the program's AArch64 code instruction by instruction and maps its Linux system
// calls onto the host through the run-time library. What it covers is what the arm64 back end
// and src/prelude_linux_arm64.al use: the integer, load/store, branch, floating-point and SIMD
// forms of src/arm64/enc.al (decoded here from the architecture's encoding tables, not from
// the encoder), exclusive accesses, TPIDR_EL0; files, directories, time, memory maps, futexes,
// threads (clone of the same address space: run as green threads on one host thread, switched
// every few thousand instructions and when they wait), signal handlers for faults (SIGSEGV,
// SIGBUS) on the alternate stack. Not covered: new processes (fork, execve, pipes: -ENOSYS),
// memory maps of files, other signals. An instruction it does not know ends the run with
// status 132 and a message; a fault without a handler with 139.
//
// This is a test tool: it shares nothing with the compiler, but it was written by the same
// hands as the back end, so a misreading of the architecture both made would not show here.
// Real hardware or QEMU remains the reference (docs/ARM64_TEST.md).

priv const BASE = 0x400000

// ---------- host memory ----------
when TARGET_OS == Windows {
    priv extern "kernel32.dll" fn VirtualAlloc(addr: i64, size: i64, kind: u32, protect: u32) -> i64
    priv extern "kernel32.dll" fn VirtualFree(addr: i64, size: i64, kind: u32) -> i32

    // address space without memory behind it (committed on first use: commit)
    priv fn reserve(n: i64) -> i64 {
        return VirtualAlloc(0, n, 0x2000, 1)
    }

    priv fn commit(p: i64, n: i64) -> bool {
        return VirtualAlloc(p, n, 0x1000, 4) != 0
    }

    priv fn release(p: i64, n: i64) {
        VirtualFree(p, 0, 0x8000)
    }
} else {
    priv fn reserve(n: i64) -> i64 {
        // PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE
        p := syscall(9, 0, n, 3, 0x4022, -1, 0)
        return if p < 0 && p > -4096 { 0 } else { p }
    }

    priv fn commit(p: i64, n: i64) -> bool {
        return true
    }

    priv fn release(p: i64, n: i64) {
        syscall(11, p, n)
    }
}

// ---------- guest memory ----------
// The image (its PT_LOAD segments) lies at its link address in the guest and in a host buffer;
// every other guest region (stacks, maps) has the same address as on the host. A region is
// committed in steps of COMMIT as the guest touches it.
priv const COMMIT = 1 << 20

priv struct Region {
    lo: i64
    hi: i64
    delta: i64     // host address - guest address
    clo: i64       // committed: [clo, chi) (guest addresses)
    chi: i64
}

priv regions: Vec[Region]
// the last regions used (a small cache in front of the list)
priv cache: [4]Region
priv cache_next: i64
// the address of the last fault (0: none) of the running instruction
priv fault_addr: i64
priv faulted: bool
// the signal of the fault: 11 (SIGSEGV) for memory, 5 (SIGTRAP) for BRK
priv fault_sig: i64 = 11

// a region with [clo, chi) committed (an empty range: anywhere in it)
priv fn add_region(lo: i64, hi: i64, delta: i64, clo: i64, chi: i64) {
    regions.push(Region{lo: lo, hi: hi, delta: delta, clo: clo, chi: chi})
}

priv fn drop_region(lo: i64) {
    for k in 0..regions.len {
        if regions[k].lo == lo {
            regions.remove(k)
            break
        }
    }
    for k in 0..4 {
        cache[k] = Region{}
    }
}

// the host address of n bytes at guest address a, or 0 after recording a fault
priv noinline fn slow_host(a: i64, n: i64) -> i64 {
    for k in 0..regions.len {
        g := &regions[k]
        if a >= g.lo && a + n <= g.hi {
            if g.clo == g.chi {
                g.clo = max(g.lo + ((a - g.lo) & ~(COMMIT - 1)), g.lo)
                g.chi = g.clo
            }
            if a < g.clo {
                from := max(g.lo + ((a - g.lo) & ~(COMMIT - 1)), g.lo)
                if !commit(from + g.delta, g.clo - from) {
                    break
                }
                g.clo = from
            }
            if a + n > g.chi {
                to := min(align_up(a + n - g.lo, COMMIT) + g.lo, g.hi)
                if !commit(g.chi + g.delta, to - g.chi) {
                    break
                }
                g.chi = to
            }
            cache[cache_next] = *g
            cache_next = (cache_next + 1) & 3
            return a + g.delta
        }
    }
    if !faulted {
        faulted = true
        fault_addr = a
    }
    return 0
}

priv inline fn host(a: i64, n: i64) -> i64 {
    for k in 0..4 {
        c := &cache[k]
        if a >= c.clo && a + n <= c.chi {
            return a + c.delta
        }
    }
    return slow_host(a, n)
}

priv fn rd8(a: i64) -> i64 {
    h := host(a, 1)
    return if h == 0 { 0 } else { i64(cast[*u8](h)[0]) }
}

priv fn rd16(a: i64) -> i64 {
    h := host(a, 2)
    return if h == 0 { 0 } else { i64(cast[*u16](h)[0]) }
}

priv fn rd32(a: i64) -> i64 {
    h := host(a, 4)
    return if h == 0 { 0 } else { i64(cast[*u32](h)[0]) }
}

priv fn rd64(a: i64) -> i64 {
    h := host(a, 8)
    return if h == 0 { 0 } else { cast[*i64](h)[0] }
}

priv fn wr8(a: i64, v: i64) {
    h := host(a, 1)
    if h != 0 {
        cast[*u8](h)[0] = u8(v)
    }
}

priv fn wr16(a: i64, v: i64) {
    h := host(a, 2)
    if h != 0 {
        cast[*u16](h)[0] = u16(v)
    }
}

priv fn wr32(a: i64, v: i64) {
    h := host(a, 4)
    if h != 0 {
        cast[*u32](h)[0] = u32(v)
    }
}

priv fn wr64(a: i64, v: i64) {
    h := host(a, 8)
    if h != 0 {
        cast[*i64](h)[0] = v
    }
}

// a NUL-terminated string of the guest
priv fn gstr(a: i64) -> str {
    out := vec[u8]()
    loop {
        c := rd8(a + out.len)
        if faulted || c == 0 || out.len > 65536 {
            break
        }
        out.push(u8(c))
    }
    return out.items()
}

priv fn gbytes(a: i64, n: i64) -> []u8 {
    h := host(a, max(n, 1))
    if h == 0 {
        return nil
    }
    return mkslice[u8](cast[*u8](h), n)
}

// ---------- threads ----------
priv struct Th {
    x: [32]i64      // x0-x30; x[31] unused (sp is `sp`, the zero register reads 0)
    sp: i64
    pc: i64
    n: bool
    z: bool
    c: bool
    v: bool
    vlo: [32]u64
    vhi: [32]u64
    tp: i64
    tid: i64
    excl: i64       // the address of the exclusive monitor, -1: none
    clear_tid: i64  // CLONE_CHILD_CLEARTID
    // waiting: 0 runs, 1 futex (wait_addr), 2 sleeps until wake_at, 3 ended
    wait: i64
    wait_addr: i64
    wake_at: i64    // clock_ns (0: none)
    in_signal: bool
    alt_lo: i64
    alt_size: i64
}

priv threads: Vec[*Th]
priv next_tid: i64 = 100
priv handlers: [32]i64
priv exit_code: i64 = -1

priv fn creg(t: *Th, r: i64) -> i64 {
    return if r == 31 { 0 } else { t.x[r] }
}

// a register that may be sp (31)
priv fn sreg(t: *Th, r: i64) -> i64 {
    return if r == 31 { t.sp } else { t.x[r] }
}

priv fn setr(t: *Th, r: i64, v: i64, sf: bool) {
    if r != 31 {
        t.x[r] = if sf { v } else { v & 0xFFFF_FFFF }
    }
}

priv fn sets(t: *Th, r: i64, v: i64, sf: bool) {
    w := if sf { v } else { v & 0xFFFF_FFFF }
    if r == 31 {
        t.sp = w
    } else {
        t.x[r] = w
    }
}

// ---------- integer helpers ----------
priv fn sx(v: i64, bits: i64) -> i64 {
    return (v << (64 - bits)) >> (64 - bits)
}

priv fn ones(n: i64) -> i64 {
    return if n >= 64 { -1 } else { (1 << n) - 1 }
}

priv fn ror(v: i64, r: i64, width: i64) -> i64 {
    m := ones(width)
    x := v & m
    if r % width == 0 {
        return x
    }
    s := r % width
    return i64((u64(x) >> u64(s)) | (u64(x) << u64(width - s))) & m
}

// a shift of the shifted-register forms: kind 0 LSL, 1 LSR, 2 ASR, 3 ROR
priv fn shifted(v: i64, kind: i64, amt: i64, sf: bool) -> i64 {
    width := if sf { 64 } else { 32 }
    x := if sf { v } else { v & 0xFFFF_FFFF }
    if amt == 0 {
        return x
    }
    match kind {
        0 => return (x << amt) & ones(width)
        1 => return i64(u64(x) >> u64(amt))
        2 => return (if sf { x >> amt } else { sx(x, 32) >> amt }) & ones(width)
        _ => return ror(x, amt, width)
    }
}

// NZCV of a + b + carry (sub: a - b as a + ~b + 1)
priv fn addf(t: *Th, a0: i64, b0: i64, sub: bool, sf: bool, setf: bool) -> i64 {
    width := if sf { 64 } else { 32 }
    m := ones(width)
    a := a0 & m
    b := if sub { ~b0 & m } else { b0 & m }
    cin := if sub { 1 } else { 0 }
    r := 0
    carry := false
    if sf {
        r = a + b + cin
        // the unsigned carry of a + b + cin
        carry = u64(r) < u64(a) || (cin == 1 && u64(r) == u64(a))
    } else {
        full := a + b + cin
        r = full & m
        carry = full > m
    }
    if setf {
        sa := if sf { a } else { sx(a, 32) }
        sb := if sf { b } else { sx(b, 32) }
        sr := if sf { r } else { sx(r, 32) }
        t.n = sr < 0
        t.z = r == 0
        t.c = carry
        t.v = (sa < 0) == (sb < 0) && (sr < 0) != (sa < 0)
    }
    return r
}

priv fn cond(t: *Th, cc: i64) -> bool {
    r := match cc >> 1 {
        0 => t.z
        1 => t.c
        2 => t.n
        3 => t.v
        4 => t.c && !t.z
        5 => t.n == t.v
        6 => t.n == t.v && !t.z
        _ => true
    }
    if cc & 1 == 1 && cc != 15 {
        return !r
    }
    return r
}

// DecodeBitMasks of the logical immediates: the value of N:immr:imms for a width of 32 or 64
priv fn bitmask(nbit: i64, immr: i64, imms: i64, width: i64) -> (i64, bool) {
    combined := (nbit << 6) | (~imms & 0x3F)
    if combined == 0 {
        return (0, false)
    }
    len := 63 - i64(clz(u64(combined)))
    if len < 1 {
        return (0, false)
    }
    levels := ones(len)
    s := imms & levels
    r := immr & levels
    if s == levels {
        return (0, false)
    }
    esize := 1 << len
    welem := ones(s + 1)
    e := ror(welem, r, esize)
    v := 0
    k := 0
    while k < width {
        v |= e << k
        k += esize
    }
    return (v & ones(width), true)
}

// 128-bit products: the upper 64 bits
priv fn umulh(a: i64, b: i64) -> i64 {
    a0 := u64(a) & 0xFFFF_FFFF
    a1 := u64(a) >> 32
    b0 := u64(b) & 0xFFFF_FFFF
    b1 := u64(b) >> 32
    p00 := a0 * b0
    p01 := a0 * b1
    p10 := a1 * b0
    p11 := a1 * b1
    mid := (p00 >> 32) + (p01 & 0xFFFF_FFFF) + (p10 & 0xFFFF_FFFF)
    return i64(p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32))
}

priv fn smulh(a: i64, b: i64) -> i64 {
    h := umulh(a, b)
    if a < 0 {
        h -= b
    }
    if b < 0 {
        h -= a
    }
    return h
}

// ---------- floating point ----------
priv fn f32of(bits: u64) -> f32 {
    return cast[f32](u32(bits))
}

priv fn f64of(bits: u64) -> f64 {
    return cast[f64](bits)
}

priv fn b32(x: f32) -> u64 {
    return u64(cast[u32](x))
}

priv fn b64(x: f64) -> u64 {
    return cast[u64](x)
}

// writes a scalar result: the rest of the register is zeroed
priv fn setv(t: *Th, r: i64, lo: u64) {
    t.vlo[r] = lo
    t.vhi[r] = 0
}

priv fn fcmp_flags(t: *Th, a: f64, b: f64) {
    if a != a || b != b {
        t.n = false
        t.z = false
        t.c = true
        t.v = true
    } else if a == b {
        t.n = false
        t.z = true
        t.c = true
        t.v = false
    } else if a < b {
        t.n = true
        t.z = false
        t.c = false
        t.v = false
    } else {
        t.n = false
        t.z = false
        t.c = true
        t.v = false
    }
}

// FCVTZS: towards zero, saturating, NaN -> 0
priv fn fcvtzs(x: f64, sf: bool) -> i64 {
    if x != x {
        return 0
    }
    if sf {
        if x >= 9223372036854775807.0 {
            return 9223372036854775807
        }
        if x <= -9223372036854775808.0 {
            return -9223372036854775807 - 1
        }
        return i64(x)
    }
    if x >= 2147483647.0 {
        return 2147483647
    }
    if x <= -2147483648.0 {
        return -2147483648 & 0xFFFF_FFFF
    }
    return i64(x) & 0xFFFF_FFFF
}

// lane k (0-3) of a q register as single bits
priv fn lane(t: *Th, r: i64, k: i64) -> u64 {
    w := if k < 2 { t.vlo[r] } else { t.vhi[r] }
    return (w >> u64(32 * (k & 1))) & 0xFFFF_FFFF
}

priv fn set_lane(lo: *u64, hi: *u64, k: i64, v: u64) {
    sh := u64(32 * (k & 1))
    m := u64(0xFFFF_FFFF) << sh
    if k < 2 {
        *lo = (*lo & ~m) | ((v & 0xFFFF_FFFF) << sh)
    } else {
        *hi = (*hi & ~m) | ((v & 0xFFFF_FFFF) << sh)
    }
}

// ---------- the instructions ----------
priv fn unknown(t: *Th, w: i64) -> never {
    eprint(fmt("a64emu: unknown instruction ", hex(u64(w), 8), " at ", hex(u64(t.pc), 8)))
    exit(132)
}

// a load or store of `size` bytes (1, 2, 4, 8, 16) of register rt at address a; v: a SIMD
// register; load kinds: 0 zero-extend, 1 sign-extend to 64, 2 sign-extend to 32
priv fn access(t: *Th, a: i64, size: i64, rt: i64, v: bool, load: bool, ext: i64) {
    if v {
        if load {
            lo := u64(0)
            hi := u64(0)
            match size {
                4 => lo = u64(rd32(a))
                8 => lo = u64(rd64(a))
                _ => {
                    lo = u64(rd64(a))
                    hi = u64(rd64(a + 8))
                }
            }
            if !faulted {
                t.vlo[rt] = lo
                t.vhi[rt] = hi
            }
        } else {
            match size {
                4 => wr32(a, i64(t.vlo[rt]))
                8 => wr64(a, i64(t.vlo[rt]))
                _ => {
                    wr64(a, i64(t.vlo[rt]))
                    wr64(a + 8, i64(t.vhi[rt]))
                }
            }
        }
        return
    }
    if load {
        x := match size {
            1 => rd8(a)
            2 => rd16(a)
            4 => rd32(a)
            _ => rd64(a)
        }
        if faulted {
            return
        }
        if ext == 1 {
            x = sx(x, 8 * size)
        } else if ext == 2 {
            x = sx(x, 8 * size) & 0xFFFF_FFFF
        }
        setr(t, rt, x, true)
    } else {
        x := creg(t, rt)
        match size {
            1 => wr8(a, x)
            2 => wr16(a, x)
            4 => wr32(a, x)
            _ => wr64(a, x)
        }
    }
}

// executes the instruction at t.pc; returns false when the thread stopped (system call that
// blocks or ends it: the scheduler looks again)
priv fn step(t: *Th) -> bool {
    w := rd32(t.pc)
    if faulted {
        return true
    }
    next := t.pc + 4
    rd := w & 31
    rn := (w >> 5) & 31
    rm := (w >> 16) & 31
    sf := (w >> 31) & 1 == 1
    // ---- loads and stores (single register) ----
    if w & 0x0A000000 == 0x08000000 && (w >> 27) & 7 == 7 {
        v := (w >> 26) & 1 == 1
        size := (w >> 30) & 3
        opc := (w >> 22) & 3
        bytes := 1 << size
        load := opc != 0
        ext := 0
        if v {
            load = opc & 1 == 1
            if opc >= 2 {
                bytes = 16
            }
        } else if opc == 2 {
            ext = 1
        } else if opc == 3 {
            ext = 2
        }
        if (w >> 24) & 3 == 1 {
            // unsigned offset
            a := sreg(t, rn) + ((w >> 10) & 0xFFF) * bytes
            access(t, a, bytes, rt_of(w), v, load, ext)
        } else if (w >> 24) & 3 == 0 && (w >> 21) & 1 == 1 && (w >> 10) & 3 == 2 {
            // register offset (LSL or UXTX only)
            opt := (w >> 13) & 7
            if opt != 3 {
                unknown(t, w)
            }
            off := creg(t, rm)
            if (w >> 12) & 1 == 1 {
                off = off << i64(ctz(u64(bytes)))
            }
            access(t, sreg(t, rn) + off, bytes, rt_of(w), v, load, ext)
        } else if (w >> 24) & 3 == 0 && (w >> 21) & 1 == 0 {
            imm := sx((w >> 12) & 0x1FF, 9)
            mode := (w >> 10) & 3
            base := sreg(t, rn)
            match mode {
                0 => access(t, base + imm, bytes, rt_of(w), v, load, ext)
                1 => {
                    access(t, base, bytes, rt_of(w), v, load, ext)
                    if !faulted {
                        sets(t, rn, base + imm, true)
                    }
                }
                3 => {
                    access(t, base + imm, bytes, rt_of(w), v, load, ext)
                    if !faulted {
                        sets(t, rn, base + imm, true)
                    }
                }
                _ => unknown(t, w)
            }
        } else {
            unknown(t, w)
        }
        t.pc = next
        return true
    }
    // ---- load / store pair ----
    if w & 0x3A000000 == 0x28000000 {
        v := (w >> 26) & 1 == 1
        opc := (w >> 30) & 3
        mode := (w >> 23) & 3
        load := (w >> 22) & 1 == 1
        rt2 := (w >> 10) & 31
        scale := if v { 4 << opc } else { if opc == 2 { 8 } else { 4 } }
        off := sx((w >> 15) & 0x7F, 7) * scale
        base := sreg(t, rn)
        a := if mode == 1 { base } else { base + off }
        if mode == 0 {
            unknown(t, w)
        }
        access(t, a, scale, rd, v, load, 0)
        access(t, a + scale, scale, rt2, v, load, 0)
        if !faulted && mode != 2 {
            sets(t, rn, base + off, true)
        }
        t.pc = next
        return true
    }
    // ---- add / subtract (immediate) ----
    if (w >> 23) & 0x3F == 0x22 {
        sub := (w >> 30) & 1 == 1
        setf := (w >> 29) & 1 == 1
        imm := ((w >> 10) & 0xFFF) << (if (w >> 22) & 1 == 1 { 12 } else { 0 })
        r := addf(t, sreg(t, rn), imm, sub, sf, setf)
        if setf {
            setr(t, rd, r, sf)
        } else {
            sets(t, rd, r, sf)
        }
        t.pc = next
        return true
    }
    // ---- logical (immediate) ----
    if (w >> 23) & 0x3F == 0x24 {
        opc := (w >> 29) & 3
        imm, ok := bitmask((w >> 22) & 1, (w >> 16) & 0x3F, (w >> 10) & 0x3F, if sf { 64 } else { 32 })
        if !ok {
            unknown(t, w)
        }
        a := creg(t, rn)
        r := match opc {
            0 => a & imm
            1 => a | imm
            2 => a ^ imm
            _ => a & imm
        }
        r = r & ones(if sf { 64 } else { 32 })
        if opc == 3 {
            t.n = if sf { r < 0 } else { (r >> 31) & 1 == 1 }
            t.z = r == 0
            t.c = false
            t.v = false
            setr(t, rd, r, sf)
        } else {
            sets(t, rd, r, sf)
        }
        t.pc = next
        return true
    }
    // ---- move wide ----
    if (w >> 23) & 0x3F == 0x25 {
        opc := (w >> 29) & 3
        hw := (w >> 21) & 3
        imm := ((w >> 5) & 0xFFFF) << (16 * hw)
        r := match opc {
            0 => ~imm
            2 => imm
            3 => (creg(t, rd) & ~(0xFFFF << (16 * hw))) | imm
            _ => unknown(t, w)
        }
        setr(t, rd, r, sf)
        t.pc = next
        return true
    }
    // ---- bitfield ----
    if (w >> 23) & 0x3F == 0x26 {
        opc := (w >> 29) & 3
        width := if sf { 64 } else { 32 }
        immr := (w >> 16) & 0x3F
        imms := (w >> 10) & 0x3F
        src := creg(t, rn) & ones(width)
        r := 0
        if imms >= immr {
            fw := imms - immr + 1
            field := i64(u64(src) >> u64(immr)) & ones(fw)
            r = match opc {
                0 => sx(field, fw) & ones(width)
                1 => (creg(t, rd) & ~ones(fw)) | field
                _ => field
            }
        } else {
            fw := imms + 1
            pos := width - immr
            field := (src & ones(fw)) << pos
            r = match opc {
                0 => (sx(src & ones(fw), fw) << pos) & ones(width)
                1 => (creg(t, rd) & ~(ones(fw) << pos)) | field
                _ => field & ones(width)
            }
        }
        if opc == 3 {
            unknown(t, w)
        }
        setr(t, rd, r, sf)
        t.pc = next
        return true
    }
    // ---- EXTR ----
    if (w >> 23) & 0x3F == 0x27 && (w >> 29) & 3 == 0 {
        width := if sf { 64 } else { 32 }
        lsb := (w >> 10) & 0x3F
        hi := creg(t, rn) & ones(width)
        lo := creg(t, rm) & ones(width)
        r := if lsb == 0 { lo } else { (i64(u64(lo) >> u64(lsb)) | (hi << (width - lsb))) & ones(width) }
        setr(t, rd, r, sf)
        t.pc = next
        return true
    }
    // ---- branches ----
    if w & 0x7C000000 == 0x14000000 {
        if (w >> 31) == 1 {
            t.x[30] = next
        }
        t.pc = t.pc + 4 * sx(w & 0x3FFFFFF, 26)
        return true
    }
    if w & 0xFF000010 == 0x54000000 {
        t.pc = if cond(t, w & 15) { t.pc + 4 * sx((w >> 5) & 0x7FFFF, 19) } else { next }
        return true
    }
    if w & 0x7E000000 == 0x34000000 {
        x := creg(t, rd) & ones(if sf { 64 } else { 32 })
        nz := (w >> 24) & 1 == 1
        t.pc = if (x != 0) == nz { t.pc + 4 * sx((w >> 5) & 0x7FFFF, 19) } else { next }
        return true
    }
    match w & 0xFFFFFC1F {
        0xD61F0000 => {
            t.pc = creg(t, rn)
            return true
        }
        0xD63F0000 => {
            target := creg(t, rn)
            t.x[30] = next
            t.pc = target
            return true
        }
        0xD65F0000 => {
            t.pc = creg(t, rn)
            return true
        }
        _ => {}
    }
    // ---- add / subtract, logical (registers) ----
    if w & 0x1F000000 == 0x0B000000 {
        sub := (w >> 30) & 1 == 1
        setf := (w >> 29) & 1 == 1
        if (w >> 21) & 1 == 0 {
            b := shifted(creg(t, rm), (w >> 22) & 3, (w >> 10) & 0x3F, sf)
            r := addf(t, creg(t, rn), b, sub, sf, setf)
            setr(t, rd, r, sf)
        } else {
            // extended register: UXTX / LSL #0 only
            if (w >> 10) & 0x3F != 0x18 {
                unknown(t, w)
            }
            r := addf(t, sreg(t, rn), creg(t, rm), sub, sf, setf)
            if setf {
                setr(t, rd, r, sf)
            } else {
                sets(t, rd, r, sf)
            }
        }
        t.pc = next
        return true
    }
    if w & 0x1F000000 == 0x0A000000 {
        opc := (w >> 29) & 3
        b := shifted(creg(t, rm), (w >> 22) & 3, (w >> 10) & 0x3F, sf)
        if (w >> 21) & 1 == 1 {
            b = ~b & ones(if sf { 64 } else { 32 })
        }
        a := creg(t, rn)
        r := match opc {
            0 => a & b
            1 => a | b
            2 => a ^ b
            _ => a & b
        }
        r = r & ones(if sf { 64 } else { 32 })
        if opc == 3 {
            t.n = if sf { r < 0 } else { (r >> 31) & 1 == 1 }
            t.z = r == 0
            t.c = false
            t.v = false
        }
        setr(t, rd, r, sf)
        t.pc = next
        return true
    }
    // ---- data processing (register) ----
    if w & 0x7FE00000 == 0x1AC00000 {
        op := (w >> 10) & 0x3F
        width := if sf { 64 } else { 32 }
        a := creg(t, rn) & ones(width)
        b := creg(t, rm) & ones(width)
        r := match op {
            2 => if b == 0 { 0 } else { i64(u64(a) / u64(b)) }
            3 => {
                sa := if sf { a } else { sx(a, 32) }
                sb := if sf { b } else { sx(b, 32) }
                if sb == 0 {
                    0
                } else if sb == -1 {
                    -sa
                } else {
                    sa / sb
                }
            }
            8 => shifted(a, 0, b & (width - 1), sf)
            9 => shifted(a, 1, b & (width - 1), sf)
            10 => shifted(a, 2, b & (width - 1), sf)
            11 => shifted(a, 3, b & (width - 1), sf)
            _ => unknown(t, w)
        }
        setr(t, rd, r, sf)
        t.pc = next
        return true
    }
    if w & 0x7FFF0000 == 0x5AC00000 {
        op := (w >> 10) & 0x3F
        width := if sf { 64 } else { 32 }
        a := creg(t, rn) & ones(width)
        r := 0
        match op {
            0 => {
                // RBIT
                for k in 0..width {
                    if (a >> k) & 1 == 1 {
                        r |= 1 << (width - 1 - k)
                    }
                }
            }
            1 => {
                // REV16: the bytes of each halfword
                for k in 0..width / 16 {
                    h := (a >> (16 * k)) & 0xFFFF
                    r |= (((h & 0xFF) << 8) | (h >> 8)) << (16 * k)
                }
            }
            2, 3 => {
                // REV (32-bit) / REV32 (op 2, 64-bit) / REV (op 3, 64-bit)
                chunk := if op == 3 || !sf { width } else { 32 }
                for c in 0..width / chunk {
                    x := (a >> (chunk * c)) & ones(chunk)
                    y := 0
                    for k in 0..chunk / 8 {
                        y |= ((x >> (8 * k)) & 0xFF) << (chunk - 8 - 8 * k)
                    }
                    r |= y << (chunk * c)
                }
            }
            4 => r = if a == 0 { width } else { i64(clz(u64(a))) - (64 - width) }
            _ => unknown(t, w)
        }
        setr(t, rd, r, sf)
        t.pc = next
        return true
    }
    if w & 0x7F000000 == 0x1B000000 {
        ra := (w >> 10) & 31
        op31 := (w >> 21) & 7
        o0 := (w >> 15) & 1
        a := creg(t, rn)
        b := creg(t, rm)
        r := 0
        match op31 {
            0 => {
                p := a * b
                r = if o0 == 0 { creg(t, ra) + p } else { creg(t, ra) - p }
            }
            1 => r = creg(t, ra) + sx(a & 0xFFFF_FFFF, 32) * sx(b & 0xFFFF_FFFF, 32)
            5 => r = creg(t, ra) + (a & 0xFFFF_FFFF) * (b & 0xFFFF_FFFF)
            2 => r = smulh(a, b)
            6 => r = umulh(a, b)
            _ => unknown(t, w)
        }
        if (op31 == 1 || op31 == 5) && o0 == 1 {
            unknown(t, w)
        }
        setr(t, rd, r, sf)
        t.pc = next
        return true
    }
    if w & 0x1FE00000 == 0x1A800000 {
        op := ((w >> 30) & 1) << 1 | ((w >> 10) & 1)
        ok := cond(t, (w >> 12) & 15)
        b := creg(t, rm)
        r := if ok { creg(t, rn) } else {
            match op {
                0 => b
                1 => b + 1
                2 => ~b
                _ => -b
            }
        }
        setr(t, rd, r, sf)
        t.pc = next
        return true
    }
    // ---- system ----
    if w & 0xFFE0001F == 0xD4000001 {
        t.pc = next
        return syscall_(t)
    }
    if w & 0xFFE0001F == 0xD4200000 {
        if handlers[5] == 0 {
            eprint(fmt("a64emu: brk at ", hex(u64(t.pc), 8)))
            exit(133)
        }
        faulted = true
        fault_sig = 5
        fault_addr = t.pc
        return true
    }
    if w & 0xFFFFFFE0 == 0xD53BD040 {
        setr(t, rd, t.tp, true)
        t.pc = next
        return true
    }
    if w & 0xFFFFFFE0 == 0xD51BD040 {
        t.tp = creg(t, rd)
        t.pc = next
        return true
    }
    if w == 0xD5033BBF || w == 0xD503201F || w == 0xD503305F {
        if w == 0xD503305F {
            t.excl = -1
        }
        t.pc = next
        return true
    }
    if w & 0x1F000000 == 0x10000000 {
        imm := sx(((w >> 5) & 0x7FFFF) << 2 | (w >> 29) & 3, 21)
        if (w >> 31) == 1 {
            setr(t, rd, (t.pc & ~0xFFF) + (imm << 12), true)
        } else {
            setr(t, rd, t.pc + imm, true)
        }
        t.pc = next
        return true
    }
    // ---- exclusive and acquire / release ----
    if w & 0x3F000000 == 0x08000000 {
        size := 1 << ((w >> 30) & 3)
        a := sreg(t, rn)
        match w & 0x3FFFFC00 {
            0x085FFC00 => {
                // LDAXR
                access(t, a, size, rd, false, true, 0)
                t.excl = a
            }
            0x08DFFC00 => access(t, a, size, rd, false, true, 0)
            0x089FFC00 => access(t, a, size, rd, false, false, 0)
            _ => {
                if w & 0x3FE0FC00 == 0x0800FC00 {
                    // STLXR: status 0 if the monitor still holds this address
                    if t.excl == a {
                        access(t, a, size, rd, false, false, 0)
                        setr(t, rm, 0, false)
                    } else {
                        setr(t, rm, 1, false)
                    }
                    t.excl = -1
                } else {
                    unknown(t, w)
                }
            }
        }
        t.pc = next
        return true
    }
    // ---- scalar floating point ----
    if w & 0x7F200000 == 0x1E200000 {
        ft := (w >> 22) & 3
        dbl := ft == 1
        if ft >= 2 {
            unknown(t, w)
        }
        rnv := rn
        a := if dbl { f64of(t.vlo[rnv]) } else { f64(f32of(t.vlo[rnv])) }
        if (w >> 10) & 3 == 2 {
            // two sources
            op := (w >> 12) & 15
            if dbl {
                x := f64of(t.vlo[rn])
                y := f64of(t.vlo[rm])
                r := match op {
                    0 => x * y
                    1 => x / y
                    2 => x + y
                    3 => x - y
                    _ => unknown(t, w)
                }
                setv(t, rd, b64(r))
            } else {
                x := f32of(t.vlo[rn])
                y := f32of(t.vlo[rm])
                r := match op {
                    0 => x * y
                    1 => x / y
                    2 => x + y
                    3 => x - y
                    _ => unknown(t, w)
                }
                setv(t, rd, b32(r))
            }
            t.pc = next
            return true
        }
        if (w >> 10) & 3 == 3 {
            // FCSEL
            ok := cond(t, (w >> 12) & 15)
            src := if ok { rn } else { rm }
            setv(t, rd, if dbl { t.vlo[src] } else { t.vlo[src] & 0xFFFF_FFFF })
            t.pc = next
            return true
        }
        if (w >> 10) & 0x1F == 0x10 {
            // one source
            op := (w >> 15) & 0x3F
            if dbl {
                x := f64of(t.vlo[rn])
                match op {
                    0 => setv(t, rd, t.vlo[rn])
                    1 => setv(t, rd, t.vlo[rn] & 0x7FFF_FFFF_FFFF_FFFF)
                    2 => setv(t, rd, t.vlo[rn] ^ 0x8000_0000_0000_0000)
                    3 => setv(t, rd, b64(sqrt(x)))
                    4 => setv(t, rd, b32(f32(x)))
                    _ => unknown(t, w)
                }
            } else {
                x := f32of(t.vlo[rn])
                lo := t.vlo[rn] & 0xFFFF_FFFF
                match op {
                    0 => setv(t, rd, lo)
                    1 => setv(t, rd, lo & 0x7FFF_FFFF)
                    2 => setv(t, rd, lo ^ 0x8000_0000)
                    3 => setv(t, rd, b32(sqrt(x)))
                    5 => setv(t, rd, b64(f64(x)))
                    _ => unknown(t, w)
                }
            }
            t.pc = next
            return true
        }
        if (w >> 10) & 0xF == 8 && w & 0x1F == 0 {
            // FCMP
            b := if dbl { f64of(t.vlo[rm]) } else { f64(f32of(t.vlo[rm])) }
            fcmp_flags(t, a, b)
            t.pc = next
            return true
        }
        if (w >> 10) & 0x3F == 0 {
            // conversions between general and floating-point registers
            k := (w >> 16) & 31
            match k {
                2 => {
                    // SCVTF
                    x := if sf { creg(t, rn) } else { sx(creg(t, rn) & 0xFFFF_FFFF, 32) }
                    setv(t, rd, if dbl { b64(f64(x)) } else { b32(f32(x)) })
                }
                0x18 => setr(t, rd, fcvtzs(a, sf), sf)
                6 => setr(t, rd, i64(t.vlo[rn]) & ones(if sf { 64 } else { 32 }), sf)
                7 => setv(t, rd, u64(creg(t, rn)) & u64(ones(if sf { 64 } else { 32 })))
                _ => unknown(t, w)
            }
            t.pc = next
            return true
        }
        unknown(t, w)
    }
    // ---- SIMD ----
    simd(t, w)
    t.pc = next
    return true
}

priv fn rt_of(w: i64) -> i64 {
    return w & 31
}

priv fn simd(t: *Th, w: i64) {
    rd := w & 31
    rn := (w >> 5) & 31
    rm := (w >> 16) & 31
    match w & 0xFFE0FC00 {
        0x4E20D400, 0x4EA0D400, 0x6E20DC00, 0x6E20FC00, 0x4E20F400, 0x4EA0F400, 0x6EA0E400 => {
            lo := u64(0)
            hi := u64(0)
            for k in 0..4 {
                x := f32of(lane(t, rn, k))
                y := f32of(lane(t, rm, k))
                r := match w & 0xFFE0FC00 {
                    0x4E20D400 => b32(x + y)
                    0x4EA0D400 => b32(x - y)
                    0x6E20DC00 => b32(x * y)
                    0x6E20FC00 => b32(x / y)
                    0x4E20F400 => b32(if x > y { x } else { y })
                    0x4EA0F400 => b32(if x < y { x } else { y })
                    _ => if x > y { u64(0xFFFF_FFFF) } else { 0 }
                }
                set_lane(&lo, &hi, k, r)
            }
            t.vlo[rd] = lo
            t.vhi[rd] = hi
            return
        }
        0x4EA01C00 => {
            // ORR (MOV)
            lo := t.vlo[rn] | t.vlo[rm]
            hi := t.vhi[rn] | t.vhi[rm]
            t.vlo[rd] = lo
            t.vhi[rd] = hi
            return
        }
        0x6E601C00 => {
            // BSL
            m0 := t.vlo[rd]
            m1 := t.vhi[rd]
            t.vlo[rd] = (m0 & t.vlo[rn]) | (~m0 & t.vlo[rm])
            t.vhi[rd] = (m1 & t.vhi[rn]) | (~m1 & t.vhi[rm])
            return
        }
        _ => {}
    }
    match w & 0xFFFFFC00 {
        0x4EA0F800, 0x6EA0F800, 0x6EA1F800 => {
            lo := u64(0)
            hi := u64(0)
            for k in 0..4 {
                x := lane(t, rn, k)
                r := match w & 0xFFFFFC00 {
                    0x4EA0F800 => x & 0x7FFF_FFFF
                    0x6EA0F800 => x ^ 0x8000_0000
                    _ => b32(sqrt(f32of(x)))
                }
                set_lane(&lo, &hi, k, r)
            }
            t.vlo[rd] = lo
            t.vhi[rd] = hi
            return
        }
        0x0E205800 => {
            // CNT .8b: the bits of each of the low 8 bytes
            x := t.vlo[rn]
            r := u64(0)
            for k in 0..8 {
                r |= u64(popcnt((x >> u64(8 * k)) & 0xFF)) << u64(8 * k)
            }
            setv(t, rd, r)
            return
        }
        0x0E31B800 => {
            // ADDV b, .8b
            x := t.vlo[rn]
            s := u64(0)
            for k in 0..8 {
                s += (x >> u64(8 * k)) & 0xFF
            }
            setv(t, rd, s & 0xFF)
            return
        }
        _ => {}
    }
    if w & 0xFFE0FC00 == 0x4E000400 && (w >> 16) & 7 == 4 {
        // DUP .4s, v.s[i]
        x := lane(t, rn, (w >> 19) & 3)
        both := x | (x << 32)
        t.vlo[rd] = both
        t.vhi[rd] = both
        return
    }
    if w & 0xFFE0FC00 == 0x5E000400 && (w >> 16) & 7 == 4 {
        // DUP s, v.s[i]
        setv(t, rd, lane(t, rn, (w >> 19) & 3))
        return
    }
    if w & 0xFFE08400 == 0x6E000400 && (w >> 16) & 7 == 4 {
        // INS v.s[i], v.s[j]
        x := lane(t, rn, (w >> 13) & 3)
        lo := t.vlo[rd]
        hi := t.vhi[rd]
        set_lane(&lo, &hi, (w >> 19) & 3, x)
        t.vlo[rd] = lo
        t.vhi[rd] = hi
        return
    }
    if w & 0xFFFFFFE0 == 0x6F00E400 {
        t.vlo[rd] = 0
        t.vhi[rd] = 0
        return
    }
    unknown(t, w)
}

// ---------- system calls ----------
// guest descriptors: the host descriptor (-1: free); a directory opened for getdents64 keeps
// its path and whether it was read
priv struct Fd {
    host: i64
    dir: str
    is_dir: bool
    done: bool
}

priv fds: Vec[Fd]

priv fn new_fd(f: Fd) -> i64 {
    for k in 3..fds.len {
        if fds[k].host == -1 && !fds[k].is_dir {
            fds[k] = f
            return k
        }
    }
    fds.push(f)
    return fds.len - 1
}

priv fn host_fd(fd: i64) -> i64 {
    if fd < 0 || fd >= fds.len {
        return -1
    }
    return fds[fd].host
}

priv const AT_FDCWD = -100

// a guest path relative to the working directory (only AT_FDCWD is supported)
priv fn gpath(dfd: i64, p: i64) -> str {
    return gstr(p)
}

// a stand-in for the inode of a file: a number per absolute, normalised path (the compiler
// tells files apart by device and inode)
priv inodes: Map[str, i64]

priv fn inode(path: str) -> i64 {
    p := if len(path) > 0 && (path[0] == '/' || (len(path) > 1 && path[1] == ':')) { path } else { fmt(__os_current_dir(), "/", path) }
    parts := vec[str]()
    for c in split(replace(p, "\\", "/"), '/') {
        if c == "" || c == "." {
            continue
        }
        if c == ".." {
            if parts.len > 0 {
                parts.pop()
            }
            continue
        }
        parts.push(to_lower(c))
    }
    key := join(parts.items(), "/")
    n, has := inodes.get(key)
    if !has {
        n = inodes.len + 2
        inodes.set(key, n)
    }
    return n
}

priv fn write_stat(st: i64, mode: i64, size: i64, mtime_ns: i64, ino: i64) {
    for k in 0..16 {
        wr64(st + 8 * k, 0)
    }
    wr64(st, 1)
    wr64(st + 8, ino)
    wr32(st + 16, mode)
    wr32(st + 20, 1)
    wr64(st + 48, size)
    wr32(st + 56, 4096)
    wr64(st + 88, mtime_ns / 1000000000)
    wr64(st + 96, mtime_ns % 1000000000)
}

priv fn syscall_(t: *Th) -> bool {
    nr := t.x[8]
    a0 := t.x[0]
    a1 := t.x[1]
    a2 := t.x[2]
    a3 := t.x[3]
    a4 := t.x[4]
    r := -38 // ENOSYS
    match nr {
        63 => {
            // read
            h := host_fd(a0)
            if h < 0 {
                r = -9
            } else {
                b := gbytes(a1, a2)
                r = if faulted { -14 } else { __os_read(h, cast[i64](ptr(b)), a2) }
            }
        }
        64 => {
            // write
            h := host_fd(a0)
            if h < 0 {
                r = -9
            } else {
                b := gbytes(a1, a2)
                if faulted {
                    r = -14
                } else {
                    e := __write_all(h, cast[i64](ptr(b)), a2)
                    r = if e == 0 { a2 } else { -e }
                }
            }
        }
        56 => {
            // openat(dfd, path, flags, mode)
            p := gpath(a0, a1)
            flags := a2
            if flags & 0x4000 != 0 {
                kind, _, _ := __os_stat(cstr(p))
                r = if kind == 2 { new_fd(Fd{host: -1, dir: p, is_dir: true}) } else if kind < 0 { -2 } else { -20 }
            } else {
                write := flags & 3 != 0
                h := __os_open(cstr(p), write)
                r = if h < 0 { h } else { new_fd(Fd{host: h, dir: p}) }
            }
        }
        57 => {
            // close
            if a0 >= 3 && a0 < fds.len && (fds[a0].host >= 0 || fds[a0].is_dir) {
                if fds[a0].host >= 0 {
                    __os_close(fds[a0].host)
                }
                fds[a0] = Fd{host: -1}
                r = 0
            } else {
                r = if a0 >= 0 && a0 < 3 { 0 } else { -9 }
            }
        }
        80 => {
            // fstat
            h := host_fd(a0)
            if a0 >= 0 && a0 < fds.len && fds[a0].is_dir {
                write_stat(a1, 0x41ED, 4096, 0, inode(fds[a0].dir))
                r = 0
            } else if h < 0 {
                r = -9
            } else {
                size, reg := __os_fstat(h)
                if size < 0 && !reg {
                    // a terminal or pipe
                    write_stat(a1, 0x2190, 0, 0, 1000000 + a0)
                } else {
                    write_stat(a1, if reg { 0x81A4 } else { 0x1180 }, max(size, 0), 0, if len(fds[a0].dir) > 0 { inode(fds[a0].dir) } else { 1000000 + a0 })
                }
                r = 0
            }
        }
        79 => {
            // newfstatat(dfd, path, st, flags)
            p := gpath(a0, a1)
            kind, size, mtime := __os_stat(cstr(p))
            if kind < 0 {
                r = -2
            } else {
                write_stat(a2, if kind == 1 { 0x81A4 } else if kind == 2 { 0x41ED } else { 0x2190 }, size, mtime, inode(p))
                r = 0
            }
        }
        61 => {
            // getdents64: all entries at once, then 0
            if a0 < 0 || a0 >= fds.len || !fds[a0].is_dir {
                r = -9
            } else if fds[a0].done {
                r = 0
            } else {
                names := vec[str]()
                e := __os_list_dir(cstr(fds[a0].dir), &names)
                if e < 0 {
                    r = e
                } else {
                    off := 0
                    for nm in names {
                        reclen := align_up(19 + len(nm) + 1, 8)
                        if off + reclen > a2 {
                            break
                        }
                        wr64(a1 + off, 1)
                        wr64(a1 + off + 8, off + reclen)
                        wr16(a1 + off + 16, reclen)
                        wr8(a1 + off + 18, 0)
                        for k in 0..len(nm) {
                            wr8(a1 + off + 19 + k, i64(nm[k]))
                        }
                        wr8(a1 + off + 19 + len(nm), 0)
                        off += reclen
                    }
                    fds[a0].done = true
                    r = off
                }
            }
        }
        34 => r = __os_make_dir(cstr(gpath(a0, a1)))
        35 => {
            p := cstr(gpath(a0, a1))
            r = if a2 & 0x200 != 0 { __os_remove_dir(p) } else { __os_remove_file(p) }
        }
        38 => r = __os_rename(cstr(gpath(a0, a1)), cstr(gpath(a2, a3)))
        48 => {
            kind, _, _ := __os_stat(cstr(gpath(a0, a1)))
            r = if kind < 0 { -2 } else { 0 }
        }
        53 => r = 0 // fchmodat
        17 => {
            // getcwd
            d := __os_current_dir()
            if len(d) + 1 > a1 {
                r = -34
            } else {
                for k in 0..len(d) {
                    wr8(a0 + k, i64(d[k]))
                }
                wr8(a0 + len(d), 0)
                r = len(d) + 1
            }
        }
        222 => {
            // mmap(addr, len, prot, flags, fd, off): anonymous memory only
            n := align_up(a1, 0x10000)
            if a4 != -1 && a3 & 0x20 == 0 {
                r = -19
            } else if a3 & 0x10 != 0 {
                // MAP_FIXED over memory of the guest (ALC_CHECK_MEMORY): left as it is
                r = a0
            } else if n <= 0 {
                r = -22
            } else {
                p := reserve(n)
                if p == 0 {
                    r = -12
                } else {
                    add_region(p, p + n, 0, p, p)
                    r = p
                }
            }
        }
        215 => {
            // munmap
            for g in regions {
                if g.lo == a0 && g.delta == 0 {
                    release(g.lo, g.hi - g.lo)
                    drop_region(g.lo)
                    break
                }
            }
            r = 0
        }
        226 => {
            // mprotect: PROT_NONE at the start of a region (the guard page below a thread's
            // stack) takes those pages out of it, so that an overflow faults; anything else is
            // accepted as it is
            if a2 == 0 {
                for k in 0..regions.len {
                    g := &regions[k]
                    if g.lo == a0 && a0 + a1 < g.hi {
                        g.lo = a0 + a1
                        g.clo = max(g.clo, g.lo)
                        g.chi = max(g.chi, g.clo)
                    }
                }
                for k in 0..4 {
                    cache[k] = Region{}
                }
            }
            r = 0
        }
        93 => {
            // exit: this thread
            t.wait = 3
            if t.clear_tid != 0 {
                wr32(t.clear_tid, 0)
                wake(t.clear_tid, 0x7FFFFFFF)
            }
            return false
        }
        94 => {
            exit_code = a0 & 255
            return false
        }
        113 => {
            // clock_gettime
            ns := if a0 == 0 { __os_wall_time() * 1000000000 } else { clock_ns() }
            wr64(a1, ns / 1000000000)
            wr64(a1 + 8, ns % 1000000000)
            r = 0
        }
        101 => {
            // nanosleep(req, rem)
            ns := rd64(a0) * 1000000000 + rd64(a0 + 8)
            t.wait = 2
            t.wake_at = clock_ns() + ns
            t.x[0] = 0
            return false
        }
        98 => {
            // futex(addr, op, val, timeout)
            op := a1 & 127
            if op == 0 {
                if rd32(a0) != (a2 & 0xFFFF_FFFF) {
                    r = -11
                } else {
                    t.wait = 1
                    t.wait_addr = a0
                    t.wake_at = if a3 != 0 { clock_ns() + rd64(a3) * 1000000000 + rd64(a3 + 8) } else { 0 }
                    t.x[0] = 0
                    return false
                }
            } else if op == 1 {
                r = wake(a0, a2)
            }
        }
        220 => r = clone(t, a0, a1, a2, a3, a4)
        132 => {
            // sigaltstack(new, old)
            if a0 != 0 {
                t.alt_lo = rd64(a0)
                t.alt_size = rd64(a0 + 16)
                if rd32(a0 + 8) & 2 != 0 {
                    t.alt_size = 0
                }
            }
            r = 0
        }
        134 => {
            // rt_sigaction(sig, act, old, size)
            if a1 != 0 && a0 > 0 && a0 < 32 {
                handlers[a0] = rd64(a1)
            }
            r = 0
        }
        135 => r = 0 // rt_sigprocmask
        123 => {
            // sched_getaffinity: one CPU (the threads run one after the other)
            wr64(a2, 1)
            r = 8
        }
        172 => r = __os_process_id()
        178 => r = t.tid
        163 => {
            // getrlimit: unlimited
            wr64(a1, -1)
            wr64(a1 + 8, -1)
            r = 0
        }
        164, 154 => r = 0
        129 => r = 0
        73 => {
            // ppoll without descriptors: waits forever (a thread while another one panics)
            if a1 == 0 {
                t.wait = 2
                t.wake_at = clock_ns() + 1000000000000
                return false
            }
            r = a1
        }
        _ => {}
    }
    if faulted {
        // (a bad pointer given to a system call: EFAULT)
        faulted = false
        r = -14
    }
    t.x[0] = r
    return true
}

// wakes up to n threads waiting at addr: their number
priv fn wake(addr: i64, n: i64) -> i64 {
    k := 0
    for th in threads {
        if k >= n {
            break
        }
        if th.wait == 1 && th.wait_addr == addr {
            th.wait = 0
            k += 1
        }
    }
    return k
}

// clone(flags, stack, ptid, tls, ctid) of a thread in the same address space
priv fn clone(t: *Th, flags: i64, stack: i64, ptid: i64, tls: i64, ctid: i64) -> i64 {
    if flags & 0x100 == 0 {
        // a new process: not emulated
        return -38
    }
    cs := alloc[Th](1)
    c := &cs[0]
    *c = *t
    c.x[0] = 0
    c.sp = stack
    c.tid = next_tid
    next_tid += 1
    c.excl = -1
    c.wait = 0
    c.in_signal = false
    c.alt_size = 0
    if flags & 0x80000 != 0 {
        c.tp = tls
    }
    if flags & 0x100000 != 0 {
        wr32(ptid, c.tid)
    }
    if flags & 0x200000 != 0 {
        c.clear_tid = ctid
    }
    threads.push(c)
    return c.tid
}

// a fault of the running instruction: to the signal handler on the alternate stack (the
// layer's __on_fault reads si_addr at info + 16 and pc in the ucontext at 176 + 8 + 8 * 32)
priv fn deliver(t: *Th) {
    a := fault_addr
    sig := fault_sig
    faulted = false
    fault_sig = 11
    h := handlers[sig]
    if h == 0 || t.in_signal {
        eprint(fmt("a64emu: segmentation fault at ", hex(u64(t.pc), 8), ", address ", hex(u64(a), 8)))
        exit(139)
    }
    t.in_signal = true
    top := if t.alt_size > 0 { t.alt_lo + t.alt_size } else { t.sp - 4096 }
    top = (top - 2048) & ~15
    info := top
    uc := top + 256
    for k in 0..(256 + 600) / 8 {
        wr64(top + 8 * k, 0)
    }
    wr32(info, sig)
    wr64(info + 16, a)
    for k in 0..31 {
        wr64(uc + 184 + 8 * k, t.x[k])
    }
    wr64(uc + 184 + 248, t.sp)
    wr64(uc + 184 + 256, t.pc)
    if faulted {
        eprint(fmt("a64emu: fault while delivering a fault at ", hex(u64(t.pc), 8)))
        exit(139)
    }
    t.x[0] = sig
    t.x[1] = info
    t.x[2] = uc
    t.x[30] = 0
    t.sp = top
    t.pc = h
}

// ---------- loading ----------
priv fn load(path: str, argv: []str) -> *Th {
    b, ok := read_file(path)
    if !ok || len(b) < 64 || b[..4] != "\x7FELF" {
        eprint(fmt("a64emu: cannot read the ELF file ", path))
        exit(127)
    }
    fn u16_(b: str, at: i64) -> i64 {
        return i64(b[at]) | i64(b[at + 1]) << 8
    }
    fn u64_(b: str, at: i64) -> i64 {
        x := 0
        for k in 0..8 {
            x |= i64(b[at + k]) << (8 * k)
        }
        return x
    }
    if u16_(b, 18) != 183 {
        eprint(fmt("a64emu: ", path, " is not an AArch64 executable"))
        exit(127)
    }
    entry := u64_(b, 24)
    phoff := u64_(b, 32)
    phnum := u16_(b, 56)
    hi := BASE
    for k in 0..phnum {
        h := phoff + 56 * k
        if u16_(b, h) == 1 {
            hi = max(hi, u64_(b, h + 16) + u64_(b, h + 40))
        }
    }
    size := align_up(hi - BASE, 0x10000)
    img := reserve(size)
    if img == 0 || !commit(img, size) {
        eprint("a64emu: no memory for the image")
        exit(127)
    }
    for k in 0..phnum {
        h := phoff + 56 * k
        if u16_(b, h) == 1 {
            off := u64_(b, h + 8)
            va := u64_(b, h + 16)
            fsz := u64_(b, h + 32)
            memcopy(cast[*u8](img + (va - BASE)), cast[*u8](cast[i64](ptr(b)) + off), fsz)
        }
    }
    add_region(BASE, BASE + size, img - BASE, BASE, BASE + size)
    // the stack: 8 MiB as Linux gives by default (A64EMU_STACK_MB=n: n MiB), committed as it
    // is used. (getrlimit reports no limit: the compiler then does not start itself again for
    // a bigger stack, which the emulator could not do; give it one with A64EMU_STACK_MB.)
    ssize := 8 << 20
    sv, sset := env_get("A64EMU_STACK_MB")
    if sset {
        mb, mok := parse_i64(sv)
        if mok && mb >= 1 && mb <= 4096 {
            ssize = mb << 20
        }
    }
    s := reserve(ssize)
    if s == 0 {
        eprint("a64emu: no memory for the stack")
        exit(127)
    }
    add_region(s, s + ssize, 0, s + ssize, s + ssize)
    // strings, then auxv, envp, argv, argc (the layout of the Linux kernel)
    p := s + ssize - 64
    fn put_str(p: *i64, x: str) -> i64 {
        *p -= len(x) + 1
        for k in 0..len(x) {
            wr8(*p + k, i64(x[k]))
        }
        wr8(*p + len(x), 0)
        return *p
    }
    aptrs := vec[i64]()
    for x in argv {
        aptrs.push(put_str(&p, x))
    }
    eptrs := vec[i64]()
    for x in host_env() {
        eptrs.push(put_str(&p, x))
    }
    p = (p - 16) & ~15
    rnd := p
    wr64(rnd, 0x0123456789ABCDEF)
    wr64(rnd + 8, 0x0FEDCBA987654321)
    words := vec[i64]()
    words.push(argv.len)
    words.extend(aptrs.items())
    words.push(0)
    words.extend(eptrs.items())
    words.push(0)
    for kv in [](i64, i64){(3, BASE + phoff), (4, 56), (5, phnum), (6, 4096), (9, entry), (25, rnd), (0, 0)} {
        words.push(kv.0)
        words.push(kv.1)
    }
    sp := (p - 8 * words.len) & ~15
    for k, x in words {
        wr64(sp + 8 * k, x)
    }
    t := alloc[Th](1)
    t[0].sp = sp
    t[0].pc = entry
    t[0].tid = 1
    t[0].excl = -1
    return &t[0]
}

// the environment of the host, as NAME=value strings
priv fn host_env() -> []str {
    out := vec[str]()
    for name in []str{"PATH", "HOME", "ALC_BACKTRACE", "ALC_CHECK_MEMORY", "AL_TEST_DISPLAY", "TMPDIR", "TEMP"} {
        v, has := env_get(name)
        if has {
            out.push(fmt(name, "=", v))
        }
    }
    return out.items()
}

// ---------- the scheduler ----------
priv const SLICE = 20000

fn main() -> i64 {
    a := args()
    if len(a) < 2 {
        eprint("usage: a64emu program [args...]")
        return 2
    }
    for k in 0..3 {
        fds.push(Fd{host: k})
    }
    main_t := load(a[1], a[1..])
    threads.push(main_t)
    cur := 0
    loop {
        if exit_code >= 0 {
            flush()
            return exit_code
        }
        // the next thread that can run (waiting ones whose time has come wake up)
        now := 0
        found := -1
        earliest := -1
        for k in 0..threads.len {
            i := (cur + k) % threads.len
            th := threads[i]
            if th.wait == 3 {
                continue
            }
            if th.wait != 0 && th.wake_at != 0 {
                if now == 0 {
                    now = clock_ns()
                }
                if now >= th.wake_at {
                    if th.wait == 1 {
                        th.x[0] = -110 // a futex wait that timed out: ETIMEDOUT
                    }
                    th.wait = 0
                } else if earliest < 0 || th.wake_at < earliest {
                    earliest = th.wake_at
                }
            }
            if th.wait == 0 {
                found = i
                break
            }
        }
        if found < 0 {
            if earliest < 0 {
                eprint("a64emu: every thread waits (deadlock)")
                return 134
            }
            __os_sleep_ns(max(earliest - clock_ns(), 0))
            continue
        }
        cur = found
        t := threads[cur]
        t.excl = -1
        for _ in 0..SLICE {
            at := t.pc
            if !step(t) {
                break
            }
            if faulted {
                // (the faulting instruction: step may have moved on)
                t.pc = at
                deliver(t)
            }
        }
        cur = (cur + 1) % threads.len
    }
}
