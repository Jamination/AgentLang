// Constant folding, algebraic simplification, strength reduction and CFG simplification.

fn simplify_mask(bits: i64) -> u64 {
    if bits >= 64 {
        return ~u64(0)
    }
    return (u64(1) << bits) - 1
}

// (value, true) for Some(value), (zero, false) for None
fn simplify_unopt[T](o: Opt[T]) -> (T, bool) {
    z: T
    match o {
        Some(x) => { return (x, true) }
        None => {}
    }
    return (z, false)
}

// `o == Some(k)`
fn simplify_opt_is(o: Opt[i64], k: i64) -> bool {
    match o {
        Some(x) => { return x == k }
        None => {}
    }
    return false
}

fn simplify_is_pow2(x: u64) -> bool {
    return x != 0 && x & (x - 1) == 0
}

// `k.unsigned_abs()`
fn simplify_uabs(k: i64) -> u64 {
    if k < 0 {
        return u64(0 - k)
    }
    return u64(k)
}

// high 64 bits of the unsigned 128-bit product a * b
fn simplify_mulhu(a: u64, b: u64) -> u64 {
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
fn simplify_mulhs(a: i64, b: i64) -> i64 {
    h := simplify_mulhu(u64(a), u64(b))
    if a < 0 {
        h -= u64(b)
    }
    if b < 0 {
        h -= u64(a)
    }
    return i64(h)
}

// low 64 bits of the 128-bit value hi:lo shifted right by `bits` (arithmetic when signed)
fn simplify_shr128(lo: u64, hi: u64, bits: i64, signed: bool) -> i64 {
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

fn simplify_fold_bin(op: Op, ty: T, a: i64, b: i64) -> Opt[i64] {
    bits := i64(ty.bits())
    m := simplify_mask(bits)
    ua := u64(a) & m
    ub := u64(b) & m
    sh := i64(u32(u64(b) & (u64(bits) - 1)))
    r: i64
    match op {
        OpAdd => { r = a + b }
        OpSub => { r = a - b }
        OpMul => { r = a * b }
        OpSDiv => {
            if b == 0 {
                return None
            }
            r = simplify_wrapping_div(a, b)
        }
        OpSRem => {
            if b == 0 {
                return None
            }
            r = simplify_wrapping_rem(a, b)
        }
        OpUDiv => {
            if ub == 0 {
                return None
            }
            r = i64(ua / ub)
        }
        OpURem => {
            if ub == 0 {
                return None
            }
            r = i64(ua % ub)
        }
        OpAnd => { r = a & b }
        OpOr => { r = a | b }
        OpXor => { r = a ^ b }
        OpShl => { r = i64((ua << sh) & m) }
        OpLShr => { r = i64(ua >> sh) }
        OpAShr => { r = a >> sh }
        OpRotl => {
            if sh == 0 {
                r = a
            } else {
                r = i64(((ua << sh) | (ua >> (bits - sh))) & m)
            }
        }
        OpRotr => {
            if sh == 0 {
                r = a
            } else {
                r = i64(((ua >> sh) | (ua << (bits - sh))) & m)
            }
        }
        // ((a as i128) * (b as i128)) >> bits
        OpMulHiS => { r = simplify_shr128(u64(a) * u64(b), u64(simplify_mulhs(a, b)), bits, true) }
        // ((ua as u128) * (ub as u128)) >> bits
        OpMulHiU => { r = simplify_shr128(ua * ub, simplify_mulhu(ua, ub), bits, false) }
        _ => { return None }
    }
    return Some(ir_canon(ty, r))
}

// i64::wrapping_div: MIN / -1 is MIN
fn simplify_wrapping_div(a: i64, b: i64) -> i64 {
    if b == -1 {
        return 0 - a
    }
    return a / b
}

// i64::wrapping_rem: MIN % -1 is 0
fn simplify_wrapping_rem(a: i64, b: i64) -> i64 {
    if b == -1 {
        return 0
    }
    return a % b
}

fn simplify_fold_icmp(op: Op, ty: T, a: i64, b: i64) -> Opt[bool] {
    m := simplify_mask(i64(ty.bits()))
    ua := u64(a) & m
    ub := u64(b) & m
    match op {
        OpEq => { return Some(a == b) }
        OpNe => { return Some(a != b) }
        OpSlt => { return Some(a < b) }
        OpSle => { return Some(a <= b) }
        OpSgt => { return Some(a > b) }
        OpSge => { return Some(a >= b) }
        OpUlt => { return Some(ua < ub) }
        OpUle => { return Some(ua <= ub) }
        OpUgt => { return Some(ua > ub) }
        OpUge => { return Some(ua >= ub) }
        _ => {}
    }
    return None
}

// `new` is a builtin: the field is `new_insts`
struct SimplifyCtx {
    f: *Func
    new_insts: Vec[i64]
    changed: bool
    uses: Vec[i64]
}

fn c(self: *SimplifyCtx, v: i64) -> Opt[i64] {
    return self.f.is_const(v)
}

// scalar float constants only (vector constants are never folded)
fn fc(self: *SimplifyCtx, v: i64) -> Opt[f64] {
    i := &self.f.insts[v]
    if i.op == OpFConst && i.ty == TF64 {
        return Some(cast[f64](u64(i.k)))
    } else if i.op == OpFConst && i.ty == TF32 {
        return Some(f64(cast[f32](u32(i.k))))
    }
    return None
}

// bits of the constant r in type ty; f32 results are computed in f64 and rounded once,
// which is exact for + - * / sqrt
fn simplify_ctx_fbits(ty: T, r: f64) -> i64 {
    if ty == TF32 {
        return i64(cast[u32](f32(r)))
    }
    return i64(cast[u64](r))
}

fn konst(self: *SimplifyCtx, ty: T, k: i64) -> i64 {
    v := self.f.mk(OpConst, ty, vec[i64](), ir_canon(ty, k))
    self.new_insts.push(v)
    return v
}

fn mk(self: *SimplifyCtx, op: Op, ty: T, args: Vec[i64]) -> i64 {
    v := self.f.mk(op, ty, args, 0)
    self.new_insts.push(v)
    return v
}

// rewrite v in place
fn set(self: *SimplifyCtx, v: i64, op: Op, args: Vec[i64], k: i64) {
    i := self.f.im(v)
    i.op = op
    i.args = args
    i.k = k
    i.pb.clear()
    self.changed = true
}

fn set_const(self: *SimplifyCtx, v: i64, k: i64) {
    ty := self.f.insts[v].ty
    self.set(v, OpConst, vec[i64](), ir_canon(ty, k))
}

fn op(self: *SimplifyCtx, v: i64) -> Op {
    return self.f.insts[v].op
}

fn simplify_simplify_small(k: i64) -> bool {
    return k >= i64(i32(0x80000000)) && k <= 0x7FFFFFFF
}

fn simplify_simplify_is_not(s: *SimplifyCtx, n: i64, x: i64) -> bool {
    ni := s.f.insts[n]
    return ni.op == OpXor && simplify_opt_is(s.c(ni.args[1]), -1) && ni.args[0] == x
}

// returns Some(w) when v should be replaced by the existing value w
fn simplify(self: *SimplifyCtx, v: i64) -> Opt[i64] {
    inst := self.f.insts[v]
    ty := inst.ty
    op := inst.op
    match op {
        OpAdd, OpSub, OpMul, OpSDiv, OpUDiv, OpSRem, OpURem, OpAnd, OpOr, OpXor, OpShl, OpLShr, OpAShr,
        OpRotl, OpRotr, OpMulHiS, OpMulHiU => {
            a := inst.args[0]
            b := inst.args[1]
            x0, hx0 := simplify_unopt(self.c(a))
            y0, hy0 := simplify_unopt(self.c(b))
            if hx0 && hy0 {
                r0, hr0 := simplify_unopt(simplify_fold_bin(op, ty, x0, y0))
                if hr0 {
                    self.set_const(v, r0)
                    return None
                }
            }
            if op.is_commutative() && is_some(self.c(a)) && !is_some(self.c(b)) {
                tmp := a
                a = b
                b = tmp
                self.f.im(v).args = vec_of([]i64{a, b})
                self.changed = true
            }
            cb := self.c(b)
            bits := i64(ty.bits())
            k, hk := simplify_unopt(cb)
            if hk {
                is_shift := op == OpShl || op == OpLShr || op == OpAShr || op == OpRotl || op == OpRotr
                if k == 0 && (op == OpAdd || op == OpSub || op == OpOr || op == OpXor || is_shift) {
                    return Some(a)
                } else if is_shift && k & (bits - 1) == 0 {
                    return Some(a)
                } else if k == 1 && (op == OpMul || op == OpSDiv || op == OpUDiv) {
                    return Some(a)
                } else if k == 0 && (op == OpMul || op == OpAnd) {
                    self.set_const(v, 0)
                    return None
                } else if k == 1 && (op == OpSRem || op == OpURem) {
                    self.set_const(v, 0)
                    return None
                } else if op == OpXor && k == 1 && ty == TI8 && self.op(a).is_cmp() {
                    ai := self.f.insts[a]
                    if ai.op.is_icmp() {
                        self.set(v, ai.op.negate_icmp(), clone(&ai.args), 0)
                        return None
                    }
                    if ai.op == OpFEq || ai.op == OpFNe {
                        nop := OpFEq
                        if ai.op == OpFEq {
                            nop = OpFNe
                        }
                        self.set(v, nop, clone(&ai.args), 0)
                        return None
                    }
                } else if op == OpAnd && k == -1 {
                    return Some(a)
                } else if op == OpOr && k == -1 {
                    self.set_const(v, -1)
                    return None
                } else if op == OpSub {
                    nk := self.konst(ty, 0 - k)
                    self.set(v, OpAdd, vec_of([]i64{a, nk}), 0)
                    return None
                } else if op == OpMul && k > 0 && simplify_is_pow2(u64(k)) {
                    s := self.konst(ty, i64(ctz(u64(k))))
                    self.set(v, OpShl, vec_of([]i64{a, s}), 0)
                    return None
                } else if op == OpMul && k == -1 {
                    z := self.konst(ty, 0)
                    self.set(v, OpSub, vec_of([]i64{z, a}), 0)
                    return None
                } else if op == OpUDiv {
                    uk := u64(k) & simplify_mask(i64(ty.bits()))
                    if simplify_is_pow2(uk) {
                        s := self.konst(ty, i64(ctz(uk)))
                        self.set(v, OpLShr, vec_of([]i64{a, s}), 0)
                        return None
                    }
                    if ty == TI64 || ty == TI32 {
                        q := self.udiv_magic(a, ty, uk)
                        return Some(q)
                    }
                } else if op == OpURem {
                    uk := u64(k) & simplify_mask(i64(ty.bits()))
                    if simplify_is_pow2(uk) {
                        m := self.konst(ty, i64(uk - 1))
                        self.set(v, OpAnd, vec_of([]i64{a, m}), 0)
                        return None
                    }
                    if ty == TI64 || ty == TI32 {
                        q := self.udiv_magic(a, ty, uk)
                        d := self.konst(ty, k)
                        p := self.mk(OpMul, ty, vec_of([]i64{q, d}))
                        self.set(v, OpSub, vec_of([]i64{a, p}), 0)
                        return None
                    }
                } else if (op == OpSDiv || op == OpSRem) && k != 0 && k != -1 && (ty == TI64 || ty == TI32) &&
                    k != i64(0x8000000000000000) && !(ty == TI32 && k == i64(i32(0x80000000))) {
                    q: i64
                    if simplify_is_pow2(simplify_uabs(k)) {
                        // (a + ((a >> bits-1) >>> (bits - s))) >> s, negated for negative divisors
                        s := i64(ctz(simplify_uabs(k)))
                        c1 := self.konst(ty, bits - 1)
                        sign := self.mk(OpAShr, ty, vec_of([]i64{a, c1}))
                        c2 := self.konst(ty, bits - s)
                        bias := self.mk(OpLShr, ty, vec_of([]i64{sign, c2}))
                        sum := self.mk(OpAdd, ty, vec_of([]i64{a, bias}))
                        c3 := self.konst(ty, s)
                        q1 := self.mk(OpAShr, ty, vec_of([]i64{sum, c3}))
                        if k < 0 {
                            z := self.konst(ty, 0)
                            q = self.mk(OpSub, ty, vec_of([]i64{z, q1}))
                        } else {
                            q = q1
                        }
                    } else {
                        q = self.sdiv_magic(a, ty, k)
                    }
                    if op == OpSDiv {
                        return Some(q)
                    }
                    d := self.konst(ty, k)
                    p := self.mk(OpMul, ty, vec_of([]i64{q, d}))
                    self.set(v, OpSub, vec_of([]i64{a, p}), 0)
                    return None
                }
            }
            if a == b {
                if op == OpSub || op == OpXor {
                    self.set_const(v, 0)
                    return None
                }
                if op == OpAnd || op == OpOr {
                    return Some(a)
                }
            }
            // (x op c1) op c2 for associative ops
            if hk {
                k2 := k
                ai := self.f.insts[a]
                if ai.op == op && (op == OpAdd || op == OpMul || op == OpAnd || op == OpOr || op == OpXor) {
                    k1, hk1 := simplify_unopt(self.c(ai.args[1]))
                    if hk1 {
                        x := ai.args[0]
                        kf, hkf := simplify_unopt(simplify_fold_bin(op, ty, k1, k2))
                        assert hkf
                        kc := self.konst(ty, kf)
                        self.set(v, op, vec_of([]i64{x, kc}), 0)
                        return None
                    }
                }
                // (x << c1) << c2, (x >>> c1) >>> c2
                if ai.op == op && (op == OpShl || op == OpLShr) {
                    k1, hk1 := simplify_unopt(self.c(ai.args[1]))
                    if hk1 {
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
                }
            }
            // (x + c1) << c2  =>  (x << c2) + (c1 << c2) ; (x + c1) * c2  =>  x * c2 + c1 * c2
            if hk {
                k2 := k
                ai := self.f.insts[a]
                if (op == OpShl || op == OpMul) && ai.op == OpAdd {
                    k1, hk1 := simplify_unopt(self.c(ai.args[1]))
                    prod_small := false
                    if hk1 {
                        pr, hpr := simplify_unopt(simplify_fold_bin(op, ty, k1, k2))
                        if hpr {
                            prod_small = simplify_simplify_small(pr)
                        }
                    }
                    if hk1 && prod_small {
                        x := ai.args[0]
                        inner := self.mk(op, ty, vec_of([]i64{x, b}))
                        kf, hkf := simplify_unopt(simplify_fold_bin(op, ty, k1, k2))
                        assert hkf
                        kc := self.konst(ty, kf)
                        self.set(v, OpAdd, vec_of([]i64{inner, kc}), 0)
                        return None
                    }
                }
            }
            if op == OpXor || op == OpOr {
                ai := self.f.insts[a]
                bi := self.f.insts[b]
                ua := 2
                if a < self.uses.len {
                    ua = self.uses[a]
                }
                ub := 2
                if b < self.uses.len {
                    ub = self.uses[b]
                }
                if ai.op == OpAnd && bi.op == OpAnd && ua == 1 && ub == 1 {
                    // bit select: (x & y) ^ (~x & z)  =>  z ^ (x & (y ^ z))
                    has_sel := false
                    sel_x := 0
                    sel_y := 0
                    sel_z := 0
                    for o in 0..2 {
                        p := ai
                        q := bi
                        if o == 1 {
                            p = bi
                            q = ai
                        }
                        for pi in 0..2 {
                            for qi in 0..2 {
                                if !has_sel && simplify_simplify_is_not(self, q.args[qi], p.args[pi]) {
                                    has_sel = true
                                    sel_x = p.args[pi]
                                    sel_y = p.args[1 - pi]
                                    sel_z = q.args[1 - qi]
                                }
                            }
                        }
                    }
                    if has_sel {
                        yz := self.mk(OpXor, ty, vec_of([]i64{sel_y, sel_z}))
                        m := self.mk(OpAnd, ty, vec_of([]i64{sel_x, yz}))
                        self.set(v, OpXor, vec_of([]i64{sel_z, m}), 0)
                        return None
                    }
                    // (x & y) ^ (x & z)  =>  x & (y ^ z)
                    if op == OpXor {
                        for pi in 0..2 {
                            for qi in 0..2 {
                                if ai.args[pi] == bi.args[qi] {
                                    x := ai.args[pi]
                                    yz := self.mk(OpXor, ty, vec_of([]i64{ai.args[1 - pi], bi.args[1 - qi]}))
                                    self.set(v, OpAnd, vec_of([]i64{x, yz}), 0)
                                    return None
                                }
                            }
                        }
                    }
                }
            }
            // rotate idioms: (x >>> n) | (x << (bits - n))
            if op == OpOr || op == OpXor || op == OpAdd {
                match self.match_rotate(a, b, ty) {
                    Some(r) => {
                        self.set(v, r.0, vec_of([]i64{r.1, r.2}), 0)
                        return None
                    }
                    None => {}
                }
            }
            // x + (0 - y) => x - y
            if op == OpAdd {
                bi := self.f.insts[b]
                if bi.op == OpSub && simplify_opt_is(self.c(bi.args[0]), 0) {
                    y := bi.args[1]
                    self.set(v, OpSub, vec_of([]i64{a, y}), 0)
                    return None
                }
            }
            return None
        }
        OpFAdd, OpFSub, OpFMul, OpFDiv => {
            x, hx := simplify_unopt(self.fc(inst.args[0]))
            if hx {
                y, hy := simplify_unopt(self.fc(inst.args[1]))
                if hy {
                    r: f64
                    if op == OpFAdd {
                        r = x + y
                    } else if op == OpFSub {
                        r = x - y
                    } else if op == OpFMul {
                        r = x * y
                    } else {
                        r = x / y
                    }
                    self.set(v, OpFConst, vec[i64](), simplify_ctx_fbits(ty, r))
                }
            }
            return None
        }
        OpFNeg, OpFAbs, OpFSqrt => {
            x, hx := simplify_unopt(self.fc(inst.args[0]))
            if hx {
                r: f64
                if op == OpFNeg {
                    r = -x
                } else if op == OpFAbs {
                    r = fabs(x)
                } else {
                    r = sqrt(x)
                }
                self.set(v, OpFConst, vec[i64](), simplify_ctx_fbits(ty, r))
            }
            return None
        }
        OpEq, OpNe, OpSlt, OpSle, OpSgt, OpSge, OpUlt, OpUle, OpUgt, OpUge => {
            a := inst.args[0]
            b := inst.args[1]
            at := self.f.insts[a].ty
            x, hx := simplify_unopt(self.c(a))
            y, hy := simplify_unopt(self.c(b))
            if hx && hy {
                r, hr := simplify_unopt(simplify_fold_icmp(op, at, x, y))
                assert hr
                self.set_const(v, i64(r))
                return None
            }
            if is_some(self.c(a)) {
                tmp := a
                a = b
                b = tmp
                op = op.swap_cmp()
                i := self.f.im(v)
                i.op = op
                i.args = vec_of([]i64{a, b})
                self.changed = true
            }
            if a == b {
                r := op == OpEq || op == OpSle || op == OpSge || op == OpUle || op == OpUge
                self.set_const(v, i64(r))
                return None
            }
            // (x & (len - 1)) <u len  is true exactly when len != 0
            if op == OpUlt || op == OpUgt {
                idx := b
                lenv := a
                if op == OpUlt {
                    idx = a
                    lenv = b
                }
                if self.masked_by(idx, lenv, 4, idx) {
                    z := self.konst(at, 0)
                    self.set(v, OpNe, vec_of([]i64{lenv, z}), 0)
                    return None
                }
            }
            // comparisons of booleans with constants
            k, hk := simplify_unopt(self.c(b))
            if hk {
                ai := self.f.insts[a]
                if (op == OpEq || op == OpNe) && at == TI8 && ai.op.is_cmp() {
                    truth := (op == OpNe) == (k == 0)
                    // (cmp != 0) or (cmp == 1) => cmp ; (cmp == 0) or (cmp != 1) => !cmp
                    if k == 0 || k == 1 {
                        if truth {
                            return Some(a)
                        }
                        if ai.op.is_icmp() {
                            self.set(v, ai.op.negate_icmp(), clone(&ai.args), 0)
                            return None
                        }
                        if ai.op == OpFEq || ai.op == OpFNe {
                            nop := OpFEq
                            if ai.op == OpFEq {
                                nop = OpFNe
                            }
                            self.set(v, nop, clone(&ai.args), 0)
                            return None
                        }
                    }
                }
                // unsigned x < 0 is false, x >= 0 is true
                if k == 0 && op == OpUlt {
                    self.set_const(v, 0)
                    return None
                }
                if k == 0 && op == OpUge {
                    self.set_const(v, 1)
                    return None
                }
                // (x + c1) == c2  =>  x == c2 - c1
                if (op == OpEq || op == OpNe) && ai.op == OpAdd {
                    k1, hk1 := simplify_unopt(self.c(ai.args[1]))
                    if hk1 {
                        nk := self.konst(at, k - k1)
                        self.set(v, op, vec_of([]i64{ai.args[0], nk}), 0)
                        return None
                    }
                }
            }
            return None
        }
        OpFEq, OpFNe, OpFLt, OpFLe, OpFGt, OpFGe => {
            x, hx := simplify_unopt(self.fc(inst.args[0]))
            if hx {
                y, hy := simplify_unopt(self.fc(inst.args[1]))
                if hy {
                    r: bool
                    if op == OpFEq {
                        r = x == y
                    } else if op == OpFNe {
                        r = x != y
                    } else if op == OpFLt {
                        r = x < y
                    } else if op == OpFLe {
                        r = x <= y
                    } else if op == OpFGt {
                        r = x > y
                    } else {
                        r = x >= y
                    }
                    self.set_const(v, i64(r))
                }
            }
            return None
        }
        OpSExt, OpZExt, OpTrunc => {
            a := inst.args[0]
            at := self.f.insts[a].ty
            if at == ty {
                return Some(a)
            }
            x, hx := simplify_unopt(self.c(a))
            if hx {
                r := x
                if op == OpZExt {
                    r = i64(u64(x) & simplify_mask(i64(at.bits())))
                }
                self.set_const(v, r)
                return None
            }
            ai := self.f.insts[a]
            if (op == OpSExt && ai.op == OpSExt) || (op == OpZExt && ai.op == OpZExt) {
                self.set(v, op, vec_of([]i64{ai.args[0]}), 0)
            } else if op == OpSExt && ai.op == OpZExt {
                // zero-extended value is non-negative
                self.set(v, OpZExt, vec_of([]i64{ai.args[0]}), 0)
            } else if op == OpTrunc && (ai.op == OpSExt || ai.op == OpZExt || ai.op == OpTrunc) {
                src := ai.args[0]
                st := self.f.insts[src].ty
                if st == ty {
                    return Some(src)
                }
                if ai.op == OpTrunc || i64(st.bits()) > i64(ty.bits()) {
                    self.set(v, OpTrunc, vec_of([]i64{src}), 0)
                } else {
                    self.set(v, ai.op, vec_of([]i64{src}), 0)
                }
            }
            return None
        }
        OpSIToF => {
            x, hx := simplify_unopt(self.c(inst.args[0]))
            if hx {
                fbits: i64
                if ty == TF32 {
                    fbits = i64(cast[u32](f32(x)))
                } else {
                    fbits = i64(cast[u64](f64(x)))
                }
                self.set(v, OpFConst, vec[i64](), fbits)
            }
            return None
        }
        OpFToSI => {
            x, hx := simplify_unopt(self.fc(inst.args[0]))
            if hx {
                if simplify_is_finite(x) && fabs(x) < 9.0e18 && (ty == TI64 || fabs(x) < 2.0e9) {
                    self.set_const(v, i64(x))
                }
            }
            return None
        }
        OpBitsToF => {
            x, hx := simplify_unopt(self.c(inst.args[0]))
            if hx {
                kb := x
                if ty == TF32 {
                    kb = x & 0xFFFFFFFF
                }
                self.set(v, OpFConst, vec[i64](), kb)
            }
            return None
        }
        OpFToBits => {
            i := self.f.insts[inst.args[0]]
            if i.op == OpFConst {
                k := i.k
                self.set_const(v, k)
            }
            return None
        }
        OpFExt, OpFTrunc => {
            x, hx := simplify_unopt(self.fc(inst.args[0]))
            if hx {
                self.set(v, OpFConst, vec[i64](), simplify_ctx_fbits(ty, x))
            }
            return None
        }
        OpSelect => {
            c := inst.args[0]
            a := inst.args[1]
            b := inst.args[2]
            if a == b {
                return Some(a)
            }
            k, hk := simplify_unopt(self.c(c))
            if hk {
                if k != 0 {
                    return Some(a)
                }
                return Some(b)
            }
            return None
        }
        OpPhi => { return None }
        _ => {}
    }
    return None
}

// `x.is_finite()`
fn simplify_is_finite(x: f64) -> bool {
    return (cast[u64](x) >> 52) & 0x7FF != 0x7FF
}

fn simplify_masked_by_is_len_m1(s: *SimplifyCtx, lenv: i64, m: i64) -> bool {
    mi := s.f.insts[m]
    return mi.op == OpAdd && mi.args[0] == lenv && simplify_opt_is(s.c(mi.args[1]), -1)
}

// is v always of the form (x & (len - 1)), directly or through phis?
fn masked_by(self: *SimplifyCtx, v: i64, lenv: i64, depth: i64, root: i64) -> bool {
    i := self.f.insts[v]
    if i.op == OpAnd {
        return simplify_masked_by_is_len_m1(self, lenv, i.args[0]) || simplify_masked_by_is_len_m1(self, lenv, i.args[1])
    }
    if i.op == OpPhi && depth > 0 && !i.args.is_empty() {
        for a in i.args.items() {
            if !(a == root || a == v || self.masked_by(a, lenv, depth - 1, root)) {
                return false
            }
        }
        return true
    }
    return false
}

// `a.saturating_sub(b)` on unsigned counts
fn simplify_sat_sub(a: i64, b: i64) -> i64 {
    if a > b {
        return a - b
    }
    return 0
}

// upper bound on the number of significant bits of an unsigned value
fn ubits(self: *SimplifyCtx, v: i64, depth: i64) -> i64 {
    i := self.f.insts[v]
    tb := max(i64(i.ty.bits()), 1)
    if depth == 0 {
        return tb
    }
    r := tb
    if i.op == OpConst {
        r = 64 - i64(clz(u64(i.k) & simplify_mask(tb)))
    } else if i.op == OpLShr {
        k, hk := simplify_unopt(self.c(i.args[1]))
        if hk {
            r = simplify_sat_sub(self.ubits(i.args[0], depth - 1), i64(u32(k & (tb - 1))))
        } else {
            r = tb
        }
    } else if i.op == OpAnd {
        r0 := self.ubits(i.args[0], depth - 1)
        r = min(r0, self.ubits(i.args[1], depth - 1))
    } else if i.op == OpZExt {
        r0 := self.ubits(i.args[0], depth - 1)
        r = min(r0, i64(self.f.insts[i.args[0]].ty.bits()))
    } else if i.op == OpURem {
        k, hk := simplify_unopt(self.c(i.args[1]))
        if hk {
            r = 64 - i64(clz(u64(k) & simplify_mask(tb)))
        } else {
            r = tb
        }
    } else if i.op == OpUDiv {
        k, hk := simplify_unopt(self.c(i.args[1]))
        if hk && k > 0 {
            r = simplify_sat_sub(self.ubits(i.args[0], depth - 1), 63 - i64(clz(u64(k))))
        } else {
            r = tb
        }
    } else if i.op.is_cmp() {
        r = 1
    } else {
        r = tb
    }
    return min(r, tb)
}

fn simplify_match_rotate_is_complement(s: *SimplifyCtx, bits: i64, m: i64, n: i64) -> bool {
    mi := s.f.insts[m]
    if !(mi.op == OpSub && mi.args[1] == n) {
        return false
    }
    k, hk := simplify_unopt(s.c(mi.args[0]))
    if hk {
        return k & (bits - 1) == 0
    }
    return false
}

fn match_rotate(self: *SimplifyCtx, a: i64, b: i64, ty: T) -> Opt[(Op, i64, i64)] {
    bits := i64(ty.bits())
    ai := self.f.insts[a]
    bi := self.f.insts[b]
    shr: Inst
    shl: Inst
    if ai.op == OpLShr && bi.op == OpShl {
        shr = ai
        shl = bi
    } else if ai.op == OpShl && bi.op == OpLShr {
        shr = bi
        shl = ai
    } else {
        return None
    }
    if shr.args[0] != shl.args[0] {
        return None
    }
    x := shr.args[0]
    nr := shr.args[1]
    nl := shl.args[1]
    kr0, hkr := simplify_unopt(self.c(nr))
    kl0, hkl := simplify_unopt(self.c(nl))
    if hkr && hkl {
        kr := kr0 & (bits - 1)
        kl := kl0 & (bits - 1)
        if kr + kl == bits && kr != 0 {
            return Some((OpRotr, x, nr))
        }
        return None
    }
    // variable amounts: (x >>> n) | (x << (bits - n))  or  (x << n) | (x >>> (bits - n))
    if simplify_match_rotate_is_complement(self, bits, nl, nr) {
        return Some((OpRotr, x, nr))
    }
    if simplify_match_rotate_is_complement(self, bits, nr, nl) {
        return Some((OpRotl, x, nl))
    }
    return None
}

// unsigned division by a constant (Hacker's Delight, magicu)
// The Rust code computes in u128; every value fits 64 bits (or is reduced modulo 2^w right
// away), so this uses wrapping u64 arithmetic.
fn udiv_magic(self: *SimplifyCtx, n: i64, ty: T, d: u64) -> i64 {
    w := i64(ty.bits())
    // a dividend known to be narrow needs only one multiplication and one shift
    nb := self.ubits(n, 6)
    if ty == TI64 && nb < 64 && nb > 0 {
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
                t := self.mk(OpMul, ty, vec_of([]i64{n, mc}))
                sc := self.konst(ty, sh)
                return self.mk(OpLShr, ty, vec_of([]i64{t, sc}))
            }
        }
    }
    two_w1 := u64(1) << (w - 1)
    wmask := simplify_mask(w)
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
    t := self.mk(OpMulHiU, ty, vec_of([]i64{n, mc}))
    if !add {
        if s == 0 {
            return t
        }
        sc := self.konst(ty, s)
        return self.mk(OpLShr, ty, vec_of([]i64{t, sc}))
    } else {
        diff := self.mk(OpSub, ty, vec_of([]i64{n, t}))
        one := self.konst(ty, 1)
        half := self.mk(OpLShr, ty, vec_of([]i64{diff, one}))
        sum := self.mk(OpAdd, ty, vec_of([]i64{half, t}))
        if s - 1 == 0 {
            return sum
        }
        sc := self.konst(ty, s - 1)
        return self.mk(OpLShr, ty, vec_of([]i64{sum, sc}))
    }
}

// signed division by a constant (Hacker's Delight, magic)
// u128 in the Rust code; all values fit 64 bits.
fn sdiv_magic(self: *SimplifyCtx, n: i64, ty: T, d: i64) -> i64 {
    w := i64(ty.bits())
    two_w1 := u64(1) << (w - 1)
    ad := simplify_uabs(d)
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
    wmask := simplify_mask(w)
    m := i64((q2 + 1) & wmask)
    m = ir_canon(ty, m)
    if d < 0 {
        m = ir_canon(ty, 0 - m)
    }
    s := p - w
    mc := self.konst(ty, m)
    q := self.mk(OpMulHiS, ty, vec_of([]i64{n, mc}))
    if d > 0 && m < 0 {
        q = self.mk(OpAdd, ty, vec_of([]i64{q, n}))
    } else if d < 0 && m > 0 {
        q = self.mk(OpSub, ty, vec_of([]i64{q, n}))
    }
    if s > 0 {
        sc := self.konst(ty, s)
        q = self.mk(OpAShr, ty, vec_of([]i64{q, sc}))
    }
    c := self.konst(ty, w - 1)
    sign := self.mk(OpLShr, ty, vec_of([]i64{q, c}))
    return self.mk(OpAdd, ty, vec_of([]i64{q, sign}))
}

fn simplify_fold_insts_find(repl: *Vec[i64], v0: i64) -> i64 {
    v := v0
    while v < repl.len && repl[v] != NOV {
        v = repl[v]
    }
    return v
}

fn simplify_fold_insts(f: *Func) -> bool {
    rpo := f.rpo()
    repl := vec_fill(f.insts.len, NOV)
    uses := f.use_counts()
    cx := SimplifyCtx{f: f, new_insts: vec[i64](), changed: false, uses: uses}
    for b in rpo.items() {
        old := cx.f.blocks[b].insts
        cx.f.blocks[b].insts = vec[i64]()
        cx.new_insts = vec[i64]()
        for v in old.items() {
            for ai in 0..cx.f.insts[v].args.len {
                a := cx.f.insts[v].args[ai]
                r := simplify_fold_insts_find(&repl, a)
                if r != a {
                    cx.f.insts[v].args[ai] = r
                }
            }
            match cx.simplify(v) {
                Some(w) => {
                    if repl.len < cx.f.insts.len {
                        repl.resize(cx.f.insts.len, NOV)
                    }
                    repl[v] = w
                    cx.changed = true
                }
                None => { cx.new_insts.push(v) }
            }
        }
        cx.f.blocks[b].insts = cx.new_insts
        cx.new_insts = vec[i64]()
    }
    changed := cx.changed
    repl.resize(f.insts.len, NOV)
    f.apply_repl(&repl)
    return changed
}

// `fix` of step 5: the replacement of a value defined in b
fn simplify_simplify_cfg_fix(a: i64, def_block: *Vec[i64], b: i64, binsts: *Vec[i64], side_t: bool, repl_t: *Vec[i64], repl_e: *Vec[i64]) -> i64 {
    if a < def_block.len && def_block[a] == b {
        k := index_of(binsts.items(), a)
        assert k >= 0
        if side_t {
            return repl_t[k]
        }
        return repl_e[k]
    }
    return a
}

// `side` of step 6: the block x is a tiny side-effect-free arm; returns where it jumps to
fn simplify_simplify_cfg_side(f: *Func, preds: *Vec[Vec[i64]], x: i64) -> Opt[i64] {
    if x == 0 || preds[x].len != 1 {
        return None
    }
    j := 0
    match f.blocks[x].term {
        TermJmp(j1) => { j = j1 }
        _ => { return None }
    }
    insts := f.blocks[x].insts
    real := 0
    for v in insts.items() {
        op := f.insts[v].op
        cheap := op == OpConst || op == OpFConst || op == OpGAddr || op == OpFAddr || op == OpAdd || op == OpSub ||
            op == OpAnd || op == OpOr || op == OpXor || op == OpShl || op == OpLShr || op == OpAShr || op == OpSExt ||
            op == OpZExt || op == OpTrunc
        if !cheap {
            return None
        }
        if !(op == OpConst || op == OpFConst || op == OpGAddr || op == OpFAddr) {
            real += 1
        }
    }
    if real > 2 {
        return None
    }
    return Some(j)
}

// all instructions of the block are phis
fn simplify_all_phis(f: *Func, binsts: *Vec[i64]) -> bool {
    for v in binsts.items() {
        if f.insts[v].op != OpPhi {
            return false
        }
    }
    return true
}

// redirect the edge p -> from to p -> to
fn simplify_retarget(f: *Func, p: i64, from: i64, to: i64) {
    match f.blocks[p].term {
        TermJmp(x) => {
            if x == from {
                f.blocks[p].term = TermJmp(to)
            }
        }
        TermBr(c, x, y) => {
            nx := x
            ny := y
            if x == from {
                nx = to
            }
            if y == from {
                ny = to
            }
            f.blocks[p].term = TermBr(c, nx, ny)
        }
        _ => {}
    }
}

fn simplify_simplify_cfg(f: *Func) -> bool {
    changed := false
    // 1. fold constant / degenerate branches
    for b in 0..f.blocks.len {
        match f.blocks[b].term {
            TermBr(c, t, e) => {
                if t == e {
                    f.blocks[b].term = TermJmp(t)
                    changed = true
                    continue
                }
                ci := f.insts[c]
                if ci.op == OpConst {
                    if ci.k != 0 {
                        f.blocks[b].term = TermJmp(t)
                    } else {
                        f.blocks[b].term = TermJmp(e)
                    }
                    changed = true
                } else if ci.op == OpXor && simplify_opt_is(f.is_const(ci.args[1]), 1) && f.insts[ci.args[0]].ty == TI8 {
                    // br !x, t, e  =>  br x, e, t  (x is a boolean)
                    x := ci.args[0]
                    if f.insts[x].op.is_cmp() {
                        f.blocks[b].term = TermBr(x, e, t)
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
    // 2. merge straight-line blocks
    guard_merge := 0
    loop {
        guard_merge += 1
        if guard_merge > 20000 {
            eput(fmt("simplify_cfg: step merge does not converge in ", f.name, "\n"))
            break
        }
        // per-round tables live on the scratch heap (see base.al)
        scratch_reset()
        scratch_on()
        preds := f.preds()
        merged := false
        repl := vec_fill(f.insts.len, NOV)
        dead := vec_fill(f.blocks.len, false)
        rpo := f.rpo()
        scratch_off()
        for b in rpo.items() {
            if dead[b] {
                continue
            }
            loop {
                s := 0
                is_jmp := false
                match f.blocks[b].term {
                    TermJmp(s1) => {
                        s = s1
                        is_jmp = true
                    }
                    _ => {}
                }
                if !is_jmp {
                    break
                }
                if s == 0 || s == b || preds[s].len != 1 || dead[s] {
                    break
                }
                sinsts := f.blocks[s].insts
                f.blocks[s].insts = vec[i64]()
                for v in sinsts.items() {
                    if f.insts[v].op == OpPhi {
                        repl[v] = f.insts[v].args[0]
                    } else {
                        f.blocks[b].insts.push(v)
                    }
                }
                st := f.blocks[s].term
                f.blocks[s].term = TermNone
                f.blocks[b].term = st
                dead[s] = true
                // successors of s now come from b
                succs := f.succs(b)
                for ss in succs.items() {
                    for ii in 0..f.blocks[ss].insts.len {
                        v := f.blocks[ss].insts[ii]
                        if f.insts[v].op != OpPhi {
                            break
                        }
                        pb := f.insts[v].pb
                        for pk in 0..pb.len {
                            if pb[pk] == s {
                                pb[pk] = b
                            }
                        }
                    }
                }
                merged = true
            }
        }
        if !merged {
            break
        }
        f.apply_repl(&repl)
        changed = true
    }
    // 3. skip empty forwarding blocks
    guard_forward := 0
    loop {
        guard_forward += 1
        if guard_forward > 20000 {
            eput(fmt("simplify_cfg: step forward does not converge in ", f.name, "\n"))
            break
        }
        scratch_reset()
        scratch_on()
        preds := f.preds()
        did := false
        rpo := f.rpo()
        scratch_off()
        for e in rpo.items() {
            if e == 0 || !f.blocks[e].insts.is_empty() {
                continue
            }
            t := 0
            is_jmp := false
            match f.blocks[e].term {
                TermJmp(t1) => {
                    if t1 != e {
                        t = t1
                        is_jmp = true
                    }
                }
                _ => {}
            }
            if !is_jmp {
                continue
            }
            t_has_phi := false
            if f.blocks[t].insts.len > 0 {
                t_has_phi = f.insts[f.blocks[t].insts[0]].op == OpPhi
            }
            moved_any := false
            for p in preds[e].items() {
                if p == e {
                    continue
                }
                if t_has_phi && (contains(&preds[t], p) || moved_any && false) {
                    continue
                }
                // a conditional branch whose other arm already goes to t would need a select
                if t_has_phi {
                    skip := false
                    match f.blocks[p].term {
                        TermBr(c, a, b2) => {
                            if a == t || b2 == t {
                                skip = true
                            }
                        }
                        _ => {}
                    }
                    if skip {
                        continue
                    }
                }
                // redirect p -> e to p -> t
                simplify_retarget(f, p, e, t)
                if t_has_phi {
                    for ii in 0..f.blocks[t].insts.len {
                        v := f.blocks[t].insts[ii]
                        if f.insts[v].op != OpPhi {
                            break
                        }
                        inst := f.im(v)
                        k := index_of(inst.pb.items(), e)
                        if k >= 0 {
                            val := inst.args[k]
                            inst.args.push(val)
                            inst.pb.push(p)
                        }
                    }
                }
                moved_any = true
                did = true
            }
            if did {
                break
            }
        }
        if !did {
            break
        }
        cleanup_prune_unreachable(f)
        changed = true
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
        scratch_reset()
        scratch_on()
        preds := f.preds()
        uses := f.use_counts()
        did := false
        rpo := f.rpo()
        scratch_off()
        for b in rpo.items() {
            c := 0
            t := 0
            e := 0
            is_br := false
            match f.blocks[b].term {
                TermBr(c1, t1, e1) => {
                    if t1 != e1 && t1 != b && e1 != b {
                        c = c1
                        t = t1
                        e = e1
                        is_br = true
                    }
                }
                _ => {}
            }
            if !is_br {
                continue
            }
            binsts := clone(&f.blocks[b].insts)
            if binsts.is_empty() || !simplify_all_phis(f, &binsts) || !contains(&binsts, c) {
                continue
            }
            // the phis of b may only be used by its terminator and by phis of its successors
            phi_uses := vec_fill(binsts.len, 0)
            for si in 0..2 {
                s := t
                if si == 1 {
                    s = e
                }
                for v in f.blocks[s].insts.items() {
                    i := f.insts[v]
                    if i.op != OpPhi {
                        break
                    }
                    for k in 0..i.args.len {
                        a := i.args[k]
                        if i.pb[k] == b {
                            pi := index_of(binsts.items(), a)
                            if pi >= 0 {
                                phi_uses[pi] += 1
                            }
                        }
                    }
                }
            }
            // `continue 'blocks`
            bad := false
            for pi in 0..binsts.len {
                ph := binsts[pi]
                extra := 0
                if ph == c {
                    extra = 1
                }
                if uses[ph] != phi_uses[pi] + extra {
                    bad = true
                    break
                }
            }
            if bad {
                continue
            }
            cphi := f.insts[c]
            for k in 0..cphi.pb.len {
                p := cphi.pb[k]
                kc, hkc := simplify_unopt(f.is_const(cphi.args[k]))
                if !hkc {
                    continue
                }
                if p == b || !contains(&preds[b], p) {
                    continue
                }
                target := e
                if kc != 0 {
                    target = t
                }
                // p must not already reach the target directly (its phis would need two inputs)
                if contains(&preds[target], p) {
                    continue
                }
                // a conditional branch in p with both arms into b cannot be threaded simply
                both := false
                match f.blocks[p].term {
                    TermBr(pc, x, y) => {
                        if x == b && y == b {
                            both = true
                        }
                    }
                    _ => {}
                }
                if both {
                    continue
                }
                // new phi inputs in the target for the edge p -> target
                for ii in 0..f.blocks[target].insts.len {
                    v := f.blocks[target].insts[ii]
                    if f.insts[v].op != OpPhi {
                        break
                    }
                    inst := f.insts[v]
                    bk := index_of(inst.pb.items(), b)
                    if bk >= 0 {
                        val := inst.args[bk]
                        // a phi of b seen through p is its input from p
                        nv := val
                        if contains(&binsts, val) {
                            vi := f.insts[val]
                            pk := index_of(vi.pb.items(), p)
                            assert pk >= 0
                            nv = vi.args[pk]
                        }
                        im := f.im(v)
                        im.args.push(nv)
                        im.pb.push(p)
                    }
                }
                simplify_retarget(f, p, b, target)
                did = true
                // `break 'blocks`
                break
            }
            if did {
                break
            }
        }
        if !did {
            break
        }
        cleanup_prune_unreachable(f)
        changed = true
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
        scratch_reset()
        scratch_on()
        cfg := cfg_new(f)
        def_block := f.block_of()
        scratch_off()
        did := false
        for b in cfg.rpo.items() {
            c := 0
            t := 0
            e := 0
            is_br := false
            match f.blocks[b].term {
                TermBr(c1, t1, e1) => {
                    if t1 != e1 && t1 != b && e1 != b {
                        c = c1
                        t = t1
                        e = e1
                        is_br = true
                    }
                }
                _ => {}
            }
            if !is_br {
                continue
            }
            binsts := clone(&f.blocks[b].insts)
            if b == 0 || binsts.is_empty() || !simplify_all_phis(f, &binsts) || !contains(&binsts, c) {
                continue
            }
            if cfg.preds[t].len != 1 || cfg.preds[e].len != 1 || cfg.preds[b].len < 2 {
                continue
            }
            cphi := f.insts[c]
            dest := vec[(i64, i64)]()
            // `continue 'blocks2`
            bad := false
            for k in 0..cphi.pb.len {
                p := cphi.pb[k]
                kc, hkc := simplify_unopt(f.is_const(cphi.args[k]))
                if !hkc {
                    bad = true
                    break
                }
                if p == b {
                    bad = true
                    break
                }
                match f.blocks[p].term {
                    TermBr(pc, x, y) => {
                        if x == b && y == b {
                            bad = true
                        }
                    }
                    _ => {}
                }
                if bad {
                    break
                }
                if kc != 0 {
                    dest.push((p, t))
                } else {
                    dest.push((p, e))
                }
            }
            if bad {
                continue
            }
            if dest.len != cfg.preds[b].len {
                continue
            }
            // every use of b's phis must be dominated by t or by e
            for bb in 0..f.blocks.len {
                if !cfg.reachable(bb) || bb == b {
                    continue
                }
                for v in f.blocks[bb].insts.items() {
                    i := f.insts[v]
                    for k in 0..i.args.len {
                        a := i.args[k]
                        if def_block[a] == b {
                            at := bb
                            if i.op == OpPhi {
                                at = i.pb[k]
                            }
                            if !(cfg.dom(t, at) || cfg.dom(e, at)) {
                                bad = true
                                break
                            }
                        }
                    }
                    if bad {
                        break
                    }
                }
                if bad {
                    break
                }
                tu := f.term_uses(bb)
                for a in tu.items() {
                    if def_block[a] == b && !(cfg.dom(t, bb) || cfg.dom(e, bb)) {
                        bad = true
                        break
                    }
                }
                if bad {
                    break
                }
            }
            if bad {
                continue
            }
            // build the replacement values of b's phis on each side
            repl_t := vec[i64]()
            repl_e := vec[i64]()
            for side in 0..2 {
                s := t
                if side == 1 {
                    s = e
                }
                ps := vec[i64]()
                for d in dest.items() {
                    if d.1 == s {
                        ps.push(d.0)
                    }
                }
                for ph in binsts.items() {
                    pi := f.insts[ph]
                    vals := vec[i64]()
                    for p in ps.items() {
                        pk := index_of(pi.pb.items(), p)
                        assert pk >= 0
                        vals.push(pi.args[pk])
                    }
                    nv := ph
                    if ps.is_empty() {
                        nv = ph
                    } else {
                        all_same := true
                        for x in vals.items() {
                            if x != vals[0] {
                                all_same = false
                                break
                            }
                        }
                        if all_same {
                            nv = vals[0]
                        } else {
                            np := f.mk(OpPhi, pi.ty, vals, 0)
                            f.im(np).pb = clone(&ps)
                            f.blocks[s].insts.insert(0, np)
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
                    if v >= def_block.len {
                        continue
                    }
                    for ai in 0..f.insts[v].args.len {
                        a := f.insts[v].args[ai]
                        if a < def_block.len && def_block[a] == b {
                            at := bb
                            if f.insts[v].op == OpPhi {
                                at = f.insts[v].pb[ai]
                            }
                            k := index_of(binsts.items(), a)
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
                    TermBr(cc, x, y) => {
                        f.blocks[bb].term = TermBr(simplify_simplify_cfg_fix(cc, &def_block, b, &binsts, side_t, &repl_t, &repl_e), x, y)
                    }
                    TermRet(vs) => {
                        // vs shares its buffer with the terminator
                        for vi in 0..vs.len {
                            vs[vi] = simplify_simplify_cfg_fix(vs[vi], &def_block, b, &binsts, side_t, &repl_t, &repl_e)
                        }
                    }
                    _ => {}
                }
            }
            // retarget the predecessors
            for d in dest.items() {
                simplify_retarget(f, d.0, b, d.1)
            }
            did = true
            break
        }
        if !did {
            break
        }
        cleanup_prune_unreachable(f)
        changed = true
    }
    // 6. if-conversion: tiny side-effect-free arms become selects (conditional moves)
    loop {
        if !opt_enabled("ifconv") {
            break
        }
        scratch_reset()
        scratch_on()
        preds := f.preds()
        did := false
        rpo := f.rpo()
        scratch_off()
        for b in rpo.items() {
            c := 0
            t := 0
            e := 0
            is_br := false
            match f.blocks[b].term {
                TermBr(c1, t1, e1) => {
                    if t1 != e1 {
                        c = c1
                        t = t1
                        e = e1
                        is_br = true
                    }
                }
                _ => {}
            }
            if !is_br {
                continue
            }
            j1, h1 := simplify_unopt(simplify_simplify_cfg_side(f, &preds, t))
            j2, h2 := simplify_unopt(simplify_simplify_cfg_side(f, &preds, e))
            tb: Opt[i64] = None
            eb: Opt[i64] = None
            j := 0
            if h1 && h2 && j1 == j2 && j1 != t && j1 != e {
                tb = Some(t)
                eb = Some(e)
                j = j1
            } else if h1 && j1 == e {
                tb = Some(t)
                j = e
            } else if h2 && j2 == t {
                eb = Some(e)
                j = t
            } else {
                continue
            }
            if j == b || j == 0 {
                continue
            }
            from_t := b
            match tb {
                Some(x) => { from_t = x }
                None => {}
            }
            from_e := b
            match eb {
                Some(x) => { from_e = x }
                None => {}
            }
            // the join's phis decide whether this is worth it
            phis := vec[i64]()
            for v in f.blocks[j].insts.items() {
                if f.insts[v].op != OpPhi {
                    break
                }
                phis.push(v)
            }
            pairs := vec[(i64, i64, i64)]()
            ok := true
            selects := 0
            for ph in phis.items() {
                i := f.insts[ph]
                kt := index_of(i.pb.items(), from_t)
                ke := index_of(i.pb.items(), from_e)
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
            for xi in 0..2 {
                xo := tb
                if xi == 1 {
                    xo = eb
                }
                match xo {
                    Some(x) => {
                        moved := f.blocks[x].insts
                        f.blocks[x].insts = vec[i64]()
                        f.blocks[b].insts.extend(moved.items())
                    }
                    None => {}
                }
            }
            for pr in pairs.items() {
                ph := pr.0
                vt := pr.1
                ve := pr.2
                ty := f.insts[ph].ty
                nv := vt
                if vt != ve {
                    nv = f.push(b, OpSelect, ty, vec_of([]i64{c, vt, ve}), 0)
                }
                i := f.im(ph)
                k := 0
                while k < i.pb.len {
                    if i.pb[k] == from_t || i.pb[k] == from_e {
                        i.pb.remove(k)
                        i.args.remove(k)
                    } else {
                        k += 1
                    }
                }
                i.pb.push(b)
                i.args.push(nv)
            }
            f.blocks[b].term = TermJmp(j)
            did = true
            break
        }
        if !did {
            break
        }
        cleanup_prune_unreachable(f)
        changed = true
    }
    // normalize `br c, t, t`
    for b in 0..f.blocks.len {
        match f.blocks[b].term {
            TermBr(c, t, e) => {
                if t == e {
                    f.blocks[b].term = TermJmp(t)
                    changed = true
                }
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
        if simplify_fold_insts(f) {
            ch = true
        }
        opt_trace("  cfg", f)
        if simplify_simplify_cfg(f) {
            ch = true
        }
        opt_trace("  phis", f)
        if cleanup_trivial_phis(f) {
            ch = true
        }
        opt_trace("  dce", f)
        if cleanup_dce(f) {
            ch = true
        }
        if !ch {
            break
        }
        any = true
    }
    return any
}
