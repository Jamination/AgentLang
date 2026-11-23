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
    // the counter of a stepped loop (StepLoop) itself, against a length above its bound
    Stepped,
}

// v is defined outside the loop (in_loop: its blocks; def_block: the block of every
// instruction)
priv fn invariant(v: i64, in_loop: []bool, def_block: []i32) -> bool {
    return def_block[v] == NOV || !in_loop[def_block[v]]
}

priv fn find_iv(f: *Func, header: i64, latch: i64, pre: i64, in_loop: []bool, def_block: []i32) -> Opt[Iv] {
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
    cmp := ci.op
    // `cur < end` on the counter itself (an inclusive range `for i in a..=b` is lowered so,
    // which cannot wrap): continuing while cur < end is continuing while cur + 1 <= end, and
    // cur + 1 cannot wrap then. The loop is described by its next value and `<=`.
    cur_form := false
    if f.insts[next].op == Phi {
        cmp = match cmp {
            Slt => Sle
            Ult => Ule
            Sgt => Sge
            Ugt => Uge
            _ => return None
        }
        cur := next
        next = f.insts[cur].phi_input(latch)
        if next == NOV || f.insts[next].op != Add || f.insts[next].args[0] != cur {
            return None
        }
        cur_form = true
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
    if pi.op != Phi || i64(def_block[phi]) != header || pi.args.len != 2 {
        return None
    }
    start := pi.phi_input(pre)
    back := pi.phi_input(latch)
    if start == NOV || back != next {
        return None
    }
    ty := pi.ty
    if cur_form && step != 1 && step != -1 {
        return None
    }
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
    o := cmp
    ok := match (step, o) {
        (1, Slt), (1, Ult), (-1, Sgt), (-1, Ugt) => true
        (1, Sle), (1, Ule), (-1, Sge), (-1, Uge) if cur_form => true
        // inclusive bounds must not sit at the edge of the type (the counter would wrap)
        (1, Sle), (1, Ule), (-1, Sge), (-1, Uge) => match f.is_const(end) {
            Some(k) => {
                bits := ty.bits()
                smin := -9223372036854775807 - 1
                smax := 9223372036854775807
                if bits != 64 {
                    smin = -(1 << (bits - 1))
                    smax = (1 << (bits - 1)) - 1
                }
                match o {
                    Sle => k != smax
                    Sge => k != smin
                    Ule => k != -1
                    _ => k != 0
                }
            }
            None => false
        }
        _ => false
    }
    if !ok {
        return None
    }
    return Some(Iv{phi: phi, start: start, step: step, end: end, cmp: o, ty: ty, last_const: None})
}

// A loop with an increasing step that is not a constant (`for i in a..=b by s`, also
// `a..b by s`), lowered so that it cannot wrap: the latch continues while
//     cur <= end && end - cur >=u s     (exclusive: cur < end && end - cur >u s)
// with cur the header phi and next = cur + s (s invariant). Whatever s is, every value after
// the first lies between it and `end` (end included or not): the next value is taken only
// when it is at most `end` (below it), and cur + s with s <=u end - cur cannot wrap. The
// comparisons are signed or unsigned as the counter's type.
// Once the loop is known to be entered only when `start <= end` (`start < end`), the first
// comparison holds on every iteration and stepped_latch removes it from the latch; the loop
// is still recognised then (by that entry condition).
priv struct StepLoop {
    phi: i64,
    start: i64,
    end: i64,
    incl: bool,
    first: i64, // the comparison of cur with end (NOV once removed)
    room: i64,  // the comparison of the distance with s
}

// Is the loop entered only when `start op end` (op one of `ops`)? The block that is the only
// way to the preheader, or one above it through blocks with one predecessor, branches on it.
priv fn entry_cmp(f: *Func, cfg: *Cfg, pre: i64, ops: []Op, start: i64, end: i64) -> bool {
    b := pre
    for depth in 0..16 {
        if cfg.preds[b].len != 1 {
            return false
        }
        p := cfg.preds[b][0]
        match f.blocks[p].term {
            Br(c, t, e) if t == b && t != e => {
                ci := &f.insts[c]
                if contains(ops, ci.op) && ci.args.len == 2 && same(f, ci.args[0], start) && same(f, ci.args[1], end) {
                    return true
                }
            }
            _ => {}
        }
        b = p
    }
    return false
}

priv fn find_stepped(f: *Func, cfg: *Cfg, header: i64, latch: i64, pre: i64, in_loop: []bool, def_block: []i32) -> Opt[StepLoop] {
    c, t, e := match f.blocks[latch].term {
        Br(c0, t0, e0) => (c0, t0, e0)
        _ => return None
    }
    if t != header || in_loop[e] {
        return None
    }
    first := NOV
    room := c
    if f.insts[c].op == And {
        a0 := f.insts[c].args[0]
        a1 := f.insts[c].args[1]
        first, room = if f.insts[a0].op == Uge || f.insts[a0].op == Ugt { (a1, a0) } else { (a0, a1) }
    }
    ri := &f.insts[room]
    if ri.op != Uge && ri.op != Ugt {
        return None
    }
    incl := ri.op == Uge
    dist := &f.insts[ri.args[0]]
    s := ri.args[1]
    if dist.op != Sub || !invariant(s, in_loop, def_block) {
        return None
    }
    end := dist.args[0]
    phi := dist.args[1]
    pi := &f.insts[phi]
    if pi.op != Phi || i64(def_block[phi]) != header || pi.args.len != 2 || !invariant(end, in_loop, def_block) {
        return None
    }
    start := pi.phi_input(pre)
    next := pi.phi_input(latch)
    if start == NOV || next == NOV {
        return None
    }
    ni := &f.insts[next]
    if ni.op != Add || ni.args[0] != phi || ni.args[1] != s {
        return None
    }
    if first != NOV {
        fi := &f.insts[first]
        ok := if incl { fi.op == Sle || fi.op == Ule } else { fi.op == Slt || fi.op == Ult }
        if !ok || fi.args[0] != phi || !same(f, fi.args[1], end) {
            return None
        }
    } else {
        ops := if incl { []Op{Sle, Ule} } else { []Op{Slt, Ult} }
        if !entry_cmp(f, cfg, pre, ops, start, end) {
            return None
        }
    }
    return Some(StepLoop{phi: phi, start: start, end: end, incl: incl, first: first, room: room})
}

// does every value of the stepped loop's counter after the first lie below `ln` (known at
// compile time)? The bound is `ln` itself for an exclusive loop, or constants with end < ln
// (end <= ln when exclusive), both of them below 2^63
priv fn stepped_below(f: *Func, sp: *StepLoop, ln: i64) -> bool {
    if !sp.incl && same(f, sp.end, ln) {
        return true
    }
    match (f.is_const(sp.end), f.is_const(ln)) {
        (Some(e), Some(n)) => return e >= 0 && n >= 0 && (e < n || !sp.incl && e <= n)
        _ => return false
    }
}

// Removes `cur <= end` (`cur < end`) from the latch of a stepped loop that is only entered
// when `start <= end` (`start < end`, the same comparison): it then holds on every iteration
// (see StepLoop).
priv fn stepped_latch(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block_v: *Vec[i32]) -> bool {
    l := &loops.loops[li]
    h := l.header
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 || f.succs(outside[0]).len != 1 || l.latches.len != 1 {
        return false
    }
    pre := outside[0]
    latch := l.latches[0]
    _, t, e := match f.blocks[latch].term {
        Br(c0, t0, e0) if f.insts[c0].op == And => (c0, t0, e0)
        _ => return false
    }
    if def_block_v.len == 0 {
        *def_block_v = f.block_of()
    }
    sp := match find_stepped(f, cfg, h, latch, pre, in_loop, def_block_v.items()) {
        Some(x) => x
        None => return false
    }
    op := f.insts[sp.first].op
    if !entry_cmp(f, cfg, pre, []Op{op}, sp.start, sp.end) {
        return false
    }
    f.blocks[latch].term = Br(sp.room, t, e)
    return true
}

// A check whose condition does not change in the loop and that the loop header makes before
// anything else (only phis and pure instructions before it) has the same outcome on every
// iteration as on the first, which runs right after the preheader: it moves there, whatever
// the shape of the loop (calls, other exits). (A probe loop over a power-of-two table,
// `i = (i + 1) & (len - 1)`, checks `len != 0` there.)
priv fn header_check(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block_v: *Vec[i32]) -> bool {
    l := &loops.loops[li]
    h := l.header
    c, ok, trap := match f.blocks[h].term {
        Br(c0, t0, e0) if t0 != e0 => (c0, t0, e0)
        _ => return false
    }
    if !in_loop[ok] || in_loop[trap] || !opt_is_check_trap(f, trap) {
        return false
    }
    for v in f.blocks[h].insts {
        o := f.insts[v].op
        if o != Phi && !o.is_pure() {
            return false
        }
    }
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 || f.succs(outside[0]).len != 1 {
        return false
    }
    pre := outside[0]
    if def_block_v.len == 0 {
        *def_block_v = f.block_of()
    }
    if !invariant(c, in_loop, def_block_v.items()) {
        return false
    }
    f.blocks[pre].term = Br(c, h, trap)
    f.blocks[h].term = Jmp(ok)
    return true
}

// match idx as ext(inner) with inner = iv, inner + inv, inner - inv or inv - inner
priv fn match_affine(f: *Func, idx: i64, iv: *Iv, in_loop: []bool, def_block: []i32) -> Opt[BceAffine] {
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
        if i.op == Add || i.op == Sub {
            a := i.args[0]
            b := i.args[1]
            if invariant(b, in_loop, def_block) && !invariant(a, in_loop, def_block) {
                v = a
            } else if invariant(a, in_loop, def_block) && !invariant(b, in_loop, def_block) {
                if i.op == Sub {
                    coef = -coef
                }
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
priv fn clone_at(f: *Func, pre: i64, v: i64, iv_phi: i64, at: i64, in_loop: []bool, def_block: []i32) -> i64 {
    if v == iv_phi {
        return at
    }
    if v >= len(def_block) || invariant(v, in_loop, def_block) {
        return v
    }
    i := clone(f.insts[v])
    args := vec[i64]()
    for a in i.args {
        args.push(clone_at(f, pre, a, iv_phi, at, in_loop, def_block))
    }
    return f.push(pre, i.op, i.ty, args, i.k)
}

// For idx = zext(inner) the hoisted checks assume that inner moves monotonically as an unsigned
// number. Narrow arithmetic in inner (u8 `i + 10`) or a signed counter crossing -1 -> 0 can wrap
// around at the narrow width and still give indices that are all in bounds (a[250..=255],
// then a[0..]), which the first/last/order checks would reject: a panic where there is none.
// A wrap visits a value >= 2^bits - |step|, so it is harmless only to show when the length is
// a constant no larger than that (the wrapping access is then out of bounds itself).
priv fn zext_cannot_wrap(f: *Func, a: *BceAffine, iv: *Iv, ln: i64) -> bool {
    if a.ext != Some(ZExt) {
        return true
    }
    unsigned := iv.cmp == Ult || iv.cmp == Ule || iv.cmp == Ugt || iv.cmp == Uge
    if a.inner == iv.phi && unsigned {
        return true
    }
    bits := iv.ty.bits()
    if bits >= 64 {
        return false
    }
    match f.is_const(ln) {
        Some(k) => k >= 0 && k <= (1 << bits) - abs(iv.step)
        None => false
    }
}

// `in_loop`: the blocks of loop `li` are marked (by the caller, in one buffer for all loops).
// `def_block`: the block of every instruction, computed when the first loop needs it and shared
// by the loops of one round (hoisting adds instructions but moves none)
priv fn hoist_in_loop(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block_v: *Vec[i32]) -> bool {
    l := &loops.loops[li]
    h := l.header
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 || f.succs(outside[0]).len != 1 || l.latches.len != 1 {
        return false
    }
    pre := outside[0]
    latch := l.latches[0]
    // the loop may only be left through its latch or through failing checks, and has no calls
    for b in l.blocks {
        for v in f.blocks[b].insts {
            o := f.insts[v].op
            if o == Call || o == CallInd || o == Syscall || o == Atomic {
                return false
            }
        }
        match f.blocks[b].term {
            Ret(_), Trap, Term.None => return false
            _ => {}
        }
        ss := f.succs(b)
        for s in ss {
            if !in_loop[s] && b != latch && !opt_is_check_trap(f, s) {
                return false
            }
        }
    }
    if def_block_v.len == 0 {
        *def_block_v = f.block_of()
    }
    def_block := def_block_v.items()
    iv_opt := find_iv(f, h, latch, pre, in_loop, def_block)
    has_iv := is_some(iv_opt)
    iv := iv_opt.or(Iv{})
    sp_opt: Opt[StepLoop] = if has_iv { None } else { find_stepped(f, cfg, h, latch, pre, in_loop, def_block) }
    // collect candidate checks
    cands := vec[(i64, i64, i64, i64, i64, i64, Kind)]() // block, cond, ok, trap, idx, len
    for b in l.blocks {
        c, t, e := match f.blocks[b].term {
            Br(c0, t0, e0) => (c0, t0, e0)
            _ => continue
        }
        if !in_loop[t] || in_loop[e] || !opt_is_check_trap(f, e) || b == latch {
            continue
        }
        if !cfg.dom(b, latch) {
            continue
        }
        ci := &f.insts[c]
        idx, ln := match ci.op {
            Ult => (ci.args[0], ci.args[1])
            Ugt => (ci.args[1], ci.args[0])
            _ => continue
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
                Some(a) if zext_cannot_wrap(f, &a, &iv, ln) => cands.push((b, c, t, e, idx, ln, Affine(a)))
                _ => {}
            }
        }
        match &sp_opt {
            Some(&sp) if idx == sp.phi && stepped_below(f, sp, ln) => cands.push((b, c, t, e, idx, ln, Kind.Stepped))
            _ => {}
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
                for cand in cands {
                    if cand.6 != Invariant {
                        any_affine = true
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
    fn index_at(f: *Func, at: i64, pre: i64, a: *BceAffine, iv: *Iv, in_loop: []bool, def_block: []i32) -> i64 {
        inner := clone_at(f, pre, a.inner, iv.phi, at, in_loop, def_block)
        match a.ext {
            Some(op) => f.push(pre, op, I64, vec_of([]i64{inner}), 0)
            None => inner
        }
    }
    for ci in 0..cands.len {
        b, c, ok, trap, _, ln, kind := cands[ci]
        match kind {
            Invariant => {
                add_check(f, &cur, c, trap, h)
            }
            Kind.Stepped => {
                // the first value; the others lie between it and a bound below the length
                sp := sp_opt.or(StepLoop{})
                c1 := f.push(pre, Ult, I8, vec_of([]i64{sp.start, ln}), 0)
                add_check(f, &cur, c1, trap, h)
            }
            Affine(a) => {
                assert has_iv
                e_first := index_at(f, iv.start, pre, &a, &iv, in_loop, def_block)
                e_last := index_at(f, last_eff, pre, &a, &iv, in_loop, def_block)
                c1 := f.push(pre, Ult, I8, vec_of([]i64{e_first, ln}), 0)
                c2 := f.push(pre, Ult, I8, vec_of([]i64{e_last, ln}), 0)
                // coef and step are not 0: the order of the indices of the first and the last
                // iteration
                x, y := if (a.coef > 0) == (iv.step > 0) { (e_first, e_last) } else { (e_last, e_first) }
                c3 := f.push(pre, Ule, I8, vec_of([]i64{x, y}), 0)
                add_check(f, &cur, c1, trap, h)
                add_check(f, &cur, c2, trap, h)
                add_check(f, &cur, c3, trap, h)
                if abs(a.coef) > 1 {
                    // the trip count must be small enough that coef * iv cannot wrap; when it is
                    // not, some access is out of bounds anyway
                    d := if iv.step > 0 {
                        f.push(pre, Sub, I64, vec_of([]i64{last_eff, iv.start}), 0)
                    } else {
                        f.push(pre, Sub, I64, vec_of([]i64{iv.start, last_eff}), 0)
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
        f.phi_pred_replace(h, pre, cur)
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
        (Some(s), Some(e)) => return simplify_fold_icmp(iv.cmp, iv.ty, s, e).or(false)
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
// `in_loop`: the blocks of loop `li` are marked (by the caller, in one buffer for all loops).
// `def_block`: the block of every instruction, computed when the first loop needs it.
priv fn eliminate_in_loop(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block_v: *Vec[i32]) -> bool {
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
    for b in l.blocks {
        match f.blocks[b].term {
            Br(_, _, e0) if b != latch && is_trap_block(f, e0) => {
                any = true
                break
            }
            _ => {}
        }
    }
    if !any {
        return false
    }
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
    for b in l.blocks {
        c, t, e := match f.blocks[b].term {
            Br(c0, t0, e0) => (c0, t0, e0)
            _ => continue
        }
        if b == latch || t == e || !is_trap_block(f, e) {
            continue
        }
        ci := &f.insts[c]
        idx, ln := match ci.op {
            Ult => (ci.args[0], ci.args[1])
            Ugt => (ci.args[1], ci.args[0])
            _ => continue
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
    cfg, loops := cfg_loops(f)
    def_block := vec[i32]()
    in_loop := vec_fill(f.blocks.len, false)
    did := false
    for li in 0..loops.loops.len {
        loops.mark_blocks(li, in_loop.items(), true)
        if eliminate_in_loop(f, &cfg, &loops, li, in_loop.items(), &def_block) {
            did = true
        }
        loops.mark_blocks(li, in_loop.items(), false)
    }
    return did
}

fn bce_run(f: *Func) -> bool {
    changed := false
    if opt_enabled("bcerange") && rg_run(f) {
        changed = true
        cleanup_prune_unreachable(f)
    }
    if eliminate(f) {
        changed = true
        cleanup_prune_unreachable(f)
    }
    for it in 0..200 {
        licm_make_preheaders(f)
        cfg, loops := cfg_loops(f)
        order := licm_loop_order(&loops)
        // one analysis serves every loop of the round except the ancestors of a loop that
        // changed (their block lists and dominators are stale); deeper loops come first.
        // Hoisting one loop per round made functions with many loops quadratic in time and
        // memory (and left loops after the 200th unhoisted)
        touched := vec_fill(loops.loops.len, false)
        def_block := vec[i32]()
        // sized before any hoisting: blocks added this round belong to no loop of the round
        in_loop := vec_fill(f.blocks.len, false)
        did := false
        for li in order {
            if touched[li] {
                continue
            }
            loops.mark_blocks(li, in_loop.items(), true)
            hoisted := hoist_in_loop(f, &cfg, &loops, li, in_loop.items(), &def_block)
            if !hoisted {
                hoisted = header_check(f, &cfg, &loops, li, in_loop.items(), &def_block)
            }
            loops.mark_blocks(li, in_loop.items(), false)
            if hoisted {
                did = true
                up := loops.loops[li].parent
                loop {
                    match up {
                        Some(p) => {
                            touched[p] = true
                            up = loops.loops[p].parent
                        }
                        None => break
                    }
                }
            }
        }
        if !did {
            break
        }
        changed = true
        cleanup_prune_unreachable(f)
    }
    // the latches of stepped loops (after hoisting, which recognises them by that latch)
    any := false
    for b in 0..f.blocks.len {
        match f.blocks[b].term {
            Br(c, _, _) if f.insts[c].op == And => {
                for a in f.insts[c].args {
                    o := f.insts[a].op
                    if (o == Uge || o == Ugt) && f.insts[f.insts[a].args[0]].op == Sub {
                        any = true
                    }
                }
            }
            _ => {}
        }
    }
    if any {
        licm_make_preheaders(f)
        cfg, loops := cfg_loops(f)
        def_block := vec[i32]()
        in_loop := vec_fill(f.blocks.len, false)
        for li in 0..loops.loops.len {
            loops.mark_blocks(li, in_loop.items(), true)
            if stepped_latch(f, &cfg, &loops, li, in_loop.items(), &def_block) {
                changed = true
            }
            loops.mark_blocks(li, in_loop.items(), false)
        }
    }
    return changed
}

// ---------- checks decided by dominating conditions ----------
// A bounds check `idx <u len` holds when 0 <= idx < len (signed), which the conditions of the
// branches that lead to it often show: `while i < n && s[i] != 0` (n the length), `while i + 4
// <= n` with s[i], s[i + 1], ... A small range analysis over the dominator tree answers three
// questions about a value x at a place in the function (a block, or the way from a block into
// another): a lower bound, an upper bound, and a bound c with x - y <= c for another value y.
// Every value is read as the signed number it holds; `x + k` is x plus k only where the bounds
// of x show that the sum does not wrap. Its sources are
// - the conditions of the branches into the blocks that dominate the place (also checks that
//   passed: a check is a branch to a trap block);
// - the definitions (constants, sums with constants, masks, zero extensions, shifts, remainders);
// - the phis of loops, by induction: a bound that holds for the inputs from outside the loop and
//   that the inputs along the back edges keep, assuming it for the phi itself;
// - lengths: the second operand of a bounds check (`idx <u len`) is the length of a sequence of
//   `len` elements in memory, at least 0 and below 2^62 (no object is larger; other lengths
//   only come from what is not checked: `mkslice`, a `Vec` length set by hand).
// A check is removed when its condition is proven with the check itself left out (so no proof
// leans on what it proves), one at a time (each later proof sees only the checks still there).
// A run of checks `x + k1 <u len`, `x + k2 <u len`, ... with nothing but checks and plain
// instructions between them becomes one check of the largest index at the place of the first:
// the others pass with it when x + min k >= 0. (That a check fails earlier is not observable,
// as in hoisting and checkmerge: only which failing access is reported can differ.)

priv fn rg_min() -> i64 {
    return -9223372036854775807 - 1
}

priv fn rg_max() -> i64 {
    return 9223372036854775807
}

// the largest length (see above)
priv fn rg_len_max() -> i64 {
    return 1 << 62
}

// a true comparison `a op b`, op one of Slt Sle Ult Ule Eq Ne
priv struct RgFact {
    op: Op
    a: i64
    b: i64
}

priv struct Rg {
    f: *Func
    cfg: Cfg
    def_block: Vec[i32]
    nb: i64
    // the operands that are lengths of bounds checks
    is_len: Vec[bool]
    // facts by place: places 0..nb are blocks, nb + j the way edges[j] = (from, to)
    edges: Vec[(i64, i64)]
    facts: Vec[Vec[RgFact]]
    fgen: Vec[i64]
    gen: i64
    budget: i64
    // the bounds assumed for phis while their induction is checked: (phi, kind, y, bound);
    // kind 0: phi >= bound, 1: phi <= bound, 2: phi - y <= bound
    asm: Vec[(i64, i64, i64, i64)]
    // the length of the check being proven (NOV: none)
    ctx_y: i64
    // how deep the questions go
    depth: i64
    // the answers so far: (kind and place, x, y, the assumptions) -> (depth, bound); kind 0
    // lower bound, 1 upper bound, 2 x - y; emptied when the facts change
    cache: Map[(i64, i64, i64, i64), (i64, i64)]
}

// the key of an answer under the current assumptions
priv fn rg_key(self: *Rg, kind: i64, x: i64, y: i64, pos: i64) -> (i64, i64, i64, i64) {
    sig: u64 = 0
    for a in self.asm {
        sig = (sig ^ u64(a.0)) * 0x9E3779B97F4A7C15
        sig = (sig ^ u64(a.1 + 4 * a.2)) * 0x9E3779B97F4A7C15
        sig = (sig ^ u64(a.3)) * 0x9E3779B97F4A7C15
    }
    return (kind + 4 * pos, x, y, i64(sig))
}

// a remembered answer found at least as deep as d
priv fn rg_cached(self: *Rg, key: (i64, i64, i64, i64), d: i64) -> Opt[i64] {
    dv, found := self.cache.get(key)
    if found && dv.0 >= d {
        return Some(dv.1)
    }
    return None
}

// a + b, or None when it wraps
priv fn rg_add(a: i64, b: i64) -> Opt[i64] {
    if (b > 0 && a > rg_max() - b) || (b < 0 && a < rg_min() - b) {
        return None
    }
    return Some(a + b)
}

priv fn rg_const(self: *Rg, v: i64) -> Opt[i64] {
    i := &self.f.insts[v]
    if i.op == Const && i.ty == I64 {
        return Some(i.k)
    }
    return None
}

// x = y + k with k a constant (also y - k): (y, k)
priv fn rg_split(self: *Rg, x: i64) -> Opt[(i64, i64)] {
    i := &self.f.insts[x]
    if i.ty != I64 || i.args.len != 2 {
        return None
    }
    if i.op == Add {
        match self.rg_const(i.args[1]) {
            Some(k) => return Some((i.args[0], k))
            None => {}
        }
        match self.rg_const(i.args[0]) {
            Some(k) => return Some((i.args[1], k))
            None => {}
        }
    }
    if i.op == Sub {
        match self.rg_const(i.args[1]) {
            Some(k) if k != rg_min() => return Some((i.args[0], -k))
            _ => {}
        }
    }
    return None
}

priv fn rg_block_of(self: *Rg, v: i64) -> i64 {
    if v >= self.def_block.len || self.def_block[v] == NOV {
        return -1
    }
    return i64(self.def_block[v])
}

// the place of the way from p into b
priv fn rg_edge(self: *Rg, p: i64, b: i64) -> i64 {
    for j in 0..self.edges.len {
        if self.edges[j] == (p, b) {
            return self.nb + j
        }
    }
    self.edges.push((p, b))
    self.facts.push(vec[RgFact]())
    self.fgen.push(-1)
    return self.nb + self.edges.len - 1
}

// the fact the branch of block p gives on its way into block b
priv fn rg_edge_fact(self: *Rg, p: i64, b: i64, out: *Vec[RgFact]) {
    c, t, e := match self.f.blocks[p].term {
        Br(c0, t0, e0) if t0 != e0 && (t0 == b || e0 == b) => (c0, t0, e0)
        _ => return
    }
    ci := &self.f.insts[c]
    if !ci.op.is_icmp() || ci.args.len != 2 || self.f.insts[ci.args[0]].ty != I64 {
        return
    }
    o := if t == b { ci.op } else { ci.op.negate_icmp() }
    x := ci.args[0]
    y := ci.args[1]
    match o {
        Sgt => out.push(RgFact{op: Slt, a: y, b: x})
        Sge => out.push(RgFact{op: Sle, a: y, b: x})
        Ugt => out.push(RgFact{op: Ult, a: y, b: x})
        Uge => out.push(RgFact{op: Ule, a: y, b: x})
        _ => out.push(RgFact{op: o, a: x, b: y})
    }
}

// the facts that hold at place `pos`
priv fn rg_facts(self: *Rg, pos: i64) -> Vec[RgFact] {
    if self.fgen[pos] == self.gen {
        return self.facts[pos]
    }
    out := vec[RgFact]()
    b := pos
    if pos >= self.nb {
        p, to := self.edges[pos - self.nb]
        self.rg_edge_fact(p, to, &out)
        b = p
    }
    // up the dominator tree: the branch into every block with one predecessor
    for depth in 0..64 {
        if b == 0 || out.len >= 40 {
            break
        }
        if self.cfg.preds[b].len == 1 {
            self.rg_edge_fact(self.cfg.preds[b][0], b, &out)
        }
        if self.cfg.idom[b] == NOV {
            break
        }
        b = i64(self.cfg.idom[b])
    }
    self.facts[pos] = out
    self.fgen[pos] = self.gen
    return out
}

// is v at least 0 (at pos)?
priv fn rg_nonneg(self: *Rg, v: i64, pos: i64, d: i64) -> bool {
    return self.is_len[v] || self.rg_lo(v, pos, d) >= 0
}

// rg_lo_raw, rg_hi_raw and rg_ub_raw, each answer remembered
priv fn rg_lo(self: *Rg, x: i64, pos: i64, d: i64) -> i64 {
    if self.f.insts[x].op == Const || d <= 0 {
        return self.rg_lo_raw(x, pos, d)
    }
    key := self.rg_key(0, x, NOV, pos)
    match self.rg_cached(key, d) {
        Some(r) => return r
        None => {}
    }
    r := self.rg_lo_raw(x, pos, d)
    self.cache.set(key, (d, r))
    return r
}

priv fn rg_hi(self: *Rg, x: i64, pos: i64, d: i64) -> i64 {
    if self.f.insts[x].op == Const || d <= 0 {
        return self.rg_hi_raw(x, pos, d)
    }
    key := self.rg_key(1, x, NOV, pos)
    match self.rg_cached(key, d) {
        Some(r) => return r
        None => {}
    }
    r := self.rg_hi_raw(x, pos, d)
    self.cache.set(key, (d, r))
    return r
}

priv fn rg_ub(self: *Rg, x: i64, y: i64, pos: i64, d: i64) -> i64 {
    if x == y || d <= 0 {
        return self.rg_ub_raw(x, y, pos, d)
    }
    key := self.rg_key(2, x, y, pos)
    match self.rg_cached(key, d) {
        Some(r) => return r
        None => {}
    }
    r := self.rg_ub_raw(x, y, pos, d)
    self.cache.set(key, (d, r))
    return r
}

// a lower bound of x at pos (rg_min(): none known)
priv fn rg_lo_raw(self: *Rg, x: i64, pos: i64, d: i64) -> i64 {
    i := &self.f.insts[x]
    if i.ty != I64 {
        return rg_min()
    }
    if i.op == Const {
        return i.k
    }
    if d <= 0 || self.budget <= 0 {
        return if self.is_len[x] { 0 } else { rg_min() }
    }
    self.budget -= 1
    r := rg_min()
    args := i.args
    match i.op {
        ZExt => r = 0
        And => {
            if self.rg_nonneg(args[0], pos, d - 1) || self.rg_nonneg(args[1], pos, d - 1) {
                r = 0
            }
        }
        LShr => match self.rg_const(args[1]) {
            Some(k) if k & 63 != 0 => r = 0
            _ => {}
        }
        URem => match self.rg_const(args[1]) {
            Some(k) if k > 0 => r = 0
            _ => {}
        }
        UDiv => match self.rg_const(args[1]) {
            Some(k) if k > 1 || k < 0 => r = 0
            _ => {}
        }
        SRem => match self.rg_const(args[1]) {
            Some(k) if k != 0 && k != rg_min() => {
                r = if self.rg_nonneg(args[0], pos, d - 1) { 0 } else { -(abs(k) - 1) }
            }
            _ => {}
        }
        Add, Sub => {
            match self.rg_split(x) {
                Some((y, k)) => {
                    // y + k does not wrap when y <= max - k (k > 0); k < 0 only lowers it
                    ly := self.rg_lo(y, pos, d - 1)
                    ok := if k > 0 { self.rg_hi(y, pos, d - 1) <= rg_max() - k } else { true }
                    if ok {
                        match rg_add(ly, k) {
                            Some(s) => r = s
                            None => {}
                        }
                    }
                }
                None => {}
            }
        }
        Select => r = min(self.rg_lo(args[1], pos, d - 1), self.rg_lo(args[2], pos, d - 1))
        Phi => r = self.rg_phi(x, 0, NOV, d)
        _ => {}
    }
    if self.is_len[x] {
        r = max(r, 0)
    }
    for a in self.asm {
        if a.0 == x && a.1 == 0 {
            r = max(r, a.3)
        }
    }
    for fa in self.rg_facts(pos) {
        if fa.b == x {
            match fa.op {
                Slt => r = max(r, sat_add(self.rg_lo(fa.a, pos, d - 1), 1))
                Sle, Eq => r = max(r, self.rg_lo(fa.a, pos, d - 1))
                _ => {}
            }
        } else if fa.a == x {
            match fa.op {
                Eq => r = max(r, self.rg_lo(fa.b, pos, d - 1))
                Ult, Ule => {
                    if self.rg_nonneg(fa.b, pos, d - 1) {
                        r = max(r, 0)
                    }
                }
                _ => {}
            }
        }
    }
    return r
}

// an upper bound of x at pos (rg_max(): none known)
priv fn rg_hi_raw(self: *Rg, x: i64, pos: i64, d: i64) -> i64 {
    i := &self.f.insts[x]
    if i.ty != I64 {
        return rg_max()
    }
    if i.op == Const {
        return i.k
    }
    if d <= 0 || self.budget <= 0 {
        return if self.is_len[x] { rg_len_max() } else { rg_max() }
    }
    self.budget -= 1
    r := rg_max()
    args := i.args
    match i.op {
        ZExt => {
            bits := self.f.insts[args[0]].ty.bits()
            if bits < 63 {
                r = (1 << bits) - 1
            }
        }
        And => {
            for a in args {
                if self.rg_nonneg(a, pos, d - 1) {
                    r = min(r, self.rg_hi(a, pos, d - 1))
                }
            }
        }
        LShr => match self.rg_const(args[1]) {
            Some(k) if k & 63 != 0 => {
                s := k & 63
                r = if self.rg_nonneg(args[0], pos, d - 1) { self.rg_hi(args[0], pos, d - 1) >> s } else { rg_max() >> (s - 1) }
            }
            _ => {}
        }
        URem => match self.rg_const(args[1]) {
            Some(k) if k > 0 => r = k - 1
            _ => {}
        }
        SRem => match self.rg_const(args[1]) {
            Some(k) if k != 0 && k != rg_min() => r = abs(k) - 1
            _ => {}
        }
        Add, Sub => {
            match self.rg_split(x) {
                Some((y, k)) => {
                    // y + k does not wrap when y >= min - k (k < 0); k > 0 only raises it
                    hy := self.rg_hi(y, pos, d - 1)
                    ok := if k < 0 { self.rg_lo(y, pos, d - 1) >= rg_min() - k } else { true }
                    if ok {
                        match rg_add(hy, k) {
                            Some(s) => r = s
                            None => {}
                        }
                    }
                }
                None => {}
            }
        }
        Select => r = max(self.rg_hi(args[1], pos, d - 1), self.rg_hi(args[2], pos, d - 1))
        Phi => {
            // below the length of the check being proven, or by an induction of its own
            if self.ctx_y != NOV {
                u := self.rg_phi(x, 2, self.ctx_y, d)
                if u != rg_max() {
                    r = sat_add(self.rg_hi(self.ctx_y, pos, d - 1), u)
                }
            }
            if r == rg_max() {
                r = self.rg_phi(x, 1, NOV, d)
            }
        }
        _ => {}
    }
    if self.is_len[x] {
        r = min(r, rg_len_max())
    }
    for ai in 0..self.asm.len {
        a := self.asm[ai]
        if a.0 == x && a.1 == 1 {
            r = min(r, a.3)
        }
        if a.0 == x && a.1 == 2 {
            // x - y <= c
            r = min(r, sat_add(self.rg_hi(a.2, pos, d - 1), a.3))
        }
    }
    for fa in self.rg_facts(pos) {
        // the fact bounds z from above by bz
        z := NOV
        bz := rg_max()
        z_nonneg := false
        match fa.op {
            Slt => {
                z = fa.a
                bz = sat_sub(self.rg_hi(fa.b, pos, d - 1), 1)
            }
            Sle => {
                z = fa.a
                bz = self.rg_hi(fa.b, pos, d - 1)
            }
            Eq => {
                z = if fa.b == x { fa.b } else { fa.a }
                bz = self.rg_hi(if fa.b == x { fa.a } else { fa.b }, pos, d - 1)
            }
            Ult, Ule => {
                if self.rg_nonneg(fa.b, pos, d - 1) {
                    z = fa.a
                    hb := self.rg_hi(fa.b, pos, d - 1)
                    bz = if fa.op == Ult { hb - 1 } else { hb }
                    z_nonneg = true
                }
            }
            _ => {}
        }
        if z == NOV || bz == rg_max() {
            continue
        }
        if z == x {
            r = min(r, bz)
            continue
        }
        // a fact on z = x + k bounds x = z - k when that does not wrap
        match self.rg_split(z) {
            Some((y, k)) if y == x => {
                ok := if k > 0 { z_nonneg || self.rg_lo(z, pos, d - 1) >= rg_min() + k } else { bz <= rg_max() + k }
                if ok {
                    r = min(r, bz - k)
                }
            }
            _ => {}
        }
    }
    return r
}

// a bound c with x - y <= c at pos (rg_max(): none known)
priv fn rg_ub_raw(self: *Rg, x: i64, y: i64, pos: i64, d: i64) -> i64 {
    if x == y {
        return 0
    }
    match self.rg_const(y) {
        Some(ky) => {
            if ky == rg_min() {
                return rg_max()
            }
            return match rg_add(self.rg_hi(x, pos, d), -ky) {
                Some(s) => s
                None => rg_max()
            }
        }
        None => {}
    }
    if d <= 0 || self.budget <= 0 {
        return rg_max()
    }
    self.budget -= 1
    r := rg_max()
    match self.rg_const(x) {
        Some(kx) => {
            ly := self.rg_lo(y, pos, d - 1)
            if ly != rg_min() {
                match rg_add(kx, -ly) {
                    Some(s) => r = s
                    None => {}
                }
            }
            return r
        }
        None => {}
    }
    // x = z + k (not wrapping): x - y = (z - y) + k
    match self.rg_split(x) {
        Some((z, k)) => {
            ok := if k > 0 { self.rg_hi(z, pos, d - 1) <= rg_max() - k } else { self.rg_lo(z, pos, d - 1) >= rg_min() - k }
            if ok {
                u := self.rg_ub(z, y, pos, d - 1)
                if u != rg_max() {
                    r = min(r, sat_add(u, k))
                }
            }
        }
        None => {}
    }
    // y = z + k (not wrapping): x - y = (x - z) - k
    match self.rg_split(y) {
        Some((z, k)) => {
            ok := if k > 0 { self.rg_hi(z, pos, d - 1) <= rg_max() - k } else { self.rg_lo(z, pos, d - 1) >= rg_min() - k }
            if ok {
                u := self.rg_ub(x, z, pos, d - 1)
                if u != rg_max() {
                    r = min(r, sat_sub(u, k))
                }
            }
        }
        None => {}
    }
    if self.f.insts[x].op == Phi {
        r = min(r, self.rg_phi(x, 2, y, d))
    }
    for a in self.asm {
        if a.0 == x && a.1 == 2 && a.2 == y {
            r = min(r, a.3)
        }
    }
    for fa in self.rg_facts(pos) {
        // up to two relations (a, b, c): a - b <= c
        rels := [2](i64, i64, i64){(NOV, NOV, 0), (NOV, NOV, 0)}
        unsigned := false
        match fa.op {
            Slt => rels[0] = (fa.a, fa.b, -1)
            Sle => rels[0] = (fa.a, fa.b, 0)
            Eq => {
                rels[0] = (fa.a, fa.b, 0)
                rels[1] = (fa.b, fa.a, 0)
            }
            Ult, Ule => {
                // with b >= 0, a <u b is 0 <= a < b
                if self.rg_nonneg(fa.b, pos, d - 1) {
                    rels[0] = (fa.a, fa.b, if fa.op == Ult { -1 } else { 0 })
                    unsigned = true
                }
            }
            _ => {}
        }
        for ri in 0..2 {
            a, b, c := rels[ri]
            if a == NOV {
                continue
            }
            k := 0
            if a != x {
                // a = x + k: x = a - k when that does not wrap
                match self.rg_split(a) {
                    Some((z, k1)) if z == x => {
                        ok := if k1 > 0 { unsigned || self.rg_lo(a, pos, d - 1) >= rg_min() + k1 } else { self.rg_hi(a, pos, d - 1) <= rg_max() + k1 }
                        if !ok {
                            continue
                        }
                        k = k1
                    }
                    _ => continue
                }
            }
            // x - y = (a - b) - k + (b - y)
            u := if b == y { 0 } else { self.rg_ub(b, y, pos, d - 1) }
            if u != rg_max() {
                r = min(r, sat_add(sat_sub(c, k), u))
            }
        }
    }
    return r
}

// a bound of loop phi x, of kind `kind` (0: lower, 1: upper, 2: x - y <= c), by induction over
// the ways into its block: the weakest bound of the inputs from outside the loop, if the inputs
// along the back edges keep it while it is assumed for x (widened up to twice). A lower bound
// and a bound against the length of the check being proven (`ctx_y`) are shown together: each
// may need the other (`i + 4` does not wrap because i <= n - 4, and i >= 0 holds).
priv fn rg_phi(self: *Rg, x: i64, kind: i64, y: i64, d: i64) -> i64 {
    none := if kind == 0 { rg_min() } else { rg_max() }
    for a in self.asm {
        if a.0 == x && a.1 == kind && a.2 == y {
            // inside its own induction: the assumption answers (the callers look at it)
            return none
        }
    }
    h := self.rg_block_of(x)
    if h < 0 || d <= 0 {
        return none
    }
    n := self.f.insts[x].args.len
    if n == 0 || n > 8 || self.cfg.preds[h].len != n {
        return none
    }
    // y must keep its value in the loop: defined above the phi's block
    fn above(s: *Rg, y: i64, h: i64) -> bool {
        if is_some(s.rg_const(y)) {
            return true
        }
        yb := s.rg_block_of(y)
        return yb >= 0 && yb != h && s.cfg.dom(yb, h)
    }
    if kind == 2 && !above(self, y, h) {
        return none
    }
    // the components shown together: (kind, y, alive)
    comps := vec[(i64, i64, bool)]()
    comps.push((kind, y, true))
    if kind == 0 && self.ctx_y != NOV && above(self, self.ctx_y, h) {
        comps.push((2, self.ctx_y, true))
    } else if kind == 2 && y == self.ctx_y {
        comps.push((0, NOV, true))
    }
    ins := vec[i64]()
    frs := vec[i64]()
    for k in 0..n {
        ins.push(self.f.insts[x].args[k])
        frs.push(self.f.insts[x].from()[k])
    }
    fn bound(s: *Rg, kind: i64, v: i64, y: i64, pos: i64, d: i64) -> i64 {
        return match kind {
            0 => s.rg_lo(v, pos, d)
            1 => s.rg_hi(v, pos, d)
            _ => s.rg_ub(v, y, pos, d)
        }
    }
    fn nothing(kind: i64) -> i64 {
        return if kind == 0 { rg_min() } else { rg_max() }
    }
    // a is a weaker bound than b
    fn worse(kind: i64, a: i64, b: i64) -> bool {
        return if kind == 0 { a < b } else { a > b }
    }
    cands := vec[i64]()
    any_back := false
    for ci in 0..comps.len {
        ck, cy, _ := comps[ci]
        cand := if ck == 0 { rg_max() } else { rg_min() }
        for k in 0..n {
            p := frs[k]
            if self.cfg.dom(h, p) {
                any_back = true
                continue
            }
            b := bound(self, ck, ins[k], cy, self.rg_edge(p, h), d - 1)
            if worse(ck, b, cand) {
                cand = b
            }
        }
        if cand == nothing(ck) || cand == (if ck == 0 { rg_max() } else { rg_min() }) {
            // nothing known, or no way in from outside the loop
            if ci == 0 {
                return none
            }
            comps[ci] = (ck, cy, false)
        }
        cands.push(cand)
    }
    if !any_back {
        return cands[0]
    }
    for round in 0..4 {
        mark := self.asm.len
        for ci in 0..comps.len {
            ck, cy, alive := comps[ci]
            if alive {
                self.asm.push((x, ck, cy, cands[ci]))
            }
        }
        held := true
        weak := vec_of(cands.items())
        for ci in 0..comps.len {
            ck, cy, alive := comps[ci]
            if !alive {
                continue
            }
            for k in 0..n {
                p := frs[k]
                if !self.cfg.dom(h, p) || ins[k] == x {
                    continue
                }
                b := bound(self, ck, ins[k], cy, self.rg_edge(p, h), d - 1)
                if worse(ck, b, weak[ci]) {
                    weak[ci] = b
                    held = false
                }
            }
        }
        self.asm.len = mark
        if held {
            return cands[0]
        }
        if round == 3 {
            break
        }
        // widen; a component with no bound left is given up (the others are shown again
        // without it)
        for ci in 0..comps.len {
            ck, cy, alive := comps[ci]
            if !alive {
                continue
            }
            if weak[ci] == nothing(ck) || round >= 1 && weak[ci] != cands[ci] {
                if ci == 0 {
                    return none
                }
                comps[ci] = (ck, cy, false)
            }
            cands[ci] = weak[ci]
        }
    }
    return none
}

// the facts are found again (a terminator changed)
priv fn rg_forget(self: *Rg) {
    self.gen += 1
    self.cache.clear()
}

// is `idx <u len` true at block b (whose own branch is not counted)?
priv fn rg_proves(self: *Rg, idx: i64, ln: i64, b: i64) -> bool {
    self.ctx_y = ln
    self.cache.clear()
    self.budget = 6000
    ok := self.rg_lo(idx, b, self.depth) >= 0
    if ok {
        self.budget = 6000
        ok = self.rg_ub(idx, ln, b, self.depth) <= -1
    }
    self.ctx_y = NOV
    return ok
}

// (index, length) of a bounds check condition
priv fn rg_check(f: *Func, c: i64) -> Opt[(i64, i64)] {
    ci := &f.insts[c]
    idx, ln := match ci.op {
        Ult => (ci.args[0], ci.args[1])
        Ugt => (ci.args[1], ci.args[0])
        _ => return None
    }
    if f.insts[idx].ty != I64 || f.insts[ln].ty != I64 {
        return None
    }
    return Some((idx, ln))
}

// a new instruction in block b
priv fn rg_push(self: *Rg, b: i64, op: Op, args: Vec[i64], k: i64) -> i64 {
    ty := if op.is_cmp() { I8 } else { I64 }
    v := self.f.push(b, op, ty, args, k)
    self.def_block.resize(self.f.insts.len, i32(NOV))
    self.is_len.resize(self.f.insts.len, false)
    self.def_block[v] = i32(b)
    return v
}

// merges the run of checks `x + k <u len` that starts at block b (see above)
priv fn rg_merge(self: *Rg, b: i64) -> bool {
    f := self.f
    c, ok, trap := match f.blocks[b].term {
        Br(c0, t0, e0) if t0 != e0 => (c0, t0, e0)
        _ => return false
    }
    idx, ln := match rg_check(f, c) {
        Some(x) => x
        None => return false
    }
    lim := 1 << 40
    x, k0 := self.rg_split(idx).or((idx, 0))
    if k0 < -lim || k0 > lim {
        return false
    }
    kmax := k0
    kmin := k0
    removed := vec[(i64, i64, i64, i64)]() // block, cond, ok, trap
    cur := ok
    steps := 0
    walk: loop {
        steps += 1
        if steps > 64 || self.cfg.preds[cur].len != 1 || cur == b {
            break
        }
        for v in f.blocks[cur].insts {
            o := f.insts[v].op
            if o == Call || o == CallInd || o == Syscall || o == Atomic || o == Phi {
                break walk
            }
        }
        match f.blocks[cur].term {
            Jmp(t) => cur = t
            Br(c2, t2, e2) => {
                if t2 == e2 || !opt_is_check_trap(f, e2) {
                    break
                }
                match rg_check(f, c2) {
                    Some((idx2, ln2)) if ln2 == ln => {
                        x2, k2 := self.rg_split(idx2).or((idx2, 0))
                        if x2 == x && k2 >= -lim && k2 <= lim {
                            kmax = max(kmax, k2)
                            kmin = min(kmin, k2)
                            removed.push((cur, c2, t2, e2))
                            f.blocks[cur].term = Jmp(t2)
                        }
                    }
                    _ => {}
                }
                cur = t2
            }
            _ => break
        }
    }
    if removed.is_empty() {
        return false
    }
    // the strongest check goes first; its index is made again here
    if kmax > k0 {
        kc := self.rg_push(b, Const, vec[i64](), kmax)
        ix := self.rg_push(b, Add, vec_of([]i64{x, kc}), 0)
        nc := self.rg_push(b, Ult, vec_of([]i64{ix, ln}), 0)
        f.blocks[b].term = Br(nc, ok, trap)
    }
    self.rg_forget()
    // in the changed function: x + kmin >= 0 at b (then no x + k wraps as an unsigned number,
    // and every one is at most x + kmax)
    self.budget = 6000
    self.ctx_y = ln
    self.cache.clear()
    lo_ok := self.rg_lo(x, b, self.depth) >= -kmin
    self.ctx_y = NOV
    if lo_ok {
        return true
    }
    // undo (the instructions made stay unused)
    f.blocks[b].term = Br(c, ok, trap)
    for r in removed {
        f.blocks[r.0].term = Br(r.1, r.2, r.3)
    }
    self.rg_forget()
    return false
}

priv fn rg_run(f: *Func) -> bool {
    any := false
    for b in 0..f.blocks.len {
        match f.blocks[b].term {
            Br(c, t, e) if t != e && is_trap_block(f, e) && is_some(rg_check(f, c)) => {
                any = true
                break
            }
            _ => {}
        }
    }
    if !any {
        return false
    }
    nb := f.blocks.len
    s := Rg{f: f, cfg: cfg_new(f), def_block: f.block_of(), nb: nb, is_len: vec_fill(f.insts.len, false), edges: vec[(i64, i64)](), facts: vec_fill(nb, vec[RgFact]()), fgen: vec_fill(nb, i64(-1)), gen: 0, budget: 0, asm: vec[(i64, i64, i64, i64)](), ctx_y: NOV, depth: 12, cache: map[(i64, i64, i64, i64), (i64, i64)]()}
    checks := vec[i64]()
    for b in s.cfg.rpo {
        match f.blocks[b].term {
            Br(c, t, e) if t != e && opt_is_check_trap(f, e) => {
                match rg_check(f, c) {
                    Some((_, ln)) => {
                        s.is_len[ln] = true
                        checks.push(b)
                    }
                    None => {}
                }
            }
            _ => {}
        }
    }
    if checks.is_empty() {
        return false
    }
    changed := false
    for b in checks {
        if s.rg_merge(b) {
            changed = true
        }
    }
    for b in checks {
        c, ok, trap := match f.blocks[b].term {
            Br(c0, t0, e0) if t0 != e0 => (c0, t0, e0)
            _ => continue
        }
        idx, ln := match rg_check(f, c) {
            Some(x) => x
            None => continue
        }
        // proven without the check itself
        f.blocks[b].term = Jmp(ok)
        s.rg_forget()
        if s.rg_proves(idx, ln, b) {
            changed = true
        } else {
            f.blocks[b].term = Br(c, ok, trap)
            s.rg_forget()
        }
    }
    return changed
}
