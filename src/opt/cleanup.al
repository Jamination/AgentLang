// CFG cleanup and dead code elimination.

// remove phi inputs from non-predecessors, drop unreachable blocks' contents
fn cleanup_prune_unreachable(f: *Func) -> bool {
    rpo := f.rpo()
    reach := vec_fill(f.blocks.len, false)
    for b in rpo.items() {
        reach[b] = true
    }
    changed := false
    for b in 0..f.blocks.len {
        if !reach[b] && (!f.blocks[b].insts.is_empty() || !term_is_none(f.blocks[b].term)) {
            f.blocks[b].insts.clear()
            f.blocks[b].term = Term.None
            changed = true
        }
    }
    preds := f.preds()
    for b in rpo.items() {
        for ii in 0..f.blocks[b].insts.len {
            v := f.blocks[b].insts[ii]
            if f.insts[v].op != Phi {
                continue
            }
            inst := &f.insts[v]
            k := 0
            while k < inst.pb.len {
                if !contains(&preds[b], inst.pb[k]) {
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

priv fn term_is_none(t: Term) -> bool {
    match t {
        Term.None => true
        _ => false
    }
}

fn cleanup_is_root(op: Op) -> bool {
    return op == Store || op == Call || op == CallInd || op == Syscall || op == MemCpy || op == MemSet
}

fn cleanup_dce(f: *Func) -> bool {
    n := f.insts.len
    live := vec_fill(n, false)
    work := vec[i64]()
    for bi in 0..f.blocks.len {
        b := &f.blocks[bi]
        for v in b.insts.items() {
            if cleanup_is_root(f.insts[v].op) {
                live[v] = true
                work.push(v)
            }
        }
        match b.term {
            Br(c, _, _) if !live[c] => {
                live[c] = true
                work.push(c)
            }
            Ret(vs) => {
                for v in vs.items() {
                    if !live[v] {
                        live[v] = true
                        work.push(v)
                    }
                }
            }
            _ => {}
        }
    }
    while work.len > 0 {
        v := work.pop()
        for ai in 0..f.insts[v].args.len {
            a := f.insts[v].args[ai]
            if !live[a] {
                live[a] = true
                work.push(a)
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
                for a0 in f.insts[v].args.items() {
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
