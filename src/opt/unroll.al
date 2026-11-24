// Full unrolling of loops with a small constant trip count.

priv const MAX_TRIP = 16
priv const MAX_UNROLLED_SIZE = 640

priv struct Plan {
    blocks: Vec[i64],
    header: i64,
    latch: i64,
    pre: i64,
    exit: i64,
    // number of copies of the body
    trip: i64,
    // true: the loop disappears; false: the copies form a loop again (trip count is a multiple)
    full: bool,
}

priv const MAX_PARTIAL_SIZE = 400

// the leading phis of block `h`
priv fn header_phis(f: *Func, h: i64) -> Vec[i64] {
    hphis := vec[i64]()
    for v in f.blocks[h].insts {
        if f.insts[v].op != Phi {
            break
        }
        hphis.push(i64(v))
    }
    return hphis
}

// `in_loop`: the blocks of loop `li` are marked (by the caller, one buffer for all loops);
// `def_block_v`: the block of every instruction, computed when first needed and shared by the
// loops of one round (analysis changes nothing)
priv fn analyze(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block_v: *Vec[i32]) -> Opt[Plan] {
    l := &loops.loops[li]
    h := l.header
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 || f.succs(outside[0]).len != 1 || l.latches.len != 1 {
        return None
    }
    pre := outside[0]
    latch := l.latches[0]
    c, t, e := match f.blocks[latch].term {
        Br(c0, t0, e0) => (c0, t0, e0)
        _ => return None
    }
    back_true, exit_b := if t == h && !in_loop[e] {
        (true, e)
    } else if e == h && !in_loop[t] {
        (false, t)
    } else {
        return None
    }
    // counted loop with constant bounds
    ci := &f.insts[c]
    if !ci.op.is_icmp() {
        return None
    }
    next := ci.args[0]
    end := ci.args[1]
    endk := match f.is_const(end) {
        Some(k) => k
        None => return None
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
    if pi.op != Phi || pi.args.len != 2 || !contains(&f.blocks[h].insts, i32(phi)) {
        return None
    }
    s0 := pi.phi_input(pre)
    if s0 == NOV {
        return None
    }
    start := match f.is_const(s0) {
        Some(k) => k
        None => return None
    }
    back := pi.phi_input(latch)
    if back != next || step == 0 {
        return None
    }
    ty := pi.ty
    trip := 0
    i := start
    loop {
        trip += 1
        if trip > 1 << 16 {
            return None
        }
        nx := ir_canon(ty, i + step)
        cont := match simplify_fold_icmp(ci.op, ty, nx, endk) {
            Some(r) => r == back_true
            None => return None
        }
        if !cont {
            break
        }
        i = nx
    }
    // longest chain of header phis that only shift values along (h = g; g = f; ...)
    hphis := header_phis(f, h)
    chain := 1
    for ph in hphis {
        ln := 1
        cur := ph
        loop {
            b := f.insts[cur].phi_input(latch)
            if b == NOV || b == ph || !contains(&hphis, b) || ln > 16 {
                break
            }
            ln += 1
            cur = b
        }
        chain = max(chain, ln)
    }
    // size and exits
    if def_block_v.len == 0 {
        *def_block_v = f.block_of()
    }
    def_block := def_block_v.items()
    size := 0
    for b in l.blocks {
        size += f.blocks[b].insts.len + 1
        match f.blocks[b].term {
            Ret(_), Term.None, Trap => return None
            _ => {}
        }
        ss := f.succs(b)
        for s in ss {
            if in_loop[s] || (b == latch && s == exit_b) {
                continue
            }
            // side exits must be traps that do not look at loop values
            sb := &f.blocks[s]
            if sb.term != Trap {
                return None
            }
            for v in sb.insts {
                inst := &f.insts[v]
                if inst.op == Phi {
                    return None
                }
                for a in inst.args {
                    if def_block[a] != NOV && in_loop[def_block[a]] {
                        return None
                    }
                }
            }
        }
    }
    if trip <= MAX_TRIP && size * trip <= MAX_UNROLLED_SIZE {
        return Some(Plan{blocks: clone(l.blocks), header: h, latch: latch, pre: pre, exit: exit_b, trip: trip, full: true})
    }
    // partial: unrolling by the shift-chain length turns the per-iteration register shuffle into
    // plain renaming
    if opt_enabled("partial") && chain >= 2 && chain <= 8 && trip % chain == 0 && trip > chain && size * chain <= MAX_PARTIAL_SIZE {
        return Some(Plan{blocks: clone(l.blocks), header: h, latch: latch, pre: pre, exit: exit_b, trip: chain, full: false})
    }
    return None
}

// the (start, back-edge) inputs of header phi ph
priv fn phi_in_at(phi_in: *Map[i64, (i64, i64)], ph: i64) -> (i64, i64) {
    x, found := phi_in.get(ph)
    assert found, "unroll: phi not in map"
    return x
}

// the copy of block b
priv fn bmap_at(bmap: *Map[i64, i64], b: i64) -> i64 {
    nb, found := bmap.get(b)
    assert found, "unroll: block not in map"
    return nb
}

// `def_block_v`: as in analyze (still exact: analysis changed nothing)
priv fn apply(f: *Func, p: *Plan, def_block_v: *Vec[i32]) {
    n0 := f.insts.len
    nb0 := f.blocks.len
    in_loop_v := vec_fill(nb0, false)
    for b in p.blocks {
        in_loop_v[b] = true
    }
    in_loop := in_loop_v.items()
    if def_block_v.len == 0 {
        *def_block_v = f.block_of()
    }
    def_block := def_block_v.items()
    // is v an original value (below n0) defined inside the loop?
    fn loop_def(v: i64, n0: i64, def_block: []i32, in_loop: []bool) -> bool {
        v < n0 && def_block[v] != NOV && in_loop[def_block[v]]
    }
    // the copy of v in the iteration that `m` describes
    fn look(m: *Vec[i64], v: i64, n0: i64, def_block: []i32, in_loop: []bool) -> i64 {
        if loop_def(v, n0, def_block, in_loop) {
            return m[v]
        }
        return v
    }
    hphis := header_phis(f, p.header)
    // (start value, back-edge value) of each header phi
    phi_in := map[i64, (i64, i64)]()
    for ph in hphis {
        i := &f.insts[ph]
        phi_in.set(ph, (i.phi_input(p.pre), i.phi_input(p.latch)))
    }
    // copy 0 is the original body; prev maps original values to their copy in the previous
    // iteration. Only values defined in the loop are ever looked up, so the two maps are
    // reused for every copy and only their loop entries are reset (fresh function-sized maps
    // per copy made unrolling many loops quadratic in memory)
    loop_vals := vec[i64]()
    for b in p.blocks {
        for v in f.blocks[b].insts {
            if i64(v) < n0 {
                loop_vals.push(i64(v))
            }
        }
    }
    prev := vec_fill(n0, NOV)
    for v in loop_vals {
        prev[v] = v
    }
    spare := vec_fill(n0, NOV)
    prev_latch := p.latch
    orig_latch_term := clone(f.blocks[p.latch].term)
    prev_header_of_last := p.header
    for kk in 1..p.trip {
        bmap := map[i64, i64]()
        for b in p.blocks {
            bmap.set(b, f.new_block())
        }
        cur := spare
        for v in loop_vals {
            cur[v] = NOV
        }
        for ph in hphis {
            bk := phi_in_at(&phi_in, ph).1
            cur[ph] = look(&prev, bk, n0, def_block, in_loop)
        }
        // allocate ids
        for b in p.blocks {
            for ii in 0..f.blocks[b].insts.len {
                v := i64(f.blocks[b].insts[ii])
                if v >= n0 || cur[v] != NOV {
                    continue
                }
                if b == p.header && f.insts[v].op == Phi {
                    continue
                }
                // (a copy: mk may move the instructions)
                src := f.insts[v]
                nv := f.mk(src.op, src.ty, vec[i64](), src.k)
                f.im(nv).aux = src.aux
                f.im(nv).set_srcloc(src.srcloc())
                if f.dexp.len > 0 && src.srcloc() > 0 {
                    // (-g: code of this location now runs in another iteration's copy too)
                    f.dtaint.push(src.srcloc())
                }
                cur[v] = nv
            }
        }
        for b in p.blocks {
            nb := bmap_at(&bmap, b)
            insts := clone(f.blocks[b].insts)
            for v in insts {
                if i64(v) >= n0 {
                    continue
                }
                if b == p.header && f.insts[v].op == Phi {
                    continue
                }
                nv := cur[v]
                nargs := f.insts[v].args.len
                args := mkslice[i64](__alloc_raw(nargs * 8), nargs)
                for ai in 0..nargs {
                    args[ai] = look(&cur, f.insts[v].args[ai], n0, def_block, in_loop)
                }
                if f.insts[v].op == Phi {
                    pb := mkslice[i64](__alloc_raw(nargs * 8), nargs)
                    vfrom := f.insts[v].from()
                    for ai in 0..nargs {
                        pb[ai] = bmap.get_or(vfrom[ai], vfrom[ai])
                    }
                    f.im(nv).phi_set(args, pb)
                } else {
                    f.im(nv).args = args
                }
                f.blocks[nb].insts.push(i32(nv))
            }
            src_term := if b == p.latch { clone(orig_latch_term) } else { clone(f.blocks[b].term) }
            f.blocks[nb].term = match src_term {
                Jmp(t) => Jmp(bmap.get_or(t, t))
                Br(c, t, e) => Br(look(&cur, c, n0, def_block, in_loop), bmap.get_or(t, t), bmap.get_or(e, e))
                Switch(c, tab) => {
                    for j in 1..1 + tab[0] {
                        tab[j] = bmap.get_or(tab[j], tab[j])
                    }
                    Switch(look(&cur, c, n0, def_block, in_loop), tab)
                }
                _ => src_term
            }
        }
        // the previous copy's latch falls into this copy
        f.blocks[prev_latch].term = Jmp(bmap_at(&bmap, p.header))
        prev_latch = bmap_at(&bmap, p.latch)
        prev_header_of_last = bmap_at(&bmap, p.header)
        spare = prev
        prev = cur
    }
    if p.full {
        // the last copy leaves the loop
        f.blocks[prev_latch].term = Jmp(p.exit)
    } else if p.trip > 1 {
        // the last copy branches back to the first one
        match f.blocks[prev_latch].term {
            Br(_, &t, &e) => {
                if *t != p.exit {
                    *t = p.header
                }
                if *e != p.exit {
                    *e = p.header
                }
            }
            _ => {}
        }
    }
    // exit phis and uses after the loop see the last copy
    if p.trip > 1 {
        last_m := &prev
        for b in 0..nb0 {
            if in_loop[b] {
                continue
            }
            if b == p.exit {
                f.phi_pred_replace(b, p.latch, prev_latch)
            }
            for ii in 0..f.blocks[b].insts.len {
                v := f.blocks[b].insts[ii]
                for ai in 0..f.insts[v].args.len {
                    a := f.insts[v].args[ai]
                    if loop_def(a, n0, def_block, in_loop) {
                        f.insts[v].args[ai] = last_m[a]
                    }
                }
            }
            match f.blocks[b].term {
                Br(&c, _, _) => {
                    if loop_def(*c, n0, def_block, in_loop) {
                        *c = last_m[*c]
                    }
                }
                Switch(&c, _) => {
                    if loop_def(*c, n0, def_block, in_loop) {
                        *c = last_m[*c]
                    }
                }
                Ret(vs) => {
                    nvs := clone(vs)
                    for k in 0..nvs.len {
                        if loop_def(nvs[k], n0, def_block, in_loop) {
                            nvs[k] = last_m[nvs[k]]
                        }
                    }
                    f.blocks[b].term = Ret(nvs)
                }
                _ => {}
            }
        }
    }
    if !p.full {
        // header phis stay: their back-edge inputs now come from the last copy
        if p.trip > 1 {
            for ph in hphis {
                bk := phi_in_at(&phi_in, ph).1
                nv := if loop_def(bk, n0, def_block, in_loop) { prev[bk] } else { bk }
                i := f.im(ph)
                ifrom := i.from()
                for k in 0..ifrom.len {
                    if ifrom[k] == p.latch {
                        ifrom[k] = prev_latch
                        i.args[k] = nv
                    }
                }
            }
        }
        return
    }
    // copy 0: header phis take their initial values
    repl := vec_fill(f.insts.len, i32(NOV))
    for ph in hphis {
        repl[ph] = i32(phi_in_at(&phi_in, ph).0)
    }
    // (hphis are still the leading phis of the header: nothing above changed its list)
    f.blocks[p.header].insts = vec_of(f.blocks[p.header].insts[hphis.len..])
    // (-g: the phis are equal to those values in the first copy only)
    dbg_forget(f, &repl)
    f.apply_repl(&repl)
}

// ---------- runtime unrolling ----------
// An innermost counted loop (loop_counted, counting by 1 to a bound known on entry) with a
// small body and no calls is unrolled u times when its trip count is not known at compile
// time:
//
//     pre:  tc = end - start; ok = (start < end) & (tc >=u u)
//           br ok header rpre
//     header..latch: u copies of the body, one after the other (the counter of copy k is
//           iv + k), then `br iv + u != start + (tc & -u) header mid`
//     mid:  the partial results of the reductions combine; br (tc & (u-1)) != 0 rpre x
//     rpre: phis: the values the remainder starts from (from pre: the loop's start values)
//     the remainder: a copy of the original loop, with its own preheader rpre; it leaves to x
//     x:    phis of the values used after the loop (from the remainder or from mid); jmp exit
//
// Reductions (loop_reduction: wrapping integer +, *, &, |, ^, min, max) keep one partial result
// per copy, so that the copies do not wait for each other; mid combines them. Side exits to
// check failure blocks stay in every copy in their order (loop_exits_simple). Both loops are
// marked (LOOP_NO_UNROLL) so that later runs of the pipeline leave them alone. Runs after
// bounds-check hoisting, which needs the original loop shape and leaves the checks out of the
// loop.
priv const RT_MAX_SIZE = 40 // instructions and terminators of the loop
priv const RT_TARGET = 64   // roughly the size of the unrolled body

// the number of copies for a loop body of `size` (1: do not unroll). (8 copies of a tiny body
// measured slower than 4 where the loop shares the registers with much else: bytesum, whose
// 8 partial sums spilled.)
priv fn rt_factor(size: i64) -> i64 {
    if size > RT_MAX_SIZE {
        return 1
    }
    if size * 4 <= RT_TARGET {
        return 4
    }
    return 2
}

// the position of phi ph among the reductions (-1: none)
priv fn red_index(reds: *Vec[Reduction], ph: i64) -> i64 {
    for k in 0..reds.len {
        if reds[k].phi == ph {
            return k
        }
    }
    return -1
}

// unrolls loop li if it qualifies; true if it did
priv fn rt_try(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block: []i32) -> bool {
    cl := match loop_counted(f, cfg, loops, li, in_loop, def_block) {
        Some(c) => c
        None => return false
    }
    if f.insts[cl.cond].aux & LOOP_NO_UNROLL != 0 || !loop_trip_known(&cl) {
        return false
    }
    if loop_has_call(f, &cl) || !loop_exits_simple(f, &cl, in_loop, def_block) {
        return false
    }
    size := loop_size(f, &cl)
    if size > RT_MAX_SIZE {
        return false
    }
    outside := loop_used_outside(f, in_loop, def_block)
    reds := vec[Reduction]()
    for ph in header_phis(f, cl.header) {
        match loop_reduction(f, &cl, ph, in_loop, def_block, outside.items()) {
            Some(r) => reds.push(r)
            None => {}
        }
    }
    u := rt_factor(size)
    // at most 8 partial results in all (a loop unrolled by hand into 4 sums already has
    // its own: 16 would spill)
    while u > 1 && u * reds.len > 8 {
        u /= 2
    }
    if u < 2 {
        return false
    }
    match loop_const_trip(f, &cl) {
        Some(t) => {
            while u > 2 && t < 2 * u {
                u /= 2
            }
            if t < 2 * u {
                return false
            }
        }
        None => {}
    }
    rt_apply(f, &cl, u, &reds, &outside, in_loop, def_block)
    return true
}

// the main loop of the frame (loop_remainder_begin) as u copies of the body
priv fn rt_apply(f: *Func, cl: *CLoop, u: i64, reds: *Vec[Reduction], outside: *Vec[i64], in_loop: []bool, def_block: []i32) {
    h := cl.header
    lt := cl.latch
    rem := loop_remainder_begin(f, cl, u)
    hphis := &rem.hphis
    // the partial results of the reductions: accs[r * u + k] for copy k (k = 0: the phi),
    // starting from inits[r * u + k]
    accs := vec[i64]()
    inits := vec[i64]()
    for r in 0..reds.len {
        rp := reds[r].phi
        st := rem.starts[index_of(hphis.items(), rp)]
        accs.push(rp)
        inits.push(st)
        for k in 1..u {
            accs.push(f.mk_phi(f.insts[rp].ty, 2))
            inits.push(loop_red_init(f, cl.pre, &reds[r], st))
        }
    }
    // copies 1..u-1, each after the previous one
    maps := vec[IMap]()
    maps.push(imap_new(1))
    prev_latch := lt
    for k in 1..u {
        vm := imap_new(2 * loop_size(f, cl))
        for pi in 0..hphis.len {
            ph := hphis[pi]
            ri := red_index(reds, ph)
            if ri >= 0 {
                vm.iset(ph, accs[ri * u + k])
            } else {
                vm.iset(ph, loop_map_val(&maps[k - 1], rem.backs[pi]))
            }
        }
        bm := loop_clone_blocks(f, cl.blocks.items(), &vm)
        f.blocks[prev_latch].term = Jmp(bm.iget(h))
        prev_latch = bm.iget(lt)
        maps.push(vm)
    }
    ll := prev_latch
    lastm := &maps[u - 1]
    // the last copy goes back to the header until the counter reaches ue
    c2 := f.push(ll, Ne, I8, vec_of([]i64{loop_map_val(lastm, cl.next), rem.ue}), 0)
    f.im(c2).aux = LOOP_NO_UNROLL
    f.blocks[ll].term = Br(c2, h, rem.mid)
    // the header phis: the back edge comes from the last copy
    for pi in 0..hphis.len {
        ph := hphis[pi]
        ri := red_index(reds, ph)
        nb := if ri >= 0 { rem.backs[pi] } else { loop_map_val(lastm, rem.backs[pi]) }
        i := f.im(ph)
        ifrom := i.from()
        for k in 0..ifrom.len {
            if ifrom[k] == lt {
                ifrom[k] = ll
                i.args[k] = nb
            }
        }
    }
    newphis := vec[i32]()
    for r in 0..reds.len {
        for k in 1..u {
            a := accs[r * u + k]
            f.im(a).phi_set([]i64{inits[r * u + k], loop_map_val(&maps[k], reds[r].back)}, []i64{rem.chk, ll})
            newphis.push(i32(a))
        }
    }
    if newphis.len > 0 {
        newphis.extend(f.blocks[h].insts.items())
        f.blocks[h].insts = newphis
    }
    // the values after the main loop: the last copy's, or for a reduction the partial results
    // combined (pairwise) in mid
    fin := imap_new(outside.len + hphis.len)
    for pi in 0..hphis.len {
        fin.iset(rem.backs[pi], loop_map_val(lastm, rem.backs[pi]))
    }
    for v in outside {
        fin.iset(v, loop_map_val(lastm, v))
    }
    for r in 0..reds.len {
        vals := vec[i64]()
        for k in 0..u {
            vals.push(loop_map_val(&maps[k], reds[r].back))
        }
        while vals.len > 1 {
            nv := vec[i64]()
            for k in 0..vals.len / 2 {
                nv.push(loop_red_combine(f, rem.mid, &reds[r], vals[2 * k], vals[2 * k + 1]))
            }
            if vals.len % 2 == 1 {
                nv.push(vals[vals.len - 1])
            }
            vals = nv
        }
        fin.iset(reds[r].back, vals[0])
    }
    loop_remainder_end(f, cl, &rem, &fin, outside.items(), in_loop, def_block)
}

// Runtime unrolling of every qualifying loop (see above); true if a loop was unrolled.
fn unroll_runtime(f: *Func) -> bool {
    if f.size() > 20000 {
        return false
    }
    return loop_each_innermost(f, rt_try)
}

fn unroll_run(f: *Func) -> bool {
    changed := false
    rounds: for it in 0..64 {
        if f.size() > 8000 {
            break
        }
        licm_make_preheaders(f)
        cfg, loops := cfg_loops(f)
        order := licm_loop_order(&loops)
        in_loop := vec_fill(f.blocks.len, false)
        def_block := vec[i32]()
        for li in order {
            loops.mark_blocks(li, in_loop.items(), true)
            found := analyze(f, &cfg, &loops, li, in_loop.items(), &def_block)
            loops.mark_blocks(li, in_loop.items(), false)
            match found {
                Some(p) => {
                    apply(f, &p, &def_block)
                    cleanup_prune_unreachable(f)
                    changed = true
                    continue rounds
                }
                None => {}
            }
        }
        break
    }
    return changed
}
