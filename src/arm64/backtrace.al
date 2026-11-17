// The stack-trace table of the arm64 code (--target linux-arm64): the table of
// src/backtrace.al (its layout is described there; the walk is __bt_print in the prelude), made
// from the code of src/arm64. The walk finds a frame's return address at sp + 8 * pushes +
// allocation: every arm64 function keeps a frame record (x29, x30) at the top of its frame,
// so the table gives each function no pushes and the bytes up to the saved x30 as its
// allocation; the return address then is the saved x30, and the caller's stack pointer the one
// above the record. (A copy of bt_attach for A64Output: the builder below is that of
// src/backtrace.al.)
priv struct Builder {
    m: *Module
    cx: *Cx
    strs: Vec[u8]
    str_ix: Map[str, i64]
    scopes: Vec[u8]
    scope_ix: Map[(i64, i64), i64]
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
    lib := file < 0 || b.cx.core_file(file) || file == b.cx.entry_file
    put32(&b.scopes, str_off(b, if file >= 0 && file < b.cx.file_names.len { b.cx.file_names[file] } else { "?" }))
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
// table if the library has no such global or nothing was compiled). cx: the files and which of
// them are library code; tests: the names of the test blocks (function __test_k is test k).
fn a64_bt_attach(m: *Module, out: *A64Output, cx: *Cx, tests: []str) {
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
    b := Builder{m: m, cx: cx, tests: tests, inl: vec_fill(m.locs.list.len, i32(0))}
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
    start := 0 // as elf_arm64_link places the functions: each at a multiple of 16
    for c in out.funcs {
        code := &c.code
        // (a specialised copy shows as the function it copies)
        fid := if m.funcs[c.fid].copy_of >= 0 { m.funcs[c.fid].copy_of } else { c.fid }
        start = align_up(start, 16)
        put32(&funcs, start)
        put32(&funcs, code.bytes.len)
        put32(&funcs, scope(&b, fid, fn_file[fid]))
        // the frame of arm64 code in the fields of x86-64's: no pushes, the return address
        // ra_off bytes above sp (in the frame record), the prologue up to the allocation
        put32(&funcs, code.ra_off)
        funcs.push(u8(0))
        funcs.push(u8(0))
        funcs.push(u8(code.prologue_end))
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
