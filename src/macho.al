// Mach-O executable writer for arm64 macOS (--target macos): the code of src/arm64, linked as
// Apple's linker links a position-independent executable for macOS 11 and later. Nothing of this
// has run on a Mac; tests/macho/check.al checks the files structurally (docs/MACOS_TEST.md).
//
// Layout (16 KiB pages; the image is loaded at a random address, so every absolute address in
// data is a fixup):
//
//   __PAGEZERO    4 GiB without access
//   __TEXT        the Mach header and load commands, __text (an entry stub, then the functions),
//                 __const (the float pool, the read-only globals without addresses in them)
//   __DATA_CONST  __got (the import slots: one per C function or variable, bound by dyld),
//                 __const (the read-only globals that hold addresses); read-only after dyld
//   __DATA        __data (the writable globals with data), __thread_vars (one thread-local
//                 variable descriptor for the whole thread block), __thread_bss (the block's
//                 template: zeros), __bss
//   __LINKEDIT    chained fixups, the exports trie (__mh_execute_header), the symbol table, the
//                 indirect symbols of __got, the string table, the code signature
//
// Fixups (LC_DYLD_CHAINED_FIXUPS, pointer format DYLD_CHAINED_PTR_64 as ld64 and lld write
// it for arm64): each 8-byte slot to bind (an import slot, the descriptor's thunk
// `__tlv_bootstrap`) or to rebase (an address in data) holds its chained form, linked to the next
// one in its 16 KiB page by a 12-bit distance in 4-byte units. The code signature is the ad-hoc,
// linker-signed one that Apple silicon requires of every executable: a CodeDirectory with the
// SHA-256 of every 4 KiB page of the file before the signature (src/sha256.al).
//
// Thread-local data: the code reaches the thread block through the descriptor (`Tlv` in
// src/arm64: `adrp/add x0, desc; ldr x16, [x0]; blr x16`, which returns the block of the calling
// thread, allocated by dyld for any thread on its first use: also threads that C libraries
// start). TPIDR_EL0, which the Linux layer owns, is not the program's on macOS.

use "sha256.al"

priv const MBASE = 0x1_0000_0000
priv const MPAGE = 0x4000
priv const LIBSYSTEM = "/usr/lib/libSystem.B.dylib"

priv fn pad_name(v: *Vec[u8], s: str) {
    for k in 0..16 {
        v.push(if k < len(s) { s[k] } else { 0 })
    }
}

priv fn put32be(v: *Vec[u8], x: i64) {
    for k in 0..4 {
        v.push(u8(x >> (24 - 8 * k)))
    }
}

priv fn put64be(v: *Vec[u8], x: i64) {
    put32be(v, x >> 32)
    put32be(v, x & 0xFFFF_FFFF)
}

priv fn uleb(v: *Vec[u8], x0: i64) {
    x := x0
    loop {
        b := x & 0x7F
        x = x >> 7
        if x == 0 {
            v.push(u8(b))
            return
        }
        v.push(u8(b | 0x80))
    }
}

// a section of the file: its segment, name, address, size, file offset (0: zero-filled), log2 of
// its alignment, flags, reserved1
priv struct Sect {
    seg: str
    name: str
    addr: i64
    size: i64
    off: i64
    align: i64
    flags: i64
    r1: i64
}

priv fn section_cmd(v: *Vec[u8], s: *Sect) {
    pad_name(v, s.name)
    pad_name(v, s.seg)
    put64(v, s.addr)
    put64(v, s.size)
    put32(v, s.off)
    put32(v, s.align)
    put32(v, 0)
    put32(v, 0)
    put32(v, s.flags)
    put32(v, s.r1)
    put32(v, 0)
    put32(v, 0)
}

priv fn segment_cmd(v: *Vec[u8], name: str, vmaddr: i64, vmsize: i64, fileoff: i64, filesize: i64, prot: i64, flags: i64, sects: []Sect) {
    put32(v, 0x19)
    put32(v, 72 + 80 * len(sects))
    pad_name(v, name)
    put64(v, vmaddr)
    put64(v, vmsize)
    put64(v, fileoff)
    put64(v, filesize)
    put32(v, prot)
    put32(v, prot)
    put32(v, len(sects))
    put32(v, flags)
    for s in sects {
        section_cmd(v, &s)
    }
}

// The entry stub: dyld calls it as `main(argc, argv, envp, apple)`; the run-time library's
// __rt_init (src/prelude_macos.al) takes argv: `mov x0, x1; bl __entry; brk #0`.
priv fn entry_stub() -> Vec[u32] {
    s := vec[u32]()
    s.push(a64_logic_reg(1, 1, false, 0, 31, 1, A64_LSL, 0))
    s.push(a64_b(true, 0)) // patched: bl __entry
    s.push(a64_brk(0))
    return s
}

// an import: (library ordinal from 1, symbol name with its leading underscore)
priv struct Imp {
    lib: i64
    name: str
}

// a fixup in a segment of data: its address, and either an import (bind >= 0) or the address
// it holds (rebase)
priv struct Fix {
    at: i64
    bind: i64
    target: i64
}

fn macho_link(m: *Module, out: *A64Output, ident: str) -> (str, str) {
    if len(out.err) != 0 {
        return ("", out.err)
    }
    externs := a64_used_externs(m, out)
    libs := vec_of([]str{LIBSYSTEM})
    imps := vec[Imp]()
    for x in externs {
        lib := m.externs[x].lib
        low := to_lower(lib)
        if ends_with(low, ".dll") || find(lib, ".so") >= 0 {
            return ("", fmt("`", m.externs[x].name, "` is imported from `", lib,
                "`, which is not a macOS library (a .dylib or a framework): this build makes a macOS executable"))
        }
        if !libs.contains(lib) {
            libs.push(lib)
        }
        imps.push(Imp{lib: index_of(libs.items(), lib) + 1, name: fmt("_", m.externs[x].name)})
    }
    // (the thunk of the thread-local variable descriptor, which dyld replaces)
    tlv_imp := imps.len
    imps.push(Imp{lib: 1, name: "__tlv_bootstrap"})
    is_slot := vec_fill(m.globals.len, -1)
    for k, x in externs {
        is_slot[m.externs[x].got] = k
    }
    live := a64_live_data(m, out)
    // ---- the size of the load commands ----
    ncmd := 14 + libs.len
    cmds_size := 72 + (72 + 160) + (72 + 160) + (72 + 320) + 72 + 16 + 16 + 24 + 80 + 32 + 24 + 24 + 24 + 16
    for l in libs {
        cmds_size += 24 + align_up(len(l) + 1, 8)
    }
    // ---- __TEXT ----
    text_off := align_up(32 + cmds_size, 16)
    text := vec[u8]()
    for wd in entry_stub() {
        put32(&text, i64(wd))
    }
    func_addr := vec_fill(m.funcs.len, 0)
    func_off := vec_fill(m.funcs.len, 0)
    for f in out.funcs {
        text.resize(align_up(text.len, 16), 0)
        func_off[f.fid] = text.len
        func_addr[f.fid] = MBASE + text_off + text.len
        text.extend(f.code.bytes.items())
    }
    gaddr := vec_fill(m.globals.len, 0)
    tconst_off := align_up(text_off + text.len, 16)
    fpool_addr := MBASE + tconst_off
    tconst := vec[u8]()
    for bits in out.fpool {
        put64(&tconst, i64(bits.lo))
        put64(&tconst, i64(bits.hi))
    }
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.readonly && live[gi] && g.relocs.is_empty() {
            tconst.resize(align_up(tconst.len, max(g.align, 1)), 0)
            gaddr[gi] = MBASE + tconst_off + tconst.len
            match g.data {
                Some(d) => tconst.extend(d.items())
                None => tconst.resize(tconst.len + g.size, 0)
            }
            tconst.push(0) // keep distinct addresses for empty strings
        }
    }
    text_size := align_up(tconst_off + tconst.len, MPAGE)
    // ---- __DATA_CONST: __got, then the read-only globals with addresses ----
    dc_off := text_size
    got_addr := MBASE + dc_off
    for gi in 0..m.globals.len {
        if is_slot[gi] >= 0 {
            gaddr[gi] = got_addr + 8 * is_slot[gi]
        }
    }
    dconst_off := dc_off + 8 * externs.len
    dconst := vec[u8]()
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.readonly && live[gi] && !g.relocs.is_empty() {
            dconst.resize(align_up(dconst.len, max(g.align, 8)), 0)
            gaddr[gi] = MBASE + dconst_off + dconst.len
            match g.data {
                Some(d) => dconst.extend(d.items())
                None => dconst.resize(dconst.len + g.size, 0)
            }
            dconst.push(0)
        }
    }
    dc_size := align_up(8 * externs.len + dconst.len, MPAGE)
    if dc_size == 0 {
        dc_size = MPAGE
    }
    // ---- __DATA: __data, __thread_vars, then zero-filled: __thread_bss, __bss ----
    d_off := dc_off + dc_size
    data := vec[u8]()
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        match g.data {
            Some(d) if !g.readonly && !g.tls && is_slot[gi] < 0 => {
                data.resize(align_up(data.len, max(g.align, 1)), 0)
                gaddr[gi] = MBASE + d_off + data.len
                data.extend(d.items())
            }
            _ => {}
        }
    }
    data_size := data.len
    data.resize(align_up(data.len, 8), 0)
    tv_addr := MBASE + d_off + data.len
    data.resize(data.len + 24, 0) // thunk (a bind), key (dyld's), offset 0
    tlsoff := vec_fill(m.globals.len, 0)
    tls_size := layout_tls(m, &tlsoff, false)
    tbss_addr := align_up(MBASE + d_off + data.len, 16)
    bss_addr := align_up(tbss_addr + tls_size, 64)
    bss_size := layout_bss(m, bss_addr, &gaddr)
    d_filesize := align_up(data.len, MPAGE)
    d_vmsize := align_up(bss_addr + bss_size - (MBASE + d_off), MPAGE)
    le_off := d_off + d_filesize
    le_addr := MBASE + d_off + d_vmsize
    if le_addr - MBASE > 0xFFFF_0000 {
        return ("", fmt("the program's code and global variables take ", le_addr - MBASE, " bytes; at most 4 GiB fit"))
    }
    // ---- the code's relocations ----
    stub_addr := MBASE + text_off
    set32(&text, 4, i64(a64_b(true, (func_addr[m.entry] - (stub_addr + 4)) / 4)))
    for f in out.funcs {
        fo := func_off[f.fid]
        for r in f.code.relocs {
            at := fo + r.off
            pc := MBASE + text_off + at
            sym := match r.tgt {
                AT_GLOBAL => gaddr[r.id]
                AT_FUNC => func_addr[r.id]
                AT_TLV => tv_addr
                _ => fpool_addr + 16 * r.id
            }
            target := sym + r.addend
            word := i64(text[at]) | i64(text[at + 1]) << 8 | i64(text[at + 2]) << 16 | i64(text[at + 3]) << 24
            match r.kind {
                AR_CALL26 => {
                    d := (target - pc) / 4
                    assert d >= -(1 << 25) && d < (1 << 25), "macho: call out of range"
                    word |= d & 0x3FFFFFF
                }
                AR_ADRP => {
                    pages := (target >> 12) - (pc >> 12)
                    word |= (pages & 3) << 29 | ((pages >> 2) & 0x7FFFF) << 5
                }
                AR_LDR64 => {
                    assert target & 7 == 0, "macho: a misaligned 8-byte load"
                    word |= ((target & 0xFFF) >> 3) << 10
                }
                _ => word |= (target & 0xFFF) << 10
            }
            set32(&text, at, word)
        }
    }
    // ---- data with addresses: the fixups ----
    dcbuf := vec_fill(8 * externs.len, u8(0))
    dcbuf.extend(dconst.items())
    fixes := vec[Fix]()
    for k in 0..externs.len {
        fixes.push(Fix{at: got_addr + 8 * k, bind: k, target: 0})
    }
    fixes.push(Fix{at: tv_addr, bind: tlv_imp, target: 0})
    for gi in 0..m.globals.len {
        g := &m.globals[gi]
        if g.relocs.is_empty() || !live[gi] || g.tls || (!g.readonly && is_none(g.data)) {
            continue
        }
        buf := if g.readonly { &dcbuf } else { &data }
        base := if g.readonly { MBASE + dc_off } else { MBASE + d_off }
        patch_data(buf, base, g, gaddr[gi], &gaddr, &func_addr)
        for rl in g.relocs {
            a := gaddr[gi] + rl.0
            assert a % 8 == 0, "macho: a misaligned address in data"
            t := 0
            for k in 0..8 {
                t |= i64(buf[a - base + k]) << (8 * k)
            }
            fixes.push(Fix{at: a, bind: -1, target: t})
        }
    }
    sort_by(fixes.items(), fn(a: Fix, b: Fix) -> bool { a.at < b.at })
    // the chained form of every slot, linked page by page
    for k, fx in fixes {
        next := 0
        if k + 1 < fixes.len && fixes[k + 1].at / MPAGE == fx.at / MPAGE {
            same_seg := (fx.at < MBASE + d_off) == (fixes[k + 1].at < MBASE + d_off)
            if same_seg && (fixes[k + 1].at - fx.at) / 4 < 4096 {
                next = (fixes[k + 1].at - fx.at) / 4
            }
        }
        v := 0
        if fx.bind >= 0 {
            v = fx.bind | next << 51 | (1 << 63)
        } else {
            assert fx.target >= 0 && fx.target < (1 << 36), "macho: a rebase target out of range"
            v = fx.target | next << 51
        }
        if fx.at < MBASE + d_off {
            set64(&dcbuf, fx.at - (MBASE + dc_off), v)
        } else {
            set64(&data, fx.at - (MBASE + d_off), v)
        }
    }
    // ---- __LINKEDIT: chained fixups ----
    le := vec[u8]()
    fixups_off := le_off
    {
        // header, then the starts in the image (5 segments), the starts in __DATA_CONST and
        // __DATA, the imports, the symbol names
        hdr := vec[u8]()
        starts := vec[u8]()
        put32(&starts, 5)
        seg_starts := vec[u8]()
        offs := vec_fill(5, 0)
        for si in 2..4 {
            seg_lo := if si == 2 { MBASE + dc_off } else { MBASE + d_off }
            seg_size := if si == 2 { dc_size } else { d_vmsize }
            npages := seg_size / MPAGE
            page_start := vec_fill(npages, 0xFFFF)
            for fx in fixes {
                if fx.at >= seg_lo && fx.at < seg_lo + seg_size {
                    p := (fx.at - seg_lo) / MPAGE
                    if page_start[p] == 0xFFFF {
                        page_start[p] = (fx.at - seg_lo) % MPAGE
                    }
                }
            }
            offs[si] = 4 + 4 * 5 + seg_starts.len
            put32(&seg_starts, 22 + 2 * npages)
            put16(&seg_starts, MPAGE)
            put16(&seg_starts, 2) // DYLD_CHAINED_PTR_64
            put64(&seg_starts, seg_lo - MBASE)
            put32(&seg_starts, 0)
            put16(&seg_starts, npages)
            for ps in page_start {
                put16(&seg_starts, ps)
            }
            seg_starts.resize(align_up(seg_starts.len, 4), 0)
        }
        for o in offs {
            put32(&starts, o)
        }
        starts.extend(seg_starts.items())
        names := vec[u8]()
        imports := vec[u8]()
        for im in imps {
            put32(&imports, im.lib | names.len << 9)
            names.extend(im.name)
            names.push(0)
        }
        starts_off := 32
        imports_off := align_up(starts_off + starts.len, 4)
        symbols_off := imports_off + imports.len
        put32(&hdr, 0)
        put32(&hdr, starts_off)
        put32(&hdr, imports_off)
        put32(&hdr, symbols_off)
        put32(&hdr, imps.len)
        put32(&hdr, 1) // DYLD_CHAINED_IMPORT
        put32(&hdr, 0) // uncompressed names
        hdr.resize(starts_off, 0)
        hdr.extend(starts.items())
        hdr.resize(imports_off, 0)
        hdr.extend(imports.items())
        hdr.extend(names.items())
        hdr.resize(align_up(hdr.len, 8), 0)
        le.extend(hdr.items())
    }
    fixups_size := le.len
    // the exports trie: __mh_execute_header at offset 0
    exports_off := le_off + le.len
    {
        mh := "__mh_execute_header"
        root := vec[u8]()
        root.push(0)
        root.push(1)
        root.extend(mh)
        root.push(0)
        child := root.len + 1
        uleb(&root, child)
        root.extend([]u8{2, 0, 0, 0})
        root.resize(align_up(root.len, 8), 0)
        le.extend(root.items())
    }
    exports_size := le_off + le.len - exports_off
    // the symbol table: the functions (local), __mh_execute_header, the imports (undefined)
    strtab := vec_of([]u8{' ', 0})
    syms := vec[u8]()
    fn nlist(syms: *Vec[u8], strx: i64, ty: i64, sect: i64, desc: i64, value: i64) {
        put32(syms, strx)
        syms.push(u8(ty))
        syms.push(u8(sect))
        put16(syms, desc)
        put64(syms, value)
    }
    nlocal := 0
    for f in out.funcs {
        nlist(&syms, strtab.len, 0x0e, 1, 0, func_addr[f.fid])
        strtab.extend(fmt("_", m.funcs[f.fid].name))
        strtab.push(0)
        nlocal += 1
    }
    nlist(&syms, strtab.len, 0x0f, 1, 0x10, MBASE)
    strtab.extend("__mh_execute_header")
    strtab.push(0)
    iundef := nlocal + 1
    for im in imps {
        nlist(&syms, strtab.len, 0x01, 0, im.lib << 8, 0)
        strtab.extend(im.name)
        strtab.push(0)
    }
    strtab.resize(align_up(strtab.len, 8), 0)
    sym_off := le_off + le.len
    le.extend(syms.items())
    indirect_off := le_off + le.len
    for k in 0..externs.len {
        put32(&le, iundef + k)
    }
    le.resize(align_up(le.len, 8), 0)
    str_off := le_off + le.len
    le.extend(strtab.items())
    // the code signature: 16-byte aligned, after everything it signs
    le.resize(align_up(le.len, 16), 0)
    sig_off := le_off + le.len
    nslots := (sig_off + 4095) / 4096
    ident_pad := align_up(len(ident) + 1, 16)
    cd_len := 88 + ident_pad + 32 * nslots
    sig_len := 12 + 8 + cd_len
    le_size := le.len + sig_len
    // ---- load commands ----
    cmds := vec[u8]()
    segment_cmd(&cmds, "__PAGEZERO", 0, MBASE, 0, 0, 0, 0, []Sect{})
    segment_cmd(&cmds, "__TEXT", MBASE, text_size, 0, text_size, 5, 0, []Sect{
        Sect{seg: "__TEXT", name: "__text", addr: MBASE + text_off, size: text.len, off: text_off, align: 4, flags: 0x80000400},
        Sect{seg: "__TEXT", name: "__const", addr: MBASE + tconst_off, size: tconst.len, off: tconst_off, align: 4},
    })
    segment_cmd(&cmds, "__DATA_CONST", MBASE + dc_off, dc_size, dc_off, dc_size, 3, 0x10, []Sect{
        Sect{seg: "__DATA_CONST", name: "__got", addr: got_addr, size: 8 * externs.len, off: dc_off, align: 3, flags: 6},
        Sect{seg: "__DATA_CONST", name: "__const", addr: MBASE + dconst_off, size: dconst.len, off: dconst_off, align: 3},
    })
    segment_cmd(&cmds, "__DATA", MBASE + d_off, d_vmsize, d_off, d_filesize, 3, 0, []Sect{
        Sect{seg: "__DATA", name: "__data", addr: MBASE + d_off, size: data_size, off: d_off, align: 4},
        Sect{seg: "__DATA", name: "__thread_vars", addr: tv_addr, size: 24, off: d_off + (tv_addr - (MBASE + d_off)), align: 3, flags: 0x13},
        Sect{seg: "__DATA", name: "__thread_bss", addr: tbss_addr, size: tls_size, off: 0, align: 4, flags: 0x12},
        Sect{seg: "__DATA", name: "__bss", addr: bss_addr, size: bss_size, off: 0, align: 6, flags: 1},
    })
    segment_cmd(&cmds, "__LINKEDIT", le_addr, align_up(le_size, MPAGE), le_off, le_size, 1, 0, []Sect{})
    put32(&cmds, 0x80000034) // LC_DYLD_CHAINED_FIXUPS
    put32(&cmds, 16)
    put32(&cmds, fixups_off)
    put32(&cmds, fixups_size)
    put32(&cmds, 0x80000033) // LC_DYLD_EXPORTS_TRIE
    put32(&cmds, 16)
    put32(&cmds, exports_off)
    put32(&cmds, exports_size)
    put32(&cmds, 0x2) // LC_SYMTAB
    put32(&cmds, 24)
    put32(&cmds, sym_off)
    put32(&cmds, nlocal + 1 + imps.len)
    put32(&cmds, str_off)
    put32(&cmds, strtab.len)
    put32(&cmds, 0xb) // LC_DYSYMTAB
    put32(&cmds, 80)
    for x in []i64{0, nlocal, nlocal, 1, iundef, imps.len, 0, 0, 0, 0, 0, 0, indirect_off, externs.len, 0, 0, 0, 0} {
        put32(&cmds, x)
    }
    put32(&cmds, 0xe) // LC_LOAD_DYLINKER
    put32(&cmds, 32)
    put32(&cmds, 12)
    cmds.extend("/usr/lib/dyld")
    cmds.resize(cmds.len + 32 - 12 - 13, 0)
    uuid_at := cmds.len + 8
    put32(&cmds, 0x1b) // LC_UUID (filled in below)
    put32(&cmds, 24)
    put64(&cmds, 0)
    put64(&cmds, 0)
    put32(&cmds, 0x32) // LC_BUILD_VERSION: macOS 11.0, SDK 11.0, no tools
    put32(&cmds, 24)
    put32(&cmds, 1)
    put32(&cmds, 0xb0000)
    put32(&cmds, 0xb0000)
    put32(&cmds, 0)
    put32(&cmds, 0x80000028) // LC_MAIN
    put32(&cmds, 24)
    put64(&cmds, text_off)
    put64(&cmds, 0)
    for l in libs {
        n := 24 + align_up(len(l) + 1, 8)
        put32(&cmds, 0xc) // LC_LOAD_DYLIB
        put32(&cmds, n)
        put32(&cmds, 24)
        put32(&cmds, 2)          // timestamp
        put32(&cmds, 0x10000)    // current version 1.0.0
        put32(&cmds, 0x10000)    // compatibility version 1.0.0
        cmds.extend(l)
        cmds.resize(cmds.len + n - 24 - len(l), 0)
    }
    put32(&cmds, 0x1d) // LC_CODE_SIGNATURE
    put32(&cmds, 16)
    put32(&cmds, sig_off)
    put32(&cmds, sig_len)
    assert cmds.len == cmds_size, "macho: the size of the load commands"
    // ---- the file ----
    file := vec[u8]()
    put32(&file, 0xfeedfacf)
    put32(&file, 0x0100000c) // CPU_TYPE_ARM64
    put32(&file, 0)
    put32(&file, 2)          // MH_EXECUTE
    put32(&file, ncmd)
    put32(&file, cmds_size)
    // MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE | MH_HAS_TLV_DESCRIPTORS
    put32(&file, 0x1 | 0x4 | 0x80 | 0x200000 | 0x800000)
    put32(&file, 0)
    file.extend(cmds.items())
    file.resize(text_off, 0)
    file.extend(text.items())
    file.resize(tconst_off, 0)
    file.extend(tconst.items())
    file.resize(dc_off, 0)
    file.extend(dcbuf.items())
    file.resize(d_off, 0)
    file.extend(data.items())
    file.resize(le_off, 0)
    file.extend(le.items())
    assert file.len == sig_off, "macho: the code signature's place"
    // the UUID: the first 16 bytes of the SHA-256 of the file so far (a version 4 form)
    h := sha256(file.items())
    for k in 0..16 {
        file[32 + uuid_at + k] = h[k]
    }
    file[32 + uuid_at + 6] = (h[6] & 0x0F) | 0x40
    file[32 + uuid_at + 8] = (h[8] & 0x3F) | 0x80
    // ---- the code signature (big-endian): a SuperBlob with one CodeDirectory ----
    sig := vec[u8]()
    put32be(&sig, 0xfade0cc0)
    put32be(&sig, sig_len)
    put32be(&sig, 1)
    put32be(&sig, 0)        // CSSLOT_CODEDIRECTORY
    put32be(&sig, 20)
    put32be(&sig, 0xfade0c02)
    put32be(&sig, cd_len)
    put32be(&sig, 0x20400)
    put32be(&sig, 0x20002)  // CS_ADHOC | CS_LINKER_SIGNED
    put32be(&sig, 88 + ident_pad) // hashOffset
    put32be(&sig, 88)       // identOffset
    put32be(&sig, 0)        // nSpecialSlots
    put32be(&sig, nslots)
    put32be(&sig, sig_off)  // codeLimit
    sig.push(32)            // hashSize
    sig.push(2)             // CS_HASHTYPE_SHA256
    sig.push(0)             // platform
    sig.push(12)            // log2 of the page size: 4 KiB
    put32be(&sig, 0)        // spare2
    put32be(&sig, 0)        // scatterOffset
    put32be(&sig, 0)        // teamOffset
    put32be(&sig, 0)        // spare3
    put64be(&sig, 0)        // codeLimit64
    put64be(&sig, 0)        // execSegBase: __TEXT's file offset
    put64be(&sig, text_size) // execSegLimit
    put64be(&sig, 1)        // CS_EXECSEG_MAIN_BINARY
    sig.extend(ident)
    sig.resize(20 + 88 + ident_pad, 0)
    for k in 0..nslots {
        lo := 4096 * k
        hi := min(lo + 4096, sig_off)
        d := sha256(file[lo..hi])
        sig.extend(d[..])
    }
    assert sig.len == sig_len, "macho: the size of the code signature"
    file.extend(sig.items())
    return (file.items(), "")
}
