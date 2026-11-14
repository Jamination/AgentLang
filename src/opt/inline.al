// Function inlining.

// does an instruction with this op count for the size of a function?
priv fn counts(o: Op) -> bool {
    return !(o == Const || o == FConst || o == Param || o == GAddr || o == FAddr || o == Alloca || o == Phi || o == Proj)
}

fn inline_cost(f: *Func) -> i64 {
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
// taken from the caller is looked up in it). The copies keep the callee's source locations,
// rebased onto the call's (`locs`). Returns by how much inline_cost(f) grew.
priv fn inline_call(f: *Func, cb: i64, call: i64, g: *Func, repl: *Vec[i32], returns: *bool, locs: *SrcLocs) -> i64 {
    pos := index_of(f.blocks[cb].insts.items(), i32(call))
    assert pos >= 0
    call_inst := clone(f.insts[call])
    // the call goes, the continuation block gets a terminator
    grown := 0
    // split the block
    cont := f.new_block()
    tail := vec_of(f.blocks[cb].insts[pos + 1..])
    f.blocks[cb].insts.truncate(pos)
    f.blocks[cont].insts = tail
    old_term := f.blocks[cb].term
    f.blocks[cb].term = Term.None
    f.blocks[cont].term = old_term
    for s in f.succs(cont) {
        f.phi_pred_replace(s, cb, cont)
    }
    // clone callee
    grpo := g.rpo()
    // bmap[gb]: the copy of callee block gb (NOV: unreachable in the callee)
    bmap := vec_fill(g.blocks.len, NOV)
    for gb in grpo {
        bmap[gb] = f.new_block()
    }
    vmap := vec_fill(g.insts.len, NOV)
    lmemo := map[i32, i32]()
    for gb in grpo {
        for gv in g.blocks[gb].insts {
            gi := &g.insts[gv]
            if gi.op == Param {
                vmap[gv] = repl_find(repl.items(), call_inst.args[gi.k])
                continue
            }
            nv := f.mk(gi.op, gi.ty, vec[i64](), gi.k)
            f.im(nv).aux = gi.aux
            if g.lib {
                // (library code: its frames are not shown, the call's line stands for it)
                f.im(nv).set_srcloc(call_inst.srcloc())
            } else if gi.srcloc() != 0 {
                l := locs.src_loc_inlined(gi.srcloc(), call_inst.srcloc(), &lmemo)
                f.im(nv).set_srcloc(l)
            }
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
                    if p != NOV {
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
            z := f.mk(if rt.is_fp() { FConst } else { Const }, rt, vec[i64](), 0)
            f.blocks[0].insts.insert(0, i32(z))
            results.push(z)
        } else if rets.len == 1 {
            results.push(rets[0].1[k])
        } else {
            vals := vec[i64]()
            pbs := vec[i64]()
            for r in rets {
                vals.push(r.1[k])
                pbs.push(r.0)
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
        // projections of the call: replaced, and dropped from their blocks
        for b in 0..f.blocks.len {
            blk := &f.blocks[b]
            n := 0
            for ii in 0..blk.insts.len {
                v := blk.insts[ii]
                i := &f.insts[v]
                if i.op == Proj && i.args[0] == call {
                    repl[v] = i32(results[i.k])
                } else {
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
    devirt: bool, // make indirect calls of known targets direct (ALC_DISABLE=devirt: no)
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
    while !sb.is_empty() {
        b := sb.last()
        i := si.last()
        cnt, s0, s1 := f.succ_pair(b)
        if b == nb0 {
            cnt = 0
        }
        if i < cnt {
            s := if i == 1 { s1 } else { s0 }
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
    if post.is_empty() || post[0] != nb0 {
        return (vec[i64](), false)
    }
    out := vec[i64]()
    out.reserve(rpo.len + post.len)
    out.extend(rpo[..at + 1])
    for k in post.len - 1..=1 by -1 {
        out.push(post[k])
    }
    out.push(nb0)
    out.extend(rpo[at + 1..])
    return (out, true)
}

// The function an indirect call `i` of f calls when its target is a known function: the value
// of a function's address (FAddr, after the replacements `repl` of inline_run), and the call
// passes and returns what that function takes and returns (a function value made with `cast`
// may not); -1 otherwise. A C function's address comes from its import slot, never FAddr; a
// call with the C convention (aux 1) is left alone anyway.
fn inline_known_target(m: *Module, f: *Func, i: *Inst, repl: []i32) -> i64 {
    if i.op != CallInd || i.aux != 0 {
        return -1
    }
    a := &f.insts[repl_find(repl, i.args[0])]
    if a.op != FAddr {
        return -1
    }
    g := &m.funcs[a.k]
    if g.ext != None || g.params.len != i.args.len - 1 {
        return -1
    }
    for p in 0..g.params.len {
        if f.insts[i.args[p + 1]].ty != g.params[p] {
            return -1
        }
    }
    rt := if g.rets.len == 1 { g.rets[0] } else { T.Void }
    return if i.ty == rt { a.k } else { -1 }
}

// makes the indirect call `i` a direct call of function t (inline_known_target)
priv fn make_direct(i: *Inst, t: i64) {
    i.op = Call
    i.k = t
    i.args = i.args[1..]
}

// Makes every indirect call of a known target in function fid direct (those the passes after
// inline_run exposed, or that it did not reach); true if there was one.
fn inline_devirt_all(m: *Module, fid: i64) -> bool {
    f := &m.funcs[fid]
    any := false
    for bi in 0..f.blocks.len {
        for v in f.blocks[bi].insts {
            i := &f.insts[v]
            if i.op == CallInd {
                t := inline_known_target(m, f, i, nil)
                if t >= 0 {
                    make_direct(i, t)
                    any = true
                }
            }
        }
    }
    return any
}

// inline eligible calls in function `fid`; `done[g]` marks callees that are final;
// `costs[g]` is inline_cost(g) once known (-1 before: a final function does not change).
// Returns whether a call was inlined, and whether an indirect call was made direct.
fn inline_run(m: *Module, fid: i64, done: []bool, call_counts: []i64, addr_taken: []bool, pol: *Policy, costs: []i64) -> (bool, bool) {
    any := false
    // a call through a function value was made direct
    devirt := false
    budget := 400
    // replacements of the results of inlined calls, applied at the end
    repl := vec[i32]()
    caller_size := inline_cost(&m.funcs[fid])
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
    while budget > 0 && caller_size <= pol.max_caller {
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
                    if i.op == CallInd && pol.devirt {
                        // a call through a known function value becomes a direct call (and
                        // may then be inlined below)
                        t := inline_known_target(m, f, i, repl.items())
                        if t < 0 {
                            continue
                        }
                        make_direct(i, t)
                        devirt = true
                    } else if i.op != Call {
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
                        costs[g] = inline_cost(gf)
                    }
                    size := costs[g]
                    limit := if gf.inl > 0 {
                        pol.hinted
                    } else if call_counts[g] == 1 && !addr_taken[g] {
                        pol.single_site
                    } else {
                        pol.small
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
            Some((b, call, g)) => {
                // g is not f and inline_call only changes f
                returns := false
                nb0 := m.funcs[fid].blocks.len
                caller_size += inline_call(&m.funcs[fid], b, call, &m.funcs[g], &repl, &returns, &m.locs)
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
    return (any, devirt)
}
