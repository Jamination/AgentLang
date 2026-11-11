// Semantic analysis + lowering context: declarations, type resolution, constants, globals, instances.

struct Opts {
    checks: bool
}

enum CV {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(str),
}

priv enum CState {
    Busy,
    Done(Opt[i64], CV),
    Failed,
}

priv enum ParamAbi {
    Scalar(T),
    Flat(Vec[Leaf]),
    ByRef,
}

enum RetAbi {
    None,
    Scalar(T),
    Flat(Vec[Leaf]),
    SRet,
}

priv const MAX_FLAT = 4

struct Cx {
    types: Types
    module: Module
    errs: Vec[Diag]
    opts: Opts
    file_names: Vec[str]
    fn_decls: Vec[*FnDecl]
    fn_names: Map[str, i64]
    struct_decls: Vec[*StructDecl]
    struct_names: Map[str, i64]
    enum_decls: Vec[*EnumDecl]
    enum_names: Map[str, i64]
    // user enums' variants by name: (enum declaration, variant index) of every enum that has one
    variants: Map[str, Vec[(i64, i64)]]
    const_decls: Map[str, *ConstDecl]
    const_vals: Map[str, CState]
    global_decls: Map[str, *GlobalDecl]
    globals: Map[str, (i64, i64)]
    // instance tables: the key is (declaration index, type arguments as a slice that is never
    // modified afterwards)
    struct_insts: Map[(i64, []i64), i64]
    enum_insts: Map[(i64, []i64), i64]
    fn_insts: Map[(i64, []i64), i64]
    fn_sigs: Vec[(Vec[i64], i64)]
    work: Vec[(i64, i64, Vec[i64])]
    strings: Map[str, i64]
    exposed: Map[i64, bool]
    inst_depth: i64
    // names declared by the prelude: prelude code always sees these, user code may shadow them
    p_fn_names: Map[str, i64]
    // every definition of a function name (overloads), per layer, in declaration order
    fn_over: Map[str, Vec[i64]]
    p_fn_over: Map[str, Vec[i64]]
    p_struct_names: Map[str, i64]
    p_enum_names: Map[str, i64]
    // true while resolving names on behalf of prelude code
    scope_prelude: bool
    entry_file: i64
    // files whose declarations are only checked when something uses them
    lazy_files: Map[i64, bool]
    n_prelude: i64
    // written name -> position of a `priv` declaration of it in some file (for the hint of
    // "unknown name" diagnostics)
    priv_decls: Map[str, Pos]
    // constants: 1 = a scalar value (`const_vals`), 2 = an aggregate or vector in read-only
    // memory (`const_mems`: type and global; type -1 while the initializer is evaluated),
    // 0 = being classified
    const_kind: Map[str, i64]
    const_mems: Map[str, (i64, i64)]
    // files read by `embed`, by path
    embeds: Map[str, str]
    // the same for the enums of the prelude (see lower_match.al for the lookup rules)
    p_variants: Map[str, Vec[(i64, i64)]]
    // which layers declare a function, type, constant or global of a name: 1 = prelude, 2 = user
    decl_layers: Map[str, i64]
    // the nested and anonymous functions (lower_nested.al)
    nested: Vec[NestedFn]
}

// for "unknown name" diagnostics: says that `n` exists as a private declaration of another file
fn priv_hint(self: *Cx, n: str) -> str {
    pos, found := self.priv_decls.get(n)
    if !found {
        return ""
    }
    fname: str = "?"
    if pos.file >= 0 && pos.file < self.file_names.len {
        fname = self.file_names[pos.file]
    }
    return fmt(" (`", n, "` is declared `priv` in ", fname, ", line ", pos.line, ": a private declaration is visible only inside its own file; remove `priv` there to use it from other files)")
}

fn lower_builtin_type(name: str) -> Opt[i64] {
    match name {
        "i8" => Some(T_I8)
        "i16" => Some(T_I16)
        "i32" => Some(T_I32)
        "i64" => Some(T_I64)
        "u8" => Some(T_U8)
        "u16" => Some(T_U16)
        "u32" => Some(T_U32)
        "u64" => Some(T_U64)
        "f64" => Some(T_F64)
        "f32" => Some(T_F32)
        "vec2" => Some(T_VEC2)
        "vec3" => Some(T_VEC3)
        "vec4" => Some(T_VEC4)
        "quat" => Some(T_QUAT)
        "mat4" => Some(T_MAT4)
        "bool" => Some(T_BOOL)
        "str" => Some(T_STR)
        "never" => Some(T_NEVER)
        _ => None
    }
}

// `f as i64` of the Rust source: saturating, NaN gives 0
priv fn f64_to_i64(f: f64) -> i64 {
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
priv fn put_le(data: *Vec[u8], off: i64, x: u64, n: i64) {
    for j in 0..n {
        data[off + j] = u8(x >> u64(8 * j))
    }
}

// parameter types of a function declaration as text (to detect duplicate overloads)
fn lower_new_sig(g: *FnDecl) -> str {
    parts := vec[str]()
    for i in 0..g.params.len {
        parts.push(ast_type_str(&g.params[i].1))
    }
    return join(parts.items(), ",")
}

// files with an index below `n_prelude` form the always-present core library
fn cx_new(decls: []Decl, file_names: Vec[str], opts: Opts, n_prelude: i64) -> Cx {
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
        variants: map[str, Vec[(i64, i64)]](),
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
        const_kind: map[str, i64](),
        const_mems: map[str, (i64, i64)](),
        embeds: map[str, str](),
        p_variants: map[str, Vec[(i64, i64)]](),
        decl_layers: map[str, i64](),
    }
    names := map[str, Pos]()
    // is the visible declaration of a name a function?
    names_fn := map[str, bool]()
    for i in 0..len(decls) {
        name: str
        pos: Pos
        // 1 = function, 2 = struct, 3 = enum, 4 = constant, 5 = global
        kind := 0
        // the declarations are copied to the heap once: the context keeps pointers to them
        fp: *FnDecl
        sp: *StructDecl
        ep: *EnumDecl
        cp: *ConstDecl
        gp: *GlobalDecl
        match decls[i] {
            Fn(f) => {
                fp = new[FnDecl]()
                *fp = f
                name = f.name
                pos = f.pos
                kind = 1
            }
            Struct(s) => {
                sp = new[StructDecl]()
                *sp = s
                name = s.name
                pos = s.pos
                kind = 2
            }
            Enum(e) => {
                ep = new[EnumDecl]()
                *ep = e
                name = e.name
                pos = e.pos
                kind = 3
            }
            Const(c) => {
                cp = new[ConstDecl]()
                *cp = c
                name = c.name
                pos = c.pos
                kind = 4
            }
            Glob(g) => {
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
                l: Vec[i64]
                has_layer := false
                if pos.file < np {
                    l, has_layer = cx.p_fn_over.get(name)
                } else {
                    l, has_layer = cx.fn_over.get(name)
                }
                dup := -1
                if has_layer {
                    for k in 0..l.len {
                        if lower_new_sig(cx.fn_decls[l[k]]) == lower_new_sig(fp) {
                            dup = l[k]
                            break
                        }
                    }
                }
                if dup >= 0 {
                    at := cx.pos_str(cx.fn_decls[dup].pos)
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
        cx.decl_layers.set(name, cx.decl_layers.get_or(name, 0) | (if pos.file < np { 1 } else { 2 }))
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
    // enum variants: two enums may use the same variant name; within a layer (prelude / user)
    // a variant must not have the name of another kind of declaration
    for ei in 0..cx.enum_decls.len {
        e := cx.enum_decls[ei]
        layer := if e.pos.file < np { 1 } else { 2 }
        for vi in 0..e.variants.len {
            vn := e.variants[vi].0
            if cx.decl_layers.get_or(vn, 0) & layer != 0 {
                cx.err(e.pos, fmt("enum variant `", vn, "` conflicts with another declaration"))
                continue
            }
            dup := false
            for vj in 0..vi {
                if e.variants[vj].0 == vn {
                    dup = true
                    break
                }
            }
            if dup {
                cx.err(e.pos, fmt("enum `", e.name, "` declares the variant `", vn, "` twice"))
                continue
            }
            l: Vec[(i64, i64)]
            has_l := false
            if layer == 1 {
                l, has_l = cx.p_variants.get(vn)
            } else {
                l, has_l = cx.variants.get(vn)
            }
            if !has_l {
                l = vec[(i64, i64)]()
            }
            l.push((ei, vi))
            if layer == 1 {
                cx.p_variants.set(vn, l)
            } else {
                cx.variants.set(vn, l)
            }
        }
    }
    return cx
}

fn find_fn(self: *Cx, n: str) -> Opt[i64] {
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
fn fn_candidates(self: *Cx, n: str) -> Vec[i64] {
    v := self.fn_candidates_of(n)
    // a private function (see priv.al): the public definitions of the written name follow
    if v.len != 0 && ast_is_private(n) {
        more := self.fn_candidates_of(ast_plain(n))
        v.extend(more.items())
    }
    return v
}

priv fn fn_candidates_of(self: *Cx, n: str) -> Vec[i64] {
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

fn find_struct(self: *Cx, n: str) -> Opt[i64] {
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

fn find_enum(self: *Cx, n: str) -> Opt[i64] {
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

fn internal_file(self: *Cx, file: i64) -> bool {
    return file < self.n_prelude || file == self.entry_file
}

fn pos_str(self: *Cx, p: Pos) -> str {
    fname: str = "?"
    if p.file >= 0 && p.file < self.file_names.len {
        fname = self.file_names[p.file]
    }
    return fmt(fname, ":", p.line, ":", p.col)
}

fn err(self: *Cx, pos: Pos, msg: str) {
    self.errs.push(Diag{pos: pos, msg: msg})
}

// ---------- types ----------
fn resolve(self: *Cx, t: *TypeAst, env: *Map[str, i64]) -> i64 {
    match *t {
        Name(n, args, pos) => {
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
                targs.push(self.resolve(&args[i], env))
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
        Ptr(e) => {
            et := self.resolve(e, env)
            if et == T_ERR {
                return T_ERR
            }
            return self.types.ptr_to(et)
        }
        Slice(e) => {
            et := self.resolve(e, env)
            if et == T_ERR {
                return T_ERR
            }
            return self.types.slice(et)
        }
        Array(n, e) => {
            e2 := self.resolve(e, env)
            ln := match self.const_eval(n) {
                Some(Int(v)) if v >= 0 => v
                _ => -1
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
            return self.types.intern(TyK.Array(e2, ln))
        }
        Fn(ps, r) => {
            pts := vec[i64]()
            for i in 0..ps.len {
                pts.push(self.resolve(&ps[i], env))
            }
            rt := match r {
                Some(rr) => self.resolve(rr, env)
                None => T_UNIT
            }
            if contains(&pts, T_ERR) || rt == T_ERR {
                return T_ERR
            }
            return self.types.intern(TyK.Fn(pts, rt))
        }
        Tuple(ts) => {
            tys := vec[i64]()
            for i in 0..ts.len {
                tys.push(self.resolve(&ts[i], env))
            }
            if contains(&tys, T_ERR) {
                return T_ERR
            }
            if tys.is_empty() {
                return T_UNIT
            }
            return self.types.intern(TyK.Tuple(tys))
        }
    }
    return T_ERR
}

priv fn inst_name(self: *Cx, base: str, targs: []i64) -> str {
    if len(targs) == 0 {
        return base
    }
    parts := vec[str]()
    for t in targs {
        parts.push(self.types.name(t))
    }
    return fmt(base, "[", join(parts.items(), ", "), "]")
}

priv fn inst_struct(self: *Cx, si: i64, targs: Vec[i64], pos: Pos) -> i64 {
    d := self.struct_decls[si]
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
        state: 3,
    })
    ty := self.types.intern(Struct(sid))
    self.struct_insts.set((si, clone(targs).items()), ty)
    env := map[str, i64]()
    for i in 0..min(d.tparams.len, targs.len) {
        env.set(d.tparams[i], targs[i])
    }
    fields := vec[(str, i64)]()
    seen := map[str, bool]()
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    for i in 0..d.fields.len {
        fname := d.fields[i].0
        if seen.has(fname) {
            self.err(d.pos, fmt("duplicate field `", fname, "` in struct `", d.name, "`"))
        } else {
            seen.set(fname, true)
        }
        t := self.resolve(&d.fields[i].1, &env)
        fields.push((fname, t))
    }
    self.scope_prelude = save_scope
    self.types.structs[sid].fields = fields
    self.types.structs[sid].state = 0
    return ty
}

fn inst_enum(self: *Cx, ei: i64, targs: Vec[i64], pos: Pos) -> i64 {
    d := self.enum_decls[ei]
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
        if !d.variants[i].1.is_empty() {
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
        state: if simple { 2 } else { 3 },
    })
    ty := self.types.intern(Enum(eid))
    self.enum_insts.set((ei, clone(targs).items()), ty)
    env := map[str, i64]()
    for i in 0..min(d.tparams.len, targs.len) {
        env.set(d.tparams[i], targs[i])
    }
    vars := vec[(str, Vec[i64])]()
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    for i in 0..d.variants.len {
        vts := &d.variants[i].1
        ts := vec[i64]()
        for j in 0..vts.len {
            ts.push(self.resolve(&vts[j], &env))
        }
        vars.push((d.variants[i].0, ts))
    }
    self.scope_prelude = save_scope
    self.types.enums[eid].variants = vars
    if !simple {
        self.types.enums[eid].state = 0
    }
    return ty
}

fn flush_layout_errors(self: *Cx, pos: Pos) {
    errs := self.types.layout_errors
    self.types.layout_errors = vec[str]()
    for i in 0..errs.len {
        self.err(pos, errs[i])
    }
}

// ---------- ABI ----------
fn abi_param(self: *Cx, t: i64) -> ParamAbi {
    if self.types.is_scalar(t) {
        return Scalar(self.types.scalar_ir(t).0)
    }
    if self.types.leaf_count(t) <= MAX_FLAT {
        l := vec[Leaf]()
        self.types.leaves(t, 0, &l)
        return Flat(l)
    }
    return ByRef
}

fn abi_ret(self: *Cx, t: i64) -> RetAbi {
    if t == T_UNIT || t == T_NEVER || t == T_ERR {
        return RetAbi.None
    }
    if self.types.is_scalar(t) {
        return Scalar(self.types.scalar_ir(t).0)
    }
    if self.types.leaf_count(t) <= MAX_FLAT {
        l := vec[Leaf]()
        self.types.leaves(t, 0, &l)
        if l.is_empty() {
            return RetAbi.None
        }
        return Flat(l)
    }
    return SRet
}

// the IR parameters and results of a function with parameter types `ptys` and result `rty`
fn fn_abi(self: *Cx, f: *Func, ptys: []i64, rty: i64) {
    match self.abi_ret(rty) {
        RetAbi.None => {}
        Scalar(t) => {
            f.rets.push(t)
        }
        Flat(l) => {
            for i in 0..l.len {
                f.rets.push(l[i].t)
            }
        }
        SRet => {
            f.params.push(I64)
        }
    }
    for pi in 0..len(ptys) {
        pt := ptys[pi]
        match self.abi_param(pt) {
            Scalar(t) => {
                f.params.push(t)
            }
            Flat(l) => {
                for i in 0..l.len {
                    f.params.push(l[i].t)
                }
            }
            ByRef => {
                f.params.push(I64)
            }
        }
    }
}

// ---------- function instances ----------
fn inst_fn(self: *Cx, di: i64, targs: Vec[i64]) -> i64 {
    known, found := self.fn_insts.get((di, targs.items()))
    if found {
        return known
    }
    d := self.fn_decls[di]
    env := map[str, i64]()
    for i in 0..min(d.tparams.len, targs.len) {
        env.set(d.tparams[i], targs[i])
    }
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    ptys := vec[i64]()
    for i in 0..d.params.len {
        ptys.push(self.resolve(&d.params[i].1, &env))
    }
    rty := match d.ret {
        Some(r) => self.resolve(&r, &env)
        None => T_UNIT
    }
    self.scope_prelude = save_scope
    self.flush_layout_errors(d.pos)
    fid := self.module.funcs.len
    f := func_new(self.inst_name(ast_plain(d.name), targs.items()))
    f.inl = d.inl
    f.noreturn = rty == T_NEVER
    self.fn_abi(&f, ptys.items(), rty)
    match d.ext {
        Some(lib) => {
            // a C function: scalar arguments and result only
            bad := -1
            for i in 0..ptys.len + 1 {
                t := if i < ptys.len { ptys[i] } else { rty }
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
fn string_global(self: *Cx, s: str) -> i64 {
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

fn global(self: *Cx, name: str) -> Opt[(i64, i64)] {
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
                        if data[i] != 0 {
                            nonzero = true
                            break
                        }
                    }
                    if nonzero || !relocs.is_empty() {
                        g := &self.module.globals[gid]
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
priv fn const_type_of(self: *Cx, e: *Expr) -> i64 {
    match e.k {
        Int(_) => return T_I64
        Float(_) => return T_F64
        Bool(_) => return T_BOOL
        Str(_) => return T_STR
        Lit(t, _) => {
            env := map[str, i64]()
            return self.expr_type(t, &env).or(T_ERR)
        }
        Call(c, _) => {
            env := map[str, i64]()
            match self.expr_type(c, &env) {
                Some(t) => return t
                None => {}
            }
        }
        Tuple(es) => {
            ts := vec[i64]()
            for i in 0..es.len {
                t := self.const_type_of(&es[i])
                if t == T_ERR {
                    return T_ERR
                }
                ts.push(t)
            }
            return self.types.intern(TyK.Tuple(ts))
        }
        Ident(n) => {
            if self.const_is_mem(n) {
                match self.const_global(n) {
                    Some(g) => return g.0
                    None => return T_ERR
                }
            }
        }
        _ => {}
    }
    match self.const_eval(e) {
        Some(Int(_)) => T_I64
        Some(Float(_)) => T_F64
        Some(Bool(_)) => T_BOOL
        Some(Str(_)) => T_STR
        None => T_ERR
    }
}

// interpret an expression as a type (for literals, casts, generic args)
fn expr_type(self: *Cx, e: *Expr, env: *Map[str, i64]) -> Opt[i64] {
    match e.k {
        Ident(n) => {
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
                    if self.struct_decls[si].tparams.is_empty() {
                        return Some(self.inst_struct(si, vec[i64](), e.pos))
                    }
                    return None
                }
                None => {}
            }
            match self.find_enum(n) {
                Some(ei) => {
                    if self.enum_decls[ei].tparams.is_empty() {
                        return Some(self.inst_enum(ei, vec[i64](), e.pos))
                    }
                    return None
                }
                None => {}
            }
            return None
        }
        Index(b, args) => {
            n := match b.k {
                Ident(bn) => bn
                _ => return None
            }
            is_s := self.find_struct(n)
            is_e := self.find_enum(n)
            if !is_some(is_s) && !is_some(is_e) {
                return None
            }
            targs := vec[i64]()
            for i in 0..args.len {
                match self.expr_type(&args[i], env) {
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
        TypeE(t) => {
            return Some(self.resolve(&t, env))
        }
        Un(Deref, inner) => {
            match self.expr_type(inner, env) {
                Some(t) => return Some(self.types.ptr_to(t))
                None => return None
            }
        }
        Tuple(es) => {
            ts := vec[i64]()
            for i in 0..es.len {
                match self.expr_type(&es[i], env) {
                    Some(xt) => {
                        ts.push(xt)
                    }
                    None => return None
                }
            }
            return Some(self.types.intern(TyK.Tuple(ts)))
        }
        _ => {}
    }
    return None
}

// ---------- constant evaluation ----------
// Is constant `name` an aggregate or a vector, kept in read-only memory, rather than a
// scalar value? Decided by the form of its initializer: a `T{...}` literal, a tuple, a
// vector constructor, or the name of another such constant.
fn const_is_mem(self: *Cx, name: str) -> bool {
    k, known := self.const_kind.get(name)
    if known {
        return k == 2
    }
    d, has := self.const_decls.get(name)
    if !has {
        return false
    }
    self.const_kind.set(name, 0)
    mem := false
    match d.val.k {
        Lit(_, _), Tuple(_) => {
            mem = true
        }
        Call(c, _) => {
            saved := self.errs.len
            save_scope := self.scope_prelude
            self.scope_prelude = self.internal_file(d.pos.file)
            env := map[str, i64]()
            match self.expr_type(c, &env) {
                Some(t) => {
                    match self.types.k(t) {
                        Vec(_), Quat, Mat4 => {
                            mem = true
                        }
                        _ => {}
                    }
                }
                None => {}
            }
            self.scope_prelude = save_scope
            self.errs.truncate(saved)
        }
        Ident(n) => {
            mem = n != name && self.const_is_mem(n)
        }
        _ => {}
    }
    self.const_kind.set(name, if mem { 2 } else { 1 })
    return mem
}

// the (type, global) of a constant that lives in read-only memory (see `const_is_mem`)
fn const_global(self: *Cx, name: str) -> Opt[(i64, i64)] {
    d, has_decl := self.const_decls.get(name)
    if !has_decl {
        return None
    }
    known, found := self.const_mems.get(name)
    if found {
        if known.0 == -1 {
            self.err(d.pos, fmt("constant `", name, "` depends on itself"))
            return None
        }
        if known.0 == T_ERR {
            return None
        }
        return Some(known)
    }
    self.const_mems.set(name, (-1, 0))
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    ty := T_ERR
    match d.ty {
        Some(t) => {
            env := map[str, i64]()
            ty = self.resolve(&t, &env)
        }
        None => {
            nerr := self.errs.len
            ty = self.const_type_of(&d.val)
            if ty == T_ERR && self.errs.len == nerr {
                self.err(d.pos, fmt("cannot infer the type of constant `", name, "`: its value must be a compile-time constant of a known type (literals, other constants, function names, `T{...}` literals, tuples and vector constructors made of them)"))
            }
        }
    }
    self.flush_layout_errors(d.pos)
    res := (T_ERR, 0)
    if ty != T_ERR {
        size := self.types.size_of(ty)
        align := max(self.types.align_of(ty), 8)
        data := vec_fill(size, u8(0))
        relocs := vec[(i64, RelocTarget)]()
        nerr := self.errs.len
        if self.const_init(&d.val, ty, 0, &data, &relocs) {
            gid := self.module.globals.len
            self.module.globals.push(Global{name: d.name, size: size, align: align, data: Some(data), relocs: relocs, readonly: true})
            res = (ty, gid)
        } else if self.errs.len == nerr {
            vt := self.const_type_of(&d.val)
            self.errs.truncate(nerr)
            if vt != T_ERR && vt != ty {
                self.err(d.val.pos, fmt("constant `", name, "` is declared as ", self.types.name(ty), ", but its value has type ", self.types.name(vt)))
            } else {
                self.err(d.val.pos, fmt("value of constant `", name, "` is not a compile-time constant of type ", self.types.name(ty), " (allowed: literals, other constants, function names, and `T{...}` literals, tuples and vector constructors made of them)"))
            }
        }
    }
    self.scope_prelude = save_scope
    self.const_mems.set(name, res)
    if res.0 == T_ERR {
        return None
    }
    return Some(res)
}

// The bytes of the file that `embed(args)` at `pos` names (relative to the source file),
// read once per path; None after reporting why not.
fn embed_bytes(self: *Cx, args: []Expr, pos: Pos) -> Opt[str] {
    if len(args) != 1 {
        self.err(pos, fmt("`embed` takes 1 argument(s), got ", len(args)))
        return None
    }
    rel := match args[0].k {
        Str(s) => s
        _ => {
            self.err(args[0].pos, "`embed` takes a string literal path")
            return None
        }
    }
    src := ""
    if pos.file >= 0 && pos.file < self.file_names.len {
        src = self.file_names[pos.file]
    }
    dir := ""
    if starts_with(src, "<") {
        std_dir, have := env_get("ALC_STD_DIR")
        if have {
            dir = std_dir
        }
    } else {
        dir = lower_call_parent_dir(src)
    }
    path := lower_call_path_join(dir, rel)
    cached, hit := self.embeds.get(path)
    if hit {
        return Some(cached)
    }
    bytes, ok := read_file(path)
    if ok {
        self.embeds.set(path, bytes)
        return Some(bytes)
    }
    self.err(args[0].pos, fmt("cannot embed `", path, "`: ", lower_call_io_error(path)))
    return None
}

fn const_named(self: *Cx, name: str) -> Opt[(Opt[i64], CV)] {
    if self.const_is_mem(name) {
        // not a scalar value; evaluated here so that its errors are reported
        self.const_global(name)
        return None
    }
    st, has_st := self.const_vals.get(name)
    if has_st {
        match st {
            Done(t, v) => return Some((t, v))
            Busy => {
                bd, _ := self.const_decls.get(name)
                self.err(bd.pos, fmt("constant `", name, "` depends on itself"))
                return None
            }
            Failed => return None
        }
    }
    d, has_decl := self.const_decls.get(name)
    if !has_decl {
        return None
    }
    self.const_vals.set(d.name, Busy)
    ty: Opt[i64] = None
    match d.ty {
        Some(t) => {
            env := map[str, i64]()
            ty = Some(self.resolve(&t, &env))
        }
        None => {}
    }
    nerr0 := self.errs.len
    match self.const_eval(&d.val) {
        Some(v0) => {
            v := v0
            match ty {
                Some(t) => {
                    // typed constant: check/coerce
                    ok := match (self.types.k(t), v0) {
                        (Int(bits, signed), Int(i)) => {
                            v = CV.Int(wrap_int(i, bits, signed))
                            true
                        }
                        (F64, Int(i)), (F32, Int(i)) => {
                            v = Float(f64(i))
                            true
                        }
                        (F32, Float(f)) => {
                            v = Float(f64(f32(f)))
                            true
                        }
                        (F64, Float(_)), (Bool, Bool(_)), (Slice(T_U8), Str(_)) => true
                        _ => false
                    }
                    if !ok {
                        self.err(d.pos, fmt("constant `", name, "` value does not match its declared type"))
                    }
                }
                None => {}
            }
            self.const_vals.set(d.name, Done(ty, v))
            return Some((ty, v))
        }
        None => {
            if self.errs.len == nerr0 {
                self.err(d.val.pos, fmt("value of constant `", name, "` is not a compile-time constant"))
            }
            self.const_vals.set(d.name, Failed)
            return None
        }
    }
    return None
}

// integer (op) integer
priv fn const_bin_int(cx: *Cx, op: BinOp, x: i64, y: i64, pos: Pos) -> Opt[CV] {
    match op {
        Add => return Some(Int(x + y))
        Sub => return Some(Int(x - y))
        Mul => return Some(Int(x * y))
        Div => {
            if y == 0 {
                cx.err(pos, "division by zero in constant expression")
                return None
            }
            if y == -1 {
                // wrapping: MIN / -1 is MIN
                return Some(Int(-x))
            }
            return Some(Int(x / y))
        }
        Rem => {
            if y == 0 {
                cx.err(pos, "division by zero in constant expression")
                return None
            }
            if y == -1 {
                // wrapping: MIN % -1 is 0
                return Some(Int(0))
            }
            return Some(Int(x % y))
        }
        And => return Some(Int(x & y))
        Or => return Some(Int(x | y))
        Xor => return Some(Int(x ^ y))
        // the shift count is taken modulo 64, as with wrapping_shl / wrapping_shr
        Shl => return Some(Int(x << (y & 63)))
        Shr => return Some(Int(x >> (y & 63)))
        Eq => return Some(Bool(x == y))
        Ne => return Some(Bool(x != y))
        Lt => return Some(Bool(x < y))
        Le => return Some(Bool(x <= y))
        Gt => return Some(Bool(x > y))
        Ge => return Some(Bool(x >= y))
        _ => {}
    }
    return None
}

// the operand of a mixed / float operation as a float: (value, ok)
priv fn const_float_operand(cx: *Cx, e: *Expr) -> (f64, bool) {
    match cx.const_eval(e) {
        Some(Int(i)) => (f64(i), true)
        Some(Float(f)) => (f, true)
        _ => (0.0, false)
    }
}

// float (op) float, with integers converted; the operands are evaluated again
priv fn const_bin_float(cx: *Cx, op: BinOp, a: *Expr, b: *Expr) -> Opt[CV] {
    x, xok := const_float_operand(cx, a)
    if !xok {
        return None
    }
    y, yok := const_float_operand(cx, b)
    if !yok {
        return None
    }
    match op {
        Add => Some(Float(x + y))
        Sub => Some(Float(x - y))
        Mul => Some(Float(x * y))
        Div => Some(Float(x / y))
        Eq => Some(Bool(x == y))
        Ne => Some(Bool(x != y))
        Lt => Some(Bool(x < y))
        Le => Some(Bool(x <= y))
        Gt => Some(Bool(x > y))
        Ge => Some(Bool(x >= y))
        _ => None
    }
}

fn const_eval(self: *Cx, e: *Expr) -> Opt[CV] {
    match e.k {
        Int(n) => return Some(CV.Int(i64(n)))
        Float(f) => return Some(CV.Float(f))
        Bool(b) => return Some(CV.Bool(b))
        Str(s) => return Some(CV.Str(s))
        Ident(n) => {
            if self.const_decls.has(n) {
                match self.const_named(n) {
                    Some(x) => return Some(x.1)
                    None => return None
                }
            }
            return None
        }
        Un(op, x) => {
            match (op, self.const_eval(x)) {
                (Neg, Some(Int(i))) => return Some(CV.Int(-i))
                (BitNot, Some(Int(i))) => return Some(CV.Int(~i))
                (Neg, Some(Float(f))) => return Some(CV.Float(-f))
                (Not, Some(Bool(b))) => return Some(CV.Bool(!b))
                _ => return None
            }
        }
        Bin(op, a, b) => {
            x := match self.const_eval(a) {
                Some(xv) => xv
                None => return None
            }
            y := match self.const_eval(b) {
                Some(yv) => yv
                None => return None
            }
            match (x, y) {
                (Int(xi), Int(yi)) => return const_bin_int(self, op, xi, yi, e.pos)
                (Int(_), Float(_)), (Float(_), Int(_)), (Float(_), Float(_)) => return const_bin_float(self, op, a, b)
                (Bool(xb), Bool(yb)) => {
                    match op {
                        LAnd => return Some(CV.Bool(xb && yb))
                        LOr => return Some(CV.Bool(xb || yb))
                        Eq => return Some(CV.Bool(xb == yb))
                        Ne => return Some(CV.Bool(xb != yb))
                        _ => return None
                    }
                }
                _ => return None
            }
        }
        Call(c, args) => {
            match c.k {
                // embed("file"): the content of a file as a string constant
                Ident("embed") if !self.fn_names.has("embed") => {
                    match self.embed_bytes(args.items(), e.pos) {
                        Some(bytes) => return Some(CV.Str(bytes))
                        None => return None
                    }
                }
                _ => {}
            }
            if args.len == 1 {
                // numeric conversion of a constant: T(x); sizeof[T]()
                env := map[str, i64]()
                t := match self.expr_type(c, &env) {
                    Some(ct) => ct
                    None => return None
                }
                v := match self.const_eval(&args[0]) {
                    Some(av) => av
                    None => return None
                }
                match (self.types.k(t), v) {
                    (Int(bits, signed), Int(i)) => return Some(CV.Int(wrap_int(i, bits, signed)))
                    (Int(bits, signed), Float(f)) => return Some(CV.Int(wrap_int(f64_to_i64(f), bits, signed)))
                    (F64, Int(i)) => return Some(CV.Float(f64(i)))
                    (F64, Float(f)) => return Some(CV.Float(f))
                    (F32, Int(i)) => return Some(CV.Float(f64(f32(i))))
                    (F32, Float(f)) => return Some(CV.Float(f64(f32(f))))
                    _ => return None
                }
            }
            if args.is_empty() {
                match c.k {
                    Index(b, targs) => {
                        is_sizeof := match b.k {
                            Ident("sizeof") => true
                            _ => false
                        }
                        if is_sizeof && targs.len == 1 {
                            env := map[str, i64]()
                            match self.expr_type(&targs[0], &env) {
                                Some(t) => return Some(CV.Int(self.types.size_of(t)))
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
priv fn const_init(self: *Cx, e: *Expr, ty: i64, off: i64, data: *Vec[u8], relocs: *Vec[(i64, RelocTarget)]) -> bool {
    k := self.types.k(ty)
    match e.k {
        Lit(te, items) => {
            match k {
                Array(et, n) => {
                    env := map[str, i64]()
                    match self.expr_type(te, &env) {
                        Some(t) if t == ty => {}
                        _ => return false
                    }
                    if items.len > n {
                        self.err(e.pos, fmt("too many elements in array literal (max ", n, ")"))
                        return false
                    }
                    es := self.types.size_of(et)
                    for i in 0..items.len {
                        if is_some(items[i].0) {
                            return false
                        }
                        if !self.const_init(&items[i].1, et, off + i * es, data, relocs) {
                            return false
                        }
                    }
                    return true
                }
                Struct(sid) => {
                    env := map[str, i64]()
                    match self.expr_type(te, &env) {
                        Some(t) if t == ty => {}
                        _ => return false
                    }
                    self.types.layout_struct(sid)
                    fields := self.types.structs[sid].fields
                    offs := clone(self.types.structs[sid].offsets)
                    for i in 0..items.len {
                        fi := i
                        match items[i].0 {
                            Some(n) => {
                                fi = -1
                                for j in 0..fields.len {
                                    if fields[j].0 == n {
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
                        if !self.const_init(&items[i].1, fields[fi].1, off + offs[fi], data, relocs) {
                            return false
                        }
                    }
                    return true
                }
                _ => {}
            }
        }
        Tuple(es) => {
            match k {
                Tuple(tys) => {
                    if es.len != tys.len {
                        return false
                    }
                    offs := self.types.tuple_offsets(tys.items())
                    for i in 0..es.len {
                        if !self.const_init(&es[i], tys[i], off + offs[i], data, relocs) {
                            return false
                        }
                    }
                    return true
                }
                _ => {}
            }
        }
        Ident(n) => {
            if self.const_is_mem(n) {
                // another constant in read-only memory: copy its bytes
                match self.const_global(n) {
                    Some(g) => {
                        if g.0 != ty {
                            return false
                        }
                        match self.module.globals[g.1].data {
                            Some(src) => {
                                for i in 0..src.len {
                                    data[off + i] = src[i]
                                }
                            }
                            None => {}
                        }
                        srel := self.module.globals[g.1].relocs
                        for i in 0..srel.len {
                            relocs.push((off + srel[i].0, srel[i].1))
                        }
                        return true
                    }
                    None => return false
                }
            }
            match k {
                Enum(eid) => {
                    // a variant of an enum without data
                    vi := self.variant_of(self.types.enums[eid].decl, n)
                    if vi >= 0 && self.types.enums[eid].simple {
                        put_le(data, off, u64(vi), 8)
                        return true
                    }
                    return false
                }
                Fn(ptys, rty) => {
                    // address of a (non-generic) function
                    di := match self.find_fn(n) {
                        Some(fdi) if self.fn_decls[fdi].tparams.is_empty() => fdi
                        _ => return false
                    }
                    fid := self.inst_fn(di, vec[i64]())
                    sig := self.fn_sigs[fid]
                    if sig.0.items() != ptys.items() || sig.1 != rty {
                        self.err(e.pos, fmt("function `", n, "` does not have the type ", self.types.name(ty)))
                        return false
                    }
                    relocs.push((off, Function(fid)))
                    return true
                }
                _ => {}
            }
        }
        Nil => {
            match k {
                Ptr(_), Fn(_, _) => return true
                _ => {}
            }
        }
        Call(c, args) => {
            // vec3(1.0, 2.0, 3.0) with constant components; mat4 from four constant columns
            is_vec := false
            n := 4
            et := T_F32
            es := 4
            match k {
                Mat4 => {
                    is_vec = true
                    et = T_VEC4
                    es = 16
                }
                Vec(vn) => {
                    is_vec = true
                    n = vn
                }
                Quat => {
                    is_vec = true
                }
                _ => {}
            }
            if is_vec {
                env := map[str, i64]()
                match self.expr_type(c, &env) {
                    Some(t) if t == ty => {}
                    _ => return false
                }
                if args.len != n {
                    return false
                }
                for i in 0..args.len {
                    if !self.const_init(&args[i], et, off + i * es, data, relocs) {
                        return false
                    }
                }
                return true
            }
        }
        _ => {}
    }
    v := match self.const_eval(e) {
        Some(cv) => cv
        None => return false
    }
    match (k, v) {
        (Int(bits, _), Int(i)) => put_le(data, off, u64(i), bits / 8)
        (F32, Float(f)) => put_le(data, off, u64(cast[u32](f32(f))), 4)
        (F32, Int(i)) => put_le(data, off, u64(cast[u32](f32(i))), 4)
        (F64, Float(f)) => put_le(data, off, cast[u64](f), 8)
        (F64, Int(i)) => put_le(data, off, cast[u64](f64(i)), 8)
        (Bool, Bool(b)) => {
            data[off] = if b { u8(1) } else { u8(0) }
        }
        (Slice(T_U8), Str(s)) => {
            g := self.string_global(s)
            relocs.push((off, Glob(g, 0)))
            put_le(data, off + 8, u64(len(s)), 8)
        }
        _ => return false
    }
    return true
}

priv fn wrap_int(v: i64, bits: i64, signed: bool) -> i64 {
    match (signed, bits) {
        (true, 8) => i64(i8(v))
        (true, 16) => i64(i16(v))
        (true, 32) => i64(i32(v))
        (false, 8) => i64(u8(v))
        (false, 16) => i64(u16(v))
        (false, 32) => i64(u32(v))
        _ => v
    }
}
