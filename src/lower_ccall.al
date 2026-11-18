// Calls of C functions on AArch64 (--target linux-arm64): the C calling convention of the Arm
// procedure call standard (AAPCS64, "Procedure Call Standard for the Arm 64-bit Architecture",
// section 6.8 "Parameter passing"), laid out here, while lowering, where the types are known.
// The back end (`call` in src/arm64/isel.al) only places the values this makes:
//
//     CallInd, aux CCALL_AUX, args [function, (x8 pointer), x0.., v0.., stack pieces...],
//     k = (number of x registers) | (number of v registers) << 4 | (an x8 pointer) << 8
//
// A stack piece is an integer or floating-point value of 1, 2, 4 or 8 bytes. Linux puts each in
// its own 8-byte slot, in order (AAPCS64 rounds every stack argument up to 8 bytes); the
// lowering adds a zero piece where a 16-byte aligned argument needs a slot skipped.
//
// The classification (rules B.1-B.6 and C.1-C.17 of the standard, for the types AL has):
// - an integer, bool, enum without data, pointer or function value: the next x register
//   (narrow integers extended to 32 bits, as the x86-64 lowering does too), else a stack slot;
// - f32 / f64: the next v register, else a stack slot;
// - a struct, tuple, array or enum with data ("composite"):
//   - a homogeneous floating-point aggregate (HFA: 1 to 4 members, all f32 or all f64, nothing
//     else) in as many consecutive v registers, if that many are left; otherwise no further
//     argument goes to a v register (NSRN = 8) and the HFA is copied to the stack;
//   - larger than 16 bytes: copied by the caller, passed as the address of the copy (an
//     integer argument);
//   - otherwise its bytes as 1 or 2 8-byte words in consecutive x registers, if that many are
//     left (a composite of 16-byte alignment starts at an even register); otherwise NGRN = 8 and
//     the words go to the stack. A composite is never split between registers and the stack.
// - variadic arguments (`...`) follow the same rules on Linux.
// - results: an integer or float in x0 / v0; an HFA in v0-v3; a composite of up to 16 bytes in
//   x0 (and x1); a larger one in memory the caller provides, whose address it passes in x8.
//
// Vector types (vec2 ... mat4) do not cross the C boundary (lower.al refuses them).

const CCALL_AUX = 3

priv const C_NREG = 8

// the floating-point type of an HFA (F32 or F64) and its number of members, or (Void, 0)
fn c_hfa(self: *Cx, t: i64) -> (T, i64) {
    size := self.types.size_of(t)
    if size == 0 || size > 32 || self.types.is_scalar(t) {
        return (Void, 0)
    }
    leaves := self.types.leaf_list(t)
    if leaves.len < 1 || leaves.len > 4 {
        return (Void, 0)
    }
    ft := leaves[0].t
    if ft != F32 && ft != F64 {
        return (Void, 0)
    }
    es := if ft == F32 { 4 } else { 8 }
    for k, l in leaves {
        if l.t != ft || l.off != k * es {
            return (Void, 0)
        }
    }
    if size != leaves.len * es {
        return (Void, 0)
    }
    return (ft, leaves.len)
}

priv struct CLay {
    xs: Vec[i64]
    vs: Vec[i64]
    stack: Vec[i64]
    ngrn: i64
    nsrn: i64
    nsaa: i64 // bytes of stack arguments so far
}

// a stack piece (an IR value of 1-8 bytes): Linux gives it an 8-byte slot
priv fn piece(self: *Fx, l: *CLay, v: i64) {
    l.stack.push(v)
    l.nsaa += 8
}

// aligns the next stack argument to 16 bytes with a zero piece
priv fn stack_align16(self: *Fx, l: *CLay) {
    if l.nsaa % 16 != 0 {
        self.piece(l, self.iconst(I64, 0))
    }
}

// the bytes of the composite `v` as 8-byte words (the last one padded with zeros), read from a
// copy, so that no load reaches past the value
priv fn c_words(self: *Fx, t: i64, v: Val) -> Vec[i64] {
    size := self.cx.types.size_of(t)
    n := (size + 7) / 8
    tmp := self.alloca(8 * n, max(self.cx.types.align_of(t), 8))
    if size % 8 != 0 {
        self.store_raw(self.add_off(tmp, 8 * (n - 1)), self.iconst(I64, 0), I64, AK_ANY)
    }
    self.store(self.mval(t, tmp), v)
    out := vec[i64]()
    for k in 0..n {
        out.push(self.load_raw(self.add_off(tmp, 8 * k), I64, AK_ANY))
    }
    return out
}

// one argument of type t
priv fn c_arg(self: *Fx, l: *CLay, t: i64, v: Val) {
    types := &self.cx.types
    if types.is_scalar(t) {
        s := self.scalar(v)
        it := self.irt(t)
        if it == F32 || it == F64 {
            if l.nsrn < C_NREG {
                l.vs.push(s)
                l.nsrn += 1
            } else {
                self.piece(l, s)
            }
            return
        }
        if it == I8 || it == I16 {
            s = self.ins(if types.is_signed(t) { SExt } else { ZExt }, I32, vec_one(s), 0)
        }
        if l.ngrn < C_NREG {
            l.xs.push(s)
            l.ngrn += 1
        } else {
            self.piece(l, s)
        }
        return
    }
    size := types.size_of(t)
    align := types.align_of(t)
    ft, nm := self.cx.c_hfa(t)
    if nm > 0 {
        if l.nsrn + nm <= C_NREG {
            es := if ft == F32 { 4 } else { 8 }
            for k in 0..nm {
                l.vs.push(self.load_raw(self.add_off(v.v, es * k), ft, AK_ANY))
            }
            l.nsrn += nm
            return
        }
        l.nsrn = C_NREG
        for w in self.c_words(t, v) {
            self.piece(l, w)
        }
        return
    }
    if size > 16 {
        // a copy, passed by its address
        tmp := self.temp(t)
        self.store(self.mval(t, tmp), v)
        if l.ngrn < C_NREG {
            l.xs.push(tmp)
            l.ngrn += 1
        } else {
            self.piece(l, tmp)
        }
        return
    }
    words := self.c_words(t, v)
    if align >= 16 && l.ngrn % 2 == 1 {
        l.xs.push(self.iconst(I64, 0))
        l.ngrn += 1
    }
    if l.ngrn + words.len <= C_NREG {
        l.xs.extend(words.items())
        l.ngrn += words.len
        return
    }
    l.ngrn = C_NREG
    if align >= 16 {
        self.stack_align16(l)
    }
    for w in words {
        self.piece(l, w)
    }
}

// A call of the C function `x` (an extern) with the arguments `args` of types `ptys` (the
// declared parameters, then the promoted variadic ones) and the result type rty.
fn c_call_a64(self: *Fx, target: i64, ptys: []i64, rty: i64, args: Vec[Val]) -> Val {

    l := CLay{}
    // the result: in registers (x0, x1 or v0-v3), or memory whose address goes in x8
    sret := NOV
    rt := T.Void
    rwords := 0
    rhfa := T.Void
    rn := 0
    if rty != T_UNIT && rty != T_NEVER && rty != T_ERR {
        if self.cx.types.is_scalar(rty) {
            rt = self.irt(rty)
        } else {
            rhfa, rn = self.cx.c_hfa(rty)
            if rn == 0 {
                size := self.cx.types.size_of(rty)
                if size > 16 {
                    sret = self.temp(rty)
                } else if size > 0 {
                    rwords = (size + 7) / 8
                }
            }
        }
    }
    for i in 0..min(args.len, len(ptys)) {
        self.c_arg(&l, ptys[i], args[i])
    }
    ir_args := vec_one(target)
    if sret != NOV {
        ir_args.push(sret)
    }
    ir_args.extend(l.xs.items())
    ir_args.extend(l.vs.items())
    ir_args.extend(l.stack.items())
    k := l.xs.len | (l.vs.len << 4) | (if sret != NOV { 1 << 8 } else { 0 })
    res := val_unit()
    if rt != Void {
        c := self.ins(CallInd, rt, ir_args, k)
        self.f.im(c).aux = CCALL_AUX
        res = self.sval(rty, c)
    } else if rn > 0 || rwords > 0 {
        // the registers of the result into a temporary, read as the result type
        n := if rn > 0 { rn } else { rwords }
        et := if rn > 0 { rhfa } else { T.I64 }
        es := if et == F32 { 4 } else { 8 }
        tmp := self.alloca(max(n * es, self.cx.types.size_of(rty)), max(self.cx.types.align_of(rty), 8))
        if n == 1 {
            c := self.ins(CallInd, et, ir_args, k)
            self.f.im(c).aux = CCALL_AUX
            self.store_raw(tmp, c, et, AK_ANY)
        } else {
            c := self.ins(CallInd, Void, ir_args, k)
            self.f.im(c).aux = CCALL_AUX
            for j in 0..n {
                p := self.ins(Proj, et, vec_one(c), j)
                self.store_raw(self.add_off(tmp, es * j), p, et, AK_ANY)
            }
        }
        res = self.mval(rty, tmp)
    } else {
        c := self.ins(CallInd, Void, ir_args, k)
        self.f.im(c).aux = CCALL_AUX
        if sret != NOV {
            res = self.mval(rty, sret)
        } else if rty != T_UNIT && rty != T_NEVER && rty != T_ERR {
            // a zero-size value
            res = self.mval(rty, self.temp(rty))
        }
    }
    if rty == T_NEVER {
        self.terminate(Trap)
        return val_never()
    }
    return res
}

// a struct, tuple, array or enum with data that can be passed to C by value on arm64: not
// empty (C has no empty structs) and without vector members
fn c_aggregate_ok(self: *Cx, t: i64) -> bool {
    if self.types.size_of(t) == 0 {
        return false
    }
    for l in self.types.leaf_list(t) {
        if l.t == V2 || l.t == V3 || l.t == V4 {
            return false
        }
    }
    return true
}
