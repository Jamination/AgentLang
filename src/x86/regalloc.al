// Iterated register coalescing (George & Appel) over machine IR.

priv gpr_order := [15]i64{0, 1, 2, 6, 7, 8, 9, 10, 11, 3, 5, 12, 13, 14, 15}

priv struct BitSet {
    w: Vec[u64]
}

priv fn bit_set_new(n: i64) -> BitSet {
    return BitSet{w: vec_fill((n + 63) / 64, u64(0))}
}

priv fn set(self: *BitSet, i: i64) {
    self.w[i / 64] |= u64(1) << u64(i % 64)
}

fn clear(self: *BitSet, i: i64) {
    self.w[i / 64] &= ~(u64(1) << u64(i % 64))
}

priv fn union_with(self: *BitSet, o: *BitSet) -> bool {
    ch := false
    for wi in 0..min(self.w.len, o.w.len) {
        n := self.w[wi] | o.w[wi]
        if n != self.w[wi] {
            self.w[wi] = n
            ch = true
        }
    }
    return ch
}

priv fn liveness(mf: *MFunc, order: []i64) -> Vec[BitSet] {
    nreg := 32 + mf.vclass.len
    nb := mf.blocks.len
    gen := vec[BitSet]()
    kill := vec[BitSet]()
    for x in 0..nb {
        gen.push(bit_set_new(nreg))
    }
    for x in 0..nb {
        kill.push(bit_set_new(nreg))
    }
    defs := vec[i64]()
    uses := vec[i64]()
    for b in order {
        n := mf.blocks[b].insts.len
        for x in n - 1..=0 by -1 {
            mir_defs_uses(&mf.blocks[b].insts[x], &defs, &uses)
            for d in defs {
                gen[b].clear(d)
                kill[b].set(d)
            }
            for u in uses {
                gen[b].set(u)
            }
        }
    }
    live_in := vec[BitSet]()
    live_out := vec[BitSet]()
    for x in 0..nb {
        live_in.push(bit_set_new(nreg))
    }
    for x in 0..nb {
        live_out.push(bit_set_new(nreg))
    }
    changed := true
    while changed {
        changed = false
        for oi in len(order) - 1..=0 by -1 {
            b := order[oi]
            out := BitSet{w: clone(live_out[b].w)}
            for si in 0..mf.blocks[b].succs.len {
                s := mf.blocks[b].succs[si]
                out.union_with(&live_in[s])
            }
            live_out[b] = out
            // in = gen | (out - kill)
            ch := false
            for wi in 0..live_in[b].w.len {
                n := gen[b].w[wi] | (live_out[b].w[wi] & ~kill[b].w[wi])
                if n != live_in[b].w[wi] {
                    live_in[b].w[wi] = n
                    ch = true
                }
            }
            changed = changed || ch
        }
    }
    return live_out
}

priv enum NS {
    Pre,
    Initial,
    Simplify,
    Freeze,
    Spill,
    Spilled,
    Coalesced,
    Colored,
    Stack,
    Other, // different class
}

priv enum MS {
    Worklist,
    Active,
    Coalesced,
    Constrained,
    Frozen,
}

priv struct Irc {
    k: i64
    n: i64
    state: Vec[NS]
    adj_set: Map[u64, bool]
    adj: Vec[Vec[i64]]
    degree: Vec[i64]
    moves: Vec[(i64, i64)]
    mstate: Vec[MS]
    move_list: Vec[Vec[i64]]
    alias: Vec[i64]
    color: Vec[i64]
    simplify_wl: Vec[i64]
    freeze_wl: Vec[i64]
    spill_wl: Vec[i64]
    move_wl: Vec[i64]
    stack: Vec[i64]
    cost: Vec[f64]
}

fn pre(self: *Irc, n: i64) -> bool {
    return n < 32
}

priv fn add_edge(self: *Irc, u: i64, v: i64) {
    if u == v {
        return
    }
    key := (u64(min(u, v)) << 32) | u64(max(u, v))
    if !self.adj_set.has(key) {
        self.adj_set.set(key, true)
        if !self.pre(u) {
            self.adj[u].push(v)
            self.degree[u] += 1
        }
        if !self.pre(v) {
            self.adj[v].push(u)
            self.degree[v] += 1
        }
    }
}

priv fn has_edge(self: *Irc, u: i64, v: i64) -> bool {
    key := (u64(min(u, v)) << 32) | u64(max(u, v))
    return self.adj_set.has(key)
}

priv fn adjacent(self: *Irc, n: i64) -> Vec[i64] {
    out := vec[i64]()
    for m in self.adj[n] {
        st := self.state[m]
        if !(st == Stack || st == Coalesced) {
            out.push(m)
        }
    }
    return out
}

priv fn node_moves(self: *Irc, n: i64) -> Vec[i64] {
    out := vec[i64]()
    for m in self.move_list[n] {
        ms := self.mstate[m]
        if ms == Active || ms == Worklist {
            out.push(m)
        }
    }
    return out
}

priv fn move_related(self: *Irc, n: i64) -> bool {
    for m in self.move_list[n] {
        ms := self.mstate[m]
        if ms == Active || ms == Worklist {
            return true
        }
    }
    return false
}

priv fn get_alias(self: *Irc, n0: i64) -> i64 {
    n := n0
    while self.state[n] == Coalesced {
        n = self.alias[n]
    }
    return n
}

priv fn enable_moves(self: *Irc, n: i64) {
    nm := self.node_moves(n)
    for m in nm {
        if self.mstate[m] == Active {
            self.mstate[m] = Worklist
            self.move_wl.push(m)
        }
    }
}

priv fn decrement_degree(self: *Irc, m: i64) {
    if self.pre(m) {
        return
    }
    d := self.degree[m]
    // saturating_sub(1)
    self.degree[m] = if d > 0 { d - 1 } else { 0 }
    if d == self.k {
        self.enable_moves(m)
        adj := self.adjacent(m)
        for a in adj {
            self.enable_moves(a)
        }
        if self.state[m] == Spill {
            if self.move_related(m) {
                self.state[m] = Freeze
                self.freeze_wl.push(m)
            } else {
                self.state[m] = Simplify
                self.simplify_wl.push(m)
            }
        }
    }
}

priv fn simplify(self: *Irc, n: i64) {
    self.state[n] = Stack
    self.stack.push(n)
    adj := self.adjacent(n)
    for m in adj {
        self.decrement_degree(m)
    }
}

priv fn add_worklist(self: *Irc, u: i64) {
    if !self.pre(u) && self.state[u] == Freeze && !self.move_related(u) && self.degree[u] < self.k {
        self.state[u] = Simplify
        self.simplify_wl.push(u)
    }
}

fn ok(self: *Irc, t: i64, r: i64) -> bool {
    return self.pre(t) || self.degree[t] < self.k || self.has_edge(t, r)
}

priv fn conservative(self: *Irc, u: i64, v: i64) -> bool {
    seen := map[i64, bool]()
    k := 0
    au := self.adjacent(u)
    av := self.adjacent(v)
    for n in au {
        if !seen.has(n) {
            seen.set(n, true)
            if self.pre(n) || self.degree[n] >= self.k {
                k += 1
            }
        }
    }
    for n in av {
        if !seen.has(n) {
            seen.set(n, true)
            if self.pre(n) || self.degree[n] >= self.k {
                k += 1
            }
        }
    }
    return k < self.k
}

priv fn combine(self: *Irc, u: i64, v: i64) {
    // v is merged into u
    self.state[v] = Coalesced
    self.alias[v] = u
    ml := clone(self.move_list[v])
    if !self.pre(u) {
        for m in ml {
            if !contains(&self.move_list[u], m) {
                self.move_list[u].push(m)
            }
        }
        self.cost[u] += self.cost[v]
    }
    self.enable_moves(v)
    adj_v := self.adjacent(v)
    for t in adj_v {
        self.add_edge(t, u)
        self.decrement_degree(t)
    }
    if !self.pre(u) && self.degree[u] >= self.k && self.state[u] == Freeze {
        self.state[u] = Spill
        self.spill_wl.push(u)
    }
}

priv fn coalesce(self: *Irc, m: i64) {
    d, s := self.moves[m]
    x := self.get_alias(d)
    y := self.get_alias(s)
    u := x
    v := y
    if self.pre(y) {
        u = y
        v = x
    }
    if u == v {
        self.mstate[m] = Coalesced
        self.add_worklist(u)
    } else if self.pre(v) || self.has_edge(u, v) {
        self.mstate[m] = Constrained
        self.add_worklist(u)
        self.add_worklist(v)
    } else {
        can := false
        if self.pre(u) {
            can = true
            adj := self.adjacent(v)
            for t in adj {
                if !self.ok(t, u) {
                    can = false
                    break
                }
            }
        } else {
            can = self.conservative(u, v)
        }
        if can {
            self.mstate[m] = Coalesced
            self.combine(u, v)
            self.add_worklist(u)
        } else {
            self.mstate[m] = Active
        }
    }
}

priv fn freeze_moves(self: *Irc, u: i64) {
    nm := self.node_moves(u)
    for m in nm {
        x, y := self.moves[m]
        v := if self.get_alias(y) == self.get_alias(u) { self.get_alias(x) } else { self.get_alias(y) }
        self.mstate[m] = Frozen
        if !self.pre(v) && self.state[v] == Freeze && !self.move_related(v) && self.degree[v] < self.k {
            self.state[v] = Simplify
            self.simplify_wl.push(v)
        }
    }
}

priv fn run(self: *Irc) {
    loop {
        if self.simplify_wl.len > 0 {
            n := self.simplify_wl.pop()
            if self.state[n] == Simplify {
                self.simplify(n)
            }
        } else if self.move_wl.len > 0 {
            m := self.move_wl.pop()
            if self.mstate[m] == Worklist {
                self.coalesce(m)
            }
        } else if self.freeze_wl.len > 0 {
            u := self.freeze_wl.pop()
            if self.state[u] == Freeze {
                self.state[u] = Simplify
                self.simplify_wl.push(u)
                self.freeze_moves(u)
            }
        } else {
            // select a spill candidate: lowest cost / degree
            best: Opt[(i64, f64)] = None
            for i in 0..self.spill_wl.len {
                n := self.spill_wl[i]
                if self.state[n] != Spill {
                    continue
                }
                c := self.cost[n] / f64(max(self.degree[n], 1))
                better := match best {
                    Some(b) => c < b.1
                    None => true
                }
                if better {
                    best = Some((i, c))
                }
            }
            match best {
                Some(b) => {
                    n := self.spill_wl.swap_remove(b.0)
                    self.state[n] = Simplify
                    self.simplify_wl.push(n)
                    self.freeze_moves(n)
                }
                None => {
                    break
                }
            }
        }
    }
}

struct Alloc {
    used_callee_saved: Vec[i64]
}

priv fn spill_slot(o: Opnd, first_spill: i64) -> Opt[i64] {
    match o {
        M(m) => {
            if m.kind == Slot && i64(m.id) >= first_spill && i64(m.base) == NOREG && i64(m.idx) == NOREG && i64(m.disp) == 0 {
                return Some(i64(m.id))
            }
        }
        _ => {}
    }
    return None
}

// index of the first entry of `st` for slot `s`, or -1
priv fn find_slot(st: *Vec[(i64, i64)], s: i64) -> i64 {
    for x in 0..st.len {
        if st[x].0 == s {
            return x
        }
    }
    return -1
}

// index of the first entry of `st` held in register `r`, or -1
priv fn find_reg(st: *Vec[(i64, i64)], r: i64) -> i64 {
    for x in 0..st.len {
        if st[x].1 == r {
            return x
        }
    }
    return -1
}

// st.retain(|e| e.1 != d)
priv fn retain_reg_ne(st: *Vec[(i64, i64)], d: i64) {
    n := 0
    for x in 0..st.len {
        if st[x].1 != d {
            st[n] = st[x]
            n += 1
        }
    }
    st.len = n
}

// st.retain(|e| e.0 != s)
priv fn retain_slot_ne(st: *Vec[(i64, i64)], s: i64) {
    n := 0
    for x in 0..st.len {
        if st[x].0 != s {
            st[n] = st[x]
            n += 1
        }
    }
    st.len = n
}

// After allocation: reuse registers that still hold the value of a spill slot instead of
// reloading it, and drop stores to slots that are never read.
priv fn spill_forward(mf: *MFunc, order: []i64, first_spill: i64) {
    nb := mf.blocks.len
    npreds := vec_fill(nb, 0)
    the_pred := vec_fill(nb, 0xFFFFFFFF)
    for b in order {
        for s in mf.blocks[b].succs {
            npreds[s] += 1
            the_pred[s] = b
        }
    }
    no_state: Opt[Vec[(i64, i64)]] = None
    out_state := vec_fill(nb, no_state)
    defs := vec[i64]()
    uses := vec[i64]()
    for oi, b in order {
        st := vec[(i64, i64)]()
        if oi != 0 && npreds[b] == 1 {
            match out_state[the_pred[b]] {
                Some(s) => {
                    st = clone(s)
                }
                None => {}
            }
        }
        insts := mf.blocks[b].insts
        mf.blocks[b].insts = vec[MInst]()
        out := vec[MInst]()
        for x in 0..insts.len {
            i := insts[x]
            is_store := (i.op == Mov || i.op == MovSd) && is_some(spill_slot(i.a, first_spill))
            // uses of a slot whose value is still in a register
            match spill_slot(i.b, first_spill) {
                Some(s) => {
                    fi := find_slot(&st, s)
                    if fi >= 0 {
                        r := st[fi].1
                        full_reload := ((i.op == Mov && i.sz == 8) || i.op == MovSd) && is_r(i.a)
                        if full_reload && eq(i.a, R(r)) {
                            continue
                        }
                        i.b = R(r)
                    }
                }
                None => {}
            }
            if i.op == Cmp || i.op == Test {
                match spill_slot(i.a, first_spill) {
                    Some(s) => {
                        fi := find_slot(&st, s)
                        if fi >= 0 {
                            i.a = R(st[fi].1)
                        }
                    }
                    None => {}
                }
            }
            mir_defs_uses(&i, &defs, &uses)
            for d in defs {
                retain_reg_ne(&st, d)
            }
            if is_store {
                s := match spill_slot(i.a, first_spill) {
                    Some(sl) => sl
                    None => panic("unwrap on None")
                }
                retain_slot_ne(&st, s)
                match i.b {
                    R(r) => st.push((s, r))
                    _ => {}
                }
            } else {
                match (spill_slot(i.b, first_spill), i.a) {
                    (Some(s), R(d)) => {
                        if ((i.op == Mov && i.sz == 8) || i.op == MovSd) && find_slot(&st, s) < 0 {
                            st.push((s, d))
                        }
                    }
                    _ => {
                        d, src, is_cp := i.is_copy()
                        if is_cp {
                            // a register copy of a slot value is another home for it
                            fi := find_reg(&st, src)
                            if fi >= 0 {
                                st.push((st[fi].0, d))
                            }
                        }
                    }
                }
            }
            out.push(i)
        }
        mf.blocks[b].insts = out
        out_state[b] = Some(st)
    }
    // remove stores to slots that are never read
    reads := vec_fill(mf.slots.len, 0)
    for b in order {
        for x in 0..mf.blocks[b].insts.len {
            i := &mf.blocks[b].insts[x]
            is_store := (i.op == Mov || i.op == MovSd) && is_some(spill_slot(i.a, first_spill))
            ops := [3]Opnd{i.a, i.b, i.c}
            for k, o in ops {
                match o {
                    M(m) if m.kind == Slot && i64(m.id) >= first_spill && !(k == 0 && is_store) => reads[i64(m.id)] += 1
                    _ => {}
                }
            }
        }
    }
    for b in order {
        // insts.retain(..)
        insts := &mf.blocks[b].insts
        n := 0
        for x in 0..insts.len {
            i := &insts[x]
            is_store := i.op == Mov || i.op == MovSd
            keep := true
            if is_store {
                match spill_slot(i.a, first_spill) {
                    Some(s) => {
                        keep = reads[s] > 0
                    }
                    None => {}
                }
            }
            if keep {
                insts[n] = insts[x]
                n += 1
            }
        }
        insts.len = n
    }
}

// spill weight helper
priv fn depth_weight(d: i64) -> f64 {
    // 10f64.powi(min(d, 6))
    w := 1.0
    for x in 0..min(d, 6) {
        w *= 10.0
    }
    return w
}

priv fn allocate_in_class(r: i64, mf: *MFunc, class: u8) -> bool {
    return mf.class(r) == class
}

fn regalloc_allocate(mf: *MFunc, order: []i64) -> Alloc {
    first_spill := mf.slots.len
    unspillable := vec_fill(mf.vclass.len, false)
    round := 0
    loop {
        round += 1
        live_out := liveness(mf, order)
        n := 32 + mf.vclass.len
        unspillable.resize(mf.vclass.len, false)
        spilled := vec[i64]()
        colors := vec_fill(n, 0xFFFFFFFF)
        for cls in 0..2 {
            class := u8(cls)
            k := if cls == 0 { 15 } else { 16 }
            g := Irc{
                k: k,
                n: n,
                state: vec_fill(n, Other),
                adj_set: map[u64, bool](),
                adj: vec[Vec[i64]](),
                degree: vec_fill(n, 0),
                moves: vec[(i64, i64)](),
                mstate: vec[MS](),
                move_list: vec[Vec[i64]](),
                alias: vec_fill(n, 0),
                color: vec_fill(n, 0xFFFFFFFF),
                simplify_wl: vec[i64](),
                freeze_wl: vec[i64](),
                spill_wl: vec[i64](),
                move_wl: vec[i64](),
                stack: vec[i64](),
                cost: vec_fill(n, 0.0),
            }
            // every element is its own Vec
            for x in 0..n {
                g.adj.push(vec[i64]())
                g.move_list.push(vec[i64]())
            }
            for r in 0..32 {
                if allocate_in_class(r, mf, class) {
                    g.state[r] = Pre
                    g.color[r] = r
                    g.degree[r] = 0xFFFFFFFF / 2
                }
            }
            for v in 0..mf.vclass.len {
                if mf.vclass[v] == class {
                    g.state[32 + v] = Initial
                }
            }
            // build
            defs := vec[i64]()
            uses := vec[i64]()
            for b in order {
                w := depth_weight(mf.blocks[b].depth)
                live := BitSet{w: clone(live_out[b].w)}
                ninsts := mf.blocks[b].insts.len
                for x in ninsts - 1..=0 by -1 {
                    i := &mf.blocks[b].insts[x]
                    mir_defs_uses(i, &defs, &uses)
                    for r in defs {
                        if r >= 32 && allocate_in_class(r, mf, class) {
                            g.cost[r] += w
                        }
                    }
                    for r in uses {
                        if r >= 32 && allocate_in_class(r, mf, class) {
                            g.cost[r] += w
                        }
                    }
                    d, s, is_cp := i.is_copy()
                    if is_cp {
                        if allocate_in_class(d, mf, class) && allocate_in_class(s, mf, class) && d != s && d != RSP && s != RSP {
                            live.clear(s)
                            mi := g.moves.len
                            g.moves.push((d, s))
                            g.mstate.push(Worklist)
                            g.move_list[d].push(mi)
                            g.move_list[s].push(mi)
                            g.move_wl.push(mi)
                        }
                    }
                    for df in defs {
                        if !allocate_in_class(df, mf, class) {
                            continue
                        }
                        // the members of live, walked in place (the set does not change meanwhile)
                        for wi in 0..live.w.len {
                            bits := live.w[wi]
                            while bits != 0 {
                                l := wi * 64 + i64(ctz(bits))
                                bits &= bits - 1
                                if l != df && allocate_in_class(l, mf, class) && !(l < 32 && df < 32) {
                                    g.add_edge(l, df)
                                }
                            }
                        }
                    }
                    // simultaneous defs interfere with each other
                    if defs.len > 1 {
                        for x1 in 0..defs.len {
                            if defs[x1] < 32 || !allocate_in_class(defs[x1], mf, class) {
                                continue
                            }
                            for y1 in 0..defs.len {
                                if x1 != y1 && allocate_in_class(defs[y1], mf, class) {
                                    g.add_edge(defs[x1], defs[y1])
                                }
                            }
                        }
                    }
                    for df in defs {
                        live.clear(df)
                    }
                    for u in uses {
                        live.set(u)
                    }
                }
            }
            for v in 0..mf.vclass.len {
                if unspillable[v] {
                    g.cost[32 + v] = 1e30
                }
            }
            // make worklists
            for v in 32..n {
                if g.state[v] != Initial {
                    continue
                }
                if g.degree[v] >= k {
                    g.state[v] = Spill
                    g.spill_wl.push(v)
                } else if g.move_related(v) {
                    g.state[v] = Freeze
                    g.freeze_wl.push(v)
                } else {
                    g.state[v] = Simplify
                    g.simplify_wl.push(v)
                }
            }
            g.run()
            // assign colors
            all := vec[i64]()
            if cls == 0 {
                for c in gpr_order {
                    all.push(c)
                }
            } else {
                for c in 16..32 {
                    all.push(c)
                }
            }
            while g.stack.len > 0 {
                nd := g.stack.pop()
                avail: [32]bool
                for x in 0..32 {
                    avail[x] = true
                }
                for w in g.adj[nd] {
                    a := g.get_alias(w)
                    if g.state[a] == Colored || g.state[a] == Pre {
                        avail[g.color[a]] = false
                    }
                }
                // biased coloring: prefer the color of a move partner
                pick := 0xFFFFFFFF
                for m in g.move_list[nd] {
                    x, y := g.moves[m]
                    o := if g.get_alias(x) == nd { g.get_alias(y) } else { g.get_alias(x) }
                    if g.state[o] == Colored || g.state[o] == Pre {
                        c := g.color[o]
                        if c != 0xFFFFFFFF && c != RSP && avail[c] && contains(&all, c) {
                            pick = c
                            break
                        }
                    }
                }
                if pick == 0xFFFFFFFF {
                    for c in all {
                        if avail[c] {
                            pick = c
                            break
                        }
                    }
                }
                if pick == 0xFFFFFFFF {
                    g.state[nd] = Spilled
                    spilled.push(nd)
                } else {
                    g.state[nd] = Colored
                    g.color[nd] = pick
                }
            }
            for v in 32..n {
                if g.state[v] == Coalesced {
                    a := g.get_alias(v)
                    if g.state[a] == Spilled {
                        spilled.push(v)
                    } else {
                        colors[v] = g.color[a]
                    }
                } else if g.state[v] == Colored {
                    colors[v] = g.color[v]
                }
            }
        }
        if spilled.is_empty() {
            // rewrite to physical registers
            // (the mapping `|r| if r >= 32 { colors[r] } else { r }` as a table)
            table := vec[i64]()
            for r in 0..n {
                table.push(if r >= 32 { colors[r] } else { r })
            }
            used: [32]bool
            for b in order {
                insts := mf.blocks[b].insts
                mf.blocks[b].insts = vec[MInst]()
                out := vec[MInst]()
                for x in 0..insts.len {
                    i := insts[x]
                    mir_map_regs(&i, table.items())
                    for y in 0..i.uses.len {
                        if i.uses[y] >= 32 {
                            i.uses[y] = colors[i.uses[y]]
                        }
                    }
                    for y in 0..i.defs.len {
                        if i.defs[y] >= 32 {
                            i.defs[y] = colors[i.defs[y]]
                        }
                    }
                    d, s, is_cp := i.is_copy()
                    if is_cp {
                        if d == s {
                            continue
                        }
                    }
                    defs := vec[i64]()
                    uses := vec[i64]()
                    mir_defs_uses(&i, &defs, &uses)
                    if !(i.op == Call || i.op == CallInd) {
                        for df in defs {
                            if df < 32 {
                                used[df] = true
                            }
                        }
                    }
                    out.push(i)
                }
                mf.blocks[b].insts = out
            }
            used_callee_saved := vec[i64]()
            for r in 0..16 {
                if used[r] && mir_callee_saved(r) {
                    used_callee_saved.push(r)
                }
            }
            if mf.slots.len > first_spill {
                spill_forward(mf, order, first_spill)
            }
            return Alloc{used_callee_saved: used_callee_saved}
        }
        if round > 40 {
            panic(fmt("register allocation did not converge in `", mf.name, "`"))
        }
        spill(mf, order, spilled.items(), &unspillable)
    }
}

// can operand `b` of this instruction be a memory operand?
priv fn b_can_be_mem(i: *MInst) -> bool {
    match i.a {
        M(m) => {
            return false
        }
        _ => {}
    }
    op := i.op
    if op == Add || op == Sub || op == And || op == Or || op == Xor || op == Cmp || op == Imul ||
        op == Addsd || op == Subsd || op == Mulsd || op == Divsd || op == Minsd || op == Maxsd ||
        op == Sqrtsd || op == Cvtf || op == Ucomisd || op == Cvtsi2sd || op == Cvttsd2si || op == Cmov ||
        op == Imul3 {
        return true
    }
    if op == Mov {
        return i.sz == 8 || i.sz == 4
    }
    if op == MovSd {
        return true
    }
    if op == Movzx || op == Movsx {
        return true
    }
    return false
}

priv fn spill(mf: *MFunc, order: []i64, spilled: []i64, unspillable: *Vec[bool]) {
    slot_of := map[i64, i64]()
    for v in spilled {
        s := if mf.wide_xmm && mf.class(v) == 1 { mf.new_slot(16, 16) } else { mf.new_slot(8, 8) }
        slot_of.set(v, s)
    }
    defs := vec[i64]()
    uses := vec[i64]()
    for b in order {
        insts := mf.blocks[b].insts
        mf.blocks[b].insts = vec[MInst]()
        out := vec[MInst]()
        for x in 0..insts.len {
            i := insts[x]
            mir_defs_uses(&i, &defs, &uses)
            touched := vec[i64]()
            for r in defs {
                if slot_of.has(r) {
                    touched.push(r)
                }
            }
            for r in uses {
                if slot_of.has(r) {
                    touched.push(r)
                }
            }
            sort(touched.items())
            touched.dedup()
            if touched.is_empty() {
                out.push(i)
                continue
            }
            after := vec[MInst]()
            for v in touched {
                slot, has_slot := slot_of.get(v)
                cls := mf.class(v)
                mem := M(mem_slot(slot, 0))
                mv := if cls == 1 { MovSd } else { Mov }
                msz: u8 = if cls == 1 && mf.wide_xmm { 16 } else { 8 }
                is_def := contains(&defs, v)
                is_use := contains(&uses, v)
                // direct forms that avoid a temporary
                d, s, is_cp := i.is_copy()
                if is_cp {
                    if s == v && d != v && !slot_of.has(d) {
                        i.b = mem
                        i.sz = msz
                        continue
                    }
                    if d == v && s != v && !slot_of.has(s) {
                        i.a = mem
                        i.sz = msz
                        continue
                    }
                }
                if is_use && !is_def && eq(i.b, R(v)) && b_can_be_mem(&i) {
                    // the only occurrence must be operand b
                    cnt := mir_count_reg(&i, v)
                    if cnt == 1 && !contains(&i.uses, v) {
                        i.b = mem
                        if i.op == MovSd {
                            i.sz = msz
                        }
                        continue
                    }
                }
                if i.op == Mov && i.sz == 8 && eq(i.a, R(v)) && is_def && !is_use {
                    match i.b {
                        I(k) if k >= -2147483648 && k <= 2147483647 => {
                            i.a = mem
                            continue
                        }
                        _ => {}
                    }
                }
                t := mf.new_vreg(cls)
                unspillable.resize(mf.vclass.len, false)
                unspillable[t - VREG0] = true
                mir_replace_reg(&i, v, t)
                for y in 0..i.uses.len {
                    if i.uses[y] == v {
                        i.uses[y] = t
                    }
                }
                for y in 0..i.defs.len {
                    if i.defs[y] == v {
                        i.defs[y] = t
                    }
                }
                if is_use {
                    out.push(minst_new(mv, msz, R(t), mem))
                }
                if is_def {
                    after.push(minst_new(mv, msz, mem, R(t)))
                }
            }
            out.push(i)
            out.extend(after.items())
        }
        mf.blocks[b].insts = out
    }
}
