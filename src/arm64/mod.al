// The arm64 back end driver (--target linux-arm64): the reachable functions, block layout,
// selection, allocation, encoding, and the float constant pool. Functions are compiled by
// several threads together as in the x86-64 driver (src/x86/mod.al, src/spread.al), with the
// same result whatever the number of threads.

struct A64Func {
    fid: i64
    code: A64Code
}

struct A64Output {
    funcs: Vec[A64Func]
    fpool: Vec[Bits128]
    err: str
    // the source files (Module.locs) of the compiled code: the driver refuses the bundled
    // modules that make system calls by their x86-64 numbers
    code_files: Vec[i64]
}

// the machine code of one function; its float constant relocations are indices into fconsts
// (the module pool is assembled afterwards, in the order of the functions)
priv struct Done {
    code: A64Code
    fconsts: Vec[Bits128]
    files: []i64 // the source files of its optimised IR (inlined code included), as first met
    ok: bool
}

priv struct Opts {
    dump_asm: bool
    mir: bool // ALC_DEBUG=mir
}

fn a64_compile(m: *Module, dump_asm: bool) -> A64Output {
    dbg, dbg_set := env_get("ALC_DEBUG")
    o := Opts{dump_asm: dump_asm, mir: dbg_set && dbg == "mir"}
    // (what the worker threads read is filled before they start)
    a_isel_init(m)
    // as x86_compile: with several CPUs, worker threads compile the functions together with
    // this one; at -O0 they also do the optimisation left to the back end, for all lowered
    // functions, and their references give the reachable ones
    nw, exact := spread_jobs()
    par := nw > 1 && !dump_asm && (!dbg_set || dbg == "mem")
    n := m.funcs.len
    fused := par && opt_deferred() && n >= SPREAD_MIN
    no_done: Done
    // made[f]: the code of function f made by compile_spread (!ok: not made there)
    made := vec_fill(n, no_done)
    r := refs_new(n)
    if fused {
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
    // the source files of the compiled code, and the float constant pool: every function's in
    // the order of the functions
    sfiles := vec[i64]()
    fpool := vec[Bits128]()
    fpool_ix := map[Bits128, i64]()
    funcs := vec[A64Func]()
    err := ""
    local := vec[i64]()
    for i in 0..fids.len {
        d := &done[i]
        for file in d.files {
            if !contains(&sfiles, file) {
                sfiles.push(file)
            }
        }
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
        a64_pool_fconsts(&d.code, local.items())
        if len(d.code.err) != 0 && len(err) == 0 {
            err = d.code.err
        }
        funcs.push(A64Func{fid: fids[i], code: d.code})
    }
    return A64Output{funcs: funcs, fpool: fpool, err: err, code_files: sfiles}
}

// What the threads of compile_spread share: an element of `done` or of the tables of `r` is
// written by the thread that took the function, and read by the caller after the join.
priv struct Spread {
    m: *Module
    o: *Opts
    done: []Done // by function
    r: *Refs     // nil: the references are known already
}

// Compiles the functions cand in nw threads (spread_run in src/spread.al), largest first,
// optimising each first (opt_finish) and recording its references in r unless r is nil.
// Returns the code by function (!ok: not in cand).
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

// the source files of the instructions of f (the chains of the locations of inlined code
// included), each once, in the order first met
priv fn code_files(m: *Module, f: *Func) -> Vec[i64] {
    files := vec[i64]()
    last := -1
    for bi in 0..f.blocks.len {
        for v in f.blocks[bi].insts {
            l := i64(f.insts[v].srcloc())
            if l == last {
                continue
            }
            last = l
            while l > 0 && l < m.locs.list.len {
                file := i64(m.locs.list[l].file)
                if !contains(&files, file) {
                    files.push(file)
                }
                l = i64(m.locs.list[l].parent)
            }
        }
    }
    return files
}

// compiles function fid (optimised already) on the thread whose Work w is
priv fn compile_fn(m: *Module, fid: i64, o: *Opts, w: *Work) -> Done {
    f := &m.funcs[fid]
    files := code_files(m, f)
    f.w = w
    work_begin(w)
    opt_backend_cleanup(f, fid)
    switch_lower(f, true)
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
    if o.mir {
        eput(a_print(&mf, layout.items()))
    }
    ra := a_regalloc(&mf, layout.items(), w)
    if o.dump_asm {
        put(a_print(&mf, layout.items()))
    }
    code := a_emit(&mf, &ra, layout.items())
    work_end(w)
    d := Done{code: clone(code), fconsts: clone(mf.fconsts), files: files.items(), ok: true}
    f.insts = vec[Inst]()
    f.blocks = vec[BlockData]()
    f.w = nil
    return d
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
        sw := k == 0 && f.is_switch(b)
        if sw {
            k = f.nsucc(b)
        }
        if i < k {
            s := if k == 2 && i == 0 { s1 } else { s0 }
            if sw {
                s = f.succ_at(b, k - 1 - i)
            }
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
                Switch(_, tab) => {
                    all := true
                    for j in 1..1 + tab[0] {
                        if !cold[tab[j]] {
                            all = false
                        }
                    }
                    all
                }
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
