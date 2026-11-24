// Induction variable optimisations on counted loops (src/opt/loop.al), after BCE:
//
// - widening: a narrow counter (`for i in 0..n` with n: i32) whose sign (zero) extension the
//   body uses gets a 64-bit twin that counts along; the extensions become the twin, and the
//   exit test compares the twin, so the narrow counter dies (no `movsxd` per iteration;
//   done only when nothing else uses the narrow counter, two counters would cost more);
// - strength reduction: `ext(iv) * m` with m loop-invariant but not a constant (a strided
//   index `a[i * m + j]`) becomes a phi that adds m every iteration (no `imul` per iteration);
// - address re-basing: the address of a load or store that is affine in the counter with a
//   constant coefficient, `base + (y*n + x - n) * 8`, is rewritten as an invariant part, the
//   scaled counter and a constant, `(base + (y*n - n) * 8) + x * 8 + 0`, which the address
//   modes of the back ends take whole; the invariant part moves before the loop (LICM) and is
//   shared by the accesses that differ only by a constant (`src[i - 1]`, `src[i + 1]`).

// puts the new instruction nv right after instruction v (in v's block)
priv fn lsr_after(f: *Func, def_block: []i32, v: i64, nv: i64) {
    l := &f.blocks[i64(def_block[v])].insts
    pos := index_of(l.items(), i32(v))
    assert pos >= 0, "lsr: instruction not in its block"
    l.insert(pos + 1, i32(nv))
}

// ---------- widening ----------

// the extension (SExt / ZExt) that does not change the counter's values between iterations:
// counting by 1 with a signed (unsigned) bound, or Phi if none
priv fn lsr_ext_op(cl: *CLoop) -> Op {
    if cl.step != 1 && cl.step != -1 {
        return Phi
    }
    return match cl.cmp {
        Slt, Sgt => SExt
        Ult, Ugt => ZExt
        _ => Phi
    }
}

priv fn widen_try(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block: []i32) -> bool {
    cl := match loop_counted(f, cfg, loops, li, in_loop, def_block) {
        Some(c) => c
        None => return false
    }
    if cl.ty == I64 || !cl.ty.is_int() || cl.cur {
        return false
    }
    ext := lsr_ext_op(&cl)
    if ext == Phi {
        return false
    }
    // the extensions of the counter (and of its next value) in the loop
    exts := vec[i64]()
    for b in cl.blocks {
        for v in f.blocks[b].insts {
            i := &f.insts[v]
            if i.op == ext && i.ty == I64 && (i.args[0] == cl.iv || i.args[0] == cl.next) {
                exts.push(i64(v))
            }
        }
    }
    // (entered only with start < end: the counter stays between them and never wraps)
    if exts.is_empty() || !loop_known_at(f, cfg, cl.pre, loop_entry_op(&cl), cl.start, cl.end) {
        return false
    }
    // only when the narrow counter then dies: nothing but its increment, the exit test and
    // the extensions use it (two counters would cost more than the extensions)
    for b in 0..f.blocks.len {
        for v in f.blocks[b].insts {
            i := &f.insts[v]
            for a in i.args {
                if a == cl.iv && i64(v) != cl.next && !contains(&exts, i64(v)) {
                    return false
                }
                if a == cl.next && i64(v) != cl.iv && i64(v) != cl.cond && !contains(&exts, i64(v)) {
                    return false
                }
            }
        }
        for a in term_args(&f.blocks[b].term) {
            if a == cl.iv || a == cl.next {
                return false
            }
        }
    }
    pre := cl.pre
    h := cl.header
    // w = ext(iv): starts at ext(start), moves by step
    ws := f.push(pre, ext, I64, vec_of([]i64{cl.start}), 0)
    w := f.mk_phi(I64, 2)
    wstep := f.push(pre, Const, I64, vec[i64](), cl.step)
    wn := f.mk(Add, I64, vec_of([]i64{w, wstep}), 0)
    f.im(w).phi_set([]i64{ws, wn}, []i64{pre, cl.latch})
    f.blocks[h].insts.insert(0, i32(w))
    lsr_after(f, def_block, cl.next, wn)
    repl := vec_fill(f.insts.len, i32(NOV))
    for x in exts {
        repl[x] = i32(if f.insts[x].args[0] == cl.iv { w } else { wn })
    }
    // the exit test on the wide counter (the narrow one cannot wrap before it ends)
    we := f.push(pre, ext, I64, vec_of([]i64{cl.end}), 0)
    nc := f.mk(cl.cmp, I8, vec_of([]i64{wn, we}), 0)
    f.im(nc).aux = f.insts[cl.cond].aux
    lt2 := &f.blocks[cl.latch].insts
    lt2.push(i32(nc))
    match f.blocks[cl.latch].term {
        Br(&c, _, _) => {
            if cl.back_true {
                *c = nc
            } else {
                // (the condition to go back was the negation)
                f.im(nc).op = cl.cmp.negate_icmp()
                *c = nc
            }
        }
        _ => {}
    }
    dbg_forget(f, &repl)
    f.apply_repl(&repl)
    return true
}

// ---------- strength reduction ----------

// x is the counter or its extension that never wraps (see lsr_ext_op)
priv fn lsr_is_iv(f: *Func, cl: *CLoop, x: i64) -> bool {
    if x == cl.iv {
        return cl.ty == I64
    }
    i := &f.insts[x]
    return (i.op == SExt || i.op == ZExt) && i.ty == I64 && i.args[0] == cl.iv && i.op == lsr_ext_op(cl)
}

priv fn reduce_try(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block: []i32) -> bool {
    cl := match loop_counted(f, cfg, loops, li, in_loop, def_block) {
        Some(c) => c
        None => return false
    }
    if cl.step != 1 && cl.step != -1 {
        return false
    }
    // iv * m with m invariant and not a constant
    found := NOV
    x := NOV
    m := NOV
    for b in cl.blocks {
        if i64(loops.loop_of[b]) != li {
            continue
        }
        for v in f.blocks[b].insts {
            i := &f.insts[v]
            if i.op != Mul || i.ty != I64 {
                continue
            }
            for k in 0..2 {
                a := i.args[k]
                o := i.args[1 - k]
                if lsr_is_iv(f, &cl, a) && loop_invariant(o, in_loop, def_block) && f.insts[o].op != Const {
                    found = i64(v)
                    x = a
                    m = o
                    break
                }
            }
            if found != NOV {
                break
            }
        }
        if found != NOV {
            break
        }
    }
    // (an extended counter: entered only with start < end, so that it never wraps)
    if found == NOV || x != cl.iv && !loop_known_at(f, cfg, cl.pre, loop_entry_op(&cl), cl.start, cl.end) {
        return false
    }
    pre := cl.pre
    // p = ext(iv) * m: starts at ext(start) * m, adds m (subtracts it counting down)
    xs := if x == cl.iv { cl.start } else { f.push(pre, f.insts[x].op, I64, vec_of([]i64{cl.start}), 0) }
    p0 := f.push(pre, Mul, I64, vec_of([]i64{xs, m}), 0)
    p := f.mk_phi(I64, 2)
    pn := f.mk(if cl.step > 0 { Add } else { Sub }, I64, vec_of([]i64{p, m}), 0)
    f.im(p).phi_set([]i64{p0, pn}, []i64{pre, cl.latch})
    f.blocks[cl.header].insts.insert(0, i32(p))
    lsr_after(f, def_block, cl.next, pn)
    repl := vec_fill(f.insts.len, i32(NOV))
    repl[found] = i32(p)
    dbg_forget(f, &repl)
    f.apply_repl(&repl)
    return true
}

// ---------- address re-basing ----------

// the instructions of the loop in v's expression (the counter not counted, nor the addition of
// a constant, which an address mode takes), at most about `cap`
priv fn lsr_nodes(f: *Func, cl: *CLoop, v: i64, in_loop: []bool, def_block: []i32, cap: i64) -> i64 {
    if v == cl.iv || loop_invariant(v, in_loop, def_block) || cap <= 0 {
        return 0
    }
    i := &f.insts[v]
    n := 1
    if i.op == Add && (f.insts[i.args[0]].op == Const || f.insts[i.args[1]].op == Const) {
        n = 0
    }
    for a in f.insts[v].args {
        n += lsr_nodes(f, cl, a, in_loop, def_block, cap - n)
    }
    return n
}

// Appends to block b the value of the affine expression v (loop_affine_coef) where the counter
// is 0, without its constant part: (the value or NOV for none, the constant part)
priv fn lsr_at0(f: *Func, cl: *CLoop, b: i64, v: i64, in_loop: []bool, def_block: []i32) -> (i64, i64) {
    i := f.insts[v]
    if loop_invariant(v, in_loop, def_block) {
        if i.op == Const {
            return (NOV, i.k)
        }
        return (v, 0)
    }
    if v == cl.iv || i.op == SExt || i.op == ZExt {
        // (the counter, or its extension: 0 where the counter is 0)
        return (NOV, 0)
    }
    match i.op {
        Add, Sub => {
            x, kx := lsr_at0(f, cl, b, i.args[0], in_loop, def_block)
            y, ky := lsr_at0(f, cl, b, i.args[1], in_loop, def_block)
            k := if i.op == Add { kx + ky } else { kx - ky }
            if y == NOV {
                return (x, k)
            }
            if x == NOV {
                if i.op == Add {
                    return (y, k)
                }
                z := f.push(b, Const, I64, vec[i64](), 0)
                return (f.push(b, Sub, I64, vec_of([]i64{z, y}), 0), k)
            }
            return (f.push(b, i.op, I64, vec_of([]i64{x, y}), 0), k)
        }
        Mul, Shl => {
            // (one operand is a constant: see loop_affine_coef)
            ci := if f.insts[i.args[1]].op == Const { 1 } else { 0 }
            c := f.insts[i.args[ci]].k
            x, kx := lsr_at0(f, cl, b, i.args[1 - ci], in_loop, def_block)
            k := if i.op == Mul { kx * c } else { kx << c }
            if x == NOV {
                return (NOV, k)
            }
            return (f.push(b, i.op, I64, vec_of([]i64{x, i.args[ci]}), 0), k)
        }
        _ => {
            assert false, "lsr: not affine"
            return (NOV, 0)
        }
    }
}

priv fn rebase_try(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block: []i32) -> bool {
    cl := match loop_counted(f, cfg, loops, li, in_loop, def_block) {
        Some(c) => c
        None => return false
    }
    ext := Phi
    if cl.ty != I64 {
        ext = lsr_ext_op(&cl)
        if ext == Phi {
            return false
        }
    }
    // the memory accesses whose address is affine in the counter and costs more than the
    // re-based form: Add(base, scaled counter) (+ a constant, folded into the address)
    todo := vec[(i64, i64)]()
    for b in cl.blocks {
        for v in f.blocks[b].insts {
            i := &f.insts[v]
            if i.op != Load && i.op != Store {
                continue
            }
            a := i.args[0]
            if loop_invariant(a, in_loop, def_block) {
                continue
            }
            c := match loop_affine_coef(f, &cl, a, in_loop, def_block) {
                Some(k) => k
                None => continue
            }
            if c == 0 {
                continue
            }
            scaled_cost := (if c == 1 { 0 } else { 1 }) + (if cl.ty == I64 { 0 } else { 1 })
            if lsr_nodes(f, &cl, a, in_loop, def_block, 8) <= 1 + scaled_cost {
                continue
            }
            todo.push((i64(v), c))
        }
    }
    if todo.is_empty() {
        return false
    }
    pre := cl.pre
    h := cl.header
    // the scaled counters, after the header's phis (one per coefficient)
    nphi := 0
    while nphi < f.blocks[h].insts.len && f.insts[f.blocks[h].insts[nphi]].op == Phi {
        nphi += 1
    }
    scaled := map[i64, i64]()
    x := cl.iv
    newh := vec[i32]()
    if cl.ty != I64 {
        x = f.mk(ext, I64, vec_of([]i64{cl.iv}), 0)
        newh.push(i32(x))
    }
    for t in todo {
        v, c := t
        a := f.insts[v].args[0]
        s, found := scaled.get(c)
        if !found {
            s = x
            if c != 1 {
                sh := 0
                while sh < 62 && i64(1) << sh < c {
                    sh += 1
                }
                if c > 0 && i64(1) << sh == c {
                    s = f.mk(Shl, I64, vec_of([]i64{x, f.push(pre, Const, I64, vec[i64](), sh)}), 0)
                } else {
                    s = f.mk(Mul, I64, vec_of([]i64{x, f.push(pre, Const, I64, vec[i64](), c)}), 0)
                }
                newh.push(i32(s))
            }
            scaled.set(c, s)
        }
        base, k := lsr_at0(f, &cl, pre, a, in_loop, def_block)
        // the new address next to the access: base + s + k
        na := if base == NOV { s } else { f.mk(Add, I64, vec_of([]i64{base, s}), 0) }
        extra := vec[i32]()
        if na != s {
            extra.push(i32(na))
        }
        if k != 0 {
            kc := f.push(pre, Const, I64, vec[i64](), k)
            na = f.mk(Add, I64, vec_of([]i64{na, kc}), 0)
            extra.push(i32(na))
        }
        b := i64(def_block[v])
        bl := &f.blocks[b].insts
        pos := index_of(bl.items(), i32(v))
        for e in 0..extra.len {
            bl.insert(pos + e, extra[e])
        }
        f.insts[v].args[0] = na
    }
    hl := &f.blocks[h].insts
    for e in 0..newh.len {
        hl.insert(nphi + e, newh[e])
    }
    return true
}

// Address re-basing is off: measured with the other loop passes on (2026-11-23, interleaved
// best of 7), it gained 4% on mem/rows but lost 2-12% on fp/lu, vec/colsum, vec/blur and
// mem/dp (the extra base registers; the isel change that keeps invariant address sums out of
// loops already took most of its gain). Kept for a later pass that weighs register pressure.
priv const LSR_REBASE = false

// Widening and strength reduction (and address re-basing if LSR_REBASE) in every innermost
// counted loop; true if anything changed.
fn lsr_run(f: *Func) -> bool {
    ch := false
    if opt_enabled("widen") && loop_each_innermost(f, widen_try) {
        ch = true
    }
    if opt_enabled("sr") && loop_each_innermost(f, reduce_try) {
        ch = true
    }
    if LSR_REBASE && opt_enabled("rebase") && loop_each_innermost(f, rebase_try) {
        ch = true
    }
    return ch
}
