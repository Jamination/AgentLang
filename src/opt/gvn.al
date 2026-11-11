// Dominator-scoped global value numbering for pure instructions, plus propagation of
// branch conditions into dominated blocks (removes repeated checks).

// type Key = (Op, T, Vec<V>, i64); `args` is an independent copy that is never changed
GvnKey :: struct { op: Op, ty: T, args: []i64, k: i64 }

GvnStep :: enum {
    GvnStepEnter(i64),
    GvnStepExit(Vec[GvnKey], Vec[(i64, Opt[bool])]),
}

gvn_numberable :: (op: Op) -> bool {
    return op.is_pure() || op == OpSDiv || op == OpUDiv || op == OpSRem || op == OpURem || op == OpProj
}

gvn_run_find :: (repl: []i64, v0: i64) -> i64 {
    v := v0
    while repl[v] != NOV {
        v = repl[v]
    }
    return v
}

gvn_run :: (f: *Func) -> bool {
    cfg := cfg_new(f)
    repl := vec_fill(f.insts.len, NOV)
    table := map[GvnKey, i64]()
    known := map[i64, bool]()
    changed := false
    bool_consts := [2]i64{NOV, NOV}
    stack := vec_of([]GvnStep{GvnStepEnter(0)})
    while stack.len > 0 {
        step := stack.pop()
        match step {
            GvnStepExit(keys, facts) => {
                for k in keys.items() {
                    table.del(k)
                }
                fi := facts.len - 1
                while fi >= 0 {
                    c := facts[fi].0
                    match facts[fi].1 {
                        Some(o) => {
                            known.set(c, o)
                        }
                        None => {
                            known.del(c)
                        }
                    }
                    fi -= 1
                }
            }
            GvnStepEnter(b) => {
                added := vec[GvnKey]()
                facts := vec[(i64, Opt[bool])]()
                // a block reached only through one arm of a conditional branch knows the condition
                if cfg.preds[b].len == 1 {
                    p := cfg.preds[b][0]
                    match f.blocks[p].term {
                        TermBr(c0, t, e) => {
                            if t != e {
                                c := gvn_run_find(repl.items(), c0)
                                val := t == b
                                old: Opt[bool] = None
                                ov, had := known.get(c)
                                if had {
                                    old = Some(ov)
                                }
                                known.set(c, val)
                                facts.push((c, old))
                                // an equivalent negated compare is also decided
                            }
                        }
                        _ => {}
                    }
                }
                old := f.blocks[b].insts
                f.blocks[b].insts = vec[i64]()
                nw := vec[i64]()
                for v in old.items() {
                    for ai in 0..f.insts[v].args.len {
                        a := f.insts[v].args[ai]
                        r := gvn_run_find(repl.items(), a)
                        // a condition decided by a dominating branch is a constant here
                        val, is_known := known.get(r)
                        if is_known {
                            if f.insts[r].op != OpConst {
                                // the constants live at the top of the entry block
                                slot := i64(val)
                                if bool_consts[slot] == NOV {
                                    bool_consts[slot] = f.mk(OpConst, TI8, vec[i64](), i64(val))
                                    repl.push(NOV)
                                }
                                r = bool_consts[slot]
                                changed = true
                            }
                        }
                        if r != a {
                            f.insts[v].args[ai] = r
                        }
                    }
                    i := &f.insts[v]
                    if !gvn_numberable(i.op) {
                        nw.push(v)
                        continue
                    }
                    args := clone(&i.args)
                    if i.op.is_commutative() && args.len == 2 && args[0] > args[1] {
                        t := args[0]
                        args[0] = args[1]
                        args[1] = t
                    }
                    key := GvnKey{op: i.op, ty: i.ty, args: args.items(), k: i.k}
                    w, found := table.get(key)
                    if found {
                        repl[v] = w
                        changed = true
                    } else {
                        table.set(key, v)
                        added.push(key)
                        nw.push(v)
                    }
                }
                f.blocks[b].insts = nw
                match f.blocks[b].term {
                    TermBr(c0, t, e) => {
                        c := gvn_run_find(repl.items(), c0)
                        val, is_known := known.get(c)
                        if is_known {
                            if val {
                                f.blocks[b].term = TermJmp(t)
                            } else {
                                f.blocks[b].term = TermJmp(e)
                            }
                            changed = true
                        }
                    }
                    _ => {}
                }
                stack.push(GvnStepExit(added, facts))
                ci := cfg.children[b].len - 1
                while ci >= 0 {
                    stack.push(GvnStepEnter(cfg.children[b][ci]))
                    ci -= 1
                }
            }
        }
    }
    extra := vec[i64]()
    for c in bool_consts {
        if c != NOV {
            extra.push(c)
        }
    }
    if !extra.is_empty() {
        // after the entry block's phis there are none: block 0 has no predecessors
        e := extra
        e.extend(f.blocks[0].insts.items())
        f.blocks[0].insts = e
    }
    if changed {
        f.apply_repl(&repl)
        cleanup_prune_unreachable(f)
    }
    return changed
}
