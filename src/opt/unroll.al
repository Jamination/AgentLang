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

// the closure `back_of` of analyze: the back-edge input of a header phi, or NOV
priv fn analyze_back_of(f: *Func, ph: i64, latch: i64) -> i64 {
    i := &f.insts[ph]
    n := min(i.pb.len, i.args.len)
    for k in 0..n {
        if i.pb[k] == latch {
            return i.args[k]
        }
    }
    return NOV
}

// the leading phis of block `h`
priv fn header_phis(f: *Func, h: i64) -> Vec[i64] {
    hphis := vec[i64]()
    for v in f.blocks[h].insts.items() {
        if f.insts[v].op != Phi {
            break
        }
        hphis.push(v)
    }
    return hphis
}

priv fn analyze(f: *Func, cfg: *Cfg, loops: *Loops, li: i64) -> Opt[Plan] {
    l := &loops.loops[li]
    h := l.header
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 || f.succs(outside[0]).len != 1 || l.latches.len != 1 {
        return None
    }
    pre := outside[0]
    latch := l.latches[0]
    in_loop := vec_fill(f.blocks.len, false)
    for b in l.blocks.items() {
        in_loop[b] = true
    }
    c, t, e := match f.blocks[latch].term {
        Br(c0, t0, e0) => (c0, t0, e0)
        _ => return None
    }
    back_true := false
    exit_b := 0
    if t == h && !in_loop[e] {
        back_true = true
        exit_b = e
    } else if e == h && !in_loop[t] {
        back_true = false
        exit_b = t
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
    if pi.op != Phi || pi.args.len != 2 || !contains(&f.blocks[h].insts, phi) {
        return None
    }
    start_opt: Opt[i64] = None
    back := NOV
    for k in 0..pi.pb.len {
        pb := pi.pb[k]
        if pb == pre {
            start_opt = f.is_const(pi.args[k])
        } else if pb == latch {
            back = pi.args[k]
        }
    }
    start := match start_opt {
        Some(k) => k
        None => return None
    }
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
    for ph in hphis.items() {
        ln := 1
        cur := ph
        loop {
            b := analyze_back_of(f, cur, latch)
            if b == NOV || b == ph || !contains(&hphis, b) || ln > 16 {
                break
            }
            ln += 1
            cur = b
        }
        chain = max(chain, ln)
    }
    // size and exits
    def_block := f.block_of()
    size := 0
    for b in l.blocks.items() {
        size += f.blocks[b].insts.len + 1
        match f.blocks[b].term {
            Ret(_), Term.None, Trap => return None
            _ => {}
        }
        ss := f.succs(b)
        for s in ss.items() {
            if in_loop[s] || (b == latch && s == exit_b) {
                continue
            }
            // side exits must be traps that do not look at loop values
            sb := &f.blocks[s]
            if !eq(sb.term, Trap) {
                return None
            }
            for v in sb.insts.items() {
                inst := &f.insts[v]
                if inst.op == Phi {
                    return None
                }
                for a in inst.args.items() {
                    if def_block[a] != 0xFFFFFFFF && in_loop[def_block[a]] {
                        return None
                    }
                }
            }
        }
    }
    if trip <= MAX_TRIP && size * trip <= MAX_UNROLLED_SIZE {
        return Some(Plan{blocks: clone(&l.blocks), header: h, latch: latch, pre: pre, exit: exit_b, trip: trip, full: true})
    }
    // partial: unrolling by the shift-chain length turns the per-iteration register shuffle into
    // plain renaming
    if opt_enabled("partial") && chain >= 2 && chain <= 8 && trip % chain == 0 && trip > chain && size * chain <= MAX_PARTIAL_SIZE {
        return Some(Plan{blocks: clone(&l.blocks), header: h, latch: latch, pre: pre, exit: exit_b, trip: chain, full: false})
    }
    return None
}

// phi_in[&ph]
priv fn phi_in_at(phi_in: *Map[i64, (i64, i64)], ph: i64) -> (i64, i64) {
    x, found := phi_in.get(ph)
    assert found, "unroll: phi not in map"
    return x
}

// bmap[&b]
priv fn bmap_at(bmap: *Map[i64, i64], b: i64) -> i64 {
    nb, found := bmap.get(b)
    assert found, "unroll: block not in map"
    return nb
}

priv fn apply(f: *Func, p: *Plan) {
    n0 := f.insts.len
    nb0 := f.blocks.len
    in_loop_v := vec_fill(nb0, false)
    for b in p.blocks.items() {
        in_loop_v[b] = true
    }
    in_loop := in_loop_v.items()
    def_block_v := f.block_of()
    def_block := def_block_v.items()
    // is v an original value (below n0) defined inside the loop?
    fn loop_def(v: i64, n0: i64, def_block: []i64, in_loop: []bool) -> bool {
        v < n0 && def_block[v] != 0xFFFFFFFF && in_loop[def_block[v]]
    }
    // the copy of v in the iteration that `m` describes
    fn look(m: *Vec[i64], v: i64, n0: i64, def_block: []i64, in_loop: []bool) -> i64 {
        if loop_def(v, n0, def_block, in_loop) {
            return m[v]
        }
        return v
    }
    hphis := header_phis(f, p.header)
    // (start value, back-edge value) of each header phi
    phi_in := map[i64, (i64, i64)]()
    for ph in hphis.items() {
        i := &f.insts[ph]
        s := NOV
        bk := NOV
        for k in 0..i.pb.len {
            pb := i.pb[k]
            if pb == p.pre {
                s = i.args[k]
            } else if pb == p.latch {
                bk = i.args[k]
            }
        }
        phi_in.set(ph, (s, bk))
    }
    // copy 0 is the original body; prev maps original values to their copy in the previous iteration
    prev := vec[i64]()
    for v in 0..n0 {
        prev.push(v)
    }
    prev_latch := p.latch
    orig_latch_term := clone(f.blocks[p.latch].term)
    prev_header_of_last := p.header
    for kk in 1..p.trip {
        bmap := map[i64, i64]()
        for b in p.blocks.items() {
            bmap.set(b, f.new_block())
        }
        cur := vec_fill(n0, NOV)
        for ph in hphis.items() {
            bk := phi_in_at(&phi_in, ph).1
            cur[ph] = look(&prev, bk, n0, def_block, in_loop)
        }
        // allocate ids
        for b in p.blocks.items() {
            for ii in 0..f.blocks[b].insts.len {
                v := f.blocks[b].insts[ii]
                if v >= n0 || cur[v] != NOV {
                    continue
                }
                if b == p.header && f.insts[v].op == Phi {
                    continue
                }
                op := f.insts[v].op
                ty := f.insts[v].ty
                k := f.insts[v].k
                aux := f.insts[v].aux
                nv := f.mk(op, ty, vec[i64](), k)
                f.im(nv).aux = aux
                cur[v] = nv
            }
        }
        for b in p.blocks.items() {
            nb := bmap_at(&bmap, b)
            insts := clone(&f.blocks[b].insts)
            for v in insts.items() {
                if v >= n0 {
                    continue
                }
                if b == p.header && f.insts[v].op == Phi {
                    continue
                }
                nv := cur[v]
                args := vec[i64]()
                for a in f.insts[v].args.items() {
                    args.push(look(&cur, a, n0, def_block, in_loop))
                }
                pb := vec[i64]()
                for x in f.insts[v].pb.items() {
                    pb.push(bmap.get_or(x, x))
                }
                f.im(nv).args = args
                f.im(nv).pb = pb
                f.blocks[nb].insts.push(nv)
            }
            src_term := if b == p.latch { clone(orig_latch_term) } else { clone(f.blocks[b].term) }
            f.blocks[nb].term = match src_term {
                Jmp(t) => Jmp(bmap.get_or(t, t))
                Br(c, t, e) => Br(look(&cur, c, n0, def_block, in_loop), bmap.get_or(t, t), bmap.get_or(e, e))
                _ => src_term
            }
        }
        // the previous copy's latch falls into this copy
        f.blocks[prev_latch].term = Jmp(bmap_at(&bmap, p.header))
        prev_latch = bmap_at(&bmap, p.latch)
        prev_header_of_last = bmap_at(&bmap, p.header)
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
            for ii in 0..f.blocks[b].insts.len {
                v := f.blocks[b].insts[ii]
                for ai in 0..f.insts[v].args.len {
                    a := f.insts[v].args[ai]
                    if loop_def(a, n0, def_block, in_loop) {
                        f.insts[v].args[ai] = last_m[a]
                    }
                }
                if f.insts[v].op == Phi && b == p.exit {
                    pbs := &f.insts[v].pb
                    for k in 0..pbs.len {
                        if pbs[k] == p.latch {
                            pbs[k] = prev_latch
                        }
                    }
                }
            }
            match f.blocks[b].term {
                Br(&c, _, _) => {
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
            for ph in hphis.items() {
                bk := phi_in_at(&phi_in, ph).1
                nv := if loop_def(bk, n0, def_block, in_loop) { prev[bk] } else { bk }
                i := f.im(ph)
                for k in 0..i.pb.len {
                    if i.pb[k] == p.latch {
                        i.pb[k] = prev_latch
                        i.args[k] = nv
                    }
                }
            }
        }
        return
    }
    // copy 0: header phis take their initial values
    repl := vec_fill(f.insts.len, NOV)
    for ph in hphis.items() {
        repl[ph] = phi_in_at(&phi_in, ph).0
    }
    hb := &f.blocks[p.header]
    n := 0
    for ii in 0..hb.insts.len {
        v := hb.insts[ii]
        if !contains(&hphis, v) {
            hb.insts[n] = v
            n += 1
        }
    }
    hb.insts.len = n
    f.apply_repl(&repl)
}

fn unroll_run(f: *Func) -> bool {
    changed := false
    for it in 0..64 {
        if f.size() > 8000 {
            break
        }
        licm_make_preheaders(f)
        cfg := cfg_new(f)
        loops := loops_new(f, &cfg)
        order := licm_loop_order(&loops)
        plan: Opt[Plan] = None
        for li in order.items() {
            match analyze(f, &cfg, &loops, li) {
                Some(p) => {
                    plan = Some(p)
                    break
                }
                None => {}
            }
        }
        match plan {
            Some(p) => {
                apply(f, &p)
                cleanup_prune_unreachable(f)
                changed = true
            }
            None => break
        }
    }
    return changed
}
