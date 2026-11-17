// Static ELF64 executable writer for AArch64 Linux (--target linux-arm64): the code of
// src/arm64, no dynamic linking (a program that declares C functions is refused).
//
// Layout (as src/elf.al): one read-only executable segment with the ELF and program headers,
// the code (an entry stub, then the functions) and the read-only data (float constants, then
// the read-only globals that the code refers to); one writable segment with the globals with
// data, then the zero-initialised ones; a PT_TLS segment for the thread block. Segments are
// aligned to 64 KiB, so the file loads on kernels with 4, 16 and 64 KiB pages.

priv const BASE = 0x400000
priv const SEG_ALIGN = 0x10000

// the read-only globals the code refers to, directly or through the data of other kept
// globals (writable globals are all kept): what x86_live_data does for the x86-64 code
priv fn live_data(m: *Module, out: *A64Output) -> Vec[bool] {
    live := vec_fill(m.globals.len, !opt_enabled("deaddata"))
    if !opt_enabled("deaddata") {
        return live
    }
    work := vec[i64]()
    for gi in 0..m.globals.len {
        if !m.globals[gi].readonly {
            live[gi] = true
            work.push(gi)
        }
    }
    for f in out.funcs {
        for r in f.code.relocs {
            if r.tgt == AT_GLOBAL && !live[r.id] {
                live[r.id] = true
                work.push(r.id)
            }
        }
    }
    while !work.is_empty() {
        g := work.pop()
        for rl in m.globals[g].relocs {
            match rl.1 {
                Global(t, _) if !live[t] => {
                    live[t] = true
                    work.push(t)
                }
                _ => {}
            }
        }
    }
    return live
}

// The entry stub (`_start`): the thread block of the main thread below the initial stack (its
// size tls_area: the 16-byte thread control block, then the block; the kernel's fresh stack
// pages are zero), TPIDR_EL0 pointing at it, then __entry(initial sp).
//     mov x0, sp; sub x9, x0, #hi, lsl #12; sub x9, x9, #lo; mov sp, x9; msr tpidr_el0, x9;
//     bl __entry; brk #0
priv fn start_stub(tls_area: i64) -> Vec[u32] {
    assert tls_area >= 0 && tls_area < (1 << 24) && tls_area % 16 == 0, "elf_arm64: the thread block is too large"
    s := vec[u32]()
    s.push(a64_add_imm(1, false, false, 0, 31, 0, false))
    s.push(a64_add_imm(1, true, false, 9, 0, tls_area >> 12, true))
    s.push(a64_add_imm(1, true, false, 9, 9, tls_area & 0xFFF, false))
    s.push(a64_add_imm(1, false, false, 31, 9, 0, false))
    s.push(a64_msr_tpidr(9))
    s.push(a64_b(true, 0)) // patched: bl __entry
    s.push(a64_brk(0))
    return s
}
priv const START_BL = 5 // the word of the stub that calls __entry

fn elf_arm64_link(m: *Module, out: *A64Output) -> (str, str) {
    if len(out.err) != 0 {
        return ("", out.err)
    }
    for f in out.funcs {
        for r in f.code.relocs {
            if r.tgt == AT_GLOBAL {
                for x in m.externs {
                    if x.got == r.id {
                        return ("", fmt("`", x.name, "` is a C function or variable (from `", x.lib,
                            "`): --target linux-arm64 makes static executables only, without C libraries"))
                    }
                }
            }
        }
    }
    nph := 4
    hdr_size := 64 + 56 * nph
    text_off := align_up(hdr_size, 16)
    // ---- thread block (offsets from its start; layout_tls without the x86 bias) ----
    gaddr := vec_fill(m.globals.len, 0)
    tls_size := layout_tls(m, &gaddr, false)
    // ---- text ----
    text := vec[u8]()
    stub := start_stub(align_up(16 + tls_size, 16))
    for wd in stub {
        put32(&text, i64(wd))
    }
    func_addr := vec_fill(m.funcs.len, 0)
    func_off := vec_fill(m.funcs.len, 0)
    for f in out.funcs {
        text.resize(align_up(text.len, 16), 0)
        func_off[f.fid] = text.len
        func_addr[f.fid] = BASE + text_off + text.len
        text.extend(f.code.bytes.items())
    }
    // ---- rodata: the float pool, then the read-only globals ----
    ro_off := align_up(text_off + text.len, 16)
    fpool_addr := BASE + ro_off
    live := live_data(m, out)
    rodata := vec[u8]()
    for bits in out.fpool {
        put64(&rodata, i64(bits.lo))
        put64(&rodata, i64(bits.hi))
    }
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.readonly && live[gi] {
            rodata.resize(align_up(rodata.len, max(g.align, 1)), 0)
            gaddr[gi] = BASE + ro_off + rodata.len
            match g.data {
                Some(d) => rodata.extend(d.items())
                None => rodata.resize(rodata.len + g.size, 0)
            }
            rodata.push(0) // keep distinct addresses for empty strings
        }
    }
    ro_end := ro_off + rodata.len
    // ---- data / bss ----
    data_off := align_up(ro_end, SEG_ALIGN)
    data := vec[u8]()
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        match g.data {
            Some(d) if !g.readonly => {
                data.resize(align_up(data.len, max(g.align, 1)), 0)
                gaddr[gi] = BASE + data_off + data.len
                data.extend(d.items())
            }
            _ => {}
        }
    }
    data.resize(align_up(data.len, 16), 0)
    bss_addr := BASE + data_off + data.len
    bss_size := layout_bss(m, bss_addr, &gaddr)
    // ADRP reaches 4 GiB around the code
    if bss_addr + bss_size > 0xFFFF_0000 {
        return ("", fmt("the program's code and global variables take ", bss_addr + bss_size - BASE, " bytes; at most 4 GiB fit"))
    }
    // ---- relocations ----
    start_addr := BASE + text_off
    bl_at := 4 * START_BL
    set32(&text, bl_at, i64(a64_b(true, (func_addr[m.entry] - (start_addr + bl_at)) / 4)))
    for f in out.funcs {
        fo := func_off[f.fid]
        for r in f.code.relocs {
            at := fo + r.off
            pc := BASE + text_off + at
            sym := match r.tgt {
                AT_GLOBAL => gaddr[r.id]
                AT_FUNC => func_addr[r.id]
                _ => fpool_addr + 16 * r.id
            }
            target := sym + r.addend
            word := i64(text[at]) | i64(text[at + 1]) << 8 | i64(text[at + 2]) << 16 | i64(text[at + 3]) << 24
            match r.kind {
                AR_CALL26 => {
                    d := (target - pc) / 4
                    assert d >= -(1 << 25) && d < (1 << 25), "elf_arm64: call out of range"
                    word |= d & 0x3FFFFFF
                }
                AR_ADRP => {
                    pages := (target >> 12) - (pc >> 12)
                    word |= (pages & 3) << 29 | ((pages >> 2) & 0x7FFFF) << 5
                }
                _ => word |= (target & 0xFFF) << 10
            }
            set32(&text, at, word)
        }
    }
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.relocs.is_empty() || !live[gi] {
            continue
        }
        if g.readonly {
            patch_data(&rodata, BASE + ro_off, g, gaddr[gi], &gaddr, &func_addr)
        } else if is_some(g.data) {
            patch_data(&data, BASE + data_off, g, gaddr[gi], &gaddr, &func_addr)
        }
    }
    // ---- symbols ----
    strtab := vec_of([]u8{0})
    symtab := vec_fill(24, u8(0))
    nsyms := 1
    for f in out.funcs {
        name_off := strtab.len
        strtab.extend(m.funcs[f.fid].name)
        strtab.push(0)
        put32(&symtab, name_off)
        symtab.push(2) // STB_LOCAL, STT_FUNC
        symtab.push(0)
        put16(&symtab, 1)
        put64(&symtab, func_addr[f.fid])
        put64(&symtab, f.code.bytes.len)
        nsyms += 1
    }
    shstr := "\0.text\0.rodata\0.data\0.bss\0.symtab\0.strtab\0.shstrtab\0"
    // ---- file ----
    file := vec[u8]()
    file.resize(text_off, 0)
    file.extend(text.items())
    file.resize(ro_off, 0)
    file.extend(rodata.items())
    file.resize(data_off, 0)
    file.extend(data.items())
    symtab_off := align_up(file.len, 8)
    file.resize(symtab_off, 0)
    file.extend(symtab.items())
    strtab_off := file.len
    file.extend(strtab.items())
    shstr_off := file.len
    file.extend(shstr)
    sh_off := align_up(file.len, 8)
    file.resize(sh_off, 0)
    sh := vec[u8]()
    fn name_at(names: str, s: str) -> i64 {
        if s == "" {
            return 0
        }
        p := find(names, fmt("\0", s, "\0"))
        assert p >= 0, "unknown section name"
        return p + 1
    }
    fn section(sh: *Vec[u8], name: i64, ty: i64, flags: i64, addr: i64, off: i64, size: i64, link: i64, info: i64, align: i64, entsize: i64) {
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
    section(&sh, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    section(&sh, name_at(shstr, ".text"), 1, 6, BASE + text_off, text_off, text.len, 0, 0, 16, 0)
    section(&sh, name_at(shstr, ".rodata"), 1, 2, BASE + ro_off, ro_off, rodata.len, 0, 0, 16, 0)
    section(&sh, name_at(shstr, ".data"), 1, 3, BASE + data_off, data_off, data.len, 0, 0, 16, 0)
    section(&sh, name_at(shstr, ".bss"), 8, 3, bss_addr, data_off + data.len, bss_size, 0, 0, 64, 0)
    section(&sh, name_at(shstr, ".symtab"), 2, 0, 0, symtab_off, symtab.len, 6, nsyms, 8, 24)
    section(&sh, name_at(shstr, ".strtab"), 3, 0, 0, strtab_off, strtab.len, 0, 0, 1, 0)
    section(&sh, name_at(shstr, ".shstrtab"), 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0)
    file.extend(sh.items())
    // ELF header: ELFCLASS64, little endian, ET_EXEC, EM_AARCH64 (183)
    h := vec[u8]()
    h.extend([]u8{0x7F, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0})
    put16(&h, 2)
    put16(&h, 183)
    put32(&h, 1)
    put64(&h, start_addr)
    put64(&h, 64)
    put64(&h, sh_off)
    put32(&h, 0)
    put16(&h, 64)
    put16(&h, 56)
    put16(&h, nph)
    put16(&h, 64)
    put16(&h, 8)
    put16(&h, 7)
    fn segment(h: *Vec[u8], ty: i64, flags: i64, off: i64, vaddr: i64, filesz: i64, memsz: i64, align: i64) {
        put32(h, ty)
        put32(h, flags)
        put64(h, off)
        put64(h, vaddr)
        put64(h, vaddr)
        put64(h, filesz)
        put64(h, memsz)
        put64(h, align)
    }
    segment(&h, 1, 5, 0, BASE, ro_end, ro_end, SEG_ALIGN)                                    // PT_LOAD r-x
    segment(&h, 1, 6, data_off, BASE + data_off, data.len, data.len + bss_size, SEG_ALIGN) // PT_LOAD rw-
    segment(&h, 7, 4, data_off + data.len, bss_addr, 0, tls_size, 16)                      // PT_TLS
    segment(&h, 0x6474e551, 6, 0, 0, 0, 0, 16)                                             // PT_GNU_STACK
    assert h.len <= file.len
    copy(file[..], h.items())
    return (file.items(), "")
}
