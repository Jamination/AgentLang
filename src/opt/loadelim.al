// Redundant load elimination, store-to-load forwarding and local dead store elimination.

struct LoadelimAvail {
    ptr i64,
    mref_addr Addr,
    size i64,
    class i64,
    ty T,
    val i64,
    pending_store Opt[i64], // a store not yet observed by any possible reader
}

fn loadelim_mr(a *LoadelimAvail) MemRef {
    return MemRef{addr: a.mref_addr, size: a.size, class: a.class, ptr: a.ptr}
}

fn loadelim_run_find(repl []i64, v0 i64) i64 {
    v := v0
    while repl[v] != NOV {
        v = repl[v]
    }
    return v
}

fn loadelim_run(f *Func) bool {
    cfg := cfg_new(f)
    esc := alias_escaped_allocas(f)
    repl := vec_fill(f.insts.len, NOV)
    dead := vec_fill(f.insts.len, false)
    changed := false
    // state at the end of each block, reused by a child that has that block as its only predecessor
    var no_state Opt[Vec[LoadelimAvail]] = None
    out_state := vec_fill(f.blocks.len, no_state)
    for b in cfg.rpo.items() {
        st := vec[LoadelimAvail]()
        if cfg.preds.buf[b].len == 1 {
            p := cfg.preds.buf[b].buf[0]
            match out_state.buf[p] {
                Some(s) => {
                    st = clone(s)
                    for k in 0..st.len {
                        st.buf[k].pending_store = None
                    }
                }
                None => {}
            }
        }
        for ii in 0..f.blocks.buf[b].insts.len {
            v := f.blocks.buf[b].insts.buf[ii]
            for ai in 0..f.insts.buf[v].args.len {
                a := f.insts.buf[v].args.buf[ai]
                r := loadelim_run_find(repl.items(), a)
                if r != a {
                    f.insts.buf[v].args.buf[ai] = r
                }
            }
            op := f.insts.buf[v].op
            if op == OpLoad {
                m := alias_memref(f, v)
                ty := f.insts.buf[v].ty
                var hit Opt[i64] = None
                for k in 0..st.len {
                    a := &st.buf[k]
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
                        repl.buf[v] = val
                        dead.buf[v] = true
                        changed = true
                    }
                    None => {
                        // this load observes any aliasing pending store
                        for k in 0..st.len {
                            a := &st.buf[k]
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
            } else if op == OpStore {
                m := alias_memref(f, v)
                ty := f.insts.buf[v].ty
                val := f.insts.buf[v].args.buf[1]
                // a previous unobserved store to exactly this location is dead
                for k in 0..st.len {
                    a := &st.buf[k]
                    match a.pending_store {
                        Some(s) => {
                            am := loadelim_mr(a)
                            if alias_must_alias(&am, &m) {
                                dead.buf[s] = true
                                changed = true
                            }
                        }
                        None => {}
                    }
                }
                // st.retain(|a| !may_alias(&mr(a), &m, &esc))
                n := 0
                for k in 0..st.len {
                    am := loadelim_mr(&st.buf[k])
                    if !alias_may_alias(&am, &m, esc.items()) {
                        st.buf[n] = st.buf[k]
                        n += 1
                    }
                }
                st.len = n
                st.push(LoadelimAvail{ptr: m.ptr, mref_addr: m.addr, size: m.size, class: m.class, ty: ty, val: val, pending_store: Some(v)})
            } else if op == OpCall || op == OpCallInd || op == OpSyscall || op == OpMemCpy || op == OpMemSet {
                // may read or write anything reachable: only non-escaped stack slots survive
                n := 0
                for k in 0..st.len {
                    keep := false
                    match st.buf[k].mref_addr.base {
                        BaseAlloca(x) => keep = !esc.buf[x]
                        _ => {}
                    }
                    if keep {
                        st.buf[n] = st.buf[k]
                        n += 1
                    }
                }
                st.len = n
                if op == OpMemCpy || op == OpMemSet {
                    // these take raw pointers that may point into any alloca passed to them
                    st.clear()
                }
                for k in 0..st.len {
                    st.buf[k].pending_store = None
                }
            }
        }
        out_state.buf[b] = Some(st)
    }
    if changed {
        for bi in 0..f.blocks.len {
            blk := &f.blocks.buf[bi]
            n := 0
            for k in 0..blk.insts.len {
                v := blk.insts.buf[k]
                if !dead.buf[v] {
                    blk.insts.buf[n] = v
                    n += 1
                }
            }
            blk.insts.len = n
        }
        f.apply_repl(&repl)
    }
    return changed
}
