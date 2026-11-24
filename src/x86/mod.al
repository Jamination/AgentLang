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
    align, align_set := env_get("ALC_ALIGN")
    dbg, dbg_set := env_get("ALC_DEBUG")
    o := Opts{dump_asm: dump_asm, align: !align_set || align != "0", mir: dbg_set && dbg == "mir"}
    // the padding of loops (loop_pads in emit.al); ALC_ALIGN=0: none, ALC_ALIGN=1: the
    // alignment of every innermost loop header to 16 that was there before
    emit_align_mode(if !align_set { 2 } else if align == "0" { 0 } else if align == "1" { 1 } else { 2 })
    emit_align_big(opt_enabled("alignbig"))
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
    switch_lower(f, true)
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
    if opt_enabled("sinkstep") {
        sink_steps(&mf)
    }
    layout := block_layout(f, depths.items())
    // the headers of the innermost loops, for the padding of loops (emit.al; ALC_ALIGN=1: their
    // alignment to 16, which on the benchmark suite cost more than it gained). (loops is empty
    // without a cycle)
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

// In a loop block, moves the step of a value that is only live out (`lea d, [x + k]`, or `mov
// d, x ; add d, k`, which becomes such a lea) to the end of the block, past the reads of x and
// the compare (lea leaves the flags alone): x then dies before d is born and the two share a
// register, so the back edge copies nothing. The typical case is an inclusive or descending
// range loop, whose compare reads the old induction value:
//     lea rax, [rcx-1] ; cmp rcx, r9 ; jcc     (then `mov rcx, rax` on the back edge)
//  -> cmp rcx, r9 ; lea rcx, [rcx-1] ; jcc
// ALC_DISABLE=sinkstep turns it off.
priv fn sink_steps(mf: *MFunc) {
    du := vec_fill(DU_MAX, 0)
    // does instruction i read / write register r?
    fn touches(mf: *MFunc, i: *MInst, du: []i64, r: i64, defs: bool) -> bool {
        mir_decode(mf, i, du, 0)
        nd := du[0] & 255
        nu := (du[0] >> 8) & 255
        lo := if defs { 1 } else { 1 + nd }
        hi := if defs { 1 + nd } else { 1 + nd + nu }
        for j in lo..hi {
            if du[j] == r {
                return true
            }
        }
        return defs && du[0] & (DU_CALL << 16) != 0 && r < VREG0
    }
    for b in 0..mf.blocks.len {
        if mf.blocks[b].depth == 0 {
            continue
        }
        insts := &mf.blocks[b].insts
        // the jumps at the end
        e := insts.len
        while e > 0 && (insts[e - 1].op == Jmp || insts[e - 1].op == Jcc) {
            e -= 1
        }
        if e == insts.len || insts[insts.len - 1].op != Jmp && insts[insts.len - 1].op != Jcc {
            continue
        }
        k := e - 1
        while k >= 0 {
            // the step as d = x + disp (and the index of its first instruction)
            i := insts[k]
            d := -1
            m := mem_new()
            first := k
            sz := i.sz
            match (i.op, &i.a, &i.b) {
                (Lea, R(r), M(mm)) if mm.kind == MK_NORMAL && r >= VREG0 && (i.sz == 4 || i.sz == 8) => {
                    d = r
                    m = mm
                }
                (Add, R(r), I(c)), (Sub, R(r), I(c)) if r >= VREG0 && (i.sz == 4 || i.sz == 8) && k > 0 && fits_i32(c) && c != -2147483648 => {
                    p := &insts[k - 1]
                    match (p.op, &p.a, &p.b) {
                        (Mov, R(pd), R(x)) if p.sz == 8 && pd == r && x >= VREG0 && x != r => {
                            // (nothing may read the flags of the add: an overflow check)
                            flags_read := false
                            for j in k + 1..insts.len {
                                if reads_flags(insts[j].op) {
                                    flags_read = true
                                    break
                                }
                                if sets_flags(insts[j].op) {
                                    break
                                }
                            }
                            if !flags_read {
                                d = r
                                m.base = i32(x)
                                m.disp = i32(if i.op == Add { c } else { -c })
                                first = k - 1
                            }
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
            ok := d >= 0 && (m.base == NOREG || i64(m.base) >= VREG0) && (m.idx == NOREG || i64(m.idx) >= VREG0) && i64(m.base) != d && i64(m.idx) != d
            if !ok {
                k -= 1
                continue
            }
            // to the end of the block, unless an instruction on the way reads d (or writes d,
            // x or the index); worth it only if something on the way reads x or the index
            t := k + 1
            reads := false
            while t < e {
                n := &insts[t]
                if touches(mf, n, du.items(), d, false) {
                    break
                }
                if touches(mf, n, du.items(), d, true) || (m.base != NOREG && touches(mf, n, du.items(), i64(m.base), true)) || (m.idx != NOREG && touches(mf, n, du.items(), i64(m.idx), true)) {
                    t = -1
                    break
                }
                if (m.base != NOREG && touches(mf, n, du.items(), i64(m.base), false)) || (m.idx != NOREG && touches(mf, n, du.items(), i64(m.idx), false)) {
                    reads = true
                }
                t += 1
            }
            // (only to the end: moved down to a use in the block, as before an `add; cmp` of
            // the new value, it was measured slower on smallint)
            if t != e || !reads {
                k = first - 1
                continue
            }
            // between `first` and t: drop the step, put the lea before instruction t
            li := minst_new(Lea, sz, R(d), M(m))
            li.tgt = i.tgt
            li.loc = i.loc
            insts.insert(t, li)
            insts.remove(k)
            if first != k {
                insts.remove(first)
                e -= 1
            }
            k = first - 1
        }
    }
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
        for j in 0..if k == 0 { f.nsucc(b) } else { 0 } {
            if idx[f.succ_at(b, j)] <= i {
                return true
            }
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
        sw := k == 0 && f.is_switch(b)
        if sw {
            k = f.nsucc(b)
        }
        if i < k {
            // (the successor visited last follows the block)
            first, last := (s1, s0)
            if k == 2 && b < len(depths) && s0 < len(depths) && s1 < len(depths) && depths[s0] < depths[b] && depths[s1] >= depths[b] {
                first, last = (s0, s1)
            }
            s := if k == 2 && i == 0 { first } else { last }
            if sw {
                // a switch: the targets from the last to the default
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
