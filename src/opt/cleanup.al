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
    // p is a predecessor of b when its (now pruned) terminator goes to b; the phis of a block
    // come first
    for b in rpo {
        for ii in 0..f.blocks[b].insts.len {
            v := f.blocks[b].insts[ii]
            if f.insts[v].op != Phi {
                break
            }
            inst := &f.insts[v]
            fr := inst.from()
            // the inputs kept move down in place (in order)
            m := 0
            for k in 0..fr.len {
                p := fr[k]
                is_pred := false
                if p >= 0 && p < n {
                    cnt, s0, s1 := f.succ_pair(p)
                    is_pred = cnt > 0 && s0 == b || cnt > 1 && s1 == b
                }
                if is_pred {
                    fr[m] = p
                    inst.args[m] = inst.args[k]
                    m += 1
                }
            }
            if m != fr.len {
                inst.args = inst.args[..m]
                changed = true
            }
        }
    }
    return changed
}

fn cleanup_is_root(op: Op) -> bool {
    return op == Store || op.clobbers()
}

fn cleanup_dce(f: *Func) -> bool {
    n := f.insts.len
    live := alloc[bool](n)
    // every value is pushed at most once (when it becomes live)
    work := mkslice[i32](__alloc_raw(n * 4), n)
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
                work[sp] = i32(c)
                sp += 1
            }
            Ret(vs) => {
                for v in vs {
                    if !live[v] {
                        live[v] = true
                        work[sp] = i32(v)
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
                work[sp] = i32(a)
                sp += 1
            }
        }
    }
    changed := false
    for bi in 0..f.blocks.len {
        b := &f.blocks[bi]
        before := b.insts.len
        // keep the live instructions, in order (a loop, not retain: this runs over every
        // instruction after each pass, and retain costs an indirect call per element)
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

// remove phis whose inputs are all the same value
fn cleanup_trivial_phis(f: *Func) -> bool {
    // the phis in block order (they come first in their blocks)
    phis := vec[i64]()
    for bi in 0..f.blocks.len {
        for v in f.blocks[bi].insts {
            if f.insts[v].op != Phi {
                break
            }
            phis.push(i64(v))
        }
    }
    if phis.is_empty() {
        return false
    }
    repl := vec_fill(f.insts.len, i32(NOV))
    any := false
    loop {
        changed := false
        for v in phis {
            if repl[v] != NOV {
                continue
            }
            same := NOV
            trivial := true
            for a0 in f.insts[v].args {
                a := repl_find(repl.items(), a0)
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
                repl[v] = i32(same)
                changed = true
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
            // keep the instructions that are not replaced, in order
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
