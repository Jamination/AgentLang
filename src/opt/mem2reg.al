// Promote non-escaping stack slots to SSA values (with scalar replacement of aggregates).

priv struct Ctx {
    f: *Func,
    cfg: *Cfg,
    var_ty: Vec[T],
    last_store: Map[(i64, i64), i64],
    def_in: Map[(i64, i64), i64],
    new_phis: Vec[(i64, i64)],
    entry_consts: Vec[i64],
    zero: Map[T, i64],
}

priv fn zero_of(self: *Ctx, t: T) -> i64 {
    z0, found := self.zero.get(t)
    if found {
        return z0
    }
    z := 0
    if t.is_fp() {
        z = self.f.mk(FConst, t, vec[i64](), 0)
    } else {
        z = self.f.mk(Const, t, vec[i64](), 0)
    }
    self.entry_consts.push(z)
    self.zero.set(t, z)
    return z
}

priv fn read_out(self: *Ctx, var_: i64, b: i64) -> i64 {
    v, found := self.last_store.get((var_, b))
    if found {
        return v
    }
    return self.read_in(var_, b)
}

priv fn read_in(self: *Ctx, var_: i64, b: i64) -> i64 {
    v0, found := self.def_in.get((var_, b))
    if found {
        return v0
    }
    np := self.cfg.preds[b].len
    v := 0
    if np == 0 {
        v = self.zero_of(self.var_ty[var_])
    } else if np == 1 {
        p := self.cfg.preds[b][0]
        // guard against a self-loop of a single block
        if p == b {
            v = self.zero_of(self.var_ty[var_])
        } else {
            v = self.read_out(var_, p)
        }
    } else {
        phi := self.f.mk(Phi, self.var_ty[var_], vec[i64](), 0)
        self.def_in.set((var_, b), phi)
        self.new_phis.push((b, phi))
        preds := clone(self.cfg.preds[b])
        for p in preds {
            a := self.read_out(var_, p)
            inst := self.f.im(phi)
            inst.args.push(a)
            inst.pb.push(p)
        }
        v = phi
    }
    self.def_in.set((var_, b), v)
    return v
}

fn mem2reg_run(f: *Func) -> bool {
    any := false
    for it in 0..8 {
        if !run_once(f) {
            break
        }
        any = true
    }
    return any
}

priv fn run_once(f: *Func) -> bool {
    cfg := cfg_new(f)
    n := f.insts.len
    // users of each value (instruction users only) + escape through terminators
    users := vec_fill(n, vec[i64]())
    term_used := vec_fill(n, false)
    for b in cfg.rpo {
        for v in f.blocks[b].insts {
            for a in f.insts[v].args {
                users[a].push(v)
            }
        }
        tu := f.term_uses(b)
        for u in tu {
            term_used[u] = true
        }
    }
    // access: inst -> var
    access := map[i64, i64]()
    var_ty := vec[T]()
    allocas := vec[i64]()
    for v in f.blocks[0].insts {
        if f.insts[v].op == Alloca {
            allocas.push(v)
        }
    }
    for a in allocas {
        escaped := term_used[a]
        derived := vec_of([](i64, i64){(a, 0)})
        is_derived := map[i64, i64]()
        is_derived.set(a, 0)
        accs := vec[(i64, i64, T)]()
        qi := 0
        while qi < derived.len && !escaped {
            x := derived[qi].0
            off := derived[qi].1
            qi += 1
            if term_used[x] {
                escaped = true
                break
            }
            for u in users[x] {
                inst := &f.insts[u]
                if inst.op == Add {
                    other := if inst.args[0] == x { inst.args[1] } else { inst.args[0] }
                    if other == x {
                        escaped = true
                        break
                    }
                    match f.is_const(other) {
                        Some(c) => {
                            had := is_derived.has(u)
                            is_derived.set(u, off + c)
                            if !had {
                                derived.push((u, off + c))
                            }
                        }
                        None => {
                            escaped = true
                            break
                        }
                    }
                } else if inst.op == Load {
                    accs.push((u, off, inst.ty))
                } else if inst.op == Store {
                    if inst.args[1] == x || inst.args[0] != x {
                        escaped = true
                        break
                    }
                    accs.push((u, off, inst.ty))
                } else {
                    escaped = true
                    break
                }
            }
        }
        if escaped {
            continue
        }
        // stored values must not be derived pointers of this alloca
        stores_derived := false
        for acc in accs {
            u := acc.0
            if f.insts[u].op == Store && is_derived.has(f.insts[u].args[1]) {
                stores_derived = true
                break
            }
        }
        if stores_derived {
            continue
        }
        // slots: (offset, type); promotable when no partial overlap with a different slot
        size := f.insts[a].k
        slots := vec[(i64, T)]()
        for acc in accs {
            if !contains(&slots, (acc.1, acc.2)) {
                slots.push((acc.1, acc.2))
            }
        }
        ok := vec_fill(slots.len, true)
        for i in 0..slots.len {
            o1 := slots[i].0
            t1 := slots[i].1
            if o1 < 0 || o1 + t1.size() > size {
                ok[i] = false
            }
            for j in 0..slots.len {
                if i == j {
                    continue
                }
                o2 := slots[j].0
                t2 := slots[j].1
                if o1 < o2 + t2.size() && o2 < o1 + t1.size() {
                    ok[i] = false
                }
            }
        }
        slot_var := vec_fill(slots.len, 0xFFFFFFFF)
        for i in 0..slots.len {
            if ok[i] {
                slot_var[i] = var_ty.len
                var_ty.push(slots[i].1)
            }
        }
        for acc in accs {
            si := index_of(slots.items(), (acc.1, acc.2))
            assert si >= 0
            if ok[si] {
                access.set(acc.0, slot_var[si])
            }
        }
    }
    if access.len == 0 {
        return false
    }
    // last store per (var, block)
    last_store := map[(i64, i64), i64]()
    for b in cfg.rpo {
        for v in f.blocks[b].insts {
            if f.insts[v].op == Store {
                var_, found := access.get(v)
                if found {
                    last_store.set((var_, b), f.insts[v].args[1])
                }
            }
        }
    }
    repl := vec_fill(n, NOV)
    rpo := clone(cfg.rpo)
    cx := Ctx{f: f, cfg: &cfg, var_ty: var_ty, last_store: last_store, def_in: map[(i64, i64), i64](), new_phis: vec[(i64, i64)](), entry_consts: vec[i64](), zero: map[T, i64]()}
    for b in rpo {
        insts := clone(cx.f.blocks[b].insts)
        cur := map[i64, i64]()
        keep := vec[i64]()
        for v in insts {
            var_, found := access.get(v)
            if found {
                if cx.f.insts[v].op == Store {
                    cur.set(var_, cx.f.insts[v].args[1])
                } else {
                    val, have := cur.get(var_)
                    if !have {
                        val = cx.read_in(var_, b)
                        cur.set(var_, val)
                    }
                    if repl.len < cx.f.insts.len {
                        repl.resize(cx.f.insts.len, NOV)
                    }
                    repl[v] = val
                }
            } else {
                keep.push(v)
            }
        }
        cx.f.blocks[b].insts = keep
    }
    new_phis := cx.new_phis
    entry_consts := cx.entry_consts
    // insert phis at block heads, constants at the entry
    by_block := map[i64, Vec[i64]]()
    for bp in new_phis {
        ps := by_block.get_or(bp.0, vec[i64]())
        ps.push(bp.1)
        by_block.set(bp.0, ps)
    }
    // the Rust iterates the HashMap; blocks are independent of each other, sorted for determinism
    bkeys := by_block.keys()
    sort(bkeys)
    for b in bkeys {
        ps := by_block.get_or(b, vec[i64]())
        ps.extend(f.blocks[b].insts.items())
        f.blocks[b].insts = ps
    }
    if !entry_consts.is_empty() {
        // after allocas/phis is not required for constants; put them first
        e := entry_consts
        e.extend(f.blocks[0].insts.items())
        f.blocks[0].insts = e
    }
    repl.resize(f.insts.len, NOV)
    f.apply_repl(&repl)
    cleanup_trivial_phis(f)
    cleanup_dce(f)
    return true
}
