// CFG cleanup and dead code elimination.

// remove phi inputs from non-predecessors, drop unreachable blocks' contents
fn cleanup_prune_unreachable(f *Func) bool {
    rpo := f.rpo()
    reach := vec_fill(f.blocks.len, false)
    for b in rpo.items() {
        reach.buf[b] = true
    }
    changed := false
    for b in 0..f.blocks.len {
        if !reach.buf[b] && (!f.blocks.buf[b].insts.is_empty() || !cleanup_term_is_none(f.blocks.buf[b].term)) {
            f.blocks.buf[b].insts.clear()
            f.blocks.buf[b].term = TermNone
            changed = true
        }
    }
    preds := f.preds()
    for b in rpo.items() {
        for ii in 0..f.blocks.buf[b].insts.len {
            v := f.blocks.buf[b].insts.buf[ii]
            if f.insts.buf[v].op != OpPhi {
                continue
            }
            inst := &f.insts.buf[v]
            k := 0
            while k < inst.pb.len {
                if !contains(&preds.buf[b], inst.pb.buf[k]) {
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

// `term != Term::None`
fn cleanup_term_is_none(t Term) bool {
    match t {
        TermNone => { return true }
        _ => {}
    }
    return false
}

fn cleanup_is_root(op Op) bool {
    return op == OpStore || op == OpCall || op == OpCallInd || op == OpSyscall || op == OpMemCpy || op == OpMemSet
}

fn cleanup_dce(f *Func) bool {
    n := f.insts.len
    live := vec_fill(n, false)
    work := vec[i64]()
    for bi in 0..f.blocks.len {
        b := &f.blocks.buf[bi]
        for v in b.insts.items() {
            if cleanup_is_root(f.insts.buf[v].op) {
                live.buf[v] = true
                work.push(v)
            }
        }
        match b.term {
            TermBr(c, t, e) => {
                if !live.buf[c] {
                    live.buf[c] = true
                    work.push(c)
                }
            }
            TermRet(vs) => {
                for v in vs.items() {
                    if !live.buf[v] {
                        live.buf[v] = true
                        work.push(v)
                    }
                }
            }
            _ => {}
        }
    }
    while work.len > 0 {
        v := work.pop()
        for ai in 0..f.insts.buf[v].args.len {
            a := f.insts.buf[v].args.buf[ai]
            if !live.buf[a] {
                live.buf[a] = true
                work.push(a)
            }
        }
    }
    changed := false
    for bi in 0..f.blocks.len {
        b := &f.blocks.buf[bi]
        before := b.insts.len
        // retain(|v| live[v])
        kept := 0
        for i in 0..before {
            v := b.insts.buf[i]
            if live.buf[v] {
                b.insts.buf[kept] = v
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

fn cleanup_trivial_phis_res(repl *Vec[i64], v0 i64) i64 {
    v := v0
    while repl.buf[v] != NOV {
        v = repl.buf[v]
    }
    return v
}

// remove phis whose inputs are all the same value
fn cleanup_trivial_phis(f *Func) bool {
    repl := vec_fill(f.insts.len, NOV)
    any := false
    loop {
        changed := false
        for bi in 0..f.blocks.len {
            for ii in 0..f.blocks.buf[bi].insts.len {
                v := f.blocks.buf[bi].insts.buf[ii]
                if f.insts.buf[v].op != OpPhi || repl.buf[v] != NOV {
                    continue
                }
                same := NOV
                trivial := true
                for a0 in f.insts.buf[v].args.items() {
                    a := cleanup_trivial_phis_res(&repl, a0)
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
                    repl.buf[v] = same
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
            b := &f.blocks.buf[bi]
            // retain(|v| repl[v] == NOV)
            kept := 0
            for i in 0..b.insts.len {
                v := b.insts.buf[i]
                if repl.buf[v] == NOV {
                    b.insts.buf[kept] = v
                    kept += 1
                }
            }
            b.insts.len = kept
        }
        f.apply_repl(&repl)
    }
    return any
}
