// Promote non-escaping stack slots to SSA values (with scalar replacement of aggregates).

priv struct Ctx {
    f: *Func,
    preds: Vec[Vec[i64]], // among the reachable blocks, in reverse postorder (cfg_preds)
    var_ty: Vec[T],
    nb: i64, // block count: the key of (var, block) is var * nb + block
    last_store: IMap,
    has_store: []bool,
    def_in: IMap,
    new_phis: Vec[(i64, i64)],
    entry_consts: Vec[i32],
    zero: [10]i64, // by T; NOV: none yet
    walk: Vec[(i64, i64, i64)], // read_in's blocks on the way back (block, phi or NOV, next pred)
}

priv fn zero_of(self: *Ctx, t: T) -> i64 {
    z0 := self.zero[i64(t)]
    if z0 != NOV {
        return z0
    }
    z := self.f.mk(if t.is_fp() { FConst } else { Const }, t, vec[i64](), 0)
    self.entry_consts.push(i32(z))
    self.zero[i64(t)] = z
    return z
}

// the value var_ has at the end of block b if b stores it there, else -1
priv fn stored_out(self: *Ctx, var_: i64, b: i64) -> i64 {
    if self.has_store[b] {
        return self.last_store.iget(var_ * self.nb + b)
    }
    return -1
}

// The value var_ has at the start of block b: def_in if known, else (and remembered in def_in)
// zero without a predecessor, the value at the end of a single predecessor, or a new phi of
// the values at the end of all predecessors (made before them: a loop back to b finds it).
// The search goes back through the predecessors with a stack of its own (self.walk), not by
// recursion: a chain of blocks can be as long as the function.
priv fn read_in(self: *Ctx, var_: i64, b0: i64) -> i64 {
    walk := &self.walk
    walk.clear()
    // b >= 0: the value at the start of b is wanted; b < 0: it is v, for the top of walk
    b := b0
    v := 0
    loop {
        if b >= 0 {
            key := var_ * self.nb + b
            v0 := self.def_in.iget(key)
            if v0 >= 0 {
                v = v0
                b = -1
                continue
            }
            preds := self.preds[b]
            np := preds.len
            // (a single predecessor that is b itself: a self-loop of a single block)
            if np == 0 || np == 1 && preds[0] == b {
                v = self.zero_of(self.var_ty[var_])
                self.def_in.iset(key, v)
                b = -1
                continue
            }
            phi := NOV
            if np > 1 {
                phi = self.f.mk_phi(self.var_ty[var_], np)
                self.def_in.iset(key, phi)
                self.new_phis.push((b, phi))
            }
            walk.push((b, phi, 0))
            s := self.stored_out(var_, preds[0])
            if s >= 0 {
                v = s
                b = -1
            } else {
                b = preds[0]
            }
            continue
        }
        // v: the result if walk is empty, else the value at the end of predecessor i of the
        // block on top of walk
        if walk.is_empty() {
            return v
        }
        top := walk.len - 1
        wb, phi, i := walk[top]
        if phi == NOV {
            self.def_in.iset(var_ * self.nb + wb, v)
            walk.pop()
            continue
        }
        preds := self.preds[wb]
        self.f.im(phi).phi_add(v, preds[i])
        if i + 1 == preds.len {
            v = phi
            walk.pop()
            continue
        }
        walk[top].2 = i + 1
        s := self.stored_out(var_, preds[i + 1])
        if s >= 0 {
            v = s
        } else {
            b = preds[i + 1]
        }
    }
}

// the last mem2reg_run on f's thread ended with a round that changed nothing (not at its round
// limit; kept in f.w)
fn mem2reg_settled(f: *Func) -> bool {
    return f.w.settled
}

fn mem2reg_run(f: *Func) -> bool {
    any := false
    f.w.settled = false
    for it in 0..8 {
        // (only the first round sees the IR the pass began with)
        if !run_once(f, it == 0) {
            f.w.settled = true
            break
        }
        any = true
    }
    return any
}

priv fn run_once(f: *Func, first: bool) -> bool {
    // allocas live in the entry block; without one there is nothing to do
    nalloca := 0
    for v in f.blocks[0].insts {
        if f.insts[v].op == Alloca {
            nalloca += 1
        }
    }
    if nalloca == 0 {
        return false
    }
    // An alloca that escapes (alias_escaped_allocas) is never promoted: its pointers, which
    // include the ones promotion follows, have a use that promotion refuses (in a terminator,
    // as a stored value, by anything but an Add, Load or Store, by an Add with a second
    // pointer). If that analysis of this very IR is at hand and every alloca escapes, nothing
    // can be done.
    esc, known := alias_escaped_known(f, opt_gen(f))
    if first && known {
        all := true
        for v in f.blocks[0].insts {
            if f.insts[v].op == Alloca && !esc[v] {
                all = false
                break
            }
        }
        if all {
            return false
        }
    }
    rpo := f.rpo()
    n := f.insts.len
    // The users of the pointers into allocas (instruction users only, in reverse postorder).
    // `ptrs` is a superset of those pointers: the allocas of the entry block and constant
    // offsets from such pointers (an argument is defined before its user in reverse postorder,
    // except for a phi: the uses by phis are all recorded). The recorded (value, user) pairs are
    // linked into one list per value (below).
    ptrs := alloc[bool](n)
    for v in f.blocks[0].insts {
        // (-g at -O0: the variables keep their slots, see src/debug.al)
        if f.insts[v].op == Alloca && !(dbg_keep_vars && f.insts[v].cap < 0) {
            ptrs[v] = true
        }
    }
    term_used := alloc[bool](n)
    pairs := vec[i32]()
    for b in rpo {
        for v in f.blocks[b].insts {
            i := &f.insts[v]
            if i.op == Phi {
                for a in i.args {
                    push_fast(&pairs, i32(a))
                    push_fast(&pairs, v)
                }
                continue
            }
            for a in i.args {
                if ptrs[a] {
                    push_fast(&pairs, i32(a))
                    push_fast(&pairs, v)
                }
            }
            if i.op == Add {
                a0 := i.args[0]
                a1 := i.args[1]
                if ptrs[a0] && f.insts[a1].op == Const || ptrs[a1] && f.insts[a0].op == Const {
                    ptrs[v] = true
                }
            }
        }
        match f.blocks[b].term {
            Br(c, _, _) => term_used[c] = true
            Switch(c, _) => term_used[c] = true
            Ret(vs) => {
                for u in vs {
                    term_used[u] = true
                }
            }
            _ => {}
        }
    }
    // the recorded users of x, in the order recorded: pairs[2 * e + 1] for e = head[x],
    // unext[e], .. until -1 (the lists are made from the end)
    total := pairs.len / 2
    head := alloc_neg1(n)
    unext := mkslice[i32](__alloc_raw(total * 4), total)
    for k in total - 1..=0 by -1 {
        x := pairs[2 * k]
        unext[k] = head[x]
        head[x] = i32(k)
    }
    // access[v] = var + 1 for a load or store of a promoted slot (0: none)
    access := alloc[i32](n)
    naccess := 0
    var_ty := vec[T]()
    // derived_of[x] == a + 1: x is a (constant offset) pointer into alloca a
    derived_of := alloc[i32](n)
    derived := vec[(i64, i64)]()
    accs := vec[(i64, i64, T)]()
    slots := vec[(i64, T)]()
    dvs := vec[(i64, i64)]() // -g: (var, the variable of the debug information)
    allocas: for a in f.blocks[0].insts {
        if f.insts[a].op != Alloca || term_used[a] || !ptrs[a] {
            continue
        }
        derived.clear()
        derived.push((i64(a), 0))
        derived_of[a] = a + 1
        accs.clear()
        qi := 0
        while qi < derived.len {
            x := derived[qi].0
            off := derived[qi].1
            qi += 1
            if term_used[x] {
                continue allocas
            }
            e := i64(head[x])
            while e >= 0 {
                u := i64(pairs[2 * e + 1])
                e = i64(unext[e])
                inst := &f.insts[u]
                if inst.op == Add {
                    other := if inst.args[0] == x { inst.args[1] } else { inst.args[0] }
                    if other == x {
                        continue allocas
                    }
                    oi := &f.insts[other]
                    if oi.op != Const {
                        continue allocas
                    }
                    if derived_of[u] != a + 1 {
                        derived_of[u] = a + 1
                        derived.push((u, off + oi.k))
                    }
                } else if inst.op == Load {
                    accs.push((u, off, inst.ty))
                } else if inst.op == Store {
                    if inst.args[1] == x || inst.args[0] != x {
                        continue allocas
                    }
                    accs.push((u, off, inst.ty))
                } else {
                    continue allocas
                }
            }
        }
        // stored values must not be derived pointers of this alloca
        for acc in accs {
            u := acc.0
            if f.insts[u].op == Store && derived_of[f.insts[u].args[1]] == a + 1 {
                continue allocas
            }
        }
        // slots: (offset, type); promotable when no partial overlap with a different slot
        size := f.insts[a].k
        slots.clear()
        for acc in accs {
            if !contains(&slots, (acc.1, acc.2)) {
                slots.push((acc.1, acc.2))
            }
        }
        slot_var := vec_fill(slots.len, NOV)
        for i in 0..slots.len {
            o1 := slots[i].0
            s1 := slots[i].1.size()
            ok := o1 >= 0 && o1 + s1 <= size
            for j in 0..slots.len {
                if i == j {
                    continue
                }
                o2 := slots[j].0
                if o1 < o2 + slots[j].1.size() && o2 < o1 + s1 {
                    ok = false
                }
            }
            if ok {
                slot_var[i] = var_ty.len
                var_ty.push(slots[i].1)
            }
        }
        // -g: a variable promoted whole (one slot at its start, of its size) is recorded
        if f.drec {
            k := dbg_var_of(&f.insts[a])
            if k >= 0 && slots.len == 1 && slot_var[0] != NOV && slots[0].0 == 0 && slots[0].1.size() == size {
                dvs.push((slot_var[0], k))
            }
        }
        for acc in accs {
            si := index_of(slots.items(), (acc.1, acc.2))
            if slot_var[si] != NOV {
                if access[acc.0] == 0 {
                    naccess += 1
                }
                access[acc.0] = i32(slot_var[si] + 1)
            }
        }
    }
    if naccess == 0 {
        return false
    }
    preds := cfg_preds(f)
    nb := f.blocks.len
    // last store per (var, block); has_store[b]: block b stores to a var
    last_store := imap_new(naccess)
    has_store := alloc[bool](nb)
    for b in rpo {
        for v in f.blocks[b].insts {
            var_ := i64(access[v]) - 1
            if var_ >= 0 && f.insts[v].op == Store {
                last_store.iset(var_ * nb + b, f.insts[v].args[1])
                has_store[b] = true
            }
        }
    }
    repl := vec_fill(n, i32(NOV))
    nvar := var_ty.len
    cx := Ctx{f: f, preds: preds, var_ty: var_ty, nb: nb, last_store: last_store, has_store: has_store, def_in: imap_new(4 * naccess), new_phis: vec[(i64, i64)](), entry_consts: vec[i32](), zero: [10]i64{NOV, NOV, NOV, NOV, NOV, NOV, NOV, NOV, NOV, NOV}, walk: vec[(i64, i64, i64)]()}
    // the value of each var in the current block: cur_val[var] when cur_blk[var] == b
    cur_val := alloc[i64](nvar)
    cur_blk := vec_fill(nvar, NOV)
    // -g: the blocks as they are before the loads and stores go (see record)
    orig := vec[Vec[i32]]()
    if !dvs.is_empty() {
        for b in rpo {
            orig.push(vec_of(f.blocks[b].insts.items()))
        }
    }
    for b in rpo {
        // the kept instructions are a subsequence: compacted in place
        insts := &cx.f.blocks[b].insts
        kept := 0
        for ii in 0..insts.len {
            v := insts[ii]
            var_ := i64(access[v]) - 1
            if var_ >= 0 {
                if cx.f.insts[v].op == Store {
                    cur_val[var_] = cx.f.insts[v].args[1]
                    cur_blk[var_] = b
                } else {
                    if cur_blk[var_] != b {
                        cur_val[var_] = cx.read_in(var_, b)
                        cur_blk[var_] = b
                    }
                    repl[v] = i32(cur_val[var_])
                }
            } else {
                insts[kept] = v
                kept += 1
            }
        }
        insts.len = kept
    }
    if !dvs.is_empty() {
        record(&cx, rpo.items(), &orig, access, &dvs, &repl)
    }
    new_phis := cx.new_phis
    // insert phis at block heads (in the order they were made), constants at the entry
    if !new_phis.is_empty() {
        // the phis of block b: by_blk[start[b]..start[b + 1]]
        start := alloc[i64](nb + 1)
        for bp in new_phis {
            start[bp.0 + 1] += 1
        }
        for b in 0..nb {
            start[b + 1] += start[b]
        }
        fill := clone(start)
        by_blk := alloc[i32](new_phis.len)
        for bp in new_phis {
            by_blk[fill[bp.0]] = i32(bp.1)
            fill[bp.0] += 1
        }
        for b in 0..nb {
            if start[b + 1] > start[b] {
                l := vec_of(by_blk[start[b]..start[b + 1]])
                l.extend(f.blocks[b].insts.items())
                f.blocks[b].insts = l
            }
        }
    }
    if !cx.entry_consts.is_empty() {
        // after allocas/phis is not required for constants; put them first
        e := cx.entry_consts
        e.extend(f.blocks[0].insts.items())
        f.blocks[0].insts = e
    }
    repl.resize(f.insts.len, NOV)
    f.apply_repl(&repl)
    cleanup_trivial_phis(f)
    cleanup_dce(f)
    return true
}

// -g (src/debug.al): records in f.dexp the value each promoted variable of the debug
// information (dvs: (var, variable)) has at the source location of every instruction, from
// the blocks as they were (orig, in the order of rpo): the value stored last, at the start of a
// block the one read_in found (def_in) or the one all predecessors end with. A location whose
// instructions see different values (or no value on some path) records -1.
priv fn record(cx: *Ctx, rpo: []i64, orig: *Vec[Vec[i32]], access: []i32, dvs: *Vec[(i64, i64)], repl: *Vec[i32]) {
    f := cx.f
    nb := cx.nb
    nd := dvs.len
    TOP := -2
    NONE := -3
    jof := vec_fill(cx.var_ty.len, -1)
    for j, x in *dvs {
        jof[x.0] = j
    }
    fn res(repl: *Vec[i32], v: i64) -> i64 {
        return repl_find(repl.items(), v)
    }
    fn meet(a: i64, b: i64) -> i64 {
        return if a == -2 { b } else if b == -2 || a == b { a } else { -1 }
    }
    // the value stored last in each block (TOP: none)
    lastv := vec_fill(nb * nd, TOP)
    for oi, b in rpo {
        for v in orig[oi] {
            var_ := i64(access[v]) - 1
            if var_ >= 0 && f.insts[v].op == Store && jof[var_] >= 0 {
                lastv[b * nd + jof[var_]] = res(repl, f.insts[v].args[1])
            }
        }
    }
    ent := vec_fill(nb * nd, TOP)
    out := vec_fill(nb * nd, TOP)
    changed := true
    while changed {
        changed = false
        for oi, b in rpo {
            for j in 0..nd {
                e := TOP
                d := cx.def_in.iget(dvs[j].0 * nb + b)
                if d >= 0 {
                    e = res(repl, d)
                } else if oi == 0 {
                    e = NONE
                } else {
                    for p in cx.preds[b] {
                        e = meet(e, out[p * nd + j])
                    }
                }
                o := if lastv[b * nd + j] != TOP { lastv[b * nd + j] } else { e }
                if ent[b * nd + j] != e || out[b * nd + j] != o {
                    ent[b * nd + j] = e
                    out[b * nd + j] = o
                    changed = true
                }
            }
        }
    }
    // (location, variable, value) at every instruction with a location (once per run of
    // instructions of one location with the same values)
    recs := vec[(i64, i64, i64)]()
    st := vec_fill(nd, NONE)
    for oi, b in rpo {
        for j in 0..nd {
            st[j] = ent[b * nd + j]
        }
        last_l := -1
        for v in orig[oi] {
            i := &f.insts[v]
            l := if i.op == Phi { 0 } else { i64(i.cap) }
            if l > 0 && l != last_l {
                for j in 0..nd {
                    s := st[j]
                    if s >= 0 || s == -1 {
                        recs.push((l, dvs[j].1, s))
                    }
                }
                last_l = l
            }
            var_ := i64(access[v]) - 1
            if var_ >= 0 && i.op == Store && jof[var_] >= 0 {
                st[jof[var_]] = res(repl, i.args[1])
                last_l = -1
            }
        }
    }
    // each (location, variable, value) once: two values of a variable at one location stay
    // two entries (a phi made here may turn out equal to the other value: apply_repl), which
    // isel takes for "unknown" if they still differ
    sort_by(recs.items(), fn(a: (i64, i64, i64), b: (i64, i64, i64)) -> bool { a.0 < b.0 || a.0 == b.0 && (a.1 < b.1 || a.1 == b.1 && a.2 < b.2) })
    for k in 0..recs.len {
        if k == 0 || recs[k] != recs[k - 1] {
            f.dexp.push(DbgExp{loc: i32(recs[k].0), var: i32(recs[k].1), val: i32(recs[k].2)})
        }
    }
}
