// DWARF 4 debug information (`alc build -g`, see src/debug.al): the sections .debug_abbrev,
// .debug_info, .debug_line, .debug_str, .debug_aranges, .debug_ranges and (ELF) .debug_frame,
// which elf.al and pe.al add to the executable.
//
// One compile unit for the whole program (language C99, the closest a debugger knows: it
// prints AL values as C structs), covering the code section; one subprogram per compiled
// function with its parameters and variables (lexical blocks for the scopes of variables
// declared inside blocks), the functions inlined into it (inlined_subroutine, from the chains
// of SrcLoc.parent), and the types they need. The line table has one sequence per function.
// Frames: .debug_frame describes the prologues and epilogues of the back end (pushes, then
// one `sub rsp`, on Windows the stack probe of a large frame; no frame pointer). The frame
// base of a function is its CFA on Linux, and rsp plus the frame size on Windows, where gdb
// unwinds with .pdata (DW_OP_call_frame_cfa needs a frame unwound by DWARF).
//
// AL types in DWARF: integers, f32 / f64 and bool are base types (u8 an unsigned char, so a
// `*u8` prints as text), pointers, arrays (`[N]T`); a slice (`[]T`, `str`) is a struct
// {ptr: *T, len: i64}; a tuple a struct with members _0, _1, ...; vec2..vec4 / quat a struct of
// f32 {x, y, z, w}, mat4 a struct {cols: [4]vec4}; a function value a pointer to a subroutine
// type; an enum without data an enumeration of 4 bytes; an enum with data a struct with the
// tag (an enumeration) and a variant part (DW_TAG_variant_part, discriminated by the tag): one
// variant per variant of the enum, whose member (named like the variant) is a struct of its
// payloads `_0`, `_1`, ... at their offsets in the enum. Vec, Map and the other library types
// are the structs they are.

priv const DW_TAG_array_type = 0x01
priv const DW_TAG_enumeration_type = 0x04
priv const DW_TAG_formal_parameter = 0x05
priv const DW_TAG_lexical_block = 0x0b
priv const DW_TAG_member = 0x0d
priv const DW_TAG_pointer_type = 0x0f
priv const DW_TAG_compile_unit = 0x11
priv const DW_TAG_structure_type = 0x13
priv const DW_TAG_subroutine_type = 0x15
priv const DW_TAG_subrange_type = 0x21
priv const DW_TAG_base_type = 0x24
priv const DW_TAG_enumerator = 0x28
priv const DW_TAG_subprogram = 0x2e
priv const DW_TAG_variable = 0x34
priv const DW_TAG_variant = 0x19
priv const DW_TAG_variant_part = 0x33

priv const DW_AT_location = 0x02
priv const DW_AT_name = 0x03
priv const DW_AT_byte_size = 0x0b
priv const DW_AT_stmt_list = 0x10
priv const DW_AT_low_pc = 0x11
priv const DW_AT_high_pc = 0x12
priv const DW_AT_language = 0x13
priv const DW_AT_discr = 0x15
priv const DW_AT_discr_value = 0x16
priv const DW_AT_comp_dir = 0x1b
priv const DW_AT_const_value = 0x1c
priv const DW_AT_producer = 0x25
priv const DW_AT_count = 0x37
priv const DW_AT_data_member_location = 0x38
priv const DW_AT_decl_file = 0x3a
priv const DW_AT_decl_line = 0x3b
priv const DW_AT_encoding = 0x3e
priv const DW_AT_external = 0x3f
priv const DW_AT_frame_base = 0x40
priv const DW_AT_type = 0x49
priv const DW_AT_ranges = 0x55
priv const DW_AT_artificial = 0x34

priv const DW_FORM_addr = 0x01
priv const DW_FORM_data2 = 0x05
priv const DW_FORM_data8 = 0x07
priv const DW_FORM_data1 = 0x0b
priv const DW_FORM_udata = 0x0f
priv const DW_FORM_strp = 0x0e
priv const DW_FORM_ref4 = 0x13
priv const DW_FORM_sec_offset = 0x17
priv const DW_FORM_exprloc = 0x18
priv const DW_FORM_flag_present = 0x19
priv const DW_FORM_sdata = 0x0d

// abbreviation codes (see abbrevs)
priv const AB_CU = 1
priv const AB_FN = 2
priv const AB_FN_VOID = 3
priv const AB_PARAM = 4
priv const AB_VAR = 5
priv const AB_BLOCK = 6
priv const AB_BASE = 7
priv const AB_PTR = 8
priv const AB_PTR_VOID = 9
priv const AB_STRUCT = 10
priv const AB_MEMBER = 11
priv const AB_ARRAY = 12
priv const AB_SUBRANGE = 13
priv const AB_ENUM = 14
priv const AB_ENUMERATOR = 15
priv const AB_SUBR = 16
priv const AB_SUBR_VOID = 17
priv const AB_SUBR_PARAM = 18
priv const AB_STRUCT_EMPTY = 19
priv const AB_VARIANT_PART = 20
priv const AB_VARIANT = 21
priv const AB_TAG_MEMBER = 22
priv const AB_INLINED = 23

// the abbreviation table: (code, tag, children, [(attribute, form)])
priv fn abbrevs() -> Vec[u8] {
    a := vec[u8]()
    fn one(a: *Vec[u8], code: i64, tag: i64, kids: bool, attrs: []i64) {
        uleb(a, code)
        uleb(a, tag)
        a.push(if kids { u8(1) } else { u8(0) })
        for x in attrs {
            uleb(a, x)
        }
        a.push(0)
        a.push(0)
    }
    one(&a, AB_CU, DW_TAG_compile_unit, true, []i64{DW_AT_producer, DW_FORM_strp, DW_AT_language, DW_FORM_data2, DW_AT_name, DW_FORM_strp,
        DW_AT_comp_dir, DW_FORM_strp, DW_AT_low_pc, DW_FORM_addr, DW_AT_high_pc, DW_FORM_data8, DW_AT_stmt_list, DW_FORM_sec_offset})
    fn_attrs := []i64{DW_AT_name, DW_FORM_strp, DW_AT_low_pc, DW_FORM_addr, DW_AT_high_pc, DW_FORM_data8, DW_AT_frame_base, DW_FORM_exprloc,
        DW_AT_decl_file, DW_FORM_udata, DW_AT_decl_line, DW_FORM_udata, DW_AT_external, DW_FORM_flag_present}
    with_type := vec_of(fn_attrs)
    with_type.extend([]i64{DW_AT_type, DW_FORM_ref4})
    one(&a, AB_FN, DW_TAG_subprogram, true, with_type.items())
    one(&a, AB_FN_VOID, DW_TAG_subprogram, true, fn_attrs)
    var_attrs := []i64{DW_AT_name, DW_FORM_strp, DW_AT_decl_file, DW_FORM_udata, DW_AT_decl_line, DW_FORM_udata, DW_AT_type, DW_FORM_ref4, DW_AT_location, DW_FORM_exprloc}
    one(&a, AB_PARAM, DW_TAG_formal_parameter, false, var_attrs)
    one(&a, AB_VAR, DW_TAG_variable, false, var_attrs)
    one(&a, AB_BLOCK, DW_TAG_lexical_block, true, []i64{DW_AT_ranges, DW_FORM_sec_offset})
    one(&a, AB_BASE, DW_TAG_base_type, false, []i64{DW_AT_name, DW_FORM_strp, DW_AT_encoding, DW_FORM_data1, DW_AT_byte_size, DW_FORM_data1})
    one(&a, AB_PTR, DW_TAG_pointer_type, false, []i64{DW_AT_byte_size, DW_FORM_data1, DW_AT_type, DW_FORM_ref4})
    one(&a, AB_PTR_VOID, DW_TAG_pointer_type, false, []i64{DW_AT_byte_size, DW_FORM_data1})
    one(&a, AB_STRUCT, DW_TAG_structure_type, true, []i64{DW_AT_name, DW_FORM_strp, DW_AT_byte_size, DW_FORM_udata})
    one(&a, AB_MEMBER, DW_TAG_member, false, []i64{DW_AT_name, DW_FORM_strp, DW_AT_type, DW_FORM_ref4, DW_AT_data_member_location, DW_FORM_udata})
    one(&a, AB_ARRAY, DW_TAG_array_type, true, []i64{DW_AT_type, DW_FORM_ref4})
    one(&a, AB_SUBRANGE, DW_TAG_subrange_type, false, []i64{DW_AT_type, DW_FORM_ref4, DW_AT_count, DW_FORM_udata})
    one(&a, AB_ENUM, DW_TAG_enumeration_type, true, []i64{DW_AT_name, DW_FORM_strp, DW_AT_type, DW_FORM_ref4, DW_AT_byte_size, DW_FORM_data1})
    one(&a, AB_ENUMERATOR, DW_TAG_enumerator, false, []i64{DW_AT_name, DW_FORM_strp, DW_AT_const_value, DW_FORM_udata})
    one(&a, AB_SUBR, DW_TAG_subroutine_type, true, []i64{DW_AT_type, DW_FORM_ref4})
    one(&a, AB_SUBR_VOID, DW_TAG_subroutine_type, true, nil)
    one(&a, AB_SUBR_PARAM, DW_TAG_formal_parameter, false, []i64{DW_AT_type, DW_FORM_ref4})
    one(&a, AB_STRUCT_EMPTY, DW_TAG_structure_type, false, []i64{DW_AT_name, DW_FORM_strp, DW_AT_byte_size, DW_FORM_udata})
    one(&a, AB_VARIANT_PART, DW_TAG_variant_part, true, []i64{DW_AT_discr, DW_FORM_ref4})
    one(&a, AB_VARIANT, DW_TAG_variant, true, []i64{DW_AT_discr_value, DW_FORM_udata})
    one(&a, AB_TAG_MEMBER, DW_TAG_member, false, []i64{DW_AT_name, DW_FORM_strp, DW_AT_type, DW_FORM_ref4, DW_AT_data_member_location, DW_FORM_udata,
        DW_AT_artificial, DW_FORM_flag_present})
    one(&a, AB_INLINED, 0x1d, true, []i64{DW_AT_name, DW_FORM_strp, 0x58, DW_FORM_udata, 0x59, DW_FORM_udata, DW_AT_ranges, DW_FORM_sec_offset})
    a.push(0)
    return a
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

priv fn sleb(v: *Vec[u8], x0: i64) {
    x := x0
    loop {
        b := u8(x & 0x7F)
        x = x >> 7
        if (x == 0 && b & 0x40 == 0) || (x == -1 && b & 0x40 != 0) {
            v.push(b)
            return
        }
        v.push(b | 0x80)
    }
}

priv struct Dw {
    m: *Module
    types: *Types
    windows: bool
    info: Vec[u8]
    strs: Vec[u8]
    str_ix: Map[str, i64]
    ranges: Vec[u8]
    text_lo: i64
    // types: the DIE offset of each type (by type id, -1: not yet written), the types still to
    // write, and the references to types to fill in (position in info, type)
    tdie: Vec[i64]
    tqueue: Vec[i64]
    tfix: Vec[(i64, i64)]
    // the DWARF file number of each source file (0: not in the line table yet), and the files
    // in the order of their numbers
    fnum: Vec[i64]
    files: Vec[i64]
}

// the offset of string s in .debug_str (each string once)
priv fn strp(d: *Dw, s: str) {
    o, found := d.str_ix.get(s)
    if !found {
        o = d.strs.len
        d.strs.extend(s)
        d.strs.push(0)
        d.str_ix.set(s, o)
    }
    put32(&d.info, o)
}

// a reference to the DIE of type t (filled in when all types are written)
priv fn tref(d: *Dw, t: i64) {
    if d.tdie.len <= t {
        // (a type made while writing: the array of a mat4, the pointer of a slice)
        d.tdie.resize(t + 1, -1)
    }
    if d.tdie[t] == -1 {
        d.tdie[t] = -2
        d.tqueue.push(t)
    }
    d.tfix.push((d.info.len, t))
    put32(&d.info, 0)
}

// does type t have a DIE (unit and never are void)?
priv fn has_die(t: i64) -> bool {
    return t > T_ERR && t != T_UNIT && t != T_NEVER
}

// the DWARF file number of source file k (1, 2, ...)
priv fn file_num(d: *Dw, k: i64) -> i64 {
    if k < 0 {
        return 0
    }
    if d.fnum.len <= k {
        d.fnum.resize(k + 1, 0)
    }
    if d.fnum[k] == 0 {
        d.files.push(k)
        d.fnum[k] = d.files.len
    }
    return d.fnum[k]
}

// ---------- types ----------

priv fn base(d: *Dw, name: str, enc: i64, size: i64) {
    uleb(&d.info, AB_BASE)
    strp(d, name)
    d.info.push(u8(enc))
    d.info.push(u8(size))
}

priv fn member(d: *Dw, name: str, t: i64, off: i64) {
    if !has_die(t) {
        return
    }
    uleb(&d.info, AB_MEMBER)
    strp(d, name)
    tref(d, t)
    uleb(&d.info, off)
}

// a struct of the members (name, type, offset)
priv fn struct_die(d: *Dw, name: str, size: i64, ms: [](str, i64, i64)) {
    any := false
    for x in ms {
        if has_die(x.1) {
            any = true
        }
    }
    uleb(&d.info, if any { AB_STRUCT } else { AB_STRUCT_EMPTY })
    strp(d, name)
    uleb(&d.info, size)
    if any {
        for x in ms {
            member(d, x.0, x.1, x.2)
        }
        d.info.push(0)
    }
}

// the members _0, _1, ... of the types tys at offsets offs
priv fn numbered(tys: []i64, offs: []i64) -> Vec[(str, i64, i64)] {
    ms := vec[(str, i64, i64)]()
    for i, t in tys {
        ms.push((fmt("_", i), t, offs[i]))
    }
    return ms
}

// the DIE of type t at the end of .debug_info
priv fn type_die(d: *Dw, t: i64) {
    ty := d.types
    d.tdie[t] = d.info.len
    match ty.k(t) {
        Bool => base(d, "bool", 2, 1)
        Int(b, s) => base(d, ty.name(t), if b == 8 { if s { 6 } else { 8 } } else if s { 5 } else { 7 }, b / 8)
        F64 => base(d, "f64", 4, 8)
        F32 => base(d, "f32", 4, 4)
        Vec(n) => {
            ms := vec[(str, i64, i64)]()
            for k in 0..n {
                ms.push(("xyzw"[k..k + 1], T_F32, 4 * k))
            }
            struct_die(d, ty.name(t), 4 * n, ms.items())
        }
        Quat => struct_die(d, "quat", 16, [](str, i64, i64){("x", T_F32, 0), ("y", T_F32, 4), ("z", T_F32, 8), ("w", T_F32, 12)})
        Mat4 => struct_die(d, "mat4", 64, [](str, i64, i64){("cols", ty.intern(Array(T_VEC4, 4)), 0)})
        Ptr(e) => {
            if has_die(e) {
                uleb(&d.info, AB_PTR)
                d.info.push(8)
                tref(d, e)
            } else {
                uleb(&d.info, AB_PTR_VOID)
                d.info.push(8)
            }
        }
        Fn(ps, r) => {
            // a pointer to the subroutine type that follows it
            uleb(&d.info, AB_PTR)
            d.info.push(8)
            put32(&d.info, d.info.len + 4)
            uleb(&d.info, if has_die(r) { AB_SUBR } else { AB_SUBR_VOID })
            if has_die(r) {
                tref(d, r)
            }
            for p in ps {
                if has_die(p) {
                    uleb(&d.info, AB_SUBR_PARAM)
                    tref(d, p)
                }
            }
            d.info.push(0)
        }
        Slice(e) => struct_die(d, ty.name(t), 16, [](str, i64, i64){("ptr", ty.ptr_to(e), 0), ("len", T_I64, 8)})
        Array(e, n) => {
            if !has_die(e) {
                struct_die(d, ty.name(t), 0, nil)
                return
            }
            uleb(&d.info, AB_ARRAY)
            tref(d, e)
            uleb(&d.info, AB_SUBRANGE)
            tref(d, T_U64)
            uleb(&d.info, n)
            d.info.push(0)
        }
        Tuple(v) => {
            offs := ty.tuple_offsets(v.items())
            struct_die(d, ty.name(t), ty.size_of(t), numbered(v.items(), offs.items()).items())
        }
        Struct(s) => {
            ty.layout_struct(s)
            info := &ty.structs[s]
            ms := vec[(str, i64, i64)]()
            for i, f in info.fields {
                if i < info.offsets.len {
                    ms.push((f.0, f.1, info.offsets[i]))
                }
            }
            struct_die(d, ast_plain_text(info.name), info.size, ms.items())
        }
        Enum(e) => enum_die(d, t, e)
        _ => base(d, ty.name(t), 7, max(ty.size_of(t), 1))
    }
}

// the enumeration of the variants of enum e (the tag), with the name `name`
priv fn tag_enum(d: *Dw, e: i64, name: str) {
    info := &d.types.enums[e]
    uleb(&d.info, AB_ENUM)
    strp(d, name)
    tref(d, T_U32)
    d.info.push(4)
    for i, v in info.variants {
        uleb(&d.info, AB_ENUMERATOR)
        strp(d, v.0)
        uleb(&d.info, i)
    }
    d.info.push(0)
}

priv fn enum_die(d: *Dw, t: i64, e: i64) {
    ty := d.types
    ty.size_of(t)
    info := &ty.enums[e]
    name := ast_plain_text(info.name)
    if info.variants.is_empty() {
        struct_die(d, name, info.size, nil)
        return
    }
    if info.simple {
        tag_enum(d, e, name)
        return
    }
    // struct E { tag (artificial), variant part }; the tag's enumeration and the payload
    // structs follow the struct
    uleb(&d.info, AB_STRUCT)
    strp(d, name)
    uleb(&d.info, info.size)
    tag_at := d.info.len
    uleb(&d.info, AB_TAG_MEMBER)
    strp(d, "tag")
    tag_ty := d.info.len
    put32(&d.info, 0)
    uleb(&d.info, 0)
    uleb(&d.info, AB_VARIANT_PART)
    put32(&d.info, tag_at)
    // the payload struct of each variant: filled in below
    pay := vec[i64]()
    for i, v in info.variants {
        uleb(&d.info, AB_VARIANT)
        uleb(&d.info, i)
        uleb(&d.info, AB_MEMBER)
        strp(d, v.0)
        pay.push(d.info.len)
        put32(&d.info, 0)
        uleb(&d.info, 0)
        d.info.push(0)
    }
    d.info.push(0)
    d.info.push(0)
    set32(&d.info, tag_ty, d.info.len)
    tag_enum(d, e, fmt(name, ".tag"))
    for i, v in info.variants {
        set32(&d.info, pay[i], d.info.len)
        offs := ty.variant_offsets(e, i)
        struct_die(d, fmt(name, ".", v.0), info.size, numbered(v.1.items(), offs.items()).items())
    }
}

// ---------- functions ----------

// a location expression: DW_OP_fbreg off (and DW_OP_deref for an indirect variable)
priv fn var_loc(d: *Dw, off: i64, indirect: bool) {
    e := vec[u8]()
    e.push(0x91)
    sleb(&e, off)
    if indirect {
        e.push(0x06)
    }
    uleb(&d.info, e.len)
    d.info.extend(e.items())
}

priv fn var_die(d: *Dw, k: i64, off: i64) {
    v := &dbg_vars[k]
    uleb(&d.info, if v.param { AB_PARAM } else { AB_VAR })
    strp(d, v.name)
    fid := v.func
    uleb(&d.info, if fid < dbg_fn_file.len { file_num(d, i64(dbg_fn_file[fid])) } else { 0 })
    uleb(&d.info, i64(v.line))
    tref(d, v.ty)
    var_loc(d, off, v.indirect)
}

// the variables of scope s and its scopes as lexical blocks (rows: of a function at address
// `at` with `size` bytes); a scope without code is left out
priv fn scope_die(d: *Dw, sc: *Vec[DbgScope], s: i64, rows: *Vec[DbgRow], at: i64, size: i64) {
    for x in 0..sc[s].vars.len / 2 {
        var_die(d, sc[s].vars[2 * x], sc[s].vars[2 * x + 1])
    }
    for c in sc[s].kids {
        runs := dbg_runs(rows, size, sc[c].first, sc[c].last, 0, size)
        if runs.is_empty() {
            continue
        }
        uleb(&d.info, AB_BLOCK)
        put32(&d.info, d.ranges.len)
        for r in runs {
            put64(&d.ranges, at + r.0 - d.text_lo)
            put64(&d.ranges, at + r.1 - d.text_lo)
        }
        put64(&d.ranges, 0)
        put64(&d.ranges, 0)
        scope_die(d, sc, c, rows, at, size)
        d.info.push(0)
    }
}

// a function inlined into the code being described: the call it was inlined at (a location),
// the function, its code (runs of offsets) and the functions inlined into it
priv struct Inl {
    call: i64
    fid: i64
    runs: Vec[(i64, i64)]
    kids: Vec[i64]
}

// The functions inlined into a function at address `at` of `size` bytes, from the locations of
// its rows: a row of inlined code has a location whose chain of calls (SrcLoc.parent) leads
// out to a line of the function; each call of the chain is an inlined_subroutine (named like
// the function, with the call's file and line) whose ranges are the code of all such rows.
priv fn inlined(d: *Dw, rows: *Vec[DbgRow], at: i64, size: i64) {
    locs := &d.m.locs.list
    nodes := vec_one(Inl{call: 0, fid: -1})
    key := map[(i64, i64), i64]()
    chain := vec[(i64, i64)]()
    for k, r in *rows {
        if r.loc <= 0 || locs[r.loc].parent == 0 {
            continue
        }
        start := r.off
        end := if k + 1 < rows.len { rows[k + 1].off } else { size }
        if end <= start {
            continue
        }
        // the calls from the outside in: (call location, the function inlined there)
        chain.clear()
        l := r.loc
        while l > 0 && locs[l].parent != 0 && chain.len < 64 {
            chain.push((i64(locs[l].parent), i64(locs[l].func)))
            l = i64(locs[l].parent)
        }
        n := 0
        for i in chain.len - 1..=0 by -1 {
            c, f := chain[i]
            next, found := key.get((n, c))
            if !found {
                next = nodes.len
                nodes.push(Inl{call: c, fid: f})
                nodes[n].kids.push(next)
                key.set((n, c), next)
            }
            n = next
            runs := &nodes[n].runs
            if !runs.is_empty() && runs[runs.len - 1].1 == start {
                runs[runs.len - 1].1 = end
            } else {
                runs.push((start, end))
            }
        }
    }
    fn emit(d: *Dw, nodes: *Vec[Inl], n: i64, at: i64) {
        for c in nodes[n].kids {
            x := &nodes[c]
            cl := &d.m.locs.list[x.call]
            uleb(&d.info, AB_INLINED)
            strp(d, dbg_fn_name(d.m, x.fid))
            uleb(&d.info, file_num(d, i64(cl.file)))
            uleb(&d.info, i64(cl.line))
            put32(&d.info, d.ranges.len)
            for r in x.runs {
                put64(&d.ranges, at + r.0 - d.text_lo)
                put64(&d.ranges, at + r.1 - d.text_lo)
            }
            put64(&d.ranges, 0)
            put64(&d.ranges, 0)
            emit(d, nodes, c, at)
            d.info.push(0)
        }
    }
    emit(d, &nodes, 0, at)
}

// the subprogram of compiled function fid at address `at`
priv fn fn_die(d: *Dw, fid: i64, code: *Code, at: i64, rows: *Vec[DbgRow]) {
    m := d.m
    orig := dbg_fn_orig(m, fid)
    rty := if dbg_cx != nil && orig < dbg_cx.fn_sigs.len { dbg_cx.fn_sigs[orig].1 } else { T_UNIT }
    uleb(&d.info, if has_die(rty) { AB_FN } else { AB_FN_VOID })
    strp(d, dbg_fn_name(m, fid))
    put64(&d.info, at)
    put64(&d.info, code.bytes.len)
    // the frame base: the CFA (Linux), rsp + the frame (Windows)
    if d.windows {
        e := vec[u8]()
        e.push(0x77) // DW_OP_breg7 (rsp)
        sleb(&e, i64(code.alloc) + 8 * i64(code.npush) + 8)
        uleb(&d.info, e.len)
        d.info.extend(e.items())
    } else {
        uleb(&d.info, 1)
        d.info.push(0x9c) // DW_OP_call_frame_cfa
    }
    file := if orig < dbg_fn_file.len { i64(dbg_fn_file[orig]) } else { -1 }
    line := if orig < dbg_fn_line.len { i64(dbg_fn_line[orig]) } else { 0 }
    uleb(&d.info, file_num(d, file))
    uleb(&d.info, line)
    if has_die(rty) {
        tref(d, rty)
    }
    sc := dbg_scopes(code)
    scope_die(d, &sc, 0, rows, at, code.bytes.len)
    inlined(d, rows, at, code.bytes.len)
    d.info.push(0)
}

// ---------- the line table ----------

priv const LINE_BASE = -5
priv const LINE_RANGE = 14
priv const OPCODE_BASE = 13

// the line program of one function (a sequence) at address `at`
priv fn line_seq(d: *Dw, p: *Vec[u8], rows: *Vec[DbgRow], at: i64, size: i64) {
    if rows.is_empty() {
        return
    }
    p.push(0)
    uleb(p, 9)
    p.push(2) // DW_LNE_set_address
    put64(p, at)
    file := 1
    line := 1
    addr := 0
    for r in rows {
        f := file_num(d, r.file)
        if f != file && f > 0 {
            p.push(4) // DW_LNS_set_file
            uleb(p, f)
            file = f
        }
        dl := r.line - line
        da := r.off - addr
        if dl >= LINE_BASE && dl < LINE_BASE + LINE_RANGE && (dl - LINE_BASE) + LINE_RANGE * da + OPCODE_BASE <= 255 {
            p.push(u8((dl - LINE_BASE) + LINE_RANGE * da + OPCODE_BASE))
        } else {
            if dl != 0 {
                p.push(3) // DW_LNS_advance_line
                sleb(p, dl)
            }
            if da != 0 {
                p.push(2) // DW_LNS_advance_pc
                uleb(p, da)
            }
            p.push(1) // DW_LNS_copy
        }
        line = r.line
        addr = r.off
    }
    if size > addr {
        p.push(2)
        uleb(p, size - addr)
    }
    p.push(0)
    uleb(p, 1)
    p.push(1) // DW_LNE_end_sequence
}

priv fn line_table(d: *Dw, prog: *Vec[u8]) -> Vec[u8] {
    hdr := vec[u8]()
    hdr.push(1) // minimum_instruction_length
    hdr.push(1) // maximum_operations_per_instruction
    hdr.push(1) // default_is_stmt
    hdr.push(u8(i8(LINE_BASE)))
    hdr.push(u8(LINE_RANGE))
    hdr.push(u8(OPCODE_BASE))
    hdr.extend([]u8{0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1})
    hdr.push(0) // no include directories: the file names are as the program names them
    for k in d.files {
        name := dbg_file_name(k)
        hdr.extend(if len(name) == 0 { "?" } else { name })
        hdr.push(0)
        hdr.extend([]u8{0, 0, 0})
    }
    hdr.push(0)
    t := vec[u8]()
    put32(&t, 2 + 4 + hdr.len + prog.len)
    put16(&t, 4)
    put32(&t, hdr.len)
    t.extend(hdr.items())
    t.extend(prog.items())
    return t
}

// ---------- call frame information (.debug_frame) ----------

// the DWARF number of x86-64 register r (rax 0, rdx 1, rcx 2, rbx 3, rsi 4, rdi 5, rbp 6, rsp 7,
// r8.. 8..)
priv fn dwreg(r: i64) -> i64 {
    return match r {
        0 => 0
        1 => 2
        2 => 1
        3 => 3
        4 => 7
        5 => 6
        6 => 4
        7 => 5
        _ => r
    }
}

priv fn advance(p: *Vec[u8], from: *i64, to: i64) {
    d := to - *from
    if d <= 0 {
        return
    }
    if d < 64 {
        p.push(u8(0x40 | d)) // DW_CFA_advance_loc
    } else if d < 256 {
        p.push(0x02)
        p.push(u8(d))
    } else if d < 65536 {
        p.push(0x03)
        put16(p, d)
    } else {
        p.push(0x04)
        put32(p, d)
    }
    *from = to
}

priv fn def_cfa_offset(p: *Vec[u8], off: i64) {
    p.push(0x0e)
    uleb(p, off)
}

// the register that the push at bytes[k..] pushes and its length, or (-1, 0)
priv fn push_at(b: *Vec[u8], k: i64) -> (i64, i64) {
    if k < b.len && b[k] >= 0x50 && b[k] <= 0x57 {
        return (i64(b[k] - 0x50), 1)
    }
    if k + 1 < b.len && b[k] == 0x41 && b[k + 1] >= 0x50 && b[k + 1] <= 0x57 {
        return (8 + i64(b[k + 1] - 0x50), 2)
    }
    return (-1, 0)
}

// the FDE of a function: its prologue (the pushes, then `sub rsp`) and each epilogue (`add
// rsp`, the pops, `ret`: the state is remembered before and restored after it)
priv fn fde(f: *Vec[u8], at: i64, code: *Code) {
    p := vec[u8]()
    b := &code.bytes
    pos := 0
    k := 0
    regs := vec[i64]()
    for n in 0..i64(code.npush) {
        r, l := push_at(b, k)
        if r < 0 {
            break
        }
        k += l
        regs.push(r)
        advance(&p, &pos, k)
        def_cfa_offset(&p, 8 * (n + 2))
        p.push(u8(0x80 | dwreg(r))) // DW_CFA_offset r, n + 2 (times the data alignment -8)
        uleb(&p, n + 2)
    }
    full := 8 + 8 * i64(code.npush) + i64(code.alloc)
    if code.alloc >= 4096 && k + 22 <= b.len && b[k] == 0x41 && b[k + 1] == 0xBB {
        // the Windows stack probe (stack_probe in x86/emit.al): mov r11d, n; then n times
        // `sub rsp, 4096; test [rsp], rsp; dec r11; jnz`: the CFA is rsp + P + 4096 * (n - r11),
        // plus 4096 between the `sub` and the `dec` (P: the pushes and the return address)
        n := i64(code.alloc) / 4096
        pp := 8 + 8 * i64(code.npush)
        loop_at := k + 6
        fn cfa_expr(p: *Vec[u8], off: i64) {
            e := vec[u8]()
            e.push(0x77) // DW_OP_breg7 (rsp) off
            sleb(&e, off)
            e.extend([]u8{0x7b, 0}) // DW_OP_breg11 (r11) 0
            e.extend([]u8{0x0a, 0x00, 0x10}) // DW_OP_const2u 4096
            e.push(0x1e) // DW_OP_mul
            e.push(0x1c) // DW_OP_minus
            p.push(0x0f) // DW_CFA_def_cfa_expression
            uleb(p, e.len)
            p.extend(e.items())
        }
        advance(&p, &pos, loop_at)
        cfa_expr(&p, pp + 4096 * n)
        advance(&p, &pos, loop_at + 7)
        cfa_expr(&p, pp + 4096 * n + 4096)
        advance(&p, &pos, loop_at + 14)
        cfa_expr(&p, pp + 4096 * n)
        x := loop_at + 16
        advance(&p, &pos, x)
        p.extend([]u8{0x0c, 7}) // DW_CFA_def_cfa rsp, P + 4096 n
        uleb(&p, pp + 4096 * n)
        if i64(code.alloc) % 4096 != 0 && x + 1 < b.len {
            // sub rsp, the rest (imm8: 4 bytes, imm32: 7)
            advance(&p, &pos, x + if b[x + 1] == 0x83 { 4 } else { 7 })
            def_cfa_offset(&p, full)
        }
    } else if code.alloc > 0 {
        advance(&p, &pos, i64(code.alloc_end))
        def_cfa_offset(&p, full)
    }
    for e in 0..code.epis.len / 2 {
        start := i64(code.epis[2 * e])
        ret := i64(code.epis[2 * e + 1])
        if start < pos || ret >= b.len {
            continue
        }
        advance(&p, &pos, start)
        p.push(0x0a) // DW_CFA_remember_state
        x := start
        if code.alloc > 0 {
            // add rsp, imm8 (4 bytes) or imm32 (7)
            x += if x + 1 < b.len && b[x + 1] == 0x83 { 4 } else { 7 }
            advance(&p, &pos, x)
            def_cfa_offset(&p, 8 + 8 * i64(code.npush))
        }
        for y in regs.len - 1..=0 by -1 {
            // (pop: 0x58 + r, or 0x41 0x58 + r)
            x += if b[x] == 0x41 { 2 } else { 1 }
            advance(&p, &pos, x)
            def_cfa_offset(&p, 8 + 8 * y)
            p.push(u8(0xc0 | dwreg(regs[y]))) // DW_CFA_restore
        }
        if ret + 1 < b.len {
            advance(&p, &pos, ret + 1)
            p.push(0x0b) // DW_CFA_restore_state
        }
    }
    while (4 + 8 + 8 + p.len) % 8 != 0 {
        p.push(0) // DW_CFA_nop
    }
    put32(f, 4 + 8 + 8 + p.len)
    put32(f, 0) // the CIE at offset 0
    put64(f, at)
    put64(f, b.len)
    f.extend(p.items())
}

// the CIE (code alignment 1, data alignment -8, return address rip; at the entry the CFA is
// rsp + 8 and the return address is at CFA - 8), then FDEs
priv fn frame_cie() -> Vec[u8] {
    c := vec[u8]()
    put32(&c, 0xffffffff) // CIE id
    c.push(1) // version
    c.push(0) // augmentation ""
    uleb(&c, 1)
    sleb(&c, -8)
    c.push(16) // return address register: rip
    c.extend([]u8{0x0c, 7, 8}) // DW_CFA_def_cfa rsp, 8
    c.extend([]u8{0x80 | 16, 1}) // DW_CFA_offset rip, 1
    while (4 + c.len) % 8 != 0 {
        c.push(0)
    }
    f := vec[u8]()
    put32(&f, c.len)
    f.extend(c.items())
    return f
}

// ---------- the sections ----------

// The DWARF sections of the program whose functions are at func_addr (by function), in the
// code section from text_lo to text_hi. start_at >= 0 (ELF): the address of the start code
// (10 bytes before the functions), whose frame ends the stack.
fn dwarf_sections(m: *Module, out: *Output, func_addr: *Vec[i64], text_lo: i64, text_hi: i64, start_at: i64, windows: bool) -> Vec[(str, Vec[u8])] {
    d := Dw{m: m, types: &dbg_cx.types, windows: windows, text_lo: text_lo, tdie: vec_fill(dbg_cx.types.kinds.len, -1)}
    // the compile unit
    put32(&d.info, 0) // unit_length (below)
    put16(&d.info, 4)
    put32(&d.info, 0) // abbreviations
    d.info.push(8)
    uleb(&d.info, AB_CU)
    strp(&d, "alc (the AL compiler)")
    put16(&d.info, 0x0c) // DW_LANG_C99
    strp(&d, dbg_file_name(dbg_main_file))
    strp(&d, __os_current_dir())
    put64(&d.info, text_lo)
    put64(&d.info, text_hi - text_lo)
    put32(&d.info, 0) // the line table at offset 0 of .debug_line
    prog := vec[u8]()
    frame := frame_cie()
    if start_at >= 0 {
        // the start code: the outermost frame (the return address is undefined)
        p := []u8{0x07, 16, 0, 0, 0, 0} // DW_CFA_undefined rip, nops
        put32(&frame, 4 + 8 + 8 + len(p))
        put32(&frame, 0)
        put64(&frame, start_at)
        put64(&frame, 10)
        frame.extend(p)
    }
    for c in out.funcs {
        at := func_addr[c.fid]
        rows := dbg_rows(m, c.fid, &c.code)
        line_seq(&d, &prog, &rows, at, c.code.bytes.len)
        fn_die(&d, c.fid, &c.code, at, &rows)
        fde(&frame, at, &c.code)
    }
    // the types the functions refer to, and the ones those refer to
    qi := 0
    while qi < d.tqueue.len {
        t := d.tqueue[qi]
        qi += 1
        if d.tdie[t] == -2 {
            type_die(&d, t)
        }
    }
    for x in d.tfix {
        set32(&d.info, x.0, d.tdie[x.1])
    }
    d.info.push(0)
    set32(&d.info, 0, d.info.len - 4)
    aranges := vec[u8]()
    put32(&aranges, 0)
    put16(&aranges, 2)
    put32(&aranges, 0)
    aranges.push(8)
    aranges.push(0)
    put32(&aranges, 0) // (padding: the tuples are aligned to 16)
    put64(&aranges, text_lo)
    put64(&aranges, text_hi - text_lo)
    put64(&aranges, 0)
    put64(&aranges, 0)
    set32(&aranges, 0, aranges.len - 4)
    secs := vec[(str, Vec[u8])]()
    secs.push((".debug_abbrev", abbrevs()))
    secs.push((".debug_info", d.info))
    secs.push((".debug_line", line_table(&d, &prog)))
    secs.push((".debug_str", d.strs))
    secs.push((".debug_aranges", aranges))
    if !d.ranges.is_empty() {
        secs.push((".debug_ranges", d.ranges))
    }
    secs.push((".debug_frame", frame))
    return secs
}
