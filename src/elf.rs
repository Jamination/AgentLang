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

pub fn link(m: &Module, out: &Output) -> Vec<u8> {
    let nph = 3u64;
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
    let shstr: &[u8] = b"\0.text\0.rodata\0.data\0.bss\0.symtab\0.strtab\0.shstrtab\0";
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
    put16(&mut h, 8);
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
    ph(1, 5, 0, BASE, ro_end, ro_end, 0x1000);
    ph(1, 6, data_off, BASE + data_off, data.len() as u64, data.len() as u64 + bss_size, 0x1000);
    ph(0x6474e551, 6, 0, 0, 0, 0, 16);
    file[..h.len()].copy_from_slice(&h);
    file
}
