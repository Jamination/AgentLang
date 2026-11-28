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
            MemCpy, MemSet, Atomic => return None
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
            // a shift or rotation count is taken modulo bits: (n & m) with m's low bits all
            // set is n, (n + c) with c a multiple of bits is n, (c - n) is (0 - n)
            if !hk && (op == Shl || op == LShr || op == AShr || op == Rotl || op == Rotr) {
                bi := &self.f.insts[b]
                bt := bi.ty
                if bi.op == And && self.c(bi.args[1]).or(0) & (bits - 1) == bits - 1 {
                    self.set(v, op, vec_of([]i64{a, bi.args[0]}), 0)
                    return None
                }
                if bi.op == Add && is_some(self.c(bi.args[1])) && self.c(bi.args[1]).or(1) & (bits - 1) == 0 {
                    self.set(v, op, vec_of([]i64{a, bi.args[0]}), 0)
                    return None
                }
                if bi.op == Sub && is_some(self.c(bi.args[0])) && self.c(bi.args[0]).or(0) != 0 &&
                    self.c(bi.args[0]).or(1) & (bits - 1) == 0 {
                    n := bi.args[1]
                    z := self.konst(bt, 0)
                    neg := self.mk(Sub, bt, vec_of([]i64{z, n}))
                    self.set(v, op, vec_of([]i64{a, neg}), 0)
                    return None
                }
            }
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
            // x & m where m keeps every bit x can have (u32(byte) & 0xFF): x
            if hk && op == And && k > 0 {
                ub := self.ubits(a, 6)
                if ub < 63 && u64(k) & mask(ub) == mask(ub) {
                    return Some(a)
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
            // the last step of a byte swap by a ladder of masked shifts (a rotation by half)
            if hk && (op == Rotl || op == Rotr) && self.match_bytes(v, ty) {
                return None
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
                match self.match_rotate(a, b, ty, op == Or) {
                    Some((rop, x, n)) => {
                        self.set(v, rop, vec_of([]i64{x, n}), 0)
                        return None
                    }
                    None => {}
                }
                // byte swaps by shifts and masks, values put together from loaded bytes
                if self.match_bytes(v, ty) {
                    return None
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
            // a comparison the range of a decides (`x & 63 <u 64`, `zext(u8) <u 256`)
            match self.range_cmp(op, a, at, k) {
                Some(r) => {
                    self.set_const(v, i64(r))
                    return None
                }
                None => {}
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
            // the sign of a value whose top bit is known to be 0: x >= 0 (x > -1) is true,
            // x < 0 (x <= -1) is false
            if ((k == 0 && (op == Sge || op == Slt)) || (k == -1 && (op == Sgt || op == Sle))) &&
                self.ubits(a, 6) < i64(at.bits()) {
                self.set_const(v, i64(op == Sge || op == Sgt))
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
            // ((x >>> s) & 1) == 0  =>  (x & (1 << s)) == 0 (a test of x with a constant)
            if (op == Eq || op == Ne) && k == 0 && ai.op == And && self.c(ai.args[1]) == Some(1) {
                si := &self.f.insts[ai.args[0]]
                sk := if si.op == LShr || si.op == AShr { self.c(si.args[1]).or(-1) } else { -1 }
                bits := i64(at.bits())
                if sk >= 0 && sk & (bits - 1) < 31 {
                    x := si.args[0]
                    bk := i64(1) << (sk & (bits - 1))
                    zk := b
                    mk := self.konst(at, bk)
                    m := self.mk(And, at, vec_of([]i64{x, mk}))
                    self.set(v, op, vec_of([]i64{m, zk}), 0)
                    return None
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
            if op == ZExt && self.set_carry(v, a, ty) {
                return None
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
            if self.c(a) == Some(1) && self.c(b) == Some(0) && self.set_carry(v, c, ty) {
                return None
            }
            if opt_enabled("selfold") {
                // a select on the negation of a boolean selects the other way round (as
                // if-conversion inside an inlined `(T, bool)` function leaves them)
                ci := &self.f.insts[c]
                if ci.ty == I8 && ci.args.len == 2 {
                    x := ci.args[0]
                    y := ci.args[1]
                    neg := NOV
                    if ci.op == Sub && self.c(x) == Some(1) && is_bool(self.f, y, 2) {
                        neg = y
                    } else if ci.op == Xor && self.c(y) == Some(1) && is_bool(self.f, x, 2) {
                        neg = x
                    } else if ci.op == Eq && self.c(y) == Some(0) && is_bool(self.f, x, 2) {
                        neg = x
                    }
                    if neg != NOV {
                        self.set(v, Select, vec_of([]i64{neg, b, a}), 0)
                        return None
                    }
                }
                // an arm that is a select on the same condition takes its side of it
                ai := &self.f.insts[a]
                bi := &self.f.insts[b]
                if ai.op == Select && ai.args[0] == c {
                    self.set(v, Select, vec_of([]i64{c, ai.args[1], b}), 0)
                    return None
                }
                if bi.op == Select && bi.args[0] == c {
                    self.set(v, Select, vec_of([]i64{c, a, bi.args[2]}), 0)
                    return None
                }
            }
            return None
        }
        Carry => {
            s := inst.args[0]
            a := inst.args[1]
            match (self.c(s), self.c(a)) {
                (Some(x), Some(y)) => {
                    self.set_const(v, i64(unwrap(simplify_fold_icmp(Ult, ty, x, y))))
                    return None
                }
                (_, Some(0)) => {
                    self.set_const(v, 0)
                    return None
                }
                _ => {}
            }
            if s == a {
                self.set_const(v, 0)
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

// ---------- value ranges for comparisons with constants ----------
// An upper bound on v read as an unsigned number of the width of its type. Every rule holds
// in wrapping arithmetic: a sum or product counts only when it cannot pass the top of the type.
priv fn umax(self: *Ctx, v: i64, depth: i64) -> u64 {
    i := &self.f.insts[v]
    if !i.ty.is_int() {
        return ~u64(0)
    }
    tb := i64(i.ty.bits())
    m := mask(tb)
    if depth == 0 {
        return m
    }
    r: u64 = m
    match i.op {
        Const => r = u64(i.k) & m
        And => r = min(self.umax(i.args[0], depth - 1), self.umax(i.args[1], depth - 1))
        Or, Xor => {
            // below the next power of two of the larger one
            x := max(self.umax(i.args[0], depth - 1), self.umax(i.args[1], depth - 1))
            r = if x == 0 { u64(0) } else { mask(64 - i64(clz(x))) }
        }
        LShr => match self.c(i.args[1]) {
            Some(k) => r = self.umax(i.args[0], depth - 1) >> u64(k & (tb - 1))
            None => {}
        }
        Shl => match self.c(i.args[1]) {
            Some(k) => {
                s := k & (tb - 1)
                x := self.umax(i.args[0], depth - 1)
                if x <= m >> u64(s) {
                    r = x << u64(s)
                }
            }
            None => {}
        }
        ZExt => r = self.umax(i.args[0], depth - 1) & mask(i64(self.f.insts[i.args[0]].ty.bits()))
        URem => match self.c(i.args[1]) {
            Some(k) if u64(k) & m != 0 => r = min(self.umax(i.args[0], depth - 1), (u64(k) & m) - 1)
            _ => {}
        }
        UDiv => match self.c(i.args[1]) {
            Some(k) if u64(k) & m != 0 => r = self.umax(i.args[0], depth - 1) / (u64(k) & m)
            _ => {}
        }
        Add => {
            x := self.umax(i.args[0], depth - 1)
            y := self.umax(i.args[1], depth - 1)
            if x <= m - y {
                r = x + y
            }
        }
        Mul => {
            x := self.umax(i.args[0], depth - 1)
            y := self.umax(i.args[1], depth - 1)
            if x == 0 || y <= m / x {
                r = x * y
            }
        }
        Select => r = max(self.umax(i.args[1], depth - 1), self.umax(i.args[2], depth - 1))
        Phi => {
            if i.args.len <= 8 {
                r = 0
                for a in i.args {
                    if a != v {
                        r = max(r, self.umax(a, depth - 1))
                    }
                }
            }
        }
        Popcnt => r = u64(tb)
        _ => {
            if i.op.is_cmp() {
                r = 1
            }
        }
    }
    return min(r, m)
}

// The value of `a op k` (k a constant) when the range of a decides it
priv fn range_cmp(self: *Ctx, op: Op, a: i64, at: T, k: i64) -> Opt[bool] {
    if !at.is_int() {
        return None
    }
    signed := op == Slt || op == Sle || op == Sgt || op == Sge
    if !signed && op != Ult && op != Ule && op != Ugt && op != Uge {
        return None
    }
    tb := i64(at.bits())
    m := mask(tb)
    hi := self.umax(a, 6)
    if hi == m {
        return None
    }
    if signed {
        // a is not negative when its bound is below the sign bit; then a lies in 0..=hi
        if hi > m >> 1 {
            return None
        }
        // (k is sign-extended)
        sh := i64(hi)
        return match op {
            Slt => if k > sh { Some(true) } else if k <= 0 { Some(false) } else { None }
            Sle => if k >= sh { Some(true) } else if k < 0 { Some(false) } else { None }
            Sgt => if k >= sh { Some(false) } else if k < 0 { Some(true) } else { None }
            _ => if k > sh { Some(false) } else if k <= 0 { Some(true) } else { None }
        }
    }
    uk := u64(k) & m
    return match op {
        Ult => if hi < uk { Some(true) } else { None }
        Ule => if hi <= uk { Some(true) } else { None }
        Ugt => if hi <= uk { Some(false) } else { None }
        _ => if hi < uk { Some(false) } else { None }
    }
}

// `var_ok`: the combining op is Or. With a variable count n that is 0 modulo bits both
// shifts give x: x | x is the rotation, but x ^ x and x + x are not
priv fn match_rotate(self: *Ctx, a: i64, b: i64, ty: T, var_ok: bool) -> Opt[(Op, i64, i64)] {
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
    if !var_ok {
        return None
    }
    if is_complement(self, bits, nl, nr) {
        return Some((Rotr, x, nr))
    }
    if is_complement(self, bits, nr, nl) {
        return Some((Rotl, x, nl))
    }
    return None
}

// v (of type ty) is 1 if the compare c holds, else 0: when c is s <u a (or a >u s) with
// s = a + x, v becomes Carry(s, a), the carry out of that addition. True if rewritten.
priv fn set_carry(self: *Ctx, v: i64, c: i64, ty: T) -> bool {
    ci := &self.f.insts[c]
    s, a := match ci.op {
        Ult => (ci.args[0], ci.args[1])
        Ugt => (ci.args[1], ci.args[0])
        _ => return false
    }
    si := &self.f.insts[s]
    if si.op != Add || si.ty != ty || (ty != I32 && ty != I64) || (si.args[0] != a && si.args[1] != a) {
        return false
    }
    self.set(v, Carry, vec_of([]i64{s, a}), 0)
    return true
}

// ---------- byte swaps and combined byte loads ----------
// The provenance of the bits of an integer value built with shifts by constants, masks,
// zero-extensions and the disjoint or (|, or ^ and + where no bit is set on both sides) of
// such values: for each bit j, l * 64 + b when it is bit b of leaf l (one of at most 8
// values the expression starts from), -1 when it is known to be 0. `budget` limits the
// number of instructions looked at.
priv fn prov(self: *Ctx, v: i64, depth: i64, budget: *i64, leaves: *Vec[i64], out: *[64]i16) -> bool {
    i := &self.f.insts[v]
    w := i64(i.ty.bits())
    if !i.ty.is_int() || *budget <= 0 {
        return false
    }
    *budget -= 1
    for j in 0..64 {
        out[j] = -1
    }
    op := i.op
    if depth > 0 {
        match op {
            Const => return i.k == 0
            Or, Xor, Add => {
                q: [64]i16
                if !self.prov(i.args[0], depth - 1, budget, leaves, out) ||
                    !self.prov(i.args[1], depth - 1, budget, leaves, &q) {
                    return false
                }
                for j in 0..w {
                    if q[j] >= 0 {
                        if out[j] >= 0 {
                            return false
                        }
                        out[j] = q[j]
                    }
                }
                return true
            }
            And, Shl, LShr if is_some(self.c(i.args[1])) => {
                k := self.c(i.args[1]).or(0)
                q: [64]i16
                if !self.prov(i.args[0], depth - 1, budget, leaves, &q) {
                    return false
                }
                s := k & (w - 1)
                for j in 0..w {
                    out[j] = match op {
                        And => if (u64(k) >> u64(j)) & 1 != 0 { q[j] } else { -1 }
                        Shl => if j >= s { q[j - s] } else { -1 }
                        _ => if j + s < w { q[j + s] } else { -1 }
                    }
                }
                return true
            }
            ZExt, Trunc => {
                src := i.args[0]
                sw := i64(self.f.insts[src].ty.bits())
                q: [64]i16
                if !self.prov(src, depth - 1, budget, leaves, &q) {
                    return false
                }
                for j in 0..min(w, sw) {
                    out[j] = q[j]
                }
                return true
            }
            Bswap => {
                q: [64]i16
                if !self.prov(i.args[0], depth - 1, budget, leaves, &q) {
                    return false
                }
                for j in 0..w {
                    out[j] = q[(w / 8 - 1 - j / 8) * 8 + j % 8]
                }
                return true
            }
            Rotl, Rotr if is_some(self.c(i.args[1])) => {
                q: [64]i16
                if !self.prov(i.args[0], depth - 1, budget, leaves, &q) {
                    return false
                }
                s := self.c(i.args[1]).or(0) & (w - 1)
                for j in 0..w {
                    out[j] = if op == Rotr { q[(j + s) & (w - 1)] } else { q[(j - s) & (w - 1)] }
                }
                return true
            }
            _ => {}
        }
    }
    // a leaf
    li := -1
    for k in 0..leaves.len {
        if leaves[k] == v {
            li = k
        }
    }
    if li < 0 {
        if leaves.len >= 8 {
            return false
        }
        leaves.push(v)
        li = leaves.len - 1
    }
    for j in 0..w {
        out[j] = i16(li * 64 + j)
    }
    return true
}

// The byte swap or the wide load that the bits of v (an Or, Xor or Add of type ty) are, if
// they are one: all bytes of the low 2, 4 or 8 bytes of a value in reverse order (above them
// zeros), or bytes loaded from consecutive addresses (little-endian: one load; big-endian: a
// load and a byte swap). Rewrites v and returns true.
priv fn match_bytes(self: *Ctx, v: i64, ty: T) -> bool {
    w := i64(ty.bits())
    i := &self.f.insts[v]
    // cheap filter: both operands are shifts, masks, extensions or such combinations
    fn part(op: Op) -> bool {
        match op {
            Shl, LShr, And, Or, Xor, Add, ZExt, Bswap, Rotl, Rotr => true
            _ => false
        }
    }
    rot := i.op == Rotl || i.op == Rotr
    if w < 16 || !part(self.op(i.args[0])) || !(rot || part(self.op(i.args[1]))) {
        return false
    }
    leaves := vec[i64]()
    pos: [64]i16
    budget := 48
    if !self.prov(v, 16, &budget, &leaves, &pos) {
        return false
    }
    // n: the number of low bytes that are not all zeros
    n := 0
    for j in 0..w {
        if pos[j] >= 0 {
            n = j / 8 + 1
        }
    }
    nb := if n <= 2 { 2 } else if n <= 4 { 4 } else { 8 }
    if n < 2 || nb > w / 8 {
        return false
    }
    nt := match nb {
        2 => T.I16
        4 => T.I32
        _ => T.I64
    }
    // a byte swap of the low nb bytes of the one leaf
    if leaves.len == 1 {
        x := leaves[0]
        xt := self.f.insts[x].ty
        if i64(xt.bits()) < nb * 8 {
            return false
        }
        for j in 0..nb * 8 {
            if i64(pos[j]) != (nb - 1 - j / 8) * 8 + j % 8 {
                return false
            }
        }
        src := x
        if xt != nt {
            src = self.mk(Trunc, nt, vec_of([]i64{x}))
        }
        if nt == ty {
            self.set(v, Bswap, vec_of([]i64{src}), 0)
        } else {
            bs := self.mk(Bswap, nt, vec_of([]i64{src}))
            self.set(v, ZExt, vec_of([]i64{bs}), 0)
        }
        return true
    }
    // loads: every byte j is a whole byte of a leaf load, at address base + off(j)
    base := -1
    class: i32 = 0
    offs: [8]i64
    for j in 0..nb {
        p := i64(pos[8 * j])
        if p < 0 {
            return false
        }
        l := p / 64
        b := p % 64
        if b % 8 != 0 {
            return false
        }
        for t in 1..8 {
            if i64(pos[8 * j + t]) != p + t {
                return false
            }
        }
        li := &self.f.insts[leaves[l]]
        if li.op != Load {
            return false
        }
        a := li.args[0]
        o := 0
        ai := &self.f.insts[a]
        if ai.op == Add && is_some(self.c(ai.args[1])) {
            o = self.c(ai.args[1]).or(0)
            a = ai.args[0]
        }
        if j == 0 {
            base = a
            class = li.aux
        } else if a != base || li.aux != class {
            return false
        }
        offs[j] = o + b / 8
    }
    little := true
    big := true
    for j in 0..nb {
        if offs[j] != offs[0] + j {
            little = false
        }
        if offs[j] != offs[0] - j {
            big = false
        }
    }
    if !little && !big {
        return false
    }
    // the loads are in this block with no store or call between them and v
    found := 0
    k := self.new_insts.len - 1
    while found < leaves.len {
        if k < 0 || self.new_insts.len - k > 256 {
            return false
        }
        u := i64(self.new_insts[k])
        o := self.op(u)
        if o == Store || o.clobbers() {
            return false
        }
        if contains(&leaves, u) {
            found += 1
        }
        k -= 1
    }
    // the address of the lowest byte
    lo := if little { 0 } else { nb - 1 }
    lp := i64(pos[8 * lo])
    ll := &self.f.insts[leaves[lp / 64]]
    addr := ll.args[0]
    if lp % 64 != 0 {
        // (a byte inside a wider leaf load: its address plus that byte's offset)
        ok := self.konst(I64, (lp % 64) / 8)
        addr = self.mk(Add, I64, vec_of([]i64{addr, ok}))
    }
    if nt == ty && little {
        self.set(v, Load, vec_of([]i64{addr}), 0)
        self.f.im(v).aux = class
        return true
    }
    ld := self.mk(Load, nt, vec_of([]i64{addr}))
    self.f.im(ld).aux = class
    if nt == ty {
        self.set(v, Bswap, vec_of([]i64{ld}), 0)
        return true
    }
    x := ld
    if big {
        x = self.mk(Bswap, nt, vec_of([]i64{ld}))
    }
    self.set(v, ZExt, vec_of([]i64{x}), 0)
    return true
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
        for i in 0..if k == 0 { f.nsucc(b) } else { 0 } {
            cnt[f.succ_at(b, i)] += 1
        }
    }
    return cnt
}

// the steps that may change something, as bits: 1 merge, 2 forward, 4 thread4, 8 thread5,
// 16 ifconv, 32 thread6 (what may_merge .. may_ifconv, may_thread6 tell, in one pass over the
// blocks)
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
                if bits & 32 == 0 && may_thread6_at(f, b) {
                    bits |= 32
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
    return arm_cost(f, x) <= IFC_ARM_MAX
}

// step 5b: at most this many instructions (besides phis) are copied for an edge, and at most
// this many edges are threaded in one run of simplify_cfg
const THREAD6_DUP = 6
const THREAD6_ROUNDS = 200

// step 5b: block b (not the entry) ends in a two-way branch on a phi of b or on a compare of
// phis of b and constants, and holds besides its phis only a few instructions that may be copied
priv fn thread6_block(f: *Func, b: i64) -> bool {
    c, t, e := match f.blocks[b].term {
        Br(c1, t1, e1) if t1 != e1 && t1 != b && e1 != b => (c1, t1, e1)
        _ => return false
    }
    binsts := &f.blocks[b].insts
    n := 0
    has_c := false
    for v in binsts {
        i := &f.insts[v]
        if i64(v) == c {
            has_c = true
        }
        if i.op == Phi {
            continue
        }
        n += 1
        if n > THREAD6_DUP || !(i.op == Load || (i.op.is_pure() && i.op != Alloca)) {
            return false
        }
    }
    if !has_c {
        return false
    }
    ci := &f.insts[c]
    if ci.op == Phi {
        return true
    }
    if !ci.op.is_icmp() {
        return false
    }
    phis := 0
    for a in ci.args {
        ai := &f.insts[a]
        if ai.op == Phi && contains(binsts, i32(a)) {
            phis += 1
        } else if ai.op != Const {
            return false
        }
    }
    return phis > 0
}

// a cheap test that step 5b may find something at block b: its branch is of the kind and some
// phi it depends on has a constant input
priv fn may_thread6_at(f: *Func, b: i64) -> bool {
    if b == 0 || !thread6_block(f, b) {
        return false
    }
    c := match f.blocks[b].term {
        Br(c1, _, _) => c1
        _ => return false
    }
    ci := &f.insts[c]
    if ci.op == Phi {
        for a in ci.args {
            if f.insts[a].op == Const {
                return true
            }
        }
        return false
    }
    for a in ci.args {
        if f.insts[a].op == Phi {
            for x in f.insts[a].args {
                if f.insts[x].op == Const {
                    return true
                }
            }
        }
    }
    return false
}

priv fn may_thread6(f: *Func) -> bool {
    for b in 1..f.blocks.len {
        if may_thread6_at(f, b) {
            return true
        }
    }
    return false
}

// the value of b's branch condition c when b is entered from p, if that edge decides it
priv fn edge_value(f: *Func, b: i64, c: i64, p: i64) -> Opt[i64] {
    fn input(f: *Func, b: i64, a: i64, p: i64) -> i64 {
        if f.insts[a].op == Phi && contains(&f.blocks[b].insts, i32(a)) {
            return f.insts[a].phi_input(p)
        }
        return a
    }
    ci := f.insts[c]
    if ci.op == Phi {
        x := ci.phi_input(p)
        if x == NOV {
            return None
        }
        return f.is_const(x)
    }
    x := input(f, b, ci.args[0], p)
    y := input(f, b, ci.args[1], p)
    if x == NOV || y == NOV {
        return None
    }
    kx := match f.is_const(x) {
        Some(k) => k
        None => return None
    }
    ky := match f.is_const(y) {
        Some(k) => k
        None => return None
    }
    m := mask(i64(f.insts[ci.args[0]].ty.bits()))
    ux := u64(kx) & m
    uy := u64(ky) & m
    r := match ci.op {
        Eq => ux == uy
        Ne => ux != uy
        Slt => kx < ky
        Sle => kx <= ky
        Sgt => kx > ky
        Sge => kx >= ky
        Ult => ux < uy
        Ule => ux <= uy
        Ugt => ux > uy
        _ => ux >= uy
    }
    return Some(if r { 1 } else { 0 })
}

// step 5b: the edge p -> b goes to a new block that holds copies of b's instructions (b's phis
// read as their inputs from p) and jumps to target; the uses of b's values elsewhere read the
// value that reaches them (new phis where b's and the copies' values meet)
priv fn thread_dup(f: *Func, b: i64, p: i64, target: i64) {
    nold := f.insts.len
    def_block := f.block_of()
    binsts := clone(f.blocks[b].insts)
    m := vec_fill(nold, NOV)
    n := f.new_block()
    for v in binsts {
        i := f.insts[v]
        if i.op == Phi {
            m[v] = i.phi_input(p)
            continue
        }
        args := vec[i64]()
        for a in i.args {
            args.push(if m[a] != NOV { m[a] } else { a })
        }
        nv := f.push(n, i.op, i.ty, args, i.k)
        f.insts[nv].aux = i.aux
        f.insts[nv].cap = i.cap
        m[v] = nv
    }
    f.blocks[n].term = Jmp(target)
    for v in f.blocks[target].insts {
        if f.insts[v].op != Phi {
            break
        }
        x := f.insts[v].phi_input(b)
        f.im(i64(v)).phi_add(if x < nold && m[x] != NOV { m[x] } else { x }, n)
    }
    f.retarget(p, b, n)
    for v in binsts {
        if f.insts[v].op != Phi {
            break
        }
        k := index_of(f.insts[v].from(), p)
        if k >= 0 {
            f.im(i64(v)).phi_remove(k)
        }
    }
    // the uses of b's values outside b and n: (block, instruction or NOV for the terminator,
    // operand index, the block the value must reach the end of: a phi's input block, else the
    // using block, which then has no definition of its own)
    sites := vec[(i64, i64, i64, i64)]()
    for bb in 0..f.blocks.len {
        if bb == b || bb == n {
            continue
        }
        for v in f.blocks[bb].insts {
            i := &f.insts[v]
            for ai in 0..i.args.len {
                a := i.args[ai]
                if a < nold && i64(def_block[a]) == b {
                    sites.push((bb, i64(v), ai, if i.op == Phi { i.from()[ai] } else { bb }))
                }
            }
        }
        ta := term_args(&f.blocks[bb].term)
        for ai in 0..len(ta) {
            a := ta[ai]
            if a < nold && i64(def_block[a]) == b {
                sites.push((bb, NOV, ai, bb))
            }
        }
    }
    if sites.is_empty() {
        return
    }
    preds := cfg_preds(f)
    // the value of x reaching the end of block blk: memo per block, phis made on demand
    // (pending: phis whose inputs are still to be filled)
    memo := vec_fill(f.blocks.len, NOV)
    pending := vec[(i64, i64)]()
    fn read(f: *Func, x: i64, xn: i64, b: i64, n: i64, blk0: i64, preds: *Vec[Vec[i64]], memo: *Vec[i64], pending: *Vec[(i64, i64)]) -> i64 {
        chain := vec[i64]()
        blk := blk0
        val := x
        loop {
            if blk == b {
                val = x
                break
            }
            if blk == n {
                val = xn
                break
            }
            if memo[blk] != NOV {
                val = memo[blk]
                break
            }
            ps := &preds[blk]
            if ps.len == 1 {
                chain.push(blk)
                blk = ps[0]
                continue
            }
            if ps.len == 0 {
                // (not reached from the entry without passing b or n)
                val = x
                break
            }
            ph := f.mk_phi(f.insts[x].ty, ps.len)
            f.blocks[blk].insts.insert(0, i32(ph))
            memo[blk] = ph
            pending.push((blk, ph))
            val = ph
            break
        }
        for cb in chain {
            memo[cb] = val
        }
        return val
    }
    // one value at a time
    vals := vec[i64]()
    for s in sites {
        bb, v, ai, _ := s
        a := if v == NOV { term_args(&f.blocks[bb].term)[ai] } else { f.insts[v].args[ai] }
        if !contains(&vals, a) {
            vals.push(a)
        }
    }
    for x in vals {
        xn := m[x]
        fill(memo.items(), NOV)
        pending.clear()
        for s in sites {
            bb, v, ai, at := s
            cur := if v == NOV { term_args(&f.blocks[bb].term)[ai] } else { f.insts[v].args[ai] }
            if cur != x {
                continue
            }
            r := read(f, x, xn, b, n, at, &preds, &memo, &pending)
            if v == NOV {
                term_args(&f.blocks[bb].term)[ai] = r
            } else {
                f.insts[v].args[ai] = r
            }
        }
        pi := 0
        while pi < pending.len {
            blk, ph := pending[pi]
            pi += 1
            for q in preds[blk] {
                r := read(f, x, xn, b, n, q, &preds, &memo, &pending)
                f.im(ph).phi_add(r, q)
            }
        }
    }
}

// if-conversion budgets: the cost of one arm, of both arms with the selects they need, and the
// number of selects (see arm_cost)
const IFC_ARM_MAX = 5
const IFC_TOTAL_MAX = 8
const IFC_SELECTS_MAX = 3

// the cost of executing block x unconditionally (about one per cheap operation, more for the
// slower ones), or IFC_ARM_MAX + 1 if it holds something that must not be speculated (a
// trap, a side effect, a memory access) or that is too slow
priv fn arm_cost(f: *Func, x: i64) -> i64 {
    cost := 0
    for v in f.blocks[x].insts {
        i := &f.insts[v]
        match i.op {
            Const, FConst, GAddr, FAddr => {}
            Add, Sub, And, Or, Xor, Shl, LShr, AShr, SExt, ZExt, Trunc => cost += 1
            Eq, Ne, Slt, Sle, Sgt, Sge, Ult, Ule, Ugt, Uge => cost += 1
            Mul => {
                // (by 3, 5, 9 or a power of two: one lea or shift)
                k := match f.is_const(i.args[1]) {
                    Some(k1) => k1
                    None => 0
                }
                cost += if k == 3 || k == 5 || k == 9 || (k > 0 && is_pow2(u64(k))) { 1 } else { 2 }
            }
            // a select left by an earlier conversion (float: a compare and a blend of three operations)
            Select => cost += if i.ty.is_int() { 1 } else { 3 }
            FNeg, FAbs, FMin, FMax, FEq, FNe, FLt, FLe, FGt, FGe => {
                if i.ty.is_vec() || f.insts[i.args[0]].ty.is_vec() {
                    return IFC_ARM_MAX + 1
                }
                cost += 1
            }
            FAdd, FSub, FMul => {
                if i.ty.is_vec() {
                    return IFC_ARM_MAX + 1
                }
                cost += 1
            }
            // (only where both arms store to one address, and loads only for that address: see
            // arm_store and same_value)
            Store, Load => cost += 1
            _ => return IFC_ARM_MAX + 1
        }
    }
    return cost
}

// the only store of block x: NOV if there is none, -1 if there are several
priv fn arm_store(f: *Func, x: i64) -> i64 {
    st := NOV
    for v in f.blocks[x].insts {
        if f.insts[v].op == Store {
            if st != NOV {
                return -1
            }
            st = i64(v)
        }
    }
    return st
}

// the number of loads in block x
priv fn arm_loads(f: *Func, x: i64) -> i64 {
    n := 0
    for v in f.blocks[x].insts {
        if f.insts[v].op == Load {
            n += 1
        }
    }
    return n
}

// x and y compute the same value (the same instruction, or the same pure operation of such
// values, depth levels deep): the number of those operations, or -1 if they differ. Two loads
// of the same address count as the same (*loads: how many such pairs): the caller makes sure
// that they read the same memory.
priv fn same_value(f: *Func, x: i64, y: i64, depth: i64, loads: *i64) -> i64 {
    if x == y {
        return 0
    }
    xi := &f.insts[x]
    yi := &f.insts[y]
    if depth == 0 || xi.op != yi.op || xi.ty != yi.ty || xi.k != yi.k || xi.aux != yi.aux || xi.args.len != yi.args.len {
        return -1
    }
    if xi.op == Const || xi.op == FConst || xi.op == GAddr || xi.op == FAddr {
        return 0
    }
    if xi.op == Load {
        *loads += 1
    } else if !xi.op.is_pure() || xi.op == Alloca {
        return -1
    }
    n := 1
    for k in 0..xi.args.len {
        d := same_value(f, xi.args[k], yi.args[k], depth - 1, loads)
        if d < 0 {
            return -1
        }
        n += d
    }
    return n
}

// the value of `c ? vt : ve` (type ty), added at the end of block b: a select, or something
// cheaper that computes the same
priv fn ifc_select(f: *Func, b: i64, c: i64, vt: i64, ve: i64, ty: T) -> i64 {
    // an arm that is itself a select on c or on its negation takes the side c decides
    ti := f.insts[vt]
    if ti.op == Select && (ti.args[0] == c || is_not(f, ti.args[0], c)) {
        return ifc_select(f, b, c, if ti.args[0] == c { ti.args[1] } else { ti.args[2] }, ve, ty)
    }
    ei := f.insts[ve]
    if ei.op == Select && (ei.args[0] == c || is_not(f, ei.args[0], c)) {
        return ifc_select(f, b, c, vt, if ei.args[0] == c { ei.args[2] } else { ei.args[1] }, ty)
    }
    if vt == ve {
        return vt
    }
    ci := f.insts[c]
    if ty == F64 || ty == F32 {
        // x86 minsd / maxsd semantics (FMin(a, b) = a < b ? a : b, FMax(a, b) = a > b ? a : b,
        // the second operand when unordered): only the exact source shapes, so NaN and -0.0
        // come out as written
        if (ci.op == FLt || ci.op == FGt) && f.insts[ci.args[0]].ty == ty {
            x := ci.args[0]
            y := ci.args[1]
            if vt == x && ve == y {
                // x < y ? x : y  /  x > y ? x : y
                return f.push(b, if ci.op == FLt { FMin } else { FMax }, ty, vec_two(x, y), 0)
            }
            if vt == y && ve == x {
                // x < y ? y : x = y > x ? y : x  /  x > y ? y : x = y < x ? y : x
                return f.push(b, if ci.op == FLt { FMax } else { FMin }, ty, vec_two(y, x), 0)
            }
            // x against zero choosing between x and -x: x < 0 exactly when -x > x (both
            // false for NaN and for either zero), x > 0 exactly when x > -x
            neg_cond := false
            pos_cond := false
            if is_fzero(f, y) {
                neg_cond = ci.op == FLt
                pos_cond = ci.op == FGt
            } else if is_fzero(f, x) {
                // 0 < y: y > 0, 0 > y: y < 0
                neg_cond = ci.op == FGt
                pos_cond = ci.op == FLt
                x = y
            }
            if neg_cond || pos_cond {
                ti := f.insts[vt]
                ei := f.insts[ve]
                if ve == x && ti.op == FNeg && ti.args[0] == x {
                    // x < 0 ? -x : x = max(-x, x)  /  x > 0 ? -x : x = min(-x, x)
                    return f.push(b, if neg_cond { FMax } else { FMin }, ty, vec_two(vt, x), 0)
                }
                if vt == x && ei.op == FNeg && ei.args[0] == x {
                    // x < 0 ? x : -x = min(x, -x)  /  x > 0 ? x : -x = max(x, -x)
                    return f.push(b, if neg_cond { FMin } else { FMax }, ty, vec_two(x, ve), 0)
                }
            }
        }
        return f.push(b, Select, ty, vec_of([]i64{c, vt, ve}), 0)
    }
    if !ty.is_int() || ci.ty != I8 {
        return f.push(b, Select, ty, vec_of([]i64{c, vt, ve}), 0)
    }
    // booleans: && and || of flags (one side a constant)
    kt0 := f.is_const(vt)
    ke0 := f.is_const(ve)
    if ty == I8 && is_some(kt0) != is_some(ke0) && is_bool(f, vt, 3) && is_bool(f, ve, 3) {
        if ke0 == Some(0) {
            return f.push(b, And, I8, vec_two(c, vt), 0)
        }
        if kt0 == Some(1) {
            return f.push(b, Or, I8, vec_two(c, ve), 0)
        }
        if kt0 == Some(0) {
            return f.push(b, And, I8, vec_two(ifc_not(f, b, c), ve), 0)
        }
        if ke0 == Some(1) {
            return f.push(b, Or, I8, vec_two(ifc_not(f, b, c), vt), 0)
        }
    }
    // x op y on one side and x on the other: x op (c ? y : 0), which keeps the select off a
    // loop-carried x (and turns into arithmetic on the flag when y is a constant)
    for side in 0..2 {
        p := if side == 0 { vt } else { ve }
        q := if side == 0 { ve } else { vt }
        pi := f.insts[p]
        if pi.ty != ty || !(pi.op == Add || pi.op == Sub || pi.op == Or || pi.op == Xor) {
            continue
        }
        y := NOV
        if pi.args[0] == q {
            y = pi.args[1]
        } else if pi.args[1] == q && pi.op != Sub {
            y = pi.args[0]
        }
        if y == NOV {
            continue
        }
        // the condition under which y applies
        cy := if side == 0 { c } else { ifc_not(f, b, c) }
        zero := f.push(b, Const, ty, vec[i64](), 0)
        s := ifc_select(f, b, cy, y, zero, ty)
        return f.push(b, pi.op, ty, vec_two(q, s), 0)
    }
    kt := f.is_const(vt)
    ke := f.is_const(ve)
    if is_some(kt) && is_some(ke) {
        a := unwrap(kt)
        e := unwrap(ke)
        if a == e {
            return vt
        }
        if a >= -0x40000000 && a <= 0x40000000 && e >= -0x40000000 && e <= 0x40000000 {
            // e + (c ? d : 0) with d = a - e: the flag zero-extended, shifted or negated
            cc := c
            d := a - e
            if d < 0 && e == 0 && d != -1 {
                // (c ? -n : 0): (!c ? n : 0) - n would need two constants; keep the select
                return f.push(b, Select, ty, vec_of([]i64{c, vt, ve}), 0)
            }
            neg := false
            if d < 0 {
                neg = true
                d = 0 - d
            }
            if is_pow2(u64(d)) && d <= 8 {
                z := cc
                if ty != I8 {
                    z = f.push(b, ZExt, ty, vec_one(cc), 0)
                }
                sh := 0
                while (1 << sh) < d {
                    sh += 1
                }
                if sh > 0 {
                    z = f.push(b, Shl, ty, vec_two(z, f.push(b, Const, ty, vec[i64](), sh)), 0)
                }
                if neg {
                    return f.push(b, Sub, ty, vec_two(f.push(b, Const, ty, vec[i64](), e), z), 0)
                }
                if e == 0 {
                    return z
                }
                return f.push(b, Add, ty, vec_two(z, f.push(b, Const, ty, vec[i64](), e)), 0)
            }
        }
    }
    return f.push(b, Select, ty, vec_of([]i64{c, vt, ve}), 0)
}

// v is the float constant 0.0 or -0.0
priv fn is_fzero(f: *Func, v: i64) -> bool {
    i := &f.insts[v]
    if i.op != FConst {
        return false
    }
    if i.ty == F32 {
        return i.k & 0x7FFF_FFFF == 0
    }
    return i.ty == F64 && i.k & 0x7FFF_FFFF_FFFF_FFFF == 0
}

// v is 0 or 1 (an i8 compare, a constant 0 or 1, or and / or / xor / select of such)
priv fn is_bool(f: *Func, v: i64, depth: i64) -> bool {
    i := &f.insts[v]
    if i.ty != I8 {
        return false
    }
    if i.op.is_cmp() {
        return true
    }
    if i.op == Const {
        return i.k == 0 || i.k == 1
    }
    if depth == 0 {
        return false
    }
    if i.op == And || i.op == Or || i.op == Xor {
        return is_bool(f, i.args[0], depth - 1) && is_bool(f, i.args[1], depth - 1)
    }
    if i.op == Select {
        return is_bool(f, i.args[1], depth - 1) && is_bool(f, i.args[2], depth - 1)
    }
    return false
}

// x is the negation of the boolean c (both 0 or 1)
priv fn is_not(f: *Func, x: i64, c: i64) -> bool {
    xi := &f.insts[x]
    ci := &f.insts[c]
    if xi.ty != I8 || ci.ty != I8 {
        return false
    }
    if xi.op == Xor && ((xi.args[0] == c && f.is_const(xi.args[1]) == Some(1)) || (xi.args[1] == c && f.is_const(xi.args[0]) == Some(1))) {
        return true
    }
    if xi.op == Sub && xi.args[1] == c && f.is_const(xi.args[0]) == Some(1) {
        return true
    }
    if xi.op == Eq && ((xi.args[0] == c && f.is_const(xi.args[1]) == Some(0)) || (xi.args[1] == c && f.is_const(xi.args[0]) == Some(0))) {
        return true
    }
    if ci.op.is_icmp() && xi.op == ci.op.negate_icmp() && xi.args[0] == ci.args[0] && xi.args[1] == ci.args[1] {
        return true
    }
    return is_not_side(f, c, x)
}

// (is_not with the roles exchanged, without recursing further)
priv fn is_not_side(f: *Func, x: i64, c: i64) -> bool {
    xi := &f.insts[x]
    if xi.op == Xor && ((xi.args[0] == c && f.is_const(xi.args[1]) == Some(1)) || (xi.args[1] == c && f.is_const(xi.args[0]) == Some(1))) {
        return true
    }
    if xi.op == Sub && xi.args[1] == c && f.is_const(xi.args[0]) == Some(1) {
        return true
    }
    return xi.op == Eq && ((xi.args[0] == c && f.is_const(xi.args[1]) == Some(0)) || (xi.args[1] == c && f.is_const(xi.args[0]) == Some(0)))
}

// arm x multiplies (more than a lea or shift does) a phi that the join's phi ph feeds back
// into: converting would put the multiply and the select on a loop-carried chain that a
// predicted branch keeps shorter
priv fn ifc_recurrence(f: *Func, x: i64, ph: i64) -> bool {
    for v in f.blocks[x].insts {
        i := &f.insts[v]
        if i.op != Mul {
            continue
        }
        k := match f.is_const(i.args[1]) {
            Some(k1) => k1
            None => 0
        }
        if k == 3 || k == 5 || k == 9 || (k > 0 && is_pow2(u64(k))) {
            continue
        }
        for a in i.args {
            ai := &f.insts[a]
            if ai.op != Phi {
                continue
            }
            for w in ai.args {
                if w == ph || (f.insts[w].op != Phi && contains(f.insts[w].args, ph)) {
                    return true
                }
            }
        }
    }
    return false
}

// the negation of the boolean c (0 or 1), added to block b
priv fn ifc_not(f: *Func, b: i64, c: i64) -> i64 {
    ci := f.insts[c]
    if ci.op.is_icmp() {
        return f.push(b, ci.op.negate_icmp(), I8, vec_two(ci.args[0], ci.args[1]), 0)
    }
    return f.push(b, Xor, I8, vec_two(c, f.push(b, Const, I8, vec[i64](), 1)), 0)
}

// see simplify_cfg, step 3b
priv fn phi_fold_headers(f: *Func) -> bool {
    // (most functions have no candidate: a block of phis only that jumps to a block with phis)
    any := false
    for e in 1..f.blocks.len {
        match f.blocks[e].term {
            Jmp(t) if t != e && !f.blocks[e].insts.is_empty() && all_phis(f, &f.blocks[e].insts) && !f.blocks[t].insts.is_empty() && f.insts[f.blocks[t].insts[0]].op == Phi => any = true
            _ => {}
        }
    }
    if !any {
        return false
    }
    rpo, preds := f.rpo_preds()
    pos := vec_fill(f.blocks.len, -1)
    for k in 0..rpo.len {
        pos[rpo[k]] = k
    }
    blocks: for e in rpo {
        if e == 0 || f.blocks[e].insts.is_empty() || !all_phis(f, &f.blocks[e].insts) {
            continue
        }
        t := match f.blocks[e].term {
            Jmp(t1) if t1 != e => t1
            _ => continue
        }
        if f.blocks[t].insts.is_empty() || f.insts[f.blocks[t].insts[0]].op != Phi {
            continue
        }
        // e is a loop header (an edge comes back to it), and no way into it reaches t already
        back := false
        for p in preds[e] {
            if p == e || pos[p] < 0 || contains(&preds[t], p) || f.has_succ(p, t) {
                continue blocks
            }
            if pos[p] >= pos[e] {
                back = true
            }
        }
        if !back {
            continue
        }
        // the phis of e are read by the phis of t on the edge from e, and nowhere else
        for b in 0..f.blocks.len {
            for v in f.blocks[b].insts {
                i := &f.insts[v]
                for k in 0..i.args.len {
                    if contains(&f.blocks[e].insts, i32(i.args[k])) && !(b == t && i.op == Phi && i.from()[k] == e) {
                        continue blocks
                    }
                }
            }
            for a in term_args(&f.blocks[b].term) {
                if contains(&f.blocks[e].insts, i32(a)) {
                    continue blocks
                }
            }
        }
        for v in f.blocks[t].insts {
            if f.insts[v].op != Phi {
                break
            }
            inst := f.im(i64(v))
            k := index_of(inst.from(), e)
            if k < 0 {
                continue
            }
            val := inst.args[k]
            inst.phi_remove(k)
            if contains(&f.blocks[e].insts, i32(val)) {
                src := f.insts[val]
                sf := src.from()
                for j in 0..src.args.len {
                    f.im(i64(v)).phi_add(src.args[j], sf[j])
                }
            } else {
                for p in preds[e] {
                    f.im(i64(v)).phi_add(val, p)
                }
            }
        }
        for p in preds[e] {
            f.retarget(p, e, t)
        }
        // (one at a time: the lists of predecessors are those of before)
        return true
    }
    return false
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
    // (Switch terminators: src/opt/switch.al)
    if switch_simplify(f) {
        changed = true
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
        scratch_reset(f.w)
        // (the CFG analyses are kept for the next pass: not on the scratch heap)
        rpo, preds := f.rpo_preds()
        scratch_on(f.w)
        merged := false
        repl := vec_fill(f.insts.len, i32(NOV))
        nrepl := 0
        dead := vec_fill(f.blocks.len, false)
        scratch_off(f.w)
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
                for si in 0..f.nsucc(b) {
                    f.phi_pred_replace(f.succ_at(b, si), s, b)
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
        scratch_reset(f.w)
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
                        Switch(_, _) if f.has_succ(p, t) => continue
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
    // 3b. a loop header that holds only phis and jumps on to an inner header (two functions
    // that tail-call each other become such a pair of loops): its phis are folded into the
    // inner header's, and both back edges go to one header, where the arms of a branch that
    // end in them can become selects (step 6)
    if opt_enabled("phifold") && phi_fold_headers(f) {
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
        scratch_reset(f.w)
        rpo, preds := f.rpo_preds()
        scratch_on(f.w)
        uses := f.use_counts()
        // blocks whose edges or phis changed this round: their entries in preds / phi lists are
        // stale, so they wait for the next round (one threading per round made long chains of
        // `&&` / `||` quadratic in time and memory)
        touched := vec_fill(f.blocks.len, false)
        did := false
        scratch_off(f.w)
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
        scratch_reset(f.w)
        cfg := cfg_new(f)
        scratch_on(f.w)
        def_block := f.block_of()
        scratch_off(f.w)
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
                    Switch(&cc, _) => {
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
    // 5b. an edge that decides the branch of a small block (a phi with a constant input from
    //     that edge, or a compare of such phis and constants) goes past it: the block's other
    //     instructions are copied onto the edge, and the values the block defines meet their
    //     copies in new phis (the general case of steps 4 and 5)
    guard_thread6 := 0
    loop {
        guard_thread6 += 1
        if !opt_enabled("thread6") || guard_thread6 > THREAD6_ROUNDS {
            break
        }
        if scanned {
            if cand & 32 == 0 {
                break
            }
        } else if !may_thread6(f) {
            break
        }
        scratch_reset(f.w)
        cfg := cfg_new(f)
        did := false
        blocks6: for b in cfg.rpo {
            if b == 0 || !thread6_block(f, b) {
                continue
            }
            c, t, e := match f.blocks[b].term {
                Br(c1, t1, e1) => (c1, t1, e1)
                _ => continue
            }
            // not into a loop through its header (that would make a second entry)
            for p in cfg.preds[b] {
                if cfg.dom(b, p) {
                    continue blocks6
                }
            }
            for p in cfg.preds[b] {
                match f.blocks[p].term {
                    Br(_, x, y) if x == b && y == b => continue
                    _ => {}
                }
                k := match edge_value(f, b, c, p) {
                    Some(k1) => k1
                    None => continue
                }
                thread_dup(f, b, p, if k != 0 { t } else { e })
                did = true
                break blocks6
            }
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
        scratch_reset(f.w)
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
            cost := 0
            for ph in phis {
                i := f.insts[ph]
                kt := index_of(i.from(), from_t)
                ke := index_of(i.from(), from_e)
                if kt >= 0 && ke >= 0 {
                    vt := i.args[kt]
                    ve := i.args[ke]
                    if vt != ve {
                        if (from_t != b && ifc_recurrence(f, from_t, ph)) || (from_e != b && ifc_recurrence(f, from_e, ph)) {
                            ok = false
                        }
                        if i.ty == F64 || i.ty == F32 {
                            // a compare and a blend (or one min / max)
                            cost += 2
                        } else if !i.ty.is_int() {
                            ok = false
                        } else {
                            cost += 1
                        }
                        selects += 1
                    }
                    pairs.push((ph, vt, ve))
                } else {
                    ok = false
                }
            }
            // a store in an arm: each arm stores once to the same address, and the store sinks
            // below the join with the value selected (anything else stays a branch)
            st_t := if from_t != b { arm_store(f, from_t) } else { NOV }
            st_e := if from_e != b { arm_store(f, from_e) } else { NOV }
            if st_t != NOV || st_e != NOV {
                if st_t == NOV || st_e == NOV || st_t < 0 || st_e < 0 {
                    continue
                }
                si := f.insts[st_t]
                se := f.insts[st_e]
                // loads in the arms only where both compute the address with them: each path
                // ran one of the two, before its store, from the same memory
                nloads := 0
                dup := same_value(f, si.args[0], se.args[0], 4, &nloads)
                if !ok || si.ty != se.ty || si.aux != se.aux || dup < 0 || arm_loads(f, from_t) != nloads || arm_loads(f, from_e) != nloads {
                    continue
                }
                if si.args[1] != se.args[1] {
                    if si.ty == F64 || si.ty == F32 {
                        cost += 2
                    } else if !si.ty.is_int() {
                        continue
                    } else {
                        cost += 1
                    }
                    selects += 1
                }
                // one store and one address remain
                cost -= 1 + dup
            } else if (from_t != b && arm_loads(f, from_t) != 0) || (from_e != b && arm_loads(f, from_e) != 0) {
                continue
            }
            if !ok || selects == 0 || selects > IFC_SELECTS_MAX {
                continue
            }
            for x in [2]i64{from_t, from_e} {
                if x != b {
                    cost += arm_cost(f, x)
                }
            }
            if cost > IFC_TOTAL_MAX {
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
                nv := if vt != ve { ifc_select(f, b, c, vt, ve, ty) } else { vt }
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
            if st_t != NOV {
                // the two stores become one after the selects
                bl := &f.blocks[b].insts
                k := 0
                while k < bl.len {
                    if i64(bl[k]) == st_t || i64(bl[k]) == st_e {
                        bl.remove(k)
                    } else {
                        k += 1
                    }
                }
                si := f.insts[st_t]
                vt := si.args[1]
                ve := f.insts[st_e].args[1]
                val := if vt != ve { ifc_select(f, b, c, vt, ve, si.ty) } else { vt }
                ns := f.push(b, Store, si.ty, vec_two(si.args[0], val), 0)
                f.insts[ns].aux = si.aux
                f.insts[ns].cap = si.cap
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

const PASS_SELBR = 10

// A select on the condition of a branch, used where only one side of the branch leads: there
// it is that side's value (a digit test's `(c - '0', true)` / `(0, false)`, if-converted inside
// the inlined function and then branched on by the caller, selects the digit only where the
// caller already knows it is one)
priv fn select_under_branch(f: *Func) -> bool {
    // (cheap exits: no two-way branch, no select)
    nb := f.blocks.len
    any := false
    for b in 0..nb {
        match f.blocks[b].term {
            Br(c, t, e) if t != e && f.insts[c].ty == I8 => {
                any = true
                break
            }
            _ => {}
        }
    }
    if !any {
        return false
    }
    sel := false
    for b in 0..nb {
        for v in f.blocks[b].insts {
            i := &f.insts[v]
            if i.op == Select {
                sel = true
                break
            }
        }
        if sel {
            break
        }
    }
    if !sel {
        return false
    }
    cfg := cfg_new(f)
    // per condition, the first block that branches on it to a successor of its own (a
    // successor whose only predecessor it is)
    br_of := imap_new(16)
    for b in cfg.rpo.items() {
        match f.blocks[b].term {
            Br(c, t, e) if t != e && (cfg.preds[t].len == 1 || cfg.preds[e].len == 1) => {
                if br_of.iget(c) < 0 {
                    br_of.iset(c, b)
                }
            }
            _ => {}
        }
    }
    // the value of select s where it is used in block x (NOV: unknown)
    fn known(f: *Func, cfg: *Cfg, br_of: *IMap, s: i64, x: i64) -> i64 {
        si := &f.insts[s]
        if si.op != Select {
            return NOV
        }
        b := br_of.iget(si.args[0])
        if b < 0 {
            return NOV
        }
        t, e := match f.blocks[b].term {
            Br(_, t0, e0) => (t0, e0)
            _ => return NOV
        }
        if cfg.preds[t].len == 1 && cfg.dom(t, x) {
            return si.args[1]
        }
        if cfg.preds[e].len == 1 && cfg.dom(e, x) {
            return si.args[2]
        }
        return NOV
    }
    changed := false
    for x in cfg.rpo.items() {
        for v in f.blocks[x].insts {
            i := &f.insts[v]
            isphi := i.op == Phi
            for k in 0..i.args.len {
                a := i.args[k]
                at := if isphi { i.from()[k] } else { x }
                r := known(f, &cfg, &br_of, a, at)
                if r != NOV {
                    i.args[k] = r
                    changed = true
                }
            }
        }
        ta := term_args(&f.blocks[x].term)
        for k in 0..len(ta) {
            r := known(f, &cfg, &br_of, ta[k], x)
            if r != NOV {
                ta[k] = r
                changed = true
            }
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
        if opt_enabled("selbr") && opt_pass(PASS_SELBR, f, select_under_branch) {
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
