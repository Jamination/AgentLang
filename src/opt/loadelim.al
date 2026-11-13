// Redundant load elimination, store-to-load forwarding and local dead store elimination.

priv struct Avail {
    m: MemRef,
    ty: T,
    val: i32,
    pending_store: i32, // a store not yet observed by any possible reader (NOV: none)
}

fn loadelim_run(f: *Func) -> bool {
    cfg := cfg_new(f)
    esc := alias_escaped_cached(f, opt_gen())
    repl := vec_fill(f.insts.len, i32(NOV))
    dead := alloc[bool](f.insts.len)
    changed := false
    // state at the end of each block, reused by a child that has that block as its only
    // predecessor; `left[p]`: such children of p not yet visited (the last one takes the state
    // instead of a copy)
    nb := f.blocks.len
    left := alloc[i64](nb)
    for b in cfg.rpo {
        if cfg.preds[b].len == 1 {
            left[cfg.preds[b][0]] += 1
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
            op := f.insts[v].op
            if op == Load {
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
            } else if op == Store {
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
                // st.retain(|a| !may_alias(&a.m, &m, &esc))
                n := 0
                for k in 0..st.len {
                    if !alias_may_alias(&st[k].m, &m, esc.items()) {
                        st[n] = st[k]
                        n += 1
                    }
                }
                st.len = n
                st.push(Avail{m: m, ty: ty, val: i32(val), pending_store: v})
            } else if op == Call || op == CallInd || op == Syscall || op == MemCpy || op == MemSet {
                // may read or write anything reachable: only non-escaped stack slots survive
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
                if op == MemCpy || op == MemSet {
                    // these take raw pointers that may point into any alloca passed to them
                    st.clear()
                }
                for k in 0..st.len {
                    st[k].pending_store = NOV
                }
            }
        }
        out_state[b] = Some(st)
    }
    if changed {
        for bi in 0..f.blocks.len {
            blk := &f.blocks[bi]
            n := 0
            for k in 0..blk.insts.len {
                v := blk.insts[k]
                if !dead[v] {
                    blk.insts[n] = v
                    n += 1
                }
            }
            blk.insts.len = n
        }
        f.apply_repl(&repl)
    }
    return changed
}
