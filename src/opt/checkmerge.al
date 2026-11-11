// Merge runs of bounds checks with constant indices against the same length:
//   k1 <u len; ...; k2 <u len   (no calls in between, k2 > k1)
// becomes a single check of the largest index at the position of the first one. A failing
// later check would end the program anyway and nothing observable happens in between.

fn checkmerge_is_trap_block(f: *Func, b: i64) -> bool {
    if !eq(f.blocks[b].term, TermTrap) {
        return false
    }
    for v in f.blocks[b].insts.items() {
        if f.insts[v].op == OpPhi {
            return false
        }
    }
    return true
}

// (len value, constant index) of a check condition `len >u k` / `k <u len`
fn checkmerge_const_check(f: *Func, c: i64) -> Opt[(i64, i64)] {
    i := &f.insts[c]
    if i.op == OpUgt {
        match f.is_const(i.args[1]) {
            Some(k) => return Some((i.args[0], k))
            None => return None
        }
    }
    if i.op == OpUlt {
        match f.is_const(i.args[0]) {
            Some(k) => return Some((i.args[1], k))
            None => return None
        }
    }
    return None
}

fn checkmerge_run(f: *Func) -> bool {
    preds := f.preds()
    changed := false
    rpo := f.rpo()
    for b in rpo.items() {
        c := 0
        ok := 0
        trap := 0
        match f.blocks[b].term {
            TermBr(c0, t0, e0) => {
                c = c0
                ok = t0
                trap = e0
            }
            _ => continue
        }
        if !checkmerge_is_trap_block(f, trap) {
            continue
        }
        ln := 0
        k0 := 0
        match checkmerge_const_check(f, c) {
            Some(x) => {
                ln = x.0
                k0 = x.1
            }
            None => continue
        }
        if f.insts[ln].ty != TI64 || k0 < 0 {
            continue
        }
        kmax := k0
        cur := ok
        steps := 0
        loop {
            steps += 1
            if steps > 256 || preds[cur].len != 1 || cur == b {
                break
            }
            blocked := false
            for v in f.blocks[cur].insts.items() {
                o := f.insts[v].op
                if o == OpCall || o == OpCallInd || o == OpSyscall || o == OpPhi {
                    blocked = true
                    break
                }
            }
            if blocked {
                break
            }
            match f.blocks[cur].term {
                TermJmp(t) => cur = t
                TermBr(c2, t2, e2) => {
                    if !checkmerge_is_trap_block(f, e2) {
                        break
                    }
                    match checkmerge_const_check(f, c2) {
                        Some(x) => {
                            if x.0 == ln && x.1 >= 0 {
                                kmax = max(kmax, x.1)
                                f.blocks[cur].term = TermJmp(t2)
                                changed = true
                            }
                        }
                        None => {}
                    }
                    cur = t2
                }
                _ => break
            }
        }
        if kmax > k0 {
            kc := f.push(b, OpConst, TI64, vec[i64](), kmax)
            nc := f.push(b, OpUgt, TI8, vec_of([]i64{ln, kc}), 0)
            f.blocks[b].term = TermBr(nc, ok, trap)
        }
    }
    if changed {
        cleanup_prune_unreachable(f)
    }
    return changed
}
