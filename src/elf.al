// Static ELF64 executable writer and linker.

const ELF_BASE = 0x400000

fn elf_align_up(x: i64, a: i64) -> i64 {
    return (x + a - 1) / a * a
}

// x as u16, little endian
fn elf_put16(v: *Vec[u8], x: i64) {
    u := u64(x)
    v.push(u8(u))
    v.push(u8(u >> 8))
}

// x as u32, little endian
fn elf_put32(v: *Vec[u8], x: i64) {
    u := u64(x)
    for k in 0..4 {
        v.push(u8(u >> u64(8 * k)))
    }
}

// x as u64, little endian
fn elf_put64(v: *Vec[u8], x: i64) {
    u := u64(x)
    for k in 0..8 {
        v.push(u8(u >> u64(8 * k)))
    }
}

// Imported C functions that the emitted code refers to, in a stable order.
fn elf_used_externs(m: *Module, out: *Output) -> Vec[i64] {
    used := vec_fill(m.externs.len, false)
    by_got := map[i64, i64]()
    for i in 0..m.externs.len {
        by_got.set(m.externs[i].got, i)
    }
    for ci in 0..out.funcs.len {
        c := &out.funcs[ci]
        for r in c.code.relocs.items() {
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
    for i in 0..m.externs.len {
        if used[i] {
            res.push(i)
        }
    }
    return res
}

fn elf_link_patch_data(buf: *Vec[u8], base_addr: i64, g: *Global, ga: i64, gaddr: *Vec[i64], func_addr: *Vec[i64]) {
    for rl in g.relocs.items() {
        off := rl.0
        val := match rl.1 {
            Glob(tg, add) => gaddr.at(tg) + add
            Function(f) => func_addr.at(f)
        }
        at := (ga - base_addr) + off
        assert at >= 0 && at + 8 <= buf.len, "data relocation out of range"
        u := u64(val)
        for k in 0..8 {
            buf[at + k] = u8(u >> u64(8 * k))
        }
    }
}

// offset of a section name in the section header string table
fn elf_link_name_of(shstr: str, s: str) -> i64 {
    pat := fmt("\0", s, "\0")
    p := find(shstr, pat)
    assert p >= 0, "unknown section name"
    return p + 1
}

// A program that calls no C function is a static executable. Otherwise the output is a
// dynamically linked executable: the system loader maps the libraries and fills the import slots.
// Result: (file bytes, error text); the error text is empty on success.
fn elf_link(m: *Module, out: *Output) -> (str, str) {
    externs := elf_used_externs(m, out)
    dynamic := !externs.is_empty()
    for x in externs.items() {
        lib := m.externs[x].lib
        if ends_with(lib, ".dll") || ends_with(lib, ".dylib") || find(lib, ".framework") >= 0 {
            return ("", fmt("`", m.externs[x].name, "` is imported from `", lib,
                "`, which is not a Linux library; this compiler emits x86-64 Linux executables (bindings for other platforms can be type-checked with `alc check`)"))
        }
    }
    nph := if dynamic { 6 } else { 3 }
    hdr_size := 64 + 56 * nph
    text_off := elf_align_up(hdr_size, 16)
    // ---- text ----
    text := vec[u8]()
    // _start: mov rdi, rsp ; call entry ; ud2
    text.extend([]u8{0x48, 0x89, 0xE7, 0xE8, 0, 0, 0, 0, 0x0F, 0x0B})
    func_addr := vec_fill(m.funcs.len, 0)
    func_size := vec_fill(m.funcs.len, 0)
    func_off := vec_fill(m.funcs.len, 0)
    for ci in 0..out.funcs.len {
        c := &out.funcs[ci]
        while text.len % 16 != 0 {
            text.push(0xCC)
        }
        func_off[c.fid] = text.len
        func_addr[c.fid] = ELF_BASE + text_off + text.len
        func_size[c.fid] = c.code.bytes.len
        text.extend(c.code.bytes.items())
    }
    // ---- rodata ----
    ro_off := elf_align_up(text_off + text.len, 16)
    rodata := vec[u8]()
    fpool_addr := ELF_BASE + ro_off
    for bits in out.fpool.items() {
        elf_put64(&rodata, i64(bits.lo))
        elf_put64(&rodata, i64(bits.hi))
    }
    gaddr := vec_fill(m.globals.len, 0)
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.readonly {
            a := max(g.align, 1)
            while rodata.len % a != 0 {
                rodata.push(0)
            }
            gaddr[gi] = ELF_BASE + ro_off + rodata.len
            match g.data {
                Some(d) => rodata.extend(d.items())
                None => rodata.resize(rodata.len + g.size, 0)
            }
            rodata.push(0) // keep distinct addresses for empty strings
        }
    }
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
        while rodata.len % 8 != 0 {
            rodata.push(0)
        }
        interp := "/lib64/ld-linux-x86-64.so.2\0"
        interp_at = ELF_BASE + ro_off + rodata.len
        interp_len = len(interp)
        rodata.extend(interp)
        dynstr := vec_of([]u8{0})
        libs := vec[str]()
        for x in externs.items() {
            if !contains(&libs, m.externs[x].lib) {
                libs.push(m.externs[x].lib)
            }
        }
        for l in libs.items() {
            needed.push(dynstr.len)
            dynstr.extend(l)
            dynstr.push(0)
        }
        dynsym := vec_fill(24, u8(0))
        for x in externs.items() {
            elf_put32(&dynsym, dynstr.len)
            dynstr.extend(m.externs[x].name)
            dynstr.push(0)
            dynsym.push(0x12) // STB_GLOBAL, STT_FUNC
            dynsym.push(0)
            elf_put16(&dynsym, 0) // undefined
            elf_put64(&dynsym, 0)
            elf_put64(&dynsym, 0)
        }
        dynstr_at = ELF_BASE + ro_off + rodata.len
        dynstr_len = dynstr.len
        rodata.extend(dynstr.items())
        while rodata.len % 8 != 0 {
            rodata.push(0)
        }
        dynsym_at = ELF_BASE + ro_off + rodata.len
        rodata.extend(dynsym.items())
        // SysV hash table with one empty bucket: nothing is exported
        hash_at = ELF_BASE + ro_off + rodata.len
        nsym := externs.len + 1
        elf_put32(&rodata, 1)
        elf_put32(&rodata, nsym)
        elf_put32(&rodata, 0)
        for x in 0..nsym {
            elf_put32(&rodata, 0)
        }
        while rodata.len % 8 != 0 {
            rodata.push(0)
        }
        rela_at = ELF_BASE + ro_off + rodata.len
        rodata.resize(rodata.len + 24 * externs.len, 0)
    }
    ro_end := ro_off + rodata.len
    // ---- data / bss ----
    data_off := elf_align_up(ro_end, 0x1000)
    data := vec[u8]()
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if !g.readonly {
            match g.data {
                Some(d) => {
                    a := max(g.align, 1)
                    while data.len % a != 0 {
                        data.push(0)
                    }
                    gaddr[gi] = ELF_BASE + data_off + data.len
                    data.extend(d.items())
                }
                None => {}
            }
        }
    }
    dyn_at := 0
    dyn_len := 0
    if dynamic {
        while data.len % 8 != 0 {
            data.push(0)
        }
        dyn_at = ELF_BASE + data_off + data.len
        d := vec[(i64, i64)]()
        for n in needed.items() {
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
        for e in d.items() {
            elf_put64(&data, e.0)
            elf_put64(&data, e.1)
        }
        dyn_len = ELF_BASE + data_off + data.len - dyn_at
        // one R_X86_64_GLOB_DAT relocation per import slot
        base := rela_at - (ELF_BASE + ro_off)
        for k in 0..externs.len {
            x := externs[k]
            r := vec[u8]()
            elf_put64(&r, gaddr.at(m.externs[x].got))
            elf_put64(&r, ((k + 1) << 32) | 6)
            elf_put64(&r, 0)
            assert base + 24 * k + 24 <= rodata.len
            for j in 0..24 {
                rodata[base + 24 * k + j] = r[j]
            }
        }
    }
    while data.len % 16 != 0 {
        data.push(0)
    }
    bss_addr := ELF_BASE + data_off + data.len
    bss_size := 0
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if !g.readonly && !is_some(g.data) {
            a := min(max(g.align, 1), 64)
            if g.size >= 64 {
                a = max(a, 64)
            }
            bss_size = elf_align_up(bss_size, a)
            gaddr[gi] = bss_addr + bss_size
            bss_size += max(g.size, 1)
        }
    }
    // ---- relocations ----
    entry_addr := func_addr.at(m.entry)
    start_addr := ELF_BASE + text_off
    rel := i32(entry_addr - (start_addr + 8))
    for k in 0..4 {
        text[4 + k] = u8(u32(rel) >> u32(8 * k))
    }
    for ci in 0..out.funcs.len {
        c := &out.funcs[ci]
        fo := func_off.at(c.fid)
        fa := func_addr.at(c.fid)
        for r in c.code.relocs.items() {
            at := fo + r.off
            val := match r.kind {
                Abs32Global(g) => gaddr.at(g) + i64(r.addend)
                Abs32Func(f) => func_addr.at(f) + i64(r.addend)
                Abs32FConst(i) => fpool_addr + 16 * i + i64(r.addend)
                Rel32Func(f) => func_addr.at(f) - (fa + r.off + 4)
            }
            assert val >= -2147483648 && val <= 2147483647, "relocation out of range"
            assert at >= 0 && at + 4 <= text.len
            v32 := u32(i32(val))
            for k in 0..4 {
                text[at + k] = u8(v32 >> u32(8 * k))
            }
        }
    }
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.relocs.is_empty() {
            continue
        }
        if g.readonly {
            elf_link_patch_data(&rodata, ELF_BASE + ro_off, g, gaddr[gi], &gaddr, &func_addr)
        } else if is_some(g.data) {
            elf_link_patch_data(&data, ELF_BASE + data_off, g, gaddr[gi], &gaddr, &func_addr)
        }
    }
    // ---- symbols ----
    strtab := vec_of([]u8{0})
    symtab := vec_fill(24, u8(0))
    nsyms := 1
    for ci in 0..out.funcs.len {
        c := &out.funcs[ci]
        f := &m.funcs[c.fid]
        name_off := strtab.len
        strtab.extend(f.name)
        strtab.push(0)
        elf_put32(&symtab, name_off)
        symtab.push(2) // STB_LOCAL, STT_FUNC
        symtab.push(0)
        elf_put16(&symtab, 1)
        elf_put64(&symtab, func_addr[c.fid])
        elf_put64(&symtab, func_size[c.fid])
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
    symtab_off := elf_align_up(file.len, 8)
    file.resize(symtab_off, 0)
    file.extend(symtab.items())
    strtab_off := file.len
    file.extend(strtab.items())
    shstr_off := file.len
    file.extend(shstr)
    sh_off := elf_align_up(file.len, 8)
    file.resize(sh_off, 0)
    sh := vec[u8]()
    // one section header (the name is looked up in the section name table `names`)
    fn section(sh: *Vec[u8], names: str, name: str, ty: i64, flags: i64, addr: i64, off: i64, size: i64, link: i64, info: i64, align: i64, entsize: i64) {
        elf_put32(sh, if name == "" { 0 } else { elf_link_name_of(names, name) })
        elf_put32(sh, ty)
        elf_put64(sh, flags)
        elf_put64(sh, addr)
        elf_put64(sh, off)
        elf_put64(sh, size)
        elf_put32(sh, link)
        elf_put32(sh, info)
        elf_put64(sh, align)
        elf_put64(sh, entsize)
    }
    section(&sh, shstr, "", 0, 0, 0, 0, 0, 0, 0, 0, 0)
    section(&sh, shstr, ".text", 1, 6, ELF_BASE + text_off, text_off, text.len, 0, 0, 16, 0)
    section(&sh, shstr, ".rodata", 1, 2, ELF_BASE + ro_off, ro_off, rodata.len, 0, 0, 16, 0)
    section(&sh, shstr, ".data", 1, 3, ELF_BASE + data_off, data_off, data.len, 0, 0, 16, 0)
    section(&sh, shstr, ".bss", 8, 3, bss_addr, data_off + data.len, bss_size, 0, 0, 64, 0)
    section(&sh, shstr, ".symtab", 2, 0, 0, symtab_off, symtab.len, 6, nsyms, 8, 24)
    section(&sh, shstr, ".strtab", 3, 0, 0, strtab_off, strtab.len, 0, 0, 1, 0)
    section(&sh, shstr, ".shstrtab", 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0)
    if dynamic {
        section(&sh, shstr, ".dynstr", 3, 2, dynstr_at, dynstr_at - ELF_BASE, dynstr_len, 0, 0, 1, 0)
        section(&sh, shstr, ".dynsym", 11, 2, dynsym_at, dynsym_at - ELF_BASE, 24 * (externs.len + 1), 8, 1, 8, 24)
        section(&sh, shstr, ".dynamic", 6, 3, dyn_at, dyn_at - ELF_BASE, dyn_len, 8, 0, 8, 16)
    }
    file.extend(sh.items())
    // ELF header
    h := vec[u8]()
    h.extend([]u8{0x7F, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0})
    elf_put16(&h, 2)
    elf_put16(&h, 62)
    elf_put32(&h, 1)
    elf_put64(&h, start_addr)
    elf_put64(&h, 64)
    elf_put64(&h, sh_off)
    elf_put32(&h, 0)
    elf_put16(&h, 64)
    elf_put16(&h, 56)
    elf_put16(&h, nph)
    elf_put16(&h, 64)
    elf_put16(&h, if dynamic { 11 } else { 8 })
    elf_put16(&h, 7)
    // program headers
    fn segment(h: *Vec[u8], ty: i64, flags: i64, off: i64, vaddr: i64, filesz: i64, memsz: i64, align: i64) {
        elf_put32(h, ty)
        elf_put32(h, flags)
        elf_put64(h, off)
        elf_put64(h, vaddr)
        elf_put64(h, vaddr)
        elf_put64(h, filesz)
        elf_put64(h, memsz)
        elf_put64(h, align)
    }
    if dynamic {
        segment(&h, 6, 4, 64, ELF_BASE + 64, 56 * nph, 56 * nph, 8) // PT_PHDR
        segment(&h, 3, 4, interp_at - ELF_BASE, interp_at, interp_len, interp_len, 1) // PT_INTERP
    }
    segment(&h, 1, 5, 0, ELF_BASE, ro_end, ro_end, 0x1000)
    segment(&h, 1, 6, data_off, ELF_BASE + data_off, data.len, data.len + bss_size, 0x1000)
    if dynamic {
        segment(&h, 2, 6, dyn_at - ELF_BASE, dyn_at, dyn_len, dyn_len, 8) // PT_DYNAMIC
    }
    segment(&h, 0x6474e551, 6, 0, 0, 0, 0, 16)
    assert h.len <= file.len
    for k in 0..h.len {
        file[k] = h[k]
    }
    return (file.items(), "")
}
