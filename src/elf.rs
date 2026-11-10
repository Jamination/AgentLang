// Static ELF64 executable writer and linker.
use crate::ir::*;
use crate::x86::emit::RelocKind;
use crate::x86::Output;

const BASE: u64 = 0x400000;

fn align_up(x: u64, a: u64) -> u64 {
    (x + a - 1) / a * a
}

fn put16(v: &mut Vec<u8>, x: u16) {
    v.extend_from_slice(&x.to_le_bytes());
}
fn put32(v: &mut Vec<u8>, x: u32) {
    v.extend_from_slice(&x.to_le_bytes());
}
fn put64(v: &mut Vec<u8>, x: u64) {
    v.extend_from_slice(&x.to_le_bytes());
}

// Imported C functions that the emitted code refers to, in a stable order.
fn used_externs(m: &Module, out: &Output) -> Vec<usize> {
    let mut used = vec![false; m.externs.len()];
    let mut by_got: std::collections::HashMap<u32, usize> = std::collections::HashMap::new();
    for (i, x) in m.externs.iter().enumerate() {
        by_got.insert(x.got, i);
    }
    for c in &out.funcs {
        for r in &c.code.relocs {
            if let RelocKind::Abs32Global(g) = r.kind {
                if let Some(&i) = by_got.get(&g) {
                    used[i] = true;
                }
            }
        }
    }
    (0..m.externs.len()).filter(|i| used[*i]).collect()
}

// A program that calls no C function is a static executable. Otherwise the output is a
// dynamically linked executable: the system loader maps the libraries and fills the import slots.
pub fn link(m: &Module, out: &Output) -> Result<Vec<u8>, String> {
    let externs = used_externs(m, out);
    let dynamic = !externs.is_empty();
    for &x in &externs {
        let lib = &m.externs[x].lib;
        if lib.ends_with(".dll") || lib.ends_with(".dylib") || lib.contains(".framework") {
            return Err(format!(
                "`{}` is imported from `{}`, which is not a Linux library; this compiler emits x86-64 Linux executables (bindings for other platforms can be type-checked with `alc check`)",
                m.externs[x].name, lib
            ));
        }
    }
    let nph = if dynamic { 6u64 } else { 3u64 };
    let hdr_size = 64 + 56 * nph;
    let text_off = align_up(hdr_size, 16);
    // ---- text ----
    let mut text: Vec<u8> = Vec::new();
    // _start: mov rdi, rsp ; call entry ; ud2
    text.extend_from_slice(&[0x48, 0x89, 0xE7, 0xE8, 0, 0, 0, 0, 0x0F, 0x0B]);
    let mut func_addr: Vec<u64> = vec![0; m.funcs.len()];
    let mut func_size: Vec<u64> = vec![0; m.funcs.len()];
    let mut func_off: Vec<u64> = vec![0; m.funcs.len()];
    for c in &out.funcs {
        while text.len() % 16 != 0 {
            text.push(0xCC);
        }
        func_off[c.fid as usize] = text.len() as u64;
        func_addr[c.fid as usize] = BASE + text_off + text.len() as u64;
        func_size[c.fid as usize] = c.code.bytes.len() as u64;
        text.extend_from_slice(&c.code.bytes);
    }
    // ---- rodata ----
    let ro_off = align_up(text_off + text.len() as u64, 16);
    let mut rodata: Vec<u8> = Vec::new();
    let fpool_addr = BASE + ro_off;
    for &bits in &out.fpool {
        put64(&mut rodata, bits as u64);
        put64(&mut rodata, (bits >> 64) as u64);
    }
    let mut gaddr: Vec<u64> = vec![0; m.globals.len()];
    for (gi, g) in m.globals.iter().enumerate() {
        if g.readonly {
            let a = g.align.max(1) as usize;
            while rodata.len() % a != 0 {
                rodata.push(0);
            }
            gaddr[gi] = BASE + ro_off + rodata.len() as u64;
            match &g.data {
                Some(d) => rodata.extend_from_slice(d),
                None => rodata.resize(rodata.len() + g.size as usize, 0),
            }
            rodata.push(0); // keep distinct addresses for empty strings
        }
    }
    // ---- dynamic linking tables (read-only part) ----
    let mut interp_at = 0u64;
    let mut interp_len = 0u64;
    let (mut dynstr_at, mut dynstr_len, mut dynsym_at, mut hash_at, mut rela_at) = (0u64, 0u64, 0u64, 0u64, 0u64);
    let mut needed: Vec<u64> = Vec::new(); // offsets of library names in dynstr
    if dynamic {
        while rodata.len() % 8 != 0 {
            rodata.push(0);
        }
        let interp = b"/lib64/ld-linux-x86-64.so.2\0";
        interp_at = BASE + ro_off + rodata.len() as u64;
        interp_len = interp.len() as u64;
        rodata.extend_from_slice(interp);
        let mut dynstr: Vec<u8> = vec![0];
        let mut libs: Vec<&str> = Vec::new();
        for &x in &externs {
            if !libs.contains(&m.externs[x].lib.as_str()) {
                libs.push(&m.externs[x].lib);
            }
        }
        for l in &libs {
            needed.push(dynstr.len() as u64);
            dynstr.extend_from_slice(l.as_bytes());
            dynstr.push(0);
        }
        let mut dynsym: Vec<u8> = vec![0; 24];
        for &x in &externs {
            put32(&mut dynsym, dynstr.len() as u32);
            dynstr.extend_from_slice(m.externs[x].name.as_bytes());
            dynstr.push(0);
            dynsym.push(0x12); // STB_GLOBAL, STT_FUNC
            dynsym.push(0);
            put16(&mut dynsym, 0); // undefined
            put64(&mut dynsym, 0);
            put64(&mut dynsym, 0);
        }
        dynstr_at = BASE + ro_off + rodata.len() as u64;
        dynstr_len = dynstr.len() as u64;
        rodata.extend_from_slice(&dynstr);
        while rodata.len() % 8 != 0 {
            rodata.push(0);
        }
        dynsym_at = BASE + ro_off + rodata.len() as u64;
        rodata.extend_from_slice(&dynsym);
        // SysV hash table with one empty bucket: nothing is exported
        hash_at = BASE + ro_off + rodata.len() as u64;
        let nsym = externs.len() as u32 + 1;
        put32(&mut rodata, 1);
        put32(&mut rodata, nsym);
        put32(&mut rodata, 0);
        for _ in 0..nsym {
            put32(&mut rodata, 0);
        }
        while rodata.len() % 8 != 0 {
            rodata.push(0);
        }
        rela_at = BASE + ro_off + rodata.len() as u64;
        rodata.resize(rodata.len() + 24 * externs.len(), 0);
    }
    let ro_end = ro_off + rodata.len() as u64;
    // ---- data / bss ----
    let data_off = align_up(ro_end, 0x1000);
    let mut data: Vec<u8> = Vec::new();
    for (gi, g) in m.globals.iter().enumerate() {
        if !g.readonly && g.data.is_some() {
            let a = g.align.max(1) as usize;
            while data.len() % a != 0 {
                data.push(0);
            }
            gaddr[gi] = BASE + data_off + data.len() as u64;
            data.extend_from_slice(g.data.as_ref().unwrap());
        }
    }
    let mut dyn_at = 0u64;
    let mut dyn_len = 0u64;
    if dynamic {
        while data.len() % 8 != 0 {
            data.push(0);
        }
        dyn_at = BASE + data_off + data.len() as u64;
        let mut d: Vec<(u64, u64)> = Vec::new();
        for n in &needed {
            d.push((1, *n)); // DT_NEEDED
        }
        d.push((4, hash_at)); // DT_HASH
        d.push((5, dynstr_at)); // DT_STRTAB
        d.push((6, dynsym_at)); // DT_SYMTAB
        d.push((10, dynstr_len)); // DT_STRSZ
        d.push((11, 24)); // DT_SYMENT
        d.push((7, rela_at)); // DT_RELA
        d.push((8, 24 * externs.len() as u64)); // DT_RELASZ
        d.push((9, 24)); // DT_RELAENT
        d.push((30, 8)); // DT_FLAGS: BIND_NOW
        d.push((0x6fff_fffb, 1)); // DT_FLAGS_1: NOW
        d.push((21, 0)); // DT_DEBUG
        d.push((0, 0));
        for (tag, val) in d {
            put64(&mut data, tag);
            put64(&mut data, val);
        }
        dyn_len = BASE + data_off + data.len() as u64 - dyn_at;
        // one R_X86_64_GLOB_DAT relocation per import slot
        let base = (rela_at - (BASE + ro_off)) as usize;
        for (k, &x) in externs.iter().enumerate() {
            let mut r: Vec<u8> = Vec::new();
            put64(&mut r, gaddr[m.externs[x].got as usize]);
            put64(&mut r, ((k as u64 + 1) << 32) | 6);
            put64(&mut r, 0);
            rodata[base + 24 * k..base + 24 * k + 24].copy_from_slice(&r);
        }
    }
    while data.len() % 16 != 0 {
        data.push(0);
    }
    let bss_addr = BASE + data_off + data.len() as u64;
    let mut bss_size = 0u64;
    for (gi, g) in m.globals.iter().enumerate() {
        if !g.readonly && g.data.is_none() {
            let a = g.align.clamp(1, 64) as u64;
            let a = if g.size >= 64 { a.max(64) } else { a };
            bss_size = align_up(bss_size, a);
            gaddr[gi] = bss_addr + bss_size;
            bss_size += g.size.max(1);
        }
    }
    // ---- relocations ----
    let entry_addr = func_addr[m.entry as usize];
    let start_addr = BASE + text_off;
    let rel = (entry_addr as i64 - (start_addr as i64 + 8)) as i32;
    text[4..8].copy_from_slice(&rel.to_le_bytes());
    for c in &out.funcs {
        let fo = func_off[c.fid as usize] as usize;
        let fa = func_addr[c.fid as usize];
        for r in &c.code.relocs {
            let at = fo + r.off as usize;
            let val: i64 = match r.kind {
                RelocKind::Abs32Global(g) => gaddr[g as usize] as i64 + r.addend as i64,
                RelocKind::Abs32Func(f) => func_addr[f as usize] as i64 + r.addend as i64,
                RelocKind::Abs32FConst(i) => fpool_addr as i64 + 16 * i as i64 + r.addend as i64,
                RelocKind::Rel32Func(f) => func_addr[f as usize] as i64 - (fa as i64 + r.off as i64 + 4),
            };
            assert!(val >= i32::MIN as i64 && val <= i32::MAX as i64, "relocation out of range");
            text[at..at + 4].copy_from_slice(&(val as i32).to_le_bytes());
        }
    }
    let patch_data = |buf: &mut Vec<u8>, base_addr: u64, g: &Global, ga: u64| {
        for (off, t) in &g.relocs {
            let val = match t {
                RelocTarget::Global(tg, add) => (gaddr[*tg as usize] as i64 + add) as u64,
                RelocTarget::Func(f) => func_addr[*f as usize],
            };
            let at = (ga - base_addr) as usize + *off as usize;
            buf[at..at + 8].copy_from_slice(&val.to_le_bytes());
        }
    };
    for (gi, g) in m.globals.iter().enumerate() {
        if g.relocs.is_empty() {
            continue;
        }
        if g.readonly {
            patch_data(&mut rodata, BASE + ro_off, g, gaddr[gi]);
        } else if g.data.is_some() {
            patch_data(&mut data, BASE + data_off, g, gaddr[gi]);
        }
    }
    // ---- symbols ----
    let mut strtab: Vec<u8> = vec![0];
    let mut symtab: Vec<u8> = vec![0; 24];
    let mut nsyms = 1u32;
    for c in &out.funcs {
        let f = &m.funcs[c.fid as usize];
        let name_off = strtab.len() as u32;
        strtab.extend_from_slice(f.name.as_bytes());
        strtab.push(0);
        put32(&mut symtab, name_off);
        symtab.push(2); // STB_LOCAL, STT_FUNC
        symtab.push(0);
        put16(&mut symtab, 1);
        put64(&mut symtab, func_addr[c.fid as usize]);
        put64(&mut symtab, func_size[c.fid as usize]);
        nsyms += 1;
    }
    let shstr: &[u8] = b"\0.text\0.rodata\0.data\0.bss\0.symtab\0.strtab\0.shstrtab\0.dynstr\0.dynsym\0.dynamic\0";
    let name_of = |s: &str| -> u32 {
        let pat = format!("\0{}\0", s);
        (shstr.windows(pat.len()).position(|w| w == pat.as_bytes()).unwrap() + 1) as u32
    };
    // ---- file assembly ----
    let mut file: Vec<u8> = Vec::new();
    file.resize(text_off as usize, 0);
    file.extend_from_slice(&text);
    file.resize(ro_off as usize, 0);
    file.extend_from_slice(&rodata);
    file.resize(data_off as usize, 0);
    file.extend_from_slice(&data);
    let symtab_off = align_up(file.len() as u64, 8);
    file.resize(symtab_off as usize, 0);
    file.extend_from_slice(&symtab);
    let strtab_off = file.len() as u64;
    file.extend_from_slice(&strtab);
    let shstr_off = file.len() as u64;
    file.extend_from_slice(shstr);
    let sh_off = align_up(file.len() as u64, 8);
    file.resize(sh_off as usize, 0);
    let mut sh: Vec<u8> = Vec::new();
    let mut shdr = |name: u32, ty: u32, flags: u64, addr: u64, off: u64, size: u64, link: u32, info: u32, align: u64, entsize: u64| {
        put32(&mut sh, name);
        put32(&mut sh, ty);
        put64(&mut sh, flags);
        put64(&mut sh, addr);
        put64(&mut sh, off);
        put64(&mut sh, size);
        put32(&mut sh, link);
        put32(&mut sh, info);
        put64(&mut sh, align);
        put64(&mut sh, entsize);
    };
    shdr(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    shdr(name_of(".text"), 1, 6, BASE + text_off, text_off, text.len() as u64, 0, 0, 16, 0);
    shdr(name_of(".rodata"), 1, 2, BASE + ro_off, ro_off, rodata.len() as u64, 0, 0, 16, 0);
    shdr(name_of(".data"), 1, 3, BASE + data_off, data_off, data.len() as u64, 0, 0, 16, 0);
    shdr(name_of(".bss"), 8, 3, bss_addr, data_off + data.len() as u64, bss_size, 0, 0, 64, 0);
    shdr(name_of(".symtab"), 2, 0, 0, symtab_off, symtab.len() as u64, 6, nsyms, 8, 24);
    shdr(name_of(".strtab"), 3, 0, 0, strtab_off, strtab.len() as u64, 0, 0, 1, 0);
    shdr(name_of(".shstrtab"), 3, 0, 0, shstr_off, shstr.len() as u64, 0, 0, 1, 0);
    if dynamic {
        shdr(name_of(".dynstr"), 3, 2, dynstr_at, dynstr_at - BASE, dynstr_len, 0, 0, 1, 0);
        shdr(name_of(".dynsym"), 11, 2, dynsym_at, dynsym_at - BASE, 24 * (externs.len() as u64 + 1), 8, 1, 8, 24);
        shdr(name_of(".dynamic"), 6, 3, dyn_at, dyn_at - BASE, dyn_len, 8, 0, 8, 16);
    }
    file.extend_from_slice(&sh);
    // ELF header
    let mut h: Vec<u8> = Vec::new();
    h.extend_from_slice(&[0x7F, b'E', b'L', b'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    put16(&mut h, 2);
    put16(&mut h, 62);
    put32(&mut h, 1);
    put64(&mut h, start_addr);
    put64(&mut h, 64);
    put64(&mut h, sh_off);
    put32(&mut h, 0);
    put16(&mut h, 64);
    put16(&mut h, 56);
    put16(&mut h, nph as u16);
    put16(&mut h, 64);
    put16(&mut h, if dynamic { 11 } else { 8 });
    put16(&mut h, 7);
    // program headers
    let mut ph = |ty: u32, flags: u32, off: u64, vaddr: u64, filesz: u64, memsz: u64, align: u64| {
        put32(&mut h, ty);
        put32(&mut h, flags);
        put64(&mut h, off);
        put64(&mut h, vaddr);
        put64(&mut h, vaddr);
        put64(&mut h, filesz);
        put64(&mut h, memsz);
        put64(&mut h, align);
    };
    if dynamic {
        ph(6, 4, 64, BASE + 64, 56 * nph, 56 * nph, 8); // PT_PHDR
        ph(3, 4, interp_at - BASE, interp_at, interp_len, interp_len, 1); // PT_INTERP
    }
    ph(1, 5, 0, BASE, ro_end, ro_end, 0x1000);
    ph(1, 6, data_off, BASE + data_off, data.len() as u64, data.len() as u64 + bss_size, 0x1000);
    if dynamic {
        ph(2, 6, dyn_at - BASE, dyn_at, dyn_len, dyn_len, 8); // PT_DYNAMIC
    }
    ph(0x6474e551, 6, 0, 0, 0, 0, 16);
    file[..h.len()].copy_from_slice(&h);
    Ok(file)
}
