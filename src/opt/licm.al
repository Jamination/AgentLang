// Loop-invariant code motion (with preheader creation).

// predecessors of the header `h` of loop `li` that are outside the loop
fn licm_outside_preds(cfg: *Cfg, loops: *Loops, li: i64, h: i64) -> Vec[i64] {
    outside := vec[i64]()
    for p in cfg.preds[h] {
        if !loops.contains(li, p) {
            outside.push(p)
        }
    }
    return outside
}

// loop indices, deepest loops first (sort_by is stable)
fn licm_loop_order(loops: *Loops) -> Vec[i64] {
    order := vec[i64]()
    for li in 0..loops.loops.len {
        order.push(li)
    }
    sort_by(order.items(), loops, fn(loops: *Loops, a: i64, b: i64) -> bool { loops.loops[a].depth > loops.loops[b].depth })
    return order
}

// how many preheaders licm_make_preheaders has made so far in the thread (callers that do not
// report them as a change: unroll_run, bce_run; counted in f.w)
fn licm_preheaders_made(f: *Func) -> i64 {
    return f.w.preheaders
}

fn licm_make_preheaders(f: *Func) -> bool {
    cfg, loops := cfg_loops(f)
    changed := false
    for li in 0..loops.loops.len {
        h := loops.loops[li].header
        outside := licm_outside_preds(&cfg, &loops, li, h)
        if outside.is_empty() {
            continue
        }
        if outside.len == 1 && f.succs(outside[0]).len == 1 {
            continue
        }
        p := f.new_block()
        f.w.preheaders += 1
        f.blocks[p].term = Jmp(h)
        for o in outside {
            f.retarget(o, h, p)
        }
        // fix header phis: their inputs from outside come from p (through a phi in p if they
        // differ)
        hinsts := clone(f.blocks[h].insts)
        for v in hinsts {
            if f.insts[v].op != Phi {
                break
            }
            inst := &f.insts[v]
            ity := inst.ty
            ifrom := inst.from()
            vals := vec[i64]()
            pbs := vec[i64]()
            keep_args := vec[i64]()
            keep_pb := vec[i64]()
            for k in 0..inst.args.len {
                pb := ifrom[k]
                if contains(&outside, pb) {
                    vals.push(inst.args[k])
                    pbs.push(pb)
                } else {
                    keep_args.push(inst.args[k])
                    keep_pb.push(pb)
                }
            }
            all_same := true
            for x in vals {
                if x != vals[0] {
                    all_same = false
                    break
                }
            }
            incoming := vals[0]
            if !all_same {
                incoming = f.mk_phi_of(ity, vals.items(), pbs.items())
                f.blocks[p].insts.push(i32(incoming))
            }
            keep_args.push(incoming)
            keep_pb.push(p)
            f.im(i64(v)).phi_set(keep_args.items(), keep_pb.items())
        }
        changed = true
    }
    return changed
}

// b dominates every exit and every latch of the loop: it runs on every iteration that completes
priv fn guaranteed(cfg: *Cfg, exiting: []i64, latches: []i64, b: i64) -> bool {
    for e in exiting {
        if !cfg.dom(b, e) {
            return false
        }
    }
    for t in latches {
        if !cfg.dom(b, t) {
            return false
        }
    }
    return true
}

fn licm_run(f: *Func) -> bool {
    changed := licm_make_preheaders(f)
    cfg, loops := cfg_loops(f)
    if loops.loops.is_empty() {
        return changed
    }
    // (unchanged since this pass began unless preheaders were made)
    esc := alias_escaped_cached(f, if changed { -1 } else { opt_gen(f) })
    def_block := f.block_of()
    order := licm_loop_order(&loops)
    // one membership buffer for all loops (cleared after each): a fresh one per loop made
    // functions with many loops quadratic in memory
    in_loop := vec_fill(f.blocks.len, false)
    for li in order {
        l := &loops.loops[li]
        h := l.header
        outside := licm_outside_preds(&cfg, &loops, li, h)
        if outside.len != 1 {
            continue
        }
        nsucc, _, _ := f.succ_pair(outside[0])
        if nsucc != 1 {
            continue
        }
        pre := outside[0]
        loops.mark_blocks(li, in_loop.items(), true)
        // the blocks in reverse postorder (their positions in it are distinct)
        blocks := vec[i64]()
        for b in l.blocks {
            blocks.push(i64(cfg.rpo_idx[b]))
        }
        sort(blocks.items())
        for k in 0..blocks.len {
            blocks[k] = cfg.rpo[blocks[k]]
        }
        // memory effects and exits
        stores := vec[MemRef]()
        has_call := false
        exiting := vec[i64]()
        for b in blocks {
            for v in f.blocks[b].insts {
                o := f.insts[v].op
                if o == Store {
                    stores.push(alias_memref(f, i64(v)))
                } else if o.clobbers() {
                    has_call = true
                }
            }
            ns, s0, s1 := f.succ_pair(b)
            leaves := ns > 0 && !in_loop[s0] || ns > 1 && !in_loop[s1]
            for j in 0..if ns == 0 { f.nsucc(b) } else { 0 } {
                if !in_loop[f.succ_at(b, j)] {
                    leaves = true
                }
            }
            if !leaves {
                match f.blocks[b].term {
                    Ret(_), Trap => leaves = true
                    _ => {}
                }
            }
            if leaves {
                exiting.push(b)
            }
        }
        loop {
            moved := false
            for b in blocks {
                // the kept instructions are compacted in place (b is not pre)
                insts := &f.blocks[b].insts
                kept := 0
                for ii in 0..insts.len {
                    v := insts[ii]
                    i := &f.insts[v]
                    invariant_args := true
                    for a in i.args {
                        db := def_block[a]
                        if !(db == NOV || !in_loop[db]) {
                            invariant_args = false
                            break
                        }
                    }
                    ok := false
                    if invariant_args {
                        if i.op.is_pure() {
                            ok = true
                        } else if i.op == SDiv || i.op == UDiv || i.op == SRem || i.op == URem {
                            safe_const := match f.is_const(i.args[1]) {
                                Some(k) => k != 0 && !(k == -1 && (i.op == SDiv || i.op == SRem))
                                None => false
                            }
                            ok = safe_const || guaranteed(&cfg, exiting.items(), l.latches.items(), b)
                        } else if i.op == Load {
                            m := alias_memref(f, i64(v))
                            private, safe_addr := match m.addr.base {
                                Alloca(x) => (!esc[x], is_some(m.addr.off))
                                Global(_) => (false, is_some(m.addr.off))
                                Unknown(_) => (false, false)
                            }
                            if !has_call || private {
                                aliased := false
                                for si in 0..stores.len {
                                    if alias_may_alias(&stores[si], &m, esc.items()) {
                                        aliased = true
                                        break
                                    }
                                }
                                if !aliased && (safe_addr || guaranteed(&cfg, exiting.items(), l.latches.items(), b)) {
                                    ok = true
                                }
                            }
                        }
                    }
                    if ok {
                        f.blocks[pre].insts.push(v)
                        def_block[v] = i32(pre)
                        moved = true
                    } else {
                        insts[kept] = v
                        kept += 1
                    }
                }
                insts.len = kept
            }
            if !moved {
                break
            }
            changed = true
        }
        loops.mark_blocks(li, in_loop.items(), false)
    }
    if opt_enabled("promote") && licm_promote(f) {
        changed = true
    }
    return changed
}

// ---------- scalar promotion ----------
// A location that a loop loads and stores through one loop-invariant address (a global
// counter, `self.count += x`, `counts[k] += 1` with k fixed) is kept in a register instead:
// it is loaded once before the loop and stored back on every way out of it. Only for loops
// without calls (nothing else could read the location while the loop runs), without exits
// but normal ones (a failing check would stop the program with the location not yet
// written back: its failure path, or code inlined from the run-time library that a check
// reports through, might read it), where no other load or store of the loop may alias the
// location. The load before the loop must be safe: one of the accesses runs on every
// iteration (and the loop runs at least once), or the location is a global. When no store
// runs on every iteration a flag tells whether the loop stored at all, so that nothing is
// written where the loop wrote nothing (another thread may own the location then).
// The promotion goes through a new stack slot that the loop's accesses use instead, which
// mem2reg then turns into SSA values.

// promotes one location of loop li if one qualifies (in_loop marks its blocks, def_block:
// the block of every instruction); true if it did
priv fn promote_loop(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block: []i32, esc: []bool) -> bool {
    l := &loops.loops[li]
    h := l.header
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 {
        return false
    }
    pre := outside[0]
    nsucc, _, _ := f.succ_pair(pre)
    if nsucc != 1 {
        return false
    }
    mems := vec[i64]()
    exits := vec[(i64, i64)]()
    exiting := vec[i64]()
    for b in l.blocks {
        match f.blocks[b].term {
            Jmp(_), Br(_, _, _) => {}
            _ => return false
        }
        for v in f.blocks[b].insts {
            o := f.insts[v].op
            if o == Load || o == Store {
                mems.push(i64(v))
            } else if o.clobbers() {
                return false
            }
        }
        ns, s0, s1 := f.succ_pair(b)
        for k in 0..ns {
            s := if k == 0 { s0 } else { s1 }
            if !in_loop[s] {
                if is_trap_block(f, s) {
                    return false
                }
                exits.push((b, s))
                if !contains(&exiting, b) {
                    exiting.push(b)
                }
            }
        }
    }
    if exits.is_empty() {
        return false
    }
    done := vec[i64]()
    for st in mems {
        if f.insts[st].op != Store {
            continue
        }
        a := f.insts[st].args[0]
        db := def_block[a]
        if db != NOV && in_loop[db] || contains(&done, a) {
            continue
        }
        done.push(a)
        ty := f.insts[st].ty
        if ty.is_vec() {
            continue
        }
        ref := alias_memref(f, st)
        match ref.addr.base {
            // (a slot of the function's own that does not escape: mem2reg's)
            Alloca(x) => {
                if !esc[x] {
                    continue
                }
            }
            _ => {}
        }
        group := vec[i64]()
        ok := true
        safe := false
        store_always := false
        for m in mems {
            mi := &f.insts[m]
            if mi.args[0] == a {
                if mi.ty != ty {
                    ok = false
                    break
                }
                group.push(m)
                if guaranteed(cfg, exiting.items(), l.latches.items(), i64(def_block[m])) {
                    safe = true
                    if mi.op == Store {
                        store_always = true
                    }
                }
            } else {
                other := alias_memref(f, m)
                if alias_may_alias(&ref, &other, esc) {
                    ok = false
                    break
                }
            }
        }
        if !ok {
            continue
        }
        if !safe {
            match ref.addr.base {
                Global(_) => safe = is_some(ref.addr.off)
                _ => {}
            }
        }
        if !safe {
            continue
        }
        promote_apply(f, pre, a, ty, group.items(), exits.items(), store_always)
        return true
    }
    return false
}

// a new stack slot of `size` bytes, at the top of the entry block
priv fn promote_slot(f: *Func, size: i64) -> i64 {
    s := f.mk(Alloca, I64, vec[i64](), size)
    f.im(s).aux = i32(size)
    f.blocks[0].insts.insert(0, i32(s))
    return s
}

priv fn promote_apply(f: *Func, pre: i64, a: i64, ty: T, group: []i64, exits: [](i64, i64), store_always: bool) {
    class := f.insts[group[0]].aux
    tmp := promote_slot(f, ty.size())
    v0 := f.push(pre, Load, ty, vec_of([]i64{a}), 0)
    f.im(v0).aux = class
    f.push(pre, Store, ty, vec_of([]i64{tmp, v0}), 0)
    flag := NOV
    one := NOV
    if !store_always {
        flag = promote_slot(f, 1)
        zero := f.push(pre, Const, I8, vec[i64](), 0)
        one = f.push(pre, Const, I8, vec[i64](), 1)
        f.push(pre, Store, I8, vec_of([]i64{flag, zero}), 0)
    }
    for m in group {
        f.insts[m].args[0] = tmp
    }
    if flag != NOV {
        // every store also sets the flag
        for b in 0..f.blocks.len {
            insts := &f.blocks[b].insts
            k := 0
            while k < insts.len {
                v := i64(insts[k])
                if f.insts[v].op == Store && contains(group, v) {
                    s := f.mk(Store, I8, vec_of([]i64{flag, one}), 0)
                    insts.insert(k + 1, i32(s))
                    k += 1
                }
                k += 1
            }
        }
    }
    // the way out: store the value back (if the loop stored)
    for e in exits {
        b, s := e
        j := loop_split_edge(f, b, s)
        at := j
        if flag != NOV {
            nb := loop_split_edge(f, b, j)
            d := f.push(nb, Load, I8, vec_of([]i64{flag}), 0)
            c := f.push(nb, Ne, I8, vec_of([]i64{d, f.push(nb, Const, I8, vec[i64](), 0)}), 0)
            at = f.new_block()
            f.blocks[at].term = Jmp(j)
            f.blocks[nb].term = Br(c, at, j)
        }
        x := f.push(at, Load, ty, vec_of([]i64{tmp}), 0)
        st := f.push(at, Store, ty, vec_of([]i64{a, x}), 0)
        f.im(st).aux = class
    }
}

// Scalar promotion in every loop (see above), deepest loops first; true if a location was
// promoted (the new stack slots are then promoted by mem2reg).
fn licm_promote(f: *Func) -> bool {
    changed := false
    skip := vec[bool]()
    rounds: for it in 0..16 {
        cfg, loops := cfg_loops(f)
        if loops.loops.is_empty() {
            break
        }
        esc := alias_escaped_allocas(f)
        def_block := f.block_of()
        in_loop := vec_fill(f.blocks.len, false)
        skip.resize(f.blocks.len, false)
        for li in licm_loop_order(&loops) {
            h := loops.loops[li].header
            if skip[h] {
                continue
            }
            loops.mark_blocks(li, in_loop.items(), true)
            done := promote_loop(f, &cfg, &loops, li, in_loop.items(), def_block.items(), esc.items())
            loops.mark_blocks(li, in_loop.items(), false)
            if done {
                changed = true
                continue rounds
            }
            skip[h] = true
        }
        break
    }
    if changed {
        // (the IR changed under the pass: analyses remembered for the change count are stale)
        f.w.gen += 1
        mem2reg_run(f)
    }
    return changed
}
