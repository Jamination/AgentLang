// Calls: user functions (with generic inference and UFCS), indirect calls, builtins, printing.
use crate::ast::*;
use crate::ir::*;
use crate::lower::*;
use crate::lower_fn::*;
use crate::types::*;
use std::collections::HashMap;

pub enum Callee {
    Direct(u32),
    Ind(V),
}

fn has_call(e: &Expr) -> bool {
    match &e.k {
        EK::Call(..) | EK::Match(..) | EK::If(..) => true,
        EK::Un(_, x) => has_call(x),
        EK::Bin(_, a, b) => has_call(a) || has_call(b),
        EK::Index(b, i) => has_call(b) || i.iter().any(has_call),
        EK::Slice(b, l, h) => has_call(b) || l.as_ref().map(|x| has_call(x)).unwrap_or(false) || h.as_ref().map(|x| has_call(x)).unwrap_or(false),
        EK::Field(b, _) => has_call(b),
        EK::Lit(_, items) => items.iter().any(|i| has_call(&i.1)),
        EK::Tuple(es) => es.iter().any(has_call),
        _ => false,
    }
}

fn mentions_unbound(t: &TypeAst, tparams: &[String], env: &HashMap<String, Ty>) -> bool {
    match t {
        TypeAst::Name(n, args, _) => (args.is_empty() && tparams.contains(n) && !env.contains_key(n)) || args.iter().any(|a| mentions_unbound(a, tparams, env)),
        TypeAst::Ptr(e) | TypeAst::Slice(e) | TypeAst::Array(_, e) => mentions_unbound(e, tparams, env),
        TypeAst::Fn(ps, r) => ps.iter().any(|a| mentions_unbound(a, tparams, env)) || r.as_ref().map(|r| mentions_unbound(r, tparams, env)).unwrap_or(false),
        TypeAst::Tuple(ts) => ts.iter().any(|a| mentions_unbound(a, tparams, env)),
    }
}

impl<'c, 'a> Fx<'c, 'a> {
    pub fn unify(&mut self, t: &TypeAst, ty: Ty, tparams: &[String], env: &mut HashMap<String, Ty>) -> bool {
        if ty == T_ERR {
            return false;
        }
        match t {
            TypeAst::Name(n, args, _) => {
                if args.is_empty() && tparams.contains(n) {
                    return match env.get(n) {
                        Some(&b) => b == ty,
                        None => {
                            env.insert(n.clone(), ty);
                            true
                        }
                    };
                }
                if args.is_empty() {
                    return true; // concrete; checked after resolution
                }
                let (decl_name, targs): (String, Vec<Ty>) = match self.cx.types.k(ty).clone() {
                    TyK::Struct(s) => {
                        let si = &self.cx.types.structs[s as usize];
                        (self.cx.struct_decls[si.decl].name.clone(), si.targs.clone())
                    }
                    TyK::Enum(e) => {
                        let ei = &self.cx.types.enums[e as usize];
                        (self.cx.enum_decls[ei.decl].name.clone(), ei.targs.clone())
                    }
                    _ => return false,
                };
                if &decl_name != n || targs.len() != args.len() {
                    return false;
                }
                let mut ok = true;
                for (a, t) in args.iter().zip(targs) {
                    ok &= self.unify(a, t, tparams, env);
                }
                ok
            }
            TypeAst::Ptr(e) => match self.cx.types.k(ty).clone() {
                TyK::Ptr(t) => self.unify(e, t, tparams, env),
                _ => false,
            },
            TypeAst::Slice(e) => match self.cx.types.k(ty).clone() {
                TyK::Slice(t) => self.unify(e, t, tparams, env),
                _ => false,
            },
            TypeAst::Array(_, e) => match self.cx.types.k(ty).clone() {
                TyK::Array(t, _) => self.unify(e, t, tparams, env),
                _ => false,
            },
            TypeAst::Fn(ps, r) => match self.cx.types.k(ty).clone() {
                TyK::Fn(pt, rt) if pt.len() == ps.len() => {
                    let mut ok = true;
                    for (a, t) in ps.iter().zip(pt) {
                        ok &= self.unify(a, t, tparams, env);
                    }
                    if let Some(r) = r {
                        ok &= self.unify(r, rt, tparams, env);
                    }
                    ok
                }
                _ => false,
            },
            TypeAst::Tuple(ts) => match self.cx.types.k(ty).clone() {
                TyK::Tuple(tt) if tt.len() == ts.len() => {
                    let mut ok = true;
                    for (a, t) in ts.iter().zip(tt) {
                        ok &= self.unify(a, t, tparams, env);
                    }
                    ok
                }
                _ => false,
            },
        }
    }

    pub fn call_rt(&mut self, name: &str, targs: Vec<Ty>, args: Vec<Val>, pos: Pos) -> Val {
        let di = match self.cx.p_fn_names.get(name).or_else(|| self.cx.fn_names.get(name)) {
            Some(&di) => di,
            None => {
                self.err(pos, format!("internal: runtime function `{}` is missing", name));
                return Val::err();
            }
        };
        let fid = self.cx.inst_fn(di, targs);
        let (ptys, rty) = self.cx.fn_sigs[fid as usize].clone();
        self.emit_call(Callee::Direct(fid), &ptys, rty, args)
    }

    // call of a C function through its import slot, with the C calling convention
    fn emit_extern_call(&mut self, x: u32, ptys: &[Ty], rty: Ty, args: Vec<Val>) -> Val {
        let got = self.cx.module.externs[x as usize].got;
        let a = self.ins(Op::GAddr, T::I64, vec![], got as i64);
        let target = self.load_raw(a, T::I64, AK_PTR);
        let mut ir_args = vec![target];
        for (v, &pt) in args.iter().zip(ptys.iter()) {
            let mut s = self.scalar(*v);
            // C callees expect narrow integers extended to 32 bits
            let it = self.irt(pt);
            if it == T::I8 || it == T::I16 {
                s = self.ins(if self.cx.types.is_signed(pt) { Op::SExt } else { Op::ZExt }, T::I32, vec![s], 0);
            }
            ir_args.push(s);
        }
        let rt = match self.cx.abi_ret(rty) {
            RetAbi::Scalar(t) => t,
            _ => T::Void,
        };
        let c = self.ins(Op::CallInd, rt, ir_args, 0);
        self.f.im(c).aux = 1;
        if rty == T_NEVER {
            self.terminate(Term::Trap);
            return Val::never();
        }
        if rt == T::Void {
            Val::unit()
        } else {
            self.sval(rty, c)
        }
    }

    pub fn emit_call(&mut self, callee: Callee, ptys: &[Ty], rty: Ty, args: Vec<Val>) -> Val {
        if args.iter().any(|a| a.ty == T_ERR) || rty == T_ERR {
            return Val::err();
        }
        if let Callee::Direct(fid) = callee {
            if let Some(x) = self.cx.module.funcs[fid as usize].ext {
                return self.emit_extern_call(x, ptys, rty, args);
            }
        }
        let mut ir_args: Vec<V> = Vec::new();
        if let Callee::Ind(f) = callee {
            ir_args.push(f);
        }
        let rabi = self.cx.abi_ret(rty);
        let mut sret_tmp = NOV;
        if let RetAbi::SRet = rabi {
            sret_tmp = self.temp(rty);
            ir_args.push(sret_tmp);
        }
        for (a, &pt) in args.iter().zip(ptys.iter()) {
            match self.cx.abi_param(pt) {
                ParamAbi::Scalar(_) => {
                    let s = self.scalar(*a);
                    ir_args.push(s);
                }
                ParamAbi::Flat(leaves) => {
                    for l in leaves {
                        let ad = self.add_off(a.v, l.off as i64);
                        let v = self.load_raw(ad, l.t, l.alias);
                        ir_args.push(v);
                    }
                }
                ParamAbi::ByRef => {
                    let t = self.temp(pt);
                    let tv = self.mval(pt, t);
                    self.store(tv, *a);
                    ir_args.push(t);
                }
            }
        }
        let (op, k) = match callee {
            Callee::Direct(fid) => (Op::Call, fid as i64),
            Callee::Ind(_) => (Op::CallInd, 0),
        };
        let res = match rabi {
            RetAbi::None | RetAbi::SRet => {
                self.ins(op, T::Void, ir_args, k);
                if let RetAbi::SRet = rabi {
                    self.mval(rty, sret_tmp)
                } else {
                    Val::unit()
                }
            }
            RetAbi::Scalar(t) => {
                let c = self.ins(op, t, ir_args, k);
                self.sval(rty, c)
            }
            RetAbi::Flat(leaves) => {
                let tmp = self.temp(rty);
                if leaves.len() == 1 {
                    let c = self.ins(op, leaves[0].t, ir_args, k);
                    let a = self.add_off(tmp, leaves[0].off as i64);
                    self.store_raw(a, c, leaves[0].t, leaves[0].alias);
                } else {
                    let c = self.ins(op, T::Void, ir_args, k);
                    for (i, l) in leaves.iter().enumerate() {
                        let p = self.ins(Op::Proj, l.t, vec![c], i as i64);
                        let a = self.add_off(tmp, l.off as i64);
                        self.store_raw(a, p, l.t, l.alias);
                    }
                }
                self.mval(rty, tmp)
            }
        };
        if rty == T_NEVER {
            self.terminate(Term::Trap);
            return Val::never();
        }
        res
    }

    // copy aggregate lvalues that later argument expressions could modify
    fn stabilize(&mut self, v: Val, later: &[Expr]) -> Val {
        if v.mem && later.iter().any(has_call) {
            let t = self.temp(v.ty);
            let tv = self.mval(v.ty, t);
            self.store(tv, v);
            return tv;
        }
        v
    }

    fn call_indirect(&mut self, fv: Val, args: &'a [Expr], pos: Pos) -> Val {
        let (ptys, rty) = match self.cx.types.k(fv.ty).clone() {
            TyK::Fn(p, r) => (p, r),
            TyK::Err => return Val::err(),
            _ => {
                let tn = self.tyname(fv.ty);
                self.err(pos, format!("{} is not callable", tn));
                return Val::err();
            }
        };
        if ptys.len() != args.len() {
            self.err(pos, format!("function value expects {} argument(s), got {}", ptys.len(), args.len()));
            return Val::err();
        }
        let f = self.scalar(fv);
        let mut vals = Vec::new();
        for (i, a) in args.iter().enumerate() {
            let v = self.expr(a, Some(ptys[i]));
            let v = self.coerce(v, ptys[i], a.pos);
            let v = self.stabilize(v, &args[i + 1..]);
            vals.push(v);
        }
        self.emit_call(Callee::Ind(f), &ptys, rty, vals)
    }

    pub fn call(&mut self, c: &'a Expr, args: &'a [Expr], expect: Option<Ty>, pos: Pos) -> Val {
        match &c.k {
            EK::Ident(n) => {
                if self.lookup(n).is_some() {
                    let fv = self.expr(c, None);
                    return self.call_indirect(fv, args, pos);
                }
                let cands = self.cx.fn_candidates(n.as_str());
                if cands.len() == 1 {
                    return self.call_decl(cands[0], None, None, args, expect, pos, &[]);
                }
                if cands.len() > 1 {
                    return self.call_overloaded(&cands, None, None, args, expect, pos);
                }
                if let Some(v) = self.builtin(n, None, args, expect, pos) {
                    return v;
                }
                let env = self.tenv.clone();
                if let Some(t) = self.cx.expr_type(c, &env) {
                    return self.conversion(t, args, pos);
                }
                if let Some(&(ei, vi)) = self.cx.variants.get(n.as_str()) {
                    return self.construct_variant(ei, vi, args, expect, pos);
                }
                if self.cx.global_decls.contains_key(n.as_str()) {
                    let fv = self.expr(c, None);
                    return self.call_indirect(fv, args, pos);
                }
                let hint = match n.as_str() {
                    "println" | "printf" | "echo" | "puts" | "console" => " (use `print(a, b, ...)`)",
                    "length" | "size" | "count" => " (use `len(x)`)",
                    "malloc" | "calloc" => " (use `alloc[T](n)` or `new[T]()`)",
                    "str" | "string" | "to_string" | "format" | "sprintf" => " (use `fmt(a, b, ...)`)",
                    "append" => " (use a `Vec`: `v.push(x)`)",
                    "int" | "float" => " (convert with a type name: `i64(x)`, `f64(x)`)",
                    _ => "",
                };
                self.err(pos, format!("unknown function `{}`{}", n, hint));
                for a in args {
                    self.expr(a, None);
                }
                Val::err()
            }
            EK::Index(b, targs) => {
                if let EK::Ident(n) = &b.k {
                    let is_var = self.lookup(n).is_some() || (self.cx.global_decls.contains_key(n.as_str()) && self.cx.find_fn(n.as_str()).is_none());
                    if !is_var {
                        let env = self.tenv.clone();
                        let cands = self.cx.fn_candidates(n.as_str());
                        let is_builtin = matches!(n.as_str(), "sizeof" | "cast" | "mkslice");
                        if !cands.is_empty() || is_builtin {
                            let mut tys = Vec::new();
                            for t in targs {
                                match self.cx.expr_type(t, &env) {
                                    Some(ty) if ty != T_ERR => tys.push(ty),
                                    Some(_) => return Val::err(),
                                    None => {
                                        self.err(t.pos, "expected a type argument".into());
                                        return Val::err();
                                    }
                                }
                            }
                            if cands.len() == 1 {
                                return self.call_decl(cands[0], Some(tys), None, args, expect, pos, &[]);
                            }
                            if cands.len() > 1 {
                                return self.call_overloaded(&cands, Some(tys), None, args, expect, pos);
                            }
                            return self.builtin(n, Some(&tys), args, expect, pos).unwrap_or_else(Val::err);
                        }
                        if let Some(t) = self.cx.expr_type(c, &env) {
                            return self.conversion(t, args, pos);
                        }
                    }
                }
                // x.f[T](a): a method call with explicit type arguments
                if let EK::Field(recv, name) = &b.k {
                    let cands = self.cx.fn_candidates(name.as_str());
                    if !cands.is_empty() {
                        let env = self.tenv.clone();
                        let saved = self.cx.errs.len();
                        let tys: Option<Vec<Ty>> = targs.iter().map(|t| self.cx.expr_type(t, &env).filter(|x| *x != T_ERR)).collect();
                        self.cx.errs.truncate(saved);
                        if let Some(tys) = tys {
                            let rv = self.expr(recv, None);
                            if rv.ty == T_ERR {
                                return Val::err();
                            }
                            if cands.len() == 1 {
                                return self.call_decl(cands[0], Some(tys), Some(rv), args, expect, pos, &[]);
                            }
                            return self.call_overloaded(&cands, Some(tys), Some(rv), args, expect, pos);
                        }
                    }
                }
                let fv = self.expr(c, None);
                self.call_indirect(fv, args, pos)
            }
            EK::Field(recv, name) => {
                let rv = self.expr(recv, None);
                if rv.ty == T_ERR {
                    return Val::err();
                }
                // a struct field holding a function value?
                let dv = self.auto_deref(rv);
                if let TyK::Struct(sid) = self.cx.types.k(dv.ty).clone() {
                    let is_fn_field = self.cx.types.structs[sid as usize].fields.iter().any(|f| &f.0 == name && matches!(self.cx.types.k(f.1), TyK::Fn(..)));
                    if is_fn_field {
                        let fp = match self.field_of(dv, name, pos) {
                            Some(p) => self.rvalue(p),
                            None => return Val::err(),
                        };
                        return self.call_indirect(fp, args, pos);
                    }
                }
                let cands = self.cx.fn_candidates(name.as_str());
                if cands.len() == 1 {
                    return self.call_decl(cands[0], None, Some(rv), args, expect, pos, &[]);
                }
                if cands.len() > 1 {
                    return self.call_overloaded(&cands, None, Some(rv), args, expect, pos);
                }
                if name == "len" && args.is_empty() {
                    if let Some(v) = self.len_of(rv) {
                        return v;
                    }
                }
                let tn = self.tyname(rv.ty);
                self.err(pos, format!("no function `{}` to call on {} (method calls `x.f(a)` mean `f(x, a)`)", name, tn));
                Val::err()
            }
            EK::TypeE(t) => {
                let env = self.tenv.clone();
                let ty = self.cx.resolve(t, &env);
                self.conversion(ty, args, pos)
            }
            _ => {
                let fv = self.expr(c, None);
                self.call_indirect(fv, args, pos)
            }
        }
    }

    fn conversion(&mut self, to: Ty, args: &'a [Expr], pos: Pos) -> Val {
        if to != T_ERR && self.is_vecish(to) {
            return self.vec_construct(to, args, pos);
        }
        if args.len() != 1 {
            self.err(pos, "a type conversion takes exactly one argument".into());
            return Val::err();
        }
        if to == T_ERR {
            return Val::err();
        }
        // literals convert directly
        fn has_float(e: &Expr) -> bool {
            match &e.k {
                EK::Float(_) => true,
                EK::Un(_, x) => has_float(x),
                EK::Bin(_, a, b) => has_float(a) || has_float(b),
                _ => false,
            }
        }
        let floaty = has_float(&args[0]) || matches!(self.cx.const_eval(&args[0]), Some(CV::Float(_)));
        let exp = if self.is_untyped(&args[0]) && (self.cx.types.is_float(to) || (self.cx.types.is_int(to) && !floaty)) { Some(to) } else { None };
        let v = self.expr(&args[0], exp);
        self.convert(v, to, pos)
    }

    // The value of function `n`: with explicit type arguments, or with the types taken from
    // the expected function type; of several definitions the one that fits is used.
    pub fn fn_value(&mut self, n: &str, explicit: Option<Vec<Ty>>, expect: Option<Ty>) -> Option<Val> {
        let cands = self.cx.fn_candidates(n);
        let want = match expect.map(|t| self.cx.types.k(t).clone()) {
            Some(TyK::Fn(p, r)) => Some((p, r)),
            _ => None,
        };
        for &di in &cands {
            let d = self.cx.fn_decls[di];
            let targs: Vec<Ty> = match (&explicit, d.tparams.is_empty()) {
                (Some(t), _) if t.len() == d.tparams.len() => t.clone(),
                (Some(_), _) => continue,
                (None, true) => Vec::new(),
                (None, false) => {
                    // infer the type arguments from the expected function type
                    let (ps, r) = match &want {
                        Some((ps, r)) if ps.len() == d.params.len() => (ps.clone(), *r),
                        _ => continue,
                    };
                    let mut env = HashMap::new();
                    let mut ok = true;
                    for (p, t) in d.params.iter().zip(ps.iter()) {
                        ok &= self.unify(&p.1, *t, &d.tparams, &mut env);
                    }
                    if let Some(rt) = &d.ret {
                        ok &= self.unify(rt, r, &d.tparams, &mut env);
                    }
                    if !ok || d.tparams.iter().any(|p| !env.contains_key(p)) {
                        continue;
                    }
                    d.tparams.iter().map(|p| env[p]).collect()
                }
            };
            let fid = self.cx.inst_fn(di, targs);
            let (ptys, rty) = self.cx.fn_sigs[fid as usize].clone();
            if let Some((wp, wr)) = &want {
                if cands.len() > 1 && (*wp != ptys || *wr != rty) {
                    continue;
                }
            }
            let ty = self.cx.types.intern(TyK::Fn(ptys, rty));
            if let Some(x) = self.cx.module.funcs[fid as usize].ext {
                // the address of a C function comes from its import slot
                let got = self.cx.module.externs[x as usize].got;
                let a = self.ins(Op::GAddr, T::I64, vec![], got as i64);
                let v = self.load_raw(a, T::I64, AK_PTR);
                return Some(self.sval(ty, v));
            }
            let v = self.ins(Op::FAddr, T::I64, vec![], fid as i64);
            return Some(self.sval(ty, v));
        }
        None
    }

    // does parameter type `pt` of declaration `d` accept a value of type `ty`?
    // (`explicit`: type arguments written at the call)
    fn param_accepts(&mut self, d: &'a FnDecl, pt: &TypeAst, ty: Ty, is_recv: bool, explicit: Option<&[Ty]>) -> bool {
        let adjust = |s: &mut Self, t: Ty| -> bool { is_recv && (matches!(s.cx.types.k(t).clone(), TyK::Ptr(i) if i == ty) || matches!(s.cx.types.k(ty).clone(), TyK::Ptr(i) if i == t)) };
        if d.tparams.is_empty() {
            let saved = self.cx.errs.len();
            let t = self.cx.resolve(pt, &HashMap::new());
            self.cx.errs.truncate(saved);
            return t == ty || adjust(self, t);
        }
        let mut base = HashMap::new();
        if let Some(tys) = explicit {
            for (n, t) in d.tparams.iter().zip(tys.iter()) {
                base.insert(n.clone(), *t);
            }
        }
        // unification binds the type parameters; the concrete parts are compared after resolution
        let fits = |s: &mut Self, pt: &TypeAst, ty: Ty| -> bool {
            let mut env = base.clone();
            if !s.unify(pt, ty, &d.tparams, &mut env) {
                return false;
            }
            if mentions_unbound(pt, &d.tparams, &env) {
                return true;
            }
            let saved = s.cx.errs.len();
            let t = s.cx.resolve(pt, &env);
            s.cx.errs.truncate(saved);
            t == ty
        };
        if fits(self, pt, ty) {
            return true;
        }
        if !is_recv {
            return false;
        }
        match (pt, self.cx.types.k(ty).clone()) {
            (TypeAst::Ptr(inner), _) => fits(self, inner, ty),
            (_, TyK::Ptr(t)) => fits(self, pt, t),
            _ => false,
        }
    }

    // how well parameter `pi` of `d` fits an untyped literal argument: 0 = its default type,
    // 1 = same kind, 2 = generic, 3 = integer literal for a float; None = does not fit
    fn literal_fit(&mut self, d: &'a FnDecl, pi: usize, a: &Expr) -> Option<u8> {
        let pt = &d.params[pi].1;
        if mentions_unbound(pt, &d.tparams, &HashMap::new()) {
            return Some(2);
        }
        let saved = self.cx.errs.len();
        let t = self.cx.resolve(pt, &HashMap::new());
        self.cx.errs.truncate(saved);
        let k = self.cx.types.k(t).clone();
        let (is_i, is_f) = (self.cx.types.is_int(t), self.cx.types.is_float(t));
        if matches!(a.k, EK::Nil) {
            return if matches!(k, TyK::Ptr(_) | TyK::Fn(..) | TyK::Slice(_)) { Some(0) } else { None };
        }
        if matches!(&a.k, EK::Ident(n) if self.cx.variants.contains_key(n.as_str())) {
            return if matches!(k, TyK::Enum(_)) { Some(0) } else { None };
        }
        if matches!(self.cx.const_eval(a), Some(CV::Float(_))) {
            return if t == T_F64 {
                Some(0)
            } else if is_f {
                Some(1)
            } else {
                None
            };
        }
        if t == T_I64 {
            Some(0)
        } else if is_i {
            Some(1)
        } else if is_f {
            Some(3)
        } else {
            None
        }
    }

    // A name with several definitions. The receiver and the arguments are looked at from left
    // to right until one definition is left: typed arguments must match the parameter type,
    // untyped literals must be acceptable to it. Remaining ties go to the definition whose
    // parameters are the literals' default types, then to one returning the expected type.
    fn call_overloaded(&mut self, cands: &[usize], explicit: Option<Vec<Ty>>, recv: Option<Val>, args: &'a [Expr], expect: Option<Ty>, pos: Pos) -> Val {
        let total = args.len() + recv.is_some() as usize;
        let off = recv.is_some() as usize;
        let name = self.cx.fn_decls[cands[0]].name.clone();
        let sigs = |s: &Self| -> String {
            cands
                .iter()
                .map(|di| {
                    let d = s.cx.fn_decls[*di];
                    format!("{}({})", d.name, d.params.iter().map(|p| type_str(&p.1)).collect::<Vec<_>>().join(", "))
                })
                .collect::<Vec<_>>()
                .join("; ")
        };
        let mut alive: Vec<usize> = cands
            .iter()
            .copied()
            .filter(|di| {
                let d = self.cx.fn_decls[*di];
                d.params.len() == total && explicit.as_ref().map(|t| t.len() == d.tparams.len()).unwrap_or(true)
            })
            .collect();
        if alive.is_empty() {
            let s = sigs(self);
            self.err(pos, format!("no definition of `{}` takes {} argument(s); candidates: {}", name, total, s));
            for a in args {
                self.expr(a, None);
            }
            return Val::err();
        }
        if let Some(rv) = recv {
            let mut keep: Vec<usize> = Vec::new();
            for &di in &alive {
                let d = self.cx.fn_decls[di];
                if self.param_accepts(d, &d.params[0].1, rv.ty, true, explicit.as_deref()) {
                    keep.push(di);
                }
            }
            if keep.is_empty() {
                let (tn, s) = (self.tyname(rv.ty), sigs(self));
                self.err(pos, format!("no definition of `{}` can be called on {}; candidates: {}", name, tn, s));
                for a in args {
                    self.expr(a, None);
                }
                return Val::err();
            }
            alive = keep;
        }
        let mut pre: Vec<(usize, Val)> = Vec::new();
        for (i, a) in args.iter().enumerate() {
            if alive.len() <= 1 {
                break;
            }
            let mut keep: Vec<usize> = Vec::new();
            if self.is_untyped(a) {
                for &di in &alive {
                    if self.literal_fit(self.cx.fn_decls[di], off + i, a).is_some() {
                        keep.push(di);
                    }
                }
                if !keep.is_empty() {
                    alive = keep;
                }
                continue;
            }
            let v = self.expr(a, None);
            if v.ty != T_ERR {
                pre.push((i, v));
                for &di in &alive {
                    let d = self.cx.fn_decls[di];
                    if self.param_accepts(d, &d.params[off + i].1, v.ty, false, explicit.as_deref()) {
                        keep.push(di);
                    }
                }
                if keep.is_empty() {
                    let (tn, s) = (self.tyname(v.ty), sigs(self));
                    self.err(a.pos, format!("no definition of `{}` takes {} as argument {} here; candidates: {}", name, tn, off + i + 1, s));
                }
            }
            if keep.is_empty() {
                for b in &args[i + 1..] {
                    self.expr(b, None);
                }
                return Val::err();
            }
            alive = keep;
        }
        let mut pick = alive[0];
        if alive.len() > 1 {
            // rank by how naturally the literal arguments fit, then by the expected result type
            let mut ranked: Vec<(u32, usize)> = Vec::new();
            for &di in &alive {
                let d = self.cx.fn_decls[di];
                let mut rank = 0u32;
                for (i, a) in args.iter().enumerate() {
                    if self.is_untyped(a) {
                        rank += self.literal_fit(d, off + i, a).unwrap_or(4) as u32;
                    }
                }
                ranked.push((rank, di));
            }
            ranked.sort_by_key(|r| r.0);
            pick = ranked[0].1;
            if let Some(et) = expect {
                for &(_, di) in &ranked {
                    let d = self.cx.fn_decls[di];
                    if let (true, Some(rt)) = (d.tparams.is_empty(), &d.ret) {
                        let saved = self.cx.errs.len();
                        let t = self.cx.resolve(rt, &HashMap::new());
                        self.cx.errs.truncate(saved);
                        if t == et {
                            pick = di;
                            break;
                        }
                    }
                }
            }
        }
        self.call_decl(pick, explicit, recv, args, expect, pos, &pre)
    }

    #[allow(clippy::too_many_arguments)]
    fn call_decl(&mut self, di: usize, explicit: Option<Vec<Ty>>, recv: Option<Val>, args: &'a [Expr], expect: Option<Ty>, pos: Pos, pre: &[(usize, Val)]) -> Val {
        let d = self.cx.fn_decls[di];
        let nrecv = if recv.is_some() { 1 } else { 0 };
        if d.params.len() != args.len() + nrecv {
            let sig: Vec<String> = d.params.iter().map(|p| p.0.clone()).collect();
            self.err(pos, format!("function `{}({})` expects {} argument(s), got {}", d.name, sig.join(", "), d.params.len(), args.len() + nrecv));
            for a in args {
                self.expr(a, None);
            }
            return Val::err();
        }
        let mut vals: Vec<Option<Val>> = vec![None; d.params.len()];
        let mut env: HashMap<String, Ty> = HashMap::new();
        let generic = !d.tparams.is_empty();
        if generic {
            if let Some(tys) = &explicit {
                if tys.len() != d.tparams.len() {
                    self.err(pos, format!("function `{}` expects {} type argument(s), got {}", d.name, d.tparams.len(), tys.len()));
                    return Val::err();
                }
                for (n, t) in d.tparams.iter().zip(tys.iter()) {
                    env.insert(n.clone(), *t);
                }
            }
        } else if explicit.as_ref().map(|t| !t.is_empty()).unwrap_or(false) {
            self.err(pos, format!("function `{}` is not generic", d.name));
            return Val::err();
        }
        let mut failed = false;
        if let Some(rv) = recv {
            if generic {
                // try by value, then through a pointer in either direction
                let pt = &d.params[0].1;
                let mut e2 = env.clone();
                if self.unify(pt, rv.ty, &d.tparams, &mut e2) {
                    env = e2;
                } else {
                    let mut e3 = env.clone();
                    let ok = match (pt, self.cx.types.k(rv.ty).clone()) {
                        (TypeAst::Ptr(inner), _) => self.unify(inner, rv.ty, &d.tparams, &mut e3),
                        (_, TyK::Ptr(t)) => self.unify(pt, t, &d.tparams, &mut e3),
                        _ => false,
                    };
                    if ok {
                        env = e3;
                    }
                }
            }
            vals[0] = Some(rv);
        }
        // pass 1: typed arguments; pass 2: untyped literals
        for pass in 0..2 {
            for (i, a) in args.iter().enumerate() {
                let pi = i + nrecv;
                if let Some(&(_, pv)) = pre.iter().find(|p| p.0 == i) {
                    // an argument that overload resolution already evaluated
                    if pass == 0 {
                        if generic && !self.unify(&d.params[pi].1, pv.ty, &d.tparams, &mut env) {
                            let tn = self.tyname(pv.ty);
                            self.err(a.pos, format!("argument {} of `{}` has type {}, which does not match the parameter type", i + 1, d.name, tn));
                            failed = true;
                        }
                        let pv = self.stabilize(pv, &args[i + 1..]);
                        vals[pi] = Some(pv);
                    }
                    continue;
                }
                let untyped = self.is_untyped(a);
                if (pass == 0) == untyped && generic {
                    continue;
                }
                if !generic && pass == 1 {
                    continue;
                }
                let pt = &d.params[pi].1;
                let exp = if generic && mentions_unbound(pt, &d.tparams, &env) {
                    None
                } else {
                    let t = self.cx.resolve(pt, &env);
                    Some(t)
                };
                let v = self.expr(a, exp);
                if v.ty == T_ERR {
                    failed = true;
                }
                if generic && exp.is_none() && v.ty != T_ERR && !self.unify(pt, v.ty, &d.tparams, &mut env) {
                    let tn = self.tyname(v.ty);
                    self.err(a.pos, format!("argument {} of `{}` has type {}, which does not match the parameter type", i + 1, d.name, tn));
                    failed = true;
                }
                let v = self.stabilize(v, &args[i + 1..]);
                vals[pi] = Some(v);
            }
        }
        if failed {
            return Val::err();
        }
        let mut targs = Vec::new();
        if generic {
            // the expected result type can bind remaining parameters
            if let (Some(et), Some(rt)) = (expect, &d.ret) {
                if d.tparams.iter().any(|p| !env.contains_key(p)) {
                    let mut e2 = env.clone();
                    if self.unify(rt, et, &d.tparams, &mut e2) {
                        env = e2;
                    }
                }
            }
            for p in &d.tparams {
                match env.get(p) {
                    Some(&t) => targs.push(t),
                    None => {
                        self.err(pos, format!("cannot infer type parameter `{}` of `{}`; write `{}[T](...)`", p, d.name, d.name));
                        return Val::err();
                    }
                }
            }
        }
        self.cx.inst_depth += 1;
        if self.cx.inst_depth > 200 {
            self.err(pos, "generic instantiation is too deep".into());
            self.cx.inst_depth -= 1;
            return Val::err();
        }
        let fid = self.cx.inst_fn(di, targs);
        self.cx.inst_depth -= 1;
        let (ptys, rty) = self.cx.fn_sigs[fid as usize].clone();
        let mut final_vals = Vec::new();
        for (i, v) in vals.into_iter().enumerate() {
            let mut v = v.unwrap();
            let pt = ptys[i];
            if i == 0 && recv.is_some() && v.ty != pt {
                // UFCS receiver adjustment: auto-ref / auto-deref
                match (self.cx.types.k(pt).clone(), self.cx.types.k(v.ty).clone()) {
                    (TyK::Ptr(inner), _) if inner == v.ty && v.mem => {
                        if v.alias >> 4 != 0 {
                            self.cx.exposed.insert(v.alias >> 4);
                        }
                        v = self.sval(pt, v.v);
                    }
                    (_, TyK::Ptr(inner)) if inner == pt => {
                        let a = self.scalar(v);
                        let m = self.mval(pt, a);
                        v = self.rvalue(m);
                    }
                    _ => {}
                }
            }
            let apos = if i >= nrecv { args[i - nrecv].pos } else { pos };
            if v.ty != pt && v.ty != T_ERR && pt != T_ERR && v.ty != T_NEVER {
                let (a, b) = (self.tyname(pt), self.tyname(v.ty));
                self.err(apos, format!("argument `{}` of `{}`: expected {}, found {}", d.params[i].0, d.name, a, b));
                failed = true;
            }
            final_vals.push(v);
        }
        if failed {
            return Val::err();
        }
        self.emit_call(Callee::Direct(fid), &ptys, rty, final_vals)
    }

    // ---------- builtins ----------
    fn builtin(&mut self, name: &str, targs: Option<&[Ty]>, args: &'a [Expr], _expect: Option<Ty>, pos: Pos) -> Option<Val> {
        let nargs = args.len();
        macro_rules! arity {
            ($n:expr) => {
                if nargs != $n {
                    self.err(pos, format!("`{}` takes {} argument(s), got {}", name, $n, nargs));
                    return Some(Val::err());
                }
            };
        }
        macro_rules! targ {
            () => {
                match targs {
                    Some(t) if t.len() == 1 => t[0],
                    _ => {
                        self.err(pos, format!("`{}` needs one type argument: `{}[T](...)`", name, name));
                        return Some(Val::err());
                    }
                }
            };
        }
        Some(match name {
            "len" => {
                arity!(1);
                let v = self.expr(&args[0], None);
                if v.ty == T_ERR {
                    return Some(Val::err());
                }
                match self.len_of(v) {
                    Some(l) => l,
                    None => {
                        let tn = self.tyname(v.ty);
                        self.err(pos, format!("`len` needs a slice, array or str, found {}", tn));
                        Val::err()
                    }
                }
            }
            "sizeof" => {
                arity!(0);
                let t = targ!();
                let s = self.cx.types.size_of(t);
                let v = self.iconst(T::I64, s as i64);
                self.sval(T_I64, v)
            }
            "cast" => {
                arity!(1);
                let to = targ!();
                let v = self.expr(&args[0], None);
                if v.ty == T_ERR {
                    return Some(Val::err());
                }
                let fk = self.cx.types.k(v.ty).clone();
                let tk = self.cx.types.k(to).clone();
                let word = |k: &TyK| matches!(k, TyK::Ptr(_) | TyK::Fn(..) | TyK::Int(64, _));
                if word(&fk) && word(&tk) {
                    let s = self.scalar(v);
                    self.sval(to, s)
                } else if matches!(fk, TyK::F64) && matches!(tk, TyK::Int(64, _)) {
                    let s = self.scalar(v);
                    let r = self.ins(Op::FToBits, T::I64, vec![s], 0);
                    self.sval(to, r)
                } else if matches!(fk, TyK::Int(64, _)) && matches!(tk, TyK::F64) {
                    let s = self.scalar(v);
                    let r = self.ins(Op::BitsToF, T::F64, vec![s], 0);
                    self.sval(to, r)
                } else if matches!(fk, TyK::F32) && matches!(tk, TyK::Int(32, _)) {
                    let s = self.scalar(v);
                    let r = self.ins(Op::FToBits, T::I32, vec![s], 0);
                    self.sval(to, r)
                } else if matches!(fk, TyK::Int(32, _)) && matches!(tk, TyK::F32) {
                    let s = self.scalar(v);
                    let r = self.ins(Op::BitsToF, T::F32, vec![s], 0);
                    self.sval(to, r)
                } else if matches!(tk, TyK::Enum(_)) && self.cx.types.is_scalar(to) && matches!(fk, TyK::Int(64, _)) {
                    let s = self.scalar(v);
                    self.sval(to, s)
                } else if matches!(fk, TyK::Slice(_)) && matches!(tk, TyK::Slice(_)) {
                    // reinterpret a slice: the byte length is preserved
                    let (TyK::Slice(fe), TyK::Slice(te)) = (fk, tk) else { unreachable!() };
                    let (p, l) = self.slice_parts(v);
                    let (fs, ts) = (self.cx.types.size_of(fe) as i64, self.cx.types.size_of(te) as i64);
                    let n = if fs == ts {
                        l
                    } else {
                        let a = self.iconst(T::I64, fs);
                        let bytes = self.ins(Op::Mul, T::I64, vec![l, a], 0);
                        let b = self.iconst(T::I64, ts.max(1));
                        self.ins(Op::UDiv, T::I64, vec![bytes, b], 0)
                    };
                    let t = self.temp(to);
                    let sv = self.mval(to, t);
                    self.store_slice(sv, p, n);
                    sv
                } else {
                    let (a, b) = (self.tyname(v.ty), self.tyname(to));
                    self.err(pos, format!("cannot cast {} to {}", a, b));
                    Val::err()
                }
            }
            "mkslice" => {
                arity!(2);
                let et = targ!();
                let p = self.expr(&args[0], None);
                let n = self.expr(&args[1], Some(T_I64));
                let n = self.coerce(n, T_I64, args[1].pos);
                if p.ty == T_ERR || n.ty == T_ERR {
                    return Some(Val::err());
                }
                if !matches!(self.cx.types.k(p.ty), TyK::Ptr(_) | TyK::Int(64, _)) {
                    self.err(args[0].pos, "`mkslice` needs a pointer or i64 address".into());
                    return Some(Val::err());
                }
                let pv = self.scalar(p);
                let nv = self.scalar(n);
                let sty = self.cx.types.slice(et);
                let t = self.temp(sty);
                let sv = self.mval(sty, t);
                self.store_slice(sv, pv, nv);
                sv
            }
            "ptr" => {
                arity!(1);
                let v = self.expr(&args[0], None);
                let v = self.auto_deref(v);
                match self.cx.types.k(v.ty).clone() {
                    TyK::Slice(et) => {
                        let (p, _) = self.slice_parts(v);
                        let pt = self.cx.types.ptr(et);
                        self.sval(pt, p)
                    }
                    TyK::Array(et, _) => {
                        let pt = self.cx.types.ptr(et);
                        self.sval(pt, v.v)
                    }
                    TyK::Err => Val::err(),
                    _ => {
                        self.err(pos, "`ptr` needs a slice or array".into());
                        Val::err()
                    }
                }
            }
            "syscall" => {
                if nargs == 0 || nargs > 7 {
                    self.err(pos, "`syscall` takes a number and up to 6 arguments".into());
                    return Some(Val::err());
                }
                let mut vs = Vec::new();
                for a in args {
                    let v = self.expr(a, Some(T_I64));
                    if v.ty == T_ERR {
                        return Some(Val::err());
                    }
                    if !self.cx.types.is_scalar(v.ty) || self.cx.types.is_float(v.ty) || self.is_vecish(v.ty) {
                        self.err(a.pos, "syscall arguments must be integers or pointers".into());
                        return Some(Val::err());
                    }
                    let s = if self.cx.types.is_int(v.ty) || v.ty == T_BOOL { self.to_i64(v) } else { self.scalar(v) };
                    vs.push(s);
                }
                let r = self.ins(Op::Syscall, T::I64, vs, 0);
                self.sval(T_I64, r)
            }
            "sqrt" | "fabs" | "fmin" | "fmax" => {
                let two = matches!(name, "fmin" | "fmax");
                if two {
                    arity!(2);
                } else {
                    arity!(1);
                }
                // an untyped literal takes the type of the other operand, else of the context
                let first = if two && self.is_untyped(&args[0]) && !self.is_untyped(&args[1]) { 1 } else { 0 };
                let exp0 = if self.is_untyped(&args[first]) { Some(self.float_expect(_expect)) } else { None };
                let v = self.expr(&args[first], exp0);
                if v.ty == T_ERR {
                    return Some(Val::err());
                }
                if !self.cx.types.is_float(v.ty) && self.cx.types.vec_lanes(v.ty).is_none() {
                    let tn = self.tyname(v.ty);
                    self.err(args[first].pos, format!("`{}` needs f32, f64 or a vector, found {}", name, tn));
                    return Some(Val::err());
                }
                let it = self.irt(v.ty);
                let s = self.scalar(v);
                let r = if two {
                    let w = self.expr(&args[1 - first], Some(v.ty));
                    let w = self.coerce(w, v.ty, args[1 - first].pos);
                    if w.ty == T_ERR {
                        return Some(Val::err());
                    }
                    let t = self.scalar(w);
                    let (a, b) = if first == 0 { (s, t) } else { (t, s) };
                    self.ins(if name == "fmin" { Op::FMin } else { Op::FMax }, it, vec![a, b], 0)
                } else {
                    self.ins(if name == "sqrt" { Op::FSqrt } else { Op::FAbs }, it, vec![s], 0)
                };
                self.sval(v.ty, r)
            }
            "popcnt" | "ctz" | "clz" | "bswap" => {
                arity!(1);
                let v = self.expr(&args[0], None);
                if v.ty == T_ERR {
                    return Some(Val::err());
                }
                if !self.cx.types.is_int(v.ty) {
                    self.err(pos, format!("`{}` needs an integer", name));
                    return Some(Val::err());
                }
                let it = self.irt(v.ty);
                let s = self.scalar(v);
                let op = match name {
                    "popcnt" => Op::Popcnt,
                    "ctz" => Op::Ctz,
                    "clz" => Op::Clz,
                    _ => Op::Bswap,
                };
                let r = self.ins(op, it, vec![s], 0);
                self.sval(v.ty, r)
            }
            "rotl" | "rotr" => {
                arity!(2);
                let v = self.expr(&args[0], None);
                let n = self.expr(&args[1], None);
                if v.ty == T_ERR || n.ty == T_ERR {
                    return Some(Val::err());
                }
                if !self.cx.types.is_int(v.ty) || !self.cx.types.is_int(n.ty) {
                    self.err(pos, format!("`{}` needs integers", name));
                    return Some(Val::err());
                }
                let it = self.irt(v.ty);
                let nt = self.irt(n.ty);
                let s = self.scalar(v);
                let mut c = self.scalar(n);
                if nt.size() > it.size() {
                    c = self.ins(Op::Trunc, it, vec![c], 0);
                } else if nt.size() < it.size() {
                    c = self.ins(Op::ZExt, it, vec![c], 0);
                }
                let r = self.ins(if name == "rotl" { Op::Rotl } else { Op::Rotr }, it, vec![s, c], 0);
                self.sval(v.ty, r)
            }
            "memcopy" | "memfill" => {
                arity!(3);
                let d = self.expr(&args[0], None);
                let s = self.expr(&args[1], if name == "memfill" { Some(T_U8) } else { None });
                let n = self.expr(&args[2], Some(T_I64));
                let n = self.coerce(n, T_I64, args[2].pos);
                if d.ty == T_ERR || s.ty == T_ERR || n.ty == T_ERR {
                    return Some(Val::err());
                }
                let okp = |k: &TyK| matches!(k, TyK::Ptr(_) | TyK::Int(64, _));
                let dk = self.cx.types.k(d.ty).clone();
                let sk = self.cx.types.k(s.ty).clone();
                if !okp(&dk) || (name == "memcopy" && !okp(&sk)) || (name == "memfill" && s.ty != T_U8) {
                    self.err(pos, format!("`{}` arguments have the wrong types", name));
                    return Some(Val::err());
                }
                let (dv, sv, nv) = (self.scalar(d), self.scalar(s), self.scalar(n));
                self.ins(if name == "memcopy" { Op::MemCpy } else { Op::MemSet }, T::Void, vec![dv, sv, nv], 0);
                Val::unit()
            }
            "embed" => {
                // the bytes of a file, read at compile time (path relative to the source file)
                arity!(1);
                let rel = match &args[0].k {
                    EK::Str(s) => String::from_utf8_lossy(s).to_string(),
                    _ => {
                        self.err(args[0].pos, "`embed` takes a string literal path".into());
                        return Some(Val::err());
                    }
                };
                let src = self.cx.file_names.get(pos.file as usize).cloned().unwrap_or_default();
                let dir = if src.starts_with('<') { std::env::var("ALC_STD_DIR").map(std::path::PathBuf::from).unwrap_or_default() } else { std::path::Path::new(&src).parent().map(|p| p.to_path_buf()).unwrap_or_default() };
                match std::fs::read(dir.join(&rel)) {
                    Ok(bytes) => self.str_val(&bytes),
                    Err(e) => {
                        self.err(args[0].pos, format!("cannot embed `{}`: {}", dir.join(&rel).display(), e));
                        Val::err()
                    }
                }
            }
            "panic" => {
                arity!(1);
                let m = self.expr(&args[0], Some(T_STR));
                let m = self.coerce(m, T_STR, args[0].pos);
                let loc = self.loc_str(pos);
                self.call_rt("__panic", vec![], vec![loc, m], pos)
            }
            "fmt" => {
                // evaluate everything first: output produced by the arguments themselves is not captured
                let mut vals = Vec::new();
                for a in args {
                    let v = self.expr(a, None);
                    let v = if v.mem && v.ty != T_ERR {
                        let t = self.temp(v.ty);
                        let tv = self.mval(v.ty, t);
                        self.store(tv, v);
                        tv
                    } else {
                        v
                    };
                    vals.push((v, a.pos));
                }
                let start = self.call_rt("__cap_begin", vec![], vec![], pos);
                for (v, p) in vals {
                    self.put_val(v, p, 0);
                }
                self.call_rt("__cap_end", vec![], vec![start], pos)
            }
            "hash" => {
                arity!(1);
                let v = self.expr(&args[0], None);
                if v.ty == T_ERR {
                    return Some(Val::err());
                }
                match self.hash_val(v, pos) {
                    Some(h) => self.sval(T_U64, h),
                    None => Val::err(),
                }
            }
            "put" | "print" => {
                for (i, a) in args.iter().enumerate() {
                    if i > 0 && name == "print" {
                        let sp = self.str_val(b" ");
                        self.call_rt("__put_str", vec![], vec![sp], pos);
                    }
                    let v = self.expr(a, None);
                    self.put_val(v, a.pos, 0);
                }
                if name == "print" {
                    let nl = self.str_val(b"\n");
                    self.call_rt("__put_str", vec![], vec![nl], pos);
                }
                Val::unit()
            }
            _ => return None,
        })
    }

    // hash of any value that supports `==`
    pub fn hash_val(&mut self, v: Val, pos: Pos) -> Option<V> {
        match self.cx.types.k(v.ty).clone() {
            TyK::Int(..) | TyK::Bool => {
                let x = self.to_i64(v);
                let a = self.sval(T_U64, x);
                let r = self.call_rt("__hash_u64", vec![], vec![a], pos);
                Some(self.scalar(r))
            }
            TyK::Ptr(_) | TyK::Fn(..) => {
                let x = self.scalar(v);
                let a = self.sval(T_U64, x);
                let r = self.call_rt("__hash_u64", vec![], vec![a], pos);
                Some(self.scalar(r))
            }
            TyK::Enum(_) if self.cx.types.is_scalar(v.ty) => {
                let x = self.scalar(v);
                let a = self.sval(T_U64, x);
                let r = self.call_rt("__hash_u64", vec![], vec![a], pos);
                Some(self.scalar(r))
            }
            TyK::F32 => {
                let d = self.convert(v, T_F64, pos);
                self.hash_val(d, pos)
            }
            TyK::F64 => {
                // -0.0 == 0.0, so both must hash alike
                let x = self.scalar(v);
                let z = self.ins(Op::FConst, T::F64, vec![], 0);
                let n = self.ins(Op::FAdd, T::F64, vec![x, z], 0);
                let bits = self.ins(Op::FToBits, T::I64, vec![n], 0);
                let a = self.sval(T_U64, bits);
                let r = self.call_rt("__hash_u64", vec![], vec![a], pos);
                Some(self.scalar(r))
            }
            TyK::Slice(et) => {
                let r = if et == T_U8 { self.call_rt("__hash_str", vec![], vec![v], pos) } else { self.call_rt("__hash_slice", vec![et], vec![v], pos) };
                Some(self.scalar(r))
            }
            TyK::Array(et, n) => {
                let sty = self.cx.types.slice(et);
                let t = self.temp(sty);
                let sv = self.mval(sty, t);
                let nv = self.iconst(T::I64, n as i64);
                self.store_slice(sv, v.v, nv);
                let r = if et == T_U8 { self.call_rt("__hash_str", vec![], vec![sv], pos) } else { self.call_rt("__hash_slice", vec![et], vec![sv], pos) };
                Some(self.scalar(r))
            }
            TyK::Struct(_) | TyK::Tuple(_) => {
                let names: Vec<String> = match self.cx.types.k(v.ty).clone() {
                    TyK::Struct(sid) => self.cx.types.structs[sid as usize].fields.iter().map(|f| f.0.clone()).collect(),
                    TyK::Tuple(ts) => (0..ts.len()).map(|i| i.to_string()).collect(),
                    _ => vec![],
                };
                let mut h = self.iconst(T::I64, 0x51ed270b);
                for n in names {
                    let p = self.field_of(v, &n, pos)?;
                    let fv = self.rvalue(p);
                    let fh = self.hash_val(fv, pos)?;
                    let (a, b) = (self.sval(T_U64, h), self.sval(T_U64, fh));
                    let r = self.call_rt("__hash_mix", vec![], vec![a, b], pos);
                    h = self.scalar(r);
                }
                Some(h)
            }
            _ => {
                let tn = self.tyname(v.ty);
                self.err(pos, format!("values of type {} cannot be hashed", tn));
                None
            }
        }
    }

    pub fn put_lit_pub(&mut self, s: &str, pos: Pos) {
        self.put_lit(s, pos)
    }
    fn put_lit(&mut self, s: &str, pos: Pos) {
        let v = self.str_val(s.as_bytes());
        self.call_rt("__put_str", vec![], vec![v], pos);
    }

    pub fn put_val(&mut self, v: Val, pos: Pos, depth: u32) {
        if v.ty == T_ERR || v.ty == T_NEVER {
            return;
        }
        match self.cx.types.k(v.ty).clone() {
            TyK::Unit => self.put_lit("()", pos),
            TyK::Int(bits, signed) => {
                let s = self.scalar(v);
                let s = if bits < 64 { self.ins(if signed { Op::SExt } else { Op::ZExt }, T::I64, vec![s], 0) } else { s };
                let (f, t) = if signed { ("__put_i64", T_I64) } else { ("__put_u64", T_U64) };
                let a = self.sval(t, s);
                self.call_rt(f, vec![], vec![a], pos);
            }
            TyK::F32 => {
                self.call_rt("__put_f32", vec![], vec![v], pos);
            }
            TyK::Vec(_) | TyK::Quat | TyK::Mat4 => self.put_vec(v, pos),
            TyK::F64 => {
                self.call_rt("__put_f64", vec![], vec![v], pos);
            }
            TyK::Bool => {
                self.call_rt("__put_bool", vec![], vec![v], pos);
            }
            TyK::Ptr(_) | TyK::Fn(..) => {
                let s = self.scalar(v);
                let a = self.sval(T_I64, s);
                self.call_rt("__put_ptr", vec![], vec![a], pos);
            }
            TyK::Slice(et) => {
                if et == T_U8 {
                    self.call_rt("__put_str", vec![], vec![v], pos);
                } else {
                    self.call_rt("__put_slice", vec![et], vec![v], pos);
                }
            }
            TyK::Array(et, n) => {
                let sty = self.cx.types.slice(et);
                let t = self.temp(sty);
                let sv = self.mval(sty, t);
                let nv = self.iconst(T::I64, n as i64);
                self.store_slice(sv, v.v, nv);
                self.call_rt("__put_slice", vec![et], vec![sv], pos);
            }
            TyK::Struct(sid) => {
                if depth > 8 {
                    self.put_lit("...", pos);
                    return;
                }
                let name = self.cx.types.structs[sid as usize].name.clone();
                let fields = self.cx.types.structs[sid as usize].fields.clone();
                self.put_lit(&format!("{}{{", name), pos);
                for (i, (fname, _)) in fields.iter().enumerate() {
                    let sep = if i > 0 { ", " } else { "" };
                    self.put_lit(&format!("{}{}: ", sep, fname), pos);
                    if let Some(p) = self.field_of(v, fname, pos) {
                        let fv = self.rvalue(p);
                        self.put_val(fv, pos, depth + 1);
                    }
                }
                self.put_lit("}", pos);
            }
            TyK::Tuple(tys) => {
                self.put_lit("(", pos);
                for i in 0..tys.len() {
                    if i > 0 {
                        self.put_lit(", ", pos);
                    }
                    if let Some(p) = self.field_of(v, &i.to_string(), pos) {
                        let fv = self.rvalue(p);
                        self.put_val(fv, pos, depth + 1);
                    }
                }
                self.put_lit(")", pos);
            }
            TyK::Enum(eid) => {
                if depth > 8 {
                    self.put_lit("...", pos);
                    return;
                }
                let info = self.cx.types.enums[eid as usize].clone();
                let tag = if info.simple { self.scalar(v) } else { self.load_raw(v.v, T::I64, AK_ANY) };
                let bj = self.new_block();
                for (vi, (vname, ptys)) in info.variants.iter().enumerate() {
                    let bt = self.new_block();
                    let bn = self.new_block();
                    let c = self.iconst(T::I64, vi as i64);
                    let eq = self.ins(Op::Eq, T::I8, vec![tag, c], 0);
                    self.br(eq, bt, bn);
                    self.switch_to(bt);
                    self.put_lit(vname, pos);
                    if !ptys.is_empty() {
                        self.put_lit("(", pos);
                        let offs = self.cx.types.variant_offsets(eid, vi);
                        for (i, pt) in ptys.iter().enumerate() {
                            if i > 0 {
                                self.put_lit(", ", pos);
                            }
                            let src = self.add_off(v.v, offs[i] as i64);
                            let pv = self.load_any(src, *pt);
                            let pv = self.rvalue(pv);
                            self.put_val(pv, pos, depth + 1);
                        }
                        self.put_lit(")", pos);
                    }
                    self.jmp(bj);
                    self.switch_to(bn);
                }
                self.put_lit("<invalid enum>", pos);
                self.jmp(bj);
                self.switch_to(bj);
            }
            TyK::Err | TyK::Never => {}
        }
    }
}
