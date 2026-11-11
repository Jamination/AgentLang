// Loop-invariant code motion (with preheader creation).

// predecessors of the header `h` of loop `li` that are outside the loop
// (cfg.preds[h].iter().copied().filter(|p| !loops.contains(li, *p)).collect())
fn licm_outside_preds(cfg *Cfg, loops *Loops, li i64, h i64) Vec[i64] {
    outside := vec[i64]()
    for p in cfg.preds[h].items() {
        if !loops.contains(li, p) {
            outside.push(p)
        }
    }
    return outside
}

// loop indices, deepest loops first; stable like Rust's sort_by
// (order.sort_by(|a, b| loops.loops[*b].depth.cmp(&loops.loops[*a].depth)))
fn licm_loop_order(loops *Loops) Vec[i64] {
    order := vec[i64]()
    for li in 0..loops.loops.len {
        order.push(li)
        k := order.len - 1
        while k > 0 && loops.loops[order[k - 1]].depth < loops.loops[li].depth {
            order[k] = order[k - 1]
            k -= 1
        }
        order[k] = li
    }
    return order
}

fn licm_make_preheaders(f *Func) bool {
    cfg := cfg_new(f)
    loops := loops_new(f, &cfg)
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
        f.blocks[p].term = TermJmp(h)
        for o in outside.items() {
            match f.blocks[o].term {
                TermJmp(t) => {
                    if t == h {
                        f.blocks[o].term = TermJmp(p)
                    }
                }
                TermBr(c, a, b) => {
                    na := a
                    nb := b
                    if a == h {
                        na = p
                    }
                    if b == h {
                        nb = p
                    }
                    f.blocks[o].term = TermBr(c, na, nb)
                }
                _ => {}
            }
        }
        // fix header phis
        hinsts := clone(&f.blocks[h].insts)
        for v in hinsts.items() {
            if f.insts[v].op != OpPhi {
                break
            }
            inst := clone(&f.insts[v])
            out_vals := vec[(i64, i64)]()
            keep_args := vec[i64]()
            keep_pb := vec[i64]()
            for k in 0..inst.pb.len {
                pb := inst.pb[k]
                if contains(&outside, pb) {
                    out_vals.push((pb, inst.args[k]))
                } else {
                    keep_args.push(inst.args[k])
                    keep_pb.push(pb)
                }
            }
            all_same := true
            for x in out_vals.items() {
                if x.1 != out_vals[0].1 {
                    all_same = false
                    break
                }
            }
            incoming := 0
            if all_same {
                incoming = out_vals.at(0).1
            } else {
                vals := vec[i64]()
                pbs := vec[i64]()
                for x in out_vals.items() {
                    vals.push(x.1)
                    pbs.push(x.0)
                }
                np := f.mk(OpPhi, inst.ty, vals, 0)
                f.im(np).pb = pbs
                f.blocks[p].insts.push(np)
                incoming = np
            }
            keep_args.push(incoming)
            keep_pb.push(p)
            i := f.im(v)
            i.args = keep_args
            i.pb = keep_pb
        }
        changed = true
    }
    return changed
}

// exiting.iter().all(|e| cfg.dom(b, *e)) && l.latches.iter().all(|t| cfg.dom(b, *t))
fn licm_run_guaranteed(cfg *Cfg, exiting []i64, latches []i64, b i64) bool {
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

fn licm_run(f *Func) bool {
    changed := licm_make_preheaders(f)
    cfg := cfg_new(f)
    loops := loops_new(f, &cfg)
    if loops.loops.is_empty() {
        return changed
    }
    esc := alias_escaped_allocas(f)
    def_block := f.block_of()
    order := licm_loop_order(&loops)
    for li in order.items() {
        l := &loops.loops[li]
        h := l.header
        outside := licm_outside_preds(&cfg, &loops, li, h)
        if outside.len != 1 || f.succs(outside[0]).len != 1 {
            continue
        }
        pre := outside[0]
        in_loop := vec_fill(f.blocks.len, false)
        for b in l.blocks.items() {
            in_loop[b] = true
        }
        // blocks.sort_by_key(|b| cfg.rpo_idx[*b as usize]) (stable)
        blocks := vec[i64]()
        for b in l.blocks.items() {
            blocks.push(b)
            k := blocks.len - 1
            while k > 0 && cfg.rpo_idx[blocks[k - 1]] > cfg.rpo_idx[b] {
                blocks[k] = blocks[k - 1]
                k -= 1
            }
            blocks[k] = b
        }
        // memory effects and exits
        stores := vec[MemRef]()
        has_call := false
        exiting := vec[i64]()
        for b in blocks.items() {
            for v in f.blocks[b].insts.items() {
                o := f.insts[v].op
                if o == OpStore {
                    stores.push(alias_memref(f, v))
                } else if o == OpCall || o == OpCallInd || o == OpSyscall || o == OpMemCpy || o == OpMemSet {
                    has_call = true
                }
            }
            leaves := false
            ss := f.succs(b)
            for s in ss.items() {
                if !in_loop[s] {
                    leaves = true
                    break
                }
            }
            if !leaves {
                match f.blocks[b].term {
                    TermRet(vs) => leaves = true
                    TermTrap => leaves = true
                    _ => {}
                }
            }
            if leaves {
                exiting.push(b)
            }
        }
        loop {
            moved := false
            for b in blocks.items() {
                insts := clone(&f.blocks[b].insts)
                keep := vec[i64]()
                for v in insts.items() {
                    i := &f.insts[v]
                    invariant_args := true
                    for a in i.args.items() {
                        db := def_block[a]
                        if !(db == 0xFFFFFFFF || !in_loop[db]) {
                            invariant_args = false
                            break
                        }
                    }
                    ok := false
                    if invariant_args {
                        if i.op.is_pure() {
                            ok = true
                        } else if i.op == OpSDiv || i.op == OpUDiv || i.op == OpSRem || i.op == OpURem {
                            safe_const := false
                            match f.is_const(i.args[1]) {
                                Some(k) => safe_const = k != 0 && !(k == -1 && (i.op == OpSDiv || i.op == OpSRem))
                                None => {}
                            }
                            ok = safe_const || licm_run_guaranteed(&cfg, exiting.items(), l.latches.items(), b)
                        } else if i.op == OpLoad {
                            m := alias_memref(f, v)
                            private := false
                            safe_addr := false
                            match m.addr.base {
                                BaseAlloca(x) => {
                                    private = !esc[x]
                                    safe_addr = is_some(m.addr.off)
                                }
                                BaseGlobal(g) => safe_addr = is_some(m.addr.off)
                                BaseUnknown(u) => {}
                            }
                            if !has_call || private {
                                aliased := false
                                for si in 0..stores.len {
                                    if alias_may_alias(&stores[si], &m, esc.items()) {
                                        aliased = true
                                        break
                                    }
                                }
                                if !aliased && (safe_addr || licm_run_guaranteed(&cfg, exiting.items(), l.latches.items(), b)) {
                                    ok = true
                                }
                            }
                        }
                    }
                    if ok {
                        f.blocks[pre].insts.push(v)
                        def_block[v] = pre
                        moved = true
                    } else {
                        keep.push(v)
                    }
                }
                f.blocks[b].insts = keep
            }
            if !moved {
                break
            }
            changed = true
        }
    }
    return changed
}
