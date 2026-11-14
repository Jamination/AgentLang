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
    // (PT_TLS: the thread block, see layout_tls; a static program's start sets it up itself)
    nph := if dynamic { 7 } else { 4 }
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
    interp_at := 0
    interp_len := 0
    dynstr_at := 0
    dynstr_len := 0
    dynsym_at := 0
    hash_at := 0
    rela_at := 0
    needed := vec[i64]() // offsets of library names in dynstr
    if dynamic {
        rodata.resize(align_up(rodata.len, 8), 0)
        interp := "/lib64/ld-linux-x86-64.so.2\0"
        interp_at = BASE + ro_off + rodata.len
        interp_len = len(interp)
        rodata.extend(interp)
        dynstr := vec_of([]u8{0})
        libs := vec[str]()
        for x in externs {
            if !libs.contains(m.externs[x].lib) {
                libs.push(m.externs[x].lib)
            }
        }
        for l in libs {
            needed.push(dynstr.len)
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
        dynstr_at = BASE + ro_off + rodata.len
        dynstr_len = dynstr.len
        rodata.extend(dynstr.items())
        rodata.resize(align_up(rodata.len, 8), 0)
        dynsym_at = BASE + ro_off + rodata.len
        rodata.extend(dynsym.items())
        // SysV hash table with one empty bucket: nothing is exported
        hash_at = BASE + ro_off + rodata.len
        nsym := externs.len + 1
        put32(&rodata, 1)
        put32(&rodata, nsym)
        put32(&rodata, 0)
        rodata.resize(align_up(rodata.len + 4 * nsym, 8), 0)
        rela_at = BASE + ro_off + rodata.len
        rodata.resize(rodata.len + 24 * externs.len, 0)
    }
    ro_end := ro_off + rodata.len
    // ---- data / bss ----
    data_off := align_up(ro_end, 0x1000)
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
    dyn_at := 0
    dyn_len := 0
    if dynamic {
        data.resize(align_up(data.len, 8), 0)
        dyn_at = BASE + data_off + data.len
        d := vec[(i64, i64)]()
        for n in needed {
            d.push((1, n)) // DT_NEEDED
        }
        d.push((4, hash_at)) // DT_HASH
        d.push((5, dynstr_at)) // DT_STRTAB
        d.push((6, dynsym_at)) // DT_SYMTAB
        d.push((10, dynstr_len)) // DT_STRSZ
        d.push((11, 24)) // DT_SYMENT
        d.push((7, rela_at)) // DT_RELA
        d.push((8, 24 * externs.len)) // DT_RELASZ
        d.push((9, 24)) // DT_RELAENT
        d.push((30, 8)) // DT_FLAGS: BIND_NOW
        d.push((0x6ffffffb, 1)) // DT_FLAGS_1: NOW
        d.push((21, 0)) // DT_DEBUG
        d.push((0, 0))
        for e in d {
            put64(&data, e.0)
            put64(&data, e.1)
        }
        dyn_len = BASE + data_off + data.len - dyn_at
        // one R_X86_64_GLOB_DAT relocation per import slot
        base := rela_at - (BASE + ro_off)
        for k, x in externs {
            at := base + 24 * k
            assert at + 24 <= rodata.len
            set64(&rodata, at, gaddr[m.externs[x].got])
            set64(&rodata, at + 8, ((k + 1) << 32) | 6)
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
    shstr := "\0.text\0.rodata\0.data\0.bss\0.symtab\0.strtab\0.shstrtab\0.dynstr\0.dynsym\0.dynamic\0"
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
    sh_off := align_up(file.len, 8)
    file.resize(sh_off, 0)
    sh := vec[u8]()
    // one section header (the name is looked up in the section name table `names`)
    fn section(sh: *Vec[u8], names: str, name: str, ty: i64, flags: i64, addr: i64, off: i64, size: i64, link: i64, info: i64, align: i64, entsize: i64) {
        put32(sh, if name == "" { 0 } else { name_of(names, name) })
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
    section(&sh, shstr, "", 0, 0, 0, 0, 0, 0, 0, 0, 0)
    section(&sh, shstr, ".text", 1, 6, BASE + text_off, text_off, text.len, 0, 0, 16, 0)
    section(&sh, shstr, ".rodata", 1, 2, BASE + ro_off, ro_off, rodata.len, 0, 0, 16, 0)
    section(&sh, shstr, ".data", 1, 3, BASE + data_off, data_off, data.len, 0, 0, 16, 0)
    section(&sh, shstr, ".bss", 8, 3, bss_addr, data_off + data.len, bss_size, 0, 0, 64, 0)
    section(&sh, shstr, ".symtab", 2, 0, 0, symtab_off, symtab.len, 6, nsyms, 8, 24)
    section(&sh, shstr, ".strtab", 3, 0, 0, strtab_off, strtab.len, 0, 0, 1, 0)
    section(&sh, shstr, ".shstrtab", 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0)
    if dynamic {
        section(&sh, shstr, ".dynstr", 3, 2, dynstr_at, dynstr_at - BASE, dynstr_len, 0, 0, 1, 0)
        section(&sh, shstr, ".dynsym", 11, 2, dynsym_at, dynsym_at - BASE, 24 * (externs.len + 1), 8, 1, 8, 24)
        section(&sh, shstr, ".dynamic", 6, 3, dyn_at, dyn_at - BASE, dyn_len, 8, 0, 8, 16)
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
    put16(&h, if dynamic { 11 } else { 8 })
    put16(&h, 7)
    // program headers
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
    if dynamic {
        segment(&h, 6, 4, 64, BASE + 64, 56 * nph, 56 * nph, 8) // PT_PHDR
        segment(&h, 3, 4, interp_at - BASE, interp_at, interp_len, interp_len, 1) // PT_INTERP
    }
    segment(&h, 1, 5, 0, BASE, ro_end, ro_end, 0x1000)
    segment(&h, 1, 6, data_off, BASE + data_off, data.len, data.len + bss_size, 0x1000)
    if dynamic {
        segment(&h, 2, 6, dyn_at - BASE, dyn_at, dyn_len, dyn_len, 8) // PT_DYNAMIC
    }
    segment(&h, 7, 4, data_off + data.len, bss_addr, 0, tls_size, 16) // PT_TLS
    segment(&h, 0x6474e551, 6, 0, 0, 0, 0, 16)
    assert h.len <= file.len
    copy(file[..], h.items())
    return (file.items(), "")
}
