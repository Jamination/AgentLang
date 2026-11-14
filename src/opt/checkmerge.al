// Merge runs of bounds checks with constant indices against the same length:
//   k1 <u len; ...; k2 <u len   (no calls in between, k2 > k1)
// becomes a single check of the largest index at the position of the first one. A failing
// later check would end the program anyway and nothing observable happens in between.

// (len value, constant index) of a check condition `len >u k` / `k <u len`
priv fn const_check(f: *Func, c: i64) -> Opt[(i64, i64)] {
    i := &f.insts[c]
    return match i.op {
        Ugt => match f.is_const(i.args[1]) {
            Some(k) => Some((i.args[0], k))
            None => None
        }
        Ult => match f.is_const(i.args[0]) {
            Some(k) => Some((i.args[1], k))
            None => None
        }
        _ => None
    }
}

fn checkmerge_run(f: *Func) -> bool {
    rpo, preds := f.rpo_preds()
    changed := false
    for b in rpo {
        c, ok, trap := match f.blocks[b].term {
            Br(c0, t0, e0) => (c0, t0, e0)
            _ => continue
        }
        if !opt_is_check_trap(f, trap) {
            continue
        }
        ln, k0 := match const_check(f, c) {
            Some(x) => x
            None => continue
        }
        if f.insts[ln].ty != I64 || k0 < 0 {
            continue
        }
        kmax := k0
        cur := ok
        steps := 0
        walk: loop {
            steps += 1
            if steps > 256 || preds[cur].len != 1 || cur == b {
                break
            }
            for v in f.blocks[cur].insts {
                o := f.insts[v].op
                if o == Call || o == CallInd || o == Syscall || o == Atomic || o == Phi {
                    break walk
                }
            }
            match f.blocks[cur].term {
                Jmp(t) => cur = t
                Br(c2, t2, e2) => {
                    if !opt_is_check_trap(f, e2) {
                        break
                    }
                    match const_check(f, c2) {
                        Some((l2, k2)) if l2 == ln && k2 >= 0 => {
                            kmax = max(kmax, k2)
                            f.blocks[cur].term = Jmp(t2)
                            changed = true
                        }
                        _ => {}
                    }
                    cur = t2
                }
                _ => break
            }
        }
        if kmax > k0 {
            kc := f.push(b, Const, I64, vec[i64](), kmax)
            nc := f.push(b, Ugt, I8, vec_of([]i64{ln, kc}), 0)
            f.blocks[b].term = Br(nc, ok, trap)
        }
    }
    if changed {
        cleanup_prune_unreachable(f)
    }
    return changed
}
