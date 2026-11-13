// Function inlining.

// does an instruction with this op count for the size of a function?
priv fn counts(o: Op) -> bool {
    return !(o == Const || o == FConst || o == Param || o == GAddr || o == FAddr || o == Alloca || o == Phi || o == Proj)
}

priv fn cost(f: *Func) -> i64 {
    n := 0
    for bi in 0..f.blocks.len {
        b := &f.blocks[bi]
        for v in b.insts {
            if counts(f.insts[v].op) {
                n += 1
            }
        }
        if b.term != Term.None {
            n += 1
        }
    }
    return n
}

// bmap[b]: the block must be present
priv fn bmap_at(bmap: *Vec[i64], b: i64) -> i64 {
    nb := bmap[b]
    assert nb != NOV, "inline: block not in map"
    return nb
}

// inline one call site: `call` (in block `cb`) to callee `g`. The uses of the call's results
// are not rewritten here: `repl` gets their replacements (applied once by inline_run; a value
// taken from the caller is looked up in it). Returns by how much cost(f) grew.
priv fn inline_call(f: *Func, cb: i64, call: i64, g: *Func, repl: *Vec[i32], returns: *bool) -> i64 {
    pos := index_of(f.blocks[cb].insts.items(), i32(call))
    assert pos >= 0
    call_inst := clone(f.insts[call])
    // the call goes, the continuation block gets a terminator
    grown := 0
    // split the block
    cont := f.new_block()
    tail := vec_of(f.blocks[cb].insts[pos + 1..f.blocks[cb].insts.len])
    f.blocks[cb].insts.len = pos + 1
    f.blocks[cb].insts.pop()
    f.blocks[cont].insts = tail
    old_term := f.blocks[cb].term
    f.blocks[cb].term = Term.None
    f.blocks[cont].term = old_term
    ss := f.succs(cont)
    for s in ss {
        for ii in 0..f.blocks[s].insts.len {
            v := f.blocks[s].insts[ii]
            if f.insts[v].op != Phi {
                break
            }
            pbs := f.insts[v].from()
            for k in 0..pbs.len {
                if pbs[k] == cb {
                    pbs[k] = cont
                }
            }
        }
    }
    // clone callee
    grpo := g.rpo()
    // bmap[gb]: the copy of callee block gb (NOV: unreachable in the callee)
    bmap := vec_fill(g.blocks.len, NOV)
    for gb in grpo {
        bmap[gb] = f.new_block()
    }
    vmap := vec_fill(g.insts.len, NOV)
    for gb in grpo {
        for gv in g.blocks[gb].insts {
            gi := &g.insts[gv]
            if gi.op == Param {
                vmap[gv] = repl_find(repl.items(), call_inst.args[gi.k])
                continue
            }
            nv := f.mk(gi.op, gi.ty, vec[i64](), gi.k)
            f.im(nv).aux = gi.aux
            vmap[gv] = nv
        }
    }
    rets := vec[(i64, Vec[i64])]()
    allocas := vec[i32]()
    for gb in grpo {
        nb := bmap[gb]
        for gv in g.blocks[gb].insts {
            gi := &g.insts[gv]
            if gi.op == Param {
                continue
            }
            nv := vmap[gv]
            n := gi.args.len
            if gi.op == Phi {
                // drop phi inputs from blocks that were unreachable in the callee
                a2 := vec[i64]()
                p2 := vec[i64]()
                gfrom := gi.from()
                for k in 0..n {
                    p := bmap[gfrom[k]]
                    if p != 0xFFFFFFFF {
                        a2.push(vmap[gi.args[k]])
                        p2.push(p)
                    }
                }
                f.im(nv).phi_set(a2.items(), p2.items())
            } else if n > 0 {
                args := mkslice[i64](__alloc_raw(n * 8), n)
                for k in 0..n {
                    args[k] = vmap[gi.args[k]]
                }
                f.im(nv).args = args
            }
            if gi.op == Alloca {
                allocas.push(i32(nv))
            } else {
                f.blocks[nb].insts.push(i32(nv))
                if counts(gi.op) {
                    grown += 1
                }
            }
        }
        grown += 1
        match g.blocks[gb].term {
            Jmp(t) => f.blocks[nb].term = Jmp(bmap_at(&bmap, t))
            Br(c, t, e) => f.blocks[nb].term = Br(vmap[c], bmap_at(&bmap, t), bmap_at(&bmap, e))
            Ret(vs) => {
                rv := vec[i64]()
                for v in vs {
                    rv.push(vmap[v])
                }
                rets.push((nb, rv))
                f.blocks[nb].term = Jmp(cont)
            }
            Trap, Term.None => f.blocks[nb].term = Trap
        }
    }
    // allocas live in the caller's entry block
    if !allocas.is_empty() {
        e := allocas
        e.extend(f.blocks[0].insts.items())
        f.blocks[0].insts = e
    }
    f.blocks[cb].term = Jmp(bmap_at(&bmap, 0))
    *returns = !rets.is_empty()
    // results
    nrets := g.rets.len
    results := vec[i64]()
    for k in 0..nrets {
        rt := g.rets[k]
        if rets.is_empty() {
            // callee never returns: any value will do
            z := 0
            if rt.is_fp() {
                z = f.mk(FConst, rt, vec[i64](), 0)
            } else {
                z = f.mk(Const, rt, vec[i64](), 0)
            }
            f.blocks[0].insts.insert(0, i32(z))
            results.push(z)
        } else if rets.len == 1 {
            results.push(rets[0].1[k])
        } else {
            vals := vec[i64]()
            for ri in 0..rets.len {
                vals.push(rets[ri].1[k])
            }
            pbs := vec[i64]()
            for ri in 0..rets.len {
                pbs.push(rets[ri].0)
            }
            phi := f.mk_phi_of(rt, vals.items(), pbs.items())
            f.blocks[cont].insts.insert(k, i32(phi))
            results.push(phi)
        }
    }
    if repl.len < f.insts.len {
        repl.resize(f.insts.len, NOV)
    }
    if nrets == 1 {
        repl[call] = i32(results[0])
    } else if nrets > 1 {
        // projections of the call
        for b in 0..f.blocks.len {
            for ii in 0..f.blocks[b].insts.len {
                v := f.blocks[b].insts[ii]
                i := &f.insts[v]
                if i.op == Proj && i.args[0] == call {
                    repl[v] = i32(results[i.k])
                }
            }
        }
        for b in 0..f.blocks.len {
            blk := &f.blocks[b]
            n := 0
            for ii in 0..blk.insts.len {
                v := blk.insts[ii]
                if !(f.insts[v].op == Proj && f.insts[v].args[0] == call) {
                    blk.insts[n] = v
                    n += 1
                }
            }
            blk.insts.len = n
        }
    }
    return grown
}

struct Policy {
    small: i64,
    hinted: i64,
    single_site: i64,
    max_caller: i64,
}

// The reverse postorder after inlining a call in block cb = rpo[at] when the callee returns:
// the blocks from nb0 on are new, nb0 is the continuation (it got cb's successors), the others
// are the callee's copy, entered from cb and left only to the continuation. The depth-first
// search reaches everything outside cb's subtree as before (see inline_run), and inside it
// the copy, where reaching the continuation explores cb's old subtree X exactly as before.
// When the continuation is the first block of the copy to finish (C = the copy's blocks that
// finish after it, in finishing order), the new order is
//   rpo[..=at] ++ reverse(C) ++ [cont] ++ rpo[at + 1..]
// (X comes right after cb in the old order, the rest after X). Otherwise false.
priv fn rpo_after_inline(f: *Func, rpo: *Vec[i64], at: i64, nb0: i64) -> (Vec[i64], bool) {
    cb := rpo[at]
    entry := match f.blocks[cb].term {
        Jmp(e) => e
        _ => return (vec[i64](), false)
    }
    n := f.blocks.len - nb0
    seen := alloc[bool](n)
    post := vec[i64]()
    // the search of rpo_compute over the new blocks, the continuation taken as a leaf
    sb := vec_one(entry)
    si := vec_one(0)
    seen[entry - nb0] = true
    while sb.len > 0 {
        b := sb[sb.len - 1]
        i := si[si.len - 1]
        cnt, s0, s1 := f.succ_pair(b)
        if b == nb0 {
            cnt = 0
        }
        if i < cnt {
            s := s0
            if i == 1 {
                s = s1
            }
            si[si.len - 1] = i + 1
            if s < nb0 || s >= f.blocks.len {
                // (cannot happen: the copy only goes to itself and the continuation)
                return (vec[i64](), false)
            }
            if !seen[s - nb0] {
                seen[s - nb0] = true
                sb.push(s)
                si.push(0)
            }
        } else {
            post.push(b)
            sb.pop()
            si.pop()
        }
    }
    if post.len == 0 || post[0] != nb0 {
        return (vec[i64](), false)
    }
    out := vec[i64]()
    out.reserve(rpo.len + post.len)
    out.extend(rpo.buf[..at + 1])
    k := post.len - 1
    while k >= 1 {
        out.push(post[k])
        k -= 1
    }
    out.push(nb0)
    out.extend(rpo.buf[at + 1..rpo.len])
    return (out, true)
}

// inline eligible calls in function `fid`; `done[g]` marks callees that are final;
// `costs[g]` is cost(g) once known (-1 before: a final function does not change)
fn inline_run(m: *Module, fid: i64, done: []bool, call_counts: []i64, addr_taken: []bool, pol: *Policy, costs: []i64) -> bool {
    any := false
    budget := 400
    // replacements of the results of inlined calls, applied at the end
    repl := vec[i32]()
    caller_size := cost(&m.funcs[fid])
    // Where the search for the next call can start in the reverse postorder. Whether a call
    // can be inlined depends only on its callee. The blocks before the block of the call just
    // inlined had none; inlining changes only the successors of that block (and adds blocks
    // reachable through it alone), so the depth-first search reaches the same blocks in the
    // same order before it: they keep their places, and keep having no such call (block 0 only
    // gains allocas and constants). Unless the callee never returns, the blocks after the call
    // are still reached through it.
    start := 0
    // the reverse postorder of f, kept up to date (see rpo_after_inline) or made anew
    frpo := vec[i64]()
    fresh := true
    loop {
        if budget == 0 {
            break
        }
        if caller_size > pol.max_caller {
            break
        }
        // find the next inlinable call
        found: Opt[(i64, i64, i64)] = None
        {
            f := &m.funcs[fid]
            // (the CFG changes with every inlined call: no use for the memo)
            if fresh {
                frpo = f.rpo_compute()
                fresh = false
            }
            search: for ri in start..frpo.len {
                b := frpo[ri]
                for v in f.blocks[b].insts {
                    i := &f.insts[v]
                    if i.op != Call {
                        continue
                    }
                    g := i.k
                    if g == fid || !done[g] {
                        continue
                    }
                    gf := &m.funcs[g]
                    if gf.inl < 0 || gf.noreturn || !gf.lowered {
                        continue
                    }
                    if costs[g] < 0 {
                        costs[g] = cost(gf)
                    }
                    size := costs[g]
                    limit := 0
                    if gf.inl > 0 {
                        limit = pol.hinted
                    } else if call_counts[g] == 1 && !addr_taken[g] {
                        limit = pol.single_site
                    } else {
                        limit = pol.small
                    }
                    if size <= limit {
                        found = Some((b, i64(v), g))
                        start = ri
                        break search
                    }
                }
            }
        }
        match found {
            Some(x) => {
                // g is not f and inline_call only changes f
                returns := false
                nb0 := m.funcs[fid].blocks.len
                caller_size += inline_call(&m.funcs[fid], x.0, x.1, &m.funcs[x.2], &repl, &returns)
                if !returns {
                    // the blocks after the call became unreachable through it: they may now
                    // be reached later, before the call's block
                    start = 0
                    fresh = true
                } else {
                    upd, ok := rpo_after_inline(&m.funcs[fid], &frpo, start, nb0)
                    if ok {
                        frpo = upd
                    } else {
                        fresh = true
                    }
                }
                any = true
                budget -= 1
            }
            None => break
        }
    }
    if any {
        m.funcs[fid].apply_repl(&repl)
    }
    return any
}
