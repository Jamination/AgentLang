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

// how many preheaders licm_make_preheaders has made so far (callers that do not report them
// as a change: unroll_run, bce_run)
priv preheaders_made: i64

fn licm_preheaders_made() -> i64 {
    return preheaders_made
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
        preheaders_made += 1
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
    esc := alias_escaped_cached(f, if changed { -1 } else { opt_gen() })
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
    return changed
}
