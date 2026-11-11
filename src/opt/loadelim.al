// Redundant load elimination, store-to-load forwarding and local dead store elimination.

struct LoadelimAvail {
    ptr: i64,
    mref_addr: Addr,
    size: i64,
    class: i64,
    ty: T,
    val: i64,
    pending_store: Opt[i64], // a store not yet observed by any possible reader
}

fn loadelim_mr(a: *LoadelimAvail) -> MemRef {
    return MemRef{addr: a.mref_addr, size: a.size, class: a.class, ptr: a.ptr}
}

fn loadelim_run_find(repl: []i64, v0: i64) -> i64 {
    v := v0
    while repl[v] != NOV {
        v = repl[v]
    }
    return v
}

fn loadelim_run(f: *Func) -> bool {
    cfg := cfg_new(f)
    esc := alias_escaped_allocas(f)
    repl := vec_fill(f.insts.len, NOV)
    dead := vec_fill(f.insts.len, false)
    changed := false
    // state at the end of each block, reused by a child that has that block as its only predecessor
    no_state: Opt[Vec[LoadelimAvail]] = None
    out_state := vec_fill(f.blocks.len, no_state)
    for b in cfg.rpo.items() {
        st := vec[LoadelimAvail]()
        if cfg.preds[b].len == 1 {
            p := cfg.preds[b][0]
            match out_state[p] {
                Some(s) => {
                    st = clone(s)
                    for k in 0..st.len {
                        st[k].pending_store = None
                    }
                }
                None => {}
            }
        }
        for ii in 0..f.blocks[b].insts.len {
            v := f.blocks[b].insts[ii]
            for ai in 0..f.insts[v].args.len {
                a := f.insts[v].args[ai]
                r := loadelim_run_find(repl.items(), a)
                if r != a {
                    f.insts[v].args[ai] = r
                }
            }
            op := f.insts[v].op
            if op == Load {
                m := alias_memref(f, v)
                ty := f.insts[v].ty
                hit: Opt[i64] = None
                for k in 0..st.len {
                    a := &st[k]
                    if a.ty == ty {
                        am := loadelim_mr(a)
                        if alias_must_alias(&am, &m) {
                            hit = Some(a.val)
                            break
                        }
                    }
                }
                match hit {
                    Some(val) => {
                        repl[v] = val
                        dead[v] = true
                        changed = true
                    }
                    None => {
                        // this load observes any aliasing pending store
                        for k in 0..st.len {
                            a := &st[k]
                            if is_some(a.pending_store) {
                                am := loadelim_mr(a)
                                if alias_may_alias(&am, &m, esc.items()) {
                                    a.pending_store = None
                                }
                            }
                        }
                        st.push(LoadelimAvail{ptr: m.ptr, mref_addr: m.addr, size: m.size, class: m.class, ty: ty, val: v, pending_store: None})
                    }
                }
            } else if op == Store {
                m := alias_memref(f, v)
                ty := f.insts[v].ty
                val := f.insts[v].args[1]
                // a previous unobserved store to exactly this location is dead
                for k in 0..st.len {
                    a := &st[k]
                    match a.pending_store {
                        Some(s) => {
                            am := loadelim_mr(a)
                            if alias_must_alias(&am, &m) {
                                dead[s] = true
                                changed = true
                            }
                        }
                        None => {}
                    }
                }
                // st.retain(|a| !may_alias(&mr(a), &m, &esc))
                n := 0
                for k in 0..st.len {
                    am := loadelim_mr(&st[k])
                    if !alias_may_alias(&am, &m, esc.items()) {
                        st[n] = st[k]
                        n += 1
                    }
                }
                st.len = n
                st.push(LoadelimAvail{ptr: m.ptr, mref_addr: m.addr, size: m.size, class: m.class, ty: ty, val: val, pending_store: Some(v)})
            } else if op == Call || op == CallInd || op == Syscall || op == MemCpy || op == MemSet {
                // may read or write anything reachable: only non-escaped stack slots survive
                n := 0
                for k in 0..st.len {
                    keep := false
                    match st[k].mref_addr.base {
                        Alloca(x) => keep = !esc[x]
                        _ => {}
                    }
                    if keep {
                        st[n] = st[k]
                        n += 1
                    }
                }
                st.len = n
                if op == MemCpy || op == MemSet {
                    // these take raw pointers that may point into any alloca passed to them
                    st.clear()
                }
                for k in 0..st.len {
                    st[k].pending_store = None
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
