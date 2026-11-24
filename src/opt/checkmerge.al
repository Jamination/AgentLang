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
    if opt_enabled("checkor") && checkmerge_or(f) {
        changed = true
    }
    if opt_enabled("checkarms") && checkmerge_arms(f) {
        changed = true
    }
    if changed {
        cleanup_prune_unreachable(f)
    }
    return changed
}

// (index, bound) of a check condition `i <u K` / `K >u i` with K a constant power of two
priv fn pow2_check(f: *Func, c: i64) -> Opt[(i64, i64)] {
    i := &f.insts[c]
    x, kv := match i.op {
        Ult => (i.args[0], i.args[1])
        Ugt => (i.args[1], i.args[0])
        _ => return None
    }
    return match f.is_const(kv) {
        Some(k) if k > 0 && k & (k - 1) == 0 && f.insts[x].ty == f.insts[kv].ty => Some((x, k))
        _ => None
    }
}

// Runs of checks of variable indices against the same power-of-two constant (an array of fixed
// size indexed by fields of a word, as in an interpreter's `r[a] = r[b] + r[c]`):
//   i1 <u K; ...; i2 <u K   (no calls in between, i2 computed before the first check)
// become one check `(i1 | i2) <u K` at the position of the first: the bits of the OR are below
// K exactly when those of every index are. As for the merges above, only which failing access
// is reported can differ.
priv fn checkmerge_or(f: *Func) -> bool {
    cfg := cfg_new(f)
    preds := &cfg.preds
    bo := f.block_of()
    changed := false
    for b in cfg.rpo.items() {
        c, ok, trap := match f.blocks[b].term {
            Br(c0, t0, e0) => (c0, t0, e0)
            _ => continue
        }
        if !opt_is_check_trap(f, trap) {
            continue
        }
        x0, k0 := match pow2_check(f, c) {
            Some(x) => x
            None => continue
        }
        acc := x0
        cur := ok
        steps := 0
        walk: loop {
            steps += 1
            if steps > 64 || preds[cur].len != 1 || cur == b {
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
                    match pow2_check(f, c2) {
                        Some((y, k2)) if k2 == k0 && f.insts[y].ty == f.insts[x0].ty => {
                            yv := y
                            yb := i64(bo[y])
                            avail := yb != NOV && cfg.dom(yb, b)
                            // (the widening of a field, made next to the check: made again)
                            if !avail && f.insts[y].op == ZExt {
                                z := f.insts[y].args[0]
                                zb := i64(bo[z])
                                if zb != NOV && cfg.dom(zb, b) {
                                    yv = f.push(b, ZExt, f.insts[y].ty, vec_of([]i64{z}), 0)
                                    avail = true
                                }
                            }
                            if avail {
                                if yv != x0 && yv != acc {
                                    acc = f.push(b, Or, f.insts[x0].ty, vec_of([]i64{acc, yv}), 0)
                                }
                                f.blocks[cur].term = Jmp(t2)
                                changed = true
                            }
                        }
                        _ => {}
                    }
                    cur = t2
                }
                _ => break
            }
        }
        if acc != x0 {
            kc := f.push(b, Const, f.insts[x0].ty, vec[i64](), k0)
            nc := f.push(b, Ult, I8, vec_of([]i64{acc, kc}), 0)
            f.blocks[b].term = Br(nc, ok, trap)
        }
    }
    return changed
}

// Both arms of a two-way branch begin with the same check (merge sort's `tmp[k] = a[j]` /
// `tmp[k] = a[i]`):
//   b: br c, t, e     t: x = i <u n; br x, t2, trap1     e: y = i <u n; br y, e2, trap2
// becomes one check ahead of the branch, which then goes straight to t2 / e2:
//   b: x = i <u n; br x, n, trap1     n: br c, t2, e2
// (the failure reported is the first arm's; as for the merges above, only which failing access
// is reported can differ). The arms' bodies are then alike enough for store sinking and
// if-conversion.
priv fn checkmerge_arms(f: *Func) -> bool {
    preds := cfg_preds(f)
    // the check an arm consists of: (condition, next block, trap block)
    fn arm(f: *Func, preds: *Vec[Vec[i64]], x: i64) -> Opt[(i64, i64, i64)] {
        if x == 0 || preds[x].len != 1 || f.blocks[x].insts.len != 1 {
            return None
        }
        return match f.blocks[x].term {
            Br(c, t, e) if i64(f.blocks[x].insts[0]) == c && t != e && t != x && f.insts[c].op.is_icmp() && opt_is_check_trap(f, e) => {
                if f.blocks[e].insts.len > 0 && f.insts[f.blocks[e].insts[0]].op == Phi {
                    return None
                }
                Some((c, t, e))
            }
            _ => None
        }
    }
    changed := false
    nb := f.blocks.len
    for b in 0..nb {
        c, t, e := match f.blocks[b].term {
            Br(c0, t0, e0) if t0 != e0 && t0 != b && e0 != b => (c0, t0, e0)
            _ => continue
        }
        x, t2, trap := match arm(f, &preds, t) {
            Some(a) => a
            None => continue
        }
        y, e2, _ := match arm(f, &preds, e) {
            Some(a) => a
            None => continue
        }
        xi := &f.insts[x]
        yi := &f.insts[y]
        if xi.op != yi.op || xi.args[0] != yi.args[0] || xi.args[1] != yi.args[1] || t2 == e2 || t2 == t || e2 == e {
            continue
        }
        n := f.new_block()
        f.blocks[t].insts.clear()
        f.blocks[b].insts.push(i32(x))
        f.blocks[n].term = Br(c, t2, e2)
        f.blocks[b].term = Br(x, n, trap)
        f.phi_pred_replace(t2, t, n)
        f.phi_pred_replace(e2, e, n)
        // (t and e have no predecessor left)
        f.blocks[t].term = Term.None
        f.blocks[e].term = Term.None
        f.blocks[e].insts.clear()
        changed = true
    }
    return changed
}
