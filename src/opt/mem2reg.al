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
}

priv fn zero_of(self: *Ctx, t: T) -> i64 {
    z0 := self.zero[i64(t)]
    if z0 != NOV {
        return z0
    }
    z := 0
    if t.is_fp() {
        z = self.f.mk(FConst, t, vec[i64](), 0)
    } else {
        z = self.f.mk(Const, t, vec[i64](), 0)
    }
    self.entry_consts.push(i32(z))
    self.zero[i64(t)] = z
    return z
}

priv fn read_out(self: *Ctx, var_: i64, b: i64) -> i64 {
    if self.has_store[b] {
        v := self.last_store.iget(var_ * self.nb + b)
        if v >= 0 {
            return v
        }
    }
    return self.read_in(var_, b)
}

priv fn read_in(self: *Ctx, var_: i64, b: i64) -> i64 {
    key := var_ * self.nb + b
    v0 := self.def_in.iget(key)
    if v0 >= 0 {
        return v0
    }
    preds := self.preds[b]
    np := preds.len
    v := 0
    if np == 0 {
        v = self.zero_of(self.var_ty[var_])
    } else if np == 1 {
        p := preds[0]
        // guard against a self-loop of a single block
        if p == b {
            v = self.zero_of(self.var_ty[var_])
        } else {
            v = self.read_out(var_, p)
        }
    } else {
        phi := self.f.mk_phi(self.var_ty[var_], np)
        self.def_in.iset(key, phi)
        self.new_phis.push((b, phi))
        for p in preds {
            a := self.read_out(var_, p)
            self.f.im(phi).phi_add(a, p)
        }
        v = phi
    }
    self.def_in.iset(key, v)
    return v
}

// push for a list that usually has room (push itself is not inlined)
priv inline fn put(l: *Vec[i32], x: i32) {
    if l.len < len(l.buf) {
        l.buf[l.len] = x
        l.len += 1
    } else {
        l.push(x)
    }
}

// the last mem2reg_run ended with a round that changed nothing (not at its round limit)
priv settled: bool

fn mem2reg_settled() -> bool {
    return settled
}

fn mem2reg_run(f: *Func) -> bool {
    any := false
    settled = false
    for it in 0..8 {
        // (only the first round sees the IR the pass began with)
        if !run_once(f, it == 0) {
            settled = true
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
    esc, known := alias_escaped_known(f, opt_gen())
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
        if f.insts[v].op == Alloca {
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
                    put(&pairs, i32(a))
                    put(&pairs, v)
                }
                continue
            }
            for a in i.args {
                if ptrs[a] {
                    put(&pairs, i32(a))
                    put(&pairs, v)
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
    head := mkslice[i32](__alloc_raw(n * 4), n)
    memfill(ptr(head), 0xFF, n * 4)
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
    allocas: for a in f.blocks[0].insts {
        if f.insts[a].op != Alloca || term_used[a] {
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
    cx := Ctx{f: f, preds: preds, var_ty: var_ty, nb: nb, last_store: last_store, has_store: has_store, def_in: imap_new(4 * naccess), new_phis: vec[(i64, i64)](), entry_consts: vec[i32](), zero: [10]i64{NOV, NOV, NOV, NOV, NOV, NOV, NOV, NOV, NOV, NOV}}
    // the value of each var in the current block: cur_val[var] when cur_blk[var] == b
    cur_val := alloc[i64](nvar)
    cur_blk := vec_fill(nvar, NOV)
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
