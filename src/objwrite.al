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
                Abs32Global(g), Rel32Global(g) => {
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
    first := -1
    for ci in 0..out.funcs.len {
        c := &out.funcs[ci]
        if first < 0 {
            text.resize(align_up(text.len, 16), 0xCC)
            first = text.len
        }
        text.resize(first + func_place(text.len - first, c.code.align64), 0xCC)
        func_off[c.fid] = text.len
        func_addr[c.fid] = addr + text.len
        text.extend(c.code.bytes.items())
    }
}

// where layout_text places a function after code that ends `end` bytes after the start of the
// first function: at a multiple of 16, or of 64 for one whose loops are padded for that
// (x86/emit.al, loop_pads; src/backtrace.al counts the same way)
fn func_place(end: i64, align64: bool) -> i64 {
    return align_up(end, if align64 { 64 } else { 16 })
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
// Windows (the block the TLS directory makes the loader allocate) its offset. The arena
// (__heap_*, the allocation fast path) comes first, in one cache line.
fn layout_tls(m: *Module, gaddr: *Vec[i64], below_tp: bool) -> i64 {
    size := 0
    for pass in 0..2 {
        for gi in 0..m.globals.len {
            g := &m.globals[gi]
            if g.tls && starts_with(g.name, "__heap_") == (pass == 0) {
                size = align_up(size, min(max(g.align, 1), 16))
                gaddr[gi] = size
                size += max(g.size, 1)
            }
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

// writes the 32-bit displacements of the code's relocations into text (a rip-relative one is
// relative to the end of its instruction: the field's end, the addend counts what follows it)
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
                Rel32Global(g) => gaddr[g] + i64(r.addend) - (fa + r.off + 4)
                Rel32FConst(i) => fpool_addr + 16 * i + i64(r.addend) - (fa + r.off + 4)
                JTab(_) => panic("a jump table relocation left in the code")
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

// ---------- ELF64 shared helpers (elf.al, elf_arm64.al) ----------

// where the read-only tables of dynamic linking lie (addresses)
struct ElfDynTabs {
    interp_at: i64
    interp_len: i64
    dynstr_at: i64
    dynstr_len: i64
    dynsym_at: i64
    hash_at: i64
    rela_at: i64
    needed: Vec[i64] // offsets of the library names in .dynstr
}

// Appends the interpreter's path, .dynstr (the libraries, then the symbols), .dynsym (symbol 0,
// then one undefined global symbol per import: STT_FUNC or STT_OBJECT), a SysV hash table with
// one empty bucket (the program exports nothing) and room for the relocations (filled in once
// the import slots have addresses) to rodata, whose first byte is at address `at`.
fn elf_dyn_tables(m: *Module, externs: []i64, interp: str, rodata: *Vec[u8], at: i64, dy: *ElfDynTabs) {
    rodata.resize(align_up(rodata.len, 8), 0)
    dy.interp_at = at + rodata.len
    dy.interp_len = len(interp) + 1
    rodata.extend(interp)
    rodata.push(0)
    dynstr := vec_of([]u8{0})
    libs := vec[str]()
    for x in externs {
        if !libs.contains(m.externs[x].lib) {
            libs.push(m.externs[x].lib)
        }
    }
    for l in libs {
        dy.needed.push(dynstr.len)
        dynstr.extend(l)
        dynstr.push(0)
    }
    dynsym := vec_fill(24, u8(0))
    for x in externs {
        put32(&dynsym, dynstr.len)
        dynstr.extend(m.externs[x].name)
        dynstr.push(0)
        // STB_GLOBAL, STT_OBJECT for a variable, STT_FUNC for a function
        dynsym.push(if m.externs[x].data { u8(0x11) } else { u8(0x12) })
        dynsym.push(0)
        put16(&dynsym, 0) // undefined
        put64(&dynsym, 0)
        put64(&dynsym, 0)
    }
    dy.dynstr_at = at + rodata.len
    dy.dynstr_len = dynstr.len
    rodata.extend(dynstr.items())
    rodata.resize(align_up(rodata.len, 8), 0)
    dy.dynsym_at = at + rodata.len
    rodata.extend(dynsym.items())
    // SysV hash table with one empty bucket: nothing is exported
    dy.hash_at = at + rodata.len
    nsym := len(externs) + 1
    put32(rodata, 1)
    put32(rodata, nsym)
    put32(rodata, 0)
    rodata.resize(align_up(rodata.len + 4 * nsym, 8), 0)
    dy.rela_at = at + rodata.len
    rodata.resize(rodata.len + 24 * len(externs), 0)
}

// the entries of the ELF .dynamic section
fn elf_dyn_entries(dy: *ElfDynTabs, nimports: i64) -> Vec[(i64, i64)] {
    d := vec[(i64, i64)]()
    for n in dy.needed {
        d.push((1, n)) // DT_NEEDED
    }
    d.push((4, dy.hash_at)) // DT_HASH
    d.push((5, dy.dynstr_at)) // DT_STRTAB
    d.push((6, dy.dynsym_at)) // DT_SYMTAB
    d.push((10, dy.dynstr_len)) // DT_STRSZ
    d.push((11, 24)) // DT_SYMENT
    d.push((7, dy.rela_at)) // DT_RELA
    d.push((8, 24 * nimports)) // DT_RELASZ
    d.push((9, 24)) // DT_RELAENT
    d.push((30, 8)) // DT_FLAGS: BIND_NOW
    d.push((0x6ffffffb, 1)) // DT_FLAGS_1: NOW
    d.push((21, 0)) // DT_DEBUG
    d.push((0, 0))
    return d
}

// writes one GLOB_DAT relocation entry per imported symbol into .rela.dyn in rodata
fn elf_patch_got_relas(m: *Module, externs: []i64, rodata: *Vec[u8], ro_addr: i64, rela_at: i64, gaddr: *Vec[i64], reloc_type: i64) {
    base := rela_at - ro_addr
    for k, x in externs {
        at := base + 24 * k
        assert at + 24 <= rodata.len
        set64(rodata, at, gaddr[m.externs[x].got])
        set64(rodata, at + 8, ((k + 1) << 32) | reloc_type)
    }
}

// emits one ELF64 program header
fn elf_segment(h: *Vec[u8], ty: i64, flags: i64, off: i64, vaddr: i64, filesz: i64, memsz: i64, align: i64) {
    put32(h, ty)
    put32(h, flags)
    put64(h, off)
    put64(h, vaddr)
    put64(h, vaddr)
    put64(h, filesz)
    put64(h, memsz)
    put64(h, align)
}

// emits one ELF64 section header
fn elf_section(sh: *Vec[u8], name: i64, ty: i64, flags: i64, addr: i64, off: i64, size: i64, link: i64, info: i64, align: i64, entsize: i64) {
    put32(sh, name)
    put32(sh, ty)
    put64(sh, flags)
    put64(sh, addr)
    put64(sh, off)
    put64(sh, size)
    put32(sh, link)
    put32(sh, info)
    put64(sh, align)
    put64(sh, entsize)
}
