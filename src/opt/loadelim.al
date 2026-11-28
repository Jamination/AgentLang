// Redundant load elimination, store-to-load forwarding and local dead store elimination.

priv struct Avail {
    m: MemRef,
    ty: T,
    val: i32,
    pending_store: i32, // a store not yet observed by any possible reader (NOV: none)
}

priv const MAX_AVAIL = 256

priv fn push_avail(st: *Vec[Avail], a: Avail) {
    if st.len >= MAX_AVAIL {
        // Drop the oldest half to bound straight-line alias scans to O(MAX_AVAIL)
        drop := MAX_AVAIL / 2
        keep := st.len - drop
        for k in 0..keep {
            st[k] = st[k + drop]
        }
        st.len = keep
    }
    st.push(a)
}

// The state at the start of a join: the entries of its first predecessor that every other
// predecessor has too, for exactly that location, type and value (that value then is in the
// location on every way in, and its definition dominates every predecessor, so the join too).
// No store is pending. Small states only (the intersection is quadratic).
priv fn join_state(out_state: *Vec[Opt[Vec[Avail]]], ps: []i64) -> Vec[Avail] {
    st := vec[Avail]()
    first := match out_state[ps[0]] {
        Some(s) => s
        None => return st
    }
    total := 0
    for p in ps {
        match out_state[p] {
            Some(s) => total += s.len
            None => return st
        }
    }
    if first.len * total > 20000 {
        return st
    }
    for e in first {
        all := true
        for k in 1..len(ps) {
            s := out_state[ps[k]].or(vec[Avail]())
            found := false
            for e2 in s {
                if e2.ty == e.ty && e2.val == e.val && alias_must_alias(&e2.m, &e.m) {
                    found = true
                    break
                }
            }
            if !found {
                all = false
                break
            }
        }
        if all {
            st.push(Avail{m: e.m, ty: e.ty, val: e.val, pending_store: NOV})
        }
    }
    return st
}

// The state at the start of the header of loop li: the entries of the state `pre` of its one
// predecessor outside the loop that no store, call or block copy of the loop may change (the
// location then keeps that value on every way into the header). No store is pending.
priv fn loop_state(f: *Func, loops: *Loops, li: i64, pre: *Opt[Vec[Avail]], esc: []bool) -> Vec[Avail] {
    st := vec[Avail]()
    s := match *pre {
        Some(x) => x
        None => return st
    }
    if s.is_empty() {
        return st
    }
    stores := vec[MemRef]()
    calls := false
    for b in loops.loops[li].blocks {
        for v in f.blocks[b].insts {
            match f.insts[v].op {
                Store => stores.push(alias_memref(f, i64(v)))
                MemCpy, MemSet => return st
                Call, CallInd, Syscall, Atomic => calls = true
                _ => {}
            }
        }
    }
    if stores.len * s.len > 20000 {
        return st
    }
    for e in s {
        if calls {
            // only non-escaped stack slots survive a call (as in loadelim_run)
            match e.m.addr.base {
                Alloca(x) if !esc[x] => {}
                _ => continue
            }
        }
        keep := true
        for m in stores {
            if alias_may_alias(&e.m, &m, esc) {
                keep = false
                break
            }
        }
        if keep {
            st.push(Avail{m: e.m, ty: e.ty, val: e.val, pending_store: NOV})
        }
    }
    return st
}

fn loadelim_run(f: *Func) -> bool {
    cfg, loops := cfg_loops(f)
    esc := alias_escaped_cached(f, opt_gen(f))
    repl := vec_fill(f.insts.len, i32(NOV))
    dead := alloc[bool](f.insts.len)
    changed := false
    // state at the end of each block, reused by a child that has that block as its only
    // predecessor; `left[p]`: such children of p not yet visited (the last one takes the state
    // instead of a copy)
    nb := f.blocks.len
    left := alloc[i64](nb)
    // a join (several predecessors, all before it in reverse postorder: no back edge) starts
    // with what every predecessor has, see join_state; its predecessors keep their state for it
    join := alloc[bool](nb)
    // a loop header with one way in from outside starts with what that predecessor has and
    // nothing in the loop can change (see loop_state): head_pred[h], or -1
    head_pred := vec_fill(nb, -1)
    for li in 0..loops.loops.len {
        h := loops.loops[li].header
        p := -1
        n := 0
        for q in cfg.preds[h] {
            if !loops.contains(li, q) {
                p = q
                n += 1
            }
        }
        if n == 1 && cfg.rpo_idx[p] < cfg.rpo_idx[h] {
            head_pred[h] = p
            left[p] += 1
        }
    }
    for b in cfg.rpo {
        np := cfg.preds[b].len
        if np == 1 {
            left[cfg.preds[b][0]] += 1
        } else if head_pred[b] >= 0 {
            // (counted above)
        } else if np > 1 && np <= 8 {
            fwd := true
            for p in cfg.preds[b] {
                if cfg.rpo_idx[p] >= cfg.rpo_idx[b] {
                    fwd = false
                }
            }
            if fwd {
                join[b] = true
                for p in cfg.preds[b] {
                    left[p] += 1
                }
            }
        }
    }
    // the latch of a loop with one keeps its state for carry_run
    carry := opt_enabled("ldcarry")
    keep := alloc[bool](nb)
    if carry {
        for li in 0..loops.loops.len {
            if loops.loops[li].latches.len == 1 {
                keep[loops.loops[li].latches[0]] = true
            }
        }
    }
    no_state: Opt[Vec[Avail]] = None
    out_state := vec_fill(nb, no_state)
    for b in cfg.rpo {
        st := vec[Avail]()
        if cfg.preds[b].len == 1 {
            p := cfg.preds[b][0]
            left[p] -= 1
            match out_state[p] {
                Some(s) => {
                    if left[p] == 0 && !keep[p] {
                        st = s
                        out_state[p] = None
                    } else {
                        st = clone(s)
                    }
                    for k in 0..st.len {
                        st[k].pending_store = NOV
                    }
                }
                None => {}
            }
        } else if head_pred[b] >= 0 {
            p := head_pred[b]
            st = loop_state(f, &loops, i64(loops.loop_of[b]), &out_state[p], esc.items())
            left[p] -= 1
            if left[p] == 0 && !keep[p] {
                out_state[p] = None
            }
        } else if join[b] {
            st = join_state(&out_state, cfg.preds[b].items())
            for p in cfg.preds[b] {
                left[p] -= 1
                if left[p] == 0 && !keep[p] {
                    out_state[p] = None
                }
            }
        }
        for ii in 0..f.blocks[b].insts.len {
            v := f.blocks[b].insts[ii]
            for ai in 0..f.insts[v].args.len {
                a := f.insts[v].args[ai]
                r := repl_find(repl.items(), a)
                if r != a {
                    f.insts[v].args[ai] = r
                }
            }
            match f.insts[v].op {
                Load => {
                    m := alias_memref(f, i64(v))
                    ty := f.insts[v].ty
                    hit := NOV
                    for k in 0..st.len {
                        a := &st[k]
                        if a.ty == ty && alias_must_alias(&a.m, &m) {
                            hit = i64(a.val)
                            break
                        }
                    }
                    if hit != NOV {
                        repl[v] = i32(hit)
                        dead[v] = true
                        changed = true
                    } else {
                        // this load observes any aliasing pending store
                        for k in 0..st.len {
                            a := &st[k]
                            if a.pending_store != NOV && alias_may_alias(&a.m, &m, esc.items()) {
                                a.pending_store = NOV
                            }
                        }
                        push_avail(&st, Avail{m: m, ty: ty, val: v, pending_store: NOV})
                    }
                }
                Store => {
                    m := alias_memref(f, i64(v))
                    ty := f.insts[v].ty
                    val := f.insts[v].args[1]
                    // a previous unobserved store to exactly this location is dead
                    for k in 0..st.len {
                        a := &st[k]
                        if a.pending_store != NOV && alias_must_alias(&a.m, &m) {
                            dead[a.pending_store] = true
                            changed = true
                        }
                    }
                    // keep the entries that cannot alias m, in order
                    n := 0
                    for k in 0..st.len {
                        if !alias_may_alias(&st[k].m, &m, esc.items()) {
                            st[n] = st[k]
                            n += 1
                        }
                    }
                    st.len = n
                    push_avail(&st, Avail{m: m, ty: ty, val: i32(val), pending_store: v})
                }
                // these take raw pointers that may point into any alloca passed to them
                MemCpy, MemSet => st.clear()
                Call, CallInd, Syscall, Atomic => {
                    // may read or write anything reachable (an atomic: what other threads
                    // wrote): only non-escaped stack slots survive
                    n := 0
                    for k in 0..st.len {
                        match st[k].m.addr.base {
                            Alloca(x) if !esc[x] => {
                                st[n] = st[k]
                                n += 1
                            }
                            _ => {}
                        }
                    }
                    st.len = n
                    for k in 0..st.len {
                        st[k].pending_store = NOV
                    }
                }
                _ => {}
            }
        }
        out_state[b] = Some(st)
    }
    if changed {
        for bi in 0..f.blocks.len {
            f.blocks[bi].insts.retain(dead, fn(dead: []bool, v: i32) -> bool { !dead[v] })
        }
        f.apply_repl(&repl)
    }
    if carry && carry_run(f, &cfg, &loops, &out_state, esc.items()) {
        changed = true
    }
    return changed
}

// ---------- loop-carried forwarding ----------
// A load in the header of a loop whose address in iteration k + 1 is the address of a value
// known at the end of iteration k (`d[i * w + j - 1]` after the store of `d[i * w + j]`, j
// stepping by 1) takes that value through a new header phi instead: its input from the latch
// is the known value, its input from before the loop a load of the address of the first
// iteration, made in the preheader. The latch's state (from loadelim_run, for the IR as it
// was then: the replacements only made values equal) says the location holds the value at the
// end of the latch; nothing before the load in the header may write it (no store that may
// alias, no call or block copy). The address of iteration k + 1 is the load's address as a
// linear form with every header phi replaced by its input from the latch (only header phis and
// values from outside the loop may appear in it). The header runs on every iteration, the
// first included, so the load before the loop reads what the first iteration's load read.
// (ALC_DISABLE=ldcarry)
priv fn carry_run(f: *Func, cfg: *Cfg, loops: *Loops, out_state: *Vec[Opt[Vec[Avail]]], esc: []bool) -> bool {
    changed := false
    def_block := vec[i32]()
    for li in 0..loops.loops.len {
        h := loops.loops[li].header
        if loops.loops[li].latches.len != 1 || cfg.preds[h].len != 2 {
            continue
        }
        lat := loops.loops[li].latches[0]
        pre := -1
        for q in cfg.preds[h] {
            if q != lat {
                pre = q
            }
        }
        if pre < 0 || loops.contains(li, pre) || f.blocks[h].insts.len > 400 {
            continue
        }
        st := match out_state[lat] {
            Some(s) => s
            None => continue
        }
        if st.is_empty() {
            continue
        }
        if def_block.len == 0 {
            def_block = f.block_of()
        }
        if carry_loop(f, loops, li, h, pre, lat, st.items(), def_block.items(), esc) {
            changed = true
            // (the blocks' instructions changed: later loops of this function next time)
            break
        }
    }
    return changed
}

// the loads of header h of loop li that can take the value of the previous iteration
priv fn carry_loop(f: *Func, loops: *Loops, li: i64, h: i64, pre0: i64, lat: i64, st: []Avail, def_block: []i32, esc: []bool) -> bool {
    pre := pre0
    split := false
    stores := vec[MemRef]()
    repl := vec[i32]()
    made := 0
    ii := 0
    while ii < f.blocks[h].insts.len {
        v := i64(f.blocks[h].insts[ii])
        ii += 1
        i := &f.insts[v]
        if i.op == Store {
            stores.push(alias_memref(f, v))
            if stores.len > 64 {
                break
            }
            continue
        }
        if i.op.clobbers() {
            break
        }
        if i.op != Load || i.ty.is_vec() || i.ty.size() < 4 {
            continue
        }
        m := alias_memref(f, v)
        if m.lin.n < 0 {
            continue
        }
        clobbered := false
        for s in stores {
            if alias_may_alias(&s, &m, esc) {
                clobbered = true
                break
            }
        }
        if clobbered {
            continue
        }
        // the address of the next iteration, in the values of this one
        nx := Lin{n: 0, c: m.lin.c}
        ok := true
        for t in 0..i64(m.lin.n) {
            u := i64(m.lin.v[t])
            k := m.lin.k[t]
            if f.insts[u].op == Phi && i64(def_block[u]) == h {
                x1 := f.insts[u].phi_input(lat)
                if x1 == NOV || !alias_lin_add(f, &nx, x1, k) {
                    ok = false
                    break
                }
            } else if def_block[u] != NOV && loops.contains(li, i64(def_block[u])) {
                ok = false
                break
            } else if !alias_lin_add(f, &nx, u, k) {
                ok = false
                break
            }
        }
        if !ok {
            continue
        }
        val := NOV
        for e in st {
            if e.ty == i.ty && e.m.size == m.size && e.val != i32(v) && lin_same_terms(&e.m.lin, &nx) && e.m.lin.c == nx.c {
                val = i64(e.val)
                break
            }
        }
        if val == NOV {
            continue
        }
        // the value from before the loop: the address of the first iteration, in the preheader
        if !split {
            np, _, _ := f.succ_pair(pre)
            if np != 1 || f.nsucc(pre) != 1 {
                pre = loop_split_edge(f, pre, h)
            }
            split = true
        }
        a0 := carry_clone(f, i.args[0], h, pre, loops, li, def_block, 0)
        if a0 == NOV {
            continue
        }
        ty := f.insts[v].ty
        l0 := f.mk(Load, ty, vec_one(a0), 0)
        f.im(l0).aux = f.insts[v].aux
        f.blocks[pre].insts.push(i32(l0))
        ph := f.mk_phi_of(ty, []i64{l0, val}, []i64{pre, lat})
        f.blocks[h].insts.insert(0, i32(ph))
        ii += 1
        if repl.len < f.insts.len {
            repl.resize(f.insts.len, NOV)
        }
        repl[v] = i32(ph)
        made += 1
    }
    if made == 0 {
        return split
    }
    dead := alloc[bool](f.insts.len)
    for x in 0..repl.len {
        if repl[x] != NOV {
            dead[x] = true
        }
    }
    f.blocks[h].insts.retain(dead, fn(dead: []bool, v: i32) -> bool { !dead[v] })
    f.apply_repl(&repl)
    return true
}

// value v of the first iteration, computed at the end of block pre (header phis: their input
// from pre; values from outside the loop: themselves; pure instructions of the loop: copies),
// or NOV
priv fn carry_clone(f: *Func, v: i64, h: i64, pre: i64, loops: *Loops, li: i64, def_block: []i32, depth: i64) -> i64 {
    db := if v < def_block.len { def_block[v] } else { NOV }
    if db == NOV || !loops.contains(li, i64(db)) {
        return v
    }
    i := &f.insts[v]
    if i.op == Phi {
        if i64(db) != h {
            return NOV
        }
        return i.phi_input(pre)
    }
    if !i.op.is_pure() || depth > 16 {
        return NOV
    }
    args := vec[i64]()
    for a in f.insts[v].args {
        c := carry_clone(f, a, h, pre, loops, li, def_block, depth + 1)
        if c == NOV {
            return NOV
        }
        args.push(c)
    }
    w := f.mk(f.insts[v].op, f.insts[v].ty, args, f.insts[v].k)
    f.im(w).aux = f.insts[v].aux
    f.blocks[pre].insts.push(i32(w))
    return w
}
