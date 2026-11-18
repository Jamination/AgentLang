// alc build -g for Windows (win_pdb.flags): the program reads its own executable and the PDB
// next to it and checks them: the CodeView entry of the debug directory (RSDS: GUID, age, the
// path of the PDB), the MSF container, the PDB info stream (the same GUID and age, the
// /names stream), DBI (the module of this file, its stream), the module's symbols (probe as
// S_GPROC32 with its variables, one in an S_BLOCK32) and lines, the publics and the types.
// The same at -O0 and optimised: probe is never inlined and its variables have their address
// taken.

struct Pair {
    x: i64
    y: i64
}

noinline fn touch(p: *i64) -> i64 {
    return *p + 1
}

noinline fn probe(a: i64) -> i64 {
    k := a * 2
    t := touch(&k)
    if t > 0 {
        inner := t + 3
        t += touch(&inner)
    }
    p := Pair{x: k, y: t}
    return t + touch(&p.y)
}

const PROBE_FIRST = 18
const PROBE_LAST = 27

priv fn u16at(b: str, o: i64) -> i64 {
    return i64(b[o]) | i64(b[o + 1]) << 8
}

priv fn u32at(b: str, o: i64) -> i64 {
    return u16at(b, o) | u16at(b, o + 2) << 16
}

priv fn cstr_at(b: str, o: i64) -> str {
    e := o
    while e < len(b) && b[e] != 0 {
        e += 1
    }
    return b[o..e]
}

// the streams of an MSF file
priv fn streams(f: str) -> Vec[str] {
    assert starts_with(f, "Microsoft C/C++ MSF 7.00\r\n\x1aDS"), "MSF magic"
    bs := u32at(f, 32)
    nblocks := u32at(f, 40)
    dir_size := u32at(f, 44)
    map := u32at(f, 52)
    assert bs == 4096 && nblocks * bs == len(f), "MSF size"
    dir := vec[u8]()
    for i in 0..(dir_size + bs - 1) / bs {
        b := u32at(f, map * bs + 4 * i)
        dir.extend(f[b * bs..b * bs + bs])
    }
    d := dir.items()
    n := u32at(d, 0)
    out := vec[str]()
    at := 4 + 4 * n
    for s in 0..n {
        size := u32at(d, 4 + 4 * s)
        if size == 0xFFFFFFFF {
            size = 0
        }
        data := vec[u8]()
        for i in 0..(size + bs - 1) / bs {
            b := u32at(d, at)
            at += 4
            data.extend(f[b * bs..b * bs + min(bs, size - i * bs)])
        }
        out.push(data.items())
    }
    return out
}

// the records of a symbol or type stream from `at` to `end`: (offset, kind)
priv fn records(s: str, at0: i64, end: i64) -> Vec[(i64, i64)] {
    out := vec[(i64, i64)]()
    at := at0
    while at + 4 <= end {
        n := u16at(s, at)
        out.push((at, u16at(s, at + 2)))
        at += 2 + n
    }
    return out
}

fn main() {
    probe(1)
    exe, ok := read_file(args()[0])
    if !ok {
        exe, ok = read_file(fmt(args()[0], ".exe"))
    }
    assert ok
    // the debug directory (data directory 6) and its RSDS record
    pe := u32at(exe, 60)
    opt := pe + 24
    nsec := u16at(exe, pe + 6)
    sh := opt + u16at(exe, pe + 20)
    fn file_off(exe: str, sh: i64, nsec: i64, rva: i64) -> i64 {
        for i in 0..nsec {
            h := sh + 40 * i
            va := u32at(exe, h + 12)
            if rva >= va && rva < va + u32at(exe, h + 8) {
                return rva - va + u32at(exe, h + 20)
            }
        }
        return -1
    }
    dd := file_off(exe, sh, nsec, u32at(exe, opt + 112 + 8 * 6))
    print("debug directory:", dd > 0 && u32at(exe, opt + 112 + 8 * 6 + 4) == 28, "codeview", u32at(exe, dd + 12) == 2)
    rs := u32at(exe, dd + 24)
    assert rs == file_off(exe, sh, nsec, u32at(exe, dd + 20)), "the RSDS record's file offset"
    guid := exe[rs + 4..rs + 20]
    path := cstr_at(exe, rs + 24)
    stem := args()[0]
    if ends_with(to_lower(stem), ".exe") {
        stem = stem[..len(stem) - 4]
    }
    k := len(stem)
    while k > 0 && stem[k - 1] != 0x2F && stem[k - 1] != 0x5C {
        k -= 1
    }
    print("rsds:", exe[rs..rs + 4] == "RSDS", "age", u32at(exe, rs + 20), "the executable's path with .pdb", ends_with(to_lower(path), to_lower(fmt(stem[k..], ".pdb"))))
    pdb, pok := read_file(path)
    assert pok, fmt("cannot read ", path)
    st := streams(pdb)
    // the PDB info stream
    info := st[1]
    print("info: version", u32at(info, 0), "age", u32at(info, 8), "same guid", info[12..28] == guid, "/names", find(info, "/names") > 0)
    // DBI: the modules
    dbi := st[3]
    print("dbi:", u32at(dbi, 0) == 0xFFFFFFFF, u32at(dbi, 4), "machine", hex(u64(u16at(dbi, 58)), 4))
    modsize := u32at(dbi, 24)
    at := 64
    mstream := -1
    symsize := 0
    c13size := 0
    nmods := 0
    while at < 64 + modsize {
        name := cstr_at(dbi, at + 64)
        obj := cstr_at(dbi, at + 64 + len(name) + 1)
        if ends_with(name, "win_pdb.al") {
            mstream = u16at(dbi, at + 34)
            symsize = u32at(dbi, at + 36)
            c13size = u32at(dbi, at + 44)
        }
        nmods += 1
        at = (at + 64 + len(name) + 1 + len(obj) + 1 + 3) / 4 * 4
    }
    print("modules:", nmods >= 3, "this file's", mstream > 0)
    // the module's symbols: probe, its frame, its variables, a block
    ms := st[mstream]
    // (the variables in order, and the depth of the S_BLOCK32s each is in)
    names := vec[str]()
    frame := false
    depth := 0
    dk := -1
    dinner := -1
    proc_off := -1
    proc_end := 0
    for r in records(ms, 4, symsize) {
        o, k := r
        if k == 0x1110 && cstr_at(ms, o + 39) == "probe" {
            proc_off = o
            proc_end = u32at(ms, o + 8)
        }
        if proc_off >= 0 && o > proc_off && o < proc_end {
            match k {
                0x1012 => frame = true
                0x1103 => depth += 1
                0x0006 => depth -= 1
                0x1111 => {
                    n := cstr_at(ms, o + 14)
                    if n == "k" || n == "inner" || n == "p" {
                        names.push(n)
                    }
                    if n == "k" {
                        dk = depth
                    } else if n == "inner" {
                        dinner = depth
                    }
                }
                _ => {}
            }
        }
    }
    print("probe:", proc_off >= 0, "S_FRAMEPROC", frame, "variables", join(names.items(), " "), "inner in a block inside k's", dinner > dk && dk >= 0)
    // the debug start after the prologue; the parameter a: S_LOCAL (a parameter) whose first
    // range (S_DEFRANGE_REGISTER) starts at probe's first instruction
    {
        start := u32at(ms, proc_off + 32)
        dstart := u32at(ms, proc_off + 20)
        local := false
        at_entry := false
        seen := false
        for r in records(ms, 4, symsize) {
            o, k := r
            if o <= proc_off || o >= proc_end {
                continue
            }
            if k == 0x113E {
                local = cstr_at(ms, o + 10) == "a" && u16at(ms, o + 8) & 1 == 1
                seen = false
            } else if local && !seen && (k == 0x1141 || k == 0x1142) {
                seen = true
                at_entry = k == 0x1141 && u32at(ms, o + 8) == start
            }
            if local && seen {
                break
            }
        }
        print("debug start after the prologue", dstart > 0, "parameter a: S_LOCAL", local, "in a register at the entry", at_entry)
    }
    // the lines of probe: in its source lines, the file in /names
    strtab := st[11]
    lines_ok := false
    file_ok := false
    chk := ""
    o := symsize
    while o < symsize + c13size {
        kind := u32at(ms, o)
        n := u32at(ms, o + 4)
        if kind == 0xF4 {
            chk = ms[o + 8..o + 8 + n]
        }
        o += 8 + n
    }
    o = symsize
    while o < symsize + c13size {
        kind := u32at(ms, o)
        n := u32at(ms, o + 4)
        if kind == 0xF2 && proc_off >= 0 && u32at(ms, o + 8) == u32at(ms, proc_off + 32) {
            // one block of probe's own lines
            fileoff := u32at(ms, o + 20)
            nl := u32at(ms, o + 24)
            lines_ok = nl > 0
            for i in 0..nl {
                line := u32at(ms, o + 32 + 8 * i + 4) & 0xFFFFFF
                lines_ok = lines_ok && line >= PROBE_FIRST && line <= PROBE_LAST
            }
            file_ok = ends_with(cstr_at(strtab, 12 + u32at(chk, fileoff)), "win_pdb.al")
        }
        o += 8 + n
    }
    print("lines:", lines_ok, "file", file_ok)
    // the publics: probe among the S_PUB32 records
    syms := st[u16at(dbi, 20)]
    pub := false
    for r in records(syms, 0, len(syms)) {
        if r.1 == 0x110e && cstr_at(syms, r.0 + 14) == "probe" {
            pub = true
        }
    }
    print("public probe:", pub)
    // the types: Pair, a structure of 16 bytes
    tpi := st[2]
    pair := false
    for r in records(tpi, 56, len(tpi)) {
        if r.1 == 0x1505 && u16at(tpi, r.0 + 6) & 0x80 == 0 && cstr_at(tpi, r.0 + 22) == "Pair" {
            pair = u16at(tpi, r.0 + 20) == 16 && u16at(tpi, r.0 + 4) == 2
        }
    }
    print("type Pair: 2 members, 16 bytes", pair)
    print("section headers:", len(st[10]) == 40 * nsec)
}
