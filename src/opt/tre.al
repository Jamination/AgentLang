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

// The values block b returns: those of its own `ret`, or of a `ret` reached through jumps to
// blocks that hold only phis (the join of an if expression), looked up through those phis;
// also the block b jumps to (-1 for its own `ret`). False if neither.
priv fn ret_through(f: *Func, b: i64) -> (Vec[i64], i64, bool) {
    fail := (vec[i64](), -1, false)
    chain := vec_one(b)
    for depth in 0..4 {
        cur := chain.last()
        match f.blocks[cur].term {
            Ret(vs) => {
                if chain.len == 1 {
                    return (clone(vs), -1, true)
                }
                rv := clone(vs)
                for k in 0..rv.len {
                    v := rv[k]
                    for i in chain.len - 1..=1 by -1 {
                        if f.insts[v].op == Phi && contains(f.blocks[chain[i]].insts.items(), i32(v)) {
                            v = f.insts[v].phi_input(chain[i - 1])
                            if v == NOV {
                                return fail
                            }
                        }
                    }
                    rv[k] = v
                }
                return (rv, chain[1], true)
            }
            Jmp(t) => {
                if contains(&chain, t) {
                    return fail
                }
                for v in f.blocks[t].insts {
                    if f.insts[v].op != Phi {
                        return fail
                    }
                }
                chain.push(t)
            }
            _ => return fail
        }
    }
    return fail
}

// Can a local be shared between the iterations of the loop? Only when the function touches it
// in a block from which no tail call is reached (that iteration is the last, the earlier ones
// never saw it), such as the failure path of a check.
priv fn allocas_private(f: *Func, sites: *Vec[Site]) -> bool {
    has := false
    for v in f.blocks[0].insts {
        if f.insts[v].op == Alloca {
            has = true
        }
    }
    if !has {
        return true
    }
    // the blocks that reach a tail call
    preds := f.preds()
    reach := vec_fill(f.blocks.len, false)
    work := vec[i64]()
    for s in sites.items() {
        if !reach[s.block] {
            reach[s.block] = true
            work.push(s.block)
        }
    }
    while !work.is_empty() {
        b := work.pop()
        for p in preds[b] {
            if !reach[p] {
                reach[p] = true
                work.push(p)
            }
        }
    }
    for b in 0..f.blocks.len {
        if !reach[b] {
            continue
        }
        for v in f.blocks[b].insts {
            for a in f.insts[v].args {
                if f.insts[a].op == Alloca {
                    return false
                }
            }
        }
        match f.blocks[b].term {
            Ret(vs) => {
                for a in vs {
                    if f.insts[a].op == Alloca {
                        return false
                    }
                }
            }
            Br(c, _, _) => {
                if f.insts[c].op == Alloca {
                    return false
                }
            }
            Switch(c, _) => {
                if f.insts[c].op == Alloca {
                    return false
                }
            }
            _ => {}
        }
    }
    return true
}

fn tre_run(f: *Func, fid: i64) -> bool {
    if f.rets.len > 1 {
        return false
    }
    uses := f.use_counts()
    rpo := f.rpo()
    sites := vec[Site]()
    // the join block a site returns through (parallel to sites; -1: its own `ret`)
    joins := vec[i64]()
    acc_op: Opt[Op] = None
    for b in rpo {
        rv, join, ok := ret_through(f, b)
        if !ok {
            continue
        }
        nsites := sites.len
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
            joins.push(join)
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
        if sites.len > nsites {
            joins.push(join)
        }
    }
    if sites.is_empty() {
        return false
    }
    // locals whose address is observable would be shared between iterations
    if !allocas_private(f, &sites) {
        return false
    }
    // a site that returns through a join returns by itself now (its inputs leave the join's phis)
    for si in 0..sites.len {
        j := joins[si]
        if j < 0 {
            continue
        }
        b := sites[si].block
        rv, _, _ := ret_through(f, b)
        for v in f.blocks[j].insts {
            k := index_of(f.insts[v].from(), b)
            if k >= 0 {
                f.im(i64(v)).phi_remove(k)
            }
        }
        f.blocks[b].term = Ret(rv)
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
        } else if f.insts[v].op == Alloca {
            // (locals stay in the entry block)
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

// ---------- sibling calls (for the back ends) ----------
// The call of block b that the back end may make a jump to the callee after the epilogue, and
// the arguments it passes (without an indirect call's target); (-1, nil) if none. It is the
// block's last instruction (but for its projections), and the block returns exactly its results
// (by its own `ret`, or the `ret` of a join that holds only phis); the callee is an AL function
// (an indirect call with the AL convention, not a C function from its import slot: the traces
// through C code show the AL frame that called it), and the function has no locals in its frame
// (whose address the callee could hold: also the copies of aggregates passed or returned by
// address). Not at -O0 or with -g, where every frame of the calls stays in backtraces and
// debuggers. The back end checks that the arguments fit in registers.
fn tre_sibling_call(m: *Module, f: *Func, b: i64) -> (i64, []i64) {
    none: (i64, []i64) = (-1, nil)
    if dbg_on || opt_deferred() {
        return none
    }
    vals := match f.blocks[b].term {
        Ret(vs) => vs
        Jmp(j) => {
            rv := match f.blocks[j].term {
                Ret(vs) => clone(vs)
                _ => return none
            }
            for x in f.blocks[j].insts {
                if f.insts[x].op != Phi {
                    return none
                }
            }
            for k in 0..rv.len {
                if f.insts[rv[k]].op == Phi && contains(f.blocks[j].insts.items(), i32(rv[k])) {
                    rv[k] = f.insts[rv[k]].phi_input(b)
                }
            }
            rv
        }
        _ => return none
    }
    ins := &f.blocks[b].insts
    k := ins.len - 1
    while k >= 0 && f.insts[ins[k]].op == Proj {
        k -= 1
    }
    if k < 0 {
        return none
    }
    v := i64(ins[k])
    i := &f.insts[v]
    args := i.args
    nrets := 0
    if i.op == Call {
        g := &m.funcs[i.k]
        if g.ext != None {
            return none
        }
        nrets = g.rets.len
    } else if i.op == CallInd && i.aux == 0 {
        t := &f.insts[i.args[0]]
        if t.op == Load && f.insts[t.args[0]].op == GAddr && starts_with(m.globals[f.insts[t.args[0]].k].name, "got.") {
            return none
        }
        args = args[1..]
        nrets = if i.ty == Void { 0 } else { 1 }
    } else {
        return none
    }
    for x in ins[k + 1..] {
        if f.insts[x].args[0] != v {
            return none
        }
    }
    // the results, in the order the callee returns them
    if i.ty != Void {
        if !(nrets == 1 && vals.len == 1 && vals[0] == v) {
            return none
        }
    } else {
        if vals.len != nrets {
            return none
        }
        for j in 0..nrets {
            x := &f.insts[vals[j]]
            if x.op != Proj || x.args[0] != v || x.k != j {
                return none
            }
        }
    }
    for bi in 0..f.blocks.len {
        for x in f.blocks[bi].insts {
            if f.insts[x].op == Alloca {
                return none
            }
        }
    }
    return (v, args)
}
