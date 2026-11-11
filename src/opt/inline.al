// Function inlining.

fn inline_cost(f: *Func) -> i64 {
    n := 0
    for bi in 0..f.blocks.len {
        b := &f.blocks[bi]
        for v in b.insts.items() {
            o := f.insts[v].op
            if !(o == OpConst || o == OpFConst || o == OpParam || o == OpGAddr || o == OpFAddr || o == OpAlloca || o == OpPhi || o == OpProj) {
                n += 1
            }
        }
        if !eq(b.term, TermNone) {
            n += 1
        }
    }
    return n
}

// bmap[&b]: the block must be present
fn inline_bmap_at(bmap: *Map[i64, i64], b: i64) -> i64 {
    nb, found := bmap.get(b)
    assert found, "inline: block not in map"
    return nb
}

// inline one call site: `call` (in block `cb`) to callee `g`
fn inline_inline_call(f: *Func, cb: i64, call: i64, g: *Func) {
    pos := index_of(f.blocks[cb].insts.items(), call)
    assert pos >= 0
    call_inst := clone(&f.insts[call])
    // split the block
    cont := f.new_block()
    tail := vec_of(f.blocks[cb].insts[pos + 1..f.blocks[cb].insts.len])
    f.blocks[cb].insts.len = pos + 1
    f.blocks[cb].insts.pop()
    f.blocks[cont].insts = tail
    old_term := f.blocks[cb].term
    f.blocks[cb].term = TermNone
    f.blocks[cont].term = old_term
    ss := f.succs(cont)
    for s in ss.items() {
        for ii in 0..f.blocks[s].insts.len {
            v := f.blocks[s].insts[ii]
            if f.insts[v].op != OpPhi {
                break
            }
            pbs := &f.insts[v].pb
            for k in 0..pbs.len {
                if pbs[k] == cb {
                    pbs[k] = cont
                }
            }
        }
    }
    // clone callee
    grpo := g.rpo()
    bmap := map[i64, i64]()
    for gb in grpo.items() {
        bmap.set(gb, f.new_block())
    }
    vmap := vec_fill(g.insts.len, NOV)
    for gb in grpo.items() {
        for gv in g.blocks[gb].insts.items() {
            gi := &g.insts[gv]
            if gi.op == OpParam {
                vmap[gv] = call_inst.args[gi.k]
                continue
            }
            nv := f.mk(gi.op, gi.ty, vec[i64](), gi.k)
            f.im(nv).aux = gi.aux
            vmap[gv] = nv
        }
    }
    rets := vec[(i64, Vec[i64])]()
    allocas := vec[i64]()
    for gb in grpo.items() {
        nb := inline_bmap_at(&bmap, gb)
        for gv in g.blocks[gb].insts.items() {
            gi := &g.insts[gv]
            if gi.op == OpParam {
                continue
            }
            nv := vmap[gv]
            args := vec[i64]()
            for a in gi.args.items() {
                args.push(vmap[a])
            }
            pb := vec[i64]()
            for p in gi.pb.items() {
                pb.push(bmap.get_or(p, 0xFFFFFFFF))
            }
            // drop phi inputs from blocks that were unreachable in the callee
            if gi.op == OpPhi && contains(&pb, 0xFFFFFFFF) {
                a2 := vec[i64]()
                p2 := vec[i64]()
                for k in 0..pb.len {
                    if pb[k] != 0xFFFFFFFF {
                        a2.push(args[k])
                        p2.push(pb[k])
                    }
                }
                f.im(nv).args = a2
                f.im(nv).pb = p2
            } else {
                f.im(nv).args = args
                f.im(nv).pb = pb
            }
            if gi.op == OpAlloca {
                allocas.push(nv)
            } else {
                f.blocks[nb].insts.push(nv)
            }
        }
        match g.blocks[gb].term {
            TermJmp(t) => f.blocks[nb].term = TermJmp(inline_bmap_at(&bmap, t))
            TermBr(c, t, e) => f.blocks[nb].term = TermBr(vmap[c], inline_bmap_at(&bmap, t), inline_bmap_at(&bmap, e))
            TermRet(vs) => {
                rv := vec[i64]()
                for v in vs.items() {
                    rv.push(vmap[v])
                }
                rets.push((nb, rv))
                f.blocks[nb].term = TermJmp(cont)
            }
            TermTrap => f.blocks[nb].term = TermTrap
            TermNone => f.blocks[nb].term = TermTrap
        }
    }
    // allocas live in the caller's entry block
    if !allocas.is_empty() {
        e := allocas
        e.extend(f.blocks[0].insts.items())
        f.blocks[0].insts = e
    }
    f.blocks[cb].term = TermJmp(inline_bmap_at(&bmap, 0))
    // results
    nrets := g.rets.len
    results := vec[i64]()
    for k in 0..nrets {
        rt := g.rets[k]
        if rets.is_empty() {
            // callee never returns: any value will do
            z := 0
            if rt.is_fp() {
                z = f.mk(OpFConst, rt, vec[i64](), 0)
            } else {
                z = f.mk(OpConst, rt, vec[i64](), 0)
            }
            f.blocks[0].insts.insert(0, z)
            results.push(z)
        } else if rets.len == 1 {
            results.push(rets[0].1.at(k))
        } else {
            vals := vec[i64]()
            for ri in 0..rets.len {
                vals.push(rets[ri].1.at(k))
            }
            phi := f.mk(OpPhi, rt, vals, 0)
            pbs := vec[i64]()
            for ri in 0..rets.len {
                pbs.push(rets[ri].0)
            }
            f.im(phi).pb = pbs
            f.blocks[cont].insts.insert(k, phi)
            results.push(phi)
        }
    }
    repl := vec_fill(f.insts.len, NOV)
    if nrets == 1 {
        repl[call] = results[0]
    } else if nrets > 1 {
        // projections of the call
        for b in 0..f.blocks.len {
            for ii in 0..f.blocks[b].insts.len {
                v := f.blocks[b].insts[ii]
                i := &f.insts[v]
                if i.op == OpProj && i.args[0] == call {
                    repl[v] = results.at(i.k)
                }
            }
        }
        for b in 0..f.blocks.len {
            blk := &f.blocks[b]
            n := 0
            for ii in 0..blk.insts.len {
                v := blk.insts[ii]
                if repl[v] == NOV {
                    blk.insts[n] = v
                    n += 1
                }
            }
            blk.insts.len = n
        }
    }
    f.apply_repl(&repl)
}

struct Policy {
    small: i64,
    hinted: i64,
    single_site: i64,
    max_caller: i64,
}

// inline eligible calls in function `fid`; `done[g]` marks callees that are final
fn inline_run(m: *Module, fid: i64, done: []bool, call_counts: []i64, addr_taken: []bool, pol: *Policy) -> bool {
    any := false
    budget := 400
    sizes := map[i64, i64]()
    loop {
        if budget == 0 {
            break
        }
        caller_size := inline_cost(&m.funcs[fid])
        if caller_size > pol.max_caller {
            break
        }
        // find the next inlinable call
        found: Opt[(i64, i64, i64)] = None
        {
            f := &m.funcs[fid]
            frpo := f.rpo()
            for b in frpo.items() {
                hit := false
                for v in f.blocks[b].insts.items() {
                    i := &f.insts[v]
                    if i.op != OpCall {
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
                    size, have := sizes.get(g)
                    if !have {
                        size = inline_cost(gf)
                        sizes.set(g, size)
                    }
                    limit := 0
                    if gf.inl > 0 {
                        limit = pol.hinted
                    } else if call_counts[g] == 1 && !addr_taken[g] {
                        limit = pol.single_site
                    } else {
                        limit = pol.small
                    }
                    if size <= limit {
                        found = Some((b, v, g))
                        hit = true
                        break
                    }
                }
                if hit {
                    break
                }
            }
        }
        match found {
            Some(x) => {
                gf := clone(&m.funcs[x.2])
                inline_inline_call(&m.funcs[fid], x.0, x.1, &gf)
                any = true
                budget -= 1
            }
            None => break
        }
    }
    return any
}
