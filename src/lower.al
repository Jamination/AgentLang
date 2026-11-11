// Semantic analysis + lowering context: declarations, type resolution, constants, globals, instances.

struct Opts {
    checks bool
}

enum CV {
    CVInt(i64),
    CVFloat(f64),
    CVBool(bool),
    CVStr(str),
}

enum CState {
    CStateBusy,
    CStateDone(Opt[i64], CV),
    CStateFailed,
}

enum ParamAbi {
    ParamAbiScalar(T),
    ParamAbiFlat(Vec[Leaf]),
    ParamAbiByRef,
}

enum RetAbi {
    RetAbiNone,
    RetAbiScalar(T),
    RetAbiFlat(Vec[Leaf]),
    RetAbiSRet,
}

const MAX_FLAT = 4

struct Cx {
    types Types
    module Module
    errs Vec[Diag]
    opts Opts
    file_names Vec[str]
    fn_decls Vec[*FnDecl]
    fn_names Map[str, i64]
    struct_decls Vec[*StructDecl]
    struct_names Map[str, i64]
    enum_decls Vec[*EnumDecl]
    enum_names Map[str, i64]
    variants Map[str, (i64, i64)]
    const_decls Map[str, *ConstDecl]
    const_vals Map[str, CState]
    global_decls Map[str, *GlobalDecl]
    globals Map[str, (i64, i64)]
    // instance tables: the key is (declaration index, type arguments as a slice that is never
    // modified afterwards)
    struct_insts Map[(i64, []i64), i64]
    enum_insts Map[(i64, []i64), i64]
    fn_insts Map[(i64, []i64), i64]
    fn_sigs Vec[(Vec[i64], i64)]
    work Vec[(i64, i64, Vec[i64])]
    strings Map[str, i64]
    exposed Map[i64, bool]
    inst_depth i64
    // names declared by the prelude: prelude code always sees these, user code may shadow them
    p_fn_names Map[str, i64]
    // every definition of a function name (overloads), per layer, in declaration order
    fn_over Map[str, Vec[i64]]
    p_fn_over Map[str, Vec[i64]]
    p_struct_names Map[str, i64]
    p_enum_names Map[str, i64]
    // true while resolving names on behalf of prelude code
    scope_prelude bool
    entry_file i64
    // files whose declarations are only checked when something uses them
    lazy_files Map[i64, bool]
    n_prelude i64
    // written name -> position of a `priv` declaration of it in some file (for the hint of
    // "unknown name" diagnostics)
    priv_decls Map[str, Pos]
}

// for "unknown name" diagnostics: says that `n` exists as a private declaration of another file
fn priv_hint(self *Cx, n str) str {
    pos, found := self.priv_decls.get(n)
    if !found {
        return ""
    }
    var fname str = "?"
    if pos.file >= 0 && pos.file < self.file_names.len {
        fname = self.file_names.buf[pos.file]
    }
    return fmt(" (`", n, "` is declared `priv` in ", fname, ", line ", pos.line, ": a private declaration is visible only inside its own file; remove `priv` there to use it from other files)")
}

fn lower_builtin_type(name str) Opt[i64] {
    match name {
        "i8" => return Some(T_I8)
        "i16" => return Some(T_I16)
        "i32" => return Some(T_I32)
        "i64" => return Some(T_I64)
        "u8" => return Some(T_U8)
        "u16" => return Some(T_U16)
        "u32" => return Some(T_U32)
        "u64" => return Some(T_U64)
        "f64" => return Some(T_F64)
        "f32" => return Some(T_F32)
        "vec2" => return Some(T_VEC2)
        "vec3" => return Some(T_VEC3)
        "vec4" => return Some(T_VEC4)
        "quat" => return Some(T_QUAT)
        "mat4" => return Some(T_MAT4)
        "bool" => return Some(T_BOOL)
        "str" => return Some(T_STR)
        "never" => return Some(T_NEVER)
        _ => {}
    }
    return None
}

// the value of an optional type, or `d`
fn lower_opt_or(o Opt[i64], d i64) i64 {
    match o {
        Some(t) => return t
        None => return d
    }
}

// `f as i64` of the Rust source: saturating, NaN gives 0
fn lower_f64_to_i64(f f64) i64 {
    if f != f {
        return 0
    }
    if f >= 9223372036854775808.0 {
        return 0x7FFFFFFFFFFFFFFF
    }
    if f <= -9223372036854775808.0 {
        return -0x7FFFFFFFFFFFFFFF - 1
    }
    return i64(f)
}

// the low `n` bytes of `x`, little-endian, into `data` at `off`
fn lower_put_le(data *Vec[u8], off i64, x u64, n i64) {
    for j in 0..n {
        data.buf[off + j] = u8(x >> u64(8 * j))
    }
}

// parameter types of a function declaration as text (to detect duplicate overloads)
fn lower_new_sig(g *FnDecl) str {
    parts := vec[str]()
    for i in 0..g.params.len {
        parts.push(ast_type_str(&g.params.buf[i].1))
    }
    return join(parts.items(), ",")
}

// files with an index below `n_prelude` form the always-present core library
fn cx_new(decls []Decl, file_names Vec[str], opts Opts, n_prelude i64) Cx {
    np := n_prelude
    cx := Cx{
        n_prelude: n_prelude,
        types: types_new(),
        module: Module{funcs: vec[Func](), globals: vec[Global](), entry: 0, externs: vec[ExternFn]()},
        errs: vec[Diag](),
        opts: opts,
        file_names: file_names,
        fn_decls: vec[*FnDecl](),
        fn_names: map[str, i64](),
        struct_decls: vec[*StructDecl](),
        struct_names: map[str, i64](),
        enum_decls: vec[*EnumDecl](),
        enum_names: map[str, i64](),
        variants: map[str, (i64, i64)](),
        const_decls: map[str, *ConstDecl](),
        const_vals: map[str, CState](),
        global_decls: map[str, *GlobalDecl](),
        globals: map[str, (i64, i64)](),
        struct_insts: map[(i64, []i64), i64](),
        enum_insts: map[(i64, []i64), i64](),
        fn_insts: map[(i64, []i64), i64](),
        fn_sigs: vec[(Vec[i64], i64)](),
        work: vec[(i64, i64, Vec[i64])](),
        strings: map[str, i64](),
        exposed: map[i64, bool](),
        inst_depth: 0,
        p_fn_names: map[str, i64](),
        fn_over: map[str, Vec[i64]](),
        p_fn_over: map[str, Vec[i64]](),
        p_struct_names: map[str, i64](),
        p_enum_names: map[str, i64](),
        scope_prelude: false,
        entry_file: 0xFFFF,
        lazy_files: map[i64, bool](),
        priv_decls: map[str, Pos](),
    }
    names := map[str, Pos]()
    // is the visible declaration of a name a function?
    names_fn := map[str, bool]()
    for i in 0..len(decls) {
        var name str
        var pos Pos
        // 1 = fn, 2 = struct, 3 = enum, 4 = const, 5 = global
        kind := 0
        // the declarations are copied to the heap once: the context keeps pointers to them
        var fp *FnDecl
        var sp *StructDecl
        var ep *EnumDecl
        var cp *ConstDecl
        var gp *GlobalDecl
        match decls[i] {
            DeclFn(f) => {
                fp = new[FnDecl]()
                *fp = f
                name = f.name
                pos = f.pos
                kind = 1
            }
            DeclStruct(s) => {
                sp = new[StructDecl]()
                *sp = s
                name = s.name
                pos = s.pos
                kind = 2
            }
            DeclEnum(e) => {
                ep = new[EnumDecl]()
                *ep = e
                name = e.name
                pos = e.pos
                kind = 3
            }
            DeclConst(c) => {
                cp = new[ConstDecl]()
                *cp = c
                name = c.name
                pos = c.pos
                kind = 4
            }
            DeclGlobal(g) => {
                gp = new[GlobalDecl]()
                *gp = g
                name = g.name
                pos = g.pos
                kind = 5
            }
            _ => {}
        }
        if kind == 0 {
            continue
        }
        if is_some(lower_builtin_type(name)) {
            cx.err(pos, fmt("`", name, "` is a builtin type name"))
            continue
        }
        if ast_is_private(name) && !cx.priv_decls.has(ast_plain(name)) {
            cx.priv_decls.set(ast_plain(name), pos)
        }
        prev, has_prev := names.get(name)
        if has_prev {
            was_fn, was_known := names_fn.get(name)
            if kind == 1 && was_known && was_fn {
                // another definition of a function name: an overload, chosen by argument type
                var l Vec[i64]
                has_layer := false
                if pos.file < np {
                    l, has_layer = cx.p_fn_over.get(name)
                } else {
                    l, has_layer = cx.fn_over.get(name)
                }
                dup := -1
                if has_layer {
                    for k in 0..l.len {
                        if lower_new_sig(cx.fn_decls.buf[l.buf[k]]) == lower_new_sig(fp) {
                            dup = l.buf[k]
                            break
                        }
                    }
                }
                if dup >= 0 {
                    at := cx.pos_str(cx.fn_decls.buf[dup].pos)
                    cx.err(pos, fmt("`", name, "` is already declared with these parameter types at ", at))
                    continue
                }
            } else if prev.file < np && pos.file >= np {
                // a user declaration shadows a prelude declaration of the same name; types
                // and values are looked up separately, so a function does not hide a type
                if kind == 2 || kind == 3 {
                    cx.struct_names.del(name)
                    cx.enum_names.del(name)
                } else {
                    cx.fn_names.del(name)
                    cx.const_decls.del(name)
                    cx.global_decls.del(name)
                }
            } else {
                at := cx.pos_str(prev)
                cx.err(pos, fmt("`", name, "` is already declared at ", at))
                continue
            }
        }
        names.set(name, pos)
        names_fn.set(name, kind == 1)
        if kind == 1 {
            di := cx.fn_decls.len
            if pos.file < np {
                if !cx.p_fn_names.has(name) {
                    cx.p_fn_names.set(name, di)
                }
                l, has_l := cx.p_fn_over.get(name)
                if !has_l {
                    l = vec[i64]()
                }
                l.push(di)
                cx.p_fn_over.set(name, l)
                if !cx.fn_names.has(name) {
                    cx.fn_names.set(name, di)
                }
            } else {
                // the first user definition is what the plain name refers to
                if !cx.fn_over.has(name) {
                    cx.fn_names.set(name, di)
                }
                l, has_l := cx.fn_over.get(name)
                if !has_l {
                    l = vec[i64]()
                }
                l.push(di)
                cx.fn_over.set(name, l)
            }
            cx.fn_decls.push(fp)
        } else if kind == 2 {
            if pos.file < np {
                cx.p_struct_names.set(name, cx.struct_decls.len)
            }
            cx.struct_names.set(name, cx.struct_decls.len)
            cx.struct_decls.push(sp)
        } else if kind == 3 {
            if pos.file < np {
                cx.p_enum_names.set(name, cx.enum_decls.len)
            }
            cx.enum_names.set(name, cx.enum_decls.len)
            cx.enum_decls.push(ep)
        } else if kind == 4 {
            cx.const_decls.set(name, cp)
        } else {
            cx.global_decls.set(name, gp)
        }
    }
    // enum variants live in the global namespace
    for ei in 0..cx.enum_decls.len {
        e := cx.enum_decls.buf[ei]
        for vi in 0..e.variants.len {
            vn := e.variants.buf[vi].0
            if names.has(vn) || cx.variants.has(vn) {
                cx.err(e.pos, fmt("enum variant `", vn, "` conflicts with another declaration"))
                continue
            }
            cx.variants.set(vn, (ei, vi))
        }
    }
    return cx
}

fn find_fn(self *Cx, n str) Opt[i64] {
    if self.scope_prelude {
        i, ok := self.p_fn_names.get(n)
        if ok {
            return Some(i)
        }
    }
    i, ok := self.fn_names.get(n)
    if ok {
        return Some(i)
    }
    return None
}

// all definitions a call to `n` may resolve to: user definitions first, then the prelude's
fn fn_candidates(self *Cx, n str) Vec[i64] {
    v := self.fn_candidates_of(n)
    // a private function (see priv.al): the public definitions of the written name follow
    if v.len != 0 && ast_is_private(n) {
        more := self.fn_candidates_of(ast_plain(n))
        v.extend(more.items())
    }
    return v
}

fn fn_candidates_of(self *Cx, n str) Vec[i64] {
    v := vec[i64]()
    if self.scope_prelude {
        // prelude code sees its own definitions; the synthesized entry also reaches user code
        pl, pok := self.p_fn_over.get(n)
        if pok {
            return clone(pl)
        }
        ul, uok := self.fn_over.get(n)
        if uok {
            return clone(ul)
        }
        return v
    }
    if !self.fn_names.has(n) {
        return v
    }
    l, ok := self.fn_over.get(n)
    if ok {
        v.extend(l.items())
    }
    l2, ok2 := self.p_fn_over.get(n)
    if ok2 {
        v.extend(l2.items())
    }
    return v
}

fn find_struct(self *Cx, n str) Opt[i64] {
    if self.scope_prelude {
        i, ok := self.p_struct_names.get(n)
        if ok {
            return Some(i)
        }
    }
    i, ok := self.struct_names.get(n)
    if ok {
        return Some(i)
    }
    return None
}

fn find_enum(self *Cx, n str) Opt[i64] {
    if self.scope_prelude {
        i, ok := self.p_enum_names.get(n)
        if ok {
            return Some(i)
        }
    }
    i, ok := self.enum_names.get(n)
    if ok {
        return Some(i)
    }
    return None
}

fn internal_file(self *Cx, file i64) bool {
    return file < self.n_prelude || file == self.entry_file
}

fn pos_str(self *Cx, p Pos) str {
    var fname str = "?"
    if p.file >= 0 && p.file < self.file_names.len {
        fname = self.file_names.buf[p.file]
    }
    return fmt(fname, ":", p.line, ":", p.col)
}

fn err(self *Cx, pos Pos, msg str) {
    self.errs.push(Diag{pos: pos, msg: msg})
}

// ---------- types ----------
fn resolve(self *Cx, t *TypeAst, env *Map[str, i64]) i64 {
    match *t {
        TypeAstName(n, args, pos) => {
            if args.is_empty() {
                et, eok := env.get(n)
                if eok {
                    return et
                }
                match lower_builtin_type(n) {
                    Some(bt) => return bt
                    None => {}
                }
            }
            targs := vec[i64]()
            for i in 0..args.len {
                targs.push(self.resolve(&args.buf[i], env))
            }
            if contains(&targs, T_ERR) {
                return T_ERR
            }
            match self.find_struct(n) {
                Some(si) => return self.inst_struct(si, targs, pos)
                None => {}
            }
            match self.find_enum(n) {
                Some(ei) => return self.inst_enum(ei, targs, pos)
                None => {}
            }
            hint := match n {
                "int", "long", "isize", "usize", "uint", "size_t" => " (integer types are i8 i16 i32 i64 u8 u16 u32 u64; the default is i64)"
                "float", "double", "f32" => " (the floating-point type is f64)"
                "string", "String", "char", "byte" => " (text is `str`, a byte is `u8`)"
                "boolean" => " (use `bool`)"
                "void" => " (omit the result type instead)"
                _ => ""
            }
            self.err(pos, fmt("unknown type `", n, "`", hint, self.priv_hint(n)))
            return T_ERR
        }
        TypeAstPtr(e) => {
            et := self.resolve(e, env)
            if et == T_ERR {
                return T_ERR
            }
            return self.types.ptr_to(et)
        }
        TypeAstSlice(e) => {
            et := self.resolve(e, env)
            if et == T_ERR {
                return T_ERR
            }
            return self.types.slice(et)
        }
        TypeAstArray(n, e) => {
            e2 := self.resolve(e, env)
            ln := -1
            match self.const_eval(n) {
                Some(cv) => {
                    match cv {
                        CVInt(v) => {
                            if v >= 0 {
                                ln = v
                            }
                        }
                        _ => {}
                    }
                }
                None => {}
            }
            if ln < 0 {
                self.err(n.pos, "array length must be a non-negative integer constant")
                return T_ERR
            }
            if e2 == T_ERR {
                return T_ERR
            }
            es := self.types.size_of(e2)
            // es * ln > 2^31 without overflow (a saturating multiplication in the Rust source)
            if es > 0 && ln > (1 << 31) / es {
                self.err(n.pos, "array type too large (max 2 GiB)")
                return T_ERR
            }
            return self.types.intern(TyKArray(e2, ln))
        }
        TypeAstFn(ps, r) => {
            pts := vec[i64]()
            for i in 0..ps.len {
                pts.push(self.resolve(&ps.buf[i], env))
            }
            rt := T_UNIT
            match r {
                Some(rr) => {
                    rt = self.resolve(rr, env)
                }
                None => {}
            }
            if contains(&pts, T_ERR) || rt == T_ERR {
                return T_ERR
            }
            return self.types.intern(TyKFn(pts, rt))
        }
        TypeAstTuple(ts) => {
            tys := vec[i64]()
            for i in 0..ts.len {
                tys.push(self.resolve(&ts.buf[i], env))
            }
            if contains(&tys, T_ERR) {
                return T_ERR
            }
            if tys.is_empty() {
                return T_UNIT
            }
            return self.types.intern(TyKTuple(tys))
        }
    }
    return T_ERR
}

fn inst_name(self *Cx, base str, targs []i64) str {
    if len(targs) == 0 {
        return base
    }
    parts := vec[str]()
    for t in targs {
        parts.push(self.types.name(t))
    }
    return fmt(base, "[", join(parts.items(), ", "), "]")
}

fn inst_struct(self *Cx, si i64, targs Vec[i64], pos Pos) i64 {
    d := self.struct_decls.buf[si]
    if d.tparams.len != targs.len {
        self.err(pos, fmt("struct `", d.name, "` expects ", d.tparams.len, " type argument(s), got ", targs.len))
        return T_ERR
    }
    known, found := self.struct_insts.get((si, targs.items()))
    if found {
        return known
    }
    sid := self.types.structs.len
    name := self.inst_name(ast_plain(d.name), targs.items())
    self.types.structs.push(StructInfo{
        name: name,
        decl: si,
        targs: clone(targs),
        fields: vec[(str, i64)](),
        offsets: vec[i64](),
        size: 0,
        align: 1,
        state: 0,
    })
    ty := self.types.intern(TyKStruct(sid))
    self.struct_insts.set((si, clone(targs).items()), ty)
    env := map[str, i64]()
    for i in 0..min(d.tparams.len, targs.len) {
        env.set(d.tparams.buf[i], targs.buf[i])
    }
    fields := vec[(str, i64)]()
    seen := map[str, bool]()
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    for i in 0..d.fields.len {
        fname := d.fields.buf[i].0
        if seen.has(fname) {
            self.err(d.pos, fmt("duplicate field `", fname, "` in struct `", d.name, "`"))
        } else {
            seen.set(fname, true)
        }
        t := self.resolve(&d.fields.buf[i].1, &env)
        fields.push((fname, t))
    }
    self.scope_prelude = save_scope
    self.types.structs.buf[sid].fields = fields
    return ty
}

fn inst_enum(self *Cx, ei i64, targs Vec[i64], pos Pos) i64 {
    d := self.enum_decls.buf[ei]
    if d.tparams.len != targs.len {
        self.err(pos, fmt("enum `", d.name, "` expects ", d.tparams.len, " type argument(s), got ", targs.len))
        return T_ERR
    }
    known, found := self.enum_insts.get((ei, targs.items()))
    if found {
        return known
    }
    eid := self.types.enums.len
    name := self.inst_name(ast_plain(d.name), targs.items())
    simple := true
    for i in 0..d.variants.len {
        if !d.variants.buf[i].1.is_empty() {
            simple = false
            break
        }
    }
    self.types.enums.push(EnumInfo{
        name: name,
        decl: ei,
        targs: clone(targs),
        variants: vec[(str, Vec[i64])](),
        simple: simple,
        size: 8,
        state: if simple { 2 } else { 0 },
    })
    ty := self.types.intern(TyKEnum(eid))
    self.enum_insts.set((ei, clone(targs).items()), ty)
    env := map[str, i64]()
    for i in 0..min(d.tparams.len, targs.len) {
        env.set(d.tparams.buf[i], targs.buf[i])
    }
    vars := vec[(str, Vec[i64])]()
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    for i in 0..d.variants.len {
        vts := &d.variants.buf[i].1
        ts := vec[i64]()
        for j in 0..vts.len {
            ts.push(self.resolve(&vts.buf[j], &env))
        }
        vars.push((d.variants.buf[i].0, ts))
    }
    self.scope_prelude = save_scope
    self.types.enums.buf[eid].variants = vars
    return ty
}

fn flush_layout_errors(self *Cx, pos Pos) {
    errs := self.types.layout_errors
    self.types.layout_errors = vec[str]()
    for i in 0..errs.len {
        self.err(pos, errs.buf[i])
    }
}

// ---------- ABI ----------
fn abi_param(self *Cx, t i64) ParamAbi {
    if self.types.is_scalar(t) {
        return ParamAbiScalar(self.types.scalar_ir(t).0)
    }
    if self.types.leaf_count(t) <= MAX_FLAT {
        l := vec[Leaf]()
        self.types.leaves(t, 0, &l)
        return ParamAbiFlat(l)
    }
    return ParamAbiByRef
}

fn abi_ret(self *Cx, t i64) RetAbi {
    if t == T_UNIT || t == T_NEVER || t == T_ERR {
        return RetAbiNone
    }
    if self.types.is_scalar(t) {
        return RetAbiScalar(self.types.scalar_ir(t).0)
    }
    if self.types.leaf_count(t) <= MAX_FLAT {
        l := vec[Leaf]()
        self.types.leaves(t, 0, &l)
        if l.is_empty() {
            return RetAbiNone
        }
        return RetAbiFlat(l)
    }
    return RetAbiSRet
}

// ---------- function instances ----------
fn inst_fn(self *Cx, di i64, targs Vec[i64]) i64 {
    known, found := self.fn_insts.get((di, targs.items()))
    if found {
        return known
    }
    d := self.fn_decls.buf[di]
    env := map[str, i64]()
    for i in 0..min(d.tparams.len, targs.len) {
        env.set(d.tparams.buf[i], targs.buf[i])
    }
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    ptys := vec[i64]()
    for i in 0..d.params.len {
        ptys.push(self.resolve(&d.params.buf[i].1, &env))
    }
    rty := T_UNIT
    match d.ret {
        Some(r) => {
            rty = self.resolve(&r, &env)
        }
        None => {}
    }
    self.scope_prelude = save_scope
    self.flush_layout_errors(d.pos)
    fid := self.module.funcs.len
    f := func_new(self.inst_name(ast_plain(d.name), targs.items()))
    f.inl = d.inl
    f.noreturn = rty == T_NEVER
    match self.abi_ret(rty) {
        RetAbiNone => {}
        RetAbiScalar(t) => {
            f.rets.push(t)
        }
        RetAbiFlat(l) => {
            for i in 0..l.len {
                f.rets.push(l.buf[i].t)
            }
        }
        RetAbiSRet => {
            f.params.push(TI64)
        }
    }
    for pi in 0..ptys.len {
        pt := ptys.buf[pi]
        match self.abi_param(pt) {
            ParamAbiScalar(t) => {
                f.params.push(t)
            }
            ParamAbiFlat(l) => {
                for i in 0..l.len {
                    f.params.push(l.buf[i].t)
                }
            }
            ParamAbiByRef => {
                f.params.push(TI64)
            }
        }
    }
    match d.ext {
        Some(lib) => {
            // a C function: scalar arguments and result only
            bad := -1
            for i in 0..ptys.len + 1 {
                t := if i < ptys.len { ptys.buf[i] } else { rty }
                if t != T_UNIT && t != T_NEVER && t != T_ERR && (!self.types.is_scalar(t) || is_some(self.types.vec_lanes(t))) {
                    bad = t
                    break
                }
            }
            if bad >= 0 {
                tn := self.types.name(bad)
                self.err(d.pos, fmt("extern function `", d.name, "`: ", tn, " cannot cross the C boundary (pass integers, floats and pointers)"))
            }
            got := self.module.globals.len
            self.module.globals.push(Global{name: fmt("got.", ast_plain(d.name)), size: 8, align: 8, data: Some(vec_fill(8, u8(0))), relocs: vec[(i64, RelocTarget)](), readonly: false})
            f.ext = Some(self.module.externs.len)
            self.module.externs.push(ExternFn{name: ast_plain(d.name), lib: lib, got: got})
        }
        None => {}
    }
    is_ext := is_some(f.ext)
    self.module.funcs.push(f)
    self.fn_sigs.push((ptys, rty))
    self.fn_insts.set((di, clone(targs).items()), fid)
    if !is_ext {
        self.work.push((fid, di, targs))
    }
    return fid
}

// ---------- strings / globals ----------
fn string_global(self *Cx, s str) i64 {
    known, found := self.strings.get(s)
    if found {
        return known
    }
    gid := self.module.globals.len
    self.module.globals.push(Global{
        name: fmt(".str", gid),
        size: len(s),
        align: 1,
        data: Some(vec_of(s)),
        relocs: vec[(i64, RelocTarget)](),
        readonly: true,
    })
    self.strings.set(s, gid)
    return gid
}

fn global(self *Cx, name str) Opt[(i64, i64)] {
    known, found := self.globals.get(name)
    if found {
        return Some(known)
    }
    d, has_decl := self.global_decls.get(name)
    if !has_decl {
        return None
    }
    env := map[str, i64]()
    ty := T_ERR
    match d.ty {
        Some(t) => {
            ty = self.resolve(&t, &env)
        }
        None => {
            // infer from initializer
            match d.init {
                Some(init) => {
                    ty = self.const_type_of(&init)
                    if ty == T_ERR {
                        self.err(d.pos, fmt("cannot infer type of global `", d.name, "`; add a type annotation"))
                    }
                }
                None => {}
            }
        }
    }
    self.flush_layout_errors(d.pos)
    size := self.types.size_of(ty)
    align := max(self.types.align_of(ty), 1)
    gid := self.module.globals.len
    self.module.globals.push(Global{name: ast_plain(d.name), size: size, align: max(align, 8), data: None, relocs: vec[(i64, RelocTarget)](), readonly: false})
    self.globals.set(d.name, (ty, gid))
    match d.init {
        Some(init) => {
            if ty != T_ERR {
                data := vec_fill(size, u8(0))
                relocs := vec[(i64, RelocTarget)]()
                if self.const_init(&init, ty, 0, &data, &relocs) {
                    nonzero := false
                    for i in 0..data.len {
                        if data.buf[i] != 0 {
                            nonzero = true
                            break
                        }
                    }
                    if nonzero || !relocs.is_empty() {
                        g := &self.module.globals.buf[gid]
                        g.data = Some(data)
                        g.relocs = relocs
                    }
                } else {
                    self.err(init.pos, "global initializer must be a compile-time constant")
                }
            }
        }
        None => {}
    }
    return Some((ty, gid))
}

// type of a constant initializer expression (for globals without annotation)
fn const_type_of(self *Cx, e *Expr) i64 {
    match e.k {
        EKInt(_) => return T_I64
        EKFloat(_) => return T_F64
        EKBool(_) => return T_BOOL
        EKStr(_) => return T_STR
        EKLit(t, _) => {
            env := map[str, i64]()
            return lower_opt_or(self.expr_type(t, &env), T_ERR)
        }
        EKCall(c, _) => {
            env := map[str, i64]()
            return lower_opt_or(self.expr_type(c, &env), T_ERR)
        }
        _ => {}
    }
    match self.const_eval(e) {
        Some(cv) => {
            match cv {
                CVInt(_) => return T_I64
                CVFloat(_) => return T_F64
                CVBool(_) => return T_BOOL
                CVStr(_) => return T_STR
            }
        }
        None => {}
    }
    return T_ERR
}

// interpret an expression as a type (for literals, casts, generic args)
fn expr_type(self *Cx, e *Expr, env *Map[str, i64]) Opt[i64] {
    match e.k {
        EKIdent(n) => {
            et, eok := env.get(n)
            if eok {
                return Some(et)
            }
            match lower_builtin_type(n) {
                Some(bt) => return Some(bt)
                None => {}
            }
            match self.find_struct(n) {
                Some(si) => {
                    if self.struct_decls.buf[si].tparams.is_empty() {
                        return Some(self.inst_struct(si, vec[i64](), e.pos))
                    }
                    return None
                }
                None => {}
            }
            match self.find_enum(n) {
                Some(ei) => {
                    if self.enum_decls.buf[ei].tparams.is_empty() {
                        return Some(self.inst_enum(ei, vec[i64](), e.pos))
                    }
                    return None
                }
                None => {}
            }
            return None
        }
        EKIndex(b, args) => {
            var n str
            match b.k {
                EKIdent(bn) => {
                    n = bn
                }
                _ => return None
            }
            is_s := self.find_struct(n)
            is_e := self.find_enum(n)
            if !is_some(is_s) && !is_some(is_e) {
                return None
            }
            targs := vec[i64]()
            for i in 0..args.len {
                match self.expr_type(&args.buf[i], env) {
                    Some(at) => {
                        targs.push(at)
                    }
                    None => return None
                }
            }
            match is_s {
                Some(si) => return Some(self.inst_struct(si, targs, e.pos))
                None => {}
            }
            match is_e {
                Some(ei) => return Some(self.inst_enum(ei, targs, e.pos))
                None => {}
            }
            panic("unwrap of None")
        }
        EKTypeE(t) => {
            return Some(self.resolve(&t, env))
        }
        EKUn(op, inner) => {
            if op != UnOpDeref {
                return None
            }
            match self.expr_type(inner, env) {
                Some(t) => return Some(self.types.ptr_to(t))
                None => return None
            }
        }
        EKTuple(es) => {
            ts := vec[i64]()
            for i in 0..es.len {
                match self.expr_type(&es.buf[i], env) {
                    Some(xt) => {
                        ts.push(xt)
                    }
                    None => return None
                }
            }
            return Some(self.types.intern(TyKTuple(ts)))
        }
        _ => {}
    }
    return None
}

// ---------- constant evaluation ----------
fn const_named(self *Cx, name str) Opt[(Opt[i64], CV)] {
    st, has_st := self.const_vals.get(name)
    if has_st {
        match st {
            CStateDone(t, v) => return Some((t, v))
            CStateBusy => {
                bd, _ := self.const_decls.get(name)
                self.err(bd.pos, fmt("constant `", name, "` depends on itself"))
                return None
            }
            CStateFailed => return None
        }
    }
    d, has_decl := self.const_decls.get(name)
    if !has_decl {
        return None
    }
    self.const_vals.set(d.name, CStateBusy)
    var ty Opt[i64] = None
    match d.ty {
        Some(t) => {
            env := map[str, i64]()
            ty = Some(self.resolve(&t, &env))
        }
        None => {}
    }
    match self.const_eval(&d.val) {
        Some(v0) => {
            v := v0
            match ty {
                Some(t) => {
                    // typed constant: check/coerce
                    ok := false
                    match self.types.k(t) {
                        TyKInt(bits, signed) => {
                            match v0 {
                                CVInt(i) => {
                                    v = CVInt(lower_wrap_int(i, bits, signed))
                                    ok = true
                                }
                                _ => {}
                            }
                        }
                        TyKF64 => {
                            match v0 {
                                CVInt(i) => {
                                    v = CVFloat(f64(i))
                                    ok = true
                                }
                                CVFloat(_) => {
                                    ok = true
                                }
                                _ => {}
                            }
                        }
                        TyKF32 => {
                            match v0 {
                                CVInt(i) => {
                                    v = CVFloat(f64(i))
                                    ok = true
                                }
                                CVFloat(f) => {
                                    v = CVFloat(f64(f32(f)))
                                    ok = true
                                }
                                _ => {}
                            }
                        }
                        TyKBool => {
                            match v0 {
                                CVBool(_) => {
                                    ok = true
                                }
                                _ => {}
                            }
                        }
                        TyKSlice(et) => {
                            match v0 {
                                CVStr(_) => {
                                    ok = et == T_U8
                                }
                                _ => {}
                            }
                        }
                        _ => {}
                    }
                    if !ok {
                        self.err(d.pos, fmt("constant `", name, "` value does not match its declared type"))
                    }
                }
                None => {}
            }
            self.const_vals.set(d.name, CStateDone(ty, v))
            return Some((ty, v))
        }
        None => {
            self.err(d.val.pos, fmt("value of constant `", name, "` is not a compile-time constant"))
            self.const_vals.set(d.name, CStateFailed)
            return None
        }
    }
    return None
}

// integer (op) integer
fn lower_const_bin_int(cx *Cx, op BinOp, x i64, y i64, pos Pos) Opt[CV] {
    match op {
        BinOpAdd => return Some(CVInt(x + y))
        BinOpSub => return Some(CVInt(x - y))
        BinOpMul => return Some(CVInt(x * y))
        BinOpDiv => {
            if y == 0 {
                cx.err(pos, "division by zero in constant expression")
                return None
            }
            if y == -1 {
                // wrapping: MIN / -1 is MIN
                return Some(CVInt(-x))
            }
            return Some(CVInt(x / y))
        }
        BinOpRem => {
            if y == 0 {
                cx.err(pos, "division by zero in constant expression")
                return None
            }
            if y == -1 {
                // wrapping: MIN % -1 is 0
                return Some(CVInt(0))
            }
            return Some(CVInt(x % y))
        }
        BinOpAnd => return Some(CVInt(x & y))
        BinOpOr => return Some(CVInt(x | y))
        BinOpXor => return Some(CVInt(x ^ y))
        // the shift count is taken modulo 64, as with wrapping_shl / wrapping_shr
        BinOpShl => return Some(CVInt(x << (y & 63)))
        BinOpShr => return Some(CVInt(x >> (y & 63)))
        BinOpEq => return Some(CVBool(x == y))
        BinOpNe => return Some(CVBool(x != y))
        BinOpLt => return Some(CVBool(x < y))
        BinOpLe => return Some(CVBool(x <= y))
        BinOpGt => return Some(CVBool(x > y))
        BinOpGe => return Some(CVBool(x >= y))
        _ => {}
    }
    return None
}

// the operand of a mixed / float operation as a float: (value, ok)
fn lower_const_float_operand(cx *Cx, e *Expr) (f64, bool) {
    match cx.const_eval(e) {
        Some(cv) => {
            match cv {
                CVInt(i) => return (f64(i), true)
                CVFloat(f) => return (f, true)
                _ => {}
            }
        }
        None => {}
    }
    return (0.0, false)
}

// float (op) float, with integers converted; the operands are evaluated again
fn lower_const_bin_float(cx *Cx, op BinOp, a *Expr, b *Expr) Opt[CV] {
    x, xok := lower_const_float_operand(cx, a)
    if !xok {
        return None
    }
    y, yok := lower_const_float_operand(cx, b)
    if !yok {
        return None
    }
    match op {
        BinOpAdd => return Some(CVFloat(x + y))
        BinOpSub => return Some(CVFloat(x - y))
        BinOpMul => return Some(CVFloat(x * y))
        BinOpDiv => return Some(CVFloat(x / y))
        BinOpEq => return Some(CVBool(x == y))
        BinOpNe => return Some(CVBool(x != y))
        BinOpLt => return Some(CVBool(x < y))
        BinOpLe => return Some(CVBool(x <= y))
        BinOpGt => return Some(CVBool(x > y))
        BinOpGe => return Some(CVBool(x >= y))
        _ => {}
    }
    return None
}

fn const_eval(self *Cx, e *Expr) Opt[CV] {
    match e.k {
        EKInt(n) => return Some(CVInt(i64(n)))
        EKFloat(f) => return Some(CVFloat(f))
        EKBool(b) => return Some(CVBool(b))
        EKStr(s) => return Some(CVStr(s))
        EKIdent(n) => {
            if self.const_decls.has(n) {
                match self.const_named(n) {
                    Some(x) => return Some(x.1)
                    None => return None
                }
            }
            return None
        }
        EKUn(op, x) => {
            match self.const_eval(x) {
                Some(v) => {
                    match v {
                        CVInt(i) => {
                            if op == UnOpNeg {
                                return Some(CVInt(-i))
                            }
                            if op == UnOpBitNot {
                                return Some(CVInt(~i))
                            }
                        }
                        CVFloat(f) => {
                            if op == UnOpNeg {
                                return Some(CVFloat(-f))
                            }
                        }
                        CVBool(b) => {
                            if op == UnOpNot {
                                return Some(CVBool(!b))
                            }
                        }
                        _ => {}
                    }
                    return None
                }
                None => return None
            }
        }
        EKBin(op, a, b) => {
            var x CV
            match self.const_eval(a) {
                Some(xv) => {
                    x = xv
                }
                None => return None
            }
            var y CV
            match self.const_eval(b) {
                Some(yv) => {
                    y = yv
                }
                None => return None
            }
            match x {
                CVInt(xi) => {
                    match y {
                        CVInt(yi) => return lower_const_bin_int(self, op, xi, yi, e.pos)
                        CVFloat(_) => return lower_const_bin_float(self, op, a, b)
                        _ => return None
                    }
                }
                CVFloat(_) => {
                    match y {
                        CVInt(_) => return lower_const_bin_float(self, op, a, b)
                        CVFloat(_) => return lower_const_bin_float(self, op, a, b)
                        _ => return None
                    }
                }
                CVBool(xb) => {
                    match y {
                        CVBool(yb) => {
                            match op {
                                BinOpLAnd => return Some(CVBool(xb && yb))
                                BinOpLOr => return Some(CVBool(xb || yb))
                                BinOpEq => return Some(CVBool(xb == yb))
                                BinOpNe => return Some(CVBool(xb != yb))
                                _ => return None
                            }
                        }
                        _ => return None
                    }
                }
                _ => return None
            }
        }
        EKCall(c, args) => {
            if args.len == 1 {
                // numeric conversion of a constant: T(x); sizeof[T]()
                env := map[str, i64]()
                var t i64
                match self.expr_type(c, &env) {
                    Some(ct) => {
                        t = ct
                    }
                    None => return None
                }
                var v CV
                match self.const_eval(&args.buf[0]) {
                    Some(av) => {
                        v = av
                    }
                    None => return None
                }
                match self.types.k(t) {
                    TyKInt(bits, signed) => {
                        match v {
                            CVInt(i) => return Some(CVInt(lower_wrap_int(i, bits, signed)))
                            CVFloat(f) => return Some(CVInt(lower_wrap_int(lower_f64_to_i64(f), bits, signed)))
                            _ => return None
                        }
                    }
                    TyKF64 => {
                        match v {
                            CVInt(i) => return Some(CVFloat(f64(i)))
                            CVFloat(f) => return Some(CVFloat(f))
                            _ => return None
                        }
                    }
                    TyKF32 => {
                        match v {
                            CVInt(i) => return Some(CVFloat(f64(f32(i))))
                            CVFloat(f) => return Some(CVFloat(f64(f32(f))))
                            _ => return None
                        }
                    }
                    _ => return None
                }
            }
            if args.is_empty() {
                match c.k {
                    EKIndex(b, targs) => {
                        is_sizeof := false
                        match b.k {
                            EKIdent(n) => {
                                is_sizeof = n == "sizeof"
                            }
                            _ => {}
                        }
                        if is_sizeof && targs.len == 1 {
                            env := map[str, i64]()
                            match self.expr_type(&targs.buf[0], &env) {
                                Some(t) => return Some(CVInt(self.types.size_of(t)))
                                None => return None
                            }
                        }
                    }
                    _ => {}
                }
                return None
            }
            return None
        }
        _ => {}
    }
    return None
}

// write a constant initializer into `data` at `off`
fn const_init(self *Cx, e *Expr, ty i64, off i64, data *Vec[u8], relocs *Vec[(i64, RelocTarget)]) bool {
    k := self.types.k(ty)
    match e.k {
        EKLit(te, items) => {
            match k {
                TyKArray(et, n) => {
                    env := map[str, i64]()
                    match self.expr_type(te, &env) {
                        Some(t) => {
                            if t != ty {
                                return false
                            }
                        }
                        None => return false
                    }
                    if items.len > n {
                        self.err(e.pos, fmt("too many elements in array literal (max ", n, ")"))
                        return false
                    }
                    es := self.types.size_of(et)
                    for i in 0..items.len {
                        if is_some(items.buf[i].0) {
                            return false
                        }
                        if !self.const_init(&items.buf[i].1, et, off + i * es, data, relocs) {
                            return false
                        }
                    }
                    return true
                }
                TyKStruct(sid) => {
                    env := map[str, i64]()
                    match self.expr_type(te, &env) {
                        Some(t) => {
                            if t != ty {
                                return false
                            }
                        }
                        None => return false
                    }
                    self.types.layout_struct(sid)
                    fields := clone(self.types.structs.buf[sid].fields)
                    offs := clone(self.types.structs.buf[sid].offsets)
                    for i in 0..items.len {
                        fi := i
                        match items.buf[i].0 {
                            Some(n) => {
                                fi = -1
                                for j in 0..fields.len {
                                    if fields.buf[j].0 == n {
                                        fi = j
                                        break
                                    }
                                }
                                if fi < 0 {
                                    return false
                                }
                            }
                            None => {}
                        }
                        if fi >= fields.len {
                            return false
                        }
                        if !self.const_init(&items.buf[i].1, fields.buf[fi].1, off + offs.buf[fi], data, relocs) {
                            return false
                        }
                    }
                    return true
                }
                _ => {}
            }
        }
        EKIdent(n) => {
            match k {
                TyKFn(ptys, rty) => {
                    // address of a (non-generic) function
                    di := -1
                    match self.find_fn(n) {
                        Some(fdi) => {
                            if self.fn_decls.buf[fdi].tparams.is_empty() {
                                di = fdi
                            }
                        }
                        None => {}
                    }
                    if di < 0 {
                        return false
                    }
                    fid := self.inst_fn(di, vec[i64]())
                    sig := self.fn_sigs.buf[fid]
                    if sig.0.items() != ptys.items() || sig.1 != rty {
                        self.err(e.pos, fmt("function `", n, "` does not have the type ", self.types.name(ty)))
                        return false
                    }
                    relocs.push((off, RelocTargetFunc(fid)))
                    return true
                }
                _ => {}
            }
        }
        EKNil => {
            match k {
                TyKPtr(_) => return true
                TyKFn(_, _) => return true
                _ => {}
            }
        }
        EKCall(c, args) => {
            // vec3(1.0, 2.0, 3.0) with constant components; mat4 from four constant columns
            is_vec := false
            n := 4
            et := T_F32
            es := 4
            match k {
                TyKMat4 => {
                    is_vec = true
                    et = T_VEC4
                    es = 16
                }
                TyKVec(vn) => {
                    is_vec = true
                    n = vn
                }
                TyKQuat => {
                    is_vec = true
                }
                _ => {}
            }
            if is_vec {
                env := map[str, i64]()
                match self.expr_type(c, &env) {
                    Some(t) => {
                        if t != ty {
                            return false
                        }
                    }
                    None => return false
                }
                if args.len != n {
                    return false
                }
                for i in 0..args.len {
                    if !self.const_init(&args.buf[i], et, off + i * es, data, relocs) {
                        return false
                    }
                }
                return true
            }
        }
        _ => {}
    }
    var v CV
    match self.const_eval(e) {
        Some(cv) => {
            v = cv
        }
        None => return false
    }
    match k {
        TyKInt(bits, _) => {
            match v {
                CVInt(i) => {
                    lower_put_le(data, off, u64(i), bits / 8)
                    return true
                }
                _ => {}
            }
        }
        TyKF32 => {
            match v {
                CVFloat(f) => {
                    lower_put_le(data, off, u64(cast[u32](f32(f))), 4)
                    return true
                }
                CVInt(i) => {
                    lower_put_le(data, off, u64(cast[u32](f32(i))), 4)
                    return true
                }
                _ => {}
            }
        }
        TyKF64 => {
            match v {
                CVFloat(f) => {
                    lower_put_le(data, off, cast[u64](f), 8)
                    return true
                }
                CVInt(i) => {
                    lower_put_le(data, off, cast[u64](f64(i)), 8)
                    return true
                }
                _ => {}
            }
        }
        TyKBool => {
            match v {
                CVBool(b) => {
                    data.buf[off] = if b { u8(1) } else { u8(0) }
                    return true
                }
                _ => {}
            }
        }
        TyKSlice(et) => {
            match v {
                CVStr(s) => {
                    if et == T_U8 {
                        g := self.string_global(s)
                        relocs.push((off, RelocTargetGlobal(g, 0)))
                        lower_put_le(data, off + 8, u64(len(s)), 8)
                        return true
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
    return false
}

fn lower_wrap_int(v i64, bits i64, signed bool) i64 {
    if signed {
        match bits {
            8 => return i64(i8(v))
            16 => return i64(i16(v))
            32 => return i64(i32(v))
            _ => {}
        }
    } else {
        match bits {
            8 => return i64(u8(v))
            16 => return i64(u16(v))
            32 => return i64(u32(v))
            _ => {}
        }
    }
    return v
}
