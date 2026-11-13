// Windows x86-64 executable (PE32+) writer and linker.
//
// The image is loaded at its preferred base and has no base relocations: the code addresses
// code and data with 32-bit absolute displacements, as in the ELF executables. C functions and
// variables of DLLs are imported through the import address table: the import slot of each
// (its `got` global) is its IAT entry, which the loader fills with the address of the
// function or variable.

use "objwrite.al"

priv const BASE = 0x400000
priv const SECT_ALIGN = 0x1000
priv const FILE_ALIGN = 0x200

priv fn is_dll(lib: str) -> bool {
    return len(lib) > 4 && to_lower(lib[len(lib) - 4..]) == ".dll"
}

priv struct Section {
    name: str
    rva: i64
    data: Vec[u8]
    vsize: i64 // the size in memory (more than the data: zero-filled)
    flags: i64
}

// Result: (file bytes, error text); the error text is empty on success.
fn pe_link(m: *Module, out: *Output) -> (str, str) {
    if len(out.err) != 0 {
        return ("", out.err)
    }
    imports := used_externs(m, out)
    for x in imports {
        lib := m.externs[x].lib
        if !is_dll(lib) {
            return ("", fmt("`", m.externs[x].name, "` is imported from `", lib,
                "`, which is not a Windows library: a program built with --target windows imports from DLLs (`extern \"kernel32.dll\" fn ...`)"))
        }
    }
    is_iat := vec_fill(m.globals.len, false)
    for x in imports {
        is_iat[m.externs[x].got] = true
    }
    gaddr := vec_fill(m.globals.len, 0)
    live := x86_live_data(m, out)
    func_addr := vec_fill(m.funcs.len, 0)
    func_off := vec_fill(m.funcs.len, 0)
    // ---- .text ----
    text_rva := SECT_ALIGN
    text := vec[u8]()
    layout_text(&text, out, BASE + text_rva, &func_off, &func_addr)
    // ---- .rdata: float constants, read-only globals ----
    ro_rva := align_up(text_rva + text.len, SECT_ALIGN)
    fpool_addr := BASE + ro_rva
    rodata := layout_rodata(m, out, live.items(), BASE + ro_rva, &gaddr)
    // the unwind information of the functions with a frame (4-byte aligned)
    unwind_rva := vec_fill(m.funcs.len, 0)
    for c in out.funcs {
        if !c.code.unwind.is_empty() {
            rodata.resize(align_up(rodata.len, 4), 0)
            unwind_rva[c.fid] = ro_rva + rodata.len
            rodata.extend(c.code.unwind.items())
        }
    }
    // ---- .pdata: the exception table, a RUNTIME_FUNCTION (start, end, unwind information)
    // per function with a frame, in the order of the addresses (functions without one are
    // leaf functions: the return address is at [rsp]) ----
    pd_rva := if rodata.is_empty() { ro_rva } else { align_up(ro_rva + rodata.len, SECT_ALIGN) }
    pdata := vec[u8]()
    for c in out.funcs {
        if !c.code.unwind.is_empty() {
            put32(&pdata, func_addr[c.fid] - BASE)
            put32(&pdata, func_addr[c.fid] - BASE + c.code.bytes.len)
            put32(&pdata, unwind_rva[c.fid])
        }
    }
    // ---- .idata: import directory, lookup tables, names, import address tables ----
    id_rva := if pdata.is_empty() { pd_rva } else { align_up(pd_rva + pdata.len, SECT_ALIGN) }
    idata := vec[u8]()
    libs := vec[str]()
    for x in imports {
        if !libs.contains(m.externs[x].lib) {
            libs.push(m.externs[x].lib)
        }
    }
    // descriptors (20 bytes each, then an empty one), then per library its lookup table and
    // its IAT (8 bytes per import, then 0), then the hint/name entries and library names
    nl := libs.len
    desc_size := 20 * (nl + 1)
    tables := vec[(i64, i64)]() // (lookup table, IAT) offsets per library
    pos := desc_size
    iat_lo := -1
    iat_hi := 0
    for l in libs {
        n := 0
        for x in imports {
            if m.externs[x].lib == l {
                n += 1
            }
        }
        ilt := pos
        iat := pos + 8 * (n + 1)
        tables.push((ilt, iat))
        pos = iat + 8 * (n + 1)
        if iat_lo < 0 {
            iat_lo = iat
        }
        iat_hi = pos
    }
    idata.resize(pos, 0)
    for li in 0..nl {
        l := libs[li]
        ilt, iat := tables[li]
        k := 0
        for x in imports {
            if m.externs[x].lib != l {
                continue
            }
            // hint (0) and name, padded to an even length
            idata.resize(align_up(idata.len, 2), 0)
            hn := id_rva + idata.len
            put16(&idata, 0)
            idata.extend(m.externs[x].name)
            idata.push(0)
            set64(&idata, ilt + 8 * k, hn)
            set64(&idata, iat + 8 * k, hn)
            gaddr[m.externs[x].got] = BASE + id_rva + iat + 8 * k
            k += 1
        }
        name_rva := id_rva + idata.len
        idata.extend(l)
        idata.push(0)
        // the descriptor: lookup table, (time stamp, forwarder chain: 0), name, IAT
        set32(&idata, 20 * li, id_rva + ilt)
        set32(&idata, 20 * li + 12, name_rva)
        set32(&idata, 20 * li + 16, id_rva + iat)
    }
    // ---- .data and .bss ----
    data_rva := if idata.is_empty() { id_rva } else { align_up(id_rva + idata.len, SECT_ALIGN) }
    data := vec[u8]()
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        match g.data {
            Some(d) if !g.readonly && !is_iat[gi] => {
                data.resize(align_up(data.len, max(g.align, 1)), 0)
                gaddr[gi] = BASE + data_rva + data.len
                data.extend(d.items())
            }
            _ => {}
        }
    }
    data.resize(align_up(data.len, 16), 0)
    bss_size := layout_bss(m, BASE + data_rva + data.len, &gaddr)
    image_end := data_rva + data.len + bss_size
    // the code addresses code and data with 32-bit absolute and relative displacements
    if BASE + image_end > 0x7FFF_FFFF {
        return ("", fmt("the program's code and global variables take ", image_end,
            " bytes; at most ", 0x7FFF_FFFF - BASE, " fit (put large tables in memory from alloc instead)"))
    }
    // ---- relocations ----
    patch_text(&text, out, &func_off, &func_addr, &gaddr, fpool_addr)
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.relocs.is_empty() || is_iat[gi] || !live[gi] {
            continue
        }
        if g.readonly {
            patch_data(&rodata, BASE + ro_rva, g, gaddr[gi], &gaddr, &func_addr)
        } else if is_some(g.data) {
            patch_data(&data, BASE + data_rva, g, gaddr[gi], &gaddr, &func_addr)
        }
    }
    // ---- sections (empty ones are left out) ----
    secs := vec[Section]()
    secs.push(Section{name: ".text", rva: text_rva, data: text, vsize: text.len, flags: 0x60000020})
    if !rodata.is_empty() {
        secs.push(Section{name: ".rdata", rva: ro_rva, data: rodata, vsize: rodata.len, flags: 0x40000040})
    }
    if !pdata.is_empty() {
        secs.push(Section{name: ".pdata", rva: pd_rva, data: pdata, vsize: pdata.len, flags: 0x40000040})
    }
    if !idata.is_empty() {
        secs.push(Section{name: ".idata", rva: id_rva, data: idata, vsize: idata.len, flags: 0xC0000040})
    }
    if data.len + bss_size > 0 {
        secs.push(Section{name: ".data", rva: data_rva, data: data, vsize: data.len + bss_size, flags: 0xC0000040})
    }
    hdr_size := align_up(64 + 4 + 20 + 240 + 40 * secs.len, FILE_ALIGN)
    image_size := align_up(image_end, SECT_ALIGN)
    last := secs.last()
    if last.vsize == 0 {
        image_size = align_up(last.rva + 1, SECT_ALIGN)
    }
    // ---- headers ----
    h := vec[u8]()
    // DOS header: "MZ", e_lfanew = 64
    h.extend([]u8{'M', 'Z'})
    h.resize(60, 0)
    put32(&h, 64)
    h.extend([]u8{'P', 'E', 0, 0})
    // COFF file header
    put16(&h, 0x8664)
    put16(&h, secs.len)
    put32(&h, 0) // time stamp: none (the output depends on the input only)
    put32(&h, 0)
    put32(&h, 0)
    put16(&h, 240)
    put16(&h, 0x0023) // relocations stripped, executable, large address aware
    // optional header (PE32+)
    code_size := align_up(text.len, FILE_ALIGN)
    init_size := 0
    for s in secs {
        if s.flags & 0x40 != 0 {
            init_size += align_up(s.data.len, FILE_ALIGN)
        }
    }
    put16(&h, 0x20B)
    h.push(1) // linker version
    h.push(0)
    put32(&h, code_size)
    put32(&h, init_size)
    put32(&h, 0)
    put32(&h, func_addr[m.entry] - BASE) // entry point: __entry
    put32(&h, text_rva)
    put64(&h, BASE)
    put32(&h, SECT_ALIGN)
    put32(&h, FILE_ALIGN)
    put16(&h, 6) // operating system version 6.0
    put16(&h, 0)
    put16(&h, 0) // image version
    put16(&h, 0)
    put16(&h, 6) // subsystem version 6.0
    put16(&h, 0)
    put32(&h, 0)
    put32(&h, image_size)
    put32(&h, hdr_size)
    put32(&h, 0) // checksum
    put16(&h, if pe_gui { 2 } else { 3 }) // subsystem: GUI (--gui) or console
    put16(&h, 0x8100) // NX compatible, terminal server aware (no ASLR: the image is not relocatable)
    put64(&h, 16 << 20) // stack reserve
    put64(&h, 64 << 10) // stack commit
    put64(&h, 1 << 20) // heap reserve
    put64(&h, 4 << 10) // heap commit
    put32(&h, 0)
    put32(&h, 16)
    // data directories: 1 = imports, 3 = exceptions (.pdata), 12 = import address table
    for d in 0..16 {
        match d {
            1 if !libs.is_empty() => {
                put32(&h, id_rva)
                put32(&h, 20 * (nl + 1))
            }
            3 if !pdata.is_empty() => {
                put32(&h, pd_rva)
                put32(&h, pdata.len)
            }
            12 if !libs.is_empty() => {
                put32(&h, id_rva + iat_lo)
                put32(&h, iat_hi - iat_lo)
            }
            _ => put64(&h, 0)
        }
    }
    // section table
    raw := hdr_size
    raw_at := vec[i64]()
    for s in secs {
        h.extend(pad_right(s.name, 8, 0))
        put32(&h, s.vsize)
        put32(&h, s.rva)
        rs := align_up(s.data.len, FILE_ALIGN)
        put32(&h, rs)
        put32(&h, if rs == 0 { 0 } else { raw })
        raw_at.push(raw)
        raw += rs
        put32(&h, 0)
        put32(&h, 0)
        put16(&h, 0)
        put16(&h, 0)
        put32(&h, s.flags)
    }
    assert h.len <= hdr_size
    file := vec[u8]()
    file.extend(h.items())
    file.resize(hdr_size, 0)
    for si in 0..secs.len {
        s := &secs[si]
        if s.data.is_empty() {
            continue
        }
        file.resize(raw_at[si], 0)
        file.extend(s.data.items())
        file.resize(raw_at[si] + align_up(s.data.len, FILE_ALIGN), 0)
    }
    return (file.items(), "")
}
