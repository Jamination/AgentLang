// Bounds-check hoisting.
//
// A check `idx <u len` that runs on every iteration of a counted loop is replaced by checks in
// the loop preheader. This is only done for loops that cannot be left in any other way than
// through their counting test or a failing check, and that contain no calls: for such loops a
// check that fails at some iteration would end the program anyway, so failing early is not
// observable (apart from which of several failing accesses is reported).

struct BceIv {
    phi i64,
    start i64,
    step i64,
    end i64,
    cmp Op,
    ty T,
    // last value of the induction variable when it is known at compile time
    last_const Opt[i64],
}

// index expression: ext(inner(iv)) where inner is iv +/- invariants
struct BceAffine {
    ext Opt[Op],
    // root of the inner expression (the value below the extension)
    inner i64,
    // index = coef * iv + invariant
    coef i64,
}

enum BceKind {
    BceKindInvariant,
    BceKindAffine(BceAffine),
}

fn bce_is_trap_block(f *Func, b i64) bool {
    if !eq(f.blocks.buf[b].term, TermTrap) {
        return false
    }
    for v in f.blocks.buf[b].insts.items() {
        if f.insts.buf[v].op == OpPhi {
            return false
        }
    }
    return true
}

// the closure `invariant` of find_iv, match_affine and hoist_in_loop
fn bce_invariant(v i64, in_loop []bool, def_block []i64) bool {
    return def_block[v] == 0xFFFFFFFF || !in_loop[def_block[v]]
}

fn bce_signum(x i64) i64 {
    if x > 0 {
        return 1
    }
    if x < 0 {
        return -1
    }
    return 0
}

fn bce_find_iv(f *Func, header i64, latch i64, pre i64, in_loop []bool, def_block []i64) Opt[BceIv] {
    c := 0
    t := 0
    e := 0
    match f.blocks.buf[latch].term {
        TermBr(c0, t0, e0) => {
            c = c0
            t = t0
            e = e0
        }
        _ => return None
    }
    if t != header || in_loop[e] {
        return None
    }
    ci := &f.insts.buf[c]
    if !ci.op.is_icmp() {
        return None
    }
    next := ci.args.buf[0]
    end := ci.args.buf[1]
    if !bce_invariant(end, in_loop, def_block) {
        return None
    }
    ni := &f.insts.buf[next]
    if ni.op != OpAdd {
        return None
    }
    step := 0
    match f.is_const(ni.args.buf[1]) {
        Some(k) => step = k
        None => return None
    }
    phi := ni.args.buf[0]
    pi := &f.insts.buf[phi]
    if pi.op != OpPhi || def_block[phi] != header || pi.args.len != 2 {
        return None
    }
    start := NOV
    back := NOV
    for k in 0..pi.pb.len {
        pb := pi.pb.buf[k]
        if pb == pre {
            start = pi.args.buf[k]
        } else if pb == latch {
            back = pi.args.buf[k]
        }
    }
    if start == NOV || back != next {
        return None
    }
    ty := pi.ty
    if step != 1 && step != -1 {
        // other strides: only with constant bounds, where the last value can be computed
        s0 := 0
        match f.is_const(start) {
            Some(k) => s0 = k
            None => return None
        }
        e0 := 0
        match f.is_const(end) {
            Some(k) => e0 = k
            None => return None
        }
        if step == 0 {
            return None
        }
        i := s0
        n := 0
        loop {
            n += 1
            if n > 1 << 20 {
                return None
            }
            nx := ir_canon(ty, i + step)
            // the counter must move monotonically (no wrap) while the loop continues
            if (step > 0) != (nx > i) {
                return None
            }
            match simplify_fold_icmp(ci.op, ty, nx, e0) {
                Some(r) => {
                    if !r {
                        break
                    }
                }
                None => return None
            }
            i = nx
        }
        return Some(BceIv{phi: phi, start: start, step: step, end: end, cmp: ci.op, ty: ty, last_const: Some(i)})
    }
    ok := false
    o := ci.op
    if (step == 1 && (o == OpSlt || o == OpUlt)) || (step == -1 && (o == OpSgt || o == OpUgt)) {
        ok = true
    } else if (step == 1 && (o == OpSle || o == OpUle)) || (step == -1 && (o == OpSge || o == OpUge)) {
        // inclusive bounds must not sit at the edge of the type (the counter would wrap)
        match f.is_const(end) {
            Some(k) => {
                bits := ty.bits()
                smin := -9223372036854775807 - 1
                smax := 9223372036854775807
                if bits != 64 {
                    smin = -(1 << (bits - 1))
                    smax = (1 << (bits - 1)) - 1
                }
                if o == OpSle {
                    ok = k != smax
                } else if o == OpSge {
                    ok = k != smin
                } else if o == OpUle {
                    ok = k != -1
                } else {
                    ok = k != 0
                }
            }
            None => ok = false
        }
    }
    if !ok {
        return None
    }
    return Some(BceIv{phi: phi, start: start, step: step, end: end, cmp: ci.op, ty: ty, last_const: None})
}

// match idx as ext(inner) with inner = iv, inner + inv, inner - inv or inv - inner
fn bce_match_affine(f *Func, idx i64, iv *BceIv, in_loop []bool, def_block []i64) Opt[BceAffine] {
    var ext Opt[Op] = None
    inner := idx
    {
        i := &f.insts.buf[idx]
        if (i.op == OpSExt || i.op == OpZExt) && !bce_invariant(idx, in_loop, def_block) {
            ext = Some(i.op)
            inner = i.args.buf[0]
        }
    }
    // walk down the inner chain
    coef := 1
    v := inner
    depth := 0
    loop {
        if v == iv.phi {
            break
        }
        depth += 1
        if depth > 8 {
            return None
        }
        i := &f.insts.buf[v]
        if i.ty != iv.ty {
            return None
        }
        if i.op == OpAdd {
            a := i.args.buf[0]
            b := i.args.buf[1]
            if bce_invariant(b, in_loop, def_block) && !bce_invariant(a, in_loop, def_block) {
                v = a
            } else if bce_invariant(a, in_loop, def_block) && !bce_invariant(b, in_loop, def_block) {
                v = b
            } else {
                return None
            }
        } else if i.op == OpSub {
            a := i.args.buf[0]
            b := i.args.buf[1]
            if bce_invariant(b, in_loop, def_block) && !bce_invariant(a, in_loop, def_block) {
                v = a
            } else if bce_invariant(a, in_loop, def_block) && !bce_invariant(b, in_loop, def_block) {
                coef = -coef
                v = b
            } else {
                return None
            }
        } else if (i.op == OpMul || i.op == OpShl) && !is_some(ext) && iv.ty == TI64 {
            k := 0
            match f.is_const(i.args.buf[1]) {
                Some(x) => k = x
                None => return None
            }
            m := k
            if i.op == OpShl {
                if !(k >= 0 && k < 31) {
                    return None
                }
                m = 1 << k
            }
            if m <= 0 || m > (1 << 31) || abs(coef) > (1 << 31) {
                return None
            }
            coef *= m
            v = i.args.buf[0]
        } else {
            return None
        }
    }
    if f.insts.buf[inner].ty != iv.ty {
        return None
    }
    return Some(BceAffine{ext: ext, inner: inner, coef: coef})
}

// rebuild the index expression in block `pre` with the induction variable replaced by `at`
fn bce_clone_at(f *Func, pre i64, v i64, iv_phi i64, at i64, in_loop []bool, def_block []i64) i64 {
    if v == iv_phi {
        return at
    }
    db := 0xFFFFFFFF
    if v < len(def_block) {
        db = def_block[v]
    }
    if db == 0xFFFFFFFF || !in_loop[db] {
        return v
    }
    i := clone(&f.insts.buf[v])
    args := vec[i64]()
    for a in i.args.items() {
        args.push(bce_clone_at(f, pre, a, iv_phi, at, in_loop, def_block))
    }
    return f.push(pre, i.op, i.ty, args, i.k)
}

// the closure `add_check` of hoist_in_loop (h: the loop header)
fn bce_hoist_in_loop_add_check(f *Func, cur *i64, cond i64, trap i64, h i64) {
    nb := f.new_block()
    f.blocks.buf[nb].term = TermJmp(h)
    f.blocks.buf[*cur].term = TermBr(cond, nb, trap)
    *cur = nb
}

// the closure `build` of hoist_in_loop
// computations go into `pre` (it dominates the whole chain)
fn bce_hoist_in_loop_build(f *Func, at i64, pre i64, a *BceAffine, iv *BceIv, in_loop []bool, def_block []i64) i64 {
    inner := bce_clone_at(f, pre, a.inner, iv.phi, at, in_loop, def_block)
    match a.ext {
        Some(op) => return f.push(pre, op, TI64, vec_of([]i64{inner}), 0)
        None => {}
    }
    return inner
}

fn bce_hoist_in_loop(f *Func, cfg *Cfg, loops *Loops, li i64) bool {
    l := &loops.loops.buf[li]
    h := l.header
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 || f.succs(outside.buf[0]).len != 1 || l.latches.len != 1 {
        return false
    }
    pre := outside.buf[0]
    latch := l.latches.buf[0]
    in_loop_v := vec_fill(f.blocks.len, false)
    for b in l.blocks.items() {
        in_loop_v.buf[b] = true
    }
    in_loop := in_loop_v.items()
    // the loop may only be left through its latch or through failing checks, and has no calls
    for b in l.blocks.items() {
        for v in f.blocks.buf[b].insts.items() {
            o := f.insts.buf[v].op
            if o == OpCall || o == OpCallInd || o == OpSyscall {
                return false
            }
        }
        match f.blocks.buf[b].term {
            TermRet(vs) => return false
            TermTrap => return false
            TermNone => return false
            _ => {}
        }
        ss := f.succs(b)
        for s in ss.items() {
            if !in_loop[s] && b != latch && !bce_is_trap_block(f, s) {
                return false
            }
        }
    }
    def_block_v := f.block_of()
    def_block := def_block_v.items()
    iv_opt := bce_find_iv(f, h, latch, pre, in_loop, def_block)
    has_iv := false
    var iv BceIv
    match iv_opt {
        Some(x) => {
            has_iv = true
            iv = x
        }
        None => {}
    }
    // collect candidate checks
    cands := vec[(i64, i64, i64, i64, i64, i64, BceKind)]() // block, cond, ok, trap, idx, len
    for b in l.blocks.items() {
        c := 0
        t := 0
        e := 0
        match f.blocks.buf[b].term {
            TermBr(c0, t0, e0) => {
                c = c0
                t = t0
                e = e0
            }
            _ => continue
        }
        if !in_loop[t] || in_loop[e] || !bce_is_trap_block(f, e) || b == latch {
            continue
        }
        if !cfg.dom(b, latch) {
            continue
        }
        ci := &f.insts.buf[c]
        idx := 0
        ln := 0
        if ci.op == OpUlt {
            idx = ci.args.buf[0]
            ln = ci.args.buf[1]
        } else if ci.op == OpUgt {
            idx = ci.args.buf[1]
            ln = ci.args.buf[0]
        } else {
            continue
        }
        if f.insts.buf[idx].ty != TI64 || !bce_invariant(ln, in_loop, def_block) {
            continue
        }
        if bce_invariant(idx, in_loop, def_block) {
            if bce_invariant(c, in_loop, def_block) {
                cands.push((b, c, t, e, idx, ln, BceKindInvariant))
            }
            continue
        }
        if has_iv {
            match bce_match_affine(f, idx, &iv, in_loop, def_block) {
                Some(a) => cands.push((b, c, t, e, idx, ln, BceKindAffine(a)))
                None => {}
            }
        }
    }
    if cands.is_empty() {
        return false
    }
    // the last value taken by the induction variable (guarded against zero-trip shapes)
    last_eff := NOV
    if has_iv {
        match iv.last_const {
            Some(k) => last_eff = f.push(pre, OpConst, iv.ty, vec[i64](), k)
            None => {
                any_affine := false
                for ci in 0..cands.len {
                    match cands.buf[ci].6 {
                        BceKindAffine(a) => any_affine = true
                        BceKindInvariant => {}
                    }
                    if any_affine {
                        break
                    }
                }
                if any_affine {
                    enters := f.push(pre, iv.cmp, TI8, vec_of([]i64{iv.start, iv.end}), 0)
                    last_v := iv.end
                    if iv.cmp == OpSlt || iv.cmp == OpUlt {
                        one := f.push(pre, OpConst, iv.ty, vec[i64](), 1)
                        last_v = f.push(pre, OpSub, iv.ty, vec_of([]i64{iv.end, one}), 0)
                    } else if iv.cmp == OpSgt || iv.cmp == OpUgt {
                        one := f.push(pre, OpConst, iv.ty, vec[i64](), 1)
                        last_v = f.push(pre, OpAdd, iv.ty, vec_of([]i64{iv.end, one}), 0)
                    }
                    last_eff = f.push(pre, OpSelect, iv.ty, vec_of([]i64{enters, last_v, iv.start}), 0)
                }
            }
        }
    }
    // build the chain of hoisted checks: pre -> n1 -> ... -> header
    cur := pre
    for ci in 0..cands.len {
        cand := cands.buf[ci]
        b := cand.0
        c := cand.1
        ok := cand.2
        trap := cand.3
        ln := cand.5
        match cand.6 {
            BceKindInvariant => {
                bce_hoist_in_loop_add_check(f, &cur, c, trap, h)
            }
            BceKindAffine(a) => {
                assert has_iv
                e_first := bce_hoist_in_loop_build(f, iv.start, pre, &a, &iv, in_loop, def_block)
                e_last := bce_hoist_in_loop_build(f, last_eff, pre, &a, &iv, in_loop, def_block)
                c1 := f.push(pre, OpUlt, TI8, vec_of([]i64{e_first, ln}), 0)
                c2 := f.push(pre, OpUlt, TI8, vec_of([]i64{e_last, ln}), 0)
                dir := bce_signum(a.coef) * bce_signum(iv.step)
                c3 := 0
                if dir > 0 {
                    c3 = f.push(pre, OpUle, TI8, vec_of([]i64{e_first, e_last}), 0)
                } else {
                    c3 = f.push(pre, OpUle, TI8, vec_of([]i64{e_last, e_first}), 0)
                }
                bce_hoist_in_loop_add_check(f, &cur, c1, trap, h)
                bce_hoist_in_loop_add_check(f, &cur, c2, trap, h)
                bce_hoist_in_loop_add_check(f, &cur, c3, trap, h)
                if abs(a.coef) > 1 {
                    // the trip count must be small enough that coef * iv cannot wrap; when it is
                    // not, some access is out of bounds anyway
                    d := 0
                    if iv.step > 0 {
                        d = f.push(pre, OpSub, TI64, vec_of([]i64{last_eff, iv.start}), 0)
                    } else {
                        d = f.push(pre, OpSub, TI64, vec_of([]i64{iv.start, last_eff}), 0)
                    }
                    lim := f.push(pre, OpConst, TI64, vec[i64](), 9223372036854775807 / abs(a.coef))
                    c4 := f.push(pre, OpUle, TI8, vec_of([]i64{d, lim}), 0)
                    bce_hoist_in_loop_add_check(f, &cur, c4, trap, h)
                }
            }
        }
        f.blocks.buf[b].term = TermJmp(ok)
    }
    // header phis now come from the end of the chain
    if cur != pre {
        for ii in 0..f.blocks.buf[h].insts.len {
            v := f.blocks.buf[h].insts.buf[ii]
            if f.insts.buf[v].op != OpPhi {
                break
            }
            pbs := &f.insts.buf[v].pb
            for k in 0..pbs.len {
                if pbs.buf[k] == pre {
                    pbs.buf[k] = cur
                }
            }
        }
    }
    return true
}

fn bce_run(f *Func) bool {
    changed := false
    for it in 0..200 {
        licm_make_preheaders(f)
        cfg := cfg_new(f)
        loops := loops_new(f, &cfg)
        order := licm_loop_order(&loops)
        did := false
        for li in order.items() {
            if bce_hoist_in_loop(f, &cfg, &loops, li) {
                did = true
                break
            }
        }
        if !did {
            break
        }
        changed = true
        cleanup_prune_unreachable(f)
    }
    return changed
}
