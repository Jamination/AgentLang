// Semantic analysis + lowering context: declarations, type resolution, constants, globals, instances.
use crate::ast::*;
use crate::ir::{Func, Global, Module, RelocTarget, T};
use crate::types::*;
use std::collections::{HashMap, HashSet};

pub struct Opts {
    pub checks: bool,
}

#[derive(Clone, Debug)]
pub enum CV {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(Vec<u8>),
}

pub enum CState {
    Busy,
    Done(Option<Ty>, CV),
    Failed,
}

#[derive(Clone)]
pub enum ParamAbi {
    Scalar(T),
    Flat(Vec<Leaf>),
    ByRef,
}

#[derive(Clone)]
pub enum RetAbi {
    None,
    Scalar(T),
    Flat(Vec<Leaf>),
    SRet,
}

pub const MAX_FLAT: u64 = 4;

pub struct Cx<'a> {
    pub types: Types,
    pub module: Module,
    pub errs: Vec<Diag>,
    pub opts: Opts,
    pub file_names: Vec<String>,
    pub fn_decls: Vec<&'a FnDecl>,
    pub fn_names: HashMap<&'a str, usize>,
    pub struct_decls: Vec<&'a StructDecl>,
    pub struct_names: HashMap<&'a str, usize>,
    pub enum_decls: Vec<&'a EnumDecl>,
    pub enum_names: HashMap<&'a str, usize>,
    pub variants: HashMap<&'a str, (usize, usize)>,
    pub const_decls: HashMap<&'a str, &'a ConstDecl>,
    pub const_vals: HashMap<&'a str, CState>,
    pub global_decls: HashMap<&'a str, &'a GlobalDecl>,
    pub globals: HashMap<&'a str, (Ty, u32)>,
    pub struct_insts: HashMap<(usize, Vec<Ty>), Ty>,
    pub enum_insts: HashMap<(usize, Vec<Ty>), Ty>,
    pub fn_insts: HashMap<(usize, Vec<Ty>), u32>,
    pub fn_sigs: Vec<(Vec<Ty>, Ty)>,
    pub work: Vec<(u32, usize, Vec<Ty>)>,
    pub strings: HashMap<Vec<u8>, u32>,
    pub exposed: HashSet<u32>,
    pub inst_depth: u32,
    // names declared by the prelude: prelude code always sees these, user code may shadow them
    pub p_fn_names: HashMap<&'a str, usize>,
    // every definition of a function name (overloads), per layer, in declaration order
    pub fn_over: HashMap<&'a str, Vec<usize>>,
    pub p_fn_over: HashMap<&'a str, Vec<usize>>,
    pub p_struct_names: HashMap<&'a str, usize>,
    pub p_enum_names: HashMap<&'a str, usize>,
    // true while resolving names on behalf of prelude code
    pub scope_prelude: bool,
    pub entry_file: u16,
    // files whose declarations are only checked when something uses them
    pub lazy_files: HashSet<u16>,
    pub n_prelude: u16,
}

pub fn builtin_type(name: &str) -> Option<Ty> {
    Some(match name {
        "i8" => T_I8,
        "i16" => T_I16,
        "i32" => T_I32,
        "i64" => T_I64,
        "u8" => T_U8,
        "u16" => T_U16,
        "u32" => T_U32,
        "u64" => T_U64,
        "f64" => T_F64,
        "f32" => T_F32,
        "vec2" => T_VEC2,
        "vec3" => T_VEC3,
        "vec4" => T_VEC4,
        "quat" => T_QUAT,
        "mat4" => T_MAT4,
        "bool" => T_BOOL,
        "str" => T_STR,
        "never" => T_NEVER,
        _ => return None,
    })
}

impl<'a> Cx<'a> {
    // files with an index below `n_prelude` form the always-present core library
    pub fn new(decls: &'a [Decl], file_names: Vec<String>, opts: Opts, n_prelude: u16) -> Cx<'a> {
        let np = n_prelude;
        let mut cx = Cx {
            n_prelude,
            types: Types::new(),
            module: Module { funcs: Vec::new(), globals: Vec::new(), entry: 0, externs: Vec::new() },
            errs: Vec::new(),
            opts,
            file_names,
            fn_decls: Vec::new(),
            fn_names: HashMap::new(),
            struct_decls: Vec::new(),
            struct_names: HashMap::new(),
            enum_decls: Vec::new(),
            enum_names: HashMap::new(),
            variants: HashMap::new(),
            const_decls: HashMap::new(),
            const_vals: HashMap::new(),
            global_decls: HashMap::new(),
            globals: HashMap::new(),
            struct_insts: HashMap::new(),
            enum_insts: HashMap::new(),
            fn_insts: HashMap::new(),
            fn_sigs: Vec::new(),
            work: Vec::new(),
            strings: HashMap::new(),
            exposed: HashSet::new(),
            inst_depth: 0,
            p_fn_names: HashMap::new(),
            fn_over: HashMap::new(),
            p_fn_over: HashMap::new(),
            p_struct_names: HashMap::new(),
            p_enum_names: HashMap::new(),
            scope_prelude: false,
            entry_file: u16::MAX,
            lazy_files: HashSet::new(),
        };
        let mut names: HashMap<&'a str, Pos> = HashMap::new();
        // is the visible declaration of a name a function?
        let mut names_fn: HashMap<&'a str, bool> = HashMap::new();
        for d in decls {
            let (name, pos): (&'a str, Pos) = match d {
                Decl::Fn(f) => (&f.name, f.pos),
                Decl::Struct(s) => (&s.name, s.pos),
                Decl::Enum(e) => (&e.name, e.pos),
                Decl::Const(c) => (&c.name, c.pos),
                Decl::Global(g) => (&g.name, g.pos),
                _ => continue,
            };
            if builtin_type(name).is_some() {
                cx.err(pos, format!("`{}` is a builtin type name", name));
                continue;
            }
            if let Some(prev) = names.get(name) {
                let layer = if pos.file < np { &cx.p_fn_over } else { &cx.fn_over };
                if let (Decl::Fn(f), Some(true)) = (d, names_fn.get(name)) {
                    // another definition of a function name: an overload, chosen by argument type
                    let sig = |g: &FnDecl| g.params.iter().map(|p| type_str(&p.1)).collect::<Vec<_>>().join(",");
                    let dup = layer.get(name).and_then(|l| l.iter().find(|di| sig(cx.fn_decls[**di]) == sig(f)).copied());
                    if let Some(di) = dup {
                        let at = cx.pos_str(cx.fn_decls[di].pos);
                        cx.err(pos, format!("`{}` is already declared with these parameter types at {}", name, at));
                        continue;
                    }
                } else if prev.file < np && pos.file >= np {
                    // a user declaration shadows a prelude declaration of the same name; types
                    // and values are looked up separately, so a function does not hide a type
                    if matches!(d, Decl::Struct(_) | Decl::Enum(_)) {
                        cx.struct_names.remove(name);
                        cx.enum_names.remove(name);
                    } else {
                        cx.fn_names.remove(name);
                        cx.const_decls.remove(name);
                        cx.global_decls.remove(name);
                    }
                } else {
                    let at = cx.pos_str(*prev);
                    cx.err(pos, format!("`{}` is already declared at {}", name, at));
                    continue;
                }
            }
            names.insert(name, pos);
            names_fn.insert(name, matches!(d, Decl::Fn(_)));
            match d {
                Decl::Fn(f) => {
                    let di = cx.fn_decls.len();
                    if pos.file < np {
                        cx.p_fn_names.entry(&f.name).or_insert(di);
                        cx.p_fn_over.entry(&f.name).or_default().push(di);
                        cx.fn_names.entry(&f.name).or_insert(di);
                    } else {
                        // the first user definition is what the plain name refers to
                        if !cx.fn_over.contains_key(name) {
                            cx.fn_names.insert(&f.name, di);
                        }
                        cx.fn_over.entry(&f.name).or_default().push(di);
                    }
                    cx.fn_decls.push(f);
                }
                Decl::Struct(s) => {
                    if pos.file < np {
                        cx.p_struct_names.insert(&s.name, cx.struct_decls.len());
                    }
                    cx.struct_names.insert(&s.name, cx.struct_decls.len());
                    cx.struct_decls.push(s);
                }
                Decl::Enum(e) => {
                    if pos.file < np {
                        cx.p_enum_names.insert(&e.name, cx.enum_decls.len());
                    }
                    cx.enum_names.insert(&e.name, cx.enum_decls.len());
                    cx.enum_decls.push(e);
                }
                Decl::Const(c) => {
                    cx.const_decls.insert(&c.name, c);
                }
                Decl::Global(g) => {
                    cx.global_decls.insert(&g.name, g);
                }
                _ => {}
            }
        }
        // enum variants live in the global namespace
        for (ei, e) in cx.enum_decls.clone().iter().enumerate() {
            for (vi, (vn, _)) in e.variants.iter().enumerate() {
                if names.contains_key(vn.as_str()) || cx.variants.contains_key(vn.as_str()) {
                    cx.err(e.pos, format!("enum variant `{}` conflicts with another declaration", vn));
                    continue;
                }
                cx.variants.insert(vn, (ei, vi));
            }
        }
        cx
    }

    pub fn find_fn(&self, n: &str) -> Option<usize> {
        if self.scope_prelude {
            if let Some(&i) = self.p_fn_names.get(n) {
                return Some(i);
            }
        }
        self.fn_names.get(n).copied()
    }
    // all definitions a call to `n` may resolve to: user definitions first, then the prelude's
    pub fn fn_candidates(&self, n: &str) -> Vec<usize> {
        let mut v: Vec<usize> = Vec::new();
        if self.scope_prelude {
            // prelude code sees its own definitions; the synthesized entry also reaches user code
            if let Some(l) = self.p_fn_over.get(n) {
                return l.clone();
            }
            return self.fn_over.get(n).cloned().unwrap_or_default();
        }
        if !self.fn_names.contains_key(n) {
            return v;
        }
        if let Some(l) = self.fn_over.get(n) {
            v.extend(l.iter().copied());
        }
        if let Some(l) = self.p_fn_over.get(n) {
            v.extend(l.iter().copied());
        }
        v
    }
    pub fn find_struct(&self, n: &str) -> Option<usize> {
        if self.scope_prelude {
            if let Some(&i) = self.p_struct_names.get(n) {
                return Some(i);
            }
        }
        self.struct_names.get(n).copied()
    }
    pub fn find_enum(&self, n: &str) -> Option<usize> {
        if self.scope_prelude {
            if let Some(&i) = self.p_enum_names.get(n) {
                return Some(i);
            }
        }
        self.enum_names.get(n).copied()
    }
    pub fn internal_file(&self, file: u16) -> bool {
        file < self.n_prelude || file == self.entry_file
    }

    pub fn pos_str(&self, p: Pos) -> String {
        format!("{}:{}:{}", self.file_names.get(p.file as usize).map(|s| s.as_str()).unwrap_or("?"), p.line, p.col)
    }

    pub fn err(&mut self, pos: Pos, msg: String) {
        self.errs.push(Diag { pos, msg });
    }

    // ---------- types ----------
    pub fn resolve(&mut self, t: &TypeAst, env: &HashMap<String, Ty>) -> Ty {
        match t {
            TypeAst::Name(n, args, pos) => {
                if args.is_empty() {
                    if let Some(&t) = env.get(n) {
                        return t;
                    }
                    if let Some(t) = builtin_type(n) {
                        return t;
                    }
                }
                let targs: Vec<Ty> = args.iter().map(|a| self.resolve(a, env)).collect();
                if targs.contains(&T_ERR) {
                    return T_ERR;
                }
                if let Some(si) = self.find_struct(n.as_str()) {
                    return self.inst_struct(si, targs, *pos);
                }
                if let Some(ei) = self.find_enum(n.as_str()) {
                    return self.inst_enum(ei, targs, *pos);
                }
                let hint = match n.as_str() {
                    "int" | "long" | "isize" | "usize" | "uint" | "size_t" => " (integer types are i8 i16 i32 i64 u8 u16 u32 u64; the default is i64)",
                    "float" | "double" | "f32" => " (the floating-point type is f64)",
                    "string" | "String" | "char" | "byte" => " (text is `str`, a byte is `u8`)",
                    "boolean" => " (use `bool`)",
                    "void" => " (omit the result type instead)",
                    _ => "",
                };
                self.err(*pos, format!("unknown type `{}`{}", n, hint));
                T_ERR
            }
            TypeAst::Ptr(e) => {
                let e = self.resolve(e, env);
                if e == T_ERR {
                    return T_ERR;
                }
                self.types.ptr(e)
            }
            TypeAst::Slice(e) => {
                let e = self.resolve(e, env);
                if e == T_ERR {
                    return T_ERR;
                }
                self.types.slice(e)
            }
            TypeAst::Array(n, e) => {
                let e2 = self.resolve(e, env);
                let len = match self.const_eval(n) {
                    Some(CV::Int(v)) if v >= 0 => v as u64,
                    _ => {
                        self.err(n.pos, "array length must be a non-negative integer constant".into());
                        return T_ERR;
                    }
                };
                if e2 == T_ERR {
                    return T_ERR;
                }
                let es = self.types.size_of(e2) as u64;
                if es.saturating_mul(len) > (1u64 << 31) {
                    self.err(n.pos, "array type too large (max 2 GiB)".into());
                    return T_ERR;
                }
                self.types.intern(TyK::Array(e2, len))
            }
            TypeAst::Fn(ps, r) => {
                let ps: Vec<Ty> = ps.iter().map(|p| self.resolve(p, env)).collect();
                let r = match r {
                    Some(r) => self.resolve(r, env),
                    None => T_UNIT,
                };
                if ps.contains(&T_ERR) || r == T_ERR {
                    return T_ERR;
                }
                self.types.intern(TyK::Fn(ps, r))
            }
            TypeAst::Tuple(ts) => {
                let ts: Vec<Ty> = ts.iter().map(|p| self.resolve(p, env)).collect();
                if ts.contains(&T_ERR) {
                    return T_ERR;
                }
                if ts.is_empty() {
                    return T_UNIT;
                }
                self.types.intern(TyK::Tuple(ts))
            }
        }
    }

    fn inst_name(&self, base: &str, targs: &[Ty]) -> String {
        if targs.is_empty() {
            base.to_string()
        } else {
            format!("{}[{}]", base, targs.iter().map(|t| self.types.name(*t)).collect::<Vec<_>>().join(", "))
        }
    }

    pub fn inst_struct(&mut self, si: usize, targs: Vec<Ty>, pos: Pos) -> Ty {
        let d = self.struct_decls[si];
        if d.tparams.len() != targs.len() {
            self.err(pos, format!("struct `{}` expects {} type argument(s), got {}", d.name, d.tparams.len(), targs.len()));
            return T_ERR;
        }
        if let Some(&t) = self.struct_insts.get(&(si, targs.clone())) {
            return t;
        }
        let sid = self.types.structs.len() as u32;
        let name = self.inst_name(&d.name, &targs);
        self.types.structs.push(StructInfo {
            name,
            decl: si,
            targs: targs.clone(),
            fields: Vec::new(),
            offsets: Vec::new(),
            size: 0,
            align: 1,
            state: 0,
        });
        let ty = self.types.intern(TyK::Struct(sid));
        self.struct_insts.insert((si, targs.clone()), ty);
        let mut env = HashMap::new();
        for (n, t) in d.tparams.iter().zip(targs.iter()) {
            env.insert(n.clone(), *t);
        }
        let mut fields = Vec::new();
        let mut seen: HashSet<&str> = HashSet::new();
        let save_scope = self.scope_prelude;
        self.scope_prelude = self.internal_file(d.pos.file);
        for (fname, fty) in &d.fields {
            if !seen.insert(fname) {
                self.err(d.pos, format!("duplicate field `{}` in struct `{}`", fname, d.name));
            }
            let t = self.resolve(fty, &env);
            fields.push((fname.clone(), t));
        }
        self.scope_prelude = save_scope;
        self.types.structs[sid as usize].fields = fields;
        ty
    }

    pub fn inst_enum(&mut self, ei: usize, targs: Vec<Ty>, pos: Pos) -> Ty {
        let d = self.enum_decls[ei];
        if d.tparams.len() != targs.len() {
            self.err(pos, format!("enum `{}` expects {} type argument(s), got {}", d.name, d.tparams.len(), targs.len()));
            return T_ERR;
        }
        if let Some(&t) = self.enum_insts.get(&(ei, targs.clone())) {
            return t;
        }
        let eid = self.types.enums.len() as u32;
        let name = self.inst_name(&d.name, &targs);
        let simple = d.variants.iter().all(|v| v.1.is_empty());
        self.types.enums.push(EnumInfo {
            name,
            decl: ei,
            targs: targs.clone(),
            variants: Vec::new(),
            simple,
            size: 8,
            state: if simple { 2 } else { 0 },
        });
        let ty = self.types.intern(TyK::Enum(eid));
        self.enum_insts.insert((ei, targs.clone()), ty);
        let mut env = HashMap::new();
        for (n, t) in d.tparams.iter().zip(targs.iter()) {
            env.insert(n.clone(), *t);
        }
        let mut vars = Vec::new();
        let save_scope = self.scope_prelude;
        self.scope_prelude = self.internal_file(d.pos.file);
        for (vn, vts) in &d.variants {
            let ts: Vec<Ty> = vts.iter().map(|t| self.resolve(t, &env)).collect();
            vars.push((vn.clone(), ts));
        }
        self.scope_prelude = save_scope;
        self.types.enums[eid as usize].variants = vars;
        ty
    }

    pub fn flush_layout_errors(&mut self, pos: Pos) {
        let errs: Vec<String> = self.types.layout_errors.drain(..).collect();
        for e in errs {
            self.err(pos, e);
        }
    }

    // ---------- ABI ----------
    pub fn abi_param(&mut self, t: Ty) -> ParamAbi {
        if self.types.is_scalar(t) {
            return ParamAbi::Scalar(self.types.scalar_ir(t).0);
        }
        if self.types.leaf_count(t) <= MAX_FLAT {
            let mut l = Vec::new();
            self.types.leaves(t, 0, &mut l);
            return ParamAbi::Flat(l);
        }
        ParamAbi::ByRef
    }

    pub fn abi_ret(&mut self, t: Ty) -> RetAbi {
        if t == T_UNIT || t == T_NEVER || t == T_ERR {
            return RetAbi::None;
        }
        if self.types.is_scalar(t) {
            return RetAbi::Scalar(self.types.scalar_ir(t).0);
        }
        if self.types.leaf_count(t) <= MAX_FLAT {
            let mut l = Vec::new();
            self.types.leaves(t, 0, &mut l);
            if l.is_empty() {
                return RetAbi::None;
            }
            return RetAbi::Flat(l);
        }
        RetAbi::SRet
    }

    // ---------- function instances ----------
    pub fn inst_fn(&mut self, di: usize, targs: Vec<Ty>) -> u32 {
        if let Some(&f) = self.fn_insts.get(&(di, targs.clone())) {
            return f;
        }
        let d = self.fn_decls[di];
        let mut env = HashMap::new();
        for (n, t) in d.tparams.iter().zip(targs.iter()) {
            env.insert(n.clone(), *t);
        }
        let save_scope = self.scope_prelude;
        self.scope_prelude = self.internal_file(d.pos.file);
        let ptys: Vec<Ty> = d.params.iter().map(|p| self.resolve(&p.1, &env)).collect();
        let rty = match &d.ret {
            Some(r) => self.resolve(r, &env),
            None => T_UNIT,
        };
        self.scope_prelude = save_scope;
        self.flush_layout_errors(d.pos);
        let fid = self.module.funcs.len() as u32;
        let mut f = Func::new(&self.inst_name(&d.name, &targs));
        f.inline = d.inline;
        f.noreturn = rty == T_NEVER;
        match self.abi_ret(rty) {
            RetAbi::None => {}
            RetAbi::Scalar(t) => f.rets.push(t),
            RetAbi::Flat(l) => f.rets.extend(l.iter().map(|x| x.t)),
            RetAbi::SRet => f.params.push(T::I64),
        }
        for &pt in &ptys {
            match self.abi_param(pt) {
                ParamAbi::Scalar(t) => f.params.push(t),
                ParamAbi::Flat(l) => f.params.extend(l.iter().map(|x| x.t)),
                ParamAbi::ByRef => f.params.push(T::I64),
            }
        }
        if let Some(lib) = &d.ext {
            // a C function: scalar arguments and result only
            let bad = ptys.iter().chain(std::iter::once(&rty)).copied().find(|t| *t != T_UNIT && *t != T_NEVER && *t != T_ERR && (!self.types.is_scalar(*t) || self.types.vec_lanes(*t).is_some()));
            if let Some(t) = bad {
                let tn = self.types.name(t);
                self.err(d.pos, format!("extern function `{}`: {} cannot cross the C boundary (pass integers, floats and pointers)", d.name, tn));
            }
            let got = self.module.globals.len() as u32;
            self.module.globals.push(Global { name: format!("got.{}", d.name), size: 8, align: 8, data: Some(vec![0; 8]), relocs: Vec::new(), readonly: false });
            f.ext = Some(self.module.externs.len() as u32);
            self.module.externs.push(crate::ir::ExternFn { name: d.name.clone(), lib: lib.clone(), got });
        }
        let is_ext = f.ext.is_some();
        self.module.funcs.push(f);
        self.fn_sigs.push((ptys, rty));
        self.fn_insts.insert((di, targs.clone()), fid);
        if !is_ext {
            self.work.push((fid, di, targs));
        }
        fid
    }

    // ---------- strings / globals ----------
    pub fn string_global(&mut self, s: &[u8]) -> u32 {
        if let Some(&g) = self.strings.get(s) {
            return g;
        }
        let gid = self.module.globals.len() as u32;
        self.module.globals.push(Global {
            name: format!(".str{}", gid),
            size: s.len() as u64,
            align: 1,
            data: Some(s.to_vec()),
            relocs: Vec::new(),
            readonly: true,
        });
        self.strings.insert(s.to_vec(), gid);
        gid
    }

    pub fn global(&mut self, name: &str) -> Option<(Ty, u32)> {
        if let Some(&g) = self.globals.get(name) {
            return Some(g);
        }
        let d = *self.global_decls.get(name)?;
        let env = HashMap::new();
        let mut ty = match &d.ty {
            Some(t) => self.resolve(t, &env),
            None => T_ERR,
        };
        if d.ty.is_none() {
            // infer from initializer
            if let Some(init) = &d.init {
                ty = self.const_type_of(init);
                if ty == T_ERR {
                    self.err(d.pos, format!("cannot infer type of global `{}`; add a type annotation", d.name));
                }
            }
        }
        self.flush_layout_errors(d.pos);
        let size = self.types.size_of(ty) as u64;
        let align = self.types.align_of(ty).max(1);
        let gid = self.module.globals.len() as u32;
        self.module.globals.push(Global { name: d.name.clone(), size, align: align.max(8), data: None, relocs: Vec::new(), readonly: false });
        self.globals.insert(&d.name, (ty, gid));
        if let Some(init) = &d.init {
            if ty != T_ERR {
                let mut data = vec![0u8; size as usize];
                let mut relocs = Vec::new();
                if self.const_init(init, ty, 0, &mut data, &mut relocs) {
                    if data.iter().any(|b| *b != 0) || !relocs.is_empty() {
                        let g = &mut self.module.globals[gid as usize];
                        g.data = Some(data);
                        g.relocs = relocs;
                    }
                } else {
                    self.err(init.pos, "global initializer must be a compile-time constant".into());
                }
            }
        }
        Some((ty, gid))
    }

    // type of a constant initializer expression (for globals without annotation)
    fn const_type_of(&mut self, e: &Expr) -> Ty {
        match &e.k {
            EK::Int(_) => T_I64,
            EK::Float(_) => T_F64,
            EK::Bool(_) => T_BOOL,
            EK::Str(_) => T_STR,
            EK::Lit(t, _) => self.expr_type(t, &HashMap::new()).unwrap_or(T_ERR),
            EK::Call(c, _) => self.expr_type(c, &HashMap::new()).unwrap_or(T_ERR),
            _ => match self.const_eval(e) {
                Some(CV::Int(_)) => T_I64,
                Some(CV::Float(_)) => T_F64,
                Some(CV::Bool(_)) => T_BOOL,
                Some(CV::Str(_)) => T_STR,
                None => T_ERR,
            },
        }
    }

    // interpret an expression as a type (for literals, casts, generic args)
    pub fn expr_type(&mut self, e: &Expr, env: &HashMap<String, Ty>) -> Option<Ty> {
        match &e.k {
            EK::Ident(n) => {
                if let Some(&t) = env.get(n) {
                    return Some(t);
                }
                if let Some(t) = builtin_type(n) {
                    return Some(t);
                }
                if let Some(si) = self.find_struct(n.as_str()) {
                    if self.struct_decls[si].tparams.is_empty() {
                        return Some(self.inst_struct(si, vec![], e.pos));
                    }
                    return None;
                }
                if let Some(ei) = self.find_enum(n.as_str()) {
                    if self.enum_decls[ei].tparams.is_empty() {
                        return Some(self.inst_enum(ei, vec![], e.pos));
                    }
                    return None;
                }
                None
            }
            EK::Index(b, args) => {
                let n = match &b.k {
                    EK::Ident(n) => n,
                    _ => return None,
                };
                let is_s = self.find_struct(n.as_str());
                let is_e = self.find_enum(n.as_str());
                if is_s.is_none() && is_e.is_none() {
                    return None;
                }
                let mut targs = Vec::new();
                for a in args {
                    targs.push(self.expr_type(a, env)?);
                }
                if let Some(si) = is_s {
                    return Some(self.inst_struct(si, targs, e.pos));
                }
                Some(self.inst_enum(is_e.unwrap(), targs, e.pos))
            }
            EK::TypeE(t) => Some(self.resolve(t, env)),
            EK::Un(UnOp::Deref, inner) => {
                let t = self.expr_type(inner, env)?;
                Some(self.types.ptr(t))
            }
            EK::Tuple(es) => {
                let mut ts = Vec::new();
                for x in es {
                    ts.push(self.expr_type(x, env)?);
                }
                Some(self.types.intern(TyK::Tuple(ts)))
            }
            _ => None,
        }
    }

    // ---------- constant evaluation ----------
    pub fn const_named(&mut self, name: &str) -> Option<(Option<Ty>, CV)> {
        match self.const_vals.get(name) {
            Some(CState::Done(t, v)) => return Some((*t, v.clone())),
            Some(CState::Busy) => {
                let d = self.const_decls[name];
                self.err(d.pos, format!("constant `{}` depends on itself", name));
                return None;
            }
            Some(CState::Failed) => return None,
            None => {}
        }
        let d = *self.const_decls.get(name)?;
        self.const_vals.insert(&d.name, CState::Busy);
        let ty = d.ty.as_ref().map(|t| self.resolve(t, &HashMap::new()));
        let v = self.const_eval(&d.val);
        match v {
            Some(mut v) => {
                if let Some(t) = ty {
                    // typed constant: check/coerce
                    match (self.types.k(t).clone(), &v) {
                        (TyK::Int(bits, signed), CV::Int(i)) => {
                            v = CV::Int(wrap_int(*i, bits, signed));
                        }
                        (TyK::F64 | TyK::F32, CV::Int(i)) => v = CV::Float(*i as f64),
                        (TyK::F32, CV::Float(f)) => v = CV::Float(*f as f32 as f64),
                        (TyK::F64, CV::Float(_)) | (TyK::Bool, CV::Bool(_)) => {}
                        (TyK::Slice(e), CV::Str(_)) if e == T_U8 => {}
                        _ => {
                            self.err(d.pos, format!("constant `{}` value does not match its declared type", name));
                        }
                    }
                }
                self.const_vals.insert(&d.name, CState::Done(ty, v.clone()));
                Some((ty, v))
            }
            None => {
                self.err(d.val.pos, format!("value of constant `{}` is not a compile-time constant", name));
                self.const_vals.insert(&d.name, CState::Failed);
                None
            }
        }
    }

    pub fn const_eval(&mut self, e: &Expr) -> Option<CV> {
        match &e.k {
            EK::Int(n) => Some(CV::Int(*n as i64)),
            EK::Float(f) => Some(CV::Float(*f)),
            EK::Bool(b) => Some(CV::Bool(*b)),
            EK::Str(s) => Some(CV::Str(s.clone())),
            EK::Ident(n) => {
                if self.const_decls.contains_key(n.as_str()) {
                    return self.const_named(n).map(|x| x.1);
                }
                None
            }
            EK::Un(op, x) => {
                let v = self.const_eval(x)?;
                match (op, v) {
                    (UnOp::Neg, CV::Int(i)) => Some(CV::Int(i.wrapping_neg())),
                    (UnOp::Neg, CV::Float(f)) => Some(CV::Float(-f)),
                    (UnOp::BitNot, CV::Int(i)) => Some(CV::Int(!i)),
                    (UnOp::Not, CV::Bool(b)) => Some(CV::Bool(!b)),
                    _ => None,
                }
            }
            EK::Bin(op, a, b) => {
                let x = self.const_eval(a)?;
                let y = self.const_eval(b)?;
                match (x, y) {
                    (CV::Int(x), CV::Int(y)) => Some(match op {
                        BinOp::Add => CV::Int(x.wrapping_add(y)),
                        BinOp::Sub => CV::Int(x.wrapping_sub(y)),
                        BinOp::Mul => CV::Int(x.wrapping_mul(y)),
                        BinOp::Div => {
                            if y == 0 {
                                self.err(e.pos, "division by zero in constant expression".into());
                                return None;
                            }
                            CV::Int(x.wrapping_div(y))
                        }
                        BinOp::Rem => {
                            if y == 0 {
                                self.err(e.pos, "division by zero in constant expression".into());
                                return None;
                            }
                            CV::Int(x.wrapping_rem(y))
                        }
                        BinOp::And => CV::Int(x & y),
                        BinOp::Or => CV::Int(x | y),
                        BinOp::Xor => CV::Int(x ^ y),
                        BinOp::Shl => CV::Int(x.wrapping_shl(y as u32)),
                        BinOp::Shr => CV::Int(x.wrapping_shr(y as u32)),
                        BinOp::Eq => CV::Bool(x == y),
                        BinOp::Ne => CV::Bool(x != y),
                        BinOp::Lt => CV::Bool(x < y),
                        BinOp::Le => CV::Bool(x <= y),
                        BinOp::Gt => CV::Bool(x > y),
                        BinOp::Ge => CV::Bool(x >= y),
                        _ => return None,
                    }),
                    (CV::Float(_), CV::Int(_)) | (CV::Int(_), CV::Float(_)) | (CV::Float(_), CV::Float(_)) => {
                        let x = match self.const_eval(a)? {
                            CV::Int(i) => i as f64,
                            CV::Float(f) => f,
                            _ => return None,
                        };
                        let y = match self.const_eval(b)? {
                            CV::Int(i) => i as f64,
                            CV::Float(f) => f,
                            _ => return None,
                        };
                        Some(match op {
                            BinOp::Add => CV::Float(x + y),
                            BinOp::Sub => CV::Float(x - y),
                            BinOp::Mul => CV::Float(x * y),
                            BinOp::Div => CV::Float(x / y),
                            BinOp::Eq => CV::Bool(x == y),
                            BinOp::Ne => CV::Bool(x != y),
                            BinOp::Lt => CV::Bool(x < y),
                            BinOp::Le => CV::Bool(x <= y),
                            BinOp::Gt => CV::Bool(x > y),
                            BinOp::Ge => CV::Bool(x >= y),
                            _ => return None,
                        })
                    }
                    (CV::Bool(x), CV::Bool(y)) => Some(match op {
                        BinOp::LAnd => CV::Bool(x && y),
                        BinOp::LOr => CV::Bool(x || y),
                        BinOp::Eq => CV::Bool(x == y),
                        BinOp::Ne => CV::Bool(x != y),
                        _ => return None,
                    }),
                    _ => None,
                }
            }
            EK::Call(c, args) if args.len() == 1 => {
                // numeric conversion of a constant: T(x); sizeof[T]()
                let t = self.expr_type(c, &HashMap::new())?;
                let v = self.const_eval(&args[0])?;
                match (self.types.k(t).clone(), v) {
                    (TyK::Int(bits, signed), CV::Int(i)) => Some(CV::Int(wrap_int(i, bits, signed))),
                    (TyK::Int(bits, signed), CV::Float(f)) => Some(CV::Int(wrap_int(f as i64, bits, signed))),
                    (TyK::F64, CV::Int(i)) => Some(CV::Float(i as f64)),
                    (TyK::F64, CV::Float(f)) => Some(CV::Float(f)),
                    (TyK::F32, CV::Int(i)) => Some(CV::Float(i as f32 as f64)),
                    (TyK::F32, CV::Float(f)) => Some(CV::Float(f as f32 as f64)),
                    _ => None,
                }
            }
            EK::Call(c, args) if args.is_empty() => {
                if let EK::Index(b, targs) = &c.k {
                    if matches!(&b.k, EK::Ident(n) if n == "sizeof") && targs.len() == 1 {
                        let t = self.expr_type(&targs[0], &HashMap::new())?;
                        return Some(CV::Int(self.types.size_of(t) as i64));
                    }
                }
                None
            }
            _ => None,
        }
    }

    // write a constant initializer into `data` at `off`
    pub fn const_init(&mut self, e: &Expr, ty: Ty, off: usize, data: &mut Vec<u8>, relocs: &mut Vec<(u32, RelocTarget)>) -> bool {
        let k = self.types.k(ty).clone();
        match (&e.k, &k) {
            (EK::Lit(te, items), TyK::Array(et, n)) => {
                match self.expr_type(te, &HashMap::new()) {
                    Some(t) if t == ty => {}
                    _ => return false,
                }
                if items.len() as u64 > *n {
                    self.err(e.pos, format!("too many elements in array literal (max {})", n));
                    return false;
                }
                let es = self.types.size_of(*et) as usize;
                for (i, (name, v)) in items.iter().enumerate() {
                    if name.is_some() {
                        return false;
                    }
                    if !self.const_init(v, *et, off + i * es, data, relocs) {
                        return false;
                    }
                }
                true
            }
            (EK::Lit(te, items), TyK::Struct(sid)) => {
                match self.expr_type(te, &HashMap::new()) {
                    Some(t) if t == ty => {}
                    _ => return false,
                }
                self.types.layout_struct(*sid);
                let fields = self.types.structs[*sid as usize].fields.clone();
                let offs = self.types.structs[*sid as usize].offsets.clone();
                for (i, (name, v)) in items.iter().enumerate() {
                    let fi = match name {
                        Some(n) => match fields.iter().position(|f| &f.0 == n) {
                            Some(fi) => fi,
                            None => return false,
                        },
                        None => i,
                    };
                    if fi >= fields.len() {
                        return false;
                    }
                    if !self.const_init(v, fields[fi].1, off + offs[fi] as usize, data, relocs) {
                        return false;
                    }
                }
                true
            }
            (EK::Ident(n), TyK::Fn(ptys, rty)) => {
                // address of a (non-generic) function
                let di = match self.find_fn(n) {
                    Some(di) if self.fn_decls[di].tparams.is_empty() => di,
                    _ => return false,
                };
                let fid = self.inst_fn(di, vec![]);
                if self.fn_sigs[fid as usize] != (ptys.clone(), *rty) {
                    self.err(e.pos, format!("function `{}` does not have the type {}", n, self.types.name(ty)));
                    return false;
                }
                relocs.push((off as u32, RelocTarget::Func(fid)));
                true
            }
            (EK::Nil, TyK::Ptr(_)) | (EK::Nil, TyK::Fn(..)) => true,
            (EK::Call(c, args), TyK::Vec(_) | TyK::Quat | TyK::Mat4) => {
                // vec3(1.0, 2.0, 3.0) with constant components; mat4 from four constant columns
                match self.expr_type(c, &HashMap::new()) {
                    Some(t) if t == ty => {}
                    _ => return false,
                }
                let (n, et, es) = match k {
                    TyK::Mat4 => (4, T_VEC4, 16),
                    TyK::Vec(n) => (n as usize, T_F32, 4),
                    _ => (4, T_F32, 4),
                };
                if args.len() != n {
                    return false;
                }
                for (i, a) in args.iter().enumerate() {
                    if !self.const_init(a, et, off + i * es, data, relocs) {
                        return false;
                    }
                }
                true
            }
            _ => {
                let v = match self.const_eval(e) {
                    Some(v) => v,
                    None => return false,
                };
                match (k, v) {
                    (TyK::Int(bits, _), CV::Int(i)) => {
                        let n = (bits / 8) as usize;
                        data[off..off + n].copy_from_slice(&i.to_le_bytes()[..n]);
                        true
                    }
                    (TyK::F32, CV::Float(f)) => {
                        data[off..off + 4].copy_from_slice(&(f as f32).to_bits().to_le_bytes());
                        true
                    }
                    (TyK::F32, CV::Int(i)) => {
                        data[off..off + 4].copy_from_slice(&(i as f32).to_bits().to_le_bytes());
                        true
                    }
                    (TyK::F64, CV::Float(f)) => {
                        data[off..off + 8].copy_from_slice(&f.to_bits().to_le_bytes());
                        true
                    }
                    (TyK::F64, CV::Int(i)) => {
                        data[off..off + 8].copy_from_slice(&(i as f64).to_bits().to_le_bytes());
                        true
                    }
                    (TyK::Bool, CV::Bool(b)) => {
                        data[off] = b as u8;
                        true
                    }
                    (TyK::Slice(et), CV::Str(s)) if et == T_U8 => {
                        let g = self.string_global(&s);
                        relocs.push((off as u32, RelocTarget::Global(g, 0)));
                        data[off + 8..off + 16].copy_from_slice(&(s.len() as u64).to_le_bytes());
                        true
                    }
                    _ => false,
                }
            }
        }
    }
}

pub fn wrap_int(v: i64, bits: u8, signed: bool) -> i64 {
    match (bits, signed) {
        (8, true) => v as i8 as i64,
        (16, true) => v as i16 as i64,
        (32, true) => v as i32 as i64,
        (8, false) => v as u8 as i64,
        (16, false) => v as u16 as i64,
        (32, false) => v as u32 as i64,
        _ => v,
    }
}
