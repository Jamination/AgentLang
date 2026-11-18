// A structural check of the Mach-O executables of --target macos (no Mac here runs them).
//
//   alc run tests/macho/check.al -- [-v] [path/to/alc] [file.al | executable]...
//
// builds every program (`fn main`) of the files given (default: tests/run, tests/std and
// examples) with `--target macos`, by default and with -O0, and checks the file (a file that is
// not an .al file is checked as it is: a reference made by LLVM's linker, ld64.lld, passes too).
// What it checks, from the Mach-O definitions (<mach-o/loader.h>, <mach-o/fixup-chains.h>,
// <kern/cs_blobs.h>), not from src/macho.al:
//
// - the Mach header (arm64, MH_EXECUTE, PIE, DYLDLINK, TWOLEVEL, TLV descriptors when there are
//   some) and every load command: its size a multiple of 8, inside the commands;
// - the segments: __PAGEZERO first (4 GiB, no access, nothing of the file), __TEXT from file
//   offset 0 holding the header and the commands, __LINKEDIT last; addresses and file offsets
//   multiples of 16 KiB, file ranges inside the file and not overlapping, addresses rising;
//   every section inside its segment, at its alignment, its data where the segment puts it;
// - LC_MAIN inside __text, LC_LOAD_DYLINKER /usr/lib/dyld, LC_BUILD_VERSION for macOS, LC_UUID,
//   at least one LC_LOAD_DYLIB, the first libSystem;
// - the chained fixups: the header, the starts of every segment (16 KiB pages, pointer format
//   DYLD_CHAINED_PTR_64, the segment's offset, its page count), every chain walked to its end
//   inside its page; a bind names an import (the ordinal of a loaded library, a name in the
//   pool), a rebase an address inside the image; every slot of __got is a bind, the thunk of
//   every thread-local variable descriptor a bind of __tlv_bootstrap;
// - the symbol table against LC_DYSYMTAB (locals, defined externals, undefined ones with the
//   ordinal of a loaded library); the indirect symbols of __got: one per slot, the undefined
//   symbol the slot's bind imports;
// - the exports trie: __mh_execute_header at offset 0;
// - the code signature: at the end of the file and of __LINKEDIT; a SuperBlob with a
//   CodeDirectory (version 0x20400 or later, ad hoc, SHA-256, 4 KiB pages, codeLimit its own
//   offset, the executable segment __TEXT); every page hash recomputed with the block function
//   of bench/sha256.al (copied below: independent of src/sha256.al).
//
// Output: a line per problem, then `macho check: N executables, F fixups, H pages hashed,
// P problems`; the exit status is 0 without problems.
use std.os

// ---- SHA-256: the block function of bench/sha256.al; the padding is written here ----
priv const K = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

priv fn rotr(x: u32, n: u32) -> u32 {
    (x >> n) | (x << (32 - n))
}

priv fn sha256_block(st: []u32, p: []u8) {
    w: [64]u32
    for i in 0..16 {
        w[i] = (u32(p[4 * i]) << 24) | (u32(p[4 * i + 1]) << 16) | (u32(p[4 * i + 2]) << 8) | u32(p[4 * i + 3])
    }
    for i in 16..64 {
        s0 := rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
        s1 := rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] + s0 + w[i - 7] + s1
    }
    a := st[0]
    b := st[1]
    c := st[2]
    d := st[3]
    e := st[4]
    f := st[5]
    g := st[6]
    h := st[7]
    for i in 0..64 {
        s1 := rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        ch := (e & f) ^ (~e & g)
        t1 := h + s1 + ch + K[i] + w[i]
        s0 := rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        maj := (a & b) ^ (a & c) ^ (b & c)
        t2 := s0 + maj
        h = g
        g = f
        f = e
        e = d + t1
        d = c
        c = b
        b = a
        a = t1 + t2
    }
    st[0] += a
    st[1] += b
    st[2] += c
    st[3] += d
    st[4] += e
    st[5] += f
    st[6] += g
    st[7] += h
}

// the digest of any message: whole blocks, then the rest padded (0x80, zeros, the bit length)
priv fn digest(data: []u8) -> str {
    st := [8]u32{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}
    n := len(data)
    whole := n - n % 64
    for off in 0..whole by 64 {
        sha256_block(st[..], data[off..off + 64])
    }
    last: [128]u8
    for i in 0..n - whole {
        last[i] = data[whole + i]
    }
    last[n - whole] = 0x80
    end := if n - whole < 56 { 64 } else { 128 }
    bits := u64(n) * 8
    for i in 0..8 {
        last[end - 1 - i] = u8(bits >> u64(8 * i))
    }
    for off in 0..end by 64 {
        sha256_block(st[..], last[off..off + 64])
    }
    out := vec[u8]()
    for i in 0..8 {
        for k in 0..4 {
            out.push(u8(st[i] >> u32(24 - 8 * k)))
        }
    }
    return out.items()
}

// ---- reading ----
priv fn u8_at(b: str, at: i64) -> i64 {
    return if at >= 0 && at < len(b) { i64(b[at]) } else { 0 }
}

priv fn u16_at(b: str, at: i64) -> i64 {
    return u8_at(b, at) | u8_at(b, at + 1) << 8
}

priv fn u32_at(b: str, at: i64) -> i64 {
    return u16_at(b, at) | u16_at(b, at + 2) << 16
}

priv fn u64_at(b: str, at: i64) -> i64 {
    return u32_at(b, at) | u32_at(b, at + 4) << 32
}

priv fn be32(b: str, at: i64) -> i64 {
    return u8_at(b, at) << 24 | u8_at(b, at + 1) << 16 | u8_at(b, at + 2) << 8 | u8_at(b, at + 3)
}

priv fn be64(b: str, at: i64) -> i64 {
    return be32(b, at) << 32 | be32(b, at + 4)
}

priv fn name16(b: str, at: i64) -> str {
    e := at
    while e < at + 16 && u8_at(b, e) != 0 {
        e += 1
    }
    return b[at..e]
}

priv fn cstr_at(b: str, at: i64, end: i64) -> str {
    e := at
    while e < end && e < len(b) && b[e] != 0 {
        e += 1
    }
    return b[min(at, e)..e]
}

priv struct Seg {
    name: str
    vmaddr: i64
    vmsize: i64
    fileoff: i64
    filesize: i64
    prot: i64
}

priv struct Sec {
    seg: str
    name: str
    addr: i64
    size: i64
    off: i64
    align: i64
    ty: i64
    r1: i64
}

priv struct Totals {
    files: i64
    fixups: i64
    pages: i64
}

priv const PG = 0x4000

priv fn check(name: str, b: str, p: *Vec[str], t: *Totals) {
    probs := vec[str]()
    fn bad(probs: *Vec[str], s: str) {
        probs.push(s)
    }
    if len(b) < 32 || u32_at(b, 0) != 0xfeedfacf {
        p.push(fmt(name, ": not a 64-bit Mach-O file"))
        return
    }
    if u32_at(b, 4) != 0x0100000c || u32_at(b, 12) != 2 {
        bad(&probs, fmt("cputype ", hex(u64(u32_at(b, 4)), 8), ", filetype ", u32_at(b, 12), ": expected an arm64 MH_EXECUTE"))
    }
    ncmds := u32_at(b, 16)
    sizeofcmds := u32_at(b, 20)
    flags := u32_at(b, 24)
    if flags & (0x4 | 0x80 | 0x200000) != (0x4 | 0x80 | 0x200000) {
        bad(&probs, fmt("flags ", hex(u64(flags), 8), " lack DYLDLINK, TWOLEVEL or PIE"))
    }
    segs := vec[Seg]()
    secs := vec[Sec]()
    dylibs := vec[str]()
    entryoff := -1
    fix_off := -1
    fix_size := 0
    exp_off := -1
    exp_size := 0
    sym_off := 0
    nsyms := 0
    str_off := 0
    str_size := 0
    dysym := vec[i64]()
    sig_off := -1
    sig_size := 0
    has_uuid := false
    dylinker := ""
    platform := 0
    at := 32
    for k in 0..ncmds {
        cmd := u32_at(b, at)
        size := u32_at(b, at + 4)
        if size < 8 || size % 8 != 0 || at + size > 32 + sizeofcmds {
            bad(&probs, fmt("load command ", k, " (", hex(u64(cmd), 8), "): size ", size))
            break
        }
        match cmd {
            0x19 => {
                s := Seg{name: name16(b, at + 8), vmaddr: u64_at(b, at + 24), vmsize: u64_at(b, at + 32),
                    fileoff: u64_at(b, at + 40), filesize: u64_at(b, at + 48), prot: u32_at(b, at + 60)}
                nsect := u32_at(b, at + 64)
                if size != 72 + 80 * nsect {
                    bad(&probs, fmt("segment ", s.name, ": command size ", size, " for ", nsect, " sections"))
                }
                for j in 0..nsect {
                    q := at + 72 + 80 * j
                    secs.push(Sec{name: name16(b, q), seg: name16(b, q + 16), addr: u64_at(b, q + 32), size: u64_at(b, q + 40),
                        off: u32_at(b, q + 48), align: u32_at(b, q + 52), ty: u32_at(b, q + 64) & 0xFF, r1: u32_at(b, q + 68)})
                }
                segs.push(s)
            }
            0x80000034 => {
                fix_off = u32_at(b, at + 8)
                fix_size = u32_at(b, at + 12)
            }
            0x80000033 => {
                exp_off = u32_at(b, at + 8)
                exp_size = u32_at(b, at + 12)
            }
            0x2 => {
                sym_off = u32_at(b, at + 8)
                nsyms = u32_at(b, at + 12)
                str_off = u32_at(b, at + 16)
                str_size = u32_at(b, at + 20)
            }
            0xb => {
                for j in 0..18 {
                    dysym.push(u32_at(b, at + 8 + 4 * j))
                }
            }
            0xe => dylinker = cstr_at(b, at + u32_at(b, at + 8), at + size)
            0x1b => has_uuid = true
            0x32 => platform = u32_at(b, at + 8)
            0x80000028 => entryoff = u64_at(b, at + 8)
            0xc => dylibs.push(cstr_at(b, at + u32_at(b, at + 8), at + size))
            0x1d => {
                sig_off = u32_at(b, at + 8)
                sig_size = u32_at(b, at + 12)
            }
            _ => {}
        }
        at += size
    }
    if at != 32 + sizeofcmds {
        bad(&probs, "the load commands do not fill sizeofcmds")
    }
    // ---- segments ----
    if segs.len < 3 || segs[0].name != "__PAGEZERO" || segs[0].vmaddr != 0 || segs[0].vmsize != 1 << 32 || segs[0].filesize != 0 || segs[0].prot != 0 {
        bad(&probs, "__PAGEZERO is not the first segment, 4 GiB without access")
        p.extend(prefix(name, probs).items())
        return
    }
    text := segs[1]
    if text.name != "__TEXT" || text.fileoff != 0 || text.filesize < 32 + sizeofcmds || text.prot != 5 {
        bad(&probs, "__TEXT does not start the file with the header (r-x)")
    }
    le := segs.last()
    if le.name != "__LINKEDIT" {
        bad(&probs, "__LINKEDIT is not the last segment")
    }
    image_end := 0
    for k in 1..segs.len {
        s := segs[k]
        if s.vmaddr % PG != 0 || s.fileoff % PG != 0 || s.filesize > s.vmsize || s.fileoff + s.filesize > len(b) {
            bad(&probs, fmt("segment ", s.name, ": address ", hex(u64(s.vmaddr), 9), ", offset ", s.fileoff, ", sizes ", s.filesize, "/", s.vmsize))
        }
        if k + 1 < segs.len && s.name != "__LINKEDIT" {
            n := segs[k + 1]
            if n.vmaddr < s.vmaddr + s.vmsize || n.fileoff < s.fileoff + s.filesize || s.vmsize % PG != 0 {
                bad(&probs, fmt("segments ", s.name, " and ", n.name, " overlap or are not whole pages"))
            }
        }
        image_end = max(image_end, s.vmaddr + s.vmsize)
    }
    for c in secs {
        si := -1
        for k, s in segs {
            if s.name == c.seg {
                si = k
            }
        }
        if si < 0 {
            bad(&probs, fmt("section ", c.seg, ",", c.name, " has no segment"))
            continue
        }
        s := segs[si]
        zero := c.ty == 1 || c.ty == 0x12
        if c.addr < s.vmaddr || c.addr + c.size > s.vmaddr + s.vmsize || c.addr % (1 << c.align) != 0 {
            bad(&probs, fmt("section ", c.seg, ",", c.name, " outside its segment or misaligned"))
        }
        if !zero && c.size > 0 && c.off != s.fileoff + (c.addr - s.vmaddr) {
            bad(&probs, fmt("section ", c.seg, ",", c.name, ": file offset ", c.off, " is not where its segment puts it"))
        }
        if !zero && c.addr + c.size > s.vmaddr + s.filesize {
            bad(&probs, fmt("section ", c.seg, ",", c.name, " has data beyond the file part of its segment"))
        }
    }
    file_of := fn(segs: *Vec[Seg], a: i64) -> i64 {
        for s in segs {
            if s.filesize > 0 && a >= s.vmaddr && a < s.vmaddr + s.filesize {
                return s.fileoff + (a - s.vmaddr)
            }
        }
        return -1
    }
    // ---- entry, dyld, platform, libraries ----
    text_sec := -1
    for k, c in secs {
        if c.seg == "__TEXT" && c.name == "__text" {
            text_sec = k
        }
    }
    if text_sec < 0 || entryoff < secs[text_sec].off || entryoff >= secs[text_sec].off + secs[text_sec].size {
        bad(&probs, "LC_MAIN's entry is not inside __text")
    }
    if dylinker != "/usr/lib/dyld" || platform != 1 || !has_uuid {
        bad(&probs, fmt("LC_LOAD_DYLINKER `", dylinker, "`, platform ", platform, ", UUID ", has_uuid))
    }
    if dylibs.is_empty() || dylibs[0] != "/usr/lib/libSystem.B.dylib" {
        bad(&probs, "the first LC_LOAD_DYLIB is not /usr/lib/libSystem.B.dylib")
    }
    // ---- chained fixups ----
    imports := vec[str]()
    slot_bind := map[i64, str]()
    if fix_off < 0 || fix_off + fix_size > le.fileoff + le.filesize || fix_off < le.fileoff {
        bad(&probs, "no LC_DYLD_CHAINED_FIXUPS inside __LINKEDIT")
    } else {
        f := fix_off
        starts := u32_at(b, f + 4)
        imp := u32_at(b, f + 8)
        syms := u32_at(b, f + 12)
        nimp := u32_at(b, f + 16)
        if u32_at(b, f) != 0 || u32_at(b, f + 20) != 1 || u32_at(b, f + 24) != 0 || imp + 4 * nimp > syms || syms > fix_size {
            bad(&probs, "the chained fixups header (version 0, DYLD_CHAINED_IMPORT, uncompressed names, offsets)")
        }
        for k in 0..nimp {
            v := u32_at(b, f + imp + 4 * k)
            lib := v & 0xFF
            nm := cstr_at(b, f + syms + (v >> 9), f + fix_size)
            if lib < 1 || lib > dylibs.len || len(nm) == 0 || nm[0] != '_' {
                bad(&probs, fmt("import ", k, ": library ", lib, ", name `", nm, "`"))
            }
            imports.push(nm)
        }
        si := f + starts
        if u32_at(b, si) != segs.len {
            bad(&probs, fmt("the fixups name ", u32_at(b, si), " segments, the file has ", segs.len))
        } else {
            for k in 0..segs.len {
                o := u32_at(b, si + 4 + 4 * k)
                if o == 0 {
                    continue
                }
                s := segs[k]
                q := si + o
                npages := u16_at(b, q + 20)
                if u16_at(b, q + 4) != PG || u16_at(b, q + 6) != 2 || u64_at(b, q + 8) != s.vmaddr - text.vmaddr || npages != (s.vmsize + PG - 1) / PG || u32_at(b, q) < 22 + 2 * npages {
                    bad(&probs, fmt("the fixup starts of ", s.name, " (page size, pointer format DYLD_CHAINED_PTR_64, offset, page count)"))
                    continue
                }
                for pg in 0..npages {
                    st := u16_at(b, q + 22 + 2 * pg)
                    if st == 0xFFFF {
                        continue
                    }
                    off := pg * PG + st
                    steps := 0
                    loop {
                        a := s.vmaddr + off
                        fo := file_of(&segs, a)
                        if fo < 0 || off % 4 != 0 || (off / PG) != pg || steps > 4096 {
                            bad(&probs, fmt("a fixup chain of ", s.name, " leaves its page or the file at ", hex(u64(a), 9)))
                            break
                        }
                        v := u64_at(b, fo)
                        t.fixups += 1
                        steps += 1
                        if v < 0 {
                            ord := v & 0xFFFFFF
                            if ord >= imports.len || (v >> 24) & 0xFF != 0 {
                                bad(&probs, fmt("a bind at ", hex(u64(a), 9), " names import ", ord, " of ", imports.len))
                            } else {
                                slot_bind.set(a, imports[ord])
                            }
                        } else {
                            target := v & 0xF_FFFF_FFFF
                            if target < text.vmaddr || target >= image_end || (v >> 36) & 0xFF != 0 {
                                bad(&probs, fmt("a rebase at ", hex(u64(a), 9), " to ", hex(u64(target), 9), ", outside the image"))
                            }
                        }
                        next := (v >> 51) & 0xFFF
                        if next == 0 {
                            break
                        }
                        off += 4 * next
                    }
                }
            }
        }
    }
    // every slot of __got a bind; the thunk of every thread-local variable descriptor a bind of
    // __tlv_bootstrap
    got_names := vec[str]()
    got_r1 := 0
    for c in secs {
        if c.ty == 6 {
            got_r1 = c.r1
            for a in c.addr..c.addr + c.size by 8 {
                nm, ok := slot_bind.get(a)
                if !ok {
                    bad(&probs, fmt("the __got slot at ", hex(u64(a), 9), " is not bound"))
                }
                got_names.push(nm)
            }
        }
        if c.ty == 0x13 {
            if flags & 0x800000 == 0 {
                bad(&probs, "thread-local variables without MH_HAS_TLV_DESCRIPTORS")
            }
            for a in c.addr..c.addr + c.size by 24 {
                if slot_bind.get_or(a, "") != "__tlv_bootstrap" {
                    bad(&probs, fmt("the descriptor at ", hex(u64(a), 9), " is not bound to __tlv_bootstrap"))
                }
            }
        }
    }
    // ---- symbols ----
    if dysym.len == 18 && nsyms > 0 {
        il := dysym[0]
        nl := dysym[1]
        ie := dysym[2]
        ne := dysym[3]
        iu := dysym[4]
        nu := dysym[5]
        if il != 0 || ie != il + nl || iu != ie + ne || iu + nu != nsyms {
            bad(&probs, "LC_DYSYMTAB's groups do not cover the symbol table in order")
        }
        if sym_off + 16 * nsyms > len(b) || str_off + str_size > len(b) {
            bad(&probs, "the symbol or string table is outside the file")
        } else {
            for k in 0..nsyms {
                e := sym_off + 16 * k
                ty := u8_at(b, e + 4)
                ext := ty & 1 == 1
                undef := ty & 0x0E == 0
                group := if k < ie { 0 } else if k < iu { 1 } else { 2 }
                ok := match group {
                    0 => !ext && !undef
                    1 => ext && !undef
                    _ => ext && undef && (u16_at(b, e + 6) >> 8) >= 1 && (u16_at(b, e + 6) >> 8) <= dylibs.len
                }
                if !ok {
                    bad(&probs, fmt("symbol ", k, " (type ", hex(u64(ty), 2), ") does not belong to its LC_DYSYMTAB group"))
                    break
                }
            }
            // the indirect symbols of __got
            ind := dysym[12]
            nind := dysym[13]
            for j, gn in got_names {
                if got_r1 + j >= nind {
                    bad(&probs, "fewer indirect symbols than __got slots")
                    break
                }
                si := u32_at(b, ind + 4 * (got_r1 + j))
                nm := cstr_at(b, str_off + u32_at(b, sym_off + 16 * si), str_off + str_size)
                if si < iu || nm != gn {
                    bad(&probs, fmt("indirect symbol ", j, " of __got is `", nm, "`, its bind `", gn, "`"))
                }
            }
        }
    } else {
        bad(&probs, "no LC_DYSYMTAB or no symbols")
    }
    // ---- exports trie: __mh_execute_header at 0 (a walk along the edges that spell it) ----
    {
        want := "__mh_execute_header"
        node := exp_off
        matched := 0
        found := false
        for _ in 0..64 {
            if node < exp_off || node >= exp_off + exp_size {
                break
            }
            // (terminal size, uleb; then the children)
            q := node
            term := u8_at(b, q)
            q += 1
            if matched == len(want) {
                found = term > 0 && u8_at(b, q) == 0 && u8_at(b, q + 1) == 0
                break
            }
            q += term
            nchild := u8_at(b, q)
            q += 1
            next := -1
            for _ in 0..nchild {
                edge := cstr_at(b, q, exp_off + exp_size)
                q += len(edge) + 1
                o := 0
                sh := 0
                loop {
                    c := u8_at(b, q)
                    q += 1
                    o |= (c & 0x7F) << sh
                    sh += 7
                    if c < 0x80 {
                        break
                    }
                }
                if starts_with(want[matched..], edge) && len(edge) > 0 {
                    next = exp_off + o
                    matched += len(edge)
                    break
                }
            }
            node = next
        }
        if !found {
            bad(&probs, "the exports trie lacks __mh_execute_header at offset 0")
        }
    }
    // ---- code signature ----
    if sig_off < 0 || sig_off % 16 != 0 || sig_off + sig_size != len(b) || sig_off + sig_size != le.fileoff + le.filesize {
        bad(&probs, "the code signature is not 16-byte aligned at the end of the file and of __LINKEDIT")
    } else if be32(b, sig_off) != 0xfade0cc0 || be32(b, sig_off + 4) > sig_size {
        bad(&probs, "no SuperBlob at the code signature")
    } else {
        cd := -1
        for k in 0..be32(b, sig_off + 8) {
            if be32(b, sig_off + 12 + 8 * k) == 0 {
                cd = sig_off + be32(b, sig_off + 16 + 8 * k)
            }
        }
        if cd < 0 || be32(b, cd) != 0xfade0c02 {
            bad(&probs, "no CodeDirectory in the SuperBlob")
        } else {
            version := be32(b, cd + 8)
            cflags := be32(b, cd + 12)
            hash_off := be32(b, cd + 16)
            nspecial := be32(b, cd + 24)
            nslots := be32(b, cd + 28)
            limit := be32(b, cd + 32)
            if version < 0x20400 || cflags & 2 == 0 || u8_at(b, cd + 36) != 32 || u8_at(b, cd + 37) != 2 || u8_at(b, cd + 39) != 12 {
                bad(&probs, "the CodeDirectory is not version 0x20400+, ad hoc, SHA-256 of 4 KiB pages")
            }
            if limit != sig_off || nslots != (limit + 4095) / 4096 || nspecial != 0 {
                bad(&probs, fmt("codeLimit ", limit, ", ", nslots, " code slots for the signature at ", sig_off))
            }
            if be64(b, cd + 64) != text.fileoff || be64(b, cd + 72) != text.filesize || be64(b, cd + 80) & 1 == 0 {
                bad(&probs, "the executable segment of the CodeDirectory is not __TEXT of the main binary")
            }
            for k in 0..nslots {
                lo := 4096 * k
                hi := min(lo + 4096, limit)
                t.pages += 1
                if digest(b[lo..hi]) != b[cd + hash_off + 32 * k..cd + hash_off + 32 * k + 32] {
                    bad(&probs, fmt("the hash of page ", k, " differs from the page"))
                    break
                }
            }
        }
    }
    t.files += 1
    p.extend(prefix(name, probs).items())
}

priv fn prefix(name: str, probs: Vec[str]) -> Vec[str] {
    out := vec[str]()
    for s in probs {
        out.push(fmt(name, ": ", s))
    }
    return out
}

fn main() -> i64 {
    a := args()[1..]
    verbose := false
    if len(a) > 0 && a[0] == "-v" {
        verbose = true
        a = a[1..]
    }
    alc := if TARGET_OS == Windows { "build/alc.exe" } else { "./build/alc" }
    if len(a) > 0 && (ends_with(a[0], "alc") || ends_with(a[0], "alc.exe")) {
        alc = a[0]
        a = a[1..]
    }
    inputs := vec_of(a)
    if inputs.is_empty() {
        inputs = vec_of([]str{"tests/run", "tests/std", "examples"})
    }
    files := vec[str]()
    for x in inputs {
        if !is_dir(x) {
            files.push(x)
            continue
        }
        names := list_dir(x)
        sort(names)
        for nm in names {
            if !ends_with(nm, ".al") {
                continue
            }
            src := path_join(x, nm)
            text, _ := read_file(src)
            if find(text, "fn main") >= 0 {
                files.push(src)
            }
        }
    }
    tmp := path_join(if TARGET_OS == Windows { env_get("TEMP").0 } else { "/tmp" }, fmt("macho_check.", process_id()))
    make_dir(tmp)
    probs := vec[str]()
    t := Totals{}
    for src in files {
        if !ends_with(src, ".al") {
            bytes, ok := read_file(src)
            if ok {
                check(src, bytes, &probs, &t)
            } else {
                probs.push(fmt(src, ": cannot read it"))
            }
            continue
        }
        for mode in []str{"", "-O0"} {
            out := path_join(tmp, "prog")
            cmd := vec_of([]str{alc, "build", "--target", "macos", src, "-o", out})
            if mode != "" {
                cmd.push(mode)
            }
            // (programs that do not build for this target are the conformance suite's matter)
            if run_capture_all(cmd.items()).1 != 0 {
                continue
            }
            bytes, ok := read_file(out)
            if !ok {
                continue
            }
            before := probs.len
            check(fmt(src, if mode == "" { "" } else { " -O0" }), bytes, &probs, &t)
            if verbose && probs.len == before {
                print(fmt("ok   ", src, " ", mode))
            }
        }
    }
    remove_file(path_join(tmp, "prog"))
    remove_dir(tmp)
    for s in probs {
        print(s)
    }
    print(fmt("macho check: ", t.files, " executables, ", t.fixups, " fixups, ", t.pages, " pages hashed, ", probs.len, " problems"))
    return if probs.is_empty() { 0 } else { 1 }
}
