// Redundant load elimination, store-to-load forwarding and local dead store elimination.

priv struct Avail {
    m: MemRef,
    ty: T,
    val: i32,
    pending_store: i32, // a store not yet observed by any possible reader (NOV: none)
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
    no_state: Opt[Vec[Avail]] = None
    out_state := vec_fill(nb, no_state)
    for b in cfg.rpo {
        st := vec[Avail]()
        if cfg.preds[b].len == 1 {
            p := cfg.preds[b][0]
            left[p] -= 1
            match out_state[p] {
                Some(s) => {
                    if left[p] == 0 {
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
            if left[p] == 0 {
                out_state[p] = None
            }
        } else if join[b] {
            st = join_state(&out_state, cfg.preds[b].items())
            for p in cfg.preds[b] {
                left[p] -= 1
                if left[p] == 0 {
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
                        st.push(Avail{m: m, ty: ty, val: v, pending_store: NOV})
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
                    st.push(Avail{m: m, ty: ty, val: i32(val), pending_store: v})
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
    return changed
}
