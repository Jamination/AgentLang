// The arm64 back end driver (--target linux-arm64): the reachable functions, block layout,
// selection, allocation, encoding, and the float constant pool. Functions are compiled one
// after the other on the compiler's thread (the x86-64 back end spreads them over worker
// threads: compile_spread in src/x86/mod.al; the same can be done here).

struct A64Func {
    fid: i64
    code: A64Code
}

struct A64Output {
    funcs: Vec[A64Func]
    fpool: Vec[Bits128]
    err: str
}

// the functions to compile, in increasing order: the entry, the functions whose address is in
// global data, and what these call or take the address of (from the optimised IR)
priv fn reachable(m: *Module) -> Vec[i64] {
    seen := vec_fill(m.funcs.len, false)
    work := vec_of([]i64{m.entry})
    seen[m.entry] = true
    for gi in 0..m.globals.len {
        for rl in m.globals[gi].relocs {
            match rl.1 {
                Func(f) if !seen[f] => {
                    seen[f] = true
                    work.push(f)
                }
                _ => {}
            }
        }
    }
    out := vec[i64]()
    while !work.is_empty() {
        fid := work.pop()
        out.push(fid)
        f := &m.funcs[fid]
        for bi in 0..f.blocks.len {
            for v in f.blocks[bi].insts {
                i := &f.insts[v]
                if (i.op == Call || i.op == FAddr) && !seen[i.k] {
                    seen[i.k] = true
                    work.push(i.k)
                }
            }
        }
    }
    sort(out.items())
    return out
}

fn a64_compile(m: *Module, dump_asm: bool) -> A64Output {
    dbg, dbg_set := env_get("ALC_DEBUG")
    mir := dbg_set && dbg == "mir"
    a_isel_init(m)
    w := work_main()
    for f in 0..m.funcs.len {
        opt_finish(m, f, w)
    }
    fids := reachable(m)
    fpool := vec[Bits128]()
    fpool_ix := map[Bits128, i64]()
    funcs := vec[A64Func]()
    err := ""
    for fid in fids {
        code, fconsts := compile_fn(m, fid, w, dump_asm, mir)
        local := vec[i64]()
        for bits in fconsts {
            ix, has := fpool_ix.get(bits)
            if !has {
                fpool.push(bits)
                ix = fpool.len - 1
                fpool_ix.set(bits, ix)
            }
            local.push(ix)
        }
        a64_pool_fconsts(&code, local.items())
        if len(code.err) != 0 && len(err) == 0 {
            err = code.err
        }
        funcs.push(A64Func{fid: fid, code: code})
    }
    return A64Output{funcs: funcs, fpool: fpool, err: err}
}

priv fn compile_fn(m: *Module, fid: i64, w: *Work, dump_asm: bool, mir: bool) -> (A64Code, Vec[Bits128]) {
    f := &m.funcs[fid]
    f.w = w
    work_begin(w)
    opt_backend_cleanup(f, fid)
    a_split_critical_edges(f)
    rpo := f.rpo()
    cfg := cfg_new(f)
    loops := loops_new(f, &cfg)
    depths := vec_fill(f.blocks.len, 0)
    for b in 0..f.blocks.len {
        depths[b] = loops.depth(b)
    }
    mf := a_isel_select(f, m, rpo.items(), depths.items())
    layout := block_layout(f)
    if mir {
        eput(a_print(&mf, layout.items()))
    }
    ra := a_regalloc(&mf, layout.items(), w)
    if dump_asm {
        put(a_print(&mf, layout.items()))
    }
    code := a_emit(&mf, &ra, layout.items())
    work_end(w)
    res := (clone(code), clone(mf.fconsts))
    f.insts = vec[Inst]()
    f.blocks = vec[BlockData]()
    f.w = nil
    return res
}

// Block order: reverse postorder that prefers the taken ("then") successor as fallthrough,
// with blocks that inevitably trap moved to the end (as block_layout in src/x86/mod.al)
priv fn block_layout(f: *Func) -> Vec[i64] {
    n := f.blocks.len
    seen := vec_fill(n, false)
    post := vec[i64]()
    stack := vec_of([](i64, i64){(0, 0)})
    seen[0] = true
    while !stack.is_empty() {
        top := stack.len - 1
        b, i := stack[top]
        k, s0, s1 := f.succ_pair(b)
        if i < k {
            s := if k == 2 && i == 0 { s1 } else { s0 }
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
    cold := vec_fill(n, false)
    changed := true
    while changed {
        changed = false
        for pi in post.len - 1..=0 by -1 {
            b := post[pi]
            if cold[b] {
                continue
            }
            c := match f.blocks[b].term {
                Trap, Term.None => true
                Jmp(t) => cold[t]
                Br(_, t, e) => cold[t] && cold[e]
                Ret(_) => false
            }
            if c {
                cold[b] = true
                changed = true
            }
        }
    }
    out := vec[i64]()
    for b in post {
        if !cold[b] || b == 0 {
            out.push(b)
        }
    }
    for b in post {
        if cold[b] && b != 0 {
            out.push(b)
        }
    }
    return out
}
