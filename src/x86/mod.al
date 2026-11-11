// The x86-64 backend driver: reachable functions, block layout, float constant pool.

struct Compiled {
    fid: i64
    code: Code
}

struct Output {
    funcs: Vec[Compiled]
    fpool: Vec[Bits128]
}

fn x86_reachable_funcs(m: *Module) -> Vec[i64] {
    seen := vec_fill(m.funcs.len, false)
    work := vec_of([]i64{m.entry})
    seen[m.entry] = true
    out := vec[i64]()
    while work.len > 0 {
        f := work.pop()
        out.push(f)
        func := &m.funcs[f]
        for bi in 0..func.blocks.len {
            for v in func.blocks[bi].insts.items() {
                i := &func.insts[v]
                if (i.op == OpCall || i.op == OpFAddr) && !seen[i.k] {
                    seen[i.k] = true
                    work.push(i.k)
                }
            }
        }
    }
    // function pointers stored in global data
    for gi in 0..m.globals.len {
        for rl in m.globals[gi].relocs.items() {
            t := rl.1
            match t {
                RelocTargetFunc(f) => {
                    if !seen[f] {
                        seen[f] = true
                        out.push(f)
                    }
                }
                _ => {}
            }
        }
    }
    sort(out.items())
    return out
}

fn x86_compile(m: *Module, dump_asm: bool) -> Output {
    fids := x86_reachable_funcs(m)
    fpool := vec[Bits128]()
    fpool_ix := map[Bits128, i64]()
    funcs := vec[Compiled]()
    for fid in fids.items() {
        f := &m.funcs[fid]
        // everything up to the machine code of this function is temporary (see work_begin)
        work_begin()
        cleanup_prune_unreachable(f)
        cleanup_trivial_phis(f)
        cleanup_dce(f)
        aliases := isel_split_critical_edges(f)
        cfg := cfg_new(f)
        loops := loops_new(f, &cfg)
        depths := vec[i64]()
        for b in 0..f.blocks.len {
            depths.push(loops.depth(b))
        }
        opt_trace("isel", f)
        mf := isel_select(f, m, depths.items(), aliases.items())
        layout := x86_block_layout(f)
        // optional (ALC_ALIGN=1): align the entry of innermost loops. Off by default: on the
        // benchmark suite the padding executed on every loop entry cost more than it gained.
        align_v, align_set := env_get("ALC_ALIGN")
        if align_set {
            for li in 0..loops.loops.len {
                innermost := true
                for oi in 0..loops.loops.len {
                    match loops.loops[oi].parent {
                        Some(p) => {
                            if oi != li && p == li {
                                innermost = false
                            }
                        }
                        None => {}
                    }
                    if !innermost {
                        break
                    }
                }
                header := loops.loops[li].header
                if innermost && header != 0 {
                    mf.blocks[header].align = true
                }
            }
        }
        opt_trace("regalloc", f)
        ra := regalloc_allocate(&mf, layout.items())
        opt_trace("emit", f)
        local := vec[i64]()
        for bits in mf.fconsts.items() {
            ix, has := fpool_ix.get(bits)
            if !has {
                // the pool outlives this function
                work_pause()
                fpool.push(bits)
                ix = fpool.len - 1
                fpool_ix.set(bits, ix)
                work_resume()
            }
            local.push(ix)
        }
        dbg, dbg_set := env_get("ALC_DEBUG")
        if dbg_set && dbg == "mir" {
            eput(mir_print_mfunc(&mf))
        }
        code := emit_emit(&mf, &ra, layout.items(), local.items())
        if dump_asm {
            put(mir_print_mfunc(&mf))
        }
        work_end()
        funcs.push(Compiled{fid: fid, code: Code{bytes: clone(&code.bytes), relocs: clone(&code.relocs)}})
        // the function's IR was rewritten on the work heap and is not needed again
        f.insts = vec[Inst]()
        f.blocks = vec[BlockData]()
    }
    return Output{funcs: funcs, fpool: fpool}
}

// Block order: reverse postorder that prefers the taken ("then") successor as fallthrough,
// with blocks that inevitably trap moved to the end.
fn x86_block_layout(f: *Func) -> Vec[i64] {
    n := f.blocks.len
    seen := vec_fill(n, false)
    post := vec[i64]()
    stack := vec_of([](i64, i64){(0, 0)})
    seen[0] = true
    while stack.len > 0 {
        top := stack.len - 1
        b := stack[top].0
        i := stack[top].1
        ss := f.succs(b)
        reverse(ss.items())
        if i < ss.len {
            s := ss[i]
            stack[top].1 = i + 1
            if !seen[s] {
                seen[s] = true
                stack.push((s, 0))
            }
        } else {
            post.push(b)
            stack.pop()
        }
    }
    reverse(post.items())
    // cold: every path from the block ends in a trap
    cold := vec_fill(n, false)
    changed := true
    while changed {
        changed = false
        for pi in post.len - 1..=0 by -1 {
            b := post[pi]
            if cold[b] {
                continue
            }
            tm := f.blocks[b].term
            c := match tm {
                TermTrap => true
                TermNone => true
                TermJmp(t) => cold[t]
                TermBr(x, t, e) => cold[t] && cold[e]
                TermRet(vs) => false
            }
            if c {
                cold[b] = true
                changed = true
            }
        }
    }
    out := vec[i64]()
    for b in post.items() {
        if !cold[b] || b == 0 {
            out.push(b)
        }
    }
    for b in post.items() {
        if cold[b] && b != 0 {
            out.push(b)
        }
    }
    return out
}
