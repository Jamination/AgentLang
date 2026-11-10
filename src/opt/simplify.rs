// Constant folding, algebraic simplification, strength reduction and CFG simplification.
use super::cleanup;
use crate::ir::*;

fn mask(bits: u32) -> u64 {
    if bits >= 64 {
        u64::MAX
    } else {
        (1u64 << bits) - 1
    }
}

pub fn fold_bin(op: Op, ty: T, a: i64, b: i64) -> Option<i64> {
    let bits = ty.bits();
    let m = mask(bits);
    let (ua, ub) = (a as u64 & m, b as u64 & m);
    let sh = (b as u64 & (bits as u64 - 1)) as u32;
    let r = match op {
        Op::Add => a.wrapping_add(b),
        Op::Sub => a.wrapping_sub(b),
        Op::Mul => a.wrapping_mul(b),
        Op::SDiv => {
            if b == 0 {
                return None;
            }
            a.wrapping_div(b)
        }
        Op::SRem => {
            if b == 0 {
                return None;
            }
            a.wrapping_rem(b)
        }
        Op::UDiv => {
            if ub == 0 {
                return None;
            }
            (ua / ub) as i64
        }
        Op::URem => {
            if ub == 0 {
                return None;
            }
            (ua % ub) as i64
        }
        Op::And => a & b,
        Op::Or => a | b,
        Op::Xor => a ^ b,
        Op::Shl => ((ua << sh) & m) as i64,
        Op::LShr => (ua >> sh) as i64,
        Op::AShr => a >> sh,
        Op::Rotl => {
            if sh == 0 {
                a
            } else {
                (((ua << sh) | (ua >> (bits - sh))) & m) as i64
            }
        }
        Op::Rotr => {
            if sh == 0 {
                a
            } else {
                (((ua >> sh) | (ua << (bits - sh))) & m) as i64
            }
        }
        Op::MulHiS => (((a as i128) * (b as i128)) >> bits) as i64,
        Op::MulHiU => (((ua as u128) * (ub as u128)) >> bits) as i64,
        _ => return None,
    };
    Some(canon(ty, r))
}

pub fn fold_icmp(op: Op, ty: T, a: i64, b: i64) -> Option<bool> {
    let m = mask(ty.bits());
    let (ua, ub) = (a as u64 & m, b as u64 & m);
    Some(match op {
        Op::Eq => a == b,
        Op::Ne => a != b,
        Op::Slt => a < b,
        Op::Sle => a <= b,
        Op::Sgt => a > b,
        Op::Sge => a >= b,
        Op::Ult => ua < ub,
        Op::Ule => ua <= ub,
        Op::Ugt => ua > ub,
        Op::Uge => ua >= ub,
        _ => return None,
    })
}

struct Ctx<'a> {
    f: &'a mut Func,
    new: Vec<V>,
    changed: bool,
    uses: Vec<u32>,
}

impl<'a> Ctx<'a> {
    fn c(&self, v: V) -> Option<i64> {
        self.f.is_const(v)
    }
    // scalar float constants only (vector constants are never folded)
    fn fc(&self, v: V) -> Option<f64> {
        let i = &self.f.insts[v as usize];
        if i.op == Op::FConst && i.ty == T::F64 {
            Some(f64::from_bits(i.k as u64))
        } else if i.op == Op::FConst && i.ty == T::F32 {
            Some(f32::from_bits(i.k as u32) as f64)
        } else {
            None
        }
    }
    // bits of the constant r in type ty; f32 results are computed in f64 and rounded once,
    // which is exact for + - * / sqrt
    fn fbits(ty: T, r: f64) -> i64 {
        if ty == T::F32 {
            (r as f32).to_bits() as i64
        } else {
            r.to_bits() as i64
        }
    }
    fn konst(&mut self, ty: T, k: i64) -> V {
        let v = self.f.mk(Op::Const, ty, vec![], canon(ty, k));
        self.new.push(v);
        v
    }
    fn mk(&mut self, op: Op, ty: T, args: Vec<V>) -> V {
        let v = self.f.mk(op, ty, args, 0);
        self.new.push(v);
        v
    }
    // rewrite v in place
    fn set(&mut self, v: V, op: Op, args: Vec<V>, k: i64) {
        let i = self.f.im(v);
        i.op = op;
        i.args = args;
        i.k = k;
        i.pb.clear();
        self.changed = true;
    }
    fn set_const(&mut self, v: V, k: i64) {
        let ty = self.f.insts[v as usize].ty;
        self.set(v, Op::Const, vec![], canon(ty, k));
    }
    fn op(&self, v: V) -> Op {
        self.f.insts[v as usize].op
    }

    // returns Some(w) when v should be replaced by the existing value w
    fn simplify(&mut self, v: V) -> Option<V> {
        let inst = self.f.insts[v as usize].clone();
        let ty = inst.ty;
        let op = inst.op;
        use Op::*;
        match op {
            Add | Sub | Mul | SDiv | UDiv | SRem | URem | And | Or | Xor | Shl | LShr | AShr | Rotl | Rotr | MulHiS | MulHiU => {
                let (mut a, mut b) = (inst.args[0], inst.args[1]);
                if let (Some(x), Some(y)) = (self.c(a), self.c(b)) {
                    if let Some(r) = fold_bin(op, ty, x, y) {
                        self.set_const(v, r);
                        return None;
                    }
                }
                if op.is_commutative() && self.c(a).is_some() && self.c(b).is_none() {
                    std::mem::swap(&mut a, &mut b);
                    self.f.im(v).args = vec![a, b];
                    self.changed = true;
                }
                let cb = self.c(b);
                let bits = ty.bits() as i64;
                match (op, cb) {
                    (Add | Sub | Or | Xor | Shl | LShr | AShr | Rotl | Rotr, Some(0)) => return Some(a),
                    (Shl | LShr | AShr | Rotl | Rotr, Some(k)) if k & (bits - 1) == 0 => return Some(a),
                    (Mul | SDiv | UDiv, Some(1)) => return Some(a),
                    (Mul | And, Some(0)) => {
                        self.set_const(v, 0);
                        return None;
                    }
                    (SRem | URem, Some(1)) => {
                        self.set_const(v, 0);
                        return None;
                    }
                    (Xor, Some(1)) if ty == T::I8 && self.op(a).is_cmp() => {
                        let ai = self.f.insts[a as usize].clone();
                        if ai.op.is_icmp() {
                            self.set(v, ai.op.negate_icmp(), ai.args, 0);
                            return None;
                        }
                        if ai.op == FEq || ai.op == FNe {
                            self.set(v, if ai.op == FEq { FNe } else { FEq }, ai.args, 0);
                            return None;
                        }
                    }
                    (And, Some(-1)) => return Some(a),
                    (Or, Some(-1)) => {
                        self.set_const(v, -1);
                        return None;
                    }
                    (Sub, Some(k)) => {
                        let nk = self.konst(ty, k.wrapping_neg());
                        self.set(v, Add, vec![a, nk], 0);
                        return None;
                    }
                    (Mul, Some(k)) if k > 0 && (k as u64).is_power_of_two() => {
                        let s = self.konst(ty, (k as u64).trailing_zeros() as i64);
                        self.set(v, Shl, vec![a, s], 0);
                        return None;
                    }
                    (Mul, Some(-1)) => {
                        let z = self.konst(ty, 0);
                        self.set(v, Sub, vec![z, a], 0);
                        return None;
                    }
                    (UDiv, Some(k)) => {
                        let uk = k as u64 & mask(ty.bits());
                        if uk.is_power_of_two() {
                            let s = self.konst(ty, uk.trailing_zeros() as i64);
                            self.set(v, LShr, vec![a, s], 0);
                            return None;
                        }
                        if ty == T::I64 || ty == T::I32 {
                            let q = self.udiv_magic(a, ty, uk);
                            return Some(q);
                        }
                    }
                    (URem, Some(k)) => {
                        let uk = k as u64 & mask(ty.bits());
                        if uk.is_power_of_two() {
                            let m = self.konst(ty, (uk - 1) as i64);
                            self.set(v, And, vec![a, m], 0);
                            return None;
                        }
                        if ty == T::I64 || ty == T::I32 {
                            let q = self.udiv_magic(a, ty, uk);
                            let d = self.konst(ty, k);
                            let p = self.mk(Mul, ty, vec![q, d]);
                            self.set(v, Sub, vec![a, p], 0);
                            return None;
                        }
                    }
                    (SDiv | SRem, Some(k)) if k != 0 && k != -1 && (ty == T::I64 || ty == T::I32) && k != i64::MIN && !(ty == T::I32 && k == i32::MIN as i64) => {
                        let q = if (k.unsigned_abs()).is_power_of_two() {
                            // (a + ((a >> bits-1) >>> (bits - s))) >> s, negated for negative divisors
                            let s = k.unsigned_abs().trailing_zeros() as i64;
                            let c1 = self.konst(ty, bits - 1);
                            let sign = self.mk(AShr, ty, vec![a, c1]);
                            let c2 = self.konst(ty, bits - s);
                            let bias = self.mk(LShr, ty, vec![sign, c2]);
                            let sum = self.mk(Add, ty, vec![a, bias]);
                            let c3 = self.konst(ty, s);
                            let q = self.mk(AShr, ty, vec![sum, c3]);
                            if k < 0 {
                                let z = self.konst(ty, 0);
                                self.mk(Sub, ty, vec![z, q])
                            } else {
                                q
                            }
                        } else {
                            self.sdiv_magic(a, ty, k)
                        };
                        if op == SDiv {
                            return Some(q);
                        }
                        let d = self.konst(ty, k);
                        let p = self.mk(Mul, ty, vec![q, d]);
                        self.set(v, Sub, vec![a, p], 0);
                        return None;
                    }
                    _ => {}
                }
                if a == b {
                    match op {
                        Sub | Xor => {
                            self.set_const(v, 0);
                            return None;
                        }
                        And | Or => return Some(a),
                        _ => {}
                    }
                }
                // (x op c1) op c2 for associative ops
                if let Some(k2) = cb {
                    let ai = &self.f.insts[a as usize];
                    if ai.op == op && matches!(op, Add | Mul | And | Or | Xor) {
                        if let Some(k1) = self.c(ai.args[1]) {
                            let x = ai.args[0];
                            let k = fold_bin(op, ty, k1, k2).unwrap();
                            let kc = self.konst(ty, k);
                            self.set(v, op, vec![x, kc], 0);
                            return None;
                        }
                    }
                    // (x << c1) << c2, (x >>> c1) >>> c2
                    if ai.op == op && matches!(op, Shl | LShr) {
                        if let Some(k1) = self.c(ai.args[1]) {
                            let (s1, s2) = (k1 & (bits - 1), k2 & (bits - 1));
                            let x = ai.args[0];
                            if s1 + s2 >= bits {
                                self.set_const(v, 0);
                            } else {
                                let kc = self.konst(ty, s1 + s2);
                                self.set(v, op, vec![x, kc], 0);
                            }
                            return None;
                        }
                    }
                }
                // (x + c1) << c2  =>  (x << c2) + (c1 << c2) ; (x + c1) * c2  =>  x * c2 + c1 * c2
                if let Some(k2) = cb {
                    let ai = self.f.insts[a as usize].clone();
                    if matches!(op, Shl | Mul) && ai.op == Add {
                        let small = |k: i64| k >= i32::MIN as i64 && k <= i32::MAX as i64;
                        let prod = self.c(ai.args[1]).and_then(|k1| fold_bin(op, ty, k1, k2));
                        if let (Some(k1), true) = (self.c(ai.args[1]), prod.map(small).unwrap_or(false)) {
                            let x = ai.args[0];
                            let inner = self.mk(op, ty, vec![x, b]);
                            let kc = self.konst(ty, fold_bin(op, ty, k1, k2).unwrap());
                            self.set(v, Add, vec![inner, kc], 0);
                            return None;
                        }
                    }
                }
                if op == Xor || op == Or {
                    let (ai, bi) = (self.f.insts[a as usize].clone(), self.f.insts[b as usize].clone());
                    if ai.op == And && bi.op == And && self.uses.get(a as usize).copied().unwrap_or(2) == 1 && self.uses.get(b as usize).copied().unwrap_or(2) == 1 {
                        // bit select: (x & y) ^ (~x & z)  =>  z ^ (x & (y ^ z))
                        let is_not = |s: &Self, n: V, x: V| -> bool {
                            let ni = &s.f.insts[n as usize];
                            ni.op == Xor && s.c(ni.args[1]) == Some(-1) && ni.args[0] == x
                        };
                        let mut sel: Option<(V, V, V)> = None;
                        for (p, q) in [(&ai, &bi), (&bi, &ai)] {
                            for pi in 0..2 {
                                for qi in 0..2 {
                                    if sel.is_none() && is_not(self, q.args[qi], p.args[pi]) {
                                        sel = Some((p.args[pi], p.args[1 - pi], q.args[1 - qi]));
                                    }
                                }
                            }
                        }
                        if let Some((x, y, z)) = sel {
                            let yz = self.mk(Xor, ty, vec![y, z]);
                            let m = self.mk(And, ty, vec![x, yz]);
                            self.set(v, Xor, vec![z, m], 0);
                            return None;
                        }
                        // (x & y) ^ (x & z)  =>  x & (y ^ z)
                        if op == Xor {
                            for pi in 0..2 {
                                for qi in 0..2 {
                                    if ai.args[pi] == bi.args[qi] {
                                        let x = ai.args[pi];
                                        let yz = self.mk(Xor, ty, vec![ai.args[1 - pi], bi.args[1 - qi]]);
                                        self.set(v, And, vec![x, yz], 0);
                                        return None;
                                    }
                                }
                            }
                        }
                    }
                }
                // rotate idioms: (x >>> n) | (x << (bits - n))
                if op == Or || op == Xor || op == Add {
                    if let Some(r) = self.match_rotate(a, b, ty) {
                        self.set(v, r.0, vec![r.1, r.2], 0);
                        return None;
                    }
                }
                // x + (0 - y) => x - y
                if op == Add {
                    let bi = &self.f.insts[b as usize];
                    if bi.op == Sub && self.c(bi.args[0]) == Some(0) {
                        let y = bi.args[1];
                        self.set(v, Sub, vec![a, y], 0);
                        return None;
                    }
                }
                None
            }
            FAdd | FSub | FMul | FDiv => {
                if let (Some(x), Some(y)) = (self.fc(inst.args[0]), self.fc(inst.args[1])) {
                    let r = match op {
                        FAdd => x + y,
                        FSub => x - y,
                        FMul => x * y,
                        _ => x / y,
                    };
                    self.set(v, FConst, vec![], Self::fbits(ty, r));
                }
                None
            }
            FNeg | FAbs | FSqrt => {
                if let Some(x) = self.fc(inst.args[0]) {
                    let r = match op {
                        FNeg => -x,
                        FAbs => x.abs(),
                        _ => x.sqrt(),
                    };
                    self.set(v, FConst, vec![], Self::fbits(ty, r));
                }
                None
            }
            Eq | Ne | Slt | Sle | Sgt | Sge | Ult | Ule | Ugt | Uge => {
                let (mut a, mut b) = (inst.args[0], inst.args[1]);
                let at = self.f.insts[a as usize].ty;
                if let (Some(x), Some(y)) = (self.c(a), self.c(b)) {
                    let r = fold_icmp(op, at, x, y).unwrap();
                    self.set_const(v, r as i64);
                    return None;
                }
                let mut op = op;
                if self.c(a).is_some() {
                    std::mem::swap(&mut a, &mut b);
                    op = op.swap_cmp();
                    let i = self.f.im(v);
                    i.op = op;
                    i.args = vec![a, b];
                    self.changed = true;
                }
                if a == b {
                    let r = matches!(op, Eq | Sle | Sge | Ule | Uge);
                    self.set_const(v, r as i64);
                    return None;
                }
                // (x & (len - 1)) <u len  is true exactly when len != 0
                if op == Ult || op == Ugt {
                    let (idx, len) = if op == Ult { (a, b) } else { (b, a) };
                    if self.masked_by(idx, len, 4, idx) {
                        let z = self.konst(at, 0);
                        self.set(v, Ne, vec![len, z], 0);
                        return None;
                    }
                }
                // comparisons of booleans with constants
                if let Some(k) = self.c(b) {
                    let ai = self.f.insts[a as usize].clone();
                    if matches!(op, Eq | Ne) && at == T::I8 && ai.op.is_cmp() {
                        let truth = (op == Ne) == (k == 0);
                        // (cmp != 0) or (cmp == 1) => cmp ; (cmp == 0) or (cmp != 1) => !cmp
                        if k == 0 || k == 1 {
                            if truth {
                                return Some(a);
                            }
                            if ai.op.is_icmp() {
                                self.set(v, ai.op.negate_icmp(), ai.args.clone(), 0);
                                return None;
                            }
                            if ai.op == FEq || ai.op == FNe {
                                self.set(v, if ai.op == FEq { FNe } else { FEq }, ai.args.clone(), 0);
                                return None;
                            }
                        }
                    }
                    // unsigned x < 0 is false, x >= 0 is true
                    if k == 0 && op == Ult {
                        self.set_const(v, 0);
                        return None;
                    }
                    if k == 0 && op == Uge {
                        self.set_const(v, 1);
                        return None;
                    }
                    // (x + c1) == c2  =>  x == c2 - c1
                    if matches!(op, Eq | Ne) && ai.op == Add {
                        if let Some(k1) = self.c(ai.args[1]) {
                            let nk = self.konst(at, k.wrapping_sub(k1));
                            self.set(v, op, vec![ai.args[0], nk], 0);
                            return None;
                        }
                    }
                }
                None
            }
            FEq | FNe | FLt | FLe | FGt | FGe => {
                if let (Some(x), Some(y)) = (self.fc(inst.args[0]), self.fc(inst.args[1])) {
                    let r = match op {
                        FEq => x == y,
                        FNe => x != y,
                        FLt => x < y,
                        FLe => x <= y,
                        FGt => x > y,
                        _ => x >= y,
                    };
                    self.set_const(v, r as i64);
                }
                None
            }
            SExt | ZExt | Trunc => {
                let a = inst.args[0];
                let at = self.f.insts[a as usize].ty;
                if at == ty {
                    return Some(a);
                }
                if let Some(x) = self.c(a) {
                    let r = match op {
                        SExt => x,
                        ZExt => (x as u64 & mask(at.bits())) as i64,
                        _ => x,
                    };
                    self.set_const(v, r);
                    return None;
                }
                let ai = self.f.insts[a as usize].clone();
                match (op, ai.op) {
                    (SExt, SExt) | (ZExt, ZExt) => {
                        self.set(v, op, vec![ai.args[0]], 0);
                    }
                    (SExt, ZExt) => {
                        // zero-extended value is non-negative
                        self.set(v, ZExt, vec![ai.args[0]], 0);
                    }
                    (Trunc, SExt) | (Trunc, ZExt) | (Trunc, Trunc) => {
                        let src = ai.args[0];
                        let st = self.f.insts[src as usize].ty;
                        if st == ty {
                            return Some(src);
                        }
                        if ai.op == Trunc || st.bits() > ty.bits() {
                            self.set(v, Trunc, vec![src], 0);
                        } else {
                            self.set(v, ai.op, vec![src], 0);
                        }
                    }
                    _ => {}
                }
                None
            }
            SIToF => {
                if let Some(x) = self.c(inst.args[0]) {
                    let bits = if ty == T::F32 { (x as f32).to_bits() as i64 } else { (x as f64).to_bits() as i64 };
                    self.set(v, FConst, vec![], bits);
                }
                None
            }
            FToSI => {
                if let Some(x) = self.fc(inst.args[0]) {
                    if x.is_finite() && x.abs() < 9.0e18 && (ty == T::I64 || x.abs() < 2.0e9) {
                        self.set_const(v, x as i64);
                    }
                }
                None
            }
            BitsToF => {
                if let Some(x) = self.c(inst.args[0]) {
                    self.set(v, FConst, vec![], if ty == T::F32 { x & 0xFFFF_FFFF } else { x });
                }
                None
            }
            FToBits => {
                let i = &self.f.insts[inst.args[0] as usize];
                if i.op == FConst {
                    let k = i.k;
                    self.set_const(v, k);
                }
                None
            }
            FExt | FTrunc => {
                if let Some(x) = self.fc(inst.args[0]) {
                    self.set(v, FConst, vec![], Self::fbits(ty, x));
                }
                None
            }
            Select => {
                let (c, a, b) = (inst.args[0], inst.args[1], inst.args[2]);
                if a == b {
                    return Some(a);
                }
                if let Some(k) = self.c(c) {
                    return Some(if k != 0 { a } else { b });
                }
                None
            }
            Phi => None,
            _ => None,
        }
    }

    // is v always of the form (x & (len - 1)), directly or through phis?
    fn masked_by(&self, v: V, len: V, depth: u32, root: V) -> bool {
        let i = &self.f.insts[v as usize];
        match i.op {
            Op::And => {
                let is_len_m1 = |m: V| -> bool {
                    let mi = &self.f.insts[m as usize];
                    mi.op == Op::Add && mi.args[0] == len && self.c(mi.args[1]) == Some(-1)
                };
                is_len_m1(i.args[0]) || is_len_m1(i.args[1])
            }
            Op::Phi if depth > 0 && !i.args.is_empty() => i.args.iter().all(|a| *a == root || *a == v || self.masked_by(*a, len, depth - 1, root)),
            _ => false,
        }
    }

    // upper bound on the number of significant bits of an unsigned value
    fn ubits(&self, v: V, depth: u32) -> u32 {
        let i = &self.f.insts[v as usize];
        let tb = i.ty.bits().max(1);
        if depth == 0 {
            return tb;
        }
        let r = match i.op {
            Op::Const => 64 - (i.k as u64 & mask(tb)).leading_zeros(),
            Op::LShr => match self.c(i.args[1]) {
                Some(k) => self.ubits(i.args[0], depth - 1).saturating_sub((k & (tb as i64 - 1)) as u32),
                None => tb,
            },
            Op::And => self.ubits(i.args[0], depth - 1).min(self.ubits(i.args[1], depth - 1)),
            Op::ZExt => self.ubits(i.args[0], depth - 1).min(self.f.insts[i.args[0] as usize].ty.bits()),
            Op::URem => match self.c(i.args[1]) {
                Some(k) => 64 - (k as u64 & mask(tb)).leading_zeros(),
                None => tb,
            },
            Op::UDiv => match self.c(i.args[1]) {
                Some(k) if k > 0 => self.ubits(i.args[0], depth - 1).saturating_sub(63 - (k as u64).leading_zeros()),
                _ => tb,
            },
            op if op.is_cmp() => 1,
            _ => tb,
        };
        r.min(tb)
    }

    fn match_rotate(&mut self, a: V, b: V, ty: T) -> Option<(Op, V, V)> {
        let bits = ty.bits() as i64;
        let (ai, bi) = (self.f.insts[a as usize].clone(), self.f.insts[b as usize].clone());
        let (shr, shl) = match (ai.op, bi.op) {
            (Op::LShr, Op::Shl) => (ai, bi),
            (Op::Shl, Op::LShr) => (bi, ai),
            _ => return None,
        };
        if shr.args[0] != shl.args[0] {
            return None;
        }
        let x = shr.args[0];
        let (nr, nl) = (shr.args[1], shl.args[1]);
        if let (Some(kr), Some(kl)) = (self.c(nr), self.c(nl)) {
            let (kr, kl) = (kr & (bits - 1), kl & (bits - 1));
            if kr + kl == bits && kr != 0 {
                return Some((Op::Rotr, x, nr));
            }
            return None;
        }
        // variable amounts: (x >>> n) | (x << (bits - n))  or  (x << n) | (x >>> (bits - n))
        let is_complement = |s: &Self, m: V, n: V| -> bool {
            let mi = &s.f.insts[m as usize];
            mi.op == Op::Sub && mi.args[1] == n && s.c(mi.args[0]).map(|k| k & (bits - 1) == 0).unwrap_or(false)
        };
        if is_complement(self, nl, nr) {
            return Some((Op::Rotr, x, nr));
        }
        if is_complement(self, nr, nl) {
            return Some((Op::Rotl, x, nl));
        }
        None
    }

    // unsigned division by a constant (Hacker's Delight, magicu)
    fn udiv_magic(&mut self, n: V, ty: T, d: u64) -> V {
        let w = ty.bits();
        // a dividend known to be narrow needs only one multiplication and one shift
        let nb = self.ubits(n, 6);
        if ty == T::I64 && nb < 64 && nb > 0 {
            if nb < 64 && (d as u128) >= (1u128 << nb) {
                return self.konst(ty, 0);
            }
            for sh in nb..64 {
                let two_s: u128 = 1u128 << sh;
                let m = (two_s + d as u128 - 1) / d as u128;
                let e = m * d as u128 - two_s;
                if (e << nb) <= two_s && m < (1u128 << (64 - nb)) {
                    let mc = self.konst(ty, m as u64 as i64);
                    let t = self.mk(Op::Mul, ty, vec![n, mc]);
                    let sc = self.konst(ty, sh as i64);
                    return self.mk(Op::LShr, ty, vec![t, sc]);
                }
            }
        }
        let two_w1: u128 = 1u128 << (w - 1);
        let wmask: u128 = (1u128 << w) - 1;
        let d128 = d as u128;
        let nc: u128 = wmask - ((1u128 << w) - d128) % d128;
        let mut p = w - 1;
        let mut q1 = two_w1 / nc;
        let mut r1 = two_w1 - q1 * nc;
        let mut q2 = (two_w1 - 1) / d128;
        let mut r2 = (two_w1 - 1) - q2 * d128;
        let mut add = false;
        loop {
            p += 1;
            if r1 >= nc - r1 {
                q1 = (2 * q1 + 1) & wmask;
                r1 = 2 * r1 - nc;
            } else {
                q1 = (2 * q1) & wmask;
                r1 *= 2;
            }
            if r2 + 1 >= d128 - r2 {
                if q2 >= two_w1 - 1 {
                    add = true;
                }
                q2 = (2 * q2 + 1) & wmask;
                r2 = 2 * r2 + 1 - d128;
            } else {
                if q2 >= two_w1 {
                    add = true;
                }
                q2 = (2 * q2) & wmask;
                r2 = 2 * r2 + 1;
            }
            let delta = d128 - 1 - r2;
            if !(p < 2 * w && (q1 < delta || (q1 == delta && r1 == 0))) {
                break;
            }
        }
        let m = ((q2 + 1) & wmask) as u64;
        let s = (p - w) as i64;
        let mc = self.konst(ty, m as i64);
        let t = self.mk(Op::MulHiU, ty, vec![n, mc]);
        if !add {
            if s == 0 {
                return t;
            }
            let sc = self.konst(ty, s);
            self.mk(Op::LShr, ty, vec![t, sc])
        } else {
            let diff = self.mk(Op::Sub, ty, vec![n, t]);
            let one = self.konst(ty, 1);
            let half = self.mk(Op::LShr, ty, vec![diff, one]);
            let sum = self.mk(Op::Add, ty, vec![half, t]);
            if s - 1 == 0 {
                return sum;
            }
            let sc = self.konst(ty, s - 1);
            self.mk(Op::LShr, ty, vec![sum, sc])
        }
    }

    // signed division by a constant (Hacker's Delight, magic)
    fn sdiv_magic(&mut self, n: V, ty: T, d: i64) -> V {
        let w = ty.bits();
        let two_w1: u128 = 1u128 << (w - 1);
        let ad: u128 = d.unsigned_abs() as u128;
        let t: u128 = two_w1 + if d < 0 { 1 } else { 0 };
        let anc: u128 = t - 1 - t % ad;
        let mut p = w - 1;
        let mut q1 = two_w1 / anc;
        let mut r1 = two_w1 - q1 * anc;
        let mut q2 = two_w1 / ad;
        let mut r2 = two_w1 - q2 * ad;
        loop {
            p += 1;
            q1 *= 2;
            r1 *= 2;
            if r1 >= anc {
                q1 += 1;
                r1 -= anc;
            }
            q2 *= 2;
            r2 *= 2;
            if r2 >= ad {
                q2 += 1;
                r2 -= ad;
            }
            let delta = ad - r2;
            if !(q1 < delta || (q1 == delta && r1 == 0)) {
                break;
            }
        }
        let wmask: u128 = (1u128 << w) - 1;
        let mut m = ((q2 + 1) & wmask) as u64 as i64;
        m = canon(ty, m);
        if d < 0 {
            m = canon(ty, m.wrapping_neg());
        }
        let s = (p - w) as i64;
        let mc = self.konst(ty, m);
        let mut q = self.mk(Op::MulHiS, ty, vec![n, mc]);
        if d > 0 && m < 0 {
            q = self.mk(Op::Add, ty, vec![q, n]);
        } else if d < 0 && m > 0 {
            q = self.mk(Op::Sub, ty, vec![q, n]);
        }
        if s > 0 {
            let sc = self.konst(ty, s);
            q = self.mk(Op::AShr, ty, vec![q, sc]);
        }
        let c = self.konst(ty, w as i64 - 1);
        let sign = self.mk(Op::LShr, ty, vec![q, c]);
        self.mk(Op::Add, ty, vec![q, sign])
    }
}

fn fold_insts(f: &mut Func) -> bool {
    let rpo = f.rpo();
    let mut repl: Vec<V> = vec![NOV; f.insts.len()];
    let uses = f.use_counts();
    let mut cx = Ctx { f, new: Vec::new(), changed: false, uses };
    fn find(repl: &[V], mut v: V) -> V {
        while (v as usize) < repl.len() && repl[v as usize] != NOV {
            v = repl[v as usize];
        }
        v
    }
    for &b in &rpo {
        let old = std::mem::take(&mut cx.f.blocks[b as usize].insts);
        cx.new = Vec::with_capacity(old.len());
        for v in old {
            for ai in 0..cx.f.insts[v as usize].args.len() {
                let a = cx.f.insts[v as usize].args[ai];
                let r = find(&repl, a);
                if r != a {
                    cx.f.insts[v as usize].args[ai] = r;
                }
            }
            match cx.simplify(v) {
                Some(w) => {
                    if repl.len() < cx.f.insts.len() {
                        repl.resize(cx.f.insts.len(), NOV);
                    }
                    repl[v as usize] = w;
                    cx.changed = true;
                }
                None => cx.new.push(v),
            }
        }
        cx.f.blocks[b as usize].insts = std::mem::take(&mut cx.new);
    }
    let _ = &cx.uses;
    let changed = cx.changed;
    repl.resize(f.insts.len(), NOV);
    f.apply_repl(&mut repl);
    changed
}

pub fn simplify_cfg(f: &mut Func) -> bool {
    let mut changed = false;
    // 1. fold constant / degenerate branches
    for b in 0..f.blocks.len() {
        if let Term::Br(c, t, e) = f.blocks[b].term.clone() {
            if t == e {
                f.blocks[b].term = Term::Jmp(t);
                changed = true;
                continue;
            }
            let ci = &f.insts[c as usize];
            if ci.op == Op::Const {
                f.blocks[b].term = Term::Jmp(if ci.k != 0 { t } else { e });
                changed = true;
            } else if ci.op == Op::Xor && f.is_const(ci.args[1]) == Some(1) && f.insts[ci.args[0] as usize].ty == T::I8 {
                // br !x, t, e  =>  br x, e, t  (x is a boolean)
                let x = ci.args[0];
                if f.insts[x as usize].op.is_cmp() {
                    f.blocks[b].term = Term::Br(x, e, t);
                    changed = true;
                }
            }
        }
    }
    changed |= cleanup::prune_unreachable(f);
    // 2. merge straight-line blocks
    let mut guard_merge = 0u32;
    loop {
        guard_merge += 1;
        if guard_merge > 20000 {
            eprintln!("simplify_cfg: step merge does not converge in {}", f.name);
            break;
        }
        let preds = f.preds();
        let mut merged = false;
        let mut repl: Vec<V> = vec![NOV; f.insts.len()];
        let mut dead = vec![false; f.blocks.len()];
        for b in f.rpo() {
            if dead[b as usize] {
                continue;
            }
            loop {
                let s = match f.blocks[b as usize].term {
                    Term::Jmp(s) => s,
                    _ => break,
                };
                if s == 0 || s == b || preds[s as usize].len() != 1 || dead[s as usize] {
                    break;
                }
                let sinsts = std::mem::take(&mut f.blocks[s as usize].insts);
                for v in sinsts {
                    if f.insts[v as usize].op == Op::Phi {
                        repl[v as usize] = f.insts[v as usize].args[0];
                    } else {
                        f.blocks[b as usize].insts.push(v);
                    }
                }
                let st = std::mem::replace(&mut f.blocks[s as usize].term, Term::None);
                f.blocks[b as usize].term = st;
                dead[s as usize] = true;
                // successors of s now come from b
                for ss in f.succs(b) {
                    for ii in 0..f.blocks[ss as usize].insts.len() {
                        let v = f.blocks[ss as usize].insts[ii];
                        if f.insts[v as usize].op != Op::Phi {
                            break;
                        }
                        for p in f.insts[v as usize].pb.iter_mut() {
                            if *p == s {
                                *p = b;
                            }
                        }
                    }
                }
                merged = true;
            }
        }
        if !merged {
            break;
        }
        f.apply_repl(&mut repl);
        changed = true;
    }
    // 3. skip empty forwarding blocks
    let mut guard_forward = 0u32;
    loop {
        guard_forward += 1;
        if guard_forward > 20000 {
            eprintln!("simplify_cfg: step forward does not converge in {}", f.name);
            break;
        }
        let preds = f.preds();
        let mut did = false;
        for e in f.rpo() {
            if e == 0 || !f.blocks[e as usize].insts.is_empty() {
                continue;
            }
            let t = match f.blocks[e as usize].term {
                Term::Jmp(t) if t != e => t,
                _ => continue,
            };
            let t_has_phi = f.blocks[t as usize].insts.first().map(|v| f.insts[*v as usize].op == Op::Phi).unwrap_or(false);
            let mut moved_any = false;
            for &p in &preds[e as usize] {
                if p == e {
                    continue;
                }
                if t_has_phi && (preds[t as usize].contains(&p) || moved_any && false) {
                    continue;
                }
                // a conditional branch whose other arm already goes to t would need a select
                if t_has_phi {
                    if let Term::Br(_, a, b2) = f.blocks[p as usize].term {
                        if a == t || b2 == t {
                            continue;
                        }
                    }
                }
                // redirect p -> e to p -> t
                match &mut f.blocks[p as usize].term {
                    Term::Jmp(x) => {
                        if *x == e {
                            *x = t;
                        }
                    }
                    Term::Br(_, a, b2) => {
                        if *a == e {
                            *a = t;
                        }
                        if *b2 == e {
                            *b2 = t;
                        }
                    }
                    _ => {}
                }
                if t_has_phi {
                    for ii in 0..f.blocks[t as usize].insts.len() {
                        let v = f.blocks[t as usize].insts[ii];
                        if f.insts[v as usize].op != Op::Phi {
                            break;
                        }
                        let inst = f.im(v);
                        if let Some(k) = inst.pb.iter().position(|x| *x == e) {
                            let val = inst.args[k];
                            inst.args.push(val);
                            inst.pb.push(p);
                        }
                    }
                }
                moved_any = true;
                did = true;
            }
            if did {
                break;
            }
        }
        if !did {
            break;
        }
        cleanup::prune_unreachable(f);
        changed = true;
    }
    // 4. thread jumps through blocks that only branch on a phi of constants
    let mut guard_thread4 = 0u32;
    loop {
        guard_thread4 += 1;
        if !super::enabled("thread4") {
            break;
        }
        if guard_thread4 > 20000 {
            eprintln!("simplify_cfg: step thread4 does not converge in {}", f.name);
            break;
        }
        let preds = f.preds();
        let uses = f.use_counts();
        let mut did = false;
        'blocks: for b in f.rpo() {
            let (c, t, e) = match f.blocks[b as usize].term {
                Term::Br(c, t, e) if t != e && t != b && e != b => (c, t, e),
                _ => continue,
            };
            let binsts = f.blocks[b as usize].insts.clone();
            if binsts.is_empty() || !binsts.iter().all(|v| f.insts[*v as usize].op == Op::Phi) || !binsts.contains(&c) {
                continue;
            }
            // the phis of b may only be used by its terminator and by phis of its successors
            let mut phi_uses = vec![0u32; binsts.len()];
            for s in [t, e] {
                for &v in &f.blocks[s as usize].insts {
                    let i = &f.insts[v as usize];
                    if i.op != Op::Phi {
                        break;
                    }
                    for (k, a) in i.args.iter().enumerate() {
                        if i.pb[k] == b {
                            if let Some(pi) = binsts.iter().position(|x| x == a) {
                                phi_uses[pi] += 1;
                            }
                        }
                    }
                }
            }
            for (pi, &ph) in binsts.iter().enumerate() {
                let extra = if ph == c { 1 } else { 0 };
                if uses[ph as usize] != phi_uses[pi] + extra {
                    continue 'blocks;
                }
            }
            let cphi = f.insts[c as usize].clone();
            for (k, &p) in cphi.pb.iter().enumerate() {
                let kc = match f.is_const(cphi.args[k]) {
                    Some(kc) => kc,
                    None => continue,
                };
                if p == b || !preds[b as usize].contains(&p) {
                    continue;
                }
                let target = if kc != 0 { t } else { e };
                // p must not already reach the target directly (its phis would need two inputs)
                if preds[target as usize].contains(&p) {
                    continue;
                }
                // a conditional branch in p with both arms into b cannot be threaded simply
                if let Term::Br(_, x, y) = f.blocks[p as usize].term {
                    if x == b && y == b {
                        continue;
                    }
                }
                // new phi inputs in the target for the edge p -> target
                for ii in 0..f.blocks[target as usize].insts.len() {
                    let v = f.blocks[target as usize].insts[ii];
                    if f.insts[v as usize].op != Op::Phi {
                        break;
                    }
                    let inst = f.insts[v as usize].clone();
                    if let Some(bk) = inst.pb.iter().position(|x| *x == b) {
                        let val = inst.args[bk];
                        // a phi of b seen through p is its input from p
                        let nv = if binsts.contains(&val) {
                            let vi = &f.insts[val as usize];
                            let pk = vi.pb.iter().position(|x| *x == p).unwrap();
                            vi.args[pk]
                        } else {
                            val
                        };
                        let im = f.im(v);
                        im.args.push(nv);
                        im.pb.push(p);
                    }
                }
                match &mut f.blocks[p as usize].term {
                    Term::Jmp(x) => {
                        if *x == b {
                            *x = target;
                        }
                    }
                    Term::Br(_, x, y) => {
                        if *x == b {
                            *x = target;
                        }
                        if *y == b {
                            *y = target;
                        }
                    }
                    _ => {}
                }
                did = true;
                break 'blocks;
            }
        }
        if !did {
            break;
        }
        cleanup::prune_unreachable(f);
        changed = true;
    }
    // 5. a merge block that only re-tests a flag every predecessor sets to a constant:
    //    send each predecessor straight to its destination
    let mut guard_thread5 = 0u32;
    loop {
        guard_thread5 += 1;
        if !super::enabled("thread5") {
            break;
        }
        if guard_thread5 > 20000 {
            eprintln!("simplify_cfg: step thread5 does not converge in {}", f.name);
            break;
        }
        let cfg = Cfg::new(f);
        let def_block = f.block_of();
        let mut did = false;
        'blocks2: for &b in &cfg.rpo {
            let (c, t, e) = match f.blocks[b as usize].term {
                Term::Br(c, t, e) if t != e && t != b && e != b => (c, t, e),
                _ => continue,
            };
            let binsts = f.blocks[b as usize].insts.clone();
            if b == 0 || binsts.is_empty() || !binsts.iter().all(|v| f.insts[*v as usize].op == Op::Phi) || !binsts.contains(&c) {
                continue;
            }
            if cfg.preds[t as usize].len() != 1 || cfg.preds[e as usize].len() != 1 || cfg.preds[b as usize].len() < 2 {
                continue;
            }
            let cphi = f.insts[c as usize].clone();
            let mut dest: Vec<(B, B)> = Vec::new();
            for (k, &p) in cphi.pb.iter().enumerate() {
                let kc = match f.is_const(cphi.args[k]) {
                    Some(kc) => kc,
                    None => continue 'blocks2,
                };
                if p == b {
                    continue 'blocks2;
                }
                if let Term::Br(_, x, y) = f.blocks[p as usize].term {
                    if x == b && y == b {
                        continue 'blocks2;
                    }
                }
                dest.push((p, if kc != 0 { t } else { e }));
            }
            if dest.len() != cfg.preds[b as usize].len() {
                continue;
            }
            // every use of b's phis must be dominated by t or by e
            for bb in 0..f.blocks.len() {
                if !cfg.reachable(bb as B) || bb as B == b {
                    continue;
                }
                for &v in &f.blocks[bb].insts {
                    let i = &f.insts[v as usize];
                    for (k, a) in i.args.iter().enumerate() {
                        if def_block[*a as usize] == b {
                            let at = if i.op == Op::Phi { i.pb[k] } else { bb as B };
                            if !(cfg.dom(t, at) || cfg.dom(e, at)) {
                                continue 'blocks2;
                            }
                        }
                    }
                }
                for a in f.term_uses(bb as B) {
                    if def_block[a as usize] == b && !(cfg.dom(t, bb as B) || cfg.dom(e, bb as B)) {
                        continue 'blocks2;
                    }
                }
            }
            // build the replacement values of b's phis on each side
            let mut repl_t: Vec<V> = Vec::new();
            let mut repl_e: Vec<V> = Vec::new();
            for (side, s) in [(0, t), (1, e)] {
                let ps: Vec<B> = dest.iter().filter(|d| d.1 == s).map(|d| d.0).collect();
                for &ph in &binsts {
                    let pi = f.insts[ph as usize].clone();
                    let vals: Vec<V> = ps.iter().map(|p| pi.args[pi.pb.iter().position(|x| x == p).unwrap()]).collect();
                    let nv = if ps.is_empty() {
                        ph
                    } else if vals.iter().all(|x| *x == vals[0]) {
                        vals[0]
                    } else {
                        let np = f.mk(Op::Phi, pi.ty, vals, 0);
                        f.im(np).pb = ps.clone();
                        f.blocks[s as usize].insts.insert(0, np);
                        np
                    };
                    if side == 0 {
                        repl_t.push(nv);
                    } else {
                        repl_e.push(nv);
                    }
                }
            }
            // rewrite uses
            for bb in 0..f.blocks.len() {
                if !cfg.reachable(bb as B) || bb as B == b {
                    continue;
                }
                let in_t = |x: B| cfg.dom(t, x);
                for ii in 0..f.blocks[bb].insts.len() {
                    let v = f.blocks[bb].insts[ii];
                    if (v as usize) >= def_block.len() {
                        continue;
                    }
                    for ai in 0..f.insts[v as usize].args.len() {
                        let a = f.insts[v as usize].args[ai];
                        if (a as usize) < def_block.len() && def_block[a as usize] == b {
                            let at = if f.insts[v as usize].op == Op::Phi { f.insts[v as usize].pb[ai] } else { bb as B };
                            let k = binsts.iter().position(|x| *x == a).unwrap();
                            f.insts[v as usize].args[ai] = if in_t(at) { repl_t[k] } else { repl_e[k] };
                        }
                    }
                }
                let side_t = in_t(bb as B);
                let fix = |a: &mut V| {
                    if (*a as usize) < def_block.len() && def_block[*a as usize] == b {
                        let k = binsts.iter().position(|x| x == a).unwrap();
                        *a = if side_t { repl_t[k] } else { repl_e[k] };
                    }
                };
                match &mut f.blocks[bb].term {
                    Term::Br(cc, _, _) => fix(cc),
                    Term::Ret(vs) => vs.iter_mut().for_each(fix),
                    _ => {}
                }
            }
            // retarget the predecessors
            for (p, s) in dest {
                match &mut f.blocks[p as usize].term {
                    Term::Jmp(x) => {
                        if *x == b {
                            *x = s;
                        }
                    }
                    Term::Br(_, x, y) => {
                        if *x == b {
                            *x = s;
                        }
                        if *y == b {
                            *y = s;
                        }
                    }
                    _ => {}
                }
            }
            did = true;
            break;
        }
        if !did {
            break;
        }
        cleanup::prune_unreachable(f);
        changed = true;
    }
    // 6. if-conversion: tiny side-effect-free arms become selects (conditional moves)
    loop {
        if !super::enabled("ifconv") {
            break;
        }
        let preds = f.preds();
        let mut did = false;
        for b in f.rpo() {
            let (c, t, e) = match f.blocks[b as usize].term {
                Term::Br(c, t, e) if t != e => (c, t, e),
                _ => continue,
            };
            let side = |f: &Func, x: B| -> Option<B> {
                if x == 0 || preds[x as usize].len() != 1 {
                    return None;
                }
                let j = match f.blocks[x as usize].term {
                    Term::Jmp(j) => j,
                    _ => return None,
                };
                let insts = &f.blocks[x as usize].insts;
                let mut real = 0;
                for &v in insts {
                    let op = f.insts[v as usize].op;
                    let cheap = matches!(
                        op,
                        Op::Const | Op::FConst | Op::GAddr | Op::FAddr | Op::Add | Op::Sub | Op::And | Op::Or | Op::Xor | Op::Shl | Op::LShr | Op::AShr | Op::SExt | Op::ZExt | Op::Trunc
                    );
                    if !cheap {
                        return None;
                    }
                    if !matches!(op, Op::Const | Op::FConst | Op::GAddr | Op::FAddr) {
                        real += 1;
                    }
                }
                if real > 2 {
                    return None;
                }
                Some(j)
            };
            let (tb, eb, j) = match (side(f, t), side(f, e)) {
                (Some(j1), Some(j2)) if j1 == j2 && j1 != t && j1 != e => (Some(t), Some(e), j1),
                (Some(j1), _) if j1 == e => (Some(t), None, e),
                (_, Some(j2)) if j2 == t => (None, Some(e), t),
                _ => continue,
            };
            if j == b || j == 0 {
                continue;
            }
            let from_t = tb.unwrap_or(b);
            let from_e = eb.unwrap_or(b);
            // the join's phis decide whether this is worth it
            let phis: Vec<V> = f.blocks[j as usize].insts.iter().copied().take_while(|v| f.insts[*v as usize].op == Op::Phi).collect();
            let mut pairs: Vec<(V, V, V)> = Vec::new();
            let mut ok = true;
            let mut selects = 0;
            for &ph in &phis {
                let i = &f.insts[ph as usize];
                let vt = i.pb.iter().position(|x| *x == from_t).map(|k| i.args[k]);
                let ve = i.pb.iter().position(|x| *x == from_e).map(|k| i.args[k]);
                match (vt, ve) {
                    (Some(vt), Some(ve)) => {
                        if vt != ve {
                            if !i.ty.is_int() {
                                ok = false;
                            }
                            selects += 1;
                        }
                        pairs.push((ph, vt, ve));
                    }
                    _ => ok = false,
                }
            }
            if !ok || selects == 0 || selects > 2 {
                continue;
            }
            // hoist both arms into b and merge the values with selects
            for x in [tb, eb].into_iter().flatten() {
                let moved = std::mem::take(&mut f.blocks[x as usize].insts);
                f.blocks[b as usize].insts.extend(moved);
            }
            for (ph, vt, ve) in pairs {
                let ty = f.insts[ph as usize].ty;
                let nv = if vt == ve { vt } else { f.push(b, Op::Select, ty, vec![c, vt, ve], 0) };
                let i = f.im(ph);
                let mut k = 0;
                while k < i.pb.len() {
                    if i.pb[k] == from_t || i.pb[k] == from_e {
                        i.pb.remove(k);
                        i.args.remove(k);
                    } else {
                        k += 1;
                    }
                }
                i.pb.push(b);
                i.args.push(nv);
            }
            f.blocks[b as usize].term = Term::Jmp(j);
            did = true;
            break;
        }
        if !did {
            break;
        }
        cleanup::prune_unreachable(f);
        changed = true;
    }
    // normalize `br c, t, t`
    for b in 0..f.blocks.len() {
        if let Term::Br(_, t, e) = f.blocks[b].term {
            if t == e {
                f.blocks[b].term = Term::Jmp(t);
                changed = true;
            }
        }
    }
    changed
}

pub fn run(f: &mut Func) -> bool {
    let mut any = false;
    for _ in 0..50 {
        let mut ch = false;
        super::trace("  fold", f);
        ch |= fold_insts(f);
        super::trace("  cfg", f);
        ch |= simplify_cfg(f);
        super::trace("  phis", f);
        ch |= cleanup::trivial_phis(f);
        super::trace("  dce", f);
        ch |= cleanup::dce(f);
        if !ch {
            break;
        }
        any = true;
    }
    any
}
