// Windows x86-64 executable (PE32+) writer and linker.
//
// The image is relocatable (ASLR: DYNAMIC_BASE, HIGH_ENTROPY_VA; preferred base 0x140000000,
// above 4 GiB as high entropy wants). The code holds no absolute address: it addresses code and
// data relative to rip (x86/emit.al). Every absolute address in the data (a pointer in a
// global, the four addresses of the TLS directory) is listed in the base relocation table
// (.reloc), which the loader applies when it places the image elsewhere; the import, exception
// and resource tables hold offsets from the base (RVAs) and need none. C functions and
// variables of DLLs are imported through the import address table: the import slot of each
// (its `got` global) is its IAT entry, which the loader fills with the address of the
// function or variable. The resources (.rsrc: manifest, icon, version) are built by rsrc.al.

use "objwrite.al"
use "rsrc.al"

priv const SECT_ALIGN = 0x1000
priv const FILE_ALIGN = 0x200

// The preferred base of the image. ALC_PE_BASE=<hex> sets another one (a multiple of 64 KiB):
// for tests/pe/check.py, which applies the base relocations of an image built for one base
// and compares the result with the same program built for another (-1: not a valid base).
priv fn image_base() -> i64 {
    s, set := env_get("ALC_PE_BASE")
    if !set {
        return 0x1_4000_0000
    }
    b, ok := parse_i64(s, 16)
    return if ok && b >= 0x10000 && b % 0x10000 == 0 && b < (1 << 46) { b } else { -1 }
}

// The base relocation table for the 8-byte absolute addresses at the RVAs `fix`: per 4 KiB
// page that has any, a block (page RVA, block size, then a u16 per address: type 10 (DIR64)
// << 12 | offset in the page, padded with a 0 entry to a multiple of 4 bytes)
priv fn base_relocs(fix: *Vec[i64]) -> Vec[u8] {
    sort(fix.items())
    r := vec[u8]()
    i := 0
    while i < fix.len {
        page := fix[i] - fix[i] % 4096
        j := i
        while j < fix.len && fix[j] < page + 4096 {
            j += 1
        }
        put32(&r, page)
        put32(&r, 8 + 2 * align_up(j - i, 2))
        for k in i..j {
            put16(&r, 0xA000 | (fix[k] - page))
        }
        if (j - i) % 2 != 0 {
            put16(&r, 0)
        }
        i = j
    }
    r
}

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
    base := image_base()
    if base < 0 {
        return ("", "ALC_PE_BASE is not an image base: hexadecimal digits, a multiple of 10000 (64 KiB)")
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
    layout_text(&text, out, base + text_rva, &func_off, &func_addr)
    // ---- .rdata: float constants, read-only globals ----
    ro_rva := align_up(text_rva + text.len, SECT_ALIGN)
    fpool_addr := base + ro_rva
    rodata := layout_rodata(m, out, live.items(), base + ro_rva, &gaddr)
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
            put32(&pdata, func_addr[c.fid] - base)
            put32(&pdata, func_addr[c.fid] - base + c.code.bytes.len)
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
            gaddr[m.externs[x].got] = base + id_rva + iat + 8 * k
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
                gaddr[gi] = base + data_rva + data.len
                data.extend(d.items())
            }
            _ => {}
        }
    }
    data.resize(align_up(data.len, 16), 0)
    // the TLS directory (data directory 9): the loader gives every thread a zeroed thread block
    // of tls_size bytes (see layout_tls; no template data, no callbacks: an empty list after
    // the directory) and stores the block's index in __win_tls_index, which the code reads
    tls_size := layout_tls(m, &gaddr, false)
    tls_index := -1
    for gi in 0..m.globals.len {
        if m.globals[gi].name == "__win_tls_index" && !m.globals[gi].readonly {
            tls_index = gi
        }
    }
    tls_dir := data.len
    if tls_index >= 0 {
        empty := base + data_rva + tls_dir + 40
        put64(&data, empty) // StartAddressOfRawData
        put64(&data, empty) // EndAddressOfRawData
        put64(&data, 0)     // AddressOfIndex (below)
        put64(&data, empty) // AddressOfCallBacks
        put32(&data, tls_size)
        put32(&data, 0)
        put64(&data, 0)     // the empty callback list
    }
    data.resize(align_up(data.len, 16), 0)
    bss_size := layout_bss(m, base + data_rva + data.len, &gaddr)
    // the RVAs of the absolute addresses in the image, for the base relocation table
    fix := vec[i64]()
    if tls_index >= 0 {
        set64(&data, tls_dir + 16, gaddr[tls_index])
        for k in 0..4 {
            fix.push(data_rva + tls_dir + 8 * k)
        }
    }
    image_end := data_rva + data.len + bss_size
    // the code addresses code and data with 32-bit displacements from rip
    if image_end > 0x7FFF_0000 {
        return ("", fmt("the program's code and global variables take ", image_end,
            " bytes; at most ", 0x7FFF_0000, " fit (put large tables in memory from alloc instead)"))
    }
    // ---- relocations ----
    for ci in 0..out.funcs.len {
        for r in out.funcs[ci].code.relocs {
            match r.kind {
                // (the offset of a thread-local global in the thread block)
                Abs32Global(g) => assert m.globals[g].tls, "an absolute address in Windows code"
                Abs32Func(_), Abs32FConst(_) => panic("an absolute address in Windows code")
                _ => {}
            }
        }
    }
    patch_text(&text, out, &func_off, &func_addr, &gaddr, fpool_addr)
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.relocs.is_empty() || is_iat[gi] || !live[gi] {
            continue
        }
        if g.readonly {
            patch_data(&rodata, base + ro_rva, g, gaddr[gi], &gaddr, &func_addr)
        } else if is_some(g.data) {
            patch_data(&data, base + data_rva, g, gaddr[gi], &gaddr, &func_addr)
        } else {
            continue
        }
        for rl in g.relocs {
            fix.push(gaddr[gi] - base + rl.0)
        }
    }
    // ---- .rsrc, .reloc ----
    rs_rva := if data.len + bss_size == 0 { data_rva } else { align_up(image_end, SECT_ALIGN) }
    rsrc := pe_resources(rs_rva)
    rl_rva := align_up(rs_rva + rsrc.len, SECT_ALIGN)
    reloc := base_relocs(&fix)
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
    secs.push(Section{name: ".rsrc", rva: rs_rva, data: rsrc, vsize: rsrc.len, flags: 0x40000040})
    if !reloc.is_empty() {
        // (discardable: the loader needs it only while it loads the image)
        secs.push(Section{name: ".reloc", rva: rl_rva, data: reloc, vsize: reloc.len, flags: 0x42000040})
    }
    hdr_size := align_up(64 + 4 + 20 + 240 + 40 * secs.len, FILE_ALIGN)
    last := secs.last()
    image_size := align_up(last.rva + last.vsize, SECT_ALIGN)
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
    put16(&h, 0x0022) // executable, large address aware
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
    put32(&h, func_addr[m.entry] - base) // entry point: __entry
    put32(&h, text_rva)
    put64(&h, base)
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
    // high entropy ASLR, relocatable (dynamic base), NX compatible, terminal server aware
    put16(&h, 0x8160)
    put64(&h, 16 << 20) // stack reserve
    put64(&h, 64 << 10) // stack commit
    put64(&h, 1 << 20) // heap reserve
    put64(&h, 4 << 10) // heap commit
    put32(&h, 0)
    put32(&h, 16)
    // data directories: 1 = imports, 2 = resources, 3 = exceptions (.pdata), 5 = base
    // relocations, 9 = TLS, 12 = import address table
    for d in 0..16 {
        match d {
            1 if !libs.is_empty() => {
                put32(&h, id_rva)
                put32(&h, 20 * (nl + 1))
            }
            2 => {
                put32(&h, rs_rva)
                put32(&h, rsrc.len)
            }
            3 if !pdata.is_empty() => {
                put32(&h, pd_rva)
                put32(&h, pdata.len)
            }
            5 if !reloc.is_empty() => {
                put32(&h, rl_rva)
                put32(&h, reloc.len)
            }
            9 if tls_index >= 0 => {
                put32(&h, data_rva + tls_dir)
                put32(&h, 40)
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
