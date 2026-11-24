// The loop vectorizer: an innermost counted loop of one block (its bounds checks already
// hoisted by BCE, after if-conversion) that counts up by 1 and whose memory accesses are to
// consecutive elements becomes a loop over 128-bit vectors (SSE2 on x86-64), each value of the
// loop one vector (or U of them, interleaved) of VF lanes, followed by the original loop for the
// iterations that are left (loop_remainder_begin / _end in loop.al):
//
//     for i in 0..n { y[i] = y[i] + a * x[i] }       f64: 2 lanes, 2 vectors per iteration
//     for i in 0..n { s += x[i] * y[i] }             wrapping u32 sum: 4 partial sums per vector
//
// What is vectorized (the data of the loop: its loads, its reductions and what is computed from
// them; every value of the data has lanes of one size E, VF = 16 / E):
//   - loads and stores at addresses that advance by E per iteration (loop_affine_coef); a stored
//     value is data or loop-invariant;
//   - integer +, -, &, |, ^ (all sizes), * (i16, i32), shifts by a loop-invariant count (i16,
//     i32, i64 lanes; not >> of i64), compares (not of i64) as the conditions of selects;
//   - float +, -, *, /, sqrt, min, max, neg, abs, compares as the conditions of selects;
//   - operands that are loop-invariant (one vector with the value in every lane, made before
//     the loop);
//   - integer reductions (loop_reduction: +, -, &, |, ^, min, max, which wrap exactly in any
//     order): VF partial results per vector, combined after the loop. Float reductions are
//     never reductions (the order of IEEE operations stays as written): such loops stay scalar.
// Everything else that the loop computes must be scalar values from the counter and invariants,
// used only as addresses (they are kept and give the address of lane 0). Not vectorized: loops
// with calls, side exits (a check that BCE did not hoist), divisions, conversions, accesses with
// another stride, values used after the loop other than reductions, a stored value computed
// from the counter, and loops that are known to run fewer than 2 * VF * U times.
//
// Memory: two accesses of which one is a store either are proven apart (alias analysis), or
// have a constant distance d (same address expression up to a constant) with d == 0 or |d| >=
// VF * U * E bytes, or are tested before the vector loop: at the first iteration, their distance
// is 0 or at least VF * U * E in either direction, else the scalar loop runs. With that, two
// iterations whose accesses overlap are never in the same group of VF * U iterations (or are the
// same iteration, the order of the accesses within it kept), and the groups run in order.
// Bounds: the loop has no checks left (it has no exit but its latch), and the vector loop reads
// and writes only elements the scalar loop would (the remainder runs the rest), so nothing is
// loaded past the range of the scalar loop.
//
// The vector loop and the remainder are marked (LOOP_NO_VEC, LOOP_NO_UNROLL): runtime unrolling
// leaves them alone. x86-64 only (vec_enabled; arm64 keeps the scalar loops).

priv const VEC_MAX_SIZE = 80 // instructions and terminator of the loop
priv const VEC_MAX_CHECKS = 8 // run-time distance tests

// the target can run the vectorized loops
priv fn vec_enabled() -> bool {
    return target_arch == ArchX86_64
}

// the lane type a data value works on: its type, for a compare the type of its operands
priv fn vec_lane_ty(f: *Func, v: i64) -> T {
    i := &f.insts[v]
    if i.op.is_cmp() {
        return f.insts[i.args[0]].ty
    }
    return i.ty
}

// key of copy k of value v in the vector map
priv inline fn vk(v: i64, k: i64) -> i64 {
    return v * 4 + k
}

// the terms of an i64 address expression: c + sum of coef * leaf (leaves: anything but +, -, and
// * or << by a constant)
priv fn vec_lin(f: *Func, v: i64, mult: i64, terms: *Map[i64, i64], c: *i64, depth: i64) {
    i := &f.insts[v]
    if depth < 16 && i.ty == I64 {
        match i.op {
            Const => {
                *c = *c + mult * i.k
                return
            }
            Add, Sub => {
                a := i.args[0]
                b := i.args[1]
                vec_lin(f, a, mult, terms, c, depth + 1)
                vec_lin(f, b, if f.insts[v].op == Sub { -mult } else { mult }, terms, c, depth + 1)
                return
            }
            Mul => {
                for k in 0..2 {
                    match f.is_const(f.insts[v].args[1 - k]) {
                        Some(m) => {
                            vec_lin(f, f.insts[v].args[k], mult * m, terms, c, depth + 1)
                            return
                        }
                        None => {}
                    }
                }
            }
            Shl => {
                match f.is_const(i.args[1]) {
                    Some(s) if s >= 0 && s <= 32 => {
                        vec_lin(f, f.insts[v].args[0], mult << s, terms, c, depth + 1)
                        return
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    terms.set(v, terms.get_or(v, 0) + mult)
}

// Some(a - b) when the two addresses differ by a constant
priv fn vec_const_dist(f: *Func, a: i64, b: i64) -> Opt[i64] {
    ta := map[i64, i64]()
    ca := 0
    vec_lin(f, a, 1, &ta, &ca, 0)
    tb := map[i64, i64]()
    cb := 0
    vec_lin(f, b, 1, &tb, &cb, 0)
    for k in ta.keys() {
        if ta.get_or(k, 0) != tb.get_or(k, 0) {
            return None
        }
    }
    for k in tb.keys() {
        if ta.get_or(k, 0) != tb.get_or(k, 0) {
            return None
        }
    }
    return Some(ca - cb)
}

// Is data instruction v (lane type e) one the vector loop can do? `data` marks the data values.
priv fn vec_op_ok(f: *Func, v: i64, e: T, data: *Map[i64, bool], in_loop: []bool, def_block: []i32) -> bool {
    i := &f.insts[v]
    fl := e == F32 || e == F64
    // every operand: data or loop-invariant
    for a in i.args {
        if !data.has(a) && !loop_invariant(a, in_loop, def_block) {
            return false
        }
    }
    match i.op {
        Load => return true
        Add, Sub, And, Or, Xor => return !fl
        Mul => return e == I16 || e == I32
        Shl, LShr, AShr => {
            if fl || e == I8 || e == I64 && i.op == AShr {
                return false
            }
            // the count: the same in every lane
            return !data.has(i.args[1])
        }
        FAdd, FSub, FMul, FDiv, FSqrt, FNeg, FAbs, FMin, FMax => return fl
        Eq, Ne, Slt, Sle, Sgt, Sge, Ult, Ule, Ugt, Uge, FEq, FNe, FLt, FLe, FGt, FGe => {
            if i.op.is_icmp() == fl || e == I64 {
                return false
            }
            // a mask: only the condition of selects of the data
            for b in f.blocks[def_block[v]].insts {
                bi := &f.insts[b]
                for k, a in bi.args {
                    if a == v && (bi.op != Select || k != 0) {
                        return false
                    }
                }
            }
            return true
        }
        Select => return data.has(i.args[0]) && f.insts[i.args[0]].op.is_cmp()
        _ => return false
    }
}

struct VecAccess {
    v: i64       // the load or store
    addr: i64
    store: bool
}

// vectorizes loop li if it qualifies; true if it did
priv fn vec_try(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block: []i32) -> bool {
    cl := match loop_counted(f, cfg, loops, li, in_loop, def_block) {
        Some(c) => c
        None => return false
    }
    if f.insts[cl.cond].aux & (LOOP_NO_VEC | LOOP_NO_UNROLL) != 0 || cl.step != 1 || !loop_trip_known(&cl) {
        return false
    }
    if cl.blocks.len != 1 || !loop_single_exit(f, &cl, in_loop) || loop_has_call(f, &cl) || loop_size(f, &cl) > VEC_MAX_SIZE {
        return false
    }
    h := cl.header
    outside := loop_used_outside(f, in_loop, def_block)
    // the header phis: the counter and reductions
    reds := vec[Reduction]()
    data := map[i64, bool]()
    for v in f.blocks[h].insts {
        if f.insts[v].op != Phi {
            break
        }
        if i64(v) == cl.iv {
            continue
        }
        match loop_reduction(f, &cl, i64(v), in_loop, def_block, outside.items()) {
            Some(r) => {
                if r.kind == RED_MUL {
                    return false
                }
                reds.push(r)
                data.set(i64(v), true)
            }
            None => return false
        }
    }
    // the data: loads, reductions and what depends on them
    for v in f.blocks[h].insts {
        i := &f.insts[v]
        if i.op == Phi || i.op == Store {
            continue
        }
        if i.op == Load {
            data.set(i64(v), true)
            continue
        }
        for a in i.args {
            if data.has(a) {
                data.set(i64(v), true)
                break
            }
        }
    }
    // the lane size, the same for all data
    esz := 0
    e := Void
    fn lane_ok(t: T) -> bool {
        return t.is_int() || t == F32 || t == F64
    }
    for v in f.blocks[h].insts {
        i := &f.insts[v]
        t := if data.has(i64(v)) {
            vec_lane_ty(f, i64(v))
        } else if i.op == Store {
            i.ty
        } else {
            continue
        }
        if !lane_ok(t) || esz != 0 && t.size() != esz {
            return false
        }
        if esz == 0 {
            esz = t.size()
            e = t
        }
    }
    if esz == 0 {
        return false
    }
    vf := 16 / esz
    // the instructions: scalar ones are pure and feed only addresses; data ones are supported
    accs := vec[VecAccess]()
    ndata := 0
    for v in f.blocks[h].insts {
        vi := i64(v)
        i := &f.insts[vi]
        if i.op == Phi {
            continue
        }
        if i.op == Store {
            addr := i.args[0]
            val := i.args[1]
            if data.has(addr) || !data.has(val) && !loop_invariant(val, in_loop, def_block) {
                return false
            }
            match loop_affine_coef(f, &cl, addr, in_loop, def_block) {
                Some(c) if c == esz => {}
                _ => return false
            }
            accs.push(VecAccess{v: vi, addr: addr, store: true})
            continue
        }
        if !data.has(vi) {
            if vi != cl.cond && !i.op.is_pure() {
                return false
            }
            continue
        }
        ndata += 1
        if i.op == Load {
            addr := i.args[0]
            if data.has(addr) {
                return false
            }
            match loop_affine_coef(f, &cl, addr, in_loop, def_block) {
                Some(c) if c == esz => {}
                _ => return false
            }
            accs.push(VecAccess{v: vi, addr: addr, store: false})
            continue
        }
        // (an operation's lanes: the type of the data, a compare's operands too)
        if !vec_op_ok(f, vi, vec_lane_ty(f, vi), &data, in_loop, def_block) {
            return false
        }
        if i.op.is_cmp() && f.insts[i.args[0]].ty.size() != esz {
            return false
        }
    }
    // a data value used by a scalar instruction (an address from loaded data) or by the branch
    for v in f.blocks[h].insts {
        i := &f.insts[v]
        if data.has(i64(v)) || i.op == Phi {
            continue
        }
        for k, a in i.args {
            if data.has(a) && !(i.op == Store && k == 1) {
                return false
            }
        }
    }
    for x in term_args(&f.blocks[h].term) {
        if data.has(x) {
            return false
        }
    }
    // values used after the loop: the reductions' results and the counter's next value
    for x in outside {
        ok := x == cl.next
        for r in reds {
            if r.back == x {
                ok = true
            }
        }
        if !ok {
            return false
        }
    }
    // interleave two vectors when the registers allow it: the partial results and the splats
    // stay in registers, the rest are short-lived temporaries (four per copy, roughly)
    ninv := map[i64, bool]()
    for v in f.blocks[h].insts {
        if data.has(i64(v)) || f.insts[v].op == Store {
            for a in f.insts[v].args {
                if !data.has(a) && loop_invariant(a, in_loop, def_block) && f.insts[v].op != Store {
                    ninv.set(a, true)
                }
            }
        }
    }
    u := if 2 * (reds.len + 4) + ninv.len <= 16 && ndata <= 24 { 2 } else { 1 }
    w := vf * u
    match loop_const_trip(f, &cl) {
        Some(t) => {
            if t < 2 * w && u == 2 {
                u = 1
                w = vf
            }
            if t < 2 * w {
                return false
            }
        }
        None => {}
    }
    // the memory dependences
    esc := vec[bool]()
    checks := vec[(i64, i64)]()
    span := w * esz
    for x in 0..accs.len {
        for y in x + 1..accs.len {
            a := &accs[x]
            b := &accs[y]
            if !a.store && !b.store {
                continue
            }
            match vec_const_dist(f, a.addr, b.addr) {
                Some(d) => {
                    if d != 0 && d > -span && d < span {
                        return false
                    }
                    continue
                }
                None => {}
            }
            if esc.len == 0 {
                esc = alias_escaped_allocas(f)
            }
            ma := alias_memref(f, a.v)
            mb := alias_memref(f, b.v)
            if !alias_may_alias(&ma, &mb, esc.items()) {
                continue
            }
            checks.push((a.addr, b.addr))
        }
    }
    if checks.len > VEC_MAX_CHECKS {
        return false
    }
    vec_apply(f, &cl, e, vf, u, &reds, &data, &checks, &outside, in_loop, def_block)
    return true
}

// a vector with the loop-invariant scalar x in every lane (made once, in block pre)
priv fn vec_splat(f: *Func, pre: i64, splats: *IMap, x: i64, vt: T) -> i64 {
    s := splats.iget(x)
    if s >= 0 {
        return s
    }
    s = f.push(pre, VSplat, vt, vec_one(x), 0)
    splats.iset(x, s)
    return s
}

priv struct VB {
    list: Vec[i32] // the new instructions of the header
    vm: IMap       // vk(value, copy) -> its vector
    splats: IMap   // invariant scalar -> its splat
    negs: IMap     // vk(compare, copy) -> 1 when its mask is the negation of the compare
    pre: i64
}

// a new instruction at the end of the vector loop's list, with the source location of `like`
priv fn vb_add(f: *Func, b: *VB, op: Op, ty: T, args: Vec[i64], k: i64, like: i64) -> i64 {
    v := f.mk(op, ty, args, k)
    f.im(v).set_srcloc(f.insts[like].srcloc())
    b.list.push(i32(v))
    return v
}

// copy k of operand x of the data: its vector, or the splat of an invariant
priv fn vb_opnd(f: *Func, b: *VB, x: i64, k: i64, vt: T) -> i64 {
    y := b.vm.iget(vk(x, k))
    if y >= 0 {
        return y
    }
    return vec_splat(f, b.pre, &b.splats, x, vt)
}

priv fn vec_apply(f: *Func, cl: *CLoop, e: T, vf: i64, u: i64, reds: *Vec[Reduction], data: *Map[i64, bool], checks: *Vec[(i64, i64)], outside: *Vec[i64], in_loop: []bool, def_block: []i32) {
    h := cl.header
    w := vf * u
    esz := e.size()
    vt := vec_for(e)
    orig := clone(f.blocks[h].insts)
    rem := loop_remainder_begin(f, cl, w)
    rc := rem.rv.iget(cl.cond)
    f.im(rc).aux = f.insts[rc].aux | LOOP_NO_VEC | LOOP_NO_IDIOM
    pre := cl.pre
    // the run-time distance tests, at the start values, in chk
    if checks.len > 0 {
        chk := rem.chk
        big := match f.blocks[chk].term {
            Br(c, _, _) => c
            _ => NOV
        }
        ok := big
        for c in checks {
            a0 := loop_expr_at(f, cl, chk, c.0, cl.start, in_loop, def_block)
            b0 := loop_expr_at(f, cl, chk, c.1, cl.start, in_loop, def_block)
            d := f.push(chk, Sub, I64, vec_two(a0, b0), 0)
            z := f.push(chk, Eq, I8, vec_two(d, loop_const(f, chk, I64, 0)), 0)
            sh := f.push(chk, Add, I64, vec_two(d, loop_const(f, chk, I64, w * esz - 1)), 0)
            far := f.push(chk, Uge, I8, vec_two(sh, loop_const(f, chk, I64, 2 * w * esz - 1)), 0)
            one := f.push(chk, Or, I8, vec_two(z, far), 0)
            ok = f.push(chk, And, I8, vec_two(ok, one), 0)
        }
        f.blocks[chk].term = Br(ok, h, rem.rpre)
    }
    b := VB{list: vec[i32](), vm: imap_new(4 * orig.len), splats: imap_new(8), negs: imap_new(8), pre: pre}
    // the phis: the counter, then the vector partial results of the reductions
    b.list.push(i32(cl.iv))
    acc_init := vec[i64]()
    for r in reds {
        rt := vec_for(f.insts[r.phi].ty)
        st := f.insts[r.phi].phi_input(rem.chk)
        init := match r.kind {
            RED_SMIN, RED_SMAX, RED_UMIN, RED_UMAX => f.push(pre, VSplat, rt, vec_one(st), 0)
            _ => f.push(pre, VSplat, rt, vec_one(loop_red_init(f, pre, &r, st)), 0)
        }
        acc_init.push(init)
        for k in 0..u {
            p := f.mk_phi(rt, 2)
            b.list.push(i32(p))
            b.vm.iset(vk(r.phi, k), p)
        }
    }
    // the body
    for v0 in orig {
        v := i64(v0)
        op := f.insts[v].op
        if op == Phi || v == cl.cond {
            continue
        }
        if op == Store {
            addr := f.insts[v].args[0]
            val := f.insts[v].args[1]
            aux := f.insts[v].aux
            st := vec_for(f.insts[v].ty)
            for k in 0..u {
                a := if k == 0 { addr } else { vb_add(f, &b, Add, I64, vec_two(addr, loop_const_mk(f, &b, 16 * k)), 0, v) }
                x := vb_opnd(f, &b, val, k, st)
                s := vb_add(f, &b, Store, st, vec_two(a, x), 0, v)
                f.im(s).aux = aux
            }
            continue
        }
        if !data.has(v) {
            // a scalar: the address of lane 0
            b.list.push(v0)
            continue
        }
        for k in 0..u {
            vec_inst(f, &b, v, k, vt)
        }
    }
    // the counter steps by w; the loop goes on until it reaches ue
    nn := vb_add(f, &b, Add, cl.ty, vec_two(cl.iv, loop_const_mk_ty(f, &b, cl.ty, w)), 0, cl.next)
    c2 := vb_add(f, &b, Ne, I8, vec_two(nn, rem.ue), 0, cl.cond)
    f.im(c2).aux = LOOP_NO_UNROLL | LOOP_NO_IDIOM | LOOP_NO_VEC
    f.blocks[h].insts = b.list
    f.blocks[h].term = Br(c2, h, rem.mid)
    ivi := f.im(cl.iv)
    for k in 0..ivi.args.len {
        if ivi.from()[k] == cl.latch {
            ivi.args[k] = nn
        }
    }
    for ri in 0..reds.len {
        r := &reds[ri]
        for k in 0..u {
            p := b.vm.iget(vk(r.phi, k))
            f.im(p).phi_set([]i64{acc_init[ri], b.vm.iget(vk(r.back, k))}, []i64{rem.chk, h})
        }
    }
    // after the vector loop (mid): the partial results combined
    mid := rem.mid
    fin := imap_new(outside.len + reds.len + 1)
    fin.iset(cl.next, nn)
    for r in reds {
        ty := f.insts[r.phi].ty
        rt := vec_for(ty)
        acc := b.vm.iget(vk(r.back, 0))
        for k in 1..u {
            acc = vec_combine(f, mid, r.kind, rt, acc, b.vm.iget(vk(r.back, k)))
        }
        half := 8
        while half >= ty.size() {
            t := f.push(mid, VBin, rt, vec_one(acc), VK_BSRL | half << 8)
            acc = vec_combine(f, mid, r.kind, rt, acc, t)
            half /= 2
        }
        s := f.push(mid, VExt, ty, vec_one(acc), 0)
        st := f.insts[r.phi].phi_input(rem.chk)
        fin.iset(r.back, loop_red_combine(f, mid, &r, st, s))
    }
    loop_remainder_end(f, cl, &rem, &fin, outside.items(), in_loop, def_block)
    // (-g: the variables that had the replaced scalar values are not shown in the loop)
    if f.dexp.len > 0 {
        forget := vec_fill(f.insts.len, i32(NOV))
        for v in orig {
            if data.has(i64(v)) {
                forget[v] = 0
            }
        }
        dbg_forget(f, &forget)
    }
}

// an i64 constant in the vector loop's list
priv fn loop_const_mk(f: *Func, b: *VB, k: i64) -> i64 {
    return loop_const_mk_ty(f, b, I64, k)
}

priv fn loop_const_mk_ty(f: *Func, b: *VB, ty: T, k: i64) -> i64 {
    v := f.mk(Const, ty, vec[i64](), ir_canon(ty, k))
    b.list.push(i32(v))
    return v
}

// the combination of two vectors of partial results of a reduction of kind `kind`, in block blk
priv fn vec_combine(f: *Func, blk: i64, kind: i64, rt: T, x: i64, y: i64) -> i64 {
    match kind {
        RED_ADD => return f.push(blk, VBin, rt, vec_two(x, y), VK_ADD)
        RED_AND => return f.push(blk, VBin, rt, vec_two(x, y), VK_AND)
        RED_OR => return f.push(blk, VBin, rt, vec_two(x, y), VK_OR)
        RED_XOR => return f.push(blk, VBin, rt, vec_two(x, y), VK_XOR)
        _ => {}
    }
    // min / max: m = x > y (signed or not), then the smaller or larger
    gt := f.push(blk, VBin, rt, vec_two(x, y), if kind == RED_SMIN || kind == RED_SMAX { VK_CGT } else { VK_CGTU })
    if kind == RED_SMIN || kind == RED_UMIN {
        return f.push(blk, VBin, rt, vec_of([]i64{gt, y, x}), VK_SEL)
    }
    return f.push(blk, VBin, rt, vec_of([]i64{gt, x, y}), VK_SEL)
}

// copy k of the vector form of data instruction v
priv fn vec_inst(f: *Func, b: *VB, v: i64, k: i64, vt0: T) {
    src := f.insts[v]
    e := vec_lane_ty(f, v)
    vt := vec_for(e)
    fn opn(f: *Func, b: *VB, src: *Inst, j: i64, k: i64, vt: T) -> i64 {
        return vb_opnd(f, b, src.args[j], k, vt)
    }
    r := NOV
    match src.op {
        Load => {
            addr := src.args[0]
            a := if k == 0 { addr } else { vb_add(f, b, Add, I64, vec_two(addr, loop_const_mk(f, b, 16 * k)), 0, v) }
            r = vb_add(f, b, Load, vt, vec_one(a), 0, v)
            f.im(r).aux = src.aux
        }
        Add, Sub, Mul, And, Or, Xor, FAdd, FSub, FMul, FDiv, FMin, FMax => {
            kind := match src.op {
                Add, FAdd => VK_ADD
                Sub, FSub => VK_SUB
                Mul, FMul => VK_MUL
                And => VK_AND
                Or => VK_OR
                Xor => VK_XOR
                FDiv => VK_FDIV
                FMin => VK_FMIN
                _ => VK_FMAX
            }
            x := opn(f, b, &src, 0, k, vt)
            y := opn(f, b, &src, 1, k, vt)
            r = vb_add(f, b, VBin, vt, vec_two(x, y), kind, v)
        }
        FSqrt, FNeg, FAbs => {
            kind := match src.op {
                FSqrt => VK_FSQRT
                FNeg => VK_FNEG
                _ => VK_FABS
            }
            x := opn(f, b, &src, 0, k, vt)
            r = vb_add(f, b, VBin, vt, vec_one(x), kind, v)
        }
        Shl, LShr, AShr => {
            kind := match src.op {
                Shl => VK_SHL
                LShr => VK_LSHR
                _ => VK_ASHR
            }
            x := opn(f, b, &src, 0, k, vt)
            bits := e.bits()
            match f.is_const(src.args[1]) {
                Some(c) => r = vb_add(f, b, VBin, vt, vec_one(x), kind | (c & (bits - 1)) << 8, v)
                None => {
                    // the count masked as the scalar shift does, as an i64, before the loop
                    key := -2 - src.args[1]
                    n := b.splats.iget(key)
                    if n < 0 {
                        ct := f.insts[src.args[1]].ty
                        m := f.push(b.pre, And, ct, vec_two(src.args[1], loop_const(f, b.pre, ct, bits - 1)), 0)
                        n = if ct == I64 { m } else { f.push(b.pre, ZExt, I64, vec_one(m), 0) }
                        b.splats.iset(key, n)
                    }
                    r = vb_add(f, b, VBin, vt, vec_two(x, n), kind, v)
                }
            }
        }
        Select => {
            c := src.args[0]
            m := b.vm.iget(vk(c, k))
            neg := b.negs.iget(vk(c, k)) == 1
            x := opn(f, b, &src, 1, k, vt)
            y := opn(f, b, &src, 2, k, vt)
            r = if neg {
                vb_add(f, b, VBin, vt, vec_of([]i64{m, y, x}), VK_SEL, v)
            } else {
                vb_add(f, b, VBin, vt, vec_of([]i64{m, x, y}), VK_SEL, v)
            }
        }
        _ => {
            // a compare: a mask, possibly of the negated compare
            x := opn(f, b, &src, 0, k, vt)
            y := opn(f, b, &src, 1, k, vt)
            neg := false
            swap := false
            kind := VK_CGT
            imm := 0
            match src.op {
                Eq => kind = VK_CEQ
                Ne => {
                    kind = VK_CEQ
                    neg = true
                }
                Sgt => {}
                Slt => swap = true
                Sle => neg = true
                Sge => {
                    swap = true
                    neg = true
                }
                Ugt => kind = VK_CGTU
                Ult => {
                    kind = VK_CGTU
                    swap = true
                }
                Ule => {
                    kind = VK_CGTU
                    neg = true
                }
                Uge => {
                    kind = VK_CGTU
                    swap = true
                    neg = true
                }
                FEq => kind = VK_FCMP
                FNe => {
                    kind = VK_FCMP
                    imm = 4
                }
                FLt => {
                    kind = VK_FCMP
                    imm = 1
                }
                FLe => {
                    kind = VK_FCMP
                    imm = 2
                }
                FGt => {
                    kind = VK_FCMP
                    imm = 1
                    swap = true
                }
                _ => {
                    kind = VK_FCMP
                    imm = 2
                    swap = true
                }
            }
            r = if swap {
                vb_add(f, b, VBin, vt, vec_two(y, x), kind | imm << 8, v)
            } else {
                vb_add(f, b, VBin, vt, vec_two(x, y), kind | imm << 8, v)
            }
            if neg {
                b.negs.iset(vk(v, k), 1)
            }
        }
    }
    b.vm.iset(vk(v, k), r)
}

// Vectorizes every qualifying loop (see above); true if one changed.
fn vec_run(f: *Func) -> bool {
    if !vec_enabled() || f.size() > 20000 {
        return false
    }
    return loop_each_innermost(f, vec_try)
}
