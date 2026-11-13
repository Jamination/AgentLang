// Dominator-scoped global value numbering for pure instructions, plus propagation of
// branch conditions into dominated blocks (removes repeated checks).

priv fn numberable(op: Op) -> bool {
    return op.is_pure() || op == SDiv || op == UDiv || op == SRem || op == URem || op == Proj
}

priv fn run_find(repl: []i32, v0: i64) -> i64 {
    v := v0
    while repl[v] != NOV {
        v = i64(repl[v])
    }
    return v
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
    head := mkslice[i32](__alloc_raw(cap * 4), cap)
    memfill(ptr(head), 0xFF, cap * 4)
    return Table{head: head, ent: vec[i32](), next: vec[i32](), bucket: vec[i32]()}
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

fn gvn_run(f: *Func) -> bool {
    cfg := cfg_new(f)
    repl := vec_fill(f.insts.len, i32(NOV))
    table := table_new(f.insts.len)
    known := Vec[u8]{buf: alloc[u8](f.insts.len), len: f.insts.len}
    changed := false
    bool_consts := [2]i64{NOV, NOV}
    // the walk over the dominator tree: (b, -1, ..) enters block b; (-1, mark, c, old) leaves
    // a block: entries above `mark` go, known[c] (if c is not NOV) is old again
    stack := vec_of([](i64, i64, i64, u8){(0, -1, NOV, u8(0))})
    while stack.len > 0 {
        step := stack.pop()
        b := step.0
        if b < 0 {
            pop_to(&table, step.1)
            if step.2 != NOV {
                known_set(&known, step.2, step.3)
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
                    c := run_find(repl.items(), c0)
                    fact = c
                    fact_old = known_at(&known, c)
                    known_set(&known, c, if t == b { u8(2) } else { u8(1) })
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
                r := run_find(repl.items(), a)
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
                add(&table, i64(v), h)
                insts[kept] = v
                kept += 1
            }
        }
        insts.len = kept
        match f.blocks[b].term {
            Br(c0, t, e) => {
                c := run_find(repl.items(), c0)
                kn := known_at(&known, c)
                if kn != 0 {
                    if kn == 2 {
                        f.blocks[b].term = Jmp(t)
                    } else {
                        f.blocks[b].term = Jmp(e)
                    }
                    changed = true
                }
            }
            _ => {}
        }
        stack.push((-1, mark, fact, fact_old))
        ci := cfg.children[b].len - 1
        while ci >= 0 {
            stack.push((cfg.children[b][ci], -1, NOV, u8(0)))
            ci -= 1
        }
    }
    extra := vec[i32]()
    for c in bool_consts {
        if c != NOV {
            extra.push(i32(c))
        }
    }
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
