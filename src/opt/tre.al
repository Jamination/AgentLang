// Tail-recursion elimination, including the accumulator form
//     return x + f(args)        (also *, &, |, ^ on integers)
// which becomes a loop that carries the pending operation in an accumulator.

priv struct Site {
    block: i64,
    call: i64,
    // accumulator form: (combining instruction, the other operand)
    acc: Opt[(i64, i64)],
}

priv fn identity(op: Op) -> Opt[i64] {
    return match op {
        Add, Or, Xor => Some(0)
        Mul => Some(1)
        And => Some(-1)
        _ => None
    }
}

fn tre_run(f: *Func, fid: i64) -> bool {
    if f.rets.len > 1 {
        return false
    }
    // locals whose address is observable would be shared between iterations
    for v in f.blocks[0].insts {
        if f.insts[v].op == Alloca {
            return false
        }
    }
    uses := f.use_counts()
    rpo := f.rpo()
    sites := vec[Site]()
    acc_op: Opt[Op] = None
    for b in rpo {
        rv := match f.blocks[b].term {
            Ret(vs) => clone(vs)
            _ => continue
        }
        insts := &f.blocks[b].insts
        if insts.is_empty() {
            continue
        }
        n := insts.len
        last_v := i64(insts[n - 1])
        li := &f.insts[last_v]
        // plain tail call: [call; ret call] or [call; ret] for no result
        if li.op == Call && li.k == fid && ((rv.is_empty() && f.rets.is_empty()) || (rv.len == 1 && rv[0] == last_v && uses[last_v] == 1)) {
            sites.push(Site{block: b, call: last_v, acc: None})
            continue
        }
        // accumulator form: [call; r = op(x, call); ret r] with the call right before
        if rv.len == 1 && rv[0] == last_v && n >= 2 && uses[last_v] == 1 && li.ty.is_int() {
            if is_some(identity(li.op)) {
                call := i64(insts[n - 2])
                ci := &f.insts[call]
                if ci.op == Call && ci.k == fid && uses[call] == 1 && contains(li.args, call) {
                    x := if li.args[0] == call { li.args[1] } else { li.args[0] }
                    if x != call && (acc_op == None || acc_op == Some(li.op)) {
                        acc_op = Some(li.op)
                        sites.push(Site{block: b, call: call, acc: Some((last_v, x))})
                    }
                }
            }
        }
    }
    if sites.is_empty() {
        return false
    }
    // all sites must agree: with an accumulator, plain tail calls are fine too (acc unchanged)
    ret_ty := if f.rets.is_empty() { Void } else { f.rets[0] }
    // split the entry: parameters stay, the body moves to a loop header
    header := f.new_block()
    entry_insts := f.blocks[0].insts
    f.blocks[0].insts = vec[i32]()
    params := vec[i64]()
    keep := vec[i32]()
    moved := vec[i32]()
    for v in entry_insts {
        if f.insts[v].op == Param {
            params.push(i64(v))
            keep.push(v)
        } else {
            moved.push(v)
        }
    }
    f.blocks[0].insts = keep
    entry_term := f.blocks[0].term
    f.blocks[0].term = Jmp(header)
    f.blocks[header].term = entry_term
    // successors of the old entry now come from the header
    for s in f.succs(header) {
        f.phi_pred_replace(s, 0, header)
    }
    // sites located in the old entry block are now in the header
    for si in 0..sites.len {
        if sites[si].block == 0 {
            sites[si].block = header
        }
    }
    // parameter phis (one per declared parameter that has a Param instruction)
    pphi := vec[(i64, i64, i64)]() // (index, param value, phi)
    head := vec[i32]()
    for p in params {
        ty := f.insts[p].ty
        k := f.insts[p].k
        phi := f.mk_phi(ty, sites.len + 1)
        f.im(phi).phi_add(p, 0)
        head.push(i32(phi))
        pphi.push((k, p, phi))
    }
    acc_phi: Opt[i64] = None
    match acc_op {
        Some(op) => {
            idk := unwrap(identity(op))
            c := f.mk(Const, ret_ty, vec[i64](), ir_canon(ret_ty, idk))
            f.blocks[0].insts.push(i32(c))
            phi := f.mk_phi(ret_ty, sites.len + 1)
            f.im(phi).phi_add(c, 0)
            head.push(i32(phi))
            acc_phi = Some(phi)
        }
        None => {}
    }
    head.extend(moved.items())
    f.blocks[header].insts = head
    // uses of parameters become uses of the phis (except in the phis' own entry inputs)
    repl := vec_fill(f.insts.len, i32(NOV))
    for pp in pphi {
        repl[pp.1] = i32(pp.2)
    }
    f.apply_repl(&repl)
    for pp in pphi {
        i := f.im(pp.2)
        i.args[0] = pp.1
    }
    site_blocks := vec[i64]()
    for si in 0..sites.len {
        site_blocks.push(sites[si].block)
    }
    // rewrite the tail sites
    for si in 0..sites.len {
        s := &sites[si]
        b := s.block
        call_args := vec_of(f.insts[s.call].args)
        // new accumulator value
        new_acc: Opt[i64] = None
        match (acc_phi, s.acc) {
            (Some(ap), Some((comb, _))) => {
                // read the operand again: parameters have been replaced by the loop phis
                ci := &f.insts[comb]
                op := ci.op
                x := if ci.args[0] == s.call { ci.args[1] } else { ci.args[0] }
                nv := f.mk(op, ret_ty, vec_of([]i64{ap, x}), 0)
                new_acc = Some(nv)
            }
            (Some(ap), None) => new_acc = Some(ap)
            _ => {}
        }
        // drop the call (and the combining instruction)
        drop := match s.acc {
            Some((comb, _)) => vec_two(s.call, comb)
            None => vec_one(s.call)
        }
        f.blocks[b].insts.retain(drop, fn(drop: Vec[i64], v: i32) -> bool { !drop.contains(i64(v)) })
        match new_acc {
            Some(nv) if is_some(s.acc) => f.blocks[b].insts.push(i32(nv))
            _ => {}
        }
        f.blocks[b].term = Jmp(header)
        for pp in pphi {
            a := call_args[pp.0]
            f.im(pp.2).phi_add(a, b)
        }
        match (acc_phi, new_acc) {
            (Some(ap), Some(nv)) => {
                f.im(ap).phi_add(nv, b)
            }
            _ => {}
        }
    }
    // every other return folds the accumulator in
    match (acc_phi, acc_op) {
        (Some(ap), Some(op)) => {
            for bi in 0..f.blocks.len {
                if contains(&site_blocks, bi) {
                    continue
                }
                match f.blocks[bi].term {
                    Ret(vs) if vs.len == 1 => {
                        nv := f.push(bi, op, ret_ty, vec_of([]i64{ap, vs[0]}), 0)
                        f.blocks[bi].term = Ret(vec_of([]i64{nv}))
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    return true
}
