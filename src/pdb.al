// The PDB file of a Windows executable built with -g (see src/debug.al): what Visual Studio,
// WinDbg / cdb and the Windows profilers read, next to the executable (`prog.exe` -> `prog.pdb`),
// found through the CodeView entry (RSDS) of the executable's debug directory (pe.al), whose
// GUID and age the PDB repeats.
//
// The container is an MSF file (blocks of 4096 bytes, two free block maps, a stream
// directory); its streams follow LLVM's PDB writer, the documented reference
// (llvm.org/docs/PDB):
//   1 PDB info: version, signature, age, GUID, the named streams ("/names")
//   2 TPI: the types of the variables and functions (CodeView type records), 3 DBI: the modules,
//   section contributions, section map, files, optional headers (the section headers stream),
//   4 IPI (empty), then the hash streams of TPI and IPI, the global and public symbol hash
//   streams and the symbol records they index, the section headers, one stream per module and
//   the string table "/names".
// One module per source file, holding the functions declared in it: an S_GPROC32 per function
// with an S_FRAMEPROC and its parameters and variables (S_REGREL32: offset from rsp after the
// prologue; scopes as S_BLOCK32 like the lexical blocks of DWARF), and C13 line information
// (DEBUG_S_LINES per function, DEBUG_S_FILECHKSMS for the files, by their /names offsets).
// Publics (S_PUB32) and globals (S_PROCREF) name every function. Types: the same mapping as
// DWARF (dwarf.al): base types as CodeView primitive types, a struct as LF_STRUCTURE with
// LF_MEMBERs, an enum without data as LF_ENUM, an enum with data as a struct of its tag and
// a union of one struct per variant (CodeView has no variant parts).

priv const BLOCK = 4096

// ---------- little helpers ----------

priv fn cstr_out(v: *Vec[u8], s: str) {
    v.extend(s)
    v.push(0)
}

priv fn u32_at(b: []u8, o: i64) -> i64 {
    return i64(b[o]) | i64(b[o + 1]) << 8 | i64(b[o + 2]) << 16 | i64(b[o + 3]) << 24
}

// LLVM's hashStringV1 (the hash of PDB name tables)
priv fn hash_v1(s: str) -> u32 {
    r: u32 = 0
    n := len(s)
    k := 0
    while k + 4 <= n {
        r ^= u32(s[k]) | u32(s[k + 1]) << 8 | u32(s[k + 2]) << 16 | u32(s[k + 3]) << 24
        k += 4
    }
    if n - k >= 2 {
        r ^= u32(s[k]) | u32(s[k + 1]) << 8
        k += 2
    }
    if n - k == 1 {
        r ^= u32(s[k])
    }
    r |= 0x20202020
    r ^= r >> 11
    return r ^ (r >> 16)
}

// CRC-32 (the hash of type records without a name: LLVM's hashBufferV8)
priv fn crc32(b: []u8) -> u32 {
    c: u32 = 0xFFFFFFFF
    for x in b {
        c ^= u32(x)
        for i in 0..8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0xEDB88320 } else { c >> 1 }
        }
    }
    return c ^ 0xFFFFFFFF
}

// a symbol or type record: u16 length (of what follows it), u16 kind, the body, padded to 4
// bytes (0xF3 0xF2 0xF1, as the CodeView format pads)
priv fn record(out: *Vec[u8], kind: i64, body: []u8) {
    n := 2 + len(body)
    pad := (4 - (2 + n) % 4) % 4
    put16(out, n + pad)
    put16(out, kind)
    out.extend(body)
    for i in 0..pad {
        out.push(u8(0xF0 + pad - i))
    }
}

// ---------- the string table (/names) ----------

priv struct Names {
    buf: Vec[u8]
    ix: Map[str, i64]
}

priv fn name_off(n: *Names, s: str) -> i64 {
    if n.buf.is_empty() {
        n.buf.push(0)
    }
    o, found := n.ix.get(s)
    if found {
        return o
    }
    o = n.buf.len
    cstr_out(&n.buf, s)
    n.ix.set(s, o)
    return o
}

// the PDB string table: header, strings, a hash table of their offsets, their number
priv fn string_table(n: *Names, strs: []str) -> Vec[u8] {
    if n.buf.is_empty() {
        n.buf.push(0)
    }
    t := vec[u8]()
    put32(&t, 0xEFFEEFFE)
    put32(&t, 1)
    put32(&t, n.buf.len)
    t.extend(n.buf.items())
    nb := 2 * len(strs) + 1
    buckets := vec_fill(nb, 0)
    for s in strs {
        o, _ := n.ix.get(s)
        b := i64(hash_v1(s)) % nb
        while buckets[b] != 0 {
            b = (b + 1) % nb
        }
        buckets[b] = o
    }
    put32(&t, nb)
    for b in buckets {
        put32(&t, b)
    }
    put32(&t, len(strs))
    return t
}

// ---------- the MSF container ----------

// the file of the streams (stream k is streams[k])
priv fn msf(streams: []Vec[u8]) -> Vec[u8] {
    // blocks 0 (super block), 1 and 2 (free block maps) and every 1 + 4096 k, 2 + 4096 k are
    // taken; the others are handed out in order
    next := 3
    fn take(next: *i64) -> i64 {
        while *next % BLOCK == 1 || *next % BLOCK == 2 {
            *next += 1
        }
        b := *next
        *next += 1
        return b
    }
    blocks := vec[Vec[i64]]()
    for s in streams {
        bl := vec[i64]()
        for i in 0..(s.len + BLOCK - 1) / BLOCK {
            bl.push(take(&next))
        }
        blocks.push(bl)
    }
    dir := vec[u8]()
    put32(&dir, len(streams))
    for s in streams {
        put32(&dir, s.len)
    }
    for bl in blocks {
        for b in bl {
            put32(&dir, b)
        }
    }
    dir_blocks := vec[i64]()
    for i in 0..(dir.len + BLOCK - 1) / BLOCK {
        dir_blocks.push(take(&next))
    }
    map_block := take(&next)
    nblocks := next
    file := vec_fill(nblocks * BLOCK, u8(0))
    fn write(file: *Vec[u8], bl: *Vec[i64], data: []u8) {
        for i, b in *bl {
            n := min(BLOCK, len(data) - i * BLOCK)
            copy(file[b * BLOCK..b * BLOCK + n], data[i * BLOCK..i * BLOCK + n])
        }
    }
    for i, s in streams {
        write(&file, &blocks[i], s.items())
    }
    write(&file, &dir_blocks, dir.items())
    for i, b in dir_blocks {
        set32(&file, map_block * BLOCK + 4 * i, b)
    }
    // the free block map (in blocks 1, 4097, ...): a bit per block, 1 = free
    fpm := vec_fill(align_up(nblocks, 8 * BLOCK) / 8, u8(0xFF))
    for b in 0..nblocks {
        fpm[b / 8] &= ~(u8(1) << u8(b % 8))
    }
    for k in 0..fpm.len / BLOCK {
        at := (1 + k * BLOCK) * BLOCK
        if at + BLOCK <= file.len {
            copy(file[at..at + BLOCK], fpm[k * BLOCK..(k + 1) * BLOCK])
        }
    }
    // the super block
    sb := vec[u8]()
    sb.extend("Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0")
    put32(&sb, BLOCK)
    put32(&sb, 1) // the free block map in use
    put32(&sb, nblocks)
    put32(&sb, dir.len)
    put32(&sb, 0)
    put32(&sb, map_block)
    copy(file[..sb.len], sb.items())
    return file
}

// ---------- the global and public symbol hash tables ----------

// the hash table (GSI) of the records at offsets offs (in the symbol records stream) named names
priv fn gsi_hash(names: []str, offs: []i64) -> Vec[u8] {
    n := len(names)
    // by bucket, then as LLVM orders the names of a bucket (shorter first, then without regard
    // to case): (bucket, length, name in lower case, offset, index)
    keys := vec[(i64, i64, str, i64, i64)]()
    for i, s in names {
        keys.push((i64(hash_v1(s) % 4096), len(s), to_lower(s), offs[i], i))
    }
    sort_by(keys.items(), fn(a: (i64, i64, str, i64, i64), b: (i64, i64, str, i64, i64)) -> bool {
        if a.0 != b.0 {
            return a.0 < b.0
        }
        if a.1 != b.1 {
            return a.1 < b.1
        }
        if a.2 != b.2 {
            return cmp(a.2, b.2) < 0
        }
        return a.3 < b.3
    })
    order := vec[i64]()
    bucket := vec_fill(n, 0)
    for x in keys {
        order.push(x.4)
        bucket[x.4] = x.0
    }
    t := vec[u8]()
    put32(&t, 0xFFFFFFFF)
    put32(&t, 0xF12F091A)
    put32(&t, 8 * n)
    bitmap := vec_fill(129, u32(0))
    starts := vec[i64]()
    for k, i in order {
        b := bucket[i]
        if bitmap[b / 32] & (u32(1) << u32(b % 32)) == 0 {
            bitmap[b / 32] |= u32(1) << u32(b % 32)
            starts.push(k)
        }
    }
    put32(&t, 4 * 129 + 4 * starts.len)
    for i in order {
        put32(&t, offs[i] + 1)
        put32(&t, 1)
    }
    for w in bitmap {
        put32(&t, i64(w))
    }
    for k in starts {
        put32(&t, 12 * k)
    }
    return t
}

// ---------- CodeView types ----------

priv struct Cv {
    types: *Types
    tpi: Vec[u8]          // the records
    offs: Vec[i64]        // the offset of each record
    hashes: Vec[u32]      // the hash of each record (the TPI hash stream)
    of: Map[i64, i64]     // AL type -> type index
    fwd: Map[i64, i64]    // AL type -> the index of its forward declaration
    refs: Map[i64, i64]   // type index -> a reference to it
}

// a new type record; its index
priv fn cv_add(cv: *Cv, kind: i64, body: []u8, name: str) -> i64 {
    cv.offs.push(cv.tpi.len)
    at := cv.tpi.len
    record(&cv.tpi, kind, body)
    cv.hashes.push(if len(name) > 0 { hash_v1(name) } else { crc32(cv.tpi[at..]) } % 0x3FFFF)
    return 0x1000 + cv.offs.len - 1
}

// a CodeView numeric leaf (an unsigned value)
priv fn cv_num(b: *Vec[u8], x: i64) {
    if x >= 0 && x < 0x8000 {
        put16(b, x)
    } else {
        put16(b, 0x8004) // LF_ULONG
        put32(b, x)
    }
}

// the type index of AL type t (0: none, for unit)
priv fn cv_type(cv: *Cv, t: i64) -> i64 {
    ty := cv.types
    match ty.k(t) {
        Bool => return 0x30
        Int(8, true) => return 0x68
        Int(8, false) => return 0x20 // unsigned char (a *u8 shows as text)
        Int(16, s) => return if s { 0x72 } else { 0x73 }
        Int(32, s) => return if s { 0x74 } else { 0x75 }
        Int(_, s) => return if s { 0x76 } else { 0x77 }
        F32 => return 0x40
        F64 => return 0x41
        Err, Unit, Never => return 0
        _ => {}
    }
    known, found := cv.of.get(t)
    if found {
        return known
    }
    r := 0
    match ty.k(t) {
        Ptr(e) => {
            // (a pointer to an aggregate points to its forward declaration, which debuggers
            // resolve by the name: types that refer to themselves through pointers)
            et := if is_aggregate(cv, e) { cv_fwd(cv, e) } else { cv_type(cv, e) }
            if et < 0x1000 {
                r = if et == 0 { 0x603 } else { 0x600 | et }
            } else {
                b := vec[u8]()
                put32(&b, et)
                put32(&b, 0x1000C) // 64-bit pointer, size 8
                r = cv_add(cv, 0x1002, b.items(), "") // LF_POINTER
            }
        }
        Fn(_, _) => r = 0x603 // (a code address)
        Array(e, n) => {
            et := cv_type(cv, e)
            b := vec[u8]()
            put32(&b, if et == 0 { 0x20 } else { et })
            put32(&b, 0x23) // index type: unsigned __int64
            cv_num(&b, ty.size_of(t))
            b.push(0)
            r = cv_add(cv, 0x1503, b.items(), "") // LF_ARRAY
        }
        Enum(e) => {
            ty.size_of(t)
            info := &ty.enums[e]
            if info.simple || info.variants.is_empty() {
                r = cv_enum(cv, e, ast_plain_text(info.name))
            } else {
                r = cv_tagged(cv, t, e)
            }
        }
        _ => {
            ms := cv_members(cv, t)
            r = cv_struct(cv, cv_name(cv, t), ty.size_of(t), ms.items())
        }
    }
    cv.of.set(t, r)
    return r
}

// the LF_PROCEDURE of function fid (its parameter and result types), 0 if unknown
priv fn cv_proc(cv: *Cv, fid: i64) -> i64 {
    if dbg_cx == nil || fid >= dbg_cx.fn_sigs.len {
        return 0
    }
    ps, r := dbg_cx.fn_sigs[fid]
    al := vec[u8]()
    n := 0
    for p in ps {
        t := cv_type(cv, p)
        if t != 0 {
            put32(&al, t)
            n += 1
        }
    }
    ab := vec[u8]()
    put32(&ab, n)
    ab.extend(al.items())
    args := cv_add(cv, 0x1201, ab.items(), "") // LF_ARGLIST
    rt := cv_type(cv, r)
    b := vec[u8]()
    put32(&b, if rt == 0 { 3 } else { rt }) // (3: void)
    b.push(0) // near C call
    b.push(0)
    put16(&b, n)
    put32(&b, args)
    return cv_add(cv, 0x1008, b.items(), "") // LF_PROCEDURE
}

// is t a type that becomes an LF_STRUCTURE (named, may be declared forward)?
priv fn is_aggregate(cv: *Cv, t: i64) -> bool {
    return match cv.types.k(t) {
        Struct(_), Tuple(_), Slice(_), Vec(_), Quat, Mat4 => true
        Enum(e) => !cv.types.enums[e].simple && !cv.types.enums[e].variants.is_empty()
        _ => false
    }
}

// the forward declaration of the aggregate t (made once)
priv fn cv_fwd(cv: *Cv, t: i64) -> i64 {
    known, found := cv.fwd.get(t)
    if found {
        return known
    }
    name := match cv.types.k(t) {
        Enum(e) => ast_plain_text(cv.types.enums[e].name)
        _ => cv_name(cv, t)
    }
    b := vec[u8]()
    put16(&b, 0)
    put16(&b, 0x80) // a forward reference
    put32(&b, 0)
    put32(&b, 0)
    put32(&b, 0)
    cv_num(&b, 0)
    cstr_out(&b, name)
    r := cv_add(cv, 0x1505, b.items(), name)
    cv.fwd.set(t, r)
    return r
}

priv fn cv_name(cv: *Cv, t: i64) -> str {
    return ast_plain_text(cv.types.name(t))
}

// the members (name, type, offset) of an aggregate type as in dwarf.al
priv fn cv_members(cv: *Cv, t: i64) -> Vec[(str, i64, i64)] {
    ty := cv.types
    ms := vec[(str, i64, i64)]()
    match ty.k(t) {
        Vec(n) => {
            for k in 0..n {
                ms.push(("xyzw"[k..k + 1], T_F32, 4 * k))
            }
        }
        Quat => {
            for k in 0..4 {
                ms.push(("xyzw"[k..k + 1], T_F32, 4 * k))
            }
        }
        Mat4 => ms.push(("cols", ty.intern(Array(T_VEC4, 4)), 0))
        Slice(e) => {
            ms.push(("ptr", ty.ptr_to(e), 0))
            ms.push(("len", T_I64, 8))
        }
        Tuple(v) => {
            offs := ty.tuple_offsets(v.items())
            for i, x in v {
                ms.push((fmt("_", i), x, offs[i]))
            }
        }
        Struct(s) => {
            ty.layout_struct(s)
            info := &ty.structs[s]
            for i, f in info.fields {
                if i < info.offsets.len {
                    ms.push((f.0, f.1, info.offsets[i]))
                }
            }
        }
        _ => {}
    }
    return ms
}

// an LF_FIELDLIST of the members (type indices resolved) and the LF_STRUCTURE (LF_UNION if
// `union`) that uses it
priv fn cv_fields(cv: *Cv, ms: [](str, i64, i64)) -> (i64, i64) {
    idx := vec[i64]()
    for x in ms {
        idx.push(cv_type(cv, x.1))
    }
    fl := vec[u8]()
    n := 0
    for i, x in ms {
        if idx[i] == 0 {
            continue
        }
        put16(&fl, 0x150d) // LF_MEMBER
        put16(&fl, 3) // public
        put32(&fl, idx[i])
        cv_num(&fl, x.2)
        cstr_out(&fl, x.0)
        while fl.len % 4 != 0 {
            fl.push(u8(0xF0 + 4 - fl.len % 4))
        }
        n += 1
    }
    return (cv_add(cv, 0x1203, fl.items(), ""), n) // LF_FIELDLIST
}

priv fn cv_struct(cv: *Cv, name: str, size: i64, ms: [](str, i64, i64)) -> i64 {
    fl, n := cv_fields(cv, ms)
    b := vec[u8]()
    put16(&b, n)
    put16(&b, 0) // properties
    put32(&b, fl)
    put32(&b, 0) // derived
    put32(&b, 0) // vshape
    cv_num(&b, size)
    cstr_out(&b, name)
    return cv_add(cv, 0x1505, b.items(), name) // LF_STRUCTURE
}

// an enum without data: LF_ENUM over u32 with an LF_ENUMERATE per variant
priv fn cv_enum(cv: *Cv, e: i64, name: str) -> i64 {
    info := &cv.types.enums[e]
    fl := vec[u8]()
    for i, v in info.variants {
        put16(&fl, 0x1502) // LF_ENUMERATE
        put16(&fl, 3)
        cv_num(&fl, i)
        cstr_out(&fl, v.0)
        while fl.len % 4 != 0 {
            fl.push(u8(0xF0 + 4 - fl.len % 4))
        }
    }
    fli := cv_add(cv, 0x1203, fl.items(), "")
    b := vec[u8]()
    put16(&b, info.variants.len)
    put16(&b, 0)
    put32(&b, 0x75) // underlying type: unsigned int
    put32(&b, fli)
    cstr_out(&b, name)
    return cv_add(cv, 0x1507, b.items(), name) // LF_ENUM
}

// an enum with data: struct E { tag: E.tag, (the union of the variants) }
priv fn cv_tagged(cv: *Cv, t: i64, e: i64) -> i64 {
    ty := cv.types
    info := &ty.enums[e]
    name := ast_plain_text(info.name)
    tag := cv_enum(cv, e, fmt(name, ".tag"))
    // the payload struct of each variant (its fields at their offsets in the enum)
    vs := vec[(str, i64, i64)]()
    vidx := vec[i64]()
    for i, v in info.variants {
        offs := ty.variant_offsets(e, i)
        ms := vec[(str, i64, i64)]()
        for j, x in v.1 {
            ms.push((fmt("_", j), x, offs[j]))
        }
        vidx.push(cv_struct(cv, fmt(name, ".", v.0), info.size, ms.items()))
    }
    // the union: members of the variant structs, all at 0
    fl := vec[u8]()
    for i, v in info.variants {
        put16(&fl, 0x150d)
        put16(&fl, 3)
        put32(&fl, vidx[i])
        cv_num(&fl, 0)
        cstr_out(&fl, v.0)
        while fl.len % 4 != 0 {
            fl.push(u8(0xF0 + 4 - fl.len % 4))
        }
    }
    fli := cv_add(cv, 0x1203, fl.items(), "")
    ub := vec[u8]()
    put16(&ub, info.variants.len)
    put16(&ub, 0)
    put32(&ub, fli)
    cv_num(&ub, info.size)
    uname := fmt(name, ".variants")
    cstr_out(&ub, uname)
    un := cv_add(cv, 0x1506, ub.items(), uname) // LF_UNION
    // the struct: the tag at 0 and the union at 0 (the payloads lie after the tag)
    fl2 := vec[u8]()
    for x in [](str, i64){("tag", tag), ("v", un)} {
        put16(&fl2, 0x150d)
        put16(&fl2, 3)
        put32(&fl2, x.1)
        cv_num(&fl2, 0)
        cstr_out(&fl2, x.0)
        while fl2.len % 4 != 0 {
            fl2.push(u8(0xF0 + 4 - fl2.len % 4))
        }
    }
    fl2i := cv_add(cv, 0x1203, fl2.items(), "")
    b := vec[u8]()
    put16(&b, 2)
    put16(&b, 0)
    put32(&b, fl2i)
    put32(&b, 0)
    put32(&b, 0)
    cv_num(&b, info.size)
    cstr_out(&b, name)
    return cv_add(cv, 0x1505, b.items(), name)
}

// the TPI (or IPI) stream of the records in cv and its hash stream
priv fn tpi_stream(cv: *Cv, hash_stream: i64) -> (Vec[u8], Vec[u8]) {
    h := vec[u8]()
    for x in cv.hashes {
        put32(&h, i64(x))
    }
    hv := h.len
    // the index offsets: the first record (and one every 8 KiB of records)
    last := -8192
    for i, o in cv.offs {
        if o - last >= 8192 {
            put32(&h, 0x1000 + i)
            put32(&h, o)
            last = o
        }
    }
    t := vec[u8]()
    put32(&t, 20040203)
    put32(&t, 56)
    put32(&t, 0x1000)
    put32(&t, 0x1000 + cv.offs.len)
    put32(&t, cv.tpi.len)
    put16(&t, hash_stream)
    put16(&t, 0xFFFF)
    put32(&t, 4)
    put32(&t, 0x3FFFF)
    put32(&t, 0)
    put32(&t, hv)
    put32(&t, hv)
    put32(&t, h.len - hv)
    put32(&t, h.len)
    put32(&t, 0)
    t.extend(cv.tpi.items())
    return (t, h)
}

// ---------- the PDB ----------

// a module: a source file and its functions (indices into out.funcs)
priv struct Mod {
    file: i64
    funcs: Vec[i64]
}

// the path of file k as a debugger finds it (made absolute from the working directory `cwd`)
priv fn src_path(k: i64, cwd: str) -> str {
    n := dbg_file_name(k)
    if len(n) == 0 {
        return "?"
    }
    if starts_with(n, "<") {
        return n
    }
    if host_root(n) > 0 || len(cwd) == 0 {
        return replace(n, "/", "\\")
    }
    return fmt(cwd, "\\", replace(n, "/", "\\"))
}

// The PDB of the executable whose functions are at the RVAs func_rva, its code section (the
// first section) at text_rva, with the section headers `sh` (40 bytes each); guid: 16 bytes,
// age 1.
fn pdb_build(m: *Module, out: *Output, func_rva: *Vec[i64], text_rva: i64, gaddr: *Vec[i64], base: i64, sh: []u8, guid: []u8) -> Vec[u8] {
    cwd := __os_current_dir()
    names := Names{}
    cv := Cv{types: &dbg_cx.types}
    // the modules, by the files of the functions
    mods := vec[Mod]()
    mod_of := map[i64, i64]()
    for ci, c in out.funcs {
        orig := dbg_fn_orig(m, c.fid)
        f := if orig < dbg_fn_file.len { i64(dbg_fn_file[orig]) } else { -1 }
        k, found := mod_of.get(f)
        if !found {
            k = mods.len
            mods.push(Mod{file: f})
            mod_of.set(f, k)
        }
        mods[k].funcs.push(ci)
    }
    // stream numbers: 0 old directory, 1 info, 2 TPI, 3 DBI, 4 IPI, 5 TPI hash, 6 IPI hash,
    // 7 globals, 8 publics, 9 symbol records, 10 section headers, 11 /names, 12.. modules
    S_NAMES := 11
    S_MOD0 := 12
    syms := vec[u8]() // the symbol records of publics and globals
    gnames := vec[str]()
    goffs := vec[i64]()
    pnames := vec[str]()
    poffs := vec[i64]()
    paddr := vec[i64]()
    modinfo := vec[u8]()
    contribs := vec[(i64, i64, i64)]() // (offset in .text, size, module)
    mstreams := vec[Vec[u8]]()
    file_lists := vec[Vec[str]]()
    for mi, md in mods {
        s := vec[u8]()
        put32(&s, 4) // CV_SIGNATURE_C13
        // the files of the module's lines: their checksum entries (offset in /names, no checksum)
        chk := vec[u8]()
        chk_of := map[i64, i64]()
        flist := vec[str]()
        fn chk_entry(chk: *Vec[u8], chk_of: *Map[i64, i64], flist: *Vec[str], names: *Names, f: i64, cwd: str) -> i64 {
            o, found := chk_of.get(f)
            if found {
                return o
            }
            o = chk.len
            p := src_path(f, cwd)
            put32(chk, name_off(names, p))
            chk.push(0)
            chk.push(0)
            put16(chk, 0)
            chk_of.set(f, o)
            flist.push(p)
            return o
        }
        chk_entry(&chk, &chk_of, &flist, &names, md.file, cwd)
        lines := vec[u8]()
        for ci in md.funcs {
            c := &out.funcs[ci]
            code := &c.code
            off := func_rva[c.fid] - text_rva
            size := code.bytes.len
            name := dbg_fn_name(m, c.fid)
            // S_GPROC32 ... S_END
            at := s.len
            b := vec[u8]()
            put32(&b, 0)
            put32(&b, 0) // pEnd (below)
            put32(&b, 0)
            put32(&b, size)
            // the debug start: after the prologue and the parameters' stores
            put32(&b, if code.pro_end > 0 { i64(code.pro_end) } else { i64(code.alloc_end) })
            put32(&b, size)
            put32(&b, cv_proc(&cv, dbg_fn_orig(m, c.fid)))
            put32(&b, off)
            put16(&b, 1)
            b.push(0)
            cstr_out(&b, name)
            record(&s, 0x1110, b.items())
            fp := vec[u8]()
            put32(&fp, i64(code.alloc))
            put32(&fp, 0)
            put32(&fp, 0)
            put32(&fp, 8 * i64(code.npush))
            put32(&fp, 0)
            put16(&fp, 0)
            put32(&fp, (1 << 14) | (1 << 16)) // locals and parameters from rsp
            record(&s, 0x1012, fp.items())
            rows := dbg_rows(m, c.fid, code)
            pdb_vars(&s, &cv, code, off, at, &rows)
            set32(&s, at + 8, s.len)
            record(&s, 0x0006, nil)
            // the procedure reference and the public symbol
            gnames.push(name)
            goffs.push(syms.len)
            rb := vec[u8]()
            put32(&rb, 0)
            put32(&rb, at)
            put16(&rb, mi + 1)
            cstr_out(&rb, name)
            record(&syms, 0x1125, rb.items())
            pnames.push(name)
            poffs.push(syms.len)
            paddr.push(off)
            pb := vec[u8]()
            put32(&pb, 2) // a function
            put32(&pb, off)
            put16(&pb, 1)
            cstr_out(&pb, name)
            record(&syms, 0x110e, pb.items())
            contribs.push((off, size, mi))
            // the lines: blocks of consecutive rows of one file
            if rows.is_empty() {
                continue
            }
            ls := vec[u8]()
            put32(&ls, off)
            put16(&ls, 1)
            put16(&ls, 0)
            put32(&ls, size)
            k := 0
            while k < rows.len {
                j := k
                while j < rows.len && rows[j].file == rows[k].file {
                    j += 1
                }
                put32(&ls, chk_entry(&chk, &chk_of, &flist, &names, rows[k].file, cwd))
                put32(&ls, j - k)
                put32(&ls, 12 + 8 * (j - k))
                for r in rows[k..j] {
                    put32(&ls, r.off)
                    put32(&ls, (r.line & 0xFFFFFF) | (1 << 31))
                }
                k = j
            }
            put32(&lines, 0xF2)
            put32(&lines, ls.len)
            lines.extend(ls.items())
        }
        sym_size := s.len
        put32(&s, 0xF4)
        put32(&s, chk.len)
        s.extend(chk.items())
        s.extend(lines.items())
        c13 := s.len - sym_size
        put32(&s, 0) // global refs
        mstreams.push(s)
        file_lists.push(flist)
        // the module's entry in DBI: its first section contribution, stream, sizes, names
        first := &out.funcs[md.funcs[0]]
        put32(&modinfo, 0)
        put16(&modinfo, 1)
        put16(&modinfo, 0)
        put32(&modinfo, func_rva[first.fid] - text_rva)
        put32(&modinfo, first.code.bytes.len)
        put32(&modinfo, 0x60000020)
        put16(&modinfo, mi)
        put16(&modinfo, 0)
        put32(&modinfo, 0)
        put32(&modinfo, 0)
        put16(&modinfo, 0)
        put16(&modinfo, S_MOD0 + mi)
        put32(&modinfo, sym_size)
        put32(&modinfo, 0)
        put32(&modinfo, c13)
        put16(&modinfo, flist.len)
        put16(&modinfo, 0)
        put32(&modinfo, 0)
        put32(&modinfo, 0)
        put32(&modinfo, 0)
        mname := src_path(md.file, cwd)
        cstr_out(&modinfo, mname)
        cstr_out(&modinfo, mname)
        while modinfo.len % 4 != 0 {
            modinfo.push(0)
        }
    }
    // the global variables (as in dwarf.al): S_GDATA32 by section and offset
    for n in dbg_cx.globals.keys() {
        tg, _ := dbg_cx.globals.get(n)
        ty, gi := tg
        if gi < 0 || gi >= m.globals.len || m.globals[gi].tls || dbg_cx.ext_gots.has(gi) || gaddr[gi] == 0 {
            continue
        }
        t := cv_type(&cv, ty)
        rva := gaddr[gi] - base
        for i in 0..len(sh) / 40 {
            va := u32_at(sh, 40 * i + 12)
            if t != 0 && rva >= va && rva < va + u32_at(sh, 40 * i + 8) {
                name := ast_plain_text(n)
                gnames.push(name)
                goffs.push(syms.len)
                b := vec[u8]()
                put32(&b, t)
                put32(&b, rva - va)
                put16(&b, i + 1)
                cstr_out(&b, name)
                record(&syms, 0x110d, b.items())
                break
            }
        }
    }
    // section contributions, by offset
    sort_by(contribs.items(), fn(a: (i64, i64, i64), b: (i64, i64, i64)) -> bool { a.0 < b.0 })
    sc := vec[u8]()
    put32(&sc, 0xF12EBA2D)
    for x in contribs {
        put16(&sc, 1)
        put16(&sc, 0)
        put32(&sc, x.0)
        put32(&sc, x.1)
        put32(&sc, 0x60000020)
        put16(&sc, x.2)
        put16(&sc, 0)
        put32(&sc, 0)
        put32(&sc, 0)
    }
    // the section map: one entry per section, then the absolute one
    nsec := len(sh) / 40
    smap := vec[u8]()
    put16(&smap, nsec + 1)
    put16(&smap, nsec + 1)
    for i in 0..nsec {
        ch := i64(sh[40 * i + 36]) | i64(sh[40 * i + 37]) << 8 | i64(sh[40 * i + 38]) << 16 | i64(sh[40 * i + 39]) << 24
        vs := i64(sh[40 * i + 8]) | i64(sh[40 * i + 9]) << 8 | i64(sh[40 * i + 10]) << 16 | i64(sh[40 * i + 11]) << 24
        fl := 0x108 // a selector, 32-bit address
        if ch & 0x40000000 != 0 {
            fl |= 1
        }
        if ch & 0x80000000 != 0 {
            fl |= 2
        }
        if ch & 0x20000000 != 0 {
            fl |= 4
        }
        put16(&smap, fl)
        put16(&smap, 0)
        put16(&smap, 0)
        put16(&smap, i + 1)
        put16(&smap, 0xFFFF)
        put16(&smap, 0xFFFF)
        put32(&smap, 0)
        put32(&smap, vs)
    }
    put16(&smap, 0x208)
    put16(&smap, 0)
    put16(&smap, 0)
    put16(&smap, nsec + 1)
    put16(&smap, 0xFFFF)
    put16(&smap, 0xFFFF)
    put32(&smap, 0)
    put32(&smap, 0xFFFFFFFF)
    // the files of the modules
    fi := vec[u8]()
    put16(&fi, mods.len)
    total := 0
    for fl in file_lists {
        total += fl.len
    }
    put16(&fi, total & 0xFFFF)
    at := 0
    for fl in file_lists {
        put16(&fi, at)
        at += fl.len
    }
    for fl in file_lists {
        put16(&fi, fl.len)
    }
    fnames := vec[u8]()
    for fl in file_lists {
        for p in fl {
            put32(&fi, fnames.len)
            cstr_out(&fnames, p)
        }
    }
    fi.extend(fnames.items())
    while fi.len % 4 != 0 {
        fi.push(0)
    }
    // the EC names (an empty string table)
    ec_names := Names{}
    ec := string_table(&ec_names, nil)
    // optional debug streams: only the section headers (index 5)
    opt := vec[u8]()
    for k in 0..11 {
        put16(&opt, if k == 5 { 10 } else { 0xFFFF })
    }
    dbi := vec[u8]()
    put32(&dbi, 0xFFFFFFFF)
    put32(&dbi, 19990903)
    put32(&dbi, 1)
    put16(&dbi, 7)      // globals
    put16(&dbi, 0x8E00) // build number 14.0, new format
    put16(&dbi, 8)      // publics
    put16(&dbi, 0)
    put16(&dbi, 9)      // symbol records
    put16(&dbi, 0)
    put32(&dbi, modinfo.len)
    put32(&dbi, sc.len)
    put32(&dbi, smap.len)
    put32(&dbi, fi.len)
    put32(&dbi, 0)
    put32(&dbi, 0)
    put32(&dbi, opt.len)
    put32(&dbi, ec.len)
    put16(&dbi, 0)
    put16(&dbi, 0x8664)
    put32(&dbi, 0)
    dbi.extend(modinfo.items())
    dbi.extend(sc.items())
    dbi.extend(smap.items())
    dbi.extend(fi.items())
    dbi.extend(ec.items())
    dbi.extend(opt.items())
    // publics: the header, the hash, the address map (the records by address)
    ph := gsi_hash(pnames.items(), poffs.items())
    byaddr := vec[(i64, str, i64)]()
    for i in 0..pnames.len {
        byaddr.push((paddr[i], pnames[i], i))
    }
    sort_by(byaddr.items(), fn(a: (i64, str, i64), b: (i64, str, i64)) -> bool { a.0 < b.0 || a.0 == b.0 && cmp(a.1, b.1) < 0 })
    order := vec[i64]()
    for x in byaddr {
        order.push(x.2)
    }
    pub := vec[u8]()
    put32(&pub, ph.len)
    put32(&pub, 4 * order.len)
    put32(&pub, 0)
    put32(&pub, 0)
    put16(&pub, 0)
    put16(&pub, 0)
    put32(&pub, 0)
    put32(&pub, 0)
    pub.extend(ph.items())
    for i in order {
        put32(&pub, poffs[i])
    }
    glob := gsi_hash(gnames.items(), goffs.items())
    // the string table, now that every name is in it
    all := vec[str]()
    for s in names.ix.keys() {
        all.push(s)
    }
    strtab := string_table(&names, all.items())
    // the PDB info stream: version, signature, age, GUID, the named streams, the features
    info := vec[u8]()
    put32(&info, 20000404)
    put32(&info, i64(guid[0]) | i64(guid[1]) << 8 | i64(guid[2]) << 16 | i64(guid[3]) << 24)
    put32(&info, 1)
    info.extend(guid)
    put32(&info, 7)
    info.extend("/names\0")
    put32(&info, 1) // size
    put32(&info, 8) // capacity
    put32(&info, 1) // present: one word
    put32(&info, 1 << (i64(hash_v1("/names") & 0xFFFF) % 8))
    put32(&info, 0) // deleted: none
    put32(&info, 0) // the key: offset 0 of the names
    put32(&info, S_NAMES)
    put32(&info, 0) // no more
    put32(&info, 20140508) // VC140
    // every type declared forward (behind a pointer) is also defined
    loop {
        missing := vec[i64]()
        for t in cv.fwd.keys() {
            if !cv.of.has(t) {
                missing.push(t)
            }
        }
        if missing.is_empty() {
            break
        }
        for t in missing {
            cv_type(&cv, t)
        }
    }
    tpi, tpi_hash := tpi_stream(&cv, 5)
    ipi_cv := Cv{types: cv.types}
    ipi, ipi_hash := tpi_stream(&ipi_cv, 6)
    streams := vec[Vec[u8]]()
    streams.push(vec[u8]())
    streams.push(info)
    streams.push(tpi)
    streams.push(dbi)
    streams.push(ipi)
    streams.push(tpi_hash)
    streams.push(ipi_hash)
    streams.push(glob)
    streams.push(pub)
    streams.push(syms)
    streams.push(vec_of(sh))
    streams.push(strtab)
    streams.extend(mstreams.items())
    return msf(streams.items())
}

// the parameters and variables of a compiled function at offset `off` of the code section
// (S_REGREL32: from rsp after the prologue), with an S_BLOCK32 for each run of code of a scope
// (the lexical blocks of DWARF; CodeView blocks are contiguous); `proc` is the offset of its
// S_GPROC32
priv fn pdb_vars(s: *Vec[u8], cv: *Cv, code: *Code, off: i64, proc: i64, rows: *Vec[DbgRow]) {
    sc := dbg_scopes(code)
    pdb_scope(s, cv, &sc, 0, rows, code, off, proc, 0, code.bytes.len)
}

priv fn pdb_scope(s: *Vec[u8], cv: *Cv, sc: *Vec[DbgScope], k: i64, rows: *Vec[DbgRow], code: *Code, off: i64, parent: i64, lo: i64, hi: i64) {
    for x in 0..sc[k].vars.len / 2 {
        regrel(s, cv, code, sc[k].vars[2 * x], sc[k].vars[2 * x + 1], off)
    }
    size := code.bytes.len
    for c in sc[k].kids {
        for r in dbg_runs(rows, size, sc[c].first, sc[c].last, lo, hi) {
            at := s.len
            b := vec[u8]()
            put32(&b, parent)
            put32(&b, 0) // pEnd (below)
            put32(&b, r.1 - r.0)
            put32(&b, off + r.0)
            put16(&b, 1)
            b.push(0)
            record(s, 0x1103, b.items()) // S_BLOCK32
            pdb_scope(s, cv, sc, c, rows, code, off, at, r.0, r.1)
            set32(s, at + 8, s.len)
            record(s, 0x0006, nil)
        }
    }
}

// the type index of variable k (an indirect one: a reference to its type, which debuggers
// show as the value), 0 for none
priv fn var_type(cv: *Cv, k: i64) -> i64 {
    v := &dbg_vars[k]
    t := cv_type(cv, v.ty)
    if t == 0 || !v.indirect {
        return t
    }
    known, found := cv.refs.get(t)
    if !found {
        rb := vec[u8]()
        put32(&rb, t)
        put32(&rb, 0x1002C) // 64-bit, an lvalue reference, size 8
        known = cv_add(cv, 0x1002, rb.items(), "")
        cv.refs.set(t, known)
    }
    return known
}

// CV_AMD64_RAX.. of rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8..r15
priv const CV_GPRS = [16]i64{328, 330, 331, 329, 335, 334, 332, 333, 336, 337, 338, 339, 340, 341, 342, 343}

// the CodeView number of register r (0..15, xmm0..15 as 16..31)
priv fn cv_reg(r: i64) -> i64 {
    if r >= 16 {
        return if r < 24 { 154 + (r - 16) } else { 252 + (r - 24) }
    }
    return CV_GPRS[r]
}

// variable k at offset `cfa_off` from the CFA, as S_REGREL32; one described by ranges
// (DV_RANGES) as S_LOCAL with its ranges (S_DEFRANGE_REGISTER, S_DEFRANGE_FRAMEPOINTER_REL from
// rsp after the prologue; constants have no such record: there the variable is not shown)
priv fn regrel(s: *Vec[u8], cv: *Cv, code: *Code, k: i64, cfa_off: i64, off: i64) {
    above := i64(code.alloc) + 8 * i64(code.npush) + 8
    v := &dbg_vars[k]
    t := var_type(cv, k)
    if t == 0 {
        return
    }
    if cfa_off != DV_RANGES {
        b := vec[u8]()
        put32(&b, cfa_off + above)
        put32(&b, t)
        put16(&b, 335) // CV_AMD64_RSP
        cstr_out(&b, v.name)
        record(s, 0x1111, b.items()) // S_REGREL32
        return
    }
    rs := vec[DbgRange]()
    for r in code.dranges {
        if i64(r.var) == k && (r.kind == DL_REG || r.kind == DL_FB) {
            rs.push(r)
        }
    }
    b := vec[u8]()
    put32(&b, t)
    put16(&b, (if v.param { 1 } else { 0 }) | (if rs.is_empty() { 0x100 } else { 0 })) // fIsParam, fIsOptimizedOut
    cstr_out(&b, v.name)
    record(s, 0x113E, b.items()) // S_LOCAL
    for r in rs {
        // (a range is at most 0xFFFF bytes)
        lo := i64(r.lo)
        while lo < i64(r.hi) {
            n := min(i64(r.hi) - lo, 0xFFFF)
            d := vec[u8]()
            if r.kind == DL_REG {
                put16(&d, cv_reg(r.val))
                put16(&d, 0)
            } else {
                put32(&d, r.val + above)
            }
            put32(&d, off + lo)
            put16(&d, 1)
            put16(&d, n)
            record(s, if r.kind == DL_REG { 0x1141 } else { 0x1142 }, d.items()) // S_DEFRANGE_REGISTER, _FRAMEPOINTER_REL
            lo += n
        }
    }
}
