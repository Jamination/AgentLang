// Tail-recursion elimination, including the accumulator form
//     return x + f(args)        (also *, &, |, ^ on integers)
// which becomes a loop that carries the pending operation in an accumulator.

struct TreSite {
    block i64,
    call i64,
    // accumulator form: (combining instruction, the other operand)
    acc Opt[(i64, i64)],
}

fn tre_identity(op Op) Opt[i64] {
    if op == OpAdd || op == OpOr || op == OpXor {
        return Some(0)
    }
    if op == OpMul {
        return Some(1)
    }
    if op == OpAnd {
        return Some(-1)
    }
    return None
}

// acc_op.is_none() || acc_op == Some(op)
fn tre_none_or_same(acc_op Opt[Op], op Op) bool {
    match acc_op {
        Some(o) => return o == op
        None => {}
    }
    return true
}

fn tre_run(f *Func, fid i64) bool {
    if f.rets.len > 1 {
        return false
    }
    // locals whose address is observable would be shared between iterations
    for v in f.blocks.buf[0].insts.items() {
        if f.insts.buf[v].op == OpAlloca {
            return false
        }
    }
    uses := f.use_counts()
    rpo := f.rpo()
    sites := vec[TreSite]()
    var acc_op Opt[Op] = None
    for b in rpo.items() {
        rv := vec[i64]()
        match f.blocks.buf[b].term {
            TermRet(vs) => rv = clone(vs)
            _ => continue
        }
        insts := &f.blocks.buf[b].insts
        if insts.is_empty() {
            continue
        }
        n := insts.len
        last_v := insts.buf[n - 1]
        li := &f.insts.buf[last_v]
        // plain tail call: [call; ret call] or [call; ret] for no result
        if li.op == OpCall && li.k == fid && ((rv.is_empty() && f.rets.is_empty()) || (rv.len == 1 && rv.buf[0] == last_v && uses.buf[last_v] == 1)) {
            sites.push(TreSite{block: b, call: last_v, acc: None})
            continue
        }
        // accumulator form: [call; r = op(x, call); ret r] with the call right before
        if rv.len == 1 && rv.buf[0] == last_v && n >= 2 && uses.buf[last_v] == 1 && li.ty.is_int() {
            if is_some(tre_identity(li.op)) {
                call := insts.buf[n - 2]
                ci := &f.insts.buf[call]
                if ci.op == OpCall && ci.k == fid && uses.buf[call] == 1 && contains(&li.args, call) {
                    x := if li.args.buf[0] == call { li.args.buf[1] } else { li.args.buf[0] }
                    if x != call && tre_none_or_same(acc_op, li.op) {
                        acc_op = Some(li.op)
                        sites.push(TreSite{block: b, call: call, acc: Some((last_v, x))})
                    }
                }
            }
        }
    }
    if sites.is_empty() {
        return false
    }
    // all sites must agree: with an accumulator, plain tail calls are fine too (acc unchanged)
    ret_ty := TVoid
    if f.rets.len > 0 {
        ret_ty = f.rets.buf[0]
    }
    // split the entry: parameters stay, the body moves to a loop header
    header := f.new_block()
    entry_insts := f.blocks.buf[0].insts
    f.blocks.buf[0].insts = vec[i64]()
    params := vec[i64]()
    keep := vec[i64]()
    moved := vec[i64]()
    for v in entry_insts.items() {
        if f.insts.buf[v].op == OpParam {
            params.push(v)
            keep.push(v)
        } else {
            moved.push(v)
        }
    }
    f.blocks.buf[0].insts = keep
    entry_term := f.blocks.buf[0].term
    f.blocks.buf[0].term = TermJmp(header)
    f.blocks.buf[header].term = entry_term
    // successors of the old entry now come from the header
    ss := f.succs(header)
    for s in ss.items() {
        for ii in 0..f.blocks.buf[s].insts.len {
            v := f.blocks.buf[s].insts.buf[ii]
            if f.insts.buf[v].op != OpPhi {
                break
            }
            pbs := &f.insts.buf[v].pb
            for k in 0..pbs.len {
                if pbs.buf[k] == 0 {
                    pbs.buf[k] = header
                }
            }
        }
    }
    // sites located in the old entry block are now in the header
    for si in 0..sites.len {
        if sites.buf[si].block == 0 {
            sites.buf[si].block = header
        }
    }
    // parameter phis (one per declared parameter that has a Param instruction)
    pphi := vec[(i64, i64, i64)]() // (index, param value, phi)
    head := vec[i64]()
    for p in params.items() {
        ty := f.insts.buf[p].ty
        k := f.insts.buf[p].k
        phi := f.mk(OpPhi, ty, vec_of([]i64{p}), 0)
        f.im(phi).pb = vec_of([]i64{0})
        head.push(phi)
        pphi.push((k, p, phi))
    }
    var acc_phi Opt[i64] = None
    match acc_op {
        Some(op) => {
            idk := 0
            match tre_identity(op) {
                Some(x) => idk = x
                None => panic("called `Option::unwrap()` on a `None` value")
            }
            c := f.mk(OpConst, ret_ty, vec[i64](), ir_canon(ret_ty, idk))
            f.blocks.buf[0].insts.push(c)
            phi := f.mk(OpPhi, ret_ty, vec_of([]i64{c}), 0)
            f.im(phi).pb = vec_of([]i64{0})
            head.push(phi)
            acc_phi = Some(phi)
        }
        None => {}
    }
    head.extend(moved.items())
    f.blocks.buf[header].insts = head
    // uses of parameters become uses of the phis (except in the phis' own entry inputs)
    repl := vec_fill(f.insts.len, NOV)
    for pp in pphi.items() {
        repl.buf[pp.1] = pp.2
    }
    f.apply_repl(&repl)
    for pp in pphi.items() {
        i := f.im(pp.2)
        i.args.buf[0] = pp.1
    }
    site_blocks := vec[i64]()
    for si in 0..sites.len {
        site_blocks.push(sites.buf[si].block)
    }
    // rewrite the tail sites
    for si in 0..sites.len {
        s := &sites.buf[si]
        b := s.block
        call_args := clone(&f.insts.buf[s.call].args)
        // new accumulator value
        var new_acc Opt[i64] = None
        match acc_phi {
            Some(ap) => {
                match s.acc {
                    Some(cx) => {
                        // read the operand again: parameters have been replaced by the loop phis
                        ci := &f.insts.buf[cx.0]
                        op := ci.op
                        x := if ci.args.buf[0] == s.call { ci.args.buf[1] } else { ci.args.buf[0] }
                        nv := f.mk(op, ret_ty, vec_of([]i64{ap, x}), 0)
                        new_acc = Some(nv)
                    }
                    None => new_acc = Some(ap)
                }
            }
            None => {}
        }
        // drop the call (and the combining instruction)
        drop := vec[i64]()
        match s.acc {
            Some(cx) => {
                drop.push(s.call)
                drop.push(cx.0)
            }
            None => drop.push(s.call)
        }
        blk := &f.blocks.buf[b]
        n := 0
        for ii in 0..blk.insts.len {
            v := blk.insts.buf[ii]
            if !contains(&drop, v) {
                blk.insts.buf[n] = v
                n += 1
            }
        }
        blk.insts.len = n
        match new_acc {
            Some(nv) => {
                if is_some(s.acc) {
                    f.blocks.buf[b].insts.push(nv)
                }
            }
            None => {}
        }
        f.blocks.buf[b].term = TermJmp(header)
        for pp in pphi.items() {
            a := call_args.at(pp.0)
            i := f.im(pp.2)
            i.args.push(a)
            i.pb.push(b)
        }
        match acc_phi {
            Some(ap) => {
                match new_acc {
                    Some(nv) => {
                        i := f.im(ap)
                        i.args.push(nv)
                        i.pb.push(b)
                    }
                    None => {}
                }
            }
            None => {}
        }
    }
    // every other return folds the accumulator in
    match acc_phi {
        Some(ap) => {
            match acc_op {
                Some(op) => {
                    for bi in 0..f.blocks.len {
                        if contains(&site_blocks, bi) {
                            continue
                        }
                        match f.blocks.buf[bi].term {
                            TermRet(vs) => {
                                if vs.len == 1 {
                                    nv := f.push(bi, op, ret_ty, vec_of([]i64{ap, vs.buf[0]}), 0)
                                    f.blocks.buf[bi].term = TermRet(vec_of([]i64{nv}))
                                }
                            }
                            _ => {}
                        }
                    }
                }
                None => {}
            }
        }
        None => {}
    }
    return true
}
