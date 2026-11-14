// The table that lets a panic print the call stack (the walk is __bt_print in the prelude).
// Built after the back end, from the code of the compiled functions (their frame shapes and line
// entries, see Code in x86/emit.al) and the source locations of the module (SrcLocs in ir.al);
// the linker writes it as one more read-only global, whose address goes into the library's
// global `__bt_table`. Nothing of it is executed unless the program panics.
//
// Layout (little endian; offsets in bytes from the start of the table):
//   0   u64 base: the address of the first function (a data relocation)
//   8   u32 number of functions      12  u32 number of scopes
//   16  u32 offset of the functions  20  u32 offset of the scopes
//   24  u32 offset of the line data  28  u32 offset of the strings
//   32  u32 size of the line data    36  u32 0
//   functions (24 bytes each, by address): u32 start (from base), u32 size, u32 its scope, u32
//     bytes allocated below the pushes, u8 pushes, u8 prologue offset after the pushes, u8
//     prologue offset after the allocation, u8 0, u32 offset of its line data (which ends where
//     the next function's begins)
//   scopes (8 bytes each): a function in a file: u32 file name, u32 function name (string
//     offsets; bit 31 of the name: library code)
//   line data, per function, in ULEB128 numbers: the number of inlined locations, each as
//     (scope, line, location of the call it was inlined at), then pairs (code offset - the
//     previous pair's, location) up to the end: the location holds from that offset (the first
//     pair's is 0) to the next pair's. A location is 2 * k + 1 for inlined location k of the
//     function (the call of k is an earlier one), or even: a line of the function itself, as
//     2 * line in an inlined location and as 2 * zigzag(line - the previous such line, from 0)
//     in a pair.
//   strings: ULEB128 length, then the bytes
// Library code is the code of files whose name starts with `<` (the run-time library, the core
// modules, the generated entry point).

priv struct Builder {
    m: *Module
    strs: Vec[u8]
    str_ix: Map[str, i64]
    scopes: Vec[u8]
    scope_ix: Map[(i64, i64), i64]
    files: []str
    tests: []str
    // the inlined locations of the function being added: by location (number + 1, 0: none
    // yet), their records, how many, and which locations were numbered (to clear `inl`)
    inl: Vec[i32]
    recs: Vec[u8]
    nrecs: i64
    numbered: Vec[i64]
}

priv fn uleb(v: *Vec[u8], x0: i64) {
    x := u64(x0)
    loop {
        b := u8(x & 0x7F)
        x = x >> 7
        if x == 0 {
            v.push(b)
            return
        }
        v.push(b | 0x80)
    }
}

// the offset of string s in the string data (each string once)
priv fn str_off(b: *Builder, s: str) -> i64 {
    o, found := b.str_ix.get(s)
    if found {
        return o
    }
    o = b.strs.len
    uleb(&b.strs, len(s))
    b.strs.extend(s)
    b.str_ix.set(s, o)
    return o
}

// the number of the scope "function fid in file `file`" (made once)
priv fn scope(b: *Builder, fid: i64, file: i64) -> i64 {
    k, found := b.scope_ix.get((fid, file))
    if found {
        return k
    }
    k = b.scopes.len / 8
    b.scope_ix.set((fid, file), k)
    lib := file < 0 || file >= len(b.files) || starts_with(b.files[file], "<")
    put32(&b.scopes, str_off(b, if file >= 0 && file < len(b.files) { b.files[file] } else { "?" }))
    // the name as written: `priv` names plain, nested ones `outer.name`, anonymous ones
    // `outer.fn@line:col`, generic instances `name[T]`, test blocks `test "name"`
    n := ast_plain_text(b.m.funcs[fid].name)
    if starts_with(n, "__test_") {
        t, ok := parse_i64(n[7..])
        if ok && t >= 0 && t < len(b.tests) {
            n = fmt("test \"", b.tests[t], "\"")
        }
    }
    o := str_off(b, n)
    put32(&b.scopes, if lib { o | (1 << 31) } else { o })
    return k
}

// is location l a line of machine function fid itself (not inlined)?
priv fn own(b: *Builder, l: i64, fid: i64) -> bool {
    s := &b.m.locs.list[l]
    return s.parent == 0 && i64(s.func) == fid
}

// the location value of location l (not own) in the code of function fid: its record, made
// on first use (after its call's)
priv fn inl_value(b: *Builder, l: i64, fid: i64) -> i64 {
    if b.inl[l] == 0 {
        s := b.m.locs.list[l]
        parent := 0
        if s.parent != 0 {
            p := i64(s.parent)
            parent = if own(b, p, fid) { 2 * i64(b.m.locs.list[p].line) } else { inl_value(b, p, fid) }
        }
        uleb(&b.recs, scope(b, i64(s.func), i64(s.file)))
        uleb(&b.recs, i64(s.line))
        uleb(&b.recs, parent)
        b.nrecs += 1
        b.inl[l] = i32(b.nrecs)
        b.numbered.push(l)
    }
    return 2 * (i64(b.inl[l]) - 1) + 1
}

// Adds the table for the compiled code `out` to the module and points `__bt_table` at it (no
// table if the library has no such global or nothing was compiled). files: the file names by
// index; tests: the names of the test blocks (function __test_k is test k).
fn bt_attach(m: *Module, out: *Output, files: []str, tests: []str) {
    gi := -1
    for i, g in m.globals {
        if g.name == "__bt_table" {
            gi = i
            break
        }
    }
    if gi < 0 || out.funcs.len == 0 || len(out.err) != 0 {
        return
    }
    b := Builder{m: m, files: files, tests: tests, inl: vec_fill(m.locs.list.len, i32(0))}
    // the file of each function: that of its own locations
    fn_file := vec_fill(m.funcs.len, -1)
    for l in m.locs.list {
        if l.parent == 0 && l.func >= 0 && i64(l.func) < fn_file.len && fn_file[l.func] < 0 {
            fn_file[l.func] = i64(l.file)
        }
    }
    funcs := vec[u8]()
    data := vec[u8]()
    pairs := vec[u8]()
    start := 0 // as layout_text places the functions: each at a multiple of 16
    for c in out.funcs {
        code := &c.code
        fid := c.fid
        start = align_up(start, 16)
        put32(&funcs, start)
        put32(&funcs, code.bytes.len)
        put32(&funcs, scope(&b, fid, fn_file[fid]))
        put32(&funcs, i64(code.alloc))
        funcs.push(u8(code.npush))
        funcs.push(u8(code.push_end))
        funcs.push(u8(code.alloc_end))
        funcs.push(0)
        put32(&funcs, data.len)
        b.recs.clear()
        b.nrecs = 0
        pairs.clear()
        prev := 0
        prev_line := 0
        for k in 0..code.lines.len / 2 {
            o := i64(code.lines[2 * k])
            l := i64(code.lines[2 * k + 1])
            if l <= 0 || l >= m.locs.list.len {
                continue
            }
            uleb(&pairs, o - prev)
            prev = o
            if own(&b, l, fid) {
                line := i64(m.locs.list[l].line)
                d := line - prev_line
                uleb(&pairs, 2 * ((d << 1) ^ (d >> 63)))
                prev_line = line
            } else {
                uleb(&pairs, inl_value(&b, l, fid))
            }
        }
        uleb(&data, b.nrecs)
        data.extend(b.recs.items())
        data.extend(pairs.items())
        for l in b.numbered {
            b.inl[l] = 0
        }
        b.numbered.clear()
        start += code.bytes.len
    }
    t := vec[u8]()
    put64(&t, 0)
    put32(&t, out.funcs.len)
    put32(&t, b.scopes.len / 8)
    put32(&t, 40)
    put32(&t, 40 + funcs.len)
    put32(&t, 40 + funcs.len + b.scopes.len)
    put32(&t, 40 + funcs.len + b.scopes.len + data.len)
    put32(&t, data.len)
    put32(&t, 0)
    t.extend(funcs.items())
    t.extend(b.scopes.items())
    t.extend(data.items())
    t.extend(b.strs.items())
    tid := m.globals.len
    m.globals.push(Global{name: "__bt_data", size: t.len, align: 8, data: Some(t), relocs: vec_one((0, RelocTarget.Func(out.funcs[0].fid))), readonly: true})
    g := &m.globals[gi]
    g.data = Some(vec_fill(8, u8(0)))
    g.relocs = vec_one((0, RelocTarget.Global(tid, 0)))
}
