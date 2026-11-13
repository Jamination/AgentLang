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

// The functions that each function calls or takes the address of, from its optimised IR: those
// of function f are list[start[f]..start[f] + cnt[f]]; cnt[f] is -1 while they are not known.
priv struct Refs {
    start: Vec[i64]
    cnt: Vec[i64]
    list: Vec[i64]
}

priv fn refs_new(n: i64) -> Refs {
    return Refs{start: vec_fill(n, 0), cnt: vec_fill(n, -1), list: vec[i64]()}
}

// records the references of function fid (in the order of its IR)
priv fn refs_add(r: *Refs, m: *Module, fid: i64) {
    r.start[fid] = r.list.len
    f := &m.funcs[fid]
    for bi in 0..f.blocks.len {
        for v in f.blocks[bi].insts {
            i := &f.insts[v]
            if i.op == Call || i.op == FAddr {
                r.list.push(i.k)
            }
        }
    }
    r.cnt[fid] = r.list.len - r.start[fid]
}

// The functions to compile, in increasing order: the entry, the functions whose address is in
// global data, and whatever these call or take the address of (r: the references of every
// function).
priv fn reachable_funcs(m: *Module, r: *Refs) -> Vec[i64] {
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
        for x in r.start[f]..r.start[f] + r.cnt[f] {
            k := r.list[x]
            if !seen[k] {
                seen[k] = true
                work.push(k)
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
    align_v, align_set := env_get("ALC_ALIGN")
    dbg, dbg_set := env_get("ALC_DEBUG")
    o := Opts{dump_asm: dump_asm, align: align_set, mir: dbg_set && dbg == "mir"}
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
    par := nw > 1 && !dump_asm && (!dbg_set || dbg == "mem")
    n := m.funcs.len
    fused := par && opt_deferred() && n >= 64
    no_done: Done
    // made[f]: the code of function f made by compile_spread (!ok: not made there)
    made := vec_fill(n, no_done)
    r := refs_new(n)
    if fused {
        // The optimisation left to the back end (-O0) runs in the workers too, before the
        // reachable functions are known: all lowered functions are optimised and compiled (at
        // -O0 nearly all are reachable; the code of the others is dropped), and their
        // references give the reachable functions.
        lowered := vec[i64]()
        for f in 0..n {
            if m.funcs[f].lowered {
                lowered.push(f)
            }
        }
        made = compile_spread(m, lowered.items(), &o, nw, &r)
    }
    for f in 0..n {
        if r.cnt[f] < 0 {
            opt_finish(m, f)
            refs_add(&r, m, f)
        }
    }
    fids := reachable_funcs(m, &r)
    if par && !fused && fids.len >= 64 {
        made = compile_spread(m, fids.items(), &o, nw, &r)
    }
    done := vec_fill(fids.len, no_done)
    for i in 0..fids.len {
        done[i] = made[fids[i]]
        if !done[i].ok {
            opt_finish(m, fids[i])
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

// Compiles the functions cand in nw processes: this one and nw - 1 forked workers. They take
// the functions from a queue (queue_new), largest first, so that all finish at about the same
// time; each function is optimised (what opt_optimize left to the back end, opt_finish), its
// references are recorded in r and it is compiled. A worker writes its results into a mapping
// shared with this process and then closes its copy of the write end of the pipe `fin` (so the
// results are read without waiting for the worker to end). Returns the code by function: what
// is not delivered (a worker failed, crashed or ran out of room) stays !ok and unknown in r,
// for the caller to redo. A fork's changes to the IR are its own: this process still has the
// IR of the functions of the workers as it was before.
priv fn compile_spread(m: *Module, cand: []i64, o: *Opts, nw: i64, r: *Refs) -> Vec[Done] {
    n := m.funcs.len
    sizes := vec_fill(n, 0)
    order := vec_of(cand)
    total := 0
    for f in cand {
        sizes[f] = m.funcs[f].insts.len
        // the references (8 bytes per instruction at most) and the code (about 512)
        total += 520 * sizes[f] + 4096
    }
    // twice a fair share (a worker that runs out of room stops taking functions)
    room := (1 << 22) + 2 * total / nw
    sort_by(order.items(), sizes.items(), fn(s: []i64, a: i64, b: i64) -> bool { s[a] > s[b] || (s[a] == s[b] && a < b) })
    q := queue_new(order.items())
    fin_r, fin_w := pipe_open()
    base := vec_fill(nw, 0)
    pids := vec_fill(nw, -1)
    // (a failed worker stays silent unless ALC_DEBUG is set)
    dv, dset := env_get("ALC_DEBUG")
    for w in 1..nw {
        if q < 0 || fin_r < 0 {
            break
        }
        base[w] = shared_map(room)
        if base[w] == 0 {
            continue
        }
        pid := fork_worker(!dset)
        if pid == 0 {
            fd_close(fin_r)
            spread_worker(m, q, base[w], room, o)
            fd_close(fin_w)
            worker_exit(0)
        }
        pids[w] = pid
    }
    fd_close(fin_w)
    no_done: Done
    done := vec_fill(n, no_done)
    if q >= 0 {
        loop {
            f := queue_take(q)
            if f < 0 {
                break
            }
            opt_finish(m, f)
            refs_add(r, m, f)
            done[f] = compile_fn(m, f, o)
        }
        fd_close(q)
    }
    pipe_wait_closed(fin_r)
    fd_close(fin_r)
    for w in 1..nw {
        if pids[w] >= 0 && cast[*i64](base[w])[1] == 1 {
            off := 64
            for k in 0..cast[*i64](base[w])[0] {
                rec := cast[*i64](base[w] + off)
                f := rec[0]
                nr := rec[1]
                r.start[f] = r.list.len
                for x in 0..nr {
                    r.list.push(rec[2 + x])
                }
                r.cnt[f] = nr
                code, fc, next := emit_get_code(base[w], off + 16 + 8 * nr)
                done[f] = Done{code: code, fconsts: fc, ok: true}
                off = next
            }
        }
        if base[w] != 0 {
            shared_unmap(base[w], room)
        }
    }
    for w in 1..nw {
        if pids[w] >= 0 {
            wait_worker(pids[w])
        }
    }
    return done
}

// A forked worker of compile_spread: optimises and compiles the functions it takes from the
// queue q and writes them to the shared mapping at base: words 0 (the number of records) and 1
// (1: all records written), from byte 64 the records: the function, the number of its
// references, the references, its code (emit_put_code).
priv fn spread_worker(m: *Module, q: i64, base: i64, room: i64, o: *Opts) {
    hdr := cast[*i64](base)
    off := 64
    r := refs_new(m.funcs.len)
    loop {
        f := queue_take(q)
        if f < 0 {
            break
        }
        opt_finish(m, f)
        r.list.clear()
        refs_add(&r, m, f)
        d := compile_fn(m, f, o)
        nr := r.list.len
        if off + 16 + 8 * nr + emit_code_size(&d.code, &d.fconsts) > room {
            // (this function is left to the compiler)
            break
        }
        rec := cast[*i64](base + off)
        rec[0] = f
        rec[1] = nr
        for x in 0..nr {
            rec[2 + x] = r.list[x]
        }
        off = emit_put_code(&d.code, &d.fconsts, base, off + 16 + 8 * nr)
        hdr[0] += 1
    }
    hdr[1] = 1
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
