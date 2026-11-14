// Semantic analysis + lowering context: declarations, type resolution, constants, globals, instances.

struct Opts {
    checks: bool
}

enum CV {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(str),
    // a variant of an enum without data (`const TARGET_OS = Os.Linux`): enum type, variant index
    Variant(i64, i64),
}

fn is_cv_float(o: Opt[CV]) -> bool {
    match o {
        Some(Float(_)) => true
        _ => false
    }
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
    // the import slots of `extern` variables (global ids): the slot holds the C variable's address
    ext_gots: Map[i64, bool]
    // instance tables: the key is (declaration index, type arguments as a slice that is never
    // modified afterwards)
    struct_insts: Map[(i64, []i64), i64]
    enum_insts: Map[(i64, []i64), i64]
    fn_insts: Map[(i64, []i64), i64]
    fn_sigs: Vec[(Vec[i64], i64)]
    work: Vec[(i64, i64, Vec[i64])]
    strings: Map[str, i64]
    // strings of LONG_STRING bytes or more (embedded files): (hash, text, global), see
    // string_global
    long_strings: Vec[(u64, str, i64)]
    // "file:line" strings for run-time failures: (file, line) -> (string global, length)
    locs: Map[(i64, i64), (i64, i64)]
    exposed: Map[i64, bool]
    inst_depth: i64
    // names declared by the library (see `lib_file`): library code always sees these, user
    // code may shadow them
    p_fn_names: Map[str, i64]
    // every definition of a function name (overloads), per layer, in declaration order
    fn_over: Map[str, Vec[i64]]
    p_fn_over: Map[str, Vec[i64]]
    p_struct_names: Map[str, i64]
    p_enum_names: Map[str, i64]
    // the library's constants and globals; one that the program shadows is also in
    // `const_decls` / `global_decls` under an internal name (see cx_new)
    p_const_decls: Map[str, *ConstDecl]
    p_global_decls: Map[str, *GlobalDecl]
    // true while resolving names on behalf of library code
    scope_prelude: bool
    entry_file: i64
    // files whose declarations are only checked when something uses them
    lazy_files: Map[i64, bool]
    // by file: 0 = a file of the program, LIB_CORE / LIB_MODULE = of the library (see
    // `lib_file`); files beyond its end are the program's
    lib_files: Vec[u8]
    // names declared twice in a layer (1 = library, 2 = user; the second declaration was
    // rejected): in that layer the name stands for the error type, which silences what
    // follows from the rejected declaration
    dup_layers: Map[str, i64]
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
    // the same for the enums of the library (see lower_match.al for the lookup rules)
    p_variants: Map[str, Vec[(i64, i64)]]
    // which layers declare a function, type, constant or global of a name: 1 = library, 2 = user
    decl_layers: Map[str, i64]
    // library functions that have a twin `__at_f` with the caller's "file:line" as an extra
    // last parameter: declaration -> twin
    located: Map[i64, i64]
    // the nested and anonymous functions (lower_nested.al)
    nested: Vec[NestedFn]
    // by symbol: the declarations of the name (built from the tables above at the end of
    // cx_new, see index_names); a symbol beyond its length has none. Lookups go through it.
    names: Vec[SymNames]
    lists: Vec[Vec[i64]]
    vlists: Vec[Vec[(i64, i64)]]
}

// for "unknown name" diagnostics: says that `n` exists as a private declaration of another file
fn priv_hint(self: *Cx, n: str) -> str {
    pos, found := self.priv_decls.get(n)
    if !found {
        return ""
    }
    fname := file_name(&self.file_names, pos.file)
    return fmt(" (`", n, "` is declared `priv` in ", fname, ", line ", pos.line, ": a private declaration is visible only inside its own file; remove `priv` there to use it from other files)")
}

// for a call that no visible definition of `n` accepts: says that a private declaration of
// that name exists in another file than the one of the call
fn priv_note(self: *Cx, n: str, at: Pos) -> str {
    pos, found := self.priv_decls.get(n)
    if !found || pos.file == at.file || pos.file < 0 || pos.file >= self.file_names.len {
        return ""
    }
    return fmt(" (a `priv` declaration of `", n, "` exists in ", self.file_names[pos.file], ", line ", pos.line, ": it is visible only inside that file)")
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

// f64 to i64 at compile time, as the processor converts at run time: NaN and values out of
// range give 0x8000000000000000
priv const I64_MIN: i64 = 0x8000_0000_0000_0000

priv fn f64_to_i64(f: f64) -> i64 {
    if f != f || f >= 9223372036854775808.0 || f < -9223372036854775808.0 {
        return I64_MIN
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

// `lib_files` (by file index) tells the files of the library: the run-time library and the
// bundled modules (see `lib_file`)
fn cx_new(decls: []Decl, file_names: Vec[str], opts: Opts, lib_files: Vec[u8]) -> Cx {
    cx := Cx{
        lib_files: lib_files,
        types: types_new(),
        opts: opts,
        file_names: file_names,
        entry_file: 0xFFFF,
    }
    // the latest accepted declaration of a name and the kind of its first one: in the
    // program, and in the library per namespace (a bundled module may declare a value with
    // the name of a type of the core library or the other way round, as a program may)
    user_names := map[str, (Pos, i64)]()
    lib_types := map[str, (Pos, i64)]()
    lib_vals := map[str, (Pos, i64)]()
    // library constants and globals that the program shadows
    shadowed := vec[str]()
    // the layers (1 = library, 2 = user) in which a name is a struct
    struct_layers := map[str, i64]()
    decls: for i in 0..len(decls) {
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
            Global(g) => {
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
        lib := cx.lib_file(pos.file)
        layer := if lib { 1 } else { 2 }
        is_type := kind == 2 || kind == 3
        own := if !lib { &user_names } else if is_type { &lib_types } else { &lib_vals }
        prev, has_prev := own.get(name)
        if !has_prev && lib {
            o, has_o := (if is_type { &lib_vals } else { &lib_types }).get(name)
            if has_o && cx.core_file(o.0.file) == cx.core_file(pos.file) {
                prev, has_prev = (o, true)
            }
        }
        if has_prev {
            if kind == 1 && prev.1 == 1 {
                // another definition of a function name: an overload, chosen by argument type
                sig := lower_new_sig(fp)
                for k in (if lib { &cx.p_fn_over } else { &cx.fn_over }).get_or(name, Vec[i64]{}) {
                    if lower_new_sig(cx.fn_decls[k]) == sig {
                        at := cx.pos_str(cx.fn_decls[k].pos)
                        cx.err(pos, fmt("`", name, "` is already declared with these parameter types at ", at))
                        continue decls
                    }
                }
            } else {
                at := cx.pos_str(prev.0)
                cx.err(pos, fmt("`", name, "` is already declared at ", at))
                // what the rejected declaration would have declared stands for the error type
                cx.dup_layers.set(name, cx.dup_layers.get_or(name, 0) | layer)
                if kind == 3 {
                    for v in ep.variants {
                        cx.dup_layers.set(v.0, cx.dup_layers.get_or(v.0, 0) | layer)
                    }
                }
                continue
            }
        }
        // a user declaration shadows a library declaration of the same name, whichever
        // comes first; types and values are looked up separately, so a function does not hide
        // a type, and functions of both layers are overloads
        visible := true
        other, in_other := (if lib { &user_names } else if is_type { &lib_types } else { &lib_vals }).get(name)
        if in_other && is_type == (other.1 == 2 || other.1 == 3) && !(kind == 1 && other.1 == 1) {
            if lib {
                visible = false
            } else if is_type {
                cx.struct_names.del(name)
                cx.enum_names.del(name)
            } else {
                cx.fn_names.del(name)
                cx.const_decls.del(name)
                cx.global_decls.del(name)
            }
            if other.1 == 4 || other.1 == 5 || kind == 4 || kind == 5 {
                shadowed.push(name)
            }
        }
        own.set(name, (pos, if has_prev { prev.1 } else { kind }))
        cx.decl_layers.set(name, cx.decl_layers.get_or(name, 0) | layer)
        if kind == 2 {
            struct_layers.set(name, struct_layers.get_or(name, 0) | layer)
        }
        match kind {
            1 => {
                di := cx.fn_decls.len
                if lib {
                    if !cx.p_fn_names.has(name) {
                        cx.p_fn_names.set(name, di)
                    }
                    l, _ := cx.p_fn_over.get(name)
                    l.push(di)
                    cx.p_fn_over.set(name, l)
                    if visible && !cx.fn_names.has(name) {
                        cx.fn_names.set(name, di)
                    }
                } else {
                    // the first user definition is what the plain name refers to
                    if !cx.fn_over.has(name) {
                        cx.fn_names.set(name, di)
                    }
                    l, _ := cx.fn_over.get(name)
                    l.push(di)
                    cx.fn_over.set(name, l)
                }
                cx.fn_decls.push(fp)
            }
            2 => {
                if lib {
                    cx.p_struct_names.set(name, cx.struct_decls.len)
                }
                if visible {
                    cx.struct_names.set(name, cx.struct_decls.len)
                }
                cx.struct_decls.push(sp)
            }
            3 => {
                if lib {
                    cx.p_enum_names.set(name, cx.enum_decls.len)
                }
                if visible {
                    cx.enum_names.set(name, cx.enum_decls.len)
                }
                cx.enum_decls.push(ep)
            }
            4 => {
                if lib {
                    cx.p_const_decls.set(name, cp)
                }
                if visible {
                    cx.const_decls.set(name, cp)
                }
            }
            _ => {
                if lib {
                    cx.p_global_decls.set(name, gp)
                }
                if visible {
                    cx.global_decls.set(name, gp)
                }
            }
        }
    }
    // a library constant or global that the program shadows gets an internal name (as a
    // private declaration does, see priv.al) under which its value and storage are kept
    // apart from the program's declaration
    for name in shadowed {
        cd, has_c := cx.p_const_decls.get(name)
        if has_c && cd.name == name {
            cd.name = ast_intern(fmt(name, "\x01", cd.pos.file))
            ast_sym(cd.name)
            cx.const_decls.set(cd.name, cd)
        }
        gd, has_g := cx.p_global_decls.get(name)
        if has_g && gd.name == name {
            gd.name = ast_intern(fmt(name, "\x01", gd.pos.file))
            ast_sym(gd.name)
            cx.global_decls.set(gd.name, gd)
        }
    }
    // library functions with a twin that takes the place of the call (see `call_fn`)
    for di in 0..cx.fn_decls.len {
        d := cx.fn_decls[di]
        if !cx.lib_file(d.pos.file) || !starts_with(d.name, "__at_") {
            continue
        }
        l, has := cx.p_fn_over.get(d.name[5..])
        if has {
            for c in l {
                if lower_new_sig(d) == fmt(lower_new_sig(cx.fn_decls[c]), ",str") {
                    cx.located.set(c, di)
                }
            }
        }
    }
    // enum variants: two enums may use the same variant name, and a variant may have the
    // name of a struct (a struct name is a type; `Name{...}` is always the struct literal).
    // Within a layer (library / user) it must not have the name of a function, constant,
    // global or enum
    for ei in 0..cx.enum_decls.len {
        e := cx.enum_decls[ei]
        layer := if cx.lib_file(e.pos.file) { 1 } else { 2 }
        variants: for vi in 0..e.variants.len {
            vn := e.variants[vi].0
            if cx.decl_layers.get_or(vn, 0) & layer != 0 && struct_layers.get_or(vn, 0) & layer == 0 {
                d := if layer == 2 { user_names.get_or(vn, (e.pos, 3)) } else { lib_vals.get_or(vn, lib_types.get_or(vn, (e.pos, 3))) }
                what := match d.1 { 4 => "constant"; 5 => "global variable"; 1 => "function"; _ => "enum" }
                cx.err(e.pos, fmt("variant `", vn, "` of enum `", e.name, "` has the name of the ", what, " `", vn, "` declared at ", cx.pos_str(d.0), "; a variant can share its name with variants of other enums and with a struct, not with a function, constant, global variable or enum"))
                continue
            }
            for vj in 0..vi {
                if e.variants[vj].0 == vn {
                    cx.err(e.pos, fmt("enum `", e.name, "` declares the variant `", vn, "` twice"))
                    continue variants
                }
            }
            vm := if layer == 1 { &cx.p_variants } else { &cx.variants }
            l, _ := vm.get(vn)
            l.push((ei, vi))
            vm.set(vn, l)
        }
    }
    cx.index_names()
    return cx
}

// What the declarations say about one symbol (see `Cx.names`); -1 / empty / nil for none
struct SymNames {
    fn_name: i64
    p_fn_name: i64
    struct_name: i64
    p_struct_name: i64
    enum_name: i64
    p_enum_name: i64
    // an index into `Cx.lists` (the overloads of a function name) / `Cx.vlists` (the
    // variants of a name), or -1
    fn_over: i64
    p_fn_over: i64
    variants: i64
    p_variants: i64
    layers: i64
    // the layers in which the name is declared twice (see `Cx.dup_layers`)
    dup: i64
    // the visible constant / global, and the library's own
    const_decl: *ConstDecl
    global_decl: *GlobalDecl
    p_const_decl: *ConstDecl
    p_global_decl: *GlobalDecl
}

// fills `names` from the tables of declared names, which are complete after cx_new
priv fn index_names(self: *Cx) {
    // (every name is a symbol before the table gets its length)
    for n in self.decl_layers.keys() {
        ast_sym(n)
    }
    for n in self.variants.keys() {
        ast_sym(n)
    }
    for n in self.p_variants.keys() {
        ast_sym(n)
    }
    for n in self.dup_layers.keys() {
        ast_sym(n)
    }
    self.names.resize(ast_sym_count(), SymNames{fn_name: -1, p_fn_name: -1, struct_name: -1, p_struct_name: -1, enum_name: -1, p_enum_name: -1, fn_over: -1, p_fn_over: -1, variants: -1, p_variants: -1})
    for n in self.fn_names.keys() {
        self.names[ast_sym(n)].fn_name = self.fn_names.get_or(n, -1)
    }
    for n in self.p_fn_names.keys() {
        self.names[ast_sym(n)].p_fn_name = self.p_fn_names.get_or(n, -1)
    }
    for n in self.struct_names.keys() {
        self.names[ast_sym(n)].struct_name = self.struct_names.get_or(n, -1)
    }
    for n in self.p_struct_names.keys() {
        self.names[ast_sym(n)].p_struct_name = self.p_struct_names.get_or(n, -1)
    }
    for n in self.enum_names.keys() {
        self.names[ast_sym(n)].enum_name = self.enum_names.get_or(n, -1)
    }
    for n in self.p_enum_names.keys() {
        self.names[ast_sym(n)].p_enum_name = self.p_enum_names.get_or(n, -1)
    }
    for n in self.fn_over.keys() {
        l, _ := self.fn_over.get(n)
        self.names[ast_sym(n)].fn_over = self.lists.len
        self.lists.push(l)
    }
    for n in self.p_fn_over.keys() {
        l, _ := self.p_fn_over.get(n)
        self.names[ast_sym(n)].p_fn_over = self.lists.len
        self.lists.push(l)
    }
    for n in self.variants.keys() {
        l, _ := self.variants.get(n)
        self.names[ast_sym(n)].variants = self.vlists.len
        self.vlists.push(l)
    }
    for n in self.p_variants.keys() {
        l, _ := self.p_variants.get(n)
        self.names[ast_sym(n)].p_variants = self.vlists.len
        self.vlists.push(l)
    }
    for n in self.decl_layers.keys() {
        self.names[ast_sym(n)].layers = self.decl_layers.get_or(n, 0)
    }
    for n in self.dup_layers.keys() {
        self.names[ast_sym(n)].dup = self.dup_layers.get_or(n, 0)
    }
    for n in self.const_decls.keys() {
        d, _ := self.const_decls.get(n)
        self.names[ast_sym(n)].const_decl = d
    }
    for n in self.global_decls.keys() {
        d, _ := self.global_decls.get(n)
        self.names[ast_sym(n)].global_decl = d
    }
    for n in self.p_const_decls.keys() {
        d, _ := self.p_const_decls.get(n)
        self.names[ast_sym(n)].p_const_decl = d
    }
    for n in self.p_global_decls.keys() {
        d, _ := self.p_global_decls.get(n)
        self.names[ast_sym(n)].p_global_decl = d
    }
}

// while resolving for library code: does the library declare `e`'s name as a function,
// constant or global (which hides a value of the program with that name)?
priv fn lib_value(self: *Cx, e: *SymNames) -> bool {
    return self.scope_prelude && (e.p_fn_name >= 0 || e.p_const_decl != nil || e.p_global_decl != nil)
}

// the entry of `names` for the name `n`, or nil if no declaration has that name
priv fn named(self: *Cx, n: str) -> *SymNames {
    id := ast_sym_find(n)
    if id < 0 || id >= self.names.len {
        return nil
    }
    return &self.names[id]
}

fn fn_name(self: *Cx, n: str) -> (i64, bool) {
    e := self.named(n)
    if e == nil || e.fn_name < 0 {
        return (0, false)
    }
    return (e.fn_name, true)
}

fn p_fn_name(self: *Cx, n: str) -> (i64, bool) {
    e := self.named(n)
    if e == nil || e.p_fn_name < 0 {
        return (0, false)
    }
    return (e.p_fn_name, true)
}

fn has_fn_name(self: *Cx, n: str) -> bool {
    e := self.named(n)
    return e != nil && e.fn_name >= 0
}

fn has_p_fn_over(self: *Cx, n: str) -> bool {
    e := self.named(n)
    return e != nil && e.p_fn_over >= 0
}

// the user's / the prelude's definitions of the function name `n`
fn fn_over_of(self: *Cx, n: str) -> (Vec[i64], bool) {
    e := self.named(n)
    if e == nil || e.fn_over < 0 {
        return (vec[i64](), false)
    }
    return (self.lists[e.fn_over], true)
}

fn user_variants(self: *Cx, n: str) -> (Vec[(i64, i64)], bool) {
    e := self.named(n)
    if e == nil || e.variants < 0 {
        return (vec[(i64, i64)](), false)
    }
    return (self.vlists[e.variants], true)
}

fn lib_variants(self: *Cx, n: str) -> (Vec[(i64, i64)], bool) {
    e := self.named(n)
    if e == nil || e.p_variants < 0 {
        return (vec[(i64, i64)](), false)
    }
    return (self.vlists[e.p_variants], true)
}

// which layers declare a function, type, constant or global of the name: 1 = library, 2 = user
fn decl_layer(self: *Cx, n: str) -> i64 {
    e := self.named(n)
    if e == nil {
        return 0
    }
    return e.layers
}

// is `n` declared twice in the layer being compiled (it stands for the error type there)?
fn is_dup(self: *Cx, n: str) -> bool {
    if self.dup_layers.len == 0 {
        return false
    }
    e := self.named(n)
    return e != nil && e.dup & (if self.scope_prelude { 1 } else { 2 }) != 0
}

// the constant / global `n` as the layer being compiled sees it, or nil
priv fn const_of(self: *Cx, n: str) -> *ConstDecl {
    e := self.named(n)
    if e == nil {
        return nil
    }
    if self.scope_prelude && e.p_const_decl != nil {
        return e.p_const_decl
    }
    if self.lib_value(e) {
        return nil
    }
    return e.const_decl
}

priv fn global_of(self: *Cx, n: str) -> *GlobalDecl {
    e := self.named(n)
    if e == nil {
        return nil
    }
    if self.scope_prelude && e.p_global_decl != nil {
        return e.p_global_decl
    }
    if self.lib_value(e) {
        return nil
    }
    return e.global_decl
}

fn has_const(self: *Cx, n: str) -> bool {
    return self.const_of(n) != nil
}

fn const_decl(self: *Cx, n: str) -> (*ConstDecl, bool) {
    d := self.const_of(n)
    return (d, d != nil)
}

// the name under which the constant `n` (as seen from here) is evaluated and stored: its
// declaration's (internal for a library constant the program shadows)
priv fn const_key(self: *Cx, n: str) -> str {
    d := self.const_of(n)
    return if d == nil { n } else { d.name }
}

fn has_global(self: *Cx, n: str) -> bool {
    return self.global_of(n) != nil
}

fn global_decl(self: *Cx, n: str) -> (*GlobalDecl, bool) {
    d := self.global_of(n)
    return (d, d != nil)
}

fn find_fn(self: *Cx, n: str) -> Opt[i64] {
    e := self.named(n)
    if e == nil {
        return None
    }
    if self.scope_prelude && e.p_fn_name >= 0 {
        return Some(e.p_fn_name)
    }
    if self.lib_value(e) {
        return None
    }
    if e.fn_name >= 0 {
        return Some(e.fn_name)
    }
    return None
}

// all definitions a call to `n` may resolve to: user definitions first, then the library's
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
    e := self.named(n)
    if e == nil {
        return v
    }
    if self.scope_prelude {
        // library code sees its own definitions; the synthesized entry also reaches user code
        if e.p_fn_over >= 0 {
            return clone(self.lists[e.p_fn_over])
        }
        if e.fn_over >= 0 && !self.lib_value(e) {
            return clone(self.lists[e.fn_over])
        }
        return v
    }
    if e.fn_name < 0 {
        return v
    }
    if e.fn_over >= 0 {
        v.extend(self.lists[e.fn_over].items())
    }
    if e.p_fn_over >= 0 {
        v.extend(self.lists[e.p_fn_over].items())
    }
    return v
}

fn find_struct(self: *Cx, n: str) -> Opt[i64] {
    e := self.named(n)
    if e == nil {
        return None
    }
    if self.scope_prelude && (e.p_struct_name >= 0 || e.p_enum_name >= 0) {
        return if e.p_struct_name >= 0 { Some(e.p_struct_name) } else { None }
    }
    if e.struct_name >= 0 {
        return Some(e.struct_name)
    }
    return None
}

fn find_enum(self: *Cx, n: str) -> Opt[i64] {
    e := self.named(n)
    if e == nil {
        return None
    }
    if self.scope_prelude && (e.p_enum_name >= 0 || e.p_struct_name >= 0) {
        return if e.p_enum_name >= 0 { Some(e.p_enum_name) } else { None }
    }
    if e.enum_name >= 0 {
        return Some(e.enum_name)
    }
    return None
}

// the kinds of library files (`Cx.lib_files`): the core library (`src/prelude*.al` and the
// modules that are always loaded), a bundled module included with `use std.name`
const LIB_CORE: u8 = 1
const LIB_MODULE: u8 = 2

// a file of the library: of the core library or a bundled module. Library code resolves
// names to the library's declarations; the program's declarations of the same names only
// shadow them for the program's code.
fn lib_file(self: *Cx, file: i64) -> bool {
    return file >= 0 && file < self.lib_files.len && self.lib_files[file] != 0
}

fn core_file(self: *Cx, file: i64) -> bool {
    return file >= 0 && file < self.lib_files.len && self.lib_files[file] == LIB_CORE
}

fn internal_file(self: *Cx, file: i64) -> bool {
    return self.lib_file(file) || file == self.entry_file
}

fn pos_str(self: *Cx, p: Pos) -> str {
    fname := file_name(&self.file_names, p.file)
    return fmt(fname, ":", p.line, ":", p.col)
}

// the import slot of the extern function or variable `name`: a new 8-byte global
priv fn got_global(self: *Cx, name: str) -> i64 {
    got := self.module.globals.len
    self.module.globals.push(Global{name: fmt("got.", ast_plain(name)), size: 8, align: 8, data: Some(vec_fill(8, u8(0))), readonly: false})
    return got
}

// the type environment of an instance: type parameter name -> type argument
fn tparam_env(tparams: Vec[str], targs: Vec[i64]) -> Map[str, i64] {
    env := map[str, i64]()
    for i in 0..min(tparams.len, targs.len) {
        env.set(tparams[i], targs[i])
    }
    return env
}

fn err(self: *Cx, pos: Pos, msg: str) {
    self.errs.push(Diag{pos: pos, msg: msg})
}

// the address of a value with alias class `alias` escapes: a scalar field loses its private
// class (`exposed`, applied when the function is finished)
fn expose(self: *Cx, alias: i64) {
    if alias >> 4 != 0 {
        self.exposed.set(alias >> 4, true)
    }
}

// the member names of a struct (its fields) or tuple ("0", "1", ...); none for other types
fn member_names(self: *Cx, ty: i64) -> Vec[str] {
    names := vec[str]()
    match self.types.k(ty) {
        Struct(sid) => {
            for f in self.types.structs[sid].fields {
                names.push(f.0)
            }
        }
        Tuple(ts) => {
            for i in 0..ts.len {
                names.push(fmt(i))
            }
        }
        _ => {}
    }
    return names
}

// `resolve` without its error messages
fn resolve_quiet(self: *Cx, t: *TypeAst, env: *Map[str, i64]) -> i64 {
    saved := self.errs.len
    r := self.resolve(t, env)
    self.errs.truncate(saved)
    return r
}

// `const_eval` without its error messages
fn const_eval_quiet(self: *Cx, e: *Expr) -> Opt[CV] {
    saved := self.errs.len
    r := self.const_eval(e)
    self.errs.truncate(saved)
    return r
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
            if contains(&targs, T_ERR) || self.is_dup(n) {
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
                "float", "double" => " (the floating-point types are f32 and f64; the default is f32)"
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
            // es * ln > 2^31, tested without overflow
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
    if self.inst_too_deep(d.name, targs, pos) {
        return T_ERR
    }
    known, found := self.struct_insts.get((si, targs.items()))
    if found {
        return known
    }
    sid := self.types.structs.len
    name := self.inst_name(ast_plain(d.name), targs.items())
    self.types.instantiating += 1
    self.types.structs.push(StructInfo{
        name: name,
        decl: si,
        targs: clone(targs),
        align: 1,
        state: 3,
    })
    ty := self.types.intern(Struct(sid))
    self.struct_insts.set((si, clone(targs).items()), ty)
    env := tparam_env(d.tparams, targs)
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
    self.types.instantiating -= 1
    return ty
}

fn inst_enum(self: *Cx, ei: i64, targs: Vec[i64], pos: Pos) -> i64 {
    d := self.enum_decls[ei]
    if d.tparams.len != targs.len {
        self.err(pos, fmt("enum `", d.name, "` expects ", d.tparams.len, " type argument(s), got ", targs.len))
        return T_ERR
    }
    if self.inst_too_deep(d.name, targs, pos) {
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
    if !simple {
        self.types.instantiating += 1
    }
    self.types.enums.push(EnumInfo{
        name: name,
        decl: ei,
        targs: clone(targs),
        simple: simple,
        size: ENUM_TAG,
        align: ENUM_TAG,
        state: if simple { 2 } else { 3 },
    })
    ty := self.types.intern(Enum(eid))
    self.enum_insts.set((ei, clone(targs).items()), ty)
    env := tparam_env(d.tparams, targs)
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
        self.types.instantiating -= 1
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
// Linux: an aggregate of up to MAX_FLAT scalar leaves travels as those scalars (in registers
// as far as they go); larger ones by reference, results through a hidden pointer.
// Windows (the Microsoft x64 convention, for every function: AL function values are C
// function pointers): an aggregate of 1, 2, 4 or 8 bytes travels as one integer of that size
// (`win_packed`), any other by reference to a copy the caller makes; results the same way,
// larger ones through a hidden pointer that the callee also returns (in rax).
fn abi_param(self: *Cx, t: i64) -> ParamAbi {
    if self.types.is_scalar(t) {
        return Scalar(self.types.scalar_ir(t).0)
    }
    if target_os == TargetWindows {
        match self.win_packed(t) {
            Some(l) => return Flat(l)
            None => return ByRef
        }
    }
    if self.types.leaf_count(t) <= MAX_FLAT {
        l := self.types.leaf_list(t)
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
    if target_os == TargetWindows {
        match self.win_packed(t) {
            Some(l) if l.is_empty() => return RetAbi.None
            Some(l) => return Flat(l)
            None => return SRet
        }
    }
    if self.types.leaf_count(t) <= MAX_FLAT {
        l := self.types.leaf_list(t)
        if l.is_empty() {
            return RetAbi.None
        }
        return Flat(l)
    }
    return SRet
}

// Windows: an aggregate of 1, 2, 4 or 8 bytes as the one integer leaf that holds all its bytes
// (read and written as untyped memory), none for a zero-size one; None: by reference
priv fn win_packed(self: *Cx, t: i64) -> Opt[Vec[Leaf]] {
    it := match self.types.size_of(t) {
        0 => return Some(vec[Leaf]())
        1 => T.I8
        2 => T.I16
        4 => T.I32
        8 => T.I64
        _ => return None
    }
    return Some(vec_one(Leaf{off: 0, t: it, alias: AK_ANY}))
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
            if target_os == TargetWindows {
                // the callee returns the hidden pointer
                f.rets.push(I64)
            }
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

// a generic instantiated with a type argument nested too deeply: it instantiates itself with
// ever larger types (`fn f[T](x: T) { f([]T{x}) }`), which would never end
priv fn inst_too_deep(self: *Cx, name: str, targs: Vec[i64], pos: Pos) -> bool {
    for t in targs {
        if self.types.too_deep(t) {
            self.err(pos, fmt("`", name, "` instantiates itself with ever larger type arguments (a type argument nested more than 40 levels deep, or too large)"))
            return true
        }
    }
    return false
}

// ---------- function instances ----------
fn inst_fn(self: *Cx, di: i64, targs: Vec[i64]) -> i64 {
    known, found := self.fn_insts.get((di, targs.items()))
    if found {
        return known
    }
    d := self.fn_decls[di]
    // too deep: the instance gets a signature but no body, whose lowering would instantiate further
    deep := self.inst_too_deep(d.name, targs, d.pos)
    env := tparam_env(d.tparams, targs)
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
            // a C function: scalar arguments and result only (Windows: structs too, passed as
            // the Microsoft x64 convention passes them)
            bad := -1
            for i in 0..ptys.len + 1 {
                t := if i < ptys.len { ptys[i] } else { rty }
                if t != T_UNIT && t != T_NEVER && t != T_ERR && (!(self.types.is_scalar(t) || target_os == TargetWindows) || is_some(self.types.vec_lanes(t))) {
                    bad = t
                    break
                }
            }
            if bad >= 0 {
                tn := self.types.name(bad)
                what := if target_os == TargetWindows { "pass integers, floats, pointers and structs" } else { "pass integers, floats and pointers" }
                self.err(d.pos, fmt("extern function `", d.name, "`: ", tn, " cannot cross the C boundary (", what, ")"))
            }
            got := self.got_global(d.name)
            f.ext = Some(self.module.externs.len)
            self.module.externs.push(ExternFn{name: ast_plain(d.name), lib: lib, got: got})
        }
        None => {}
    }
    is_ext := is_some(f.ext)
    // function numbers are kept in 32 bits (MInst.tgt of a call)
    assert self.module.funcs.len < 0x7FFFFFFF, "lower: too many functions"
    self.module.funcs.push(f)
    self.fn_sigs.push((ptys, rty))
    self.fn_insts.set((di, clone(targs).items()), fid)
    if !is_ext && !deep {
        self.work.push((fid, di, targs))
    }
    return fid
}

// ---------- strings / globals ----------
// strings from this length on are found by a hash of 8 bytes per step (embedded files are
// long: hashing them byte by byte in `strings` took milliseconds)
priv const LONG_STRING = 1024

priv fn long_hash(s: str) -> u64 {
    n := len(s)
    p := cast[i64](ptr(s))
    h: u64 = u64(n)
    i := 0
    while i + 8 <= n {
        h = (h ^ *cast[*u64](p + i)) * 0x9E3779B97F4A7C15
        h ^= h >> 29
        i += 8
    }
    while i < n {
        h = (h ^ u64(s[i])) * 0x100000001B3
        i += 1
    }
    return h
}

fn string_global(self: *Cx, s: str) -> i64 {
    long := len(s) >= LONG_STRING
    h: u64 = 0
    if long {
        h = long_hash(s)
        for e in self.long_strings {
            if e.0 == h && e.1 == s {
                return e.2
            }
        }
    } else {
        known, found := self.strings.get(s)
        if found {
            return known
        }
    }
    gid := self.module.globals.len
    self.module.globals.push(Global{
        name: fmt(".str", gid),
        size: len(s),
        align: 1,
        data: Some(vec_of(s)),
        readonly: true,
    })
    if long {
        self.long_strings.push((h, s, gid))
    } else {
        self.strings.set(s, gid)
    }
    return gid
}

// the (type, global) of the global variable `name` as seen from here
fn global(self: *Cx, name: str) -> Opt[(i64, i64)] {
    d, has_decl := self.global_decl(name)
    if !has_decl {
        return None
    }
    known, found := self.globals.get(d.name)
    if found {
        return Some(known)
    }
    // (its type and initializer name what its own file sees)
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    r := self.global_new(d)
    self.scope_prelude = save_scope
    return r
}

priv fn global_new(self: *Cx, d: *GlobalDecl) -> Opt[(i64, i64)] {
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
    match d.ext {
        Some(lib) => {
            // a C variable of a shared library: the program has only its import slot, which
            // the dynamic loader fills with the variable's address (no copy relocation)
            got := self.got_global(d.name)
            self.module.externs.push(ExternFn{name: ast_plain(d.name), lib: lib, got: got, data: true})
            self.ext_gots.set(got, true)
            self.globals.set(d.name, (ty, got))
            return Some((ty, got))
        }
        None => {}
    }
    size := self.types.size_of(ty)
    align := max(self.types.align_of(ty), 1)
    gid := self.module.globals.len
    self.module.globals.push(Global{name: ast_plain(d.name), size: size, align: max(align, 8), data: None, readonly: false})
    self.globals.set(d.name, (ty, gid))
    match d.init {
        Some(init) => {
            if ty != T_ERR {
                data := vec_fill(size, u8(0))
                relocs := vec[(i64, RelocTarget)]()
                nerr := self.errs.len
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
                } else if self.errs.len == nerr {
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
        Int(_, _) => return T_I64
        Float(_, _) => return T_F32
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
            // the name of a single non-generic function
            if !self.has_const(n) {
                cands := self.fn_candidates(n)
                if cands.len == 1 && self.fn_decls[cands[0]].tparams.is_empty() {
                    fid := self.inst_fn(cands[0], vec[i64]())
                    sig := self.fn_sigs[fid]
                    return self.types.intern(TyK.Fn(clone(sig.0), sig.1))
                }
            }
        }
        _ => {}
    }
    cv, ct := self.const_eval_t(e)
    match cv {
        Some(Int(_)) => T_I64
        Some(Float(_)) => ct.or(T_F32)
        Some(Bool(_)) => T_BOOL
        Some(Str(_)) => T_STR
        Some(Variant(t, _)) => t
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
            if self.is_dup(n) {
                return Some(T_ERR)
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
                None => return Some(self.inst_enum(is_e.unwrap(), targs, e.pos))
            }
        }
        TypeE(t) => {
            return Some(self.resolve(t, env))
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
    name = self.const_key(name)
    k, known := self.const_kind.get(name)
    if known {
        return k == 2
    }
    d, has := self.const_decl(name)
    if !has {
        return false
    }
    self.const_kind.set(name, 0)
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
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
            match self.types.k(self.expr_type(c, &env).or(T_ERR)) {
                Vec(_), Quat, Mat4 => {
                    mem = true
                }
                _ => {}
            }
            self.scope_prelude = save_scope
            self.errs.truncate(saved)
        }
        Ident(n) => {
            if self.has_const(n) {
                mem = n != name && self.const_is_mem(n)
            } else {
                // the name of a function: its address, relocated like one inside an aggregate
                save_scope := self.scope_prelude
                self.scope_prelude = self.internal_file(d.pos.file)
                mem = self.fn_candidates(n).len != 0
                self.scope_prelude = save_scope
            }
        }
        _ => {}
    }
    self.scope_prelude = save_scope
    self.const_kind.set(name, if mem { 2 } else { 1 })
    return mem
}

// the (type, global) of a constant that lives in read-only memory (see `const_is_mem`)
fn const_global(self: *Cx, name: str) -> Opt[(i64, i64)] {
    name = self.const_key(name)
    d, has_decl := self.const_decl(name)
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
    // (an unknown file is "?", whose directory is "")
    src := file_name(&self.file_names, pos.file)
    dir := if starts_with(src, "<") { env_get("ALC_STD_DIR").0 } else { path_parent(src).or("") }
    path := path_join(dir, rel)
    cached, hit := self.embeds.get(path)
    if hit {
        return Some(cached)
    }
    bytes, ok := read_file(path)
    if ok {
        self.embeds.set(path, bytes)
        return Some(bytes)
    }
    self.err(args[0].pos, fmt("cannot embed `", path, "`: ", os_error(io_error())))
    return None
}

fn const_named(self: *Cx, name: str) -> Opt[(Opt[i64], CV)] {
    name = self.const_key(name)
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
                bd, _ := self.const_decl(name)
                self.err(bd.pos, fmt("constant `", name, "` depends on itself"))
                return None
            }
            Failed => return None
        }
    }
    d, has_decl := self.const_decl(name)
    if !has_decl {
        return None
    }
    self.const_vals.set(d.name, Busy)
    // (its value names what its own file sees)
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    r := self.const_value(d, name)
    self.scope_prelude = save_scope
    return r
}

priv fn const_value(self: *Cx, d: *ConstDecl, name: str) -> Opt[(Opt[i64], CV)] {
    ty: Opt[i64] = None
    want := -1
    match d.ty {
        Some(t) => {
            env := map[str, i64]()
            rt := self.resolve(&t, &env)
            ty = Some(rt)
            want = match self.types.k(rt) {
                Enum(_) => rt
                _ => -1
            }
        }
        None => {}
    }
    // a variant: `const TARGET_OS = Os.Linux`, `const MODE: Mode = Fast`
    save_scope := self.scope_prelude
    self.scope_prelude = self.internal_file(d.pos.file)
    vr := self.const_variant(&d.val, want)
    self.scope_prelude = save_scope
    match vr {
        Some((ety, vi)) => {
            if is_some(ty) && ty != Some(ety) {
                self.err(d.pos, fmt("constant `", name, "` value does not match its declared type"))
            }
            self.const_vals.set(d.name, Done(Some(ety), Variant(ety, vi)))
            return Some((Some(ety), CV.Variant(ety, vi)))
        }
        None => {}
    }
    nerr0 := self.errs.len
    match self.const_eval(&d.val) {
        Some(v0) => {
            v := v0
            // the value's own integer type, if it has one (a typed constant, a conversion)
            vt := const_int_ty(self, &d.val)
            match ty {
                Some(t) => {
                    // typed constant: check/coerce
                    ok := match (self.types.k(t), v0) {
                        (Int(bits, signed), Int(i)) => {
                            v = CV.Int(wrap_int(i, bits, signed))
                            if is_some(vt) {
                                vt == Some(t)
                            } else {
                                // an untyped value must fit, as a literal must
                                if bits < 64 && (i < -(1 << (bits - 1)) || i >= 1 << bits) || dec_lit_over(&d.val, bits, signed) {
                                    self.err(d.val.pos, fmt("constant `", name, "`: value ", match d.val.k { Int(lit, _) => fmt(lit); _ => fmt(i) }, " does not fit in ", self.types.name(t)))
                                }
                                true
                            }
                        }
                        (F64, Int(i)), (F32, Int(i)) => {
                            v = Float(f64(i))
                            !is_some(vt)
                        }
                        (F32, Float(f)) => {
                            v = Float(f64(lit_f32(&d.val, f)))
                            true
                        }
                        (F64, Float(_)), (Bool, Bool(_)), (Slice(T_U8), Str(_)) => true
                        (Enum(_), Variant(et, _)) => et == t
                        _ => false
                    }
                    if !ok {
                        self.err(d.pos, fmt("constant `", name, "` value does not match its declared type"))
                    }
                }
                None => {
                    ty = match v0 {
                        Variant(et, _) => Some(et)
                        _ => vt
                    }
                    if !is_some(vt) && dec_lit_over(&d.val, 64, true) {
                        self.err(d.val.pos, fmt("constant `", name, "`: the decimal literal does not fit in i64 (declare the type, as in `const ", name, ": u64 = ...`, or write it in hex)"))
                    }
                }
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

// A variant of a non-generic enum without data written as a value: `Os.Linux`, or a bare
// `Linux` that the expected enum type `want` (-1: none) has or exactly one enum of this
// layer (else of the other) has. (enum type, variant index)
priv fn const_variant(self: *Cx, e: *Expr, want: i64) -> Opt[(i64, i64)] {
    ei := -1
    vi := -1
    match e.k {
        Ident(n) => {
            if self.has_const(n) {
                return None
            }
            if want >= 0 {
                match self.types.k(want) {
                    Enum(eid) => {
                        ei = self.types.enums[eid].decl
                        vi = self.variant_of(ei, n)
                    }
                    _ => {}
                }
            } else {
                ul, uhas := self.user_variants(n)
                pl, phas := self.lib_variants(n)
                own, own_has, other, other_has := if self.scope_prelude { (pl, phas, ul, uhas) } else { (ul, uhas, pl, phas) }
                bit := if self.scope_prelude { 1 } else { 2 }
                if own_has && own.len == 1 {
                    ei, vi = own[0]
                } else if !own_has && other_has && other.len == 1 && self.decl_layer(n) & bit == 0 {
                    ei, vi = other[0]
                }
            }
        }
        Field(b, n) => {
            match b.k {
                Ident(q) => {
                    if self.has_const(q) || self.has_global(q) {
                        return None
                    }
                    ei = self.qual_enum_name(q)
                    if ei >= 0 {
                        vi = self.variant_of(ei, n)
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
    if ei < 0 || vi < 0 || self.enum_decls[ei].tparams.len != 0 {
        return None
    }
    ety := self.inst_enum(ei, vec[i64](), e.pos)
    match self.types.k(ety) {
        Enum(eid) if self.types.enums[eid].simple => return Some((ety, vi))
        _ => return None
    }
}

// the (enum type, variant index) of an enum constant or a variant (see const_variant)
priv fn const_variant_val(cx: *Cx, e: *Expr, want: i64) -> Opt[(i64, i64)] {
    match e.k {
        Ident(n) if cx.has_const(n) => {
            match cx.const_named(n) {
                Some((_, Variant(t, v))) => return Some((t, v))
                _ => return None
            }
        }
        _ => return cx.const_variant(e, want)
    }
}

// `a == b` of an enum constant and a variant (or another one): whether they are equal; None
// if the operands are not such (at least one must name a constant)
priv fn const_variant_eq(cx: *Cx, a: *Expr, b: *Expr) -> Opt[bool] {
    named := match (a.k, b.k) {
        (Ident(n), _) if cx.has_const(n) => true
        (_, Ident(n)) if cx.has_const(n) => true
        _ => false
    }
    if !named {
        return None
    }
    va := const_variant_val(cx, a, -1)
    vb: Opt[(i64, i64)] = None
    match va {
        Some(x) => {
            vb = const_variant_val(cx, b, x.0)
        }
        None => {
            vb = const_variant_val(cx, b, -1)
            match vb {
                Some(y) => {
                    va = const_variant_val(cx, a, y.0)
                }
                None => return None
            }
        }
    }
    match (va, vb) {
        (Some(x), Some(y)) if x.0 == y.0 => return Some(x.1 == y.1)
        _ => return None
    }
}

// integer (op) integer
priv fn const_bin_int(cx: *Cx, op: BinOp, x: i64, y: i64, pos: Pos) -> Opt[CV] {
    match op {
        Add => return Some(Int(x + y))
        Sub => return Some(Int(x - y))
        Mul => return Some(Int(x * y))
        Div, Rem if y == 0 => {
            cx.err(pos, "division by zero in constant expression")
            return None
        }
        // wrapping: MIN / -1 is MIN, MIN % -1 is 0
        Div if y == -1 => return Some(Int(-x))
        Rem if y == -1 => return Some(Int(0))
        Div => return Some(Int(x / y))
        Rem => return Some(Int(x % y))
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

// The integer type of a constant scalar expression whose type is fixed: a typed constant, a
// conversion `T(x)`, or an operation with such an operand. None: untyped (or not a number).
priv fn const_int_ty(cx: *Cx, e: *Expr) -> Opt[i64] {
    return cx.const_eval_t(e).1
}

// `t` if it is a number type
priv fn const_only_num(cx: *Cx, t: Opt[i64]) -> Opt[i64] {
    return match cx.types.k(t.or(T_ERR)) {
        Int(_, _), F64, F32 => t
        _ => None
    }
}

// `r` wrapped to the integer type `t` (if any)
priv fn const_wrap_t(cx: *Cx, t: Opt[i64], r: i64) -> i64 {
    return match cx.types.k(t.or(T_ERR)) {
        Int(bits, signed) => wrap_int(r, bits, signed)
        _ => r
    }
}

// The value of a constant operator expression together with its number type (see
// `const_int_ty`), in one walk over the expression. An operation on an f32 operand is
// rounded to f32.
fn const_eval_t(self: *Cx, e: *Expr) -> (Opt[CV], Opt[i64]) {
    match e.k {
        Ident(n) if self.has_const(n) => {
            match self.const_named(n) {
                Some(x) => return (Some(x.1), const_only_num(self, x.0))
                None => return (None, None)
            }
        }
        Un(op, x) => {
            xv, t := self.const_eval_t(x)
            match (op, xv) {
                (Neg, Some(Int(i))) => return (Some(CV.Int(const_wrap_t(self, t, -i))), t)
                (BitNot, Some(Int(i))) => return (Some(CV.Int(const_wrap_t(self, t, ~i))), t)
                (Neg, Some(Float(f))) => return (Some(CV.Float(-f)), t)
                (Not, Some(Bool(b))) => return (Some(CV.Bool(!b)), None)
                _ => return (None, None)
            }
        }
        Bin(op, a, b) => {
            if op == Eq || op == Ne {
                match const_variant_eq(self, a, b) {
                    Some(r) => return (Some(CV.Bool(if op == Eq { r } else { !r })), None)
                    None => {}
                }
            }
            xv, ta := self.const_eval_t(a)
            x := match xv {
                Some(v) => v
                None => return (None, None)
            }
            yv, tb := self.const_eval_t(b)
            y := match yv {
                Some(v) => v
                None => return (None, None)
            }
            t := ta
            if !is_some(t) && op != Shl && op != Shr {
                t = tb
            }
            rt: Opt[i64] = match op {
                Add, Sub, Mul, Div, Rem, And, Or, Xor, Shl, Shr => t
                _ => None
            }
            match (x, y) {
                (Int(xi), Int(yi)) => {
                    match self.types.k(t.or(T_ERR)) {
                        Int(bits, signed) => return (const_bin_typed(self, op, xi, yi, bits, signed, e.pos), rt)
                        _ => {}
                    }
                    return (const_bin_int(self, op, xi, yi, e.pos), rt)
                }
                (Int(_), Float(_)), (Float(_), Int(_)), (Float(_), Float(_)) => {
                    // the float type of a typed operand (an integer-typed one is an error later)
                    ft := if ta == Some(T_F64) || ta == Some(T_F32) { ta } else { tb }
                    if ft != Some(T_F64) && ft != Some(T_F32) {
                        ft = None
                    }
                    r := const_bin_float(op, x, y)
                    if !is_some(rt) {
                        return (r, None)
                    }
                    match r {
                        Some(Float(f)) if ft == Some(T_F32) => return (Some(CV.Float(f64(f32(f)))), ft)
                        _ => return (r, ft)
                    }
                }
                (Bool(xb), Bool(yb)) => {
                    match op {
                        LAnd => return (Some(CV.Bool(xb && yb)), None)
                        LOr => return (Some(CV.Bool(xb || yb)), None)
                        Eq => return (Some(CV.Bool(xb == yb)), None)
                        Ne => return (Some(CV.Bool(xb != yb)), None)
                        _ => return (None, None)
                    }
                }
                _ => return (None, None)
            }
        }
        Call(c, args) => {
            v := self.const_eval(e)
            if args.len != 1 {
                return (v, None)
            }
            env := map[str, i64]()
            saved := self.errs.len
            t := self.expr_type(c, &env)
            self.errs.truncate(saved)
            return (v, const_only_num(self, t))
        }
        _ => return (self.const_eval(e), None)
    }
}

// integer (op) integer in the type `Int(bits, signed)`: operands and result wrapped to it
priv fn const_bin_typed(cx: *Cx, op: BinOp, x: i64, y: i64, bits: i64, signed: bool, pos: Pos) -> Opt[CV] {
    if signed || bits < 64 {
        // narrower unsigned values are zero-extended, signed ones sign-extended: the i64
        // operations give the right low bits; shifts and comparisons need care
        match op {
            Shl => return Some(Int(wrap_int(x << (y & (bits - 1)), bits, signed)))
            Shr => return Some(Int(wrap_int(x >> (y & (bits - 1)), bits, signed)))
            _ => {}
        }
        res := const_bin_int(cx, op, x, y, pos)
        match res {
            Some(Int(r)) => return Some(Int(wrap_int(r, bits, signed)))
            _ => return res
        }
    }
    ux := u64(x)
    uy := u64(y)
    match op {
        Div, Rem => {
            if uy == 0 {
                cx.err(pos, "division by zero in constant expression")
                return None
            }
            return Some(Int(i64(if op == Div { ux / uy } else { ux % uy })))
        }
        Shr => return Some(Int(i64(ux >> (uy & 63))))
        Lt => return Some(Bool(ux < uy))
        Le => return Some(Bool(ux <= uy))
        Gt => return Some(Bool(ux > uy))
        Ge => return Some(Bool(ux >= uy))
        _ => return const_bin_int(cx, op, x, y, pos)
    }
}

// float (op) float, with integers converted
priv fn const_bin_float(op: BinOp, xv: CV, yv: CV) -> Opt[CV] {
    x := match xv {
        Int(i) => f64(i)
        Float(f) => f
        _ => return None
    }
    y := match yv {
        Int(i) => f64(i)
        Float(f) => f
        _ => return None
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
        Int(n, _) => return Some(CV.Int(i64(n)))
        Float(f, _) => return Some(CV.Float(f))
        Bool(b) => return Some(CV.Bool(b))
        Str(s) => return Some(CV.Str(s))
        Ident(n) if self.has_const(n) => {
            match self.const_named(n) {
                Some(x) => return Some(x.1)
                None => return None
            }
        }
        Un(_, _), Bin(_, _, _) => return self.const_eval_t(e).0
        Call(c, args) => {
            match c.k {
                // embed("file"): the content of a file as a string constant
                Ident("embed") if !self.has_fn_name("embed") => {
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
                // a u64 source: values >= 2^63 are held as negative i64
                src_u64 := const_int_ty(self, &args[0]) == Some(T_U64)
                match (self.types.k(t), v) {
                    (Int(bits, signed), Int(i)) => return Some(CV.Int(wrap_int(i, bits, signed)))
                    (Int(64, false), Float(f)) => {
                        if f >= 9223372036854775808.0 {
                            // as at run time (also beyond 2^64)
                            return Some(CV.Int(f64_to_i64(f - 9223372036854775808.0) ^ I64_MIN))
                        }
                        return Some(CV.Int(f64_to_i64(f)))
                    }
                    (Int(bits, signed), Float(f)) => return Some(CV.Int(wrap_int(f64_to_i64(f), bits, signed)))
                    (F64, Int(i)) => return Some(CV.Float(if src_u64 { f64(u64(i)) } else { f64(i) }))
                    (F64, Float(f)) => return Some(CV.Float(f))
                    (F32, Int(i)) => {
                        if src_u64 && i < 0 {
                            // halved with the sticky bit, converted once and doubled
                            h := f32(i64((u64(i) >> 1) | (u64(i) & 1)))
                            return Some(CV.Float(f64(h + h)))
                        }
                        return Some(CV.Float(f64(f32(i))))
                    }
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
                            Some(src) => copy(data[off..], src.items())
                            None => {}
                        }
                        for r in self.module.globals[g.1].relocs {
                            relocs.push((off + r.0, r.1))
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
                        put_le(data, off, u64(vi), ENUM_TAG)
                        return true
                    }
                    return false
                }
                Fn(ptys, rty) => {
                    // address of a (non-generic) function; of an overloaded name the
                    // definition of this type
                    cands := self.fn_candidates(n)
                    plain := 0
                    for ci in 0..cands.len {
                        if !self.fn_decls[cands[ci]].tparams.is_empty() {
                            continue
                        }
                        plain += 1
                        fid := self.inst_fn(cands[ci], vec[i64]())
                        sig := self.fn_sigs[fid]
                        if sig.0.items() == ptys.items() && sig.1 == rty {
                            if is_some(self.module.funcs[fid].ext) {
                                self.err(e.pos, fmt("the address of the C function `", n, "` is known only at run time: it cannot be part of a constant or a global initializer"))
                                return false
                            }
                            relocs.push((off, Func(fid)))
                            return true
                        }
                    }
                    if plain != 0 {
                        self.err(e.pos, fmt("function `", n, "` does not have the type ", self.types.name(ty)))
                    }
                    return false
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
    vt := const_int_ty(self, e)
    match (k, v) {
        (Int(bits, signed), Int(i)) => {
            if is_some(vt) {
                if vt != Some(ty) {
                    self.err(e.pos, fmt("type mismatch: expected ", self.types.name(ty), ", found ", self.types.name(vt.or(T_ERR))))
                    return false
                }
            } else if bits < 64 && (i < -(1 << (bits - 1)) || i >= 1 << bits) || dec_lit_over(e, bits, signed) {
                self.err(e.pos, fmt("integer constant ", i, " does not fit in ", self.types.name(ty)))
            }
            put_le(data, off, u64(i), bits / 8)
        }
        (F32, Float(f)) => put_le(data, off, u64(cast[u32](lit_f32(e, f))), 4)
        (F32, Int(i)) if !is_some(vt) => put_le(data, off, u64(cast[u32](f32(i))), 4)
        (F64, Float(f)) => put_le(data, off, cast[u64](f), 8)
        (F64, Int(i)) if !is_some(vt) => put_le(data, off, cast[u64](f64(i)), 8)
        (F32, Int(_)), (F64, Int(_)) => {
            self.err(e.pos, fmt("type mismatch: expected ", self.types.name(ty), ", found ", self.types.name(vt.or(T_ERR))))
            return false
        }
        (Bool, Bool(b)) => {
            data[off] = if b { u8(1) } else { u8(0) }
        }
        (Enum(_), Variant(t, vi)) if t == ty => put_le(data, off, u64(vi), ENUM_TAG)
        (Slice(T_U8), Str(s)) => {
            g := self.string_global(s)
            relocs.push((off, Global(g, 0)))
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

// `f` as an f32; a float literal (also negated) is rounded once from its text
priv fn lit_f32(e: *Expr, f: f64) -> f32 {
    match e.k {
        Float(_, g) => return g
        Un(Neg, x) => return -lit_f32(x, -f)
        _ => return f32(f)
    }
}

// a decimal literal (also negated) beyond the range of Int(bits, signed); hex, binary,
// octal and character literals may be bit patterns
priv fn dec_lit_over(e: *Expr, bits: i64, signed: bool) -> bool {
    match e.k {
        Int(n, true) => return n > (if signed { (u64(1) << u64(bits - 1)) - 1 } else { u64(0xFFFFFFFFFFFFFFFF) >> u64(64 - bits) })
        Un(Neg, x) => {
            match x.k {
                Int(n, true) => return n > u64(1) << u64(bits - 1)
                _ => return false
            }
        }
        _ => return false
    }
}

// the f32 value of the untyped float constant `name` whose value is `f`: a literal (also
// negated) is rounded once from its text
fn const_lit_f32(self: *Cx, name: str, f: f64) -> f32 {
    d, has := self.const_decl(name)
    if !has {
        return f32(f)
    }
    return lit_f32(&d.val, f)
}

// an untyped constant expression counts as written in decimal (and must fit the type it is
// used as) unless its integer literals are hex / binary / octal / characters
fn const_expr_dec(self: *Cx, e: *Expr, depth: i64) -> bool {
    if depth > 50 {
        return true
    }
    match e.k {
        Int(_, dec) => return dec
        Un(_, x) => return self.const_expr_dec(x, depth + 1)
        Bin(_, a, b) => return self.const_expr_dec(a, depth + 1) && self.const_expr_dec(b, depth + 1)
        Ident(n) => {
            d, has := self.const_decl(n)
            if has {
                return self.const_expr_dec(&d.val, depth + 1)
            }
            return true
        }
        _ => return true
    }
}
