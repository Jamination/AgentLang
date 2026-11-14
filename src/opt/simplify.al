// Constant folding, algebraic simplification, strength reduction and CFG simplification.

priv fn mask(bits: i64) -> u64 {
    if bits >= 64 {
        return ~u64(0)
    }
    return (u64(1) << bits) - 1
}

priv fn is_pow2(x: u64) -> bool {
    return x != 0 && x & (x - 1) == 0
}

// |k| as an unsigned value (also for the most negative k)
priv fn uabs(k: i64) -> u64 {
    if k < 0 {
        return u64(0 - k)
    }
    return u64(k)
}

// high 64 bits of the unsigned 128-bit product a * b
priv fn mulhu(a: u64, b: u64) -> u64 {
    a0 := a & 0xFFFFFFFF
    a1 := a >> 32
    b0 := b & 0xFFFFFFFF
    b1 := b >> 32
    p00 := a0 * b0
    p01 := a0 * b1
    p10 := a1 * b0
    p11 := a1 * b1
    mid := (p00 >> 32) + (p01 & 0xFFFFFFFF) + (p10 & 0xFFFFFFFF)
    return p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32)
}

// high 64 bits of the signed 128-bit product a * b
priv fn mulhs(a: i64, b: i64) -> i64 {
    h := mulhu(u64(a), u64(b))
    if a < 0 {
        h -= u64(b)
    }
    if b < 0 {
        h -= u64(a)
    }
    return i64(h)
}

// low 64 bits of the 128-bit value hi:lo shifted right by `bits` (arithmetic when signed)
priv fn shr128(lo: u64, hi: u64, bits: i64, signed: bool) -> i64 {
    s := bits & 127
    if s == 0 {
        return i64(lo)
    }
    if s < 64 {
        return i64((lo >> s) | (hi << (64 - s)))
    }
    if s == 64 {
        return i64(hi)
    }
    if signed {
        return i64(hi) >> (s - 64)
    }
    return i64(hi >> (s - 64))
}

priv fn fold_bin(op: Op, ty: T, a: i64, b: i64) -> Opt[i64] {
    bits := i64(ty.bits())
    m := mask(bits)
    ua := u64(a) & m
    ub := u64(b) & m
    sh := i64(u32(u64(b) & (u64(bits) - 1)))
    r := match op {
        Add => a + b
        Sub => a - b
        Mul => a * b
        SDiv => {
            if b == 0 {
                return None
            }
            // MIN / -1 wraps to MIN
            if b == -1 { 0 - a } else { a / b }
        }
        SRem => {
            if b == 0 {
                return None
            }
            // MIN % -1 is 0
            if b == -1 { 0 } else { a % b }
        }
        UDiv => {
            if ub == 0 {
                return None
            }
            i64(ua / ub)
        }
        URem => {
            if ub == 0 {
                return None
            }
            i64(ua % ub)
        }
        And => a & b
        Or => a | b
        Xor => a ^ b
        Shl => i64((ua << sh) & m)
        LShr => i64(ua >> sh)
        AShr => a >> sh
        Rotl => {
            if sh == 0 {
                a
            } else {
                i64(((ua << sh) | (ua >> (bits - sh))) & m)
            }
        }
        Rotr => {
            if sh == 0 {
                a
            } else {
                i64(((ua >> sh) | (ua << (bits - sh))) & m)
            }
        }
        // the high half of the signed 128-bit product, shifted right by bits
        MulHiS => shr128(u64(a) * u64(b), u64(mulhs(a, b)), bits, true)
        // the same, unsigned
        MulHiU => shr128(ua * ub, mulhu(ua, ub), bits, false)
        _ => return None
    }
    return Some(ir_canon(ty, r))
}

fn simplify_fold_icmp(op: Op, ty: T, a: i64, b: i64) -> Opt[bool] {
    m := mask(i64(ty.bits()))
    ua := u64(a) & m
    ub := u64(b) & m
    match op {
        Eq => Some(a == b)
        Ne => Some(a != b)
        Slt => Some(a < b)
        Sle => Some(a <= b)
        Sgt => Some(a > b)
        Sge => Some(a >= b)
        Ult => Some(ua < ub)
        Ule => Some(ua <= ub)
        Ugt => Some(ua > ub)
        Uge => Some(ua >= ub)
        _ => None
    }
}

// `new` is a builtin: the field is `new_insts`
priv struct Ctx {
    f: *Func
    new_insts: Vec[i32]
    changed: bool
    uses: Vec[i32] // use counts, read only for an Xor or Or (fold_insts)
}

priv fn c(self: *Ctx, v: i64) -> Opt[i64] {
    return self.f.is_const(v)
}

// scalar float constants only (vector constants are never folded)
priv fn fc(self: *Ctx, v: i64) -> Opt[f64] {
    i := &self.f.insts[v]
    if i.op == FConst && i.ty == F64 {
        return Some(cast[f64](u64(i.k)))
    } else if i.op == FConst && i.ty == F32 {
        return Some(f64(cast[f32](u32(i.k))))
    }
    return None
}

// bits of the constant r in type ty; f32 results are computed in f64 and rounded once,
// which is exact for + - * / sqrt
priv fn fbits(ty: T, r: f64) -> i64 {
    if ty == F32 {
        return i64(cast[u32](f32(r)))
    }
    return i64(cast[u64](r))
}

priv fn konst(self: *Ctx, ty: T, k: i64) -> i64 {
    v := self.f.mk(Const, ty, vec[i64](), ir_canon(ty, k))
    push_fast(&self.new_insts, i32(v))
    return v
}

priv fn mk(self: *Ctx, op: Op, ty: T, args: Vec[i64]) -> i64 {
    v := self.f.mk(op, ty, args, 0)
    push_fast(&self.new_insts, i32(v))
    return v
}

// rewrite v in place
priv fn set(self: *Ctx, v: i64, op: Op, args: Vec[i64], k: i64) {
    i := self.f.im(v)
    if i.op == Phi {
        i.cap = 0 // (a phi's room; other instructions keep their source location)
    }
    i.op = op
    i.args = args.items()
    i.k = k
    self.changed = true
}

priv fn set_const(self: *Ctx, v: i64, k: i64) {
    ty := self.f.insts[v].ty
    self.set(v, Const, vec[i64](), ir_canon(ty, k))
}

priv fn op(self: *Ctx, v: i64) -> Op {
    return self.f.insts[v].op
}

priv fn is_not(s: *Ctx, n: i64, x: i64) -> bool {
    ni := &s.f.insts[n]
    return ni.op == Xor && s.c(ni.args[1]) == Some(-1) && ni.args[0] == x
}

// bit select (x & y) ^ (~x & z), with ai, bi the two Ands: (x, y, z) of the first match in
// the order (p, q) = (ai, bi), (bi, ai)
priv fn bit_select(s: *Ctx, ai: *Inst, bi: *Inst) -> Opt[(i64, i64, i64)] {
    for o in 0..2 {
        p := if o == 0 { ai } else { bi }
        q := if o == 0 { bi } else { ai }
        for pi in 0..2 {
            for qi in 0..2 {
                if is_not(s, q.args[qi], p.args[pi]) {
                    return Some((p.args[pi], p.args[1 - pi], q.args[1 - qi]))
                }
            }
        }
    }
    return None
}

// the comparison that is the negation of op, if there is one
priv fn negated(op: Op) -> Opt[Op] {
    if op.is_icmp() {
        return Some(op.negate_icmp())
    }
    return match op {
        FEq => Some(Op.FNe)
        FNe => Some(Op.FEq)
        _ => None
    }
}

// returns Some(w) when v should be replaced by the existing value w
priv fn simplify(self: *Ctx, v: i64) -> Opt[i64] {
    // ops without a rule below (most instructions): nothing to copy or match
    match self.f.insts[v].op {
        Const, FConst, Param, GAddr, FAddr, Alloca, Load, Store, Call, CallInd, Syscall, Proj, Phi,
        MemCpy, MemSet => return None
        _ => {}
    }
    inst := self.f.insts[v]
    ty := inst.ty
    op := inst.op
    match op {
        Add, Sub, Mul, SDiv, UDiv, SRem, URem, And, Or, Xor, Shl, LShr, AShr,
        Rotl, Rotr, MulHiS, MulHiU => {
            a := inst.args[0]
            b := inst.args[1]
            match (self.c(a), self.c(b)) {
                (Some(x), Some(y)) => match fold_bin(op, ty, x, y) {
                    Some(r) => {
                        self.set_const(v, r)
                        return None
                    }
                    None => {}
                }
                _ => {}
            }
            if op.is_commutative() && is_some(self.c(a)) && !is_some(self.c(b)) {
                a, b = (b, a)
                self.f.im(v).args = []i64{a, b}
                self.changed = true
            }
            cb := self.c(b)
            bits := i64(ty.bits())
            k := cb.or(0)
            hk := is_some(cb)
            if hk {
                is_shift := op == Shl || op == LShr || op == AShr || op == Rotl || op == Rotr
                if k == 0 && (op == Add || op == Sub || op == Or || op == Xor || is_shift) {
                    return Some(a)
                } else if is_shift && k & (bits - 1) == 0 {
                    return Some(a)
                } else if k == 1 && (op == Mul || op == SDiv || op == UDiv) {
                    return Some(a)
                } else if k == 0 && (op == Mul || op == And) {
                    self.set_const(v, 0)
                    return None
                } else if k == 1 && (op == SRem || op == URem) {
                    self.set_const(v, 0)
                    return None
                } else if op == Xor && k == 1 && ty == I8 && self.op(a).is_cmp() {
                    ai := &self.f.insts[a]
                    match negated(ai.op) {
                        Some(nop) => {
                            self.set(v, nop, vec_of(ai.args), 0)
                            return None
                        }
                        None => {}
                    }
                } else if op == And && k == -1 {
                    return Some(a)
                } else if op == Or && k == -1 {
                    self.set_const(v, -1)
                    return None
                } else if op == Sub {
                    nk := self.konst(ty, 0 - k)
                    self.set(v, Add, vec_of([]i64{a, nk}), 0)
                    return None
                } else if op == Mul && k > 0 && is_pow2(u64(k)) {
                    s := self.konst(ty, i64(ctz(u64(k))))
                    self.set(v, Shl, vec_of([]i64{a, s}), 0)
                    return None
                } else if op == Mul && k == -1 {
                    z := self.konst(ty, 0)
                    self.set(v, Sub, vec_of([]i64{z, a}), 0)
                    return None
                } else if op == UDiv {
                    uk := u64(k) & mask(i64(ty.bits()))
                    if is_pow2(uk) {
                        s := self.konst(ty, i64(ctz(uk)))
                        self.set(v, LShr, vec_of([]i64{a, s}), 0)
                        return None
                    }
                    if ty == I64 || ty == I32 {
                        q := self.udiv_magic(a, ty, uk)
                        return Some(q)
                    }
                } else if op == URem {
                    uk := u64(k) & mask(i64(ty.bits()))
                    if is_pow2(uk) {
                        m := self.konst(ty, i64(uk - 1))
                        self.set(v, And, vec_of([]i64{a, m}), 0)
                        return None
                    }
                    if ty == I64 || ty == I32 {
                        q := self.udiv_magic(a, ty, uk)
                        d := self.konst(ty, k)
                        p := self.mk(Mul, ty, vec_of([]i64{q, d}))
                        self.set(v, Sub, vec_of([]i64{a, p}), 0)
                        return None
                    }
                } else if (op == SDiv || op == SRem) && k != 0 && k != -1 && (ty == I64 || ty == I32) &&
                    k != i64(0x8000000000000000) && !(ty == I32 && k == i64(i32(0x80000000))) {
                    q: i64
                    if is_pow2(uabs(k)) {
                        // (a + ((a >> bits-1) >>> (bits - s))) >> s, negated for negative divisors
                        s := i64(ctz(uabs(k)))
                        c1 := self.konst(ty, bits - 1)
                        sign := self.mk(AShr, ty, vec_of([]i64{a, c1}))
                        c2 := self.konst(ty, bits - s)
                        bias := self.mk(LShr, ty, vec_of([]i64{sign, c2}))
                        sum := self.mk(Add, ty, vec_of([]i64{a, bias}))
                        c3 := self.konst(ty, s)
                        q1 := self.mk(AShr, ty, vec_of([]i64{sum, c3}))
                        if k < 0 {
                            z := self.konst(ty, 0)
                            q = self.mk(Sub, ty, vec_of([]i64{z, q1}))
                        } else {
                            q = q1
                        }
                    } else {
                        q = self.sdiv_magic(a, ty, k)
                    }
                    if op == SDiv {
                        return Some(q)
                    }
                    d := self.konst(ty, k)
                    p := self.mk(Mul, ty, vec_of([]i64{q, d}))
                    self.set(v, Sub, vec_of([]i64{a, p}), 0)
                    return None
                }
            }
            if a == b {
                if op == Sub || op == Xor {
                    self.set_const(v, 0)
                    return None
                }
                if op == And || op == Or {
                    return Some(a)
                }
            }
            // (x op c1) op c2 for associative ops
            if hk {
                k2 := k
                ai := &self.f.insts[a]
                if ai.op == op && (op == Add || op == Mul || op == And || op == Or || op == Xor) {
                    match self.c(ai.args[1]) {
                        Some(k1) => {
                            x := ai.args[0]
                            kc := self.konst(ty, unwrap(fold_bin(op, ty, k1, k2)))
                            self.set(v, op, vec_of([]i64{x, kc}), 0)
                            return None
                        }
                        None => {}
                    }
                }
                // (x << c1) << c2, (x >>> c1) >>> c2
                if ai.op == op && (op == Shl || op == LShr) {
                    match self.c(ai.args[1]) {
                        Some(k1) => {
                            s1 := k1 & (bits - 1)
                            s2 := k2 & (bits - 1)
                            x := ai.args[0]
                            if s1 + s2 >= bits {
                                self.set_const(v, 0)
                            } else {
                                kc := self.konst(ty, s1 + s2)
                                self.set(v, op, vec_of([]i64{x, kc}), 0)
                            }
                            return None
                        }
                        None => {}
                    }
                }
            }
            // (x + c1) << c2  =>  (x << c2) + (c1 << c2) ; (x + c1) * c2  =>  x * c2 + c1 * c2
            if hk {
                k2 := k
                ai := &self.f.insts[a]
                if (op == Shl || op == Mul) && ai.op == Add {
                    match self.c(ai.args[1]) {
                        Some(k1) => match fold_bin(op, ty, k1, k2) {
                            Some(kf) if fits_i32(kf) => {
                                x := ai.args[0]
                                inner := self.mk(op, ty, vec_of([]i64{x, b}))
                                kc := self.konst(ty, kf)
                                self.set(v, Add, vec_of([]i64{inner, kc}), 0)
                                return None
                            }
                            _ => {}
                        }
                        None => {}
                    }
                }
            }
            if op == Xor || op == Or {
                ai := &self.f.insts[a]
                bi := &self.f.insts[b]
                ua := if a < self.uses.len { i64(self.uses[a]) } else { 2 }
                ub := if b < self.uses.len { i64(self.uses[b]) } else { 2 }
                if ai.op == And && bi.op == And && ua == 1 && ub == 1 {
                    // bit select: (x & y) ^ (~x & z)  =>  z ^ (x & (y ^ z))
                    match bit_select(self, ai, bi) {
                        Some((x, y, z)) => {
                            yz := self.mk(Xor, ty, vec_of([]i64{y, z}))
                            m := self.mk(And, ty, vec_of([]i64{x, yz}))
                            self.set(v, Xor, vec_of([]i64{z, m}), 0)
                            return None
                        }
                        None => {}
                    }
                    // (x & y) ^ (x & z)  =>  x & (y ^ z)
                    if op == Xor {
                        for pi in 0..2 {
                            for qi in 0..2 {
                                if ai.args[pi] == bi.args[qi] {
                                    x := ai.args[pi]
                                    yz := self.mk(Xor, ty, vec_of([]i64{ai.args[1 - pi], bi.args[1 - qi]}))
                                    self.set(v, And, vec_of([]i64{x, yz}), 0)
                                    return None
                                }
                            }
                        }
                    }
                }
            }
            // rotate idioms: (x >>> n) | (x << (bits - n))
            if op == Or || op == Xor || op == Add {
                match self.match_rotate(a, b, ty) {
                    Some((rop, x, n)) => {
                        self.set(v, rop, vec_of([]i64{x, n}), 0)
                        return None
                    }
                    None => {}
                }
            }
            // x + (0 - y) => x - y
            if op == Add {
                bi := &self.f.insts[b]
                if bi.op == Sub && self.c(bi.args[0]) == Some(0) {
                    y := bi.args[1]
                    self.set(v, Sub, vec_of([]i64{a, y}), 0)
                    return None
                }
            }
            return None
        }
        FAdd, FSub, FMul, FDiv => {
            match (self.fc(inst.args[0]), self.fc(inst.args[1])) {
                (Some(x), Some(y)) => {
                    r := match op {
                        FAdd => x + y
                        FSub => x - y
                        FMul => x * y
                        _ => x / y
                    }
                    self.set(v, FConst, vec[i64](), fbits(ty, r))
                }
                _ => {}
            }
            return None
        }
        FNeg, FAbs, FSqrt => {
            match self.fc(inst.args[0]) {
                Some(x) => {
                    r := match op {
                        FNeg => -x
                        FAbs => fabs(x)
                        _ => sqrt(x)
                    }
                    self.set(v, FConst, vec[i64](), fbits(ty, r))
                }
                None => {}
            }
            return None
        }
        Eq, Ne, Slt, Sle, Sgt, Sge, Ult, Ule, Ugt, Uge => {
            a := inst.args[0]
            b := inst.args[1]
            at := self.f.insts[a].ty
            match (self.c(a), self.c(b)) {
                (Some(x), Some(y)) => {
                    self.set_const(v, i64(unwrap(simplify_fold_icmp(op, at, x, y))))
                    return None
                }
                _ => {}
            }
            if is_some(self.c(a)) {
                a, b = (b, a)
                op = op.swap_cmp()
                i := self.f.im(v)
                i.op = op
                i.args = []i64{a, b}
                self.changed = true
            }
            if a == b {
                r := op == Eq || op == Sle || op == Sge || op == Ule || op == Uge
                self.set_const(v, i64(r))
                return None
            }
            // (x & (len - 1)) <u len  is true exactly when len != 0
            if op == Ult || op == Ugt {
                idx, lenv := if op == Ult { (a, b) } else { (b, a) }
                if self.masked_by(idx, lenv, 4, idx) {
                    z := self.konst(at, 0)
                    self.set(v, Ne, vec_of([]i64{lenv, z}), 0)
                    return None
                }
            }
            // comparisons of booleans with constants
            k := match self.c(b) {
                Some(k1) => k1
                None => return None
            }
            ai := &self.f.insts[a]
            if (op == Eq || op == Ne) && at == I8 && ai.op.is_cmp() {
                truth := (op == Ne) == (k == 0)
                // (cmp != 0) or (cmp == 1) => cmp ; (cmp == 0) or (cmp != 1) => !cmp
                if k == 0 || k == 1 {
                    if truth {
                        return Some(a)
                    }
                    match negated(ai.op) {
                        Some(nop) => {
                            self.set(v, nop, vec_of(ai.args), 0)
                            return None
                        }
                        None => {}
                    }
                }
            }
            // unsigned x < 0 is false, x >= 0 is true
            if k == 0 && op == Ult {
                self.set_const(v, 0)
                return None
            }
            if k == 0 && op == Uge {
                self.set_const(v, 1)
                return None
            }
            // (x + c1) == c2  =>  x == c2 - c1
            if (op == Eq || op == Ne) && ai.op == Add {
                match self.c(ai.args[1]) {
                    Some(k1) => {
                        // (ai is not valid after konst)
                        x := ai.args[0]
                        nk := self.konst(at, k - k1)
                        self.set(v, op, vec_of([]i64{x, nk}), 0)
                        return None
                    }
                    None => {}
                }
            }
            return None
        }
        FEq, FNe, FLt, FLe, FGt, FGe => {
            match (self.fc(inst.args[0]), self.fc(inst.args[1])) {
                (Some(x), Some(y)) => {
                    r := match op {
                        FEq => x == y
                        FNe => x != y
                        FLt => x < y
                        FLe => x <= y
                        FGt => x > y
                        _ => x >= y
                    }
                    self.set_const(v, i64(r))
                }
                _ => {}
            }
            return None
        }
        SExt, ZExt, Trunc => {
            a := inst.args[0]
            at := self.f.insts[a].ty
            if at == ty {
                return Some(a)
            }
            match self.c(a) {
                Some(x) => {
                    self.set_const(v, if op == ZExt { i64(u64(x) & mask(i64(at.bits()))) } else { x })
                    return None
                }
                None => {}
            }
            ai := &self.f.insts[a]
            if (op == SExt && ai.op == SExt) || (op == ZExt && ai.op == ZExt) {
                self.set(v, op, vec_of([]i64{ai.args[0]}), 0)
            } else if op == SExt && ai.op == ZExt {
                // zero-extended value is non-negative
                self.set(v, ZExt, vec_of([]i64{ai.args[0]}), 0)
            } else if op == Trunc && (ai.op == SExt || ai.op == ZExt || ai.op == Trunc) {
                src := ai.args[0]
                st := self.f.insts[src].ty
                if st == ty {
                    return Some(src)
                }
                if ai.op == Trunc || i64(st.bits()) > i64(ty.bits()) {
                    self.set(v, Trunc, vec_of([]i64{src}), 0)
                } else {
                    self.set(v, ai.op, vec_of([]i64{src}), 0)
                }
            }
            return None
        }
        SIToF => {
            // f32(x), not f32(f64(x)) (rounded once)
            match self.c(inst.args[0]) {
                Some(x) => self.set(v, FConst, vec[i64](), if ty == F32 { i64(cast[u32](f32(x))) } else { i64(cast[u64](f64(x))) })
                None => {}
            }
            return None
        }
        FToSI => {
            match self.fc(inst.args[0]) {
                Some(x) if is_finite(x) && fabs(x) < 9.0e18 && (ty == I64 || fabs(x) < 2.0e9) => self.set_const(v, i64(x))
                _ => {}
            }
            return None
        }
        BitsToF => {
            match self.c(inst.args[0]) {
                Some(x) => self.set(v, FConst, vec[i64](), if ty == F32 { x & 0xFFFFFFFF } else { x })
                None => {}
            }
            return None
        }
        FToBits => {
            i := &self.f.insts[inst.args[0]]
            if i.op == FConst {
                k := i.k
                self.set_const(v, k)
            }
            return None
        }
        FExt, FTrunc => {
            match self.fc(inst.args[0]) {
                Some(x) => self.set(v, FConst, vec[i64](), fbits(ty, x))
                None => {}
            }
            return None
        }
        Select => {
            c := inst.args[0]
            a := inst.args[1]
            b := inst.args[2]
            if a == b {
                return Some(a)
            }
            match self.c(c) {
                Some(k) => return Some(if k != 0 { a } else { b })
                None => {}
            }
            return None
        }
        Phi => { return None }
        _ => {}
    }
    return None
}

// x is neither infinite nor NaN
priv fn is_finite(x: f64) -> bool {
    return (cast[u64](x) >> 52) & 0x7FF != 0x7FF
}

// is v always of the form (x & (len - 1)), directly or through phis?
priv fn masked_by(self: *Ctx, v: i64, lenv: i64, depth: i64, root: i64) -> bool {
    fn is_len_m1(s: *Ctx, lenv: i64, m: i64) -> bool {
        mi := &s.f.insts[m]
        return mi.op == Add && mi.args[0] == lenv && s.c(mi.args[1]) == Some(-1)
    }
    i := &self.f.insts[v]
    if i.op == And {
        return is_len_m1(self, lenv, i.args[0]) || is_len_m1(self, lenv, i.args[1])
    }
    if i.op == Phi && depth > 0 && i.args.len != 0 {
        for a in i.args {
            if !(a == root || a == v || self.masked_by(a, lenv, depth - 1, root)) {
                return false
            }
        }
        return true
    }
    return false
}

// upper bound on the number of significant bits of an unsigned value
priv fn ubits(self: *Ctx, v: i64, depth: i64) -> i64 {
    i := &self.f.insts[v]
    tb := max(i64(i.ty.bits()), 1)
    if depth == 0 {
        return tb
    }
    r := match i.op {
        Const => 64 - i64(clz(u64(i.k) & mask(tb)))
        LShr => match self.c(i.args[1]) {
            Some(k) => max(self.ubits(i.args[0], depth - 1) - i64(u32(k & (tb - 1))), 0)
            None => tb
        }
        And => min(self.ubits(i.args[0], depth - 1), self.ubits(i.args[1], depth - 1))
        ZExt => min(self.ubits(i.args[0], depth - 1), i64(self.f.insts[i.args[0]].ty.bits()))
        URem => match self.c(i.args[1]) {
            Some(k) => 64 - i64(clz(u64(k) & mask(tb)))
            None => tb
        }
        UDiv => match self.c(i.args[1]) {
            Some(k) if k > 0 => max(self.ubits(i.args[0], depth - 1) - (63 - i64(clz(u64(k)))), 0)
            _ => tb
        }
        _ if i.op.is_cmp() => 1
        _ => tb
    }
    return min(r, tb)
}

priv fn match_rotate(self: *Ctx, a: i64, b: i64, ty: T) -> Opt[(Op, i64, i64)] {
    // m is (bits - n) for a constant multiple of bits
    fn is_complement(s: *Ctx, bits: i64, m: i64, n: i64) -> bool {
        mi := &s.f.insts[m]
        if !(mi.op == Sub && mi.args[1] == n) {
            return false
        }
        match s.c(mi.args[0]) {
            Some(k) => k & (bits - 1) == 0
            None => false
        }
    }
    bits := i64(ty.bits())
    ai := &self.f.insts[a]
    bi := &self.f.insts[b]
    shr, shl := match (ai.op, bi.op) {
        (LShr, Shl) => (ai, bi)
        (Shl, LShr) => (bi, ai)
        _ => return None
    }
    if shr.args[0] != shl.args[0] {
        return None
    }
    x := shr.args[0]
    nr := shr.args[1]
    nl := shl.args[1]
    match (self.c(nr), self.c(nl)) {
        (Some(kr0), Some(kl0)) => {
            kr := kr0 & (bits - 1)
            kl := kl0 & (bits - 1)
            if kr + kl == bits && kr != 0 {
                return Some((Rotr, x, nr))
            }
            return None
        }
        _ => {}
    }
    // variable amounts: (x >>> n) | (x << (bits - n))  or  (x << n) | (x >>> (bits - n))
    if is_complement(self, bits, nl, nr) {
        return Some((Rotr, x, nr))
    }
    if is_complement(self, bits, nr, nl) {
        return Some((Rotl, x, nl))
    }
    return None
}

// unsigned division by a constant (Hacker's Delight, magicu)
// Every value fits 64 bits (or is reduced modulo 2^w right away), so wrapping u64
// arithmetic is enough.
priv fn udiv_magic(self: *Ctx, n: i64, ty: T, d: u64) -> i64 {
    w := i64(ty.bits())
    // a dividend known to be narrow needs only one multiplication and one shift
    nb := self.ubits(n, 6)
    if ty == I64 && nb < 64 && nb > 0 {
        if nb < 64 && d >= (u64(1) << nb) {
            return self.konst(ty, 0)
        }
        for sh in nb..64 {
            two_s := u64(1) << sh
            m := (two_s + d - 1) / d
            e := m * d - two_s
            // (e << nb) <= two_s
            if e <= (u64(1) << (sh - nb)) && m < (u64(1) << (64 - nb)) {
                mc := self.konst(ty, i64(m))
                t := self.mk(Mul, ty, vec_of([]i64{n, mc}))
                sc := self.konst(ty, sh)
                return self.mk(LShr, ty, vec_of([]i64{t, sc}))
            }
        }
    }
    two_w1 := u64(1) << (w - 1)
    wmask := mask(w)
    // wmask - ((1 << w) - d) % d
    nc := wmask - (wmask - d + 1) % d
    p := w - 1
    q1 := two_w1 / nc
    r1 := two_w1 - q1 * nc
    q2 := (two_w1 - 1) / d
    r2 := (two_w1 - 1) - q2 * d
    add := false
    loop {
        p += 1
        if r1 >= nc - r1 {
            q1 = (2 * q1 + 1) & wmask
            r1 = 2 * r1 - nc
        } else {
            q1 = (2 * q1) & wmask
            r1 *= 2
        }
        if r2 + 1 >= d - r2 {
            if q2 >= two_w1 - 1 {
                add = true
            }
            q2 = (2 * q2 + 1) & wmask
            r2 = 2 * r2 + 1 - d
        } else {
            if q2 >= two_w1 {
                add = true
            }
            q2 = (2 * q2) & wmask
            r2 = 2 * r2 + 1
        }
        delta := d - 1 - r2
        if !(p < 2 * w && (q1 < delta || (q1 == delta && r1 == 0))) {
            break
        }
    }
    m := (q2 + 1) & wmask
    s := p - w
    mc := self.konst(ty, i64(m))
    t := self.mk(MulHiU, ty, vec_of([]i64{n, mc}))
    if !add {
        if s == 0 {
            return t
        }
        sc := self.konst(ty, s)
        return self.mk(LShr, ty, vec_of([]i64{t, sc}))
    } else {
        diff := self.mk(Sub, ty, vec_of([]i64{n, t}))
        one := self.konst(ty, 1)
        half := self.mk(LShr, ty, vec_of([]i64{diff, one}))
        sum := self.mk(Add, ty, vec_of([]i64{half, t}))
        if s - 1 == 0 {
            return sum
        }
        sc := self.konst(ty, s - 1)
        return self.mk(LShr, ty, vec_of([]i64{sum, sc}))
    }
}

// signed division by a constant (Hacker's Delight, magic)
// All values fit 64 bits.
priv fn sdiv_magic(self: *Ctx, n: i64, ty: T, d: i64) -> i64 {
    w := i64(ty.bits())
    two_w1 := u64(1) << (w - 1)
    ad := uabs(d)
    t := two_w1
    if d < 0 {
        t = two_w1 + 1
    }
    anc := t - 1 - t % ad
    p := w - 1
    q1 := two_w1 / anc
    r1 := two_w1 - q1 * anc
    q2 := two_w1 / ad
    r2 := two_w1 - q2 * ad
    loop {
        p += 1
        q1 *= 2
        r1 *= 2
        if r1 >= anc {
            q1 += 1
            r1 -= anc
        }
        q2 *= 2
        r2 *= 2
        if r2 >= ad {
            q2 += 1
            r2 -= ad
        }
        delta := ad - r2
        if !(q1 < delta || (q1 == delta && r1 == 0)) {
            break
        }
    }
    wmask := mask(w)
    m := i64((q2 + 1) & wmask)
    m = ir_canon(ty, m)
    if d < 0 {
        m = ir_canon(ty, 0 - m)
    }
    s := p - w
    mc := self.konst(ty, m)
    q := self.mk(MulHiS, ty, vec_of([]i64{n, mc}))
    if d > 0 && m < 0 {
        q = self.mk(Add, ty, vec_of([]i64{q, n}))
    } else if d < 0 && m > 0 {
        q = self.mk(Sub, ty, vec_of([]i64{q, n}))
    }
    if s > 0 {
        sc := self.konst(ty, s)
        q = self.mk(AShr, ty, vec_of([]i64{q, sc}))
    }
    c := self.konst(ty, w - 1)
    sign := self.mk(LShr, ty, vec_of([]i64{q, c}))
    return self.mk(Add, ty, vec_of([]i64{q, sign}))
}

priv fn fold_insts(f: *Func) -> bool {
    rpo := f.rpo()
    // made at the first replacement
    repl := vec[i32]()
    nrepl := 0
    // The use counts are only read for an Xor or Or with two And arguments that are not new.
    // simplify never makes an Xor or Or of another op, and an old instruction becomes an And
    // only from a URem: without those at the start the counts are never read.
    has_xor_or := false
    has_and := false
    scan: for b in rpo {
        for v in f.blocks[b].insts {
            o := f.insts[v].op
            if o == Xor || o == Or {
                has_xor_or = true
            } else if o == And || o == URem {
                has_and = true
            }
            if has_xor_or && has_and {
                break scan
            }
        }
    }
    uses := vec[i32]()
    if has_xor_or && has_and {
        uses = f.use_counts()
    }
    cx := Ctx{f: f, new_insts: vec[i32](), changed: false, uses: uses}
    for b in rpo {
        // the new list of the block is built in cx.new_insts (one buffer for all blocks) and
        // copied back into the block's buffer when it fits
        old := cx.f.blocks[b].insts
        cx.f.blocks[b].insts = vec[i32]()
        cx.new_insts.clear()
        for v in old {
            for ai in 0..cx.f.insts[v].args.len {
                a := cx.f.insts[v].args[ai]
                r := repl_find(repl.items(), a)
                if r != a {
                    cx.f.insts[v].args[ai] = r
                }
            }
            match cx.simplify(i64(v)) {
                Some(w) => {
                    if repl.len < cx.f.insts.len {
                        repl.resize(cx.f.insts.len, NOV)
                    }
                    repl[v] = i32(w)
                    nrepl += 1
                    cx.changed = true
                }
                None => push_fast(&cx.new_insts, v)
            }
        }
        k := cx.new_insts.len
        if k <= len(old.buf) {
            memcopy(ptr(old.buf), ptr(cx.new_insts.buf), k * 4)
            old.len = k
            cx.f.blocks[b].insts = old
        } else {
            cx.f.blocks[b].insts = vec_of(cx.new_insts.items())
        }
    }
    changed := cx.changed
    if nrepl > 0 {
        repl.resize(f.insts.len, NOV)
        f.apply_repl(&repl)
    }
    return changed
}

// step 6: the block x is a tiny side-effect-free arm with one predecessor; where it jumps to
priv fn arm_target(f: *Func, preds: *Vec[Vec[i64]], x: i64) -> Opt[i64] {
    if preds[x].len != 1 || !may_side(f, x) {
        return None
    }
    return match f.blocks[x].term {
        Jmp(j) => Some(j)
        _ => None
    }
}

// all instructions of the block are phis
priv fn all_phis(f: *Func, binsts: *Vec[i32]) -> bool {
    for v in binsts {
        if f.insts[v].op != Phi {
            return false
        }
    }
    return true
}

// Cheap necessary conditions for a round of the steps of simplify_cfg to change anything: a
// round whose step cannot find a candidate block is not run (it would build its tables only
// to find nothing).

// the number of edges into each block
priv fn pred_counts(f: *Func) -> []i64 {
    n := f.blocks.len
    cnt := alloc[i64](n)
    for b in 0..n {
        k, s0, s1 := f.succ_pair(b)
        if k > 0 {
            cnt[s0] += 1
        }
        if k > 1 {
            cnt[s1] += 1
        }
    }
    return cnt
}

// the steps that may change something, as bits: 1 merge, 2 forward, 4 thread4, 8 thread5,
// 16 ifconv (what may_merge .. may_ifconv tell, in one pass over the blocks)
priv fn cfg_candidates(f: *Func) -> i64 {
    cnt := pred_counts(f)
    n := f.blocks.len
    bits := 0
    for b in 0..n {
        match f.blocks[b].term {
            Jmp(s) => {
                if s != 0 && s != b && cnt[s] == 1 {
                    bits |= 1
                }
                if b != 0 && s != b && f.blocks[b].insts.is_empty() {
                    bits |= 2
                }
            }
            Br(_, t, e) if t != e => {
                if bits & 16 == 0 && (may_side(f, t) || may_side(f, e)) {
                    bits |= 16
                }
                c, _, _ := phi_branch(f, b)
                if bits & 12 != 12 && c != NOV {
                    ci := &f.insts[c]
                    any_const := false
                    all_const := true
                    cfrom := ci.from()
                    for k in 0..cfrom.len {
                        p := cfrom[k]
                        is_const := f.insts[ci.args[k]].op == Const
                        if p != b && is_const {
                            any_const = true
                        }
                        if p == b || !is_const {
                            all_const = false
                        }
                    }
                    if any_const {
                        bits |= 4
                    }
                    if all_const && b != 0 {
                        bits |= 8
                    }
                }
            }
            _ => {}
        }
    }
    return bits
}

// step 2: a block jumps to another one (not the entry) that has no other predecessor
priv fn may_merge(f: *Func) -> bool {
    cnt := pred_counts(f)
    n := f.blocks.len
    for b in 0..n {
        match f.blocks[b].term {
            Jmp(s) if s != 0 && s != b && cnt[s] == 1 => return true
            _ => {}
        }
    }
    return false
}

// step 3: an empty block (not the entry) that jumps to another one
priv fn may_forward(f: *Func) -> bool {
    for e in 1..f.blocks.len {
        if f.blocks[e].insts.is_empty() {
            match f.blocks[e].term {
                Jmp(t) if t != e => return true
                _ => {}
            }
        }
    }
    return false
}

// the condition and the arms of block b's two-way branch when b holds only phis and branches
// on one of them (NOV, 0, 0 if not)
priv fn phi_branch(f: *Func, b: i64) -> (i64, i64, i64) {
    c, t, e := match f.blocks[b].term {
        Br(c1, t1, e1) if t1 != e1 && t1 != b && e1 != b => (c1, t1, e1)
        _ => return (NOV, 0, 0)
    }
    binsts := &f.blocks[b].insts
    if binsts.is_empty() || !all_phis(f, binsts) || !contains(binsts, i32(c)) {
        return (NOV, 0, 0)
    }
    return (c, t, e)
}

// step 4: such a block whose condition is a constant on some edge from another block
priv fn may_thread4(f: *Func) -> bool {
    for b in 0..f.blocks.len {
        c, _, _ := phi_branch(f, b)
        if c == NOV {
            continue
        }
        ci := &f.insts[c]
        cfrom := ci.from()
        for k in 0..cfrom.len {
            if cfrom[k] != b && f.insts[ci.args[k]].op == Const {
                return true
            }
        }
    }
    return false
}

// step 5: such a block (not the entry) whose condition is a constant on every edge from
// other blocks
priv fn may_thread5(f: *Func) -> bool {
    blocks: for b in 1..f.blocks.len {
        c, _, _ := phi_branch(f, b)
        if c == NOV {
            continue
        }
        ci := &f.insts[c]
        cfrom := ci.from()
        for k in 0..cfrom.len {
            if cfrom[k] == b || f.insts[ci.args[k]].op != Const {
                continue blocks
            }
        }
        return true
    }
    return false
}

// step 6: a two-way branch with an arm that may be a tiny side-effect-free block (the test of
// arm_target without the predecessor count)
priv fn may_ifconv(f: *Func) -> bool {
    for b in 0..f.blocks.len {
        match f.blocks[b].term {
            Br(_, t, e) if t != e => {
                if may_side(f, t) || may_side(f, e) {
                    return true
                }
            }
            _ => {}
        }
    }
    return false
}

priv fn may_side(f: *Func, x: i64) -> bool {
    if x == 0 {
        return false
    }
    match f.blocks[x].term {
        Jmp(_) => {}
        _ => return false
    }
    real := 0
    for v in f.blocks[x].insts {
        match f.insts[v].op {
            Const, FConst, GAddr, FAddr => {}
            Add, Sub, And, Or, Xor, Shl, LShr, AShr, SExt, ZExt, Trunc => real += 1
            _ => return false
        }
    }
    return real <= 2
}

priv fn simplify_cfg(f: *Func) -> bool {
    changed := false
    // 1. fold constant / degenerate branches
    for b in 0..f.blocks.len {
        match f.blocks[b].term {
            Br(c, t, e) => {
                if t == e {
                    f.blocks[b].term = Jmp(t)
                    changed = true
                    continue
                }
                ci := f.insts[c]
                if ci.op == Const {
                    f.blocks[b].term = Jmp(if ci.k != 0 { t } else { e })
                    changed = true
                } else if ci.op == Xor && f.is_const(ci.args[1]) == Some(1) && f.insts[ci.args[0]].ty == I8 {
                    // br !x, t, e  =>  br x, e, t  (x is a boolean)
                    x := ci.args[0]
                    if f.insts[x].op.is_cmp() {
                        f.blocks[b].term = Br(x, e, t)
                        changed = true
                    }
                }
            }
            _ => {}
        }
    }
    if cleanup_prune_unreachable(f) {
        changed = true
    }
    // One scan finds which steps have a candidate block; while no step has changed anything
    // (`scanned`), a step without one is not run (afterwards each round checks its own)
    cand := cfg_candidates(f)
    scanned := true
    // 2. merge straight-line blocks
    guard_merge := 0
    loop {
        guard_merge += 1
        if guard_merge > 20000 {
            eput(fmt("simplify_cfg: step merge does not converge in ", f.name, "\n"))
            break
        }
        if scanned {
            if cand & 1 == 0 {
                break
            }
        } else if !may_merge(f) {
            break
        }
        // per-round tables live on the scratch heap (see base.al)
        scratch_reset()
        // (the CFG analyses are kept for the next pass: not on the scratch heap)
        rpo, preds := f.rpo_preds()
        scratch_on()
        merged := false
        repl := vec_fill(f.insts.len, i32(NOV))
        nrepl := 0
        dead := vec_fill(f.blocks.len, false)
        scratch_off()
        for b in rpo {
            if dead[b] {
                continue
            }
            loop {
                s := match f.blocks[b].term {
                    Jmp(s1) => s1
                    _ => break
                }
                if s == 0 || s == b || preds[s].len != 1 || dead[s] {
                    break
                }
                sinsts := f.blocks[s].insts
                f.blocks[s].insts = vec[i32]()
                for v in sinsts {
                    if f.insts[v].op == Phi {
                        repl[v] = i32(f.insts[v].args[0])
                        nrepl += 1
                    } else {
                        f.blocks[b].insts.push(v)
                    }
                }
                st := f.blocks[s].term
                f.blocks[s].term = Term.None
                f.blocks[b].term = st
                dead[s] = true
                // successors of s now come from b
                nsucc, s0, s1 := f.succ_pair(b)
                for si in 0..nsucc {
                    f.phi_pred_replace(if si == 0 { s0 } else { s1 }, s, b)
                }
                merged = true
            }
        }
        if !merged {
            break
        }
        if nrepl > 0 {
            f.apply_repl(&repl)
        }
        changed = true
        scanned = false
    }
    // 3. skip empty forwarding blocks
    guard_forward := 0
    loop {
        guard_forward += 1
        if guard_forward > 20000 {
            eput(fmt("simplify_cfg: step forward does not converge in ", f.name, "\n"))
            break
        }
        if scanned {
            if cand & 2 == 0 {
                break
            }
        } else if !may_forward(f) {
            break
        }
        scratch_reset()
        rpo, preds := f.rpo_preds()
        did := false
        for e in rpo {
            if e == 0 || !f.blocks[e].insts.is_empty() {
                continue
            }
            t := match f.blocks[e].term {
                Jmp(t1) if t1 != e => t1
                _ => continue
            }
            t_has_phi := f.blocks[t].insts.len > 0 && f.insts[f.blocks[t].insts[0]].op == Phi
            for p in preds[e] {
                if p == e {
                    continue
                }
                if t_has_phi && contains(&preds[t], p) {
                    continue
                }
                // a conditional branch whose other arm already goes to t would need a select
                if t_has_phi {
                    match f.blocks[p].term {
                        Br(_, a, b2) if a == t || b2 == t => continue
                        _ => {}
                    }
                }
                // redirect p -> e to p -> t
                f.retarget(p, e, t)
                if t_has_phi {
                    for ii in 0..f.blocks[t].insts.len {
                        v := f.blocks[t].insts[ii]
                        if f.insts[v].op != Phi {
                            break
                        }
                        inst := f.im(i64(v))
                        k := index_of(inst.from(), e)
                        if k >= 0 {
                            val := inst.args[k]
                            inst.phi_add(val, p)
                        }
                    }
                }
                did = true
            }
            // keep going: edges into blocks not yet visited are only ever added this round
            // (stale `preds` are subsets), and a pred that now reaches t directly is caught by
            // its terminator; one block per round made long chains quadratic in time and memory
        }
        if !did {
            break
        }
        cleanup_prune_unreachable(f)
        changed = true
        scanned = false
    }
    // 4. thread jumps through blocks that only branch on a phi of constants
    guard_thread4 := 0
    loop {
        guard_thread4 += 1
        if !opt_enabled("thread4") {
            break
        }
        if guard_thread4 > 20000 {
            eput(fmt("simplify_cfg: step thread4 does not converge in ", f.name, "\n"))
            break
        }
        if scanned {
            if cand & 4 == 0 {
                break
            }
        } else if !may_thread4(f) {
            break
        }
        scratch_reset()
        rpo, preds := f.rpo_preds()
        scratch_on()
        uses := f.use_counts()
        // blocks whose edges or phis changed this round: their entries in preds / phi lists are
        // stale, so they wait for the next round (one threading per round made long chains of
        // `&&` / `||` quadratic in time and memory)
        touched := vec_fill(f.blocks.len, false)
        did := false
        scratch_off()
        blocks: for b in rpo {
            c, t, e := phi_branch(f, b)
            if c == NOV || touched[b] {
                continue
            }
            binsts := clone(f.blocks[b].insts)
            // the phis of b may only be used by its terminator and by phis of its successors
            phi_uses := vec_fill(binsts.len, 0)
            for s in [2]i64{t, e} {
                for v in f.blocks[s].insts {
                    i := f.insts[v]
                    if i.op != Phi {
                        break
                    }
                    ifrom := i.from()
                    for k in 0..i.args.len {
                        a := i.args[k]
                        if ifrom[k] == b {
                            pi := index_of(binsts.items(), i32(a))
                            if pi >= 0 {
                                phi_uses[pi] += 1
                            }
                        }
                    }
                }
            }
            for pi in 0..binsts.len {
                ph := binsts[pi]
                extra := 0
                if i64(ph) == c {
                    extra = 1
                }
                if i64(uses[ph]) != phi_uses[pi] + extra {
                    continue blocks
                }
            }
            cphi := f.insts[c]
            cfrom := cphi.from()
            for k in 0..cfrom.len {
                p := cfrom[k]
                kc := match f.is_const(cphi.args[k]) {
                    Some(x) => x
                    None => continue
                }
                if p == b || !contains(&preds[b], p) {
                    continue
                }
                target := if kc != 0 { t } else { e }
                if touched[p] || touched[target] {
                    continue
                }
                // p must not already reach the target directly (its phis would need two inputs)
                if contains(&preds[target], p) {
                    continue
                }
                // a conditional branch in p with both arms into b cannot be threaded simply
                match f.blocks[p].term {
                    Br(_, x, y) if x == b && y == b => continue
                    _ => {}
                }
                // new phi inputs in the target for the edge p -> target
                for ii in 0..f.blocks[target].insts.len {
                    v := f.blocks[target].insts[ii]
                    if f.insts[v].op != Phi {
                        break
                    }
                    inst := f.insts[v]
                    bk := index_of(inst.from(), b)
                    if bk >= 0 {
                        val := inst.args[bk]
                        // a phi of b seen through p is its input from p
                        nv := val
                        if contains(&binsts, i32(val)) {
                            vi := f.insts[val]
                            pk := index_of(vi.from(), p)
                            assert pk >= 0
                            nv = vi.args[pk]
                        }
                        f.im(i64(v)).phi_add(nv, p)
                        uses[nv] += 1
                    }
                }
                f.retarget(p, b, target)
                touched[b] = true
                touched[p] = true
                touched[target] = true
                did = true
                continue blocks
            }
        }
        if !did {
            break
        }
        cleanup_prune_unreachable(f)
        changed = true
        scanned = false
    }
    // the replacement of a value a defined in block b (a phi of b, binsts[k]) on the side of t
    // (side_t) or e
    fn fix(a: i64, def_block: *Vec[i32], b: i64, binsts: *Vec[i32], side_t: bool, repl_t: *Vec[i64], repl_e: *Vec[i64]) -> i64 {
        if a < def_block.len && i64(def_block[a]) == b {
            k := index_of(binsts.items(), i32(a))
            assert k >= 0
            return if side_t { repl_t[k] } else { repl_e[k] }
        }
        return a
    }
    // 5. a merge block that only re-tests a flag every predecessor sets to a constant:
    //    send each predecessor straight to its destination
    guard_thread5 := 0
    loop {
        guard_thread5 += 1
        if !opt_enabled("thread5") {
            break
        }
        if guard_thread5 > 20000 {
            eput(fmt("simplify_cfg: step thread5 does not converge in ", f.name, "\n"))
            break
        }
        if scanned {
            if cand & 8 == 0 {
                break
            }
        } else if !may_thread5(f) {
            break
        }
        scratch_reset()
        cfg := cfg_new(f)
        scratch_on()
        def_block := f.block_of()
        scratch_off()
        did := false
        blocks2: for b in cfg.rpo {
            c, t, e := phi_branch(f, b)
            if b == 0 || c == NOV {
                continue
            }
            binsts := clone(f.blocks[b].insts)
            if cfg.preds[t].len != 1 || cfg.preds[e].len != 1 || cfg.preds[b].len < 2 {
                continue
            }
            cphi := f.insts[c]
            dest := vec[(i64, i64)]()
            cfrom := cphi.from()
            for k in 0..cfrom.len {
                p := cfrom[k]
                kc := match f.is_const(cphi.args[k]) {
                    Some(x) => x
                    None => continue blocks2
                }
                if p == b {
                    continue blocks2
                }
                match f.blocks[p].term {
                    Br(_, x, y) if x == b && y == b => {
                        continue blocks2
                    }
                    _ => {}
                }
                dest.push((p, if kc != 0 { t } else { e }))
            }
            if dest.len != cfg.preds[b].len {
                continue
            }
            // every use of b's phis must be dominated by t or by e
            for bb in 0..f.blocks.len {
                if !cfg.reachable(bb) || bb == b {
                    continue
                }
                for v in f.blocks[bb].insts {
                    i := f.insts[v]
                    for k in 0..i.args.len {
                        a := i.args[k]
                        if i64(def_block[a]) == b {
                            at := bb
                            if i.op == Phi {
                                at = i.from()[k]
                            }
                            if !(cfg.dom(t, at) || cfg.dom(e, at)) {
                                continue blocks2
                            }
                        }
                    }
                }
                for a in term_args(&f.blocks[bb].term) {
                    if i64(def_block[a]) == b && !(cfg.dom(t, bb) || cfg.dom(e, bb)) {
                        continue blocks2
                    }
                }
            }
            // build the replacement values of b's phis on each side
            repl_t := vec[i64]()
            repl_e := vec[i64]()
            for side in 0..2 {
                s := if side == 0 { t } else { e }
                ps := vec[i64]()
                for d in dest {
                    if d.1 == s {
                        ps.push(d.0)
                    }
                }
                for ph in binsts {
                    pi := f.insts[ph]
                    vals := vec[i64]()
                    for p in ps {
                        pk := index_of(pi.from(), p)
                        assert pk >= 0
                        vals.push(pi.args[pk])
                    }
                    nv := i64(ph)
                    if !ps.is_empty() {
                        all_same := true
                        for x in vals {
                            if x != vals[0] {
                                all_same = false
                                break
                            }
                        }
                        if all_same {
                            nv = vals[0]
                        } else {
                            np := f.mk_phi_of(pi.ty, vals.items(), ps.items())
                            f.blocks[s].insts.insert(0, i32(np))
                            nv = np
                        }
                    }
                    if side == 0 {
                        repl_t.push(nv)
                    } else {
                        repl_e.push(nv)
                    }
                }
            }
            // rewrite uses
            for bb in 0..f.blocks.len {
                if !cfg.reachable(bb) || bb == b {
                    continue
                }
                for ii in 0..f.blocks[bb].insts.len {
                    v := f.blocks[bb].insts[ii]
                    if i64(v) >= def_block.len {
                        continue
                    }
                    for ai in 0..f.insts[v].args.len {
                        a := f.insts[v].args[ai]
                        if a < def_block.len && i64(def_block[a]) == b {
                            at := bb
                            if f.insts[v].op == Phi {
                                at = f.insts[v].from()[ai]
                            }
                            k := index_of(binsts.items(), i32(a))
                            assert k >= 0
                            if cfg.dom(t, at) {
                                f.insts[v].args[ai] = repl_t[k]
                            } else {
                                f.insts[v].args[ai] = repl_e[k]
                            }
                        }
                    }
                }
                side_t := cfg.dom(t, bb)
                match f.blocks[bb].term {
                    Br(&cc, _, _) => {
                        *cc = fix(*cc, &def_block, b, &binsts, side_t, &repl_t, &repl_e)
                    }
                    Ret(vs) => {
                        // vs shares its buffer with the terminator
                        for vi in 0..vs.len {
                            vs[vi] = fix(vs[vi], &def_block, b, &binsts, side_t, &repl_t, &repl_e)
                        }
                    }
                    _ => {}
                }
            }
            // retarget the predecessors
            for d in dest {
                f.retarget(d.0, b, d.1)
            }
            did = true
            break
        }
        if !did {
            break
        }
        cleanup_prune_unreachable(f)
        changed = true
        scanned = false
    }
    // 6. if-conversion: tiny side-effect-free arms become selects (conditional moves)
    loop {
        if !opt_enabled("ifconv") {
            break
        }
        if scanned {
            if cand & 16 == 0 {
                break
            }
        } else if !may_ifconv(f) {
            break
        }
        scratch_reset()
        rpo, preds := f.rpo_preds()
        did := false
        for b in rpo {
            c, t, e := match f.blocks[b].term {
                Br(c1, t1, e1) if t1 != e1 => (c1, t1, e1)
                _ => continue
            }
            // the arms hoisted into b (an arm that is b itself: none) and the join
            from_t, from_e, j := match (arm_target(f, &preds, t), arm_target(f, &preds, e)) {
                (Some(j1), Some(j2)) if j1 == j2 && j1 != t && j1 != e => (t, e, j1)
                (Some(j1), _) if j1 == e => (t, b, e)
                (_, Some(j2)) if j2 == t => (b, e, t)
                _ => continue
            }
            if j == b || j == 0 {
                continue
            }
            // the join's phis decide whether this is worth it
            phis := vec[i64]()
            for v in f.blocks[j].insts {
                if f.insts[v].op != Phi {
                    break
                }
                phis.push(i64(v))
            }
            pairs := vec[(i64, i64, i64)]()
            ok := true
            selects := 0
            for ph in phis {
                i := f.insts[ph]
                kt := index_of(i.from(), from_t)
                ke := index_of(i.from(), from_e)
                if kt >= 0 && ke >= 0 {
                    vt := i.args[kt]
                    ve := i.args[ke]
                    if vt != ve {
                        if !i.ty.is_int() {
                            ok = false
                        }
                        selects += 1
                    }
                    pairs.push((ph, vt, ve))
                } else {
                    ok = false
                }
            }
            if !ok || selects == 0 || selects > 2 {
                continue
            }
            // hoist both arms into b and merge the values with selects
            for x in [2]i64{from_t, from_e} {
                if x != b {
                    moved := f.blocks[x].insts
                    f.blocks[x].insts = vec[i32]()
                    f.blocks[b].insts.extend(moved.items())
                }
            }
            for pr in pairs {
                ph, vt, ve := pr
                ty := f.insts[ph].ty
                nv := if vt != ve { f.push(b, Select, ty, vec_of([]i64{c, vt, ve}), 0) } else { vt }
                i := f.im(ph)
                k := 0
                while k < i.args.len {
                    p := i.from()[k]
                    if p == from_t || p == from_e {
                        i.phi_remove(k)
                    } else {
                        k += 1
                    }
                }
                i.phi_add(nv, b)
            }
            f.blocks[b].term = Jmp(j)
            // keep going: the stale `preds` only over-count (a join loses its arms and gains b),
            // so later candidates are judged conservatively; one conversion per round made long
            // if-chains quadratic in time and memory
            did = true
        }
        if !did {
            break
        }
        cleanup_prune_unreachable(f)
        changed = true
        scanned = false
    }
    // normalize `br c, t, t`
    for b in 0..f.blocks.len {
        match f.blocks[b].term {
            Br(_, t, e) if t == e => {
                f.blocks[b].term = Jmp(t)
                changed = true
            }
            _ => {}
        }
    }
    return changed
}

fn simplify_run(f: *Func) -> bool {
    any := false
    for it in 0..50 {
        ch := false
        opt_trace("  fold", f)
        if opt_pass(7, f, fold_insts) {
            ch = true
        }
        opt_trace("  cfg", f)
        if opt_pass(PASS_CFG, f, simplify_cfg) {
            ch = true
        }
        opt_trace("  phis", f)
        if opt_pass(PASS_PHIS, f, cleanup_trivial_phis) {
            ch = true
        }
        opt_trace("  dce", f)
        if opt_pass(PASS_DCE, f, cleanup_dce) {
            ch = true
        }
        if !ch {
            break
        }
        any = true
    }
    return any
}
