// Lowering of the built-in f32 vector types: vec2 / vec3 / vec4 / quat (one xmm value each)
// and mat4 (four vec4 columns in memory).
use crate::ast::*;
use crate::ir::*;
use crate::lower_fn::*;
use crate::types::*;

fn lane_of(c: char) -> Option<u8> {
    Some(match c {
        'x' | 'r' => 0,
        'y' | 'g' => 1,
        'z' | 'b' => 2,
        'w' | 'a' => 3,
        _ => return None,
    })
}

impl<'c, 'a> Fx<'c, 'a> {
    pub fn is_vecish(&self, t: Ty) -> bool {
        self.cx.types.vec_lanes(t).is_some() || t == T_MAT4
    }

    // the float type an untyped literal takes in a context expecting `expect`
    pub fn float_expect(&self, expect: Option<Ty>) -> Ty {
        match expect {
            Some(t) if t == T_F32 || self.is_vecish(t) => T_F32,
            _ => T_F64,
        }
    }

    pub fn fconst_ty(&mut self, ty: Ty, f: f64) -> Val {
        if ty == T_F32 {
            let v = self.ins(Op::FConst, T::F32, vec![], (f as f32).to_bits() as i64);
            self.sval(T_F32, v)
        } else {
            let v = self.ins(Op::FConst, T::F64, vec![], f.to_bits() as i64);
            self.sval(T_F64, v)
        }
    }

    fn vec_ty(n: usize) -> Ty {
        match n {
            2 => T_VEC2,
            3 => T_VEC3,
            _ => T_VEC4,
        }
    }

    // like `expr`, but a variable / field / element of scalar type stays a place (not loaded)
    pub fn lvalue_base(&mut self, b: &'a Expr) -> Val {
        match &b.k {
            EK::Ident(n) => {
                if let Some((ty, addr)) = self.lookup(n) {
                    return self.mval(ty, addr);
                }
                if !self.cx.const_decls.contains_key(n.as_str()) {
                    if let Some((ty, gid)) = self.cx.global(n) {
                        let a = self.ins(Op::GAddr, T::I64, vec![], gid as i64);
                        return self.mval(ty, a);
                    }
                }
                self.expr(b, None)
            }
            EK::Field(bb, name) if name != "len" => {
                let x = self.lvalue_base(bb);
                match self.field_of(x, name, b.pos) {
                    Some(p) => p,
                    None => Val::err(),
                }
            }
            EK::Index(bb, idx) if idx.len() == 1 => match self.index_place(bb, &idx[0], b.pos) {
                Some(p) => p,
                None => Val::err(),
            },
            EK::Un(UnOp::Deref, p) => {
                let pv = self.expr(p, None);
                match self.cx.types.k(pv.ty).clone() {
                    TyK::Ptr(t) => {
                        let a = self.scalar(pv);
                        self.mval(t, a)
                    }
                    _ => self.expr(b, None),
                }
            }
            _ => self.expr(b, None),
        }
    }

    // `.x`, `.xyz`, ... on a vector; None when `bv` is not a vector
    pub fn vec_field(&mut self, bv: Val, name: &str, pos: Pos) -> Option<Option<Val>> {
        let mut bv = bv;
        if let TyK::Ptr(t) = self.cx.types.k(bv.ty).clone() {
            if self.cx.types.vec_lanes(t).is_some() {
                let a = self.scalar(bv);
                bv = self.mval(t, a);
            }
        }
        let n = self.cx.types.vec_lanes(bv.ty)?;
        let vt = self.irt(bv.ty);
        let lanes: Option<Vec<u8>> = name.chars().map(lane_of).collect();
        let lanes = match lanes {
            Some(l) if !l.is_empty() && l.len() <= 4 && l.iter().all(|k| (*k as u32) < n) => l,
            _ => {
                let tn = self.tyname(bv.ty);
                self.err(pos, format!("{} has no component `{}` (components: {}; swizzles like `.xy` or `.zyx` are allowed)", tn, name, &"xyzw"[..n as usize]));
                return Some(None);
            }
        };
        if lanes.len() == 1 {
            if bv.lane.is_some() {
                return Some(None);
            }
            if bv.mem {
                return Some(Some(Val { ty: T_F32, v: bv.v, mem: true, alias: bv.alias, lane: Some((lanes[0], vt)) }));
            }
            let x = self.ins(Op::VExt, T::F32, vec![bv.v], lanes[0] as i64);
            return Some(Some(self.sval(T_F32, x)));
        }
        let x = self.scalar(bv);
        let mut imm = 0i64;
        for (i, l) in lanes.iter().enumerate() {
            imm |= (*l as i64) << (2 * i);
        }
        let rt = Self::vec_ty(lanes.len());
        let it = self.irt(rt);
        let r = self.ins(Op::VShuf, it, vec![x, x], imm);
        Some(Some(self.sval(rt, r)))
    }

    // v[i] on a vector: a lane place for constant i, an f32 in memory otherwise
    pub fn vec_index(&mut self, bv: Val, idx: &'a Expr, pos: Pos) -> Option<Val> {
        let n = self.cx.types.vec_lanes(bv.ty)? as i64;
        let vt = self.irt(bv.ty);
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
        if let Some(k) = self.f.is_const(i) {
            if k < 0 || k >= n {
                self.err(idx.pos, format!("index {} is out of bounds for length {}", k, n));
                return None;
            }
            if bv.mem && bv.lane.is_none() {
                return Some(Val { ty: T_F32, v: bv.v, mem: true, alias: bv.alias, lane: Some((k as u8, vt)) });
            }
            let x = self.scalar(bv);
            let r = self.ins(Op::VExt, T::F32, vec![x], k);
            return Some(self.sval(T_F32, r));
        }
        if self.cx.opts.checks {
            let len = self.iconst(T::I64, n);
            let c = self.ins(Op::Ult, T::I8, vec![i, len], 0);
            self.check(c, 0, pos);
        }
        // a run-time lane: go through memory
        let base = if bv.mem && bv.lane.is_none() {
            bv.v
        } else {
            let t = self.temp(bv.ty);
            let tv = self.mval(bv.ty, t);
            self.store(tv, bv);
            t
        };
        let four = self.iconst(T::I64, 4);
        let off = self.ins(Op::Mul, T::I64, vec![i, four], 0);
        let a = self.ins(Op::Add, T::I64, vec![base, off], 0);
        let mut p = self.mval(T_F32, a);
        p.alias = AK_ANY;
        Some(p)
    }

    fn vec_eq(&mut self, l: Val, r: Val, n: u32) -> V {
        let (x, y) = (self.scalar(l), self.scalar(r));
        let mut acc = NOV;
        for k in 0..n {
            let a = self.ins(Op::VExt, T::F32, vec![x], k as i64);
            let b = self.ins(Op::VExt, T::F32, vec![y], k as i64);
            let e = self.ins(Op::FEq, T::I8, vec![a, b], 0);
            acc = if acc == NOV { e } else { self.ins(Op::And, T::I8, vec![acc, e], 0) };
        }
        acc
    }

    // binary operators with a vector, quaternion or matrix operand; None for other types
    pub fn vec_binary(&mut self, op: BinOp, l: Val, r: Val, pos: Pos) -> Option<Val> {
        let ln = self.cx.types.vec_lanes(l.ty);
        let rn = self.cx.types.vec_lanes(r.ty);
        if ln.is_none() && rn.is_none() && l.ty != T_MAT4 && r.ty != T_MAT4 {
            return None;
        }
        let bad = |s: &mut Self| {
            let (a, b) = (s.tyname(l.ty), s.tyname(r.ty));
            s.err(pos, format!("this operator is not defined for {} and {}", a, b));
            Some(Val::err())
        };
        let eq = matches!(op, BinOp::Eq | BinOp::Ne);
        if l.ty == T_MAT4 || r.ty == T_MAT4 {
            return match (op, l.ty, r.ty) {
                (BinOp::Mul, T_MAT4, T_MAT4) => Some(self.call_rt("__mat4_mul", vec![], vec![l, r], pos)),
                (BinOp::Mul, T_MAT4, T_VEC4) => Some(self.call_rt("__mat4_mulv", vec![], vec![l, r], pos)),
                (_, T_MAT4, T_MAT4) if eq => {
                    let mut acc = NOV;
                    for c in 0..4 {
                        let (a, b) = (self.add_off(l.v, 16 * c), self.add_off(r.v, 16 * c));
                        let (x, y) = (self.mval(T_VEC4, a), self.mval(T_VEC4, b));
                        let e = self.vec_eq(x, y, 4);
                        acc = if acc == NOV { e } else { self.ins(Op::And, T::I8, vec![acc, e], 0) };
                    }
                    if op == BinOp::Ne {
                        let one = self.iconst(T::I8, 1);
                        acc = self.ins(Op::Xor, T::I8, vec![acc, one], 0);
                    }
                    Some(self.sval(T_BOOL, acc))
                }
                _ => bad(self),
            };
        }
        if op == BinOp::Mul && l.ty == T_QUAT && r.ty == T_QUAT {
            return Some(self.call_rt("__quat_mul", vec![], vec![l, r], pos));
        }
        if op == BinOp::Mul && l.ty == T_QUAT && r.ty == T_VEC3 {
            return Some(self.call_rt("__quat_rotate", vec![], vec![l, r], pos));
        }
        if eq {
            if l.ty != r.ty {
                return bad(self);
            }
            let mut e = self.vec_eq(l, r, ln.unwrap());
            if op == BinOp::Ne {
                let one = self.iconst(T::I8, 1);
                e = self.ins(Op::Xor, T::I8, vec![e, one], 0);
            }
            return Some(self.sval(T_BOOL, e));
        }
        let o = match op {
            BinOp::Add => Op::FAdd,
            BinOp::Sub => Op::FSub,
            BinOp::Mul => Op::FMul,
            BinOp::Div => Op::FDiv,
            _ => return bad(self),
        };
        // vector op vector, vector op f32, f32 op vector
        let (ty, a, b) = if l.ty == r.ty {
            (l.ty, self.scalar(l), self.scalar(r))
        } else if ln.is_some() && r.ty == T_F32 {
            let it = self.irt(l.ty);
            let a = self.scalar(l);
            let s = self.scalar(r);
            (l.ty, a, self.ins(Op::VSplat, it, vec![s], 0))
        } else if rn.is_some() && l.ty == T_F32 {
            let it = self.irt(r.ty);
            let s = self.scalar(l);
            let a = self.ins(Op::VSplat, it, vec![s], 0);
            (r.ty, a, self.scalar(r))
        } else {
            let (x, y) = (self.tyname(l.ty), self.tyname(r.ty));
            self.err(pos, format!("operands have different types: {} and {} (vectors combine with the same vector type or with f32)", x, y));
            return Some(Val::err());
        };
        let it = self.irt(ty);
        let v = self.ins(o, it, vec![a, b], 0);
        Some(self.sval(ty, v))
    }

    // vec2(..) / vec3(..) / vec4(..) / quat(..) / mat4(..)
    pub fn vec_construct(&mut self, to: Ty, args: &'a [Expr], pos: Pos) -> Val {
        let tn = self.tyname(to);
        let mut vals = Vec::new();
        for a in args {
            let v = self.expr(a, Some(T_F32));
            if v.ty == T_ERR {
                return Val::err();
            }
            vals.push((v, a.pos));
        }
        if to == T_MAT4 {
            if vals.len() == 1 && vals[0].0.ty == T_MAT4 {
                return vals[0].0;
            }
            if vals.len() == 1 && vals[0].0.ty == T_F32 {
                return self.call_rt("__mat4_diag", vec![], vec![vals[0].0], pos);
            }
            if vals.len() != 4 || vals.iter().any(|v| v.0.ty != T_VEC4) {
                self.err(pos, "mat4(...) takes four vec4 columns, or one f32 for a diagonal matrix".into());
                return Val::err();
            }
            let cols: Vec<V> = vals.iter().map(|v| self.scalar(v.0)).collect();
            let t = self.temp(T_MAT4);
            for (c, x) in cols.into_iter().enumerate() {
                let a = self.add_off(t, 16 * c as i64);
                self.store_raw(a, x, T::V4, AK_VEC);
            }
            return self.mval(T_MAT4, t);
        }
        let n = self.cx.types.vec_lanes(to).unwrap() as usize;
        let it = self.irt(to);
        if vals.len() == 1 {
            let (v, _) = vals[0];
            if v.ty == to {
                return v;
            }
            if v.ty == T_F32 {
                let s = self.scalar(v);
                let r = self.ins(Op::VSplat, it, vec![s], 0);
                return self.sval(to, r);
            }
            if let Some(m) = self.cx.types.vec_lanes(v.ty) {
                if m as usize >= n {
                    // drop trailing lanes (or reinterpret vec4 <-> quat)
                    let x = self.scalar(v);
                    let r = self.ins(Op::VShuf, it, vec![x, x], 0xE4);
                    return self.sval(to, r);
                }
            }
        }
        let mut lanes: Vec<V> = Vec::new();
        for (v, apos) in &vals {
            if v.ty == T_F32 {
                lanes.push(self.scalar(*v));
            } else if let Some(m) = self.cx.types.vec_lanes(v.ty) {
                let x = self.scalar(*v);
                for k in 0..m {
                    lanes.push(self.ins(Op::VExt, T::F32, vec![x], k as i64));
                }
            } else {
                let an = self.tyname(v.ty);
                self.err(*apos, format!("{}(...) takes f32 components or smaller vectors, found {} (convert with `f32(x)`)", tn, an));
                return Val::err();
            }
        }
        if lanes.len() != n {
            self.err(pos, format!("{}(...) needs {} components (or a single f32 for all of them), got {}", tn, n, lanes.len()));
            return Val::err();
        }
        let r = self.ins(Op::VBuild, it, lanes, 0);
        self.sval(to, r)
    }

    // print a vector / matrix
    pub fn put_vec(&mut self, v: Val, pos: Pos) {
        if v.ty == T_MAT4 {
            self.put_lit_pub("mat4(", pos);
            for c in 0..4 {
                if c > 0 {
                    self.put_lit_pub(", ", pos);
                }
                let a = self.add_off(v.v, 16 * c);
                let col = self.mval(T_VEC4, a);
                self.put_vec(col, pos);
            }
            self.put_lit_pub(")", pos);
            return;
        }
        let n = self.cx.types.vec_lanes(v.ty).unwrap();
        let tn = self.tyname(v.ty);
        let x = self.scalar(v);
        self.put_lit_pub(&format!("{}(", tn), pos);
        for k in 0..n {
            if k > 0 {
                self.put_lit_pub(", ", pos);
            }
            let l = self.ins(Op::VExt, T::F32, vec![x], k as i64);
            let lv = self.sval(T_F32, l);
            self.call_rt("__put_f32", vec![], vec![lv], pos);
        }
        self.put_lit_pub(")", pos);
    }
}
