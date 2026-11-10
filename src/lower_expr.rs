// Expression lowering: operators, places, literals, conversions, match.
use crate::ast::*;
use crate::ir::*;
use crate::lower::*;
use crate::lower_fn::*;
use crate::types::*;

fn is_arith(op: BinOp) -> bool {
    matches!(op, BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem | BinOp::And | BinOp::Or | BinOp::Xor)
}
fn is_cmp(op: BinOp) -> bool {
    matches!(op, BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge)
}

impl<'c, 'a> Fx<'c, 'a> {
    pub fn is_untyped(&self, e: &Expr) -> bool {
        match &e.k {
            EK::Int(_) | EK::Float(_) | EK::Nil => true,
            EK::Un(UnOp::Neg | UnOp::BitNot, x) => self.is_untyped(x),
            EK::Bin(op, a, b) if is_arith(*op) || matches!(op, BinOp::Shl | BinOp::Shr) => self.is_untyped(a) && self.is_untyped(b),
            EK::Ident(n) => {
                self.lookup(n).is_none()
                    && (self.cx.const_decls.get(n.as_str()).map(|d| d.ty.is_none()).unwrap_or(false)
                        || (self.cx.variants.contains_key(n.as_str()) && !self.cx.const_decls.contains_key(n.as_str())))
            }
            _ => false,
        }
    }

    pub fn int_lit(&mut self, n: i64, neg: bool, expect: Option<Ty>, pos: Pos) -> Val {
        let k = expect.map(|t| self.cx.types.k(t).clone());
        match k {
            Some(TyK::Int(bits, signed)) => {
                let ty = expect.unwrap();
                if bits < 64 {
                    let lo = -(1i64 << (bits - 1));
                    let hi = if signed && neg { 1i64 << (bits - 1) } else { 1i64 << bits };
                    if n < lo || n >= hi {
                        let tn = self.tyname(ty);
                        self.err(pos, format!("integer literal {} does not fit in {}", n, tn));
                    }
                }
                let it = self.irt(ty);
                let v = self.iconst(it, n);
                self.sval(ty, v)
            }
            Some(TyK::F64) => {
                let v = self.ins(Op::FConst, T::F64, vec![], (n as f64).to_bits() as i64);
                self.sval(T_F64, v)
            }
            _ => {
                let v = self.iconst(T::I64, n);
                self.sval(T_I64, v)
            }
        }
    }

    pub fn const_val(&mut self, ty: Option<Ty>, cv: CV, expect: Option<Ty>, pos: Pos) -> Val {
        match cv {
            CV::Int(i) => self.int_lit(i, i < 0, ty.or(expect), pos),
            CV::Float(f) => {
                let v = self.ins(Op::FConst, T::F64, vec![], f.to_bits() as i64);
                self.sval(T_F64, v)
            }
            CV::Bool(b) => {
                let v = self.iconst(T::I8, b as i64);
                self.sval(T_BOOL, v)
            }
            CV::Str(s) => self.str_val(&s),
        }
    }

    pub fn expr(&mut self, e: &'a Expr, expect: Option<Ty>) -> Val {
        match &e.k {
            EK::Int(n) => self.int_lit(*n as i64, false, expect, e.pos),
            EK::Float(f) => {
                if let Some(t) = expect {
                    if self.cx.types.is_int(t) {
                        let tn = self.tyname(t);
                        self.err(e.pos, format!("float literal used where {} is expected", tn));
                    }
                }
                let v = self.ins(Op::FConst, T::F64, vec![], f.to_bits() as i64);
                self.sval(T_F64, v)
            }
            EK::Bool(b) => {
                let v = self.iconst(T::I8, *b as i64);
                self.sval(T_BOOL, v)
            }
            EK::Nil => {
                let k = expect.map(|t| self.cx.types.k(t).clone());
                match k {
                    Some(TyK::Ptr(_)) | Some(TyK::Fn(..)) => {
                        let v = self.iconst(T::I64, 0);
                        self.sval(expect.unwrap(), v)
                    }
                    Some(TyK::Slice(_)) => {
                        let t = self.temp(expect.unwrap());
                        let v = self.mval(expect.unwrap(), t);
                        self.zero(v);
                        v
                    }
                    Some(TyK::Err) => Val::err(),
                    _ => {
                        self.err(e.pos, "cannot infer the type of `nil` here".into());
                        Val::err()
                    }
                }
            }
            EK::Str(s) => self.str_val(s),
            EK::Ident(n) => self.ident(n, expect, e.pos),
            EK::Un(op, x) => self.unary(*op, x, expect, e.pos),
            EK::Bin(op, a, b) => self.binary(*op, a, b, expect, e.pos),
            EK::Call(c, args) => self.call(c, args, expect, e.pos),
            EK::Field(b, name) => {
                if name == "len" {
                    // .len on slices and arrays
                    let save = self.cx.errs.len();
                    let bv = self.expr(b, None);
                    if let Some(v) = self.len_of(bv) {
                        return v;
                    }
                    return match self.field_of(bv, name, e.pos) {
                        Some(p) => self.rvalue(p),
                        None => Val::err(),
                    };
                }
                let bv = self.expr(b, None);
                match self.field_of(bv, name, e.pos) {
                    Some(p) => self.rvalue(p),
                    None => Val::err(),
                }
            }
            EK::Index(b, idx) => {
                if idx.len() != 1 {
                    self.err(e.pos, "expected a single index".into());
                    return Val::err();
                }
                match self.index_place(b, &idx[0], e.pos) {
                    Some(p) => self.rvalue(p),
                    None => Val::err(),
                }
            }
            EK::Slice(b, lo, hi) => self.slice_expr(b, lo.as_deref(), hi.as_deref(), e.pos),
            EK::Lit(te, items) => {
                let ty = match self.lit_type(te, expect) {
                    Some(t) => t,
                    None => return Val::err(),
                };
                if let TyK::Slice(et) = self.cx.types.k(ty).clone() {
                    // heap-allocated slice literal
                    let es = self.cx.types.size_of(et);
                    let n = items.len() as i64;
                    let bytes = self.iconst(T::I64, n * es as i64);
                    let bv = self.sval(T_I64, bytes);
                    let p = self.call_rt("__alloc_raw", vec![], vec![bv], e.pos);
                    let pv = self.scalar(p);
                    for (i, (name, item)) in items.iter().enumerate() {
                        if name.is_some() {
                            self.err(item.pos, "slice literal elements cannot be named".into());
                        }
                        let v = self.expr(item, Some(et));
                        let v = self.coerce(v, et, item.pos);
                        let a = self.add_off(pv, i as i64 * es as i64);
                        let dst = self.mval(et, a);
                        self.store(dst, v);
                    }
                    let t = self.temp(ty);
                    let sv = self.mval(ty, t);
                    let nv = self.iconst(T::I64, n);
                    self.store_slice(sv, pv, nv);
                    return sv;
                }
                let t = self.temp(ty);
                let dst = self.mval(ty, t);
                self.init_lit(dst, items, e.pos);
                dst
            }
            EK::TypeE(_) => {
                self.err(e.pos, "a type cannot be used as a value here".into());
                Val::err()
            }
            EK::If(c, t, el) => self.if_value(c, t, el, true, expect),
            EK::Tuple(es) => {
                let exp_tys: Option<Vec<Ty>> = match expect.map(|t| self.cx.types.k(t).clone()) {
                    Some(TyK::Tuple(ts)) if ts.len() == es.len() => Some(ts),
                    _ => None,
                };
                let mut vals = Vec::new();
                for (i, x) in es.iter().enumerate() {
                    let v = self.expr(x, exp_tys.as_ref().map(|t| t[i]));
                    // stabilize scalars now; aggregates are copied below
                    if v.ty == T_ERR {
                        return Val::err();
                    }
                    if v.ty == T_UNIT || v.ty == T_NEVER {
                        self.err(x.pos, "tuple element has no value".into());
                        return Val::err();
                    }
                    let v = if v.mem {
                        let t = self.temp(v.ty);
                        let tv = self.mval(v.ty, t);
                        self.store(tv, v);
                        tv
                    } else {
                        v
                    };
                    vals.push(v);
                }
                let tys: Vec<Ty> = vals.iter().map(|v| v.ty).collect();
                let ty = self.cx.types.intern(TyK::Tuple(tys.clone()));
                let offs = self.cx.types.tuple_offsets(&tys);
                let t = self.temp(ty);
                for (i, v) in vals.iter().enumerate() {
                    let a = self.add_off(t, offs[i] as i64);
                    let mut dst = self.mval(tys[i], a);
                    if self.cx.types.is_scalar(tys[i]) {
                        dst.alias = self.cx.types.field_alias(ty, i as u32, tys[i]);
                    }
                    self.store(dst, *v);
                }
                self.mval(ty, t)
            }
            EK::Match(sc, arms) => self.match_expr(sc, arms, true, expect, e.pos),
        }
    }

    // load scalars out of places; aggregates stay in memory
    pub fn rvalue(&mut self, p: Val) -> Val {
        if p.mem && self.cx.types.is_scalar(p.ty) {
            let v = self.scalar(p);
            return self.sval(p.ty, v);
        }
        p
    }

    fn ident(&mut self, n: &str, expect: Option<Ty>, pos: Pos) -> Val {
        if let Some((ty, addr)) = self.lookup(n) {
            let m = self.mval(ty, addr);
            return self.rvalue(m);
        }
        if self.cx.const_decls.contains_key(n) {
            return match self.cx.const_named(n) {
                Some((ty, cv)) => self.const_val(ty, cv, expect, pos),
                None => Val::err(),
            };
        }
        if let Some((ty, gid)) = self.cx.global(n) {
            let a = self.ins(Op::GAddr, T::I64, vec![], gid as i64);
            let m = self.mval(ty, a);
            return self.rvalue(m);
        }
        if let Some(&di) = self.cx.fn_names.get(n) {
            if !self.cx.fn_decls[di].tparams.is_empty() {
                self.err(pos, format!("generic function `{}` cannot be used as a value without type arguments", n));
                return Val::err();
            }
            let fid = self.cx.inst_fn(di, vec![]);
            let (ptys, rty) = self.cx.fn_sigs[fid as usize].clone();
            let ty = self.cx.types.intern(TyK::Fn(ptys, rty));
            let v = self.ins(Op::FAddr, T::I64, vec![], fid as i64);
            return self.sval(ty, v);
        }
        if let Some(&(ei, vi)) = self.cx.variants.get(n) {
            return self.construct_variant(ei, vi, &[], expect, pos);
        }
        if builtin_type(n).is_some() || self.tenv.contains_key(n) || self.cx.struct_names.contains_key(n) {
            self.err(pos, format!("type `{}` cannot be used as a value here", n));
            return Val::err();
        }
        self.err(pos, format!("unknown identifier `{}`", n));
        Val::err()
    }

    pub fn place(&mut self, e: &'a Expr) -> Option<Val> {
        match &e.k {
            EK::Ident(n) => {
                if let Some((ty, addr)) = self.lookup(n) {
                    return Some(self.mval(ty, addr));
                }
                if !self.cx.const_decls.contains_key(n.as_str()) {
                    if let Some((ty, gid)) = self.cx.global(n) {
                        let a = self.ins(Op::GAddr, T::I64, vec![], gid as i64);
                        return Some(self.mval(ty, a));
                    }
                }
                if self.cx.const_decls.contains_key(n.as_str()) || self.cx.fn_names.contains_key(n.as_str()) {
                    self.err(e.pos, format!("`{}` is not assignable", n));
                } else {
                    self.err(e.pos, format!("unknown variable `{}` (declare it with `:=`)", n));
                }
                None
            }
            EK::Field(b, name) => {
                let bv = self.expr(b, None);
                self.field_of(bv, name, e.pos)
            }
            EK::Index(b, idx) if idx.len() == 1 => self.index_place(b, &idx[0], e.pos),
            EK::Un(UnOp::Deref, p) => {
                let pv = self.expr(p, None);
                match self.cx.types.k(pv.ty).clone() {
                    TyK::Ptr(t) => {
                        let a = self.scalar(pv);
                        Some(self.mval(t, a))
                    }
                    TyK::Err => None,
                    _ => {
                        let tn = self.tyname(pv.ty);
                        self.err(e.pos, format!("cannot dereference {}", tn));
                        None
                    }
                }
            }
            _ => {
                self.err(e.pos, "expression is not assignable".into());
                None
            }
        }
    }

    // auto-dereference pointers to aggregates
    pub fn auto_deref(&mut self, mut v: Val) -> Val {
        loop {
            match self.cx.types.k(v.ty).clone() {
                TyK::Ptr(t) if !matches!(self.cx.types.k(t), TyK::Ptr(_)) && !self.cx.types.is_scalar(t) => {
                    let a = self.scalar(v);
                    v = self.mval(t, a);
                }
                _ => return v,
            }
        }
    }

    pub fn field_of(&mut self, base: Val, name: &str, pos: Pos) -> Option<Val> {
        let bv = self.auto_deref(base);
        match self.cx.types.k(bv.ty).clone() {
            TyK::Struct(sid) => {
                self.cx.types.layout_struct(sid);
                let si = &self.cx.types.structs[sid as usize];
                match si.fields.iter().position(|f| f.0 == name) {
                    Some(fi) => {
                        let fty = si.fields[fi].1;
                        let off = si.offsets[fi];
                        let a = self.add_off(bv.v, off as i64);
                        let mut v = self.mval(fty, a);
                        if self.cx.types.is_scalar(fty) {
                            v.alias = self.cx.types.field_alias(bv.ty, fi as u32, fty);
                        }
                        Some(v)
                    }
                    None => {
                        let tn = self.tyname(bv.ty);
                        let names: Vec<String> = self.cx.types.structs[sid as usize].fields.iter().map(|f| f.0.clone()).collect();
                        self.err(pos, format!("{} has no field `{}` (fields: {})", tn, name, names.join(", ")));
                        None
                    }
                }
            }
            TyK::Tuple(tys) => match name.parse::<usize>() {
                Ok(i) if i < tys.len() => {
                    let offs = self.cx.types.tuple_offsets(&tys);
                    let a = self.add_off(bv.v, offs[i] as i64);
                    let mut v = self.mval(tys[i], a);
                    if self.cx.types.is_scalar(tys[i]) {
                        v.alias = self.cx.types.field_alias(bv.ty, i as u32, tys[i]);
                    }
                    Some(v)
                }
                _ => {
                    let tn = self.tyname(bv.ty);
                    self.err(pos, format!("{} has no element `{}`", tn, name));
                    None
                }
            },
            TyK::Err => None,
            _ => {
                let tn = self.tyname(bv.ty);
                self.err(pos, format!("{} has no field `{}`", tn, name));
                None
            }
        }
    }

    pub fn len_of(&mut self, v: Val) -> Option<Val> {
        let v = self.auto_deref(v);
        match self.cx.types.k(v.ty).clone() {
            TyK::Slice(_) => {
                let (_, l) = self.slice_parts(v);
                Some(self.sval(T_I64, l))
            }
            TyK::Array(_, n) => {
                let l = self.iconst(T::I64, n as i64);
                Some(self.sval(T_I64, l))
            }
            _ => None,
        }
    }

    pub fn to_i64(&mut self, v: Val) -> V {
        let s = self.scalar(v);
        let it = self.irt(v.ty);
        if it == T::I64 {
            return s;
        }
        let op = if self.cx.types.is_signed(v.ty) { Op::SExt } else { Op::ZExt };
        self.ins(op, T::I64, vec![s], 0)
    }

    // (ptr, len or NOV, elem type) of an indexable value
    fn indexable(&mut self, bv: Val, pos: Pos) -> Option<(V, V, Ty)> {
        let bv = self.auto_deref(bv);
        match self.cx.types.k(bv.ty).clone() {
            TyK::Slice(et) => {
                let (p, l) = self.slice_parts(bv);
                Some((p, l, et))
            }
            TyK::Array(et, n) => {
                let l = self.iconst(T::I64, n as i64);
                Some((bv.v, l, et))
            }
            TyK::Ptr(t) => {
                let p = self.scalar(bv);
                Some((p, NOV, t))
            }
            TyK::Err => None,
            _ => {
                let tn = self.tyname(bv.ty);
                self.err(pos, format!("cannot index {}", tn));
                None
            }
        }
    }

    pub fn index_place(&mut self, b: &'a Expr, idx: &'a Expr, pos: Pos) -> Option<Val> {
        let bv = self.expr(b, None);
        let (ptr, len, et) = self.indexable(bv, pos)?;
        let iv = self.expr(idx, Some(T_I64));
        if iv.ty == T_ERR {
            return None;
        }
        if !self.cx.types.is_int(iv.ty) {
            let tn = self.tyname(iv.ty);
            self.err(idx.pos, format!("index must be an integer, found {}", tn));
            return None;
        }
        let i = self.to_i64(iv);
        if len != NOV {
            let (ci, cl) = (self.f.is_const(i), self.f.is_const(len));
            if let (Some(ci), Some(cl)) = (ci, cl) {
                if ci < 0 || ci >= cl {
                    self.err(idx.pos, format!("index {} is out of bounds for length {}", ci, cl));
                }
            } else if self.cx.opts.checks {
                let c = self.ins(Op::Ult, T::I8, vec![i, len], 0);
                self.check(c, 0, pos);
            }
        }
        let es = self.cx.types.size_of(et);
        let off = if es == 1 {
            i
        } else {
            let c = self.iconst(T::I64, es as i64);
            self.ins(Op::Mul, T::I64, vec![i, c], 0)
        };
        let a = self.ins(Op::Add, T::I64, vec![ptr, off], 0);
        Some(self.mval(et, a))
    }

    fn slice_expr(&mut self, b: &'a Expr, lo: Option<&'a Expr>, hi: Option<&'a Expr>, pos: Pos) -> Val {
        let bv = self.expr(b, None);
        let (ptr, len, et) = match self.indexable(bv, pos) {
            Some(x) => x,
            None => return Val::err(),
        };
        let lo_v = match lo {
            Some(l) => {
                let v = self.expr(l, Some(T_I64));
                if !self.cx.types.is_int(v.ty) {
                    if v.ty != T_ERR {
                        self.err(l.pos, "slice bound must be an integer".into());
                    }
                    return Val::err();
                }
                self.to_i64(v)
            }
            None => self.iconst(T::I64, 0),
        };
        let hi_v = match hi {
            Some(h) => {
                let v = self.expr(h, Some(T_I64));
                if !self.cx.types.is_int(v.ty) {
                    if v.ty != T_ERR {
                        self.err(h.pos, "slice bound must be an integer".into());
                    }
                    return Val::err();
                }
                self.to_i64(v)
            }
            None => {
                if len == NOV {
                    self.err(pos, "slicing a raw pointer needs an upper bound".into());
                    return Val::err();
                }
                len
            }
        };
        if self.cx.opts.checks {
            let c = self.ins(Op::Ule, T::I8, vec![lo_v, hi_v], 0);
            self.check(c, 0, pos);
            if len != NOV && hi.is_some() {
                let c = self.ins(Op::Ule, T::I8, vec![hi_v, len], 0);
                self.check(c, 0, pos);
            }
        }
        let es = self.cx.types.size_of(et);
        let c = self.iconst(T::I64, es as i64);
        let off = self.ins(Op::Mul, T::I64, vec![lo_v, c], 0);
        let p = self.ins(Op::Add, T::I64, vec![ptr, off], 0);
        let n = self.ins(Op::Sub, T::I64, vec![hi_v, lo_v], 0);
        let sty = self.cx.types.slice(et);
        let t = self.temp(sty);
        let sv = self.mval(sty, t);
        self.store_slice(sv, p, n);
        sv
    }

    fn unary(&mut self, op: UnOp, x: &'a Expr, expect: Option<Ty>, pos: Pos) -> Val {
        match op {
            UnOp::Neg => {
                if let EK::Int(n) = &x.k {
                    return self.int_lit((*n as i64).wrapping_neg(), true, expect, pos);
                }
                let v = self.expr(x, expect);
                if v.ty == T_ERR {
                    return v;
                }
                if self.cx.types.is_int(v.ty) {
                    let it = self.irt(v.ty);
                    let z = self.iconst(it, 0);
                    let s = self.scalar(v);
                    let r = self.ins(Op::Sub, it, vec![z, s], 0);
                    self.sval(v.ty, r)
                } else if v.ty == T_F64 {
                    let s = self.scalar(v);
                    let r = self.ins(Op::FNeg, T::F64, vec![s], 0);
                    self.sval(T_F64, r)
                } else {
                    let tn = self.tyname(v.ty);
                    self.err(pos, format!("cannot negate {}", tn));
                    Val::err()
                }
            }
            UnOp::Not => {
                let v = self.expr(x, Some(T_BOOL));
                let v = self.coerce(v, T_BOOL, x.pos);
                if v.ty == T_ERR {
                    return v;
                }
                let s = self.scalar(v);
                let one = self.iconst(T::I8, 1);
                let r = self.ins(Op::Xor, T::I8, vec![s, one], 0);
                self.sval(T_BOOL, r)
            }
            UnOp::BitNot => {
                let v = self.expr(x, expect);
                if v.ty == T_ERR {
                    return v;
                }
                if !self.cx.types.is_int(v.ty) {
                    let tn = self.tyname(v.ty);
                    self.err(pos, format!("`~` needs an integer, found {}", tn));
                    return Val::err();
                }
                let it = self.irt(v.ty);
                let s = self.scalar(v);
                let m = self.iconst(it, -1);
                let r = self.ins(Op::Xor, it, vec![s, m], 0);
                self.sval(v.ty, r)
            }
            UnOp::Addr => {
                if let EK::Lit(te, items) = &x.k {
                    let inner_expect = match expect.map(|t| self.cx.types.k(t).clone()) {
                        Some(TyK::Ptr(t)) => Some(t),
                        _ => None,
                    };
                    let ty = match self.lit_type(te, inner_expect) {
                        Some(t) => t,
                        None => return Val::err(),
                    };
                    let sz = self.cx.types.size_of(ty);
                    let bytes = self.iconst(T::I64, sz as i64);
                    let bv = self.sval(T_I64, bytes);
                    let p = self.call_rt("__alloc_raw", vec![], vec![bv], pos);
                    let pv = self.scalar(p);
                    let dst = self.mval(ty, pv);
                    self.init_lit(dst, items, pos);
                    let pt = self.cx.types.ptr(ty);
                    return self.sval(pt, pv);
                }
                match self.place(x) {
                    Some(p) => {
                        if p.alias >> 4 != 0 {
                            self.cx.exposed.insert(p.alias >> 4);
                        }
                        let pt = self.cx.types.ptr(p.ty);
                        self.sval(pt, p.v)
                    }
                    None => Val::err(),
                }
            }
            UnOp::Deref => {
                let pv = self.expr(x, None);
                match self.cx.types.k(pv.ty).clone() {
                    TyK::Ptr(t) => {
                        let a = self.scalar(pv);
                        let m = self.mval(t, a);
                        self.rvalue(m)
                    }
                    TyK::Err => Val::err(),
                    _ => {
                        let tn = self.tyname(pv.ty);
                        self.err(pos, format!("cannot dereference {}", tn));
                        Val::err()
                    }
                }
            }
        }
    }

    fn binary(&mut self, op: BinOp, a: &'a Expr, b: &'a Expr, expect: Option<Ty>, pos: Pos) -> Val {
        match op {
            BinOp::LAnd | BinOp::LOr => {
                let slot = self.temp(T_BOOL);
                let bt = self.new_block();
                let bf = self.new_block();
                let bj = self.new_block();
                let mid = self.new_block();
                if op == BinOp::LAnd {
                    self.cond_br(a, mid, bf);
                } else {
                    self.cond_br(a, bt, mid);
                }
                self.switch_to(mid);
                self.cond_br(b, bt, bf);
                self.switch_to(bt);
                let one = self.iconst(T::I8, 1);
                self.store_raw(slot, one, T::I8, 0);
                self.jmp(bj);
                self.switch_to(bf);
                let zero = self.iconst(T::I8, 0);
                self.store_raw(slot, zero, T::I8, 0);
                self.jmp(bj);
                self.switch_to(bj);
                let v = self.load_raw(slot, T::I8, 0);
                self.sval(T_BOOL, v)
            }
            BinOp::Shl | BinOp::Shr => {
                let l = self.expr(a, expect);
                let r = self.expr(b, None);
                self.binary_vals(op, l, r, pos)
            }
            _ => {
                let exp = if is_cmp(op) {
                    None
                } else {
                    match expect {
                        Some(t) if self.cx.types.is_int(t) || t == T_F64 => Some(t),
                        _ => None,
                    }
                };
                let both_untyped = self.is_untyped(a) && self.is_untyped(b);
                let exp = if both_untyped && (matches!(self.cx.const_eval(a), Some(CV::Float(_))) || matches!(self.cx.const_eval(b), Some(CV::Float(_)))) {
                    Some(T_F64)
                } else {
                    exp
                };
                let (l, r) = if self.is_untyped(a) && !self.is_untyped(b) {
                    let r = self.expr(b, exp);
                    let l = self.expr(a, Some(r.ty));
                    (l, r)
                } else {
                    let l = self.expr(a, exp);
                    let r = self.expr(b, Some(l.ty));
                    (l, r)
                };
                self.binary_vals(op, l, r, pos)
            }
        }
    }

    pub fn binary_vals(&mut self, op: BinOp, l: Val, r: Val, pos: Pos) -> Val {
        if l.ty == T_ERR || r.ty == T_ERR {
            return Val::err();
        }
        let lk = self.cx.types.k(l.ty).clone();
        if matches!(op, BinOp::Shl | BinOp::Shr) {
            if !self.cx.types.is_int(l.ty) || !self.cx.types.is_int(r.ty) {
                self.err(pos, "shift operands must be integers".into());
                return Val::err();
            }
            let it = self.irt(l.ty);
            let rt = self.irt(r.ty);
            let lv = self.scalar(l);
            let mut rv = self.scalar(r);
            if rt.size() > it.size() {
                rv = self.ins(Op::Trunc, it, vec![rv], 0);
            } else if rt.size() < it.size() {
                rv = self.ins(Op::ZExt, it, vec![rv], 0);
            }
            let o = match op {
                BinOp::Shl => Op::Shl,
                _ => {
                    if self.cx.types.is_signed(l.ty) {
                        Op::AShr
                    } else {
                        Op::LShr
                    }
                }
            };
            let v = self.ins(o, it, vec![lv, rv], 0);
            return self.sval(l.ty, v);
        }
        if l.ty != r.ty {
            let (a, b) = (self.tyname(l.ty), self.tyname(r.ty));
            self.err(pos, format!("operands have different types: {} and {} (convert explicitly, e.g. `{}(x)`)", a, b, a));
            return Val::err();
        }
        if is_cmp(op) {
            let eq_only = matches!(op, BinOp::Eq | BinOp::Ne);
            match lk {
                TyK::Int(_, signed) => {
                    let o = match (op, signed) {
                        (BinOp::Eq, _) => Op::Eq,
                        (BinOp::Ne, _) => Op::Ne,
                        (BinOp::Lt, true) => Op::Slt,
                        (BinOp::Le, true) => Op::Sle,
                        (BinOp::Gt, true) => Op::Sgt,
                        (BinOp::Ge, true) => Op::Sge,
                        (BinOp::Lt, false) => Op::Ult,
                        (BinOp::Le, false) => Op::Ule,
                        (BinOp::Gt, false) => Op::Ugt,
                        (_, _) => Op::Uge,
                    };
                    let (a, b) = (self.scalar(l), self.scalar(r));
                    let v = self.ins(o, T::I8, vec![a, b], 0);
                    return self.sval(T_BOOL, v);
                }
                TyK::F64 => {
                    let o = match op {
                        BinOp::Eq => Op::FEq,
                        BinOp::Ne => Op::FNe,
                        BinOp::Lt => Op::FLt,
                        BinOp::Le => Op::FLe,
                        BinOp::Gt => Op::FGt,
                        _ => Op::FGe,
                    };
                    let (a, b) = (self.scalar(l), self.scalar(r));
                    let v = self.ins(o, T::I8, vec![a, b], 0);
                    return self.sval(T_BOOL, v);
                }
                TyK::Bool | TyK::Ptr(_) | TyK::Fn(..) | TyK::Enum(_) if eq_only && self.cx.types.is_scalar(l.ty) => {
                    let (a, b) = (self.scalar(l), self.scalar(r));
                    let v = self.ins(if op == BinOp::Eq { Op::Eq } else { Op::Ne }, T::I8, vec![a, b], 0);
                    return self.sval(T_BOOL, v);
                }
                TyK::Slice(et) if et == T_U8 && eq_only => {
                    let v = self.call_rt("__str_eq", vec![], vec![l, r], pos);
                    if op == BinOp::Eq {
                        return v;
                    }
                    let s = self.scalar(v);
                    let one = self.iconst(T::I8, 1);
                    let x = self.ins(Op::Xor, T::I8, vec![s, one], 0);
                    return self.sval(T_BOOL, x);
                }
                _ => {
                    let tn = self.tyname(l.ty);
                    self.err(pos, format!("cannot compare values of type {} with this operator", tn));
                    return Val::err();
                }
            }
        }
        match lk {
            TyK::Int(_, signed) => {
                let it = self.irt(l.ty);
                let (a, b) = (self.scalar(l), self.scalar(r));
                let o = match op {
                    BinOp::Add => Op::Add,
                    BinOp::Sub => Op::Sub,
                    BinOp::Mul => Op::Mul,
                    BinOp::And => Op::And,
                    BinOp::Or => Op::Or,
                    BinOp::Xor => Op::Xor,
                    BinOp::Div | BinOp::Rem => {
                        return self.int_div(op == BinOp::Div, signed, l.ty, it, a, b, pos);
                    }
                    _ => unreachable!(),
                };
                let v = self.ins(o, it, vec![a, b], 0);
                self.sval(l.ty, v)
            }
            TyK::F64 => {
                let o = match op {
                    BinOp::Add => Op::FAdd,
                    BinOp::Sub => Op::FSub,
                    BinOp::Mul => Op::FMul,
                    BinOp::Div => Op::FDiv,
                    _ => {
                        self.err(pos, "this operator is not defined for f64".into());
                        return Val::err();
                    }
                };
                let (a, b) = (self.scalar(l), self.scalar(r));
                let v = self.ins(o, T::F64, vec![a, b], 0);
                self.sval(T_F64, v)
            }
            _ => {
                let tn = self.tyname(l.ty);
                self.err(pos, format!("arithmetic is not defined for {}", tn));
                Val::err()
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn int_div(&mut self, is_div: bool, signed: bool, ty: Ty, it: T, a: V, b: V, pos: Pos) -> Val {
        let o = match (is_div, signed) {
            (true, true) => Op::SDiv,
            (true, false) => Op::UDiv,
            (false, true) => Op::SRem,
            (false, false) => Op::URem,
        };
        if let Some(k) = self.f.is_const(b) {
            if k == 0 {
                self.err(pos, "division by constant zero".into());
                return Val::err();
            }
            if signed && k == -1 {
                let z = self.iconst(it, 0);
                let v = if is_div { self.ins(Op::Sub, it, vec![z, a], 0) } else { z };
                return self.sval(ty, v);
            }
            let v = self.ins(o, it, vec![a, b], 0);
            return self.sval(ty, v);
        }
        if !self.cx.opts.checks {
            let v = self.ins(o, it, vec![a, b], 0);
            return self.sval(ty, v);
        }
        let z = self.iconst(it, 0);
        let nz = self.ins(Op::Ne, T::I8, vec![b, z], 0);
        self.check(nz, 1, pos);
        if !signed {
            let v = self.ins(o, it, vec![a, b], 0);
            return self.sval(ty, v);
        }
        // signed: x / -1 wraps instead of trapping
        let slot = self.alloca(it.size(), it.size());
        let m1 = self.iconst(it, -1);
        let is_m1 = self.ins(Op::Eq, T::I8, vec![b, m1], 0);
        let b_m1 = self.new_block();
        let b_div = self.new_block();
        let bj = self.new_block();
        let d = self.dead;
        self.br(is_m1, b_m1, b_div);
        self.switch_to(b_m1);
        let z2 = self.iconst(it, 0);
        let v1 = if is_div { self.ins(Op::Sub, it, vec![z2, a], 0) } else { z2 };
        self.store_raw(slot, v1, it, 0);
        self.jmp(bj);
        self.switch_to(b_div);
        let v2 = self.ins(o, it, vec![a, b], 0);
        self.store_raw(slot, v2, it, 0);
        self.jmp(bj);
        self.switch_to(bj);
        self.dead = d;
        let v = self.load_raw(slot, it, 0);
        self.sval(ty, v)
    }

    // ---------- conversions ----------
    pub fn convert(&mut self, v: Val, to: Ty, pos: Pos) -> Val {
        if v.ty == to || v.ty == T_ERR || to == T_ERR {
            return if to == T_ERR { Val::err() } else { v };
        }
        let fk = self.cx.types.k(v.ty).clone();
        let tk = self.cx.types.k(to).clone();
        let tt = self.irt(to);
        match (fk, tk) {
            (TyK::Int(fb, fs), TyK::Int(tb, _)) => {
                let s = self.scalar(v);
                let r = if tb < fb {
                    self.ins(Op::Trunc, tt, vec![s], 0)
                } else if tb > fb {
                    self.ins(if fs { Op::SExt } else { Op::ZExt }, tt, vec![s], 0)
                } else {
                    s
                };
                self.sval(to, r)
            }
            (TyK::Bool, TyK::Int(tb, _)) => {
                let s = self.scalar(v);
                let r = if tb > 8 { self.ins(Op::ZExt, tt, vec![s], 0) } else { s };
                self.sval(to, r)
            }
            (TyK::Enum(_), TyK::Int(tb, _)) if self.cx.types.is_scalar(v.ty) => {
                let s = self.scalar(v);
                let r = if tb < 64 { self.ins(Op::Trunc, tt, vec![s], 0) } else { s };
                self.sval(to, r)
            }
            (TyK::Int(fb, fs), TyK::F64) => {
                let mut s = self.scalar(v);
                if fb < 64 {
                    s = self.ins(if fs { Op::SExt } else { Op::ZExt }, T::I64, vec![s], 0);
                    let r = self.ins(Op::SIToF, T::F64, vec![s], 0);
                    return self.sval(to, r);
                }
                if fs {
                    let r = self.ins(Op::SIToF, T::F64, vec![s], 0);
                    return self.sval(to, r);
                }
                // u64: values >= 2^63 are halved (keeping the sticky bit), converted and doubled
                let slot = self.alloca(8, 8);
                let zero = self.iconst(T::I64, 0);
                let nonneg = self.ins(Op::Sge, T::I8, vec![s, zero], 0);
                let b_lo = self.new_block();
                let b_hi = self.new_block();
                let bj = self.new_block();
                let d = self.dead;
                self.br(nonneg, b_lo, b_hi);
                self.switch_to(b_lo);
                let r1 = self.ins(Op::SIToF, T::F64, vec![s], 0);
                self.store_raw(slot, r1, T::F64, 0);
                self.jmp(bj);
                self.switch_to(b_hi);
                let one = self.iconst(T::I64, 1);
                let half = self.ins(Op::LShr, T::I64, vec![s, one], 0);
                let low = self.ins(Op::And, T::I64, vec![s, one], 0);
                let h = self.ins(Op::Or, T::I64, vec![half, low], 0);
                let hf = self.ins(Op::SIToF, T::F64, vec![h], 0);
                let r2 = self.ins(Op::FAdd, T::F64, vec![hf, hf], 0);
                self.store_raw(slot, r2, T::F64, 0);
                self.jmp(bj);
                self.switch_to(bj);
                self.dead = d;
                let r = self.load_raw(slot, T::F64, 0);
                self.sval(to, r)
            }
            (TyK::F64, TyK::Int(tb, _)) => {
                let s = self.scalar(v);
                let mut r = self.ins(Op::FToSI, T::I64, vec![s], 0);
                if tb < 64 {
                    r = self.ins(Op::Trunc, tt, vec![r], 0);
                }
                self.sval(to, r)
            }
            _ => {
                let (a, b) = (self.tyname(v.ty), self.tyname(to));
                self.err(pos, format!("cannot convert {} to {} (use cast[T](x) for reinterpretation)", a, b));
                Val::err()
            }
        }
    }

    // ---------- composite literals ----------
    fn lit_type(&mut self, te: &'a Expr, expect: Option<Ty>) -> Option<Ty> {
        let env = self.tenv.clone();
        if let Some(t) = self.cx.expr_type(te, &env) {
            if t == T_ERR {
                return None;
            }
            return Some(t);
        }
        // generic struct named without type arguments: take them from the expected type
        if let EK::Ident(n) = &te.k {
            if let Some(&si) = self.cx.struct_names.get(n.as_str()) {
                if let Some(TyK::Struct(sid)) = expect.map(|t| self.cx.types.k(t).clone()) {
                    if self.cx.types.structs[sid as usize].decl == si {
                        return expect;
                    }
                }
                self.err(te.pos, format!("generic struct `{}` needs type arguments here, e.g. `{}[i64]{{...}}`", n, n));
                return None;
            }
        }
        self.err(te.pos, "expected a type before `{`".into());
        None
    }

    fn init_lit(&mut self, dst: Val, items: &'a [(Option<String>, Expr)], pos: Pos) {
        match self.cx.types.k(dst.ty).clone() {
            TyK::Struct(sid) => {
                self.cx.types.layout_struct(sid);
                let fields = self.cx.types.structs[sid as usize].fields.clone();
                let offs = self.cx.types.structs[sid as usize].offsets.clone();
                if items.len() < fields.len() {
                    self.zero(dst);
                }
                let mut seen = vec![false; fields.len()];
                for (i, (name, item)) in items.iter().enumerate() {
                    let fi = match name {
                        Some(n) => match fields.iter().position(|f| &f.0 == n) {
                            Some(fi) => fi,
                            None => {
                                let tn = self.tyname(dst.ty);
                                self.err(item.pos, format!("{} has no field `{}`", tn, n));
                                continue;
                            }
                        },
                        None => i,
                    };
                    if fi >= fields.len() {
                        self.err(item.pos, "too many values in struct literal".into());
                        break;
                    }
                    if seen[fi] {
                        self.err(item.pos, format!("field `{}` initialized twice", fields[fi].0));
                    }
                    seen[fi] = true;
                    let fty = fields[fi].1;
                    let v = self.expr(item, Some(fty));
                    let v = self.coerce(v, fty, item.pos);
                    let a = self.add_off(dst.v, offs[fi] as i64);
                    let mut fd = self.mval(fty, a);
                    if self.cx.types.is_scalar(fty) {
                        fd.alias = self.cx.types.field_alias(dst.ty, fi as u32, fty);
                    }
                    self.store(fd, v);
                }
            }
            TyK::Array(et, n) => {
                if items.len() as u64 > n {
                    self.err(pos, format!("too many elements in array literal (max {})", n));
                    return;
                }
                if (items.len() as u64) < n {
                    self.zero(dst);
                }
                let es = self.cx.types.size_of(et);
                for (i, (name, item)) in items.iter().enumerate() {
                    if name.is_some() {
                        self.err(item.pos, "array literal elements cannot be named".into());
                    }
                    let v = self.expr(item, Some(et));
                    let v = self.coerce(v, et, item.pos);
                    let a = self.add_off(dst.v, i as i64 * es as i64);
                    let ed = self.mval(et, a);
                    self.store(ed, v);
                }
            }
            TyK::Tuple(tys) => {
                if items.len() != tys.len() {
                    self.err(pos, "wrong number of tuple elements".into());
                    return;
                }
                let offs = self.cx.types.tuple_offsets(&tys);
                for (i, (_, item)) in items.iter().enumerate() {
                    let v = self.expr(item, Some(tys[i]));
                    let v = self.coerce(v, tys[i], item.pos);
                    let a = self.add_off(dst.v, offs[i] as i64);
                    let mut fd = self.mval(tys[i], a);
                    if self.cx.types.is_scalar(tys[i]) {
                        fd.alias = self.cx.types.field_alias(dst.ty, i as u32, tys[i]);
                    }
                    self.store(fd, v);
                }
            }
            _ => {
                let tn = self.tyname(dst.ty);
                self.err(pos, format!("{} cannot be built with a `{{...}}` literal", tn));
            }
        }
    }

    // ---------- enums ----------
    pub fn construct_variant(&mut self, ei: usize, vi: usize, args: &'a [Expr], expect: Option<Ty>, pos: Pos) -> Val {
        let d = self.cx.enum_decls[ei];
        let vname = &d.variants[vi].0;
        let ety = if d.tparams.is_empty() {
            self.cx.inst_enum(ei, vec![], pos)
        } else {
            match expect.map(|t| self.cx.types.k(t).clone()) {
                Some(TyK::Enum(eid)) if self.cx.types.enums[eid as usize].decl == ei => expect.unwrap(),
                _ => {
                    // infer type arguments from the payload
                    let mut env = std::collections::HashMap::new();
                    let mut ok = args.len() == d.variants[vi].1.len();
                    if ok {
                        for (a, pt) in args.iter().zip(d.variants[vi].1.iter()) {
                            let v = self.expr(a, None);
                            if !self.unify(pt, v.ty, &d.tparams, &mut env) {
                                ok = false;
                            }
                        }
                    }
                    let targs: Vec<Ty> = d.tparams.iter().filter_map(|p| env.get(p).copied()).collect();
                    if !ok || targs.len() != d.tparams.len() {
                        self.err(pos, format!("cannot infer type arguments of enum `{}` for `{}`; annotate the destination type", d.name, vname));
                        return Val::err();
                    }
                    // re-evaluating args below duplicates their code, so only allow it for inferred cases
                    self.cx.inst_enum(ei, targs, pos)
                }
            }
        };
        let eid = match self.cx.types.k(ety).clone() {
            TyK::Enum(eid) => eid,
            _ => return Val::err(),
        };
        let ptys = self.cx.types.enums[eid as usize].variants[vi].1.clone();
        if args.len() != ptys.len() {
            self.err(pos, format!("variant `{}` takes {} value(s), got {}", vname, ptys.len(), args.len()));
            return Val::err();
        }
        if self.cx.types.enums[eid as usize].simple {
            let v = self.iconst(T::I64, vi as i64);
            return self.sval(ety, v);
        }
        let t = self.temp(ety);
        let dst = self.mval(ety, t);
        self.zero(dst);
        let tag = self.iconst(T::I64, vi as i64);
        self.store_raw(t, tag, T::I64, AK_ANY);
        let offs = self.cx.types.variant_offsets(eid, vi);
        for (i, a) in args.iter().enumerate() {
            let v = self.expr(a, Some(ptys[i]));
            let v = self.coerce(v, ptys[i], a.pos);
            let fa = self.add_off(t, offs[i] as i64);
            let mut fd = self.mval(ptys[i], fa);
            fd.alias = if self.cx.types.is_scalar(ptys[i]) { AK_ANY } else { 0 };
            self.store_any(fd, v);
        }
        dst
    }

    // store into enum payload memory: all accesses use the "any" alias class
    fn store_any(&mut self, dst: Val, src: Val) {
        if src.ty == T_ERR || src.ty == T_NEVER {
            return;
        }
        if self.cx.types.is_scalar(dst.ty) {
            let v = self.scalar(src);
            let t = self.irt(dst.ty);
            self.store_raw(dst.v, v, t, AK_ANY);
            return;
        }
        let mut leaves = Vec::new();
        self.cx.types.leaves(dst.ty, 0, &mut leaves);
        if leaves.len() > 64 {
            let sz = self.cx.types.size_of(dst.ty);
            let c = self.iconst(T::I64, sz as i64);
            self.ins(Op::MemCpy, T::Void, vec![dst.v, src.v, c], 0);
            return;
        }
        let mut vals = Vec::new();
        for l in &leaves {
            let a = self.add_off(src.v, l.off as i64);
            vals.push(self.load_raw(a, l.t, l.alias));
        }
        for (l, v) in leaves.iter().zip(vals) {
            let a = self.add_off(dst.v, l.off as i64);
            self.store_raw(a, v, l.t, AK_ANY);
        }
    }

    pub fn load_any(&mut self, src: V, ty: Ty) -> Val {
        // copy a payload field out of enum memory into a fresh temp
        let t = self.temp(ty);
        let dst = self.mval(ty, t);
        let mut leaves = Vec::new();
        self.cx.types.leaves(ty, 0, &mut leaves);
        if leaves.len() > 64 {
            let sz = self.cx.types.size_of(ty);
            let c = self.iconst(T::I64, sz as i64);
            self.ins(Op::MemCpy, T::Void, vec![t, src, c], 0);
            return dst;
        }
        for l in &leaves {
            let a = self.add_off(src, l.off as i64);
            let v = self.load_raw(a, l.t, AK_ANY);
            let d = self.add_off(t, l.off as i64);
            self.store_raw(d, v, l.t, l.alias);
        }
        dst
    }

    pub fn match_expr(&mut self, sc: &'a Expr, arms: &'a [MatchArm], want: bool, expect: Option<Ty>, pos: Pos) -> Val {
        let sv = self.expr(sc, None);
        if sv.ty == T_ERR {
            return Val::err();
        }
        let sk = self.cx.types.k(sv.ty).clone();
        let enum_id = match sk {
            TyK::Enum(e) => Some(e),
            _ => None,
        };
        let payload_enum = enum_id.map(|e| !self.cx.types.enums[e as usize].simple).unwrap_or(false);
        // scrutinee: scalar value, or tag for payload enums
        let (key, key_ty): (V, Ty) = if payload_enum {
            (self.load_raw(sv.v, T::I64, AK_ANY), T_I64)
        } else if self.cx.types.is_scalar(sv.ty) {
            (self.scalar(sv), sv.ty)
        } else if sv.ty == T_STR {
            (NOV, T_STR)
        } else {
            let tn = self.tyname(sv.ty);
            self.err(pos, format!("cannot match on {}", tn));
            return Val::err();
        };
        // keep a stable copy of string scrutinee
        let str_tmp = if sv.ty == T_STR {
            let t = self.temp(T_STR);
            let tv = self.mval(T_STR, t);
            self.store(tv, sv);
            Some(tv)
        } else {
            None
        };
        let bj = self.new_block();
        let mut slot: Option<Val> = None;
        let mut all_dead = true;
        let mut has_wild = false;
        let mut covered: Vec<bool> = match enum_id {
            Some(e) => vec![false; self.cx.types.enums[e as usize].variants.len()],
            None => vec![],
        };
        let mut result_err = false;
        for arm in arms {
            let body_b = self.new_block();
            let next_b = self.new_block();
            let mut binds: Option<(usize, &'a Vec<String>)> = None;
            let npats = arm.pats.len();
            for (pi, pat) in arm.pats.iter().enumerate() {
                let last = pi + 1 == npats;
                let fail_b = if last { next_b } else { self.new_block() };
                match pat {
                    Pat::Wild => {
                        has_wild = true;
                        self.jmp(body_b);
                    }
                    Pat::Variant(name, bnames, ppos) => {
                        let vi = match (enum_id, self.cx.variants.get(name.as_str()).copied()) {
                            (Some(eid), Some((ei, vi))) if self.cx.types.enums[eid as usize].decl == ei => vi,
                            _ => {
                                let tn = self.tyname(sv.ty);
                                self.err(*ppos, format!("`{}` is not a variant of {}", name, tn));
                                self.jmp(fail_b);
                                if !last {
                                    self.switch_to(fail_b);
                                }
                                continue;
                            }
                        };
                        covered[vi] = true;
                        let nfields = self.cx.types.enums[enum_id.unwrap() as usize].variants[vi].1.len();
                        if bnames.len() != nfields {
                            self.err(*ppos, format!("variant `{}` has {} field(s), pattern binds {}", name, nfields, bnames.len()));
                        } else if npats > 1 && !bnames.is_empty() {
                            self.err(*ppos, "patterns with bindings cannot be combined with `,`".into());
                        } else {
                            binds = Some((vi, bnames));
                        }
                        let c = self.iconst(T::I64, vi as i64);
                        let eq = self.ins(Op::Eq, T::I8, vec![key, c], 0);
                        self.br(eq, body_b, fail_b);
                    }
                    Pat::Const(pe) => {
                        // payload-less variant name?
                        let mut done = false;
                        if let (EK::Ident(n), Some(eid)) = (&pe.k, enum_id) {
                            if let Some(&(ei, vi)) = self.cx.variants.get(n.as_str()) {
                                if self.cx.types.enums[eid as usize].decl == ei {
                                    covered[vi] = true;
                                    if !self.cx.types.enums[eid as usize].variants[vi].1.is_empty() {
                                        self.err(pe.pos, format!("variant `{}` has fields; write `{}(..)` with bindings", n, n));
                                    }
                                    let c = self.iconst(T::I64, vi as i64);
                                    let eq = self.ins(Op::Eq, T::I8, vec![key, c], 0);
                                    self.br(eq, body_b, fail_b);
                                    done = true;
                                }
                            }
                        }
                        if !done {
                            if payload_enum {
                                self.err(pe.pos, "expected an enum variant pattern".into());
                                self.jmp(fail_b);
                            } else if let Some(st) = str_tmp {
                                let pv = self.expr(pe, Some(T_STR));
                                let pv = self.coerce(pv, T_STR, pe.pos);
                                let r = self.call_rt("__str_eq", vec![], vec![st, pv], pe.pos);
                                let c = self.scalar(r);
                                self.br(c, body_b, fail_b);
                            } else {
                                let pv = self.expr(pe, Some(key_ty));
                                let pv = self.coerce(pv, key_ty, pe.pos);
                                let p = self.scalar(pv);
                                let eq = self.ins(Op::Eq, T::I8, vec![key, p], 0);
                                self.br(eq, body_b, fail_b);
                            }
                        }
                    }
                }
                if !last {
                    self.switch_to(fail_b);
                }
            }
            if npats == 0 {
                self.jmp(next_b);
            }
            self.switch_to(body_b);
            self.push_scope();
            if let Some((vi, bnames)) = binds {
                let eid = enum_id.unwrap();
                let ptys = self.cx.types.enums[eid as usize].variants[vi].1.clone();
                let offs = self.cx.types.variant_offsets(eid, vi);
                for (i, bn) in bnames.iter().enumerate() {
                    let src = self.add_off(sv.v, offs[i] as i64);
                    let tmp = self.load_any(src, ptys[i]);
                    if bn != "_" {
                        self.scopes.last_mut().unwrap().vars.insert(bn.clone(), (ptys[i], tmp.v));
                    }
                }
            }
            let exp = match slot {
                Some(s) => Some(s.ty),
                None => expect,
            };
            let v = self.block_value(&arm.body, want, exp);
            let d = self.dead;
            if want && !d {
                if v.ty == T_ERR {
                    result_err = true;
                } else if v.ty == T_UNIT {
                    if slot.is_some() {
                        self.err(arm.pos, "match arm has no value but other arms do".into());
                    }
                } else {
                    match slot {
                        Some(s) => {
                            let v = self.coerce(v, s.ty, arm.pos);
                            self.store(s, v);
                        }
                        None => {
                            if !all_dead {
                                self.err(arm.pos, "match arms have different types".into());
                            } else {
                                let a = self.temp(v.ty);
                                let s = self.mval(v.ty, a);
                                self.store(s, v);
                                slot = Some(s);
                            }
                        }
                    }
                }
            }
            if !d {
                all_dead = false;
            }
            self.pop_scope();
            self.jmp(bj);
            self.switch_to(next_b);
        }
        // fallthrough when no arm matched
        let exhaustive = has_wild || (enum_id.is_some() && covered.iter().all(|c| *c)) || (sv.ty == T_BOOL && arms.iter().map(|a| a.pats.len()).sum::<usize>() >= 2);
        if exhaustive {
            self.terminate(Term::Trap);
        } else {
            if want && slot.is_some() {
                let missing: Vec<String> = match enum_id {
                    Some(e) => covered
                        .iter()
                        .enumerate()
                        .filter(|(_, c)| !**c)
                        .map(|(i, _)| self.cx.types.enums[e as usize].variants[i].0.clone())
                        .collect(),
                    None => vec![],
                };
                if missing.is_empty() {
                    self.err(pos, "match used as a value must be exhaustive (add a `_ =>` arm)".into());
                } else {
                    self.err(pos, format!("match used as a value must be exhaustive; missing: {}", missing.join(", ")));
                }
            }
            all_dead = false;
            self.jmp(bj);
        }
        self.switch_to(bj);
        self.dead = all_dead;
        if all_dead {
            return Val::never();
        }
        if result_err {
            return Val::err();
        }
        slot.unwrap_or_else(Val::unit)
    }
}
