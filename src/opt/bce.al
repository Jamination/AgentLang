// Bounds-check hoisting.
//
// A check `idx <u len` that runs on every iteration of a counted loop is replaced by checks in
// the loop preheader. This is only done for loops that cannot be left in any other way than
// through their counting test or a failing check, and that contain no calls: for such loops a
// check that fails at some iteration would end the program anyway, so failing early is not
// observable (apart from which of several failing accesses is reported).

priv struct Iv {
    phi: i64,
    start: i64,
    step: i64,
    end: i64,
    cmp: Op,
    ty: T,
    // last value of the induction variable when it is known at compile time
    last_const: Opt[i64],
}

// index expression: ext(inner(iv)) where inner is iv +/- invariants
priv struct BceAffine {
    ext: Opt[Op],
    // root of the inner expression (the value below the extension)
    inner: i64,
    // index = coef * iv + invariant
    coef: i64,
}

priv enum Kind {
    Invariant,
    Affine(BceAffine),
}

priv fn is_trap_block(f: *Func, b: i64) -> bool {
    if !eq(f.blocks[b].term, Trap) {
        return false
    }
    for v in f.blocks[b].insts.items() {
        if f.insts[v].op == Phi {
            return false
        }
    }
    return true
}

// the closure `invariant` of find_iv, match_affine and hoist_in_loop
priv fn invariant(v: i64, in_loop: []bool, def_block: []i64) -> bool {
    return def_block[v] == 0xFFFFFFFF || !in_loop[def_block[v]]
}

priv fn signum(x: i64) -> i64 {
    if x > 0 {
        return 1
    }
    if x < 0 {
        return -1
    }
    return 0
}

priv fn find_iv(f: *Func, header: i64, latch: i64, pre: i64, in_loop: []bool, def_block: []i64) -> Opt[Iv] {
    c, t, e := match f.blocks[latch].term {
        Br(c0, t0, e0) => (c0, t0, e0)
        _ => return None
    }
    if t != header || in_loop[e] {
        return None
    }
    ci := &f.insts[c]
    if !ci.op.is_icmp() {
        return None
    }
    next := ci.args[0]
    end := ci.args[1]
    if !invariant(end, in_loop, def_block) {
        return None
    }
    ni := &f.insts[next]
    if ni.op != Add {
        return None
    }
    step := match f.is_const(ni.args[1]) {
        Some(k) => k
        None => return None
    }
    phi := ni.args[0]
    pi := &f.insts[phi]
    if pi.op != Phi || def_block[phi] != header || pi.args.len != 2 {
        return None
    }
    start := NOV
    back := NOV
    for k in 0..pi.pb.len {
        pb := pi.pb[k]
        if pb == pre {
            start = pi.args[k]
        } else if pb == latch {
            back = pi.args[k]
        }
    }
    if start == NOV || back != next {
        return None
    }
    ty := pi.ty
    if step != 1 && step != -1 {
        // other strides: only with constant bounds, where the last value can be computed
        s0 := match f.is_const(start) {
            Some(k) => k
            None => return None
        }
        e0 := match f.is_const(end) {
            Some(k) => k
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
                Some(true) => {}
                Some(false) => break
                None => return None
            }
            i = nx
        }
        return Some(Iv{phi: phi, start: start, step: step, end: end, cmp: ci.op, ty: ty, last_const: Some(i)})
    }
    ok := false
    o := ci.op
    if (step == 1 && (o == Slt || o == Ult)) || (step == -1 && (o == Sgt || o == Ugt)) {
        ok = true
    } else if (step == 1 && (o == Sle || o == Ule)) || (step == -1 && (o == Sge || o == Uge)) {
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
                if o == Sle {
                    ok = k != smax
                } else if o == Sge {
                    ok = k != smin
                } else if o == Ule {
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
    return Some(Iv{phi: phi, start: start, step: step, end: end, cmp: ci.op, ty: ty, last_const: None})
}

// match idx as ext(inner) with inner = iv, inner + inv, inner - inv or inv - inner
priv fn match_affine(f: *Func, idx: i64, iv: *Iv, in_loop: []bool, def_block: []i64) -> Opt[BceAffine] {
    ext: Opt[Op] = None
    inner := idx
    {
        i := &f.insts[idx]
        if (i.op == SExt || i.op == ZExt) && !invariant(idx, in_loop, def_block) {
            ext = Some(i.op)
            inner = i.args[0]
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
        i := &f.insts[v]
        if i.ty != iv.ty {
            return None
        }
        if i.op == Add {
            a := i.args[0]
            b := i.args[1]
            if invariant(b, in_loop, def_block) && !invariant(a, in_loop, def_block) {
                v = a
            } else if invariant(a, in_loop, def_block) && !invariant(b, in_loop, def_block) {
                v = b
            } else {
                return None
            }
        } else if i.op == Sub {
            a := i.args[0]
            b := i.args[1]
            if invariant(b, in_loop, def_block) && !invariant(a, in_loop, def_block) {
                v = a
            } else if invariant(a, in_loop, def_block) && !invariant(b, in_loop, def_block) {
                coef = -coef
                v = b
            } else {
                return None
            }
        } else if (i.op == Mul || i.op == Shl) && !is_some(ext) && iv.ty == I64 {
            k := match f.is_const(i.args[1]) {
                Some(x) => x
                None => return None
            }
            m := k
            if i.op == Shl {
                if !(k >= 0 && k < 31) {
                    return None
                }
                m = 1 << k
            }
            if m <= 0 || m > (1 << 31) || abs(coef) > (1 << 31) {
                return None
            }
            coef *= m
            v = i.args[0]
        } else {
            return None
        }
    }
    if f.insts[inner].ty != iv.ty {
        return None
    }
    return Some(BceAffine{ext: ext, inner: inner, coef: coef})
}

// rebuild the index expression in block `pre` with the induction variable replaced by `at`
priv fn clone_at(f: *Func, pre: i64, v: i64, iv_phi: i64, at: i64, in_loop: []bool, def_block: []i64) -> i64 {
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
    i := clone(&f.insts[v])
    args := vec[i64]()
    for a in i.args.items() {
        args.push(clone_at(f, pre, a, iv_phi, at, in_loop, def_block))
    }
    return f.push(pre, i.op, i.ty, args, i.k)
}

priv fn hoist_in_loop(f: *Func, cfg: *Cfg, loops: *Loops, li: i64) -> bool {
    l := &loops.loops[li]
    h := l.header
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 || f.succs(outside[0]).len != 1 || l.latches.len != 1 {
        return false
    }
    pre := outside[0]
    latch := l.latches[0]
    in_loop_v := vec_fill(f.blocks.len, false)
    for b in l.blocks.items() {
        in_loop_v[b] = true
    }
    in_loop := in_loop_v.items()
    // the loop may only be left through its latch or through failing checks, and has no calls
    for b in l.blocks.items() {
        for v in f.blocks[b].insts.items() {
            o := f.insts[v].op
            if o == Call || o == CallInd || o == Syscall {
                return false
            }
        }
        match f.blocks[b].term {
            Ret(_), Trap, Term.None => return false
            _ => {}
        }
        ss := f.succs(b)
        for s in ss.items() {
            if !in_loop[s] && b != latch && !is_trap_block(f, s) {
                return false
            }
        }
    }
    def_block_v := f.block_of()
    def_block := def_block_v.items()
    iv_opt := find_iv(f, h, latch, pre, in_loop, def_block)
    has_iv := false
    iv: Iv
    match iv_opt {
        Some(x) => {
            has_iv = true
            iv = x
        }
        None => {}
    }
    // collect candidate checks
    cands := vec[(i64, i64, i64, i64, i64, i64, Kind)]() // block, cond, ok, trap, idx, len
    for b in l.blocks.items() {
        c, t, e := match f.blocks[b].term {
            Br(c0, t0, e0) => (c0, t0, e0)
            _ => continue
        }
        if !in_loop[t] || in_loop[e] || !is_trap_block(f, e) || b == latch {
            continue
        }
        if !cfg.dom(b, latch) {
            continue
        }
        ci := &f.insts[c]
        idx := 0
        ln := 0
        if ci.op == Ult {
            idx = ci.args[0]
            ln = ci.args[1]
        } else if ci.op == Ugt {
            idx = ci.args[1]
            ln = ci.args[0]
        } else {
            continue
        }
        if f.insts[idx].ty != I64 || !invariant(ln, in_loop, def_block) {
            continue
        }
        if invariant(idx, in_loop, def_block) {
            if invariant(c, in_loop, def_block) {
                cands.push((b, c, t, e, idx, ln, Invariant))
            }
            continue
        }
        if has_iv {
            match match_affine(f, idx, &iv, in_loop, def_block) {
                Some(a) => cands.push((b, c, t, e, idx, ln, Affine(a)))
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
            Some(k) => last_eff = f.push(pre, Const, iv.ty, vec[i64](), k)
            None => {
                any_affine := false
                for ci in 0..cands.len {
                    match cands[ci].6 {
                        Affine(a) => any_affine = true
                        Invariant => {}
                    }
                    if any_affine {
                        break
                    }
                }
                if any_affine {
                    enters := f.push(pre, iv.cmp, I8, vec_of([]i64{iv.start, iv.end}), 0)
                    last_v := iv.end
                    if iv.cmp == Slt || iv.cmp == Ult {
                        one := f.push(pre, Const, iv.ty, vec[i64](), 1)
                        last_v = f.push(pre, Sub, iv.ty, vec_of([]i64{iv.end, one}), 0)
                    } else if iv.cmp == Sgt || iv.cmp == Ugt {
                        one := f.push(pre, Const, iv.ty, vec[i64](), 1)
                        last_v = f.push(pre, Add, iv.ty, vec_of([]i64{iv.end, one}), 0)
                    }
                    last_eff = f.push(pre, Select, iv.ty, vec_of([]i64{enters, last_v, iv.start}), 0)
                }
            }
        }
    }
    // build the chain of hoisted checks: pre -> n1 -> ... -> header
    cur := pre
    // one more check at the end of the chain `*cur`, which ends at the loop header `h`
    fn add_check(f: *Func, cur: *i64, cond: i64, trap: i64, h: i64) {
        nb := f.new_block()
        f.blocks[nb].term = Jmp(h)
        f.blocks[*cur].term = Br(cond, nb, trap)
        *cur = nb
    }
    // the index expression `a` for the value `at` of the induction variable; the
    // computations go into `pre` (it dominates the whole chain)
    fn index_at(f: *Func, at: i64, pre: i64, a: *BceAffine, iv: *Iv, in_loop: []bool, def_block: []i64) -> i64 {
        inner := clone_at(f, pre, a.inner, iv.phi, at, in_loop, def_block)
        match a.ext {
            Some(op) => f.push(pre, op, I64, vec_of([]i64{inner}), 0)
            None => inner
        }
    }
    for ci in 0..cands.len {
        cand := cands[ci]
        b := cand.0
        c := cand.1
        ok := cand.2
        trap := cand.3
        ln := cand.5
        match cand.6 {
            Invariant => {
                add_check(f, &cur, c, trap, h)
            }
            Affine(a) => {
                assert has_iv
                e_first := index_at(f, iv.start, pre, &a, &iv, in_loop, def_block)
                e_last := index_at(f, last_eff, pre, &a, &iv, in_loop, def_block)
                c1 := f.push(pre, Ult, I8, vec_of([]i64{e_first, ln}), 0)
                c2 := f.push(pre, Ult, I8, vec_of([]i64{e_last, ln}), 0)
                dir := signum(a.coef) * signum(iv.step)
                c3 := 0
                if dir > 0 {
                    c3 = f.push(pre, Ule, I8, vec_of([]i64{e_first, e_last}), 0)
                } else {
                    c3 = f.push(pre, Ule, I8, vec_of([]i64{e_last, e_first}), 0)
                }
                add_check(f, &cur, c1, trap, h)
                add_check(f, &cur, c2, trap, h)
                add_check(f, &cur, c3, trap, h)
                if abs(a.coef) > 1 {
                    // the trip count must be small enough that coef * iv cannot wrap; when it is
                    // not, some access is out of bounds anyway
                    d := 0
                    if iv.step > 0 {
                        d = f.push(pre, Sub, I64, vec_of([]i64{last_eff, iv.start}), 0)
                    } else {
                        d = f.push(pre, Sub, I64, vec_of([]i64{iv.start, last_eff}), 0)
                    }
                    lim := f.push(pre, Const, I64, vec[i64](), 9223372036854775807 / abs(a.coef))
                    c4 := f.push(pre, Ule, I8, vec_of([]i64{d, lim}), 0)
                    add_check(f, &cur, c4, trap, h)
                }
            }
        }
        f.blocks[b].term = Jmp(ok)
    }
    // header phis now come from the end of the chain
    if cur != pre {
        for ii in 0..f.blocks[h].insts.len {
            v := f.blocks[h].insts[ii]
            if f.insts[v].op != Phi {
                break
            }
            pbs := &f.insts[v].pb
            for k in 0..pbs.len {
                if pbs[k] == pre {
                    pbs[k] = cur
                }
            }
        }
    }
    return true
}

// ---------- elimination ----------
// `a` and `b` are the same value: one instruction, or two equal constants
priv fn same(f: *Func, a: i64, b: i64) -> bool {
    if a == b {
        return true
    }
    match (f.is_const(a), f.is_const(b)) {
        (Some(x), Some(y)) => x == y && f.insts[a].ty == f.insts[b].ty
        _ => false
    }
}

// Is `start < end` (in the sense of the loop's own test `iv.cmp`) known whenever the loop is
// entered? Either both are constants, or a block that is the only way to the preheader
// branches on that comparison.
priv fn entry_guard(f: *Func, cfg: *Cfg, pre: i64, iv: *Iv) -> bool {
    match (f.is_const(iv.start), f.is_const(iv.end)) {
        (Some(s), Some(e)) => {
            match simplify_fold_icmp(iv.cmp, iv.ty, s, e) {
                Some(r) => return r
                None => return false
            }
        }
        _ => {}
    }
    signed := iv.cmp == Slt
    lt := if signed { Slt } else { Ult }
    gt := if signed { Sgt } else { Ugt }
    ge := if signed { Sge } else { Uge }
    le := if signed { Sle } else { Ule }
    b := pre
    for depth in 0..16 {
        if cfg.preds[b].len != 1 {
            return false
        }
        p := cfg.preds[b][0]
        match f.blocks[p].term {
            Br(c, t, e) => {
                ci := &f.insts[c]
                if t != e && ci.args.len == 2 {
                    x := ci.args[0]
                    y := ci.args[1]
                    fwd := same(f, x, iv.start) && same(f, y, iv.end)
                    rev := same(f, x, iv.end) && same(f, y, iv.start)
                    if t == b && ((ci.op == lt && fwd) || (ci.op == gt && rev)) {
                        return true
                    }
                    if e == b && ((ci.op == ge && fwd) || (ci.op == le && rev)) {
                        return true
                    }
                }
            }
            _ => {}
        }
        b = p
    }
    return false
}

// The plainest counted loop, `for i in k..n` with a constant k >= 0, indexing with `i` a
// sequence whose length is `n` itself: the check `i <u n` holds on every iteration, because
// the loop is entered only when k < n and continued only when i + 1 < n. The check is
// removed. Unlike hoisting this puts no condition on the loop body (calls, other exits).
// `def_block`: the block of every instruction, computed when the first loop needs it.
priv fn eliminate_in_loop(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, def_block_v: *Vec[i64]) -> bool {
    l := &loops.loops[li]
    h := l.header
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 || f.succs(outside[0]).len != 1 || l.latches.len != 1 {
        return false
    }
    pre := outside[0]
    latch := l.latches[0]
    // is there a check at all? (most loops have none: do not analyse them)
    any := false
    for b in l.blocks.items() {
        match f.blocks[b].term {
            Br(_, _, e0) if b != latch && is_trap_block(f, e0) => any = true
            _ => {}
        }
        if any {
            break
        }
    }
    if !any {
        return false
    }
    in_loop_v := vec_fill(f.blocks.len, false)
    for b in l.blocks.items() {
        in_loop_v[b] = true
    }
    in_loop := in_loop_v.items()
    if def_block_v.len == 0 {
        *def_block_v = f.block_of()
    }
    def_block := def_block_v.items()
    iv := match find_iv(f, h, latch, pre, in_loop, def_block) {
        Some(x) => x
        None => return false
    }
    if iv.step != 1 || iv.ty != I64 || (iv.cmp != Slt && iv.cmp != Ult) {
        return false
    }
    match f.is_const(iv.start) {
        Some(k) if k >= 0 => {}
        _ => return false
    }
    guarded := false
    guard_known := false
    did := false
    for b in l.blocks.items() {
        c, t, e := match f.blocks[b].term {
            Br(c0, t0, e0) => (c0, t0, e0)
            _ => continue
        }
        if b == latch || t == e || !is_trap_block(f, e) {
            continue
        }
        ci := &f.insts[c]
        idx := 0
        ln := 0
        if ci.op == Ult {
            idx = ci.args[0]
            ln = ci.args[1]
        } else if ci.op == Ugt {
            idx = ci.args[1]
            ln = ci.args[0]
        } else {
            continue
        }
        if idx != iv.phi || !same(f, ln, iv.end) {
            continue
        }
        if !guard_known {
            guard_known = true
            guarded = entry_guard(f, cfg, pre, &iv)
        }
        if !guarded {
            return false
        }
        f.blocks[b].term = Jmp(t)
        did = true
    }
    return did
}

// removes the checks that can never fail, in every loop (nothing here changes the loops)
priv fn eliminate(f: *Func) -> bool {
    licm_make_preheaders(f)
    cfg := cfg_new(f)
    loops := loops_new(f, &cfg)
    def_block := vec[i64]()
    did := false
    for li in 0..loops.loops.len {
        if eliminate_in_loop(f, &cfg, &loops, li, &def_block) {
            did = true
        }
    }
    return did
}

fn bce_run(f: *Func) -> bool {
    changed := false
    if eliminate(f) {
        changed = true
        cleanup_prune_unreachable(f)
    }
    for it in 0..200 {
        licm_make_preheaders(f)
        cfg := cfg_new(f)
        loops := loops_new(f, &cfg)
        order := licm_loop_order(&loops)
        did := false
        for li in order.items() {
            if hoist_in_loop(f, &cfg, &loops, li) {
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
