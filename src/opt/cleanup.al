// CFG cleanup and dead code elimination.

// remove phi inputs from non-predecessors, drop unreachable blocks' contents
fn cleanup_prune_unreachable(f: *Func) -> bool {
    rpo := f.rpo()
    n := f.blocks.len
    reach := alloc[bool](n)
    for b in rpo {
        reach[b] = true
    }
    changed := false
    for b in 0..n {
        if !reach[b] && (!f.blocks[b].insts.is_empty() || f.blocks[b].term != Term.None) {
            f.blocks[b].insts.clear()
            f.blocks[b].term = Term.None
            changed = true
        }
    }
    // p is a predecessor of b when its (now pruned) terminator goes to b
    for b in rpo {
        for ii in 0..f.blocks[b].insts.len {
            v := f.blocks[b].insts[ii]
            if f.insts[v].op != Phi {
                continue
            }
            inst := &f.insts[v]
            k := 0
            while k < inst.pb.len {
                p := inst.pb[k]
                is_pred := false
                if p >= 0 && p < n {
                    cnt, s0, s1 := f.succ_pair(p)
                    is_pred = cnt > 0 && s0 == b || cnt > 1 && s1 == b
                }
                if !is_pred {
                    inst.pb.remove(k)
                    inst.args.remove(k)
                    changed = true
                } else {
                    k += 1
                }
            }
        }
    }
    return changed
}

fn cleanup_is_root(op: Op) -> bool {
    return op == Store || op == Call || op == CallInd || op == Syscall || op == MemCpy || op == MemSet
}

fn cleanup_dce(f: *Func) -> bool {
    n := f.insts.len
    live := alloc[bool](n)
    // every value is pushed at most once (when it becomes live)
    work := mkslice[i64](__alloc_raw(n * 8), n)
    sp := 0
    for bi in 0..f.blocks.len {
        b := &f.blocks[bi]
        for v in b.insts {
            if !live[v] && cleanup_is_root(f.insts[v].op) {
                live[v] = true
                work[sp] = v
                sp += 1
            }
        }
        match b.term {
            Br(c, _, _) if !live[c] => {
                live[c] = true
                work[sp] = c
                sp += 1
            }
            Ret(vs) => {
                for v in vs {
                    if !live[v] {
                        live[v] = true
                        work[sp] = v
                        sp += 1
                    }
                }
            }
            _ => {}
        }
    }
    while sp > 0 {
        sp -= 1
        v := work[sp]
        for a in f.insts[v].args {
            if !live[a] {
                live[a] = true
                work[sp] = a
                sp += 1
            }
        }
    }
    changed := false
    for bi in 0..f.blocks.len {
        b := &f.blocks[bi]
        before := b.insts.len
        // retain(|v| live[v])
        kept := 0
        for i in 0..before {
            v := b.insts[i]
            if live[v] {
                b.insts[kept] = v
                kept += 1
            }
        }
        b.insts.len = kept
        if b.insts.len != before {
            changed = true
        }
    }
    return changed
}

priv fn trivial_phis_res(repl: *Vec[i64], v0: i64) -> i64 {
    v := v0
    while repl[v] != NOV {
        v = repl[v]
    }
    return v
}

// remove phis whose inputs are all the same value
fn cleanup_trivial_phis(f: *Func) -> bool {
    repl := vec_fill(f.insts.len, NOV)
    any := false
    loop {
        changed := false
        for bi in 0..f.blocks.len {
            for ii in 0..f.blocks[bi].insts.len {
                v := f.blocks[bi].insts[ii]
                if f.insts[v].op != Phi || repl[v] != NOV {
                    continue
                }
                same := NOV
                trivial := true
                for a0 in f.insts[v].args {
                    a := trivial_phis_res(&repl, a0)
                    if a == v || a == same {
                        continue
                    }
                    if same != NOV {
                        trivial = false
                        break
                    }
                    same = a
                }
                if trivial && same != NOV {
                    repl[v] = same
                    changed = true
                }
            }
        }
        if !changed {
            break
        }
        any = true
    }
    if any {
        for bi in 0..f.blocks.len {
            b := &f.blocks[bi]
            // retain(|v| repl[v] == NOV)
            kept := 0
            for i in 0..b.insts.len {
                v := b.insts[i]
                if repl[v] == NOV {
                    b.insts[kept] = v
                    kept += 1
                }
            }
            b.insts.len = kept
        }
        f.apply_repl(&repl)
    }
    return any
}
