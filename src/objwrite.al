// What the executable writers (elf.al, pe.al) share: little-endian byte output and the parts
// of the image they lay out alike (text, read-only data, bss, the relocations).

// x as u16, little endian
fn put16(v: *Vec[u8], x: i64) {
    u := u64(x)
    v.push(u8(u))
    v.push(u8(u >> 8))
}

// x as u32, little endian
fn put32(v: *Vec[u8], x: i64) {
    u := u64(x)
    for k in 0..4 {
        v.push(u8(u >> u64(8 * k)))
    }
}

// x as u64, little endian
fn put64(v: *Vec[u8], x: i64) {
    u := u64(x)
    for k in 0..8 {
        v.push(u8(u >> u64(8 * k)))
    }
}

// writes the low 4 bytes of x at buf[at..]
fn set32(buf: *Vec[u8], at: i64, x: i64) {
    u := u64(x)
    for k in 0..4 {
        buf[at + k] = u8(u >> u64(8 * k))
    }
}

// writes the 8 bytes of x at buf[at..]
fn set64(buf: *Vec[u8], at: i64, x: i64) {
    u := u64(x)
    for k in 0..8 {
        buf[at + k] = u8(u >> u64(8 * k))
    }
}

// the imported C functions and variables that the emitted code refers to, in a stable order
fn used_externs(m: *Module, out: *Output) -> Vec[i64] {
    used := vec_fill(m.externs.len, false)
    by_got := map[i64, i64]()
    for i, x in m.externs {
        by_got.set(x.got, i)
    }
    for ci in 0..out.funcs.len {
        for r in out.funcs[ci].code.relocs {
            match r.kind {
                Abs32Global(g) => {
                    i, found := by_got.get(g)
                    if found {
                        used[i] = true
                    }
                }
                _ => {}
            }
        }
    }
    res := vec[i64]()
    for i, u in used {
        if u {
            res.push(i)
        }
    }
    res
}

// Appends the code of the functions to text (each at a multiple of 16, the gaps filled with
// int3), whose first byte is at address addr; records where each function is.
fn layout_text(text: *Vec[u8], out: *Output, addr: i64, func_off: *Vec[i64], func_addr: *Vec[i64]) {
    for ci in 0..out.funcs.len {
        c := &out.funcs[ci]
        text.resize(align_up(text.len, 16), 0xCC)
        func_off[c.fid] = text.len
        func_addr[c.fid] = addr + text.len
        text.extend(c.code.bytes.items())
    }
}

// The read-only data at address addr: the float constant pool, then the live read-only
// globals (their addresses go to gaddr).
fn layout_rodata(m: *Module, out: *Output, live: []bool, addr: i64, gaddr: *Vec[i64]) -> Vec[u8] {
    rodata := vec[u8]()
    for bits in out.fpool {
        put64(&rodata, i64(bits.lo))
        put64(&rodata, i64(bits.hi))
    }
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.readonly && live[gi] {
            rodata.resize(align_up(rodata.len, max(g.align, 1)), 0)
            gaddr[gi] = addr + rodata.len
            match g.data {
                Some(d) => rodata.extend(d.items())
                None => rodata.resize(rodata.len + g.size, 0)
            }
            rodata.push(0) // keep distinct addresses for empty strings
        }
    }
    rodata
}

// Places the writable globals without data at address addr (their addresses go to gaddr);
// returns the size of the bss. (Thread-local globals are not there: layout_tls.)
fn layout_bss(m: *Module, addr: i64, gaddr: *Vec[i64]) -> i64 {
    size := 0
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if !g.readonly && is_none(g.data) && !g.tls {
            a := min(max(g.align, 1), 64)
            if g.size >= 64 {
                a = max(a, 64)
            }
            size = align_up(size, a)
            gaddr[gi] = addr + size
            size += max(g.size, 1)
        }
    }
    size
}

// The thread block: every thread's copy of the thread-local globals (zeroed), aligned to 16;
// returns its size. gaddr of such a global is the displacement the code addresses it with:
// Linux (TLS variant II, the block ends at the thread pointer fs:0) its offset minus the size,
// Windows (the block the TLS directory makes the loader allocate) its offset.
fn layout_tls(m: *Module, gaddr: *Vec[i64], below_tp: bool) -> i64 {
    size := 0
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.tls {
            size = align_up(size, min(max(g.align, 1), 16))
            gaddr[gi] = size
            size += max(g.size, 1)
        }
    }
    size = align_up(max(size, 16), 16)
    if below_tp {
        for gi in 0..m.globals.len {
            if m.globals[gi].tls {
                gaddr[gi] -= size
            }
        }
    }
    size
}

// writes the 32-bit displacements of the code's relocations into text
fn patch_text(text: *Vec[u8], out: *Output, func_off: *Vec[i64], func_addr: *Vec[i64], gaddr: *Vec[i64], fpool_addr: i64) {
    for ci in 0..out.funcs.len {
        c := &out.funcs[ci]
        fo := func_off[c.fid]
        fa := func_addr[c.fid]
        for r in c.code.relocs {
            at := fo + r.off
            val := match r.kind {
                Abs32Global(g) => gaddr[g] + i64(r.addend)
                Abs32Func(f) => func_addr[f] + i64(r.addend)
                Abs32FConst(i) => fpool_addr + 16 * i + i64(r.addend)
                Rel32Func(f) => func_addr[f] - (fa + r.off + 4)
            }
            assert fits_i32(val), "relocation out of range"
            assert at >= 0 && at + 4 <= text.len
            set32(text, at, val)
        }
    }
}

// the 8-byte pointers in the data of global g (at address ga in buf, which starts at
// base_addr): to globals and functions
fn patch_data(buf: *Vec[u8], base_addr: i64, g: *Global, ga: i64, gaddr: *Vec[i64], func_addr: *Vec[i64]) {
    for rl in g.relocs {
        val := match rl.1 {
            Global(tg, add) => gaddr[tg] + add
            Func(f) => func_addr[f]
        }
        at := (ga - base_addr) + rl.0
        assert at >= 0 && at + 8 <= buf.len, "data relocation out of range"
        set64(buf, at, val)
    }
}
