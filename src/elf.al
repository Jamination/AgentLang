// Static ELF64 executable writer and linker.

use "objwrite.al"

priv const BASE = 0x400000

// offset of a section name in the section header string table
priv fn name_of(shstr: str, s: str) -> i64 {
    p := find(shstr, fmt("\0", s, "\0"))
    assert p >= 0, "unknown section name"
    p + 1
}

// A program that uses no C function or variable is a static executable. Otherwise the output
// is a dynamically linked executable: the system loader maps the libraries and fills the import
// slots (with the address of the function or variable: R_X86_64_GLOB_DAT, never a copy).
// Result: (file bytes, error text); the error text is empty on success.
fn elf_link(m: *Module, out: *Output) -> (str, str) {
    if len(out.err) != 0 {
        return ("", out.err)
    }
    externs := used_externs(m, out)
    dynamic := !externs.is_empty()
    for x in externs {
        lib := m.externs[x].lib
        if ends_with(to_lower(lib), ".dll") {
            return ("", fmt("`", m.externs[x].name, "` is imported from `", lib,
                "`, a Windows library: build with --target windows (this build makes an x86-64 Linux executable)"))
        }
        if ends_with(lib, ".dylib") || find(lib, ".framework") >= 0 {
            return ("", fmt("`", m.externs[x].name, "` is imported from `", lib,
                "`, which is not a Linux library; this compiler emits x86-64 Linux executables (bindings for other platforms can be type-checked with `alc check`)"))
        }
    }
    // (PT_TLS: the thread block, see layout_tls; a static program's start sets it up itself;
    // dynamic adds PT_PHDR, PT_INTERP, PT_DYNAMIC and PT_GNU_RELRO for Full RELRO)
    nph := if dynamic { 8 } else { 4 }
    hdr_size := 64 + 56 * nph
    text_off := align_up(hdr_size, 16)
    // ---- text ----
    text := vec[u8]()
    // _start: mov rdi, rsp ; call entry ; ud2
    text.extend([]u8{0x48, 0x89, 0xE7, 0xE8, 0, 0, 0, 0, 0x0F, 0x0B})
    func_addr := vec_fill(m.funcs.len, 0)
    func_off := vec_fill(m.funcs.len, 0)
    layout_text(&text, out, BASE + text_off, &func_off, &func_addr)
    // ---- rodata ----
    ro_off := align_up(text_off + text.len, 16)
    fpool_addr := BASE + ro_off
    gaddr := vec_fill(m.globals.len, 0)
    live := x86_live_data(m, out)
    rodata := layout_rodata(m, out, live.items(), BASE + ro_off, &gaddr)
    // ---- dynamic linking tables (read-only part) ----
    dy := ElfDynTabs{}
    if dynamic {
        elf_dyn_tables(m, externs.items(), "/lib64/ld-linux-x86-64.so.2", &rodata, BASE + ro_off, &dy)
    }
    ro_end := ro_off + rodata.len
    // ---- data / bss ----
    // For dynamic binaries, .dynamic and the GOT import slots live in a page-aligned RELRO
    // prefix at the start of .data (protected read-only after BIND_NOW relocations via
    // PT_GNU_RELRO), followed by mutable globals on the next page.
    data_off := align_up(ro_end, 0x1000)
    data := vec[u8]()
    is_got := vec_fill(m.globals.len, false)
    dyn_at := 0
    dyn_len := 0
    got_at := 0
    got_len := 0
    relro_size := 0
    if dynamic {
        for x in externs {
            is_got[m.externs[x].got] = true
        }
        dyn_at = BASE + data_off
        for e in elf_dyn_entries(&dy, externs.len) {
            put64(&data, e.0)
            put64(&data, e.1)
        }
        dyn_len = data.len
        data.resize(align_up(data.len, 8), 0)
        got_at = BASE + data_off + data.len
        for x in externs {
            gaddr[m.externs[x].got] = BASE + data_off + data.len
            put64(&data, 0)
        }
        got_len = BASE + data_off + data.len - got_at
        data.resize(align_up(data.len, 0x1000), 0)
        relro_size = data.len
        // one R_X86_64_GLOB_DAT (6) relocation per import slot
        elf_patch_got_relas(m, externs.items(), &rodata, BASE + ro_off, dy.rela_at, &gaddr, 6)
    }
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        match g.data {
            Some(d) if !g.readonly && !is_got[gi] => {
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
    tls_size := layout_tls(m, &gaddr, true)
    // the code addresses code and data with 32-bit absolute and relative displacements
    if bss_addr + bss_size > 0x7FFF_FFFF {
        return ("", fmt("the program's code and global variables take ", bss_addr + bss_size - BASE,
            " bytes; at most ", 0x7FFF_FFFF - BASE, " fit (put large tables in memory from alloc instead)"))
    }
    // ---- relocations ----
    start_addr := BASE + text_off
    set32(&text, 4, func_addr[m.entry] - (start_addr + 8))
    patch_text(&text, out, &func_off, &func_addr, &gaddr, fpool_addr)
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        // (writable globals are all live)
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
    for ci in 0..out.funcs.len {
        c := &out.funcs[ci]
        name_off := strtab.len
        strtab.extend(m.funcs[c.fid].name)
        strtab.push(0)
        put32(&symtab, name_off)
        symtab.push(2) // STB_LOCAL, STT_FUNC
        symtab.push(0)
        put16(&symtab, 1)
        put64(&symtab, func_addr[c.fid])
        put64(&symtab, c.code.bytes.len)
        nsyms += 1
    }
    shstr := "\0.text\0.rodata\0.data\0.bss\0.symtab\0.strtab\0.shstrtab\0.dynstr\0.dynsym\0.dynamic\0.got\0"
    // -g: the DWARF sections (src/dwarf.al), after the others
    dsecs := vec[(str, Vec[u8])]()
    if dbg_on {
        dsecs = dwarf_sections(m, out, &func_addr, &gaddr, start_addr, start_addr + text.len, start_addr, false)
        for s in dsecs {
            shstr = fmt(shstr, s.0, "\0")
        }
    }
    // ---- file assembly ----
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
    dsec_off := vec[i64]()
    for s in dsecs {
        dsec_off.push(file.len)
        file.extend(s.1.items())
    }
    sh_off := align_up(file.len, 8)
    file.resize(sh_off, 0)
    sh := vec[u8]()
    // one section header (the name is looked up in the section name table `names`)
    fn section(sh: *Vec[u8], names: str, name: str, ty: i64, flags: i64, addr: i64, off: i64, size: i64, link: i64, info: i64, align: i64, entsize: i64) {
        elf_section(sh, if name == "" { 0 } else { name_of(names, name) }, ty, flags, addr, off, size, link, info, align, entsize)
    }
    section(&sh, shstr, "", 0, 0, 0, 0, 0, 0, 0, 0, 0)
    section(&sh, shstr, ".text", 1, 6, BASE + text_off, text_off, text.len, 0, 0, 16, 0)
    section(&sh, shstr, ".rodata", 1, 2, BASE + ro_off, ro_off, rodata.len, 0, 0, 16, 0)
    section(&sh, shstr, ".data", 1, 3, BASE + data_off, data_off, data.len, 0, 0, 16, 0)
    section(&sh, shstr, ".bss", 8, 3, bss_addr, data_off + data.len, bss_size, 0, 0, 64, 0)
    section(&sh, shstr, ".symtab", 2, 0, 0, symtab_off, symtab.len, 6, nsyms, 8, 24)
    section(&sh, shstr, ".strtab", 3, 0, 0, strtab_off, strtab.len, 0, 0, 1, 0)
    section(&sh, shstr, ".shstrtab", 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0)
    if dynamic {
        section(&sh, shstr, ".dynstr", 3, 2, dy.dynstr_at, dy.dynstr_at - BASE, dy.dynstr_len, 0, 0, 1, 0)
        section(&sh, shstr, ".dynsym", 11, 2, dy.dynsym_at, dy.dynsym_at - BASE, 24 * (externs.len + 1), 8, 1, 8, 24)
        section(&sh, shstr, ".dynamic", 6, 3, dyn_at, dyn_at - BASE, dyn_len, 8, 0, 8, 16)
        section(&sh, shstr, ".got", 1, 3, got_at, got_at - BASE, got_len, 0, 0, 8, 8)
    }
    for k, s in dsecs {
        section(&sh, shstr, s.0, 1, 0, 0, dsec_off[k], s.1.len, 0, 0, 1, 0)
    }
    file.extend(sh.items())
    // ELF header
    h := vec[u8]()
    h.extend([]u8{0x7F, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0})
    put16(&h, 2)
    put16(&h, 62)
    put32(&h, 1)
    put64(&h, start_addr)
    put64(&h, 64)
    put64(&h, sh_off)
    put32(&h, 0)
    put16(&h, 64)
    put16(&h, 56)
    put16(&h, nph)
    put16(&h, 64)
    put16(&h, (if dynamic { 12 } else { 8 }) + dsecs.len)
    put16(&h, 7)
    // program headers
    if dynamic {
        elf_segment(&h, 6, 4, 64, BASE + 64, 56 * nph, 56 * nph, 8) // PT_PHDR
        elf_segment(&h, 3, 4, dy.interp_at - BASE, dy.interp_at, dy.interp_len, dy.interp_len, 1) // PT_INTERP
    }
    elf_segment(&h, 1, 5, 0, BASE, ro_end, ro_end, 0x1000)
    elf_segment(&h, 1, 6, data_off, BASE + data_off, data.len, data.len + bss_size, 0x1000)
    if dynamic {
        elf_segment(&h, 2, 6, dyn_at - BASE, dyn_at, dyn_len, dyn_len, 8) // PT_DYNAMIC
    }
    elf_segment(&h, 7, 4, data_off + data.len, bss_addr, 0, tls_size, 16) // PT_TLS
    elf_segment(&h, 0x6474e551, 6, 0, 0, 0, 0, 16) // PT_GNU_STACK (RW, NX)
    if dynamic {
        elf_segment(&h, 0x6474e552, 4, data_off, BASE + data_off, relro_size, relro_size, 1) // PT_GNU_RELRO
    }
    assert h.len <= file.len
    copy(file[..], h.items())
    return (file.items(), "")
}
