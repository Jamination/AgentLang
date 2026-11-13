// The x86-64 backend driver: reachable functions, block layout, float constant pool.

priv struct Compiled {
    fid: i64
    code: Code
}

struct Output {
    funcs: Vec[Compiled]
    fpool: Vec[Bits128]
    err: str // the first function that cannot be compiled (stack frame too large), or ""
}

priv fn reachable_funcs(m: *Module) -> Vec[i64] {
    seen := vec_fill(m.funcs.len, false)
    work := vec_of([]i64{m.entry})
    seen[m.entry] = true
    // function pointers stored in global data: these functions are roots as well (what they
    // call must be compiled too)
    for gi in 0..m.globals.len {
        for rl in m.globals[gi].relocs {
            t := rl.1
            match t {
                Func(f) if !seen[f] => {
                    seen[f] = true
                    work.push(f)
                }
                _ => {}
            }
        }
    }
    out := vec[i64]()
    while work.len > 0 {
        f := work.pop()
        out.push(f)
        func := &m.funcs[f]
        for bi in 0..func.blocks.len {
            for v in func.blocks[bi].insts {
                i := &func.insts[v]
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

// the machine code of one function; its float constant relocations are indices into fconsts
// (the module pool is assembled afterwards, in the order of the functions)
priv struct Done {
    code: Code
    fconsts: Vec[Bits128]
    ok: bool
}

priv struct Opts {
    dump_asm: bool
    align: bool // ALC_ALIGN
    mir: bool   // ALC_DEBUG=mir
}

fn x86_compile(m: *Module, dump_asm: bool) -> Output {
    fids := reachable_funcs(m)
    align_v, align_set := env_get("ALC_ALIGN")
    dbg, dbg_set := env_get("ALC_DEBUG")
    o := Opts{dump_asm: dump_asm, align: align_set, mir: dbg_set && dbg == "mir"}
    no_done: Done
    done := vec_fill(fids.len, no_done)
    // Functions are compiled independently of each other: with several CPUs, forked workers
    // compile parts of them (ALC_JOBS=n sets the number of processes). Debug output that is
    // written per function (mir, trace, verify) keeps the plain order.
    nw := min(cpu_count(), 6)
    jobs, jobs_set := env_get("ALC_JOBS")
    if jobs_set {
        j, jok := parse_i64(jobs)
        if jok && j >= 1 {
            nw = j
        }
    }
    if nw > 1 && fids.len >= 64 && !dump_asm && (!dbg_set || dbg == "mem") {
        compile_parallel(m, fids.items(), &o, nw, &done)
    }
    for i in 0..fids.len {
        if !done[i].ok {
            done[i] = compile_fn(m, fids[i], &o)
        }
    }
    // the float constant pool: every function's constants in the order of the functions
    fpool := vec[Bits128]()
    fpool_ix := map[Bits128, i64]()
    funcs := vec[Compiled]()
    err := ""
    local := vec[i64]()
    for i in 0..fids.len {
        d := &done[i]
        local.clear()
        for bits in d.fconsts {
            ix, has := fpool_ix.get(bits)
            if !has {
                fpool.push(bits)
                ix = fpool.len - 1
                fpool_ix.set(bits, ix)
            }
            local.push(ix)
        }
        emit_pool_fconsts(&d.code, local.items())
        if len(d.code.err) != 0 && len(err) == 0 {
            err = d.code.err
        }
        funcs.push(Compiled{fid: fids[i], code: Code{bytes: d.code.bytes, relocs: d.code.relocs}})
    }
    return Output{funcs: funcs, fpool: fpool, err: err}
}

priv fn compile_fn(m: *Module, fid: i64, o: *Opts) -> Done {
    f := &m.funcs[fid]
    // everything up to the machine code of this function is temporary (see work_begin)
    work_begin()
    opt_backend_cleanup(f, fid)
    aliases := isel_split_critical_edges(f)
    // the loops (a function without a cycle has none: no need for dominators)
    rpo := f.rpo()
    loops: Loops
    depths := vec_fill(f.blocks.len, 0)
    if x86_has_cycle(f, rpo.items()) {
        cfg := cfg_new(f)
        loops = loops_new(f, &cfg)
        for b in 0..f.blocks.len {
            depths[b] = loops.depth(b)
        }
    }
    opt_trace("isel", f)
    mf := isel_select(f, m, rpo.items(), loops, depths.items(), aliases.items())
    layout := block_layout(f)
    // optional (ALC_ALIGN=1): align the entry of innermost loops. Off by default: on the
    // benchmark suite the padding executed on every loop entry cost more than it gained.
    // (loops is empty without a cycle)
    if o.align {
        for li in 0..loops.loops.len {
            innermost := true
            for oi in 0..loops.loops.len {
                match loops.loops[oi].parent {
                    Some(p) if oi != li && p == li => innermost = false
                    _ => {}
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
    for x in 0..mf.fconsts.len {
        local.push(x)
    }
    if o.mir {
        eput(mir_print_mfunc(&mf))
    }
    code := emit_emit(&mf, &ra, layout.items(), local.items())
    if o.dump_asm {
        put(mir_print_mfunc(&mf))
    }
    work_end()
    d := Done{code: Code{bytes: clone(code.bytes), relocs: clone(code.relocs), err: clone(code.err)}, fconsts: clone(mf.fconsts), ok: true}
    // the function's IR was rewritten on the work heap and is not needed again
    f.insts = vec[Inst]()
    f.blocks = vec[BlockData]()
    return d
}

// Compiles the functions in nw processes: this one and nw - 1 forked workers, each with a
// share balanced by IR size, largest first. A worker writes its results into a mapping shared
// with this process; whatever a worker does not deliver (it failed, crashed or ran out of
// room) stays !ok in `done` and is compiled here afterwards.
priv fn compile_parallel(m: *Module, fids: []i64, o: *Opts, nw: i64, done: *Vec[Done]) {
    n := len(fids)
    sizes := vec_fill(n, 0)
    order := vec_fill(n, 0)
    for i in 0..n {
        sizes[i] = m.funcs[fids[i]].insts.len
        order[i] = i
    }
    sort_by(order.items(), sizes.items(), fn(s: []i64, a: i64, b: i64) -> bool { s[a] > s[b] || (s[a] == s[b] && a < b) })
    load := vec_fill(nw, 0)
    room := vec_fill(nw, 1 << 22)
    owner := vec_fill(n, 0)
    for i in order {
        w := 0
        for x in 1..nw {
            if load[x] < load[w] {
                w = x
            }
        }
        owner[i] = w
        load[w] += sizes[i] + 1
        room[w] += 512 * sizes[i] + 4096
    }
    base := vec_fill(nw, 0)
    pids := vec_fill(nw, -1)
    for w in 1..nw {
        base[w] = shared_map(room[w])
        if base[w] == 0 {
            continue
        }
        // (a failed worker stays silent unless ALC_DEBUG is set)
        dv, dset := env_get("ALC_DEBUG")
        pid := fork_worker(!dset)
        if pid == 0 {
            worker(m, fids, owner.items(), w, base[w], room[w], o)
            worker_exit(0)
        }
        pids[w] = pid
    }
    for i in 0..n {
        if owner[i] == 0 {
            done[i] = compile_fn(m, fids[i], o)
        }
    }
    for w in 1..nw {
        if pids[w] >= 0 && wait_worker(pids[w]) == 0 {
            hdr := cast[*i64](base[w])
            off := 64
            for r in 0..hdr[1] {
                rec := cast[*i64](base[w] + off)
                i := rec[0]
                code, fc, next := emit_get_code(base[w], off + 8)
                done[i] = Done{code: code, fconsts: fc, ok: true}
                off = next
            }
        }
        if base[w] != 0 {
            shared_unmap(base[w], room[w])
        }
    }
}

// a forked worker: compiles the functions of share w and writes them to the shared mapping
// at base: words 0 (all written) and 1 (the number of records), then from byte 64 the records:
// the index of the function, then its code (emit_put_code)
priv fn worker(m: *Module, fids: []i64, owner: []i64, w: i64, base: i64, room: i64, o: *Opts) {
    hdr := cast[*i64](base)
    off := 64
    for i in 0..len(fids) {
        if owner[i] != w {
            continue
        }
        d := compile_fn(m, fids[i], o)
        if off + 8 + emit_code_size(&d.code, &d.fconsts) > room {
            return
        }
        rec := cast[*i64](base + off)
        rec[0] = i
        off = emit_put_code(&d.code, &d.fconsts, base, off + 8)
        hdr[1] += 1
    }
    hdr[0] = 1
}

// is there an edge between reachable blocks that goes back in the reverse postorder (or a
// block that jumps to itself)? Without one the function has no loop: a block dominates only
// blocks after it in the order.
fn x86_has_cycle(f: *Func, rpo: []i64) -> bool {
    idx := vec_fill(f.blocks.len, -1)
    for i, b in rpo {
        idx[b] = i
    }
    for i, b in rpo {
        k, s0, s1 := f.succ_pair(b)
        if (k > 0 && idx[s0] <= i) || (k > 1 && idx[s1] <= i) {
            return true
        }
    }
    return false
}

// Block order: reverse postorder that prefers the taken ("then") successor as fallthrough,
// with blocks that inevitably trap moved to the end.
priv fn block_layout(f: *Func) -> Vec[i64] {
    n := f.blocks.len
    seen := vec_fill(n, false)
    post := vec[i64]()
    post.reserve(n)
    stack := vec_of([](i64, i64){(0, 0)})
    seen[0] = true
    while stack.len > 0 {
        top := stack.len - 1
        b := stack[top].0
        i := stack[top].1
        // the successors in reverse order: else, then
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
                Trap, Term.None => true
                Jmp(t) => cold[t]
                Br(x, t, e) => cold[t] && cold[e]
                Ret(vs) => false
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
