// Dominator-scoped global value numbering for pure instructions, plus propagation of
// branch conditions into dominated blocks (removes repeated checks).

priv fn numberable(op: Op) -> bool {
    return op.is_pure() || op == SDiv || op == UDiv || op == SRem || op == URem || op == Proj
}

// The instructions in scope, by their key (op, type, arguments (the two of a commutative op in
// increasing order), k). An entry is the instruction itself: its key fields do not change while
// it is in scope. Entries go in the reverse order they came (the walk leaves a block after its
// children), so the table is a stack with hash chains.
priv struct Table {
    head: []i32 // per hash bucket: the newest entry, -1 if none
    ent: Vec[i32] // the instruction
    next: Vec[i32] // the older entry of the same bucket
    bucket: Vec[i32]
}

priv fn table_new(n: i64) -> Table {
    cap := 16
    while cap < 2 * n {
        cap *= 2
    }
    return Table{head: alloc_neg1(cap), ent: vec[i32](), next: vec[i32](), bucket: vec[i32]()}
}

// the arguments of instruction i in key order
priv inline fn key_args(i: *Inst) -> (i64, i64) {
    if i.args.len != 2 {
        return (0, 0)
    }
    a := i.args[0]
    b := i.args[1]
    if i.op.is_commutative() && a > b {
        return (b, a)
    }
    return (a, b)
}

priv fn key_hash(i: *Inst) -> i64 {
    h := (u64(i64(i.op)) * 31 + u64(i64(i.ty))) * 0x9E3779B97F4A7C15 + u64(i.k)
    if i.args.len == 2 {
        a, b := key_args(i)
        h = (h ^ u64(a)) * 0x9E3779B97F4A7C15
        h = (h ^ u64(b)) * 0x9E3779B97F4A7C15
    } else {
        for x in i.args {
            h = (h ^ u64(x)) * 0x9E3779B97F4A7C15
        }
    }
    h = (h ^ u64(i.args.len)) * 0x9E3779B97F4A7C15
    return i64(h >> 32)
}

priv fn same_key(i: *Inst, j: *Inst) -> bool {
    if i.op != j.op || i.ty != j.ty || i.k != j.k || i.args.len != j.args.len {
        return false
    }
    if i.args.len == 2 {
        a1, b1 := key_args(i)
        a2, b2 := key_args(j)
        return a1 == a2 && b1 == b2
    }
    for x in 0..i.args.len {
        if i.args[x] != j.args[x] {
            return false
        }
    }
    return true
}

// the instruction in scope with the key of v, or NOV
priv fn lookup(t: *Table, f: *Func, v: i64, h: i64) -> i64 {
    i := &f.insts[v]
    e := t.head[h & (len(t.head) - 1)]
    while e >= 0 {
        w := t.ent[e]
        if same_key(i, &f.insts[w]) {
            return i64(w)
        }
        e = t.next[e]
    }
    return NOV
}

priv fn add(t: *Table, v: i64, h: i64) {
    bk := h & (len(t.head) - 1)
    t.ent.push(i32(v))
    t.next.push(t.head[bk])
    t.bucket.push(i32(bk))
    t.head[bk] = i32(t.ent.len - 1)
}

// remove the entries above `mark`
priv fn pop_to(t: *Table, mark: i64) {
    while t.ent.len > mark {
        e := t.ent.len - 1
        t.head[t.bucket[e]] = t.next[e]
        t.ent.len = e
        t.next.len = e
        t.bucket.len = e
    }
}

// the conditions known in a block: known[c] is 0 (unknown), 1 (false) or 2 (true)
priv fn known_at(known: *Vec[u8], c: i64) -> u8 {
    if c < known.len {
        return known[c]
    }
    return 0
}

priv fn known_set(known: *Vec[u8], c: i64, s: u8) {
    if c >= known.len {
        known.resize(c + 1, 0)
    }
    known[c] = s
}

priv fn eqv_at(eqv: *Vec[i32], v: i64) -> i64 {
    return if v < eqv.len && eqv[v] >= 0 { i64(eqv[v]) } else { NOV }
}

priv fn eqv_set(eqv: *Vec[i32], v: i64, x: i64) {
    if v >= eqv.len {
        eqv.resize(v + 1, i32(NOV))
    }
    eqv[v] = i32(x)
}

// ---------- comparisons implied by known conditions ----------
// the known value (0 unknown, 1 false, 2 true) of comparison `op a b`, from an equal, negated
// or swapped comparison in scope
priv fn cmp_in_scope(t: *Table, f: *Func, known: *Vec[u8], op: Op, a: i64, b: i64) -> u8 {
    for form in 0..4 {
        o := op
        x := a
        y := b
        if form & 1 != 0 {
            o = o.negate_icmp()
        }
        if form & 2 != 0 {
            o = o.swap_cmp()
            x, y = (b, a)
        }
        probe := Inst{op: o, ty: I8, args: []i64{x, y}, k: 0, aux: 0, cap: 0}
        h := key_hash(&probe)
        e := t.head[h & (len(t.head) - 1)]
        while e >= 0 {
            w := i64(t.ent[e])
            if same_key(&probe, &f.insts[w]) {
                kn := known_at(known, w)
                if kn != 0 {
                    return if form & 1 != 0 { 3 - kn } else { kn }
                }
                break
            }
            e = t.next[e]
        }
    }
    return 0
}

// the value of comparison `op x y` decided by the branch into `blk` from `p` or by a branch
// above p that p can only be reached through (`x` and `y` are compared by value: equal
// constants are the same); 0 if unknown
priv fn cmp_on_edge(f: *Func, cfg: *Cfg, p: i64, blk: i64, op: Op, x: i64, y: i64) -> u8 {
    fn same_val(f: *Func, a: i64, b: i64) -> bool {
        if a == b {
            return true
        }
        match (f.is_const(a), f.is_const(b)) {
            (Some(i), Some(j)) => i == j && f.insts[a].ty == f.insts[b].ty
            _ => false
        }
    }
    match (f.is_const(x), f.is_const(y)) {
        (Some(i), Some(j)) => {
            return match simplify_fold_icmp(op, f.insts[x].ty, i, j) {
                Some(r) => if r { u8(2) } else { u8(1) }
                None => u8(0)
            }
        }
        _ => {}
    }
    to := blk
    from := p
    for depth in 0..8 {
        match f.blocks[from].term {
            Br(c, t, e) if t != e && (t == to || e == to) => {
                ci := &f.insts[c]
                if ci.op.is_icmp() && ci.args.len == 2 {
                    // the branch's condition is true on the way to `to` exactly when `taken`
                    taken := t == to
                    for form in 0..4 {
                        o := ci.op
                        a := ci.args[0]
                        b := ci.args[1]
                        if form & 1 != 0 {
                            o = o.negate_icmp()
                        }
                        if form & 2 != 0 {
                            o = o.swap_cmp()
                            a, b = (b, a)
                        }
                        if o == op && same_val(f, a, x) && same_val(f, b, y) {
                            r := taken != (form & 1 != 0)
                            return if r { u8(2) } else { u8(1) }
                        }
                    }
                }
            }
            _ => {}
        }
        if cfg.preds[from].len != 1 {
            return 0
        }
        to = from
        from = cfg.preds[from][0]
    }
    return 0
}

// the known value of comparison v (see the call in gvn_run)
priv fn implied_cmp(t: *Table, f: *Func, cfg: *Cfg, known: *Vec[u8], def_block: *Vec[i32], v: i64) -> u8 {
    i := &f.insts[v]
    if i.args.len != 2 {
        return 0
    }
    op := i.op
    a := i.args[0]
    b := i.args[1]
    kv := cmp_in_scope(t, f, known, op, a, b)
    if kv != 0 {
        return kv
    }
    // `phi op y`: decided on each way into the phi's block (y defined above that block)
    if f.insts[a].op != Phi && f.insts[b].op == Phi {
        op = op.swap_cmp()
        a, b = (b, a)
    }
    pi := &f.insts[a]
    if pi.op != Phi || f.insts[b].op == Phi || pi.args.len == 0 || pi.args.len > 8 {
        return 0
    }
    if def_block.len == 0 {
        *def_block = f.block_of()
    }
    if a >= def_block.len || def_block[a] == NOV {
        return 0
    }
    blk := i64(def_block[a])
    if cfg.rpo_idx[blk] == NOV || cfg.preds[blk].len != pi.args.len {
        return 0
    }
    // y must be defined above blk: its value is then the same on the way in as in blk
    if !is_some(f.is_const(b)) && (b >= def_block.len || def_block[b] == NOV || i64(def_block[b]) == blk || !cfg.dom(i64(def_block[b]), blk)) {
        return 0
    }
    fr := pi.from()
    res := u8(0)
    for k in 0..pi.args.len {
        x := pi.args[k]
        if x == a {
            // the phi keeps its value on this way in
            continue
        }
        r := cmp_on_edge(f, cfg, fr[k], blk, op, x, b)
        if r == 0 || (res != 0 && r != res) {
            return 0
        }
        res = r
    }
    return res
}

fn gvn_run(f: *Func) -> bool {
    cfg := cfg_new(f)
    repl := vec_fill(f.insts.len, i32(NOV))
    table := table_new(f.insts.len)
    known := Vec[u8]{buf: alloc[u8](f.insts.len), len: f.insts.len}
    changed := false
    def_block := vec[i32]() // the block of every instruction, made when first needed
    implied_on := opt_enabled("gvnimply")
    bool_consts := [2]i64{NOV, NOV}
    // eqv[v]: the fact (index in facts: the key of a Switch case and the constant made for it,
    // or NOV) that v is equal to in the current block, or NOV; the constants made go to the
    // top of the entry block
    eqv := vec[i32]()
    facts := vec[(i64, i64)]()
    consts := vec[i32]()
    // the walk over the dominator tree: (b, -1, ..) enters block b; (-1, mark, c, old) leaves
    // a block: entries above `mark` go, known[c] (if c is not NOV) is old again
    stack := vec_of([](i64, i64, i64, u8){(0, -1, NOV, u8(0))})
    while !stack.is_empty() {
        b, top, fact_c, fact_v := stack.pop()
        if b == -2 {
            // leaves the blocks where value `top` was known: its old constant again
            eqv_set(&eqv, top, fact_c)
            continue
        }
        if b < 0 {
            pop_to(&table, top)
            if fact_c != NOV {
                known_set(&known, fact_c, fact_v)
            }
            continue
        }
        fact := NOV
        fact_old := u8(0)
        // a block reached only through one arm of a conditional branch knows the condition
        if cfg.preds[b].len == 1 {
            p := cfg.preds[b][0]
            match f.blocks[p].term {
                Br(c0, t, e) if t != e => {
                    c := repl_find(repl.items(), c0)
                    fact = c
                    fact_old = known_at(&known, c)
                    known_set(&known, c, if t == b { u8(2) } else { u8(1) })
                }
                Switch(c0, tab) => {
                    // the only case that goes to b: the value is its key here
                    c := repl_find(repl.items(), c0)
                    k := sw_only_key(&tab, b)
                    if k.0 && f.insts[c].op != Const {
                        stack.push((-2, c, eqv_at(&eqv, c), u8(0)))
                        facts.push((k.1, NOV))
                        eqv_set(&eqv, c, facts.len - 1)
                    }
                }
                _ => {}
            }
        }
        mark := table.ent.len
        // the kept instructions are compacted in place
        insts := &f.blocks[b].insts
        kept := 0
        for ii in 0..insts.len {
            v := insts[ii]
            for ai in 0..f.insts[v].args.len {
                a := f.insts[v].args[ai]
                r := repl_find(repl.items(), a)
                ev := eqv_at(&eqv, r)
                if ev != NOV {
                    if facts[ev].1 == NOV {
                        facts[ev].1 = f.mk(Const, f.insts[r].ty, vec[i64](), facts[ev].0)
                        repl.push(NOV)
                        consts.push(i32(facts[ev].1))
                    }
                    r = facts[ev].1
                    changed = true
                }
                // a condition decided by a dominating branch is a constant here
                kn := known_at(&known, r)
                if kn != 0 {
                    if f.insts[r].op != Const {
                        // the constants live at the top of the entry block
                        slot := i64(kn) - 1
                        if bool_consts[slot] == NOV {
                            bool_consts[slot] = f.mk(Const, I8, vec[i64](), slot)
                            repl.push(NOV)
                        }
                        r = bool_consts[slot]
                        changed = true
                    }
                }
                if r != a {
                    f.insts[v].args[ai] = r
                }
            }
            if !numberable(f.insts[v].op) {
                insts[kept] = v
                kept += 1
                continue
            }
            h := key_hash(&f.insts[v])
            w := lookup(&table, f, i64(v), h)
            if w != NOV {
                repl[v] = i32(w)
                changed = true
            } else {
                if f.insts[v].op.is_icmp() && implied_on {
                    // a comparison a dominating branch decides in another form, or one whose
                    // phi operand is decided on every way into its block: its uses (which this
                    // block dominates) see the constant
                    kv := implied_cmp(&table, f, &cfg, &known, &def_block, i64(v))
                    if kv != 0 {
                        known_set(&known, i64(v), kv)
                    }
                }
                add(&table, i64(v), h)
                insts[kept] = v
                kept += 1
            }
        }
        insts.len = kept
        match f.blocks[b].term {
            Br(c0, t, e) => {
                c := repl_find(repl.items(), c0)
                kn := known_at(&known, c)
                if kn != 0 {
                    f.blocks[b].term = Jmp(if kn == 2 { t } else { e })
                    changed = true
                }
            }
            Switch(c0, tab) => {
                ev := eqv_at(&eqv, repl_find(repl.items(), c0))
                if ev != NOV {
                    f.blocks[b].term = Jmp(sw_target_of(&tab, facts[ev].0))
                    changed = true
                }
            }
            _ => {}
        }
        stack.push((-1, mark, fact, fact_old))
        for ci in cfg.children[b].len - 1..=0 by -1 {
            stack.push((cfg.children[b][ci], -1, NOV, u8(0)))
        }
    }
    extra := vec[i32]()
    for c in bool_consts {
        if c != NOV {
            extra.push(i32(c))
        }
    }
    extra.extend(consts.items())
    if !extra.is_empty() {
        // after the entry block's phis there are none: block 0 has no predecessors
        e := extra
        e.extend(f.blocks[0].insts.items())
        f.blocks[0].insts = e
    }
    if changed {
        f.apply_repl(&repl)
        cleanup_prune_unreachable(f)
    }
    return changed
}
