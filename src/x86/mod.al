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

// The globals the linkers write (ELF and PE). A read-only global (a string literal, a
// constant table, a "file:line" text) is kept only if the compiled code refers to it,
// directly or through the data of another kept global: data that only removed code used
// (a branch of `if` on a constant, a function nobody calls, a check the optimiser removed)
// is not in the executable. Writable globals are all kept. ALC_DISABLE=deaddata keeps all.
fn x86_live_data(m: *Module, out: *Output) -> Vec[bool] {
    live := vec_fill(m.globals.len, !opt_enabled("deaddata"))
    if !opt_enabled("deaddata") {
        return live
    }
    work := vec[i64]()
    for gi in 0..m.globals.len {
        if !m.globals[gi].readonly {
            live[gi] = true
            work.push(gi)
        }
    }
    for ci in 0..out.funcs.len {
        for r in out.funcs[ci].code.relocs {
            match r.kind {
                Abs32Global(g), Rel32Global(g) if !live[g] => {
                    live[g] = true
                    work.push(g)
                }
                _ => {}
            }
        }
    }
    while !work.is_empty() {
        g := work.pop()
        for rl in m.globals[g].relocs {
            match rl.1 {
                Global(t, _) if !live[t] => {
                    live[t] = true
                    work.push(t)
                }
                _ => {}
            }
        }
    }
    return live
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
    _, align_set := env_get("ALC_ALIGN")
    dbg, dbg_set := env_get("ALC_DEBUG")
    o := Opts{dump_asm: dump_asm, align: align_set, mir: dbg_set && dbg == "mir"}
    // (what the worker threads read is filled before they start: opt_optimize has filled the
    // optimiser's tables)
    if target_os == TargetWindows {
        regalloc_windows()
    }
    isel_init(m)
    // Functions are compiled independently of each other: with several CPUs, worker threads
    // compile them together with this one (spread_threads in src/spread.al). Debug output that
    // is written per function (mir, trace, verify) keeps the plain order.
    nw, exact := spread_jobs()
    par := nw > 1 && !dump_asm && (!dbg_set || dbg == "mem")
    n := m.funcs.len
    fused := par && opt_deferred() && n >= SPREAD_MIN
    no_done: Done
    // made[f]: the code of function f made by compile_spread (!ok: not made there)
    made := vec_fill(n, no_done)
    r := refs_new(n)
    if fused {
        // The optimisation left to the back end (-O0) runs in the threads too, before the
        // reachable functions are known: all lowered functions are optimised and compiled (at
        // -O0 nearly all are reachable; the code of the others is dropped), and their
        // references give the reachable functions.
        lowered := vec[i64]()
        for f in 0..n {
            if m.funcs[f].lowered {
                lowered.push(f)
            }
        }
        made = compile_spread(m, lowered.items(), &o, spread_threads(nw, exact, lowered.len, SPREAD_PER_O0), &r)
    }
    w := work_main()
    for f in 0..n {
        if !r.known[f] {
            opt_finish(m, f, w)
            refs_add(&r, m, f)
        }
    }
    fids := reachable_funcs(m, &r)
    if par && !fused && fids.len >= SPREAD_MIN {
        made = compile_spread(m, fids.items(), &o, spread_threads(nw, exact, fids.len, SPREAD_PER), nil)
    }
    done := vec_fill(fids.len, no_done)
    for i in 0..fids.len {
        done[i] = made[fids[i]]
        if !done[i].ok {
            opt_finish(m, fids[i], w)
            done[i] = compile_fn(m, fids[i], &o, w)
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
        funcs.push(Compiled{fid: fids[i], code: d.code})
    }
    return Output{funcs: funcs, fpool: fpool, err: err}
}

// compiles function fid on the thread whose Work w is
priv fn compile_fn(m: *Module, fid: i64, o: *Opts, w: *Work) -> Done {
    f := &m.funcs[fid]
    // everything up to the machine code of this function is temporary (see work_begin)
    f.w = w
    work_begin(w)
    opt_backend_cleanup(f, fid)
    aliases := isel_split_critical_edges(f)
    // the loops (a function without a cycle has none: no need for dominators)
    rpo := f.rpo()
    loops: Loops
    depths := vec_fill(f.blocks.len, 0)
    if has_cycle(f, rpo.items()) {
        cfg := cfg_new(f)
        loops = loops_new(f, &cfg)
        for b in 0..f.blocks.len {
            depths[b] = loops.depth(b)
        }
    }
    opt_trace("isel", f)
    mf := isel_select(f, m, rpo.items(), loops, depths.items(), aliases.items())
    layout := block_layout(f, depths.items())
    // optional (ALC_ALIGN=1): align the entry of innermost loops. Off by default: on the
    // benchmark suite the padding executed on every loop entry cost more than it gained.
    // (loops is empty without a cycle)
    if o.align {
        inner: for li in 0..loops.loops.len {
            for oi in 0..loops.loops.len {
                if oi != li && loops.loops[oi].parent == Some(li) {
                    continue inner
                }
            }
            header := loops.loops[li].header
            if header != 0 {
                mf.blocks[header].align = true
            }
        }
    }
    opt_trace("regalloc", f)
    ra := regalloc_allocate(&mf, layout.items(), w)
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
    work_end(w)
    d := Done{code: clone(code), fconsts: clone(mf.fconsts), ok: true}
    // the function's IR was rewritten on the work heap and is not needed again
    f.insts = vec[Inst]()
    f.blocks = vec[BlockData]()
    f.w = nil
    return d
}

// What the threads of compile_spread share: an element of `done` or of the tables of `r` is
// written by the thread that took the function, and read by the caller after the threads have
// been joined.
priv struct Spread {
    m: *Module
    o: *Opts
    done: []Done  // by function
    r: *Refs      // nil: the references are known already
}

// Compiles the functions cand in nw threads (spread_run in src/spread.al), largest first: each
// function is optimised (what opt_optimize left to the back end, opt_finish), its references
// are recorded in r (unless r is nil) and it is compiled. What a thread keeps (the optimised
// IR, the references, the code) is in its arena, which stays after the join. Returns the code
// by function (!ok: not in cand).
priv fn compile_spread(m: *Module, cand: []i64, o: *Opts, nw: i64, r: *Refs) -> Vec[Done] {
    order := spread_order(m, cand)
    no_done: Done
    done := vec_fill(m.funcs.len, no_done)
    s := Spread{m: m, o: o, done: done.items(), r: r}
    spread_run(order.items(), nw, &s, fn(s: *Spread, f: i64, w: *Work) {
        opt_finish(s.m, f, w)
        if s.r != nil {
            refs_add(s.r, s.m, f)
        }
        s.done[f] = compile_fn(s.m, f, s.o, w)
    })
    return done
}

// is there an edge between reachable blocks that goes back in the reverse postorder (or a
// block that jumps to itself)? Without one the function has no loop: a block dominates only
// blocks after it in the order.
priv fn has_cycle(f: *Func, rpo: []i64) -> bool {
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
// unless the "then" successor leaves the loop of the block (a smaller loop depth, `depths`)
// and the other one does not: the loop's own code then follows, and the loop is left by a
// branch rather than continued by one. Blocks that inevitably trap are moved to the end.
priv fn block_layout(f: *Func, depths: []i64) -> Vec[i64] {
    n := f.blocks.len
    seen := vec_fill(n, false)
    post := vec[i64]()
    post.reserve(n)
    stack := vec_of([](i64, i64){(0, 0)})
    seen[0] = true
    while !stack.is_empty() {
        top := stack.len - 1
        b, i := stack[top]
        // the successors in reverse order: else, then
        k, s0, s1 := f.succ_pair(b)
        if i < k {
            // (the successor visited last follows the block)
            first, last := (s1, s0)
            if k == 2 && b < len(depths) && s0 < len(depths) && s1 < len(depths) && depths[s0] < depths[b] && depths[s1] >= depths[b] {
                first, last = (s0, s1)
            }
            s := if k == 2 && i == 0 { first } else { last }
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
