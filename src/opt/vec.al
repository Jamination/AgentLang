// The loop vectorizer: an innermost counted loop of one block (its bounds checks already
// hoisted by BCE, after if-conversion) that counts up by 1 and whose memory accesses are to
// consecutive elements becomes a loop over 128-bit vectors (SSE2 on x86-64) that runs W
// iterations at a time, followed by the original loop for the iterations that are left
// (loop_remainder_begin / _end in loop.al):
//
//     for i in 0..n { y[i] = y[i] + a * x[i] }       f64: W = 4, two vectors of 2 lanes
//     for i in 0..n { s += x[i] * y[i] }             wrapping u32 sum: partial sums in lanes
//     for x in 0..w { acc[x] += u32(row[x]) }        W = 16: one vector of u8, four of u32
//
// The data of the loop (its loads, its reductions and what is computed from them) is
// vectorized; every data value has a lane size (its type's; a compare's: its operands'), and a
// value of lane size s takes W * s / 16 vectors ("parts", part p holding iterations
// p * 16 / s ...): W = 16 / (the smallest lane size), times 2 (two interleaved vectors) when all
// lane sizes are equal and the registers allow it. What can be data:
//   - loads and stores at addresses that advance by the element size per iteration
//     (loop_affine_coef); a stored value is data or loop-invariant;
//   - integer +, -, &, |, ^ (all sizes), * (i16, i32), high halves of products (i16; unsigned
//     i32), shifts by a loop-invariant count (i16, i32, i64 lanes; not >> of i64), compares (not
//     of i64) as the conditions of selects of their lane size or as 0 / 1 extended to a wider
//     integer; zero / sign extension and truncation between integer sizes;
//   - float +, -, *, /, sqrt, min, max, neg, abs, compares as the conditions of selects;
//   - operands that are loop-invariant (a vector with the value in every lane, made before the
//     loop);
//   - integer reductions (loop_reduction: +, -, &, |, ^, min, max, which wrap exactly in any
//     order): partial results in the lanes, combined after the loop. A sum of bytes widened to
//     a larger integer (or of the 0 / 1 of byte compares) adds 8 bytes at a time into 64-bit
//     lanes (psadbw). Float reductions are never reductions (the order of IEEE operations stays
//     as written): such loops stay scalar.
// Everything else that the loop computes must be scalar values from the counter and invariants,
// used only as addresses (they are kept and give the address of the first iteration of the
// group). Not vectorized: loops with calls, side exits (a check that BCE did not hoist),
// divisions, float conversions, accesses with another stride, values used after the loop other
// than reductions, values computed from the counter used as data, and loops known to run fewer
// than 2 * W times.
//
// Memory: of two accesses of which one is a store, either alias analysis proves them apart,
// or they have a constant distance d (same address expression up to a constant, same element
// size E) with d == 0 or |d| >= W * E bytes, or they are tested before the vector loop (else the
// scalar loop runs): same element size: their distance at the first iteration is 0 or at least
// W * E in either direction; different sizes: the ranges the whole loop covers are apart. With
// that, two iterations whose accesses overlap are never in the same group of W iterations (or
// they are the same iteration, whose accesses keep their order), and the groups run in order.
// Bounds: the loop has no checks left (no exit but its latch), and the vector loop reads and
// writes only elements the scalar loop would (the remainder runs the rest): nothing is loaded
// past the range of the scalar loop.
//
// The vector loop and the remainder are marked (LOOP_NO_VEC, LOOP_NO_UNROLL): runtime unrolling
// leaves them alone. x86-64 only (vec_enabled; arm64 keeps the scalar loops).

priv const VEC_MAX_SIZE = 80 // instructions and terminator of the loop
priv const VEC_MAX_CHECKS = 16 // run-time tests of distances
priv const VEC_MAX_PARTS = 8 // vectors of one value

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

// the integer type of n bytes
priv fn vec_int_of(n: i64) -> T {
    return match n {
        1 => I8
        2 => I16
        4 => I32
        _ => I64
    }
}

// key of part p of value v in the vector map
priv inline fn vk(v: i64, p: i64) -> i64 {
    return v * 16 + p
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

// the users of v in its block
priv fn vec_users(f: *Func, b: i64, v: i64) -> Vec[i64] {
    out := vec[i64]()
    for u in f.blocks[b].insts {
        if contains(f.insts[u].args, v) {
            out.push(i64(u))
        }
    }
    return out
}

// Is data instruction v one the vector loop can do? `data` marks the data values.
priv fn vec_op_ok(f: *Func, v: i64, data: *Map[i64, bool], in_loop: []bool, def_block: []i32) -> bool {
    i := &f.insts[v]
    e := vec_lane_ty(f, v)
    fl := e == F32 || e == F64
    if !e.is_int() && !fl {
        return false
    }
    if i.op == Load {
        // (its address is checked by the caller)
        return true
    }
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
        MulHiU => return e == I16 || e == I32
        MulHiS => return e == I16
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
            // a mask: the condition of selects of its lane size, or extended as 0 / 1
            for u in vec_users(f, i64(def_block[v]), v) {
                ui := &f.insts[u]
                if ui.op == Select && ui.args[0] == v && ui.args[1] != v && ui.args[2] != v && ui.ty.size() == e.size() {
                    continue
                }
                if ui.op == ZExt && ui.ty.is_int() && !fl && ui.ty.size() >= e.size() {
                    continue
                }
                return false
            }
            return true
        }
        Select => return data.has(i.args[0]) && f.insts[i.args[0]].op.is_cmp()
        ZExt => {
            x := i.args[0]
            return data.has(x) && i.ty.is_int() && (f.insts[x].ty.is_int() || f.insts[x].op.is_cmp())
        }
        SExt => {
            x := i.args[0]
            return data.has(x) && i.ty.is_int() && f.insts[x].ty.is_int() && !f.insts[x].op.is_cmp()
        }
        Trunc => {
            x := i.args[0]
            return data.has(x) && i.ty.is_int() && f.insts[x].ty.is_int() && !f.insts[x].op.is_cmp()
        }
        _ => return false
    }
}

struct VecAccess {
    v: i64       // the load or store
    addr: i64
    size: i64    // the element size
    store: bool
}

// what vec_apply needs
priv struct VPlan {
    w: i64                // iterations per vector iteration
    lsz: Map[i64, i64]    // the lane size of each data value
    data: Map[i64, bool]
    sad: Map[i64, bool]   // reductions that sum bytes with psadbw: their phis, adds and extensions
    reds: Vec[Reduction]
    checks: Vec[(i64, i64, i64, i64)] // run-time tests: addresses, element sizes
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
    // sums of bytes (psadbw): s = s + zext(x), x bytes (or byte compares), the extension used
    // by the add alone, the add the only step of the reduction
    sad := map[i64, bool]()
    for r in reds {
        bi := &f.insts[r.back]
        pt := f.insts[r.phi].ty
        if r.kind != RED_ADD || bi.op != Add || pt == I8 {
            continue
        }
        z := if bi.args[0] == r.phi { bi.args[1] } else { bi.args[0] }
        zi := &f.insts[z]
        if bi.args[0] != r.phi && bi.args[1] != r.phi || zi.op != ZExt || !data.has(zi.args[0]) {
            continue
        }
        x := zi.args[0]
        if vec_lane_ty(f, x).size() != 1 || vec_users(f, h, z).len != 1 || vec_users(f, h, r.phi).len != 1 {
            continue
        }
        sad.set(r.phi, true)
        sad.set(r.back, true)
        sad.set(z, true)
    }
    // the instructions: scalar ones are pure and feed only addresses; data ones are supported;
    // the lane sizes
    accs := vec[VecAccess]()
    lsz := map[i64, i64]()
    smin := 16
    smax := 0
    ndata := 0
    for v in f.blocks[h].insts {
        vi := i64(v)
        i := &f.insts[vi]
        s := 0
        if i.op == Store {
            addr := i.args[0]
            val := i.args[1]
            s = i.ty.size()
            if data.has(addr) || !data.has(val) && !loop_invariant(val, in_loop, def_block) {
                return false
            }
            if !i.ty.is_int() && i.ty != F32 && i.ty != F64 || data.has(val) && lsz.get_or(val, 0) != s {
                return false
            }
            match loop_affine_coef(f, &cl, addr, in_loop, def_block) {
                Some(c) if c == s => {}
                _ => return false
            }
            accs.push(VecAccess{v: vi, addr: addr, size: s, store: true})
        } else if data.has(vi) {
            ndata += 1
            if sad.has(vi) {
                s = 1
            } else {
                s = vec_lane_ty(f, vi).size()
                if i.op != Phi && !vec_op_ok(f, vi, &data, in_loop, def_block) {
                    return false
                }
            }
            if i.op == Load {
                addr := i.args[0]
                if data.has(addr) {
                    return false
                }
                match loop_affine_coef(f, &cl, addr, in_loop, def_block) {
                    Some(c) if c == s => {}
                    _ => return false
                }
                accs.push(VecAccess{v: vi, addr: addr, size: s, store: false})
            }
            lsz.set(vi, s)
        } else {
            if i.op != Phi && !i.op.is_pure() {
                return false
            }
            continue
        }
        smin = min(smin, s)
        smax = max(smax, s)
    }
    if smax == 0 {
        return false
    }
    // a data value used by a scalar instruction (an address from loaded data) or by the branch
    for v in f.blocks[h].insts {
        i := &f.insts[v]
        if data.has(i64(v)) {
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
    // interleave two vectors when all lanes have one size and the registers allow it: the
    // partial results and the splats stay in registers, the rest are short-lived temporaries
    // (four per copy, roughly)
    ninv := map[i64, bool]()
    for v in f.blocks[h].insts {
        if data.has(i64(v)) {
            for a in f.insts[v].args {
                if !data.has(a) && loop_invariant(a, in_loop, def_block) {
                    ninv.set(a, true)
                }
            }
        }
    }
    u := if smin == smax && 2 * (reds.len + 4) + ninv.len <= 16 && ndata <= 24 { 2 } else { 1 }
    w := u * 16 / smin
    if w * smax / 16 > VEC_MAX_PARTS {
        return false
    }
    match loop_const_trip(f, &cl) {
        Some(t) => {
            if t < 2 * w && u == 2 {
                u = 1
                w = 16 / smin
            }
            if t < 2 * w {
                return false
            }
        }
        None => {}
    }
    // the memory dependences
    esc := vec[bool]()
    checks := vec[(i64, i64, i64, i64)]()
    for x in 0..accs.len {
        for y in x + 1..accs.len {
            a := &accs[x]
            b := &accs[y]
            if !a.store && !b.store {
                continue
            }
            if a.size == b.size {
                match vec_const_dist(f, a.addr, b.addr) {
                    Some(d) => {
                        span := w * a.size
                        if d != 0 && d > -span && d < span {
                            return false
                        }
                        continue
                    }
                    None => {}
                }
            }
            if esc.len == 0 {
                esc = alias_escaped_allocas(f)
            }
            ma := alias_memref(f, a.v)
            mb := alias_memref(f, b.v)
            if !alias_may_alias(&ma, &mb, esc.items()) {
                continue
            }
            checks.push((a.addr, b.addr, a.size, b.size))
        }
    }
    if checks.len > VEC_MAX_CHECKS {
        return false
    }
    plan := VPlan{w: w, lsz: lsz, data: data, sad: sad, reds: reds, checks: checks}
    vec_apply(f, &cl, &plan, &outside, in_loop, def_block)
    return true
}

priv struct VB {
    list: Vec[i32] // the new instructions of the header
    vm: IMap       // vk(value, part) -> its vector
    splats: IMap   // invariant scalar -> its splat (-2 - x: a masked shift count)
    negs: IMap     // vk(compare, part) -> 1 when its mask is the negation of the compare
    pre: i64
    w: i64
}

// a new instruction at the end of the vector loop's list, with the source location of `like`
priv fn vb_add(f: *Func, b: *VB, op: Op, ty: T, args: Vec[i64], k: i64, like: i64) -> i64 {
    v := f.mk(op, ty, args, k)
    f.im(v).set_srcloc(f.insts[like].srcloc())
    b.list.push(i32(v))
    return v
}

// a VBin in the vector loop
priv fn vb_op(f: *Func, b: *VB, ty: T, args: Vec[i64], k: i64, like: i64) -> i64 {
    return vb_add(f, b, VBin, ty, args, k, like)
}

// an i64 constant in the vector loop's list
priv fn vb_const(f: *Func, b: *VB, ty: T, k: i64) -> i64 {
    v := f.mk(Const, ty, vec[i64](), ir_canon(ty, k))
    b.list.push(i32(v))
    return v
}

// a vector with the loop-invariant scalar x in every lane (made once, before the loop)
priv fn vb_splat(f: *Func, b: *VB, x: i64) -> i64 {
    s := b.splats.iget(x)
    if s >= 0 {
        return s
    }
    s = f.push(b.pre, VSplat, vec_for(f.insts[x].ty), vec_one(x), 0)
    b.splats.iset(x, s)
    return s
}

// a splat of the constant k of type ty
priv fn vb_splat_const(f: *Func, b: *VB, ty: T, k: i64) -> i64 {
    return vb_splat(f, b, loop_const(f, b.pre, ty, k))
}

// part p of operand x of the data: its vector, or the splat of an invariant
priv fn vb_opnd(f: *Func, b: *VB, x: i64, p: i64) -> i64 {
    y := b.vm.iget(vk(x, p))
    if y >= 0 {
        return y
    }
    return vb_splat(f, b, x)
}

// part p of compare c (lane size s) as integers 0 / 1
priv fn vb_bool01(f: *Func, b: *VB, c: i64, p: i64, like: i64) -> i64 {
    s := f.insts[f.insts[c].args[0]].ty.size()
    it := vec_int_of(s)
    vt := vec_for(it)
    m := b.vm.iget(vk(c, p))
    if b.negs.iget(vk(c, p)) == 1 {
        // the mask of the negation: -1 + 1 = 0, 0 + 1 = 1
        return vb_op(f, b, vt, vec_two(m, vb_splat_const(f, b, it, 1)), VK_ADD, like)
    }
    return vb_op(f, b, vt, vec_two(vb_splat_const(f, b, it, 0), m), VK_SUB, like)
}

// the integer lanes of vector x (lane size si) extended to size so: the section j (of so / si)
// of its lanes
priv fn vb_ext(f: *Func, b: *VB, x: i64, si: i64, so: i64, j: i64, signed: bool, like: i64) -> i64 {
    r := so / si
    if r == 1 {
        return x
    }
    half := r / 2
    wt := vec_for(vec_int_of(2 * si))
    kind := if signed { if j / half == 0 { VK_SLO } else { VK_SHI } } else { if j / half == 0 { VK_ZLO } else { VK_ZHI } }
    mid := vb_op(f, b, wt, vec_one(x), kind, like)
    return vb_ext(f, b, mid, 2 * si, so, j % half, signed, like)
}

priv fn vec_apply(f: *Func, cl: *CLoop, plan: *VPlan, outside: *Vec[i64], in_loop: []bool, def_block: []i32) {
    h := cl.header
    w := plan.w
    reds := &plan.reds
    orig := clone(f.blocks[h].insts)
    rem := loop_remainder_begin(f, cl, w)
    rc := rem.rv.iget(cl.cond)
    f.im(rc).aux = f.insts[rc].aux | LOOP_NO_VEC | LOOP_NO_IDIOM
    pre := cl.pre
    // the run-time tests, in chk
    if plan.checks.len > 0 {
        chk := rem.chk
        ok := match f.blocks[chk].term {
            Br(c, _, _) => c
            _ => NOV
        }
        tc := NOV
        for c in plan.checks {
            a0 := loop_expr_at(f, cl, chk, c.0, cl.start, in_loop, def_block)
            b0 := loop_expr_at(f, cl, chk, c.1, cl.start, in_loop, def_block)
            d := f.push(chk, Sub, I64, vec_two(a0, b0), 0)
            one := NOV
            if c.2 == c.3 {
                // the distance is 0 or at least w elements either way
                span := w * c.2
                z := f.push(chk, Eq, I8, vec_two(d, loop_const(f, chk, I64, 0)), 0)
                sh := f.push(chk, Add, I64, vec_two(d, loop_const(f, chk, I64, span - 1)), 0)
                far := f.push(chk, Uge, I8, vec_two(sh, loop_const(f, chk, I64, 2 * span - 1)), 0)
                one = f.push(chk, Or, I8, vec_two(z, far), 0)
            } else {
                // the ranges [a0, a0 + tc * size) are apart
                if tc == NOV {
                    tc = loop_trip_count(f, cl, chk)
                    if cl.ty != I64 {
                        tc = f.push(chk, ZExt, I64, vec_one(tc), 0)
                    }
                }
                na := f.push(chk, Mul, I64, vec_two(tc, loop_const(f, chk, I64, c.2)), 0)
                nb := f.push(chk, Mul, I64, vec_two(tc, loop_const(f, chk, I64, c.3)), 0)
                d2 := f.push(chk, Sub, I64, vec_two(b0, a0), 0)
                x1 := f.push(chk, Uge, I8, vec_two(d, nb), 0)
                x2 := f.push(chk, Uge, I8, vec_two(d2, na), 0)
                one = f.push(chk, And, I8, vec_two(x1, x2), 0)
            }
            ok = f.push(chk, And, I8, vec_two(ok, one), 0)
        }
        f.blocks[chk].term = Br(ok, h, rem.rpre)
    }
    b := VB{list: vec[i32](), vm: imap_new(8 * orig.len), splats: imap_new(8), negs: imap_new(8), pre: pre, w: w}
    // the phis: the counter, then the vector partial results of the reductions
    b.list.push(i32(cl.iv))
    acc_init := vec[i64]()
    for r in reds {
        pt := f.insts[r.phi].ty
        st := f.insts[r.phi].phi_input(rem.chk)
        sd := plan.sad.has(r.phi)
        rt := if sd { VI64 } else { vec_for(pt) }
        init := match r.kind {
            RED_SMIN, RED_SMAX, RED_UMIN, RED_UMAX => f.push(pre, VSplat, rt, vec_one(st), 0)
            _ => f.push(pre, VSplat, rt, vec_one(if sd { loop_const(f, pre, I64, 0) } else { loop_red_init(f, pre, &r, st) }), 0)
        }
        acc_init.push(init)
        np := w * plan.lsz.get_or(r.phi, 0) / 16
        for p in 0..np {
            ph := f.mk_phi(rt, 2)
            b.list.push(i32(ph))
            b.vm.iset(vk(r.phi, p), ph)
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
            np := w * f.insts[v].ty.size() / 16
            for p in 0..np {
                a := if p == 0 { addr } else { vb_add(f, &b, Add, I64, vec_two(addr, vb_const(f, &b, I64, 16 * p)), 0, v) }
                x := vb_opnd(f, &b, val, p)
                s := vb_add(f, &b, Store, st, vec_two(a, x), 0, v)
                f.im(s).aux = aux
            }
            continue
        }
        if !plan.data.has(v) {
            // a scalar: an address of the group's first iteration
            b.list.push(v0)
            continue
        }
        if plan.sad.has(v) {
            if f.insts[v].op == Add {
                vec_sad_add(f, &b, plan, v)
            }
            continue
        }
        np := w * plan.lsz.get_or(v, 0) / 16
        for p in 0..np {
            vec_inst(f, &b, plan, v, p)
        }
    }
    // the counter steps by w; the loop goes on until it reaches ue
    nn := vb_add(f, &b, Add, cl.ty, vec_two(cl.iv, vb_const(f, &b, cl.ty, w)), 0, cl.next)
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
        np := w * plan.lsz.get_or(r.phi, 0) / 16
        for p in 0..np {
            ph := b.vm.iget(vk(r.phi, p))
            f.im(ph).phi_set([]i64{acc_init[ri], b.vm.iget(vk(r.back, p))}, []i64{rem.chk, h})
        }
    }
    // after the vector loop (mid): the partial results combined
    mid := rem.mid
    fin := imap_new(outside.len + reds.len + 1)
    fin.iset(cl.next, nn)
    for r in reds {
        pt := f.insts[r.phi].ty
        sd := plan.sad.has(r.phi)
        lt := if sd { I64 } else { pt }
        rt := vec_for(lt)
        kind := r.kind
        np := w * plan.lsz.get_or(r.phi, 0) / 16
        acc := b.vm.iget(vk(r.back, 0))
        for p in 1..np {
            acc = vec_combine(f, mid, kind, rt, acc, b.vm.iget(vk(r.back, p)))
        }
        half := 8
        while half >= lt.size() {
            t := f.push(mid, VBin, rt, vec_one(acc), VK_BSRL | half << 8)
            acc = vec_combine(f, mid, kind, rt, acc, t)
            half /= 2
        }
        s := f.push(mid, VExt, lt, vec_one(acc), 0)
        if lt != pt {
            s = f.push(mid, Trunc, pt, vec_one(s), 0)
        }
        st := f.insts[r.phi].phi_input(rem.chk)
        fin.iset(r.back, loop_red_combine(f, mid, &r, st, s))
    }
    loop_remainder_end(f, cl, &rem, &fin, outside.items(), in_loop, def_block)
    // (-g: the variables that had the replaced scalar values are not shown in the loop)
    if f.dexp.len > 0 {
        forget := vec_fill(f.insts.len, i32(NOV))
        for v in orig {
            if plan.data.has(i64(v)) {
                forget[v] = 0
            }
        }
        dbg_forget(f, &forget)
    }
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

// the add of a sum of bytes: each part of 16 bytes adds its two sums of 8 to the 64-bit lanes
priv fn vec_sad_add(f: *Func, b: *VB, plan: *VPlan, v: i64) {
    i := f.insts[v]
    phi := if plan.sad.has(i.args[0]) && f.insts[i.args[0]].op == Phi { i.args[0] } else { i.args[1] }
    z := if phi == i.args[0] { i.args[1] } else { i.args[0] }
    x := f.insts[z].args[0]
    np := b.w / 16
    for p in 0..np {
        bytes := if f.insts[x].op.is_cmp() { vb_bool01(f, b, x, p, v) } else { b.vm.iget(vk(x, p)) }
        s := vb_op(f, b, VI64, vec_one(bytes), VK_SAD, v)
        b.vm.iset(vk(v, p), vb_op(f, b, VI64, vec_two(b.vm.iget(vk(phi, p)), s), VK_ADD, v))
    }
}

// part p of the vector form of data instruction v
priv fn vec_inst(f: *Func, b: *VB, plan: *VPlan, v: i64, p: i64) {
    src := f.insts[v]
    e := vec_lane_ty(f, v)
    vt := vec_for(e)
    r := NOV
    match src.op {
        Load => {
            addr := src.args[0]
            a := if p == 0 { addr } else { vb_add(f, b, Add, I64, vec_two(addr, vb_const(f, b, I64, 16 * p)), 0, v) }
            r = vb_add(f, b, Load, vt, vec_one(a), 0, v)
            f.im(r).aux = src.aux
        }
        Add, Sub, Mul, And, Or, Xor, FAdd, FSub, FMul, FDiv, FMin, FMax, MulHiU, MulHiS => {
            kind := match src.op {
                Add, FAdd => VK_ADD
                Sub, FSub => VK_SUB
                Mul, FMul => VK_MUL
                And => VK_AND
                Or => VK_OR
                Xor => VK_XOR
                FDiv => VK_FDIV
                FMin => VK_FMIN
                FMax => VK_FMAX
                MulHiU => VK_MULHU
                MulHiS => VK_MULHS
                _ => VK_FMAX
            }
            x := vb_opnd(f, b, src.args[0], p)
            y := vb_opnd(f, b, src.args[1], p)
            r = vb_op(f, b, vt, vec_two(x, y), kind, v)
        }
        FSqrt, FNeg, FAbs => {
            kind := match src.op {
                FSqrt => VK_FSQRT
                FNeg => VK_FNEG
                _ => VK_FABS
            }
            r = vb_op(f, b, vt, vec_one(vb_opnd(f, b, src.args[0], p)), kind, v)
        }
        Shl, LShr, AShr => {
            kind := match src.op {
                Shl => VK_SHL
                LShr => VK_LSHR
                _ => VK_ASHR
            }
            x := vb_opnd(f, b, src.args[0], p)
            bits := e.bits()
            match f.is_const(src.args[1]) {
                Some(c) => r = vb_op(f, b, vt, vec_one(x), kind | (c & (bits - 1)) << 8, v)
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
                    r = vb_op(f, b, vt, vec_two(x, n), kind, v)
                }
            }
        }
        Select => {
            c := src.args[0]
            m := b.vm.iget(vk(c, p))
            x := vb_opnd(f, b, src.args[1], p)
            y := vb_opnd(f, b, src.args[2], p)
            r = if b.negs.iget(vk(c, p)) == 1 {
                vb_op(f, b, vt, vec_of([]i64{m, y, x}), VK_SEL, v)
            } else {
                vb_op(f, b, vt, vec_of([]i64{m, x, y}), VK_SEL, v)
            }
        }
        ZExt, SExt => {
            x := src.args[0]
            so := src.ty.size()
            si := plan.lsz.get_or(x, 0)
            rr := so / si
            q := p / rr
            xs := if f.insts[x].op.is_cmp() { vb_bool01(f, b, x, q, v) } else { b.vm.iget(vk(x, q)) }
            r = vb_ext(f, b, xs, si, so, p % rr, src.op == SExt, v)
        }
        Trunc => {
            x := src.args[0]
            so := src.ty.size()
            si := plan.lsz.get_or(x, 0)
            rr := si / so
            parts := vec[i64]()
            for k in 0..rr {
                parts.push(b.vm.iget(vk(x, p * rr + k)))
            }
            s := si
            while parts.len > 1 {
                s /= 2
                nt := vec_for(vec_int_of(s))
                np := vec[i64]()
                for k in 0..parts.len / 2 {
                    np.push(vb_op(f, b, nt, vec_two(parts[2 * k], parts[2 * k + 1]), VK_TRUNC, v))
                }
                parts = np
            }
            r = parts[0]
        }
        _ => {
            // a compare: a mask, possibly of the negated compare
            x := vb_opnd(f, b, src.args[0], p)
            y := vb_opnd(f, b, src.args[1], p)
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
                vb_op(f, b, vt, vec_two(y, x), kind | imm << 8, v)
            } else {
                vb_op(f, b, vt, vec_two(x, y), kind | imm << 8, v)
            }
            if neg {
                b.negs.iset(vk(v, p), 1)
            }
        }
    }
    b.vm.iset(vk(v, p), r)
}

// Vectorizes every qualifying loop (see above); true if one changed.
fn vec_run(f: *Func) -> bool {
    if !vec_enabled() || f.size() > 20000 {
        return false
    }
    return loop_each_innermost(f, vec_try)
}
