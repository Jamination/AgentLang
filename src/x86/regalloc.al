// Iterated register coalescing (George & Appel) over machine IR.

var regalloc_gpr_order = [15]i64{0, 1, 2, 6, 7, 8, 9, 10, 11, 3, 5, 12, 13, 14, 15}

struct RegallocBitSet {
    w Vec[u64]
}

fn regalloc_bit_set_new(n i64) RegallocBitSet {
    return RegallocBitSet{w: vec_fill((n + 63) / 64, u64(0))}
}

fn set(self *RegallocBitSet, i i64) {
    self.w.buf[i / 64] |= u64(1) << u64(i % 64)
}

fn clear(self *RegallocBitSet, i i64) {
    self.w.buf[i / 64] &= ~(u64(1) << u64(i % 64))
}

fn union_with(self *RegallocBitSet, o *RegallocBitSet) bool {
    ch := false
    for wi in 0..min(self.w.len, o.w.len) {
        n := self.w.buf[wi] | o.w.buf[wi]
        if n != self.w.buf[wi] {
            self.w.buf[wi] = n
            ch = true
        }
    }
    return ch
}

// the members in ascending order (Rust: a lazy iterator; its one use, in the build loop of
// regalloc_allocate, walks the words in place instead of collecting)
fn iter(self *RegallocBitSet) Vec[i64] {
    out := vec[i64]()
    for wi in 0..self.w.len {
        bits := self.w.buf[wi]
        while bits != 0 {
            t := i64(ctz(bits))
            bits &= bits - 1
            out.push(wi * 64 + t)
        }
    }
    return out
}

fn regalloc_liveness(mf *MFunc, order []i64) Vec[RegallocBitSet] {
    nreg := 32 + mf.vclass.len
    nb := mf.blocks.len
    gen := vec[RegallocBitSet]()
    kill := vec[RegallocBitSet]()
    for x in 0..nb {
        gen.push(regalloc_bit_set_new(nreg))
    }
    for x in 0..nb {
        kill.push(regalloc_bit_set_new(nreg))
    }
    defs := vec[i64]()
    uses := vec[i64]()
    for b in order {
        n := mf.blocks.buf[b].insts.len
        for x in n - 1..=0 by -1 {
            mir_defs_uses(&mf.blocks.buf[b].insts.buf[x], &defs, &uses)
            for d in defs.items() {
                gen.buf[b].clear(d)
                kill.buf[b].set(d)
            }
            for u in uses.items() {
                gen.buf[b].set(u)
            }
        }
    }
    live_in := vec[RegallocBitSet]()
    live_out := vec[RegallocBitSet]()
    for x in 0..nb {
        live_in.push(regalloc_bit_set_new(nreg))
    }
    for x in 0..nb {
        live_out.push(regalloc_bit_set_new(nreg))
    }
    changed := true
    while changed {
        changed = false
        for oi in len(order) - 1..=0 by -1 {
            b := order[oi]
            out := RegallocBitSet{w: clone(live_out.buf[b].w)}
            for si in 0..mf.blocks.buf[b].succs.len {
                s := mf.blocks.buf[b].succs.buf[si]
                out.union_with(&live_in.buf[s])
            }
            live_out.buf[b] = out
            // in = gen | (out - kill)
            ch := false
            for wi in 0..live_in.buf[b].w.len {
                n := gen.buf[b].w.buf[wi] | (live_out.buf[b].w.buf[wi] & ~kill.buf[b].w.buf[wi])
                if n != live_in.buf[b].w.buf[wi] {
                    live_in.buf[b].w.buf[wi] = n
                    ch = true
                }
            }
            changed = changed || ch
        }
    }
    return live_out
}

enum RegallocNS {
    RegallocNSPre,
    RegallocNSInitial,
    RegallocNSSimplify,
    RegallocNSFreeze,
    RegallocNSSpill,
    RegallocNSSpilled,
    RegallocNSCoalesced,
    RegallocNSColored,
    RegallocNSStack,
    RegallocNSOther, // different class
}

enum RegallocMS {
    RegallocMSWorklist,
    RegallocMSActive,
    RegallocMSCoalesced,
    RegallocMSConstrained,
    RegallocMSFrozen,
}

struct RegallocIrc {
    k i64
    n i64
    state Vec[RegallocNS]
    adj_set Map[u64, bool]
    adj Vec[Vec[i64]]
    degree Vec[i64]
    moves Vec[(i64, i64)]
    mstate Vec[RegallocMS]
    move_list Vec[Vec[i64]]
    alias Vec[i64]
    color Vec[i64]
    simplify_wl Vec[i64]
    freeze_wl Vec[i64]
    spill_wl Vec[i64]
    move_wl Vec[i64]
    stack Vec[i64]
    cost Vec[f64]
}

fn pre(self *RegallocIrc, n i64) bool {
    return n < 32
}

fn add_edge(self *RegallocIrc, u i64, v i64) {
    if u == v {
        return
    }
    key := (u64(min(u, v)) << 32) | u64(max(u, v))
    if !self.adj_set.has(key) {
        self.adj_set.set(key, true)
        if !self.pre(u) {
            self.adj.buf[u].push(v)
            self.degree.buf[u] += 1
        }
        if !self.pre(v) {
            self.adj.buf[v].push(u)
            self.degree.buf[v] += 1
        }
    }
}

fn has_edge(self *RegallocIrc, u i64, v i64) bool {
    key := (u64(min(u, v)) << 32) | u64(max(u, v))
    return self.adj_set.has(key)
}

fn adjacent(self *RegallocIrc, n i64) Vec[i64] {
    out := vec[i64]()
    for m in self.adj.buf[n].items() {
        st := self.state.buf[m]
        if !(st == RegallocNSStack || st == RegallocNSCoalesced) {
            out.push(m)
        }
    }
    return out
}

fn node_moves(self *RegallocIrc, n i64) Vec[i64] {
    out := vec[i64]()
    for m in self.move_list.buf[n].items() {
        ms := self.mstate.buf[m]
        if ms == RegallocMSActive || ms == RegallocMSWorklist {
            out.push(m)
        }
    }
    return out
}

fn move_related(self *RegallocIrc, n i64) bool {
    for m in self.move_list.buf[n].items() {
        ms := self.mstate.buf[m]
        if ms == RegallocMSActive || ms == RegallocMSWorklist {
            return true
        }
    }
    return false
}

fn get_alias(self *RegallocIrc, n0 i64) i64 {
    n := n0
    while self.state.buf[n] == RegallocNSCoalesced {
        n = self.alias.buf[n]
    }
    return n
}

fn enable_moves(self *RegallocIrc, n i64) {
    nm := self.node_moves(n)
    for m in nm.items() {
        if self.mstate.buf[m] == RegallocMSActive {
            self.mstate.buf[m] = RegallocMSWorklist
            self.move_wl.push(m)
        }
    }
}

fn decrement_degree(self *RegallocIrc, m i64) {
    if self.pre(m) {
        return
    }
    d := self.degree.buf[m]
    // saturating_sub(1)
    self.degree.buf[m] = if d > 0 { d - 1 } else { 0 }
    if d == self.k {
        self.enable_moves(m)
        adj := self.adjacent(m)
        for a in adj.items() {
            self.enable_moves(a)
        }
        if self.state.buf[m] == RegallocNSSpill {
            if self.move_related(m) {
                self.state.buf[m] = RegallocNSFreeze
                self.freeze_wl.push(m)
            } else {
                self.state.buf[m] = RegallocNSSimplify
                self.simplify_wl.push(m)
            }
        }
    }
}

fn simplify(self *RegallocIrc, n i64) {
    self.state.buf[n] = RegallocNSStack
    self.stack.push(n)
    adj := self.adjacent(n)
    for m in adj.items() {
        self.decrement_degree(m)
    }
}

fn add_worklist(self *RegallocIrc, u i64) {
    if !self.pre(u) && self.state.buf[u] == RegallocNSFreeze && !self.move_related(u) && self.degree.buf[u] < self.k {
        self.state.buf[u] = RegallocNSSimplify
        self.simplify_wl.push(u)
    }
}

fn ok(self *RegallocIrc, t i64, r i64) bool {
    return self.pre(t) || self.degree.buf[t] < self.k || self.has_edge(t, r)
}

fn conservative(self *RegallocIrc, u i64, v i64) bool {
    seen := map[i64, bool]()
    k := 0
    au := self.adjacent(u)
    av := self.adjacent(v)
    for n in au.items() {
        if !seen.has(n) {
            seen.set(n, true)
            if self.pre(n) || self.degree.buf[n] >= self.k {
                k += 1
            }
        }
    }
    for n in av.items() {
        if !seen.has(n) {
            seen.set(n, true)
            if self.pre(n) || self.degree.buf[n] >= self.k {
                k += 1
            }
        }
    }
    return k < self.k
}

fn combine(self *RegallocIrc, u i64, v i64) {
    // v is merged into u
    self.state.buf[v] = RegallocNSCoalesced
    self.alias.buf[v] = u
    ml := clone(self.move_list.buf[v])
    if !self.pre(u) {
        for m in ml.items() {
            if !contains(&self.move_list.buf[u], m) {
                self.move_list.buf[u].push(m)
            }
        }
        self.cost.buf[u] += self.cost.buf[v]
    }
    self.enable_moves(v)
    adj_v := self.adjacent(v)
    for t in adj_v.items() {
        self.add_edge(t, u)
        self.decrement_degree(t)
    }
    if !self.pre(u) && self.degree.buf[u] >= self.k && self.state.buf[u] == RegallocNSFreeze {
        self.state.buf[u] = RegallocNSSpill
        self.spill_wl.push(u)
    }
}

fn coalesce(self *RegallocIrc, m i64) {
    d, s := self.moves.buf[m]
    x := self.get_alias(d)
    y := self.get_alias(s)
    u := x
    v := y
    if self.pre(y) {
        u = y
        v = x
    }
    if u == v {
        self.mstate.buf[m] = RegallocMSCoalesced
        self.add_worklist(u)
    } else if self.pre(v) || self.has_edge(u, v) {
        self.mstate.buf[m] = RegallocMSConstrained
        self.add_worklist(u)
        self.add_worklist(v)
    } else {
        can := false
        if self.pre(u) {
            can = true
            adj := self.adjacent(v)
            for t in adj.items() {
                if !self.ok(t, u) {
                    can = false
                    break
                }
            }
        } else {
            can = self.conservative(u, v)
        }
        if can {
            self.mstate.buf[m] = RegallocMSCoalesced
            self.combine(u, v)
            self.add_worklist(u)
        } else {
            self.mstate.buf[m] = RegallocMSActive
        }
    }
}

fn freeze_moves(self *RegallocIrc, u i64) {
    nm := self.node_moves(u)
    for m in nm.items() {
        x, y := self.moves.buf[m]
        v := if self.get_alias(y) == self.get_alias(u) { self.get_alias(x) } else { self.get_alias(y) }
        self.mstate.buf[m] = RegallocMSFrozen
        if !self.pre(v) && self.state.buf[v] == RegallocNSFreeze && !self.move_related(v) && self.degree.buf[v] < self.k {
            self.state.buf[v] = RegallocNSSimplify
            self.simplify_wl.push(v)
        }
    }
}

fn run(self *RegallocIrc) {
    loop {
        if self.simplify_wl.len > 0 {
            n := self.simplify_wl.pop()
            if self.state.buf[n] == RegallocNSSimplify {
                self.simplify(n)
            }
        } else if self.move_wl.len > 0 {
            m := self.move_wl.pop()
            if self.mstate.buf[m] == RegallocMSWorklist {
                self.coalesce(m)
            }
        } else if self.freeze_wl.len > 0 {
            u := self.freeze_wl.pop()
            if self.state.buf[u] == RegallocNSFreeze {
                self.state.buf[u] = RegallocNSSimplify
                self.simplify_wl.push(u)
                self.freeze_moves(u)
            }
        } else {
            // select a spill candidate: lowest cost / degree
            var best Opt[(i64, f64)] = None
            for i in 0..self.spill_wl.len {
                n := self.spill_wl.buf[i]
                if self.state.buf[n] != RegallocNSSpill {
                    continue
                }
                c := self.cost.buf[n] / f64(max(self.degree.buf[n], 1))
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
                    self.state.buf[n] = RegallocNSSimplify
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
    used_callee_saved Vec[i64]
}

fn regalloc_spill_slot(o Opnd, first_spill i64) Opt[i64] {
    match o {
        OpndM(m) => {
            if m.kind == MemKindSlot && i64(m.id) >= first_spill && i64(m.base) == NOREG && i64(m.idx) == NOREG && i64(m.disp) == 0 {
                return Some(i64(m.id))
            }
        }
        _ => {}
    }
    return None
}

fn regalloc_is_r(o Opnd) bool {
    match o {
        OpndR(r) => true
        _ => false
    }
}

// index of the first entry of `st` for slot `s`, or -1
fn regalloc_find_slot(st *Vec[(i64, i64)], s i64) i64 {
    for x in 0..st.len {
        if st.buf[x].0 == s {
            return x
        }
    }
    return -1
}

// index of the first entry of `st` held in register `r`, or -1
fn regalloc_find_reg(st *Vec[(i64, i64)], r i64) i64 {
    for x in 0..st.len {
        if st.buf[x].1 == r {
            return x
        }
    }
    return -1
}

// st.retain(|e| e.1 != d)
fn regalloc_retain_reg_ne(st *Vec[(i64, i64)], d i64) {
    n := 0
    for x in 0..st.len {
        if st.buf[x].1 != d {
            st.buf[n] = st.buf[x]
            n += 1
        }
    }
    st.len = n
}

// st.retain(|e| e.0 != s)
fn regalloc_retain_slot_ne(st *Vec[(i64, i64)], s i64) {
    n := 0
    for x in 0..st.len {
        if st.buf[x].0 != s {
            st.buf[n] = st.buf[x]
            n += 1
        }
    }
    st.len = n
}

// After allocation: reuse registers that still hold the value of a spill slot instead of
// reloading it, and drop stores to slots that are never read.
fn regalloc_spill_forward(mf *MFunc, order []i64, first_spill i64) {
    nb := mf.blocks.len
    npreds := vec_fill(nb, 0)
    the_pred := vec_fill(nb, 0xFFFFFFFF)
    for b in order {
        for s in mf.blocks.buf[b].succs.items() {
            npreds.buf[s] += 1
            the_pred.buf[s] = b
        }
    }
    var no_state Opt[Vec[(i64, i64)]] = None
    out_state := vec_fill(nb, no_state)
    defs := vec[i64]()
    uses := vec[i64]()
    for oi, b in order {
        st := vec[(i64, i64)]()
        if oi != 0 && npreds.buf[b] == 1 {
            match out_state.buf[the_pred.buf[b]] {
                Some(s) => {
                    st = clone(s)
                }
                None => {}
            }
        }
        insts := mf.blocks.buf[b].insts
        mf.blocks.buf[b].insts = vec[MInst]()
        out := vec[MInst]()
        for x in 0..insts.len {
            i := insts.buf[x]
            is_store := (i.op == MOpMov || i.op == MOpMovSd) && is_some(regalloc_spill_slot(i.a, first_spill))
            // uses of a slot whose value is still in a register
            match regalloc_spill_slot(i.b, first_spill) {
                Some(s) => {
                    fi := regalloc_find_slot(&st, s)
                    if fi >= 0 {
                        r := st.buf[fi].1
                        full_reload := ((i.op == MOpMov && i.sz == 8) || i.op == MOpMovSd) && regalloc_is_r(i.a)
                        if full_reload && eq(i.a, OpndR(r)) {
                            continue
                        }
                        i.b = OpndR(r)
                    }
                }
                None => {}
            }
            if i.op == MOpCmp || i.op == MOpTest {
                match regalloc_spill_slot(i.a, first_spill) {
                    Some(s) => {
                        fi := regalloc_find_slot(&st, s)
                        if fi >= 0 {
                            i.a = OpndR(st.buf[fi].1)
                        }
                    }
                    None => {}
                }
            }
            mir_defs_uses(&i, &defs, &uses)
            for d in defs.items() {
                regalloc_retain_reg_ne(&st, d)
            }
            if is_store {
                s := match regalloc_spill_slot(i.a, first_spill) {
                    Some(sl) => sl
                    None => panic("unwrap on None")
                }
                regalloc_retain_slot_ne(&st, s)
                match i.b {
                    OpndR(r) => st.push((s, r))
                    _ => {}
                }
            } else {
                // `else if let (Some(s), Opnd::R(d)) = (spill_slot(b), a)`, otherwise the copy case
                matched := false
                match regalloc_spill_slot(i.b, first_spill) {
                    Some(s) => {
                        match i.a {
                            OpndR(d) => {
                                matched = true
                                if ((i.op == MOpMov && i.sz == 8) || i.op == MOpMovSd) && regalloc_find_slot(&st, s) < 0 {
                                    st.push((s, d))
                                }
                            }
                            _ => {}
                        }
                    }
                    None => {}
                }
                if !matched {
                    d, src, is_cp := i.is_copy()
                    if is_cp {
                        // a register copy of a slot value is another home for it
                        fi := regalloc_find_reg(&st, src)
                        if fi >= 0 {
                            st.push((st.buf[fi].0, d))
                        }
                    }
                }
            }
            out.push(i)
        }
        mf.blocks.buf[b].insts = out
        out_state.buf[b] = Some(st)
    }
    // remove stores to slots that are never read
    reads := vec_fill(mf.slots.len, 0)
    for b in order {
        for x in 0..mf.blocks.buf[b].insts.len {
            i := &mf.blocks.buf[b].insts.buf[x]
            is_store := (i.op == MOpMov || i.op == MOpMovSd) && is_some(regalloc_spill_slot(i.a, first_spill))
            ops := [3]Opnd{i.a, i.b, i.c}
            for k, o in ops {
                match o {
                    OpndM(m) => {
                        if m.kind == MemKindSlot && i64(m.id) >= first_spill && !(k == 0 && is_store) {
                            reads.buf[i64(m.id)] += 1
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    for b in order {
        // insts.retain(..)
        insts := &mf.blocks.buf[b].insts
        n := 0
        for x in 0..insts.len {
            i := &insts.buf[x]
            is_store := i.op == MOpMov || i.op == MOpMovSd
            keep := true
            if is_store {
                match regalloc_spill_slot(i.a, first_spill) {
                    Some(s) => {
                        keep = reads.buf[s] > 0
                    }
                    None => {}
                }
            }
            if keep {
                insts.buf[n] = insts.buf[x]
                n += 1
            }
        }
        insts.len = n
    }
}

// spill weight helper
fn regalloc_depth_weight(d i64) f64 {
    // 10f64.powi(min(d, 6))
    w := 1.0
    for x in 0..min(d, 6) {
        w *= 10.0
    }
    return w
}

fn regalloc_allocate_in_class(r i64, mf *MFunc, class u8) bool {
    return mf.class(r) == class
}

fn regalloc_allocate(mf *MFunc, order []i64) Alloc {
    first_spill := mf.slots.len
    unspillable := vec_fill(mf.vclass.len, false)
    round := 0
    loop {
        round += 1
        live_out := regalloc_liveness(mf, order)
        n := 32 + mf.vclass.len
        unspillable.resize(mf.vclass.len, false)
        spilled := vec[i64]()
        colors := vec_fill(n, 0xFFFFFFFF)
        for cls in 0..2 {
            class := u8(cls)
            k := if cls == 0 { 15 } else { 16 }
            g := RegallocIrc{
                k: k,
                n: n,
                state: vec_fill(n, RegallocNSOther),
                adj_set: map[u64, bool](),
                adj: vec[Vec[i64]](),
                degree: vec_fill(n, 0),
                moves: vec[(i64, i64)](),
                mstate: vec[RegallocMS](),
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
            // vec![Vec::new(); n]: every element is its own Vec
            for x in 0..n {
                g.adj.push(vec[i64]())
                g.move_list.push(vec[i64]())
            }
            for r in 0..32 {
                if regalloc_allocate_in_class(r, mf, class) {
                    g.state.buf[r] = RegallocNSPre
                    g.color.buf[r] = r
                    g.degree.buf[r] = 0xFFFFFFFF / 2
                }
            }
            for v in 0..mf.vclass.len {
                if mf.vclass.buf[v] == class {
                    g.state.buf[32 + v] = RegallocNSInitial
                }
            }
            // build
            defs := vec[i64]()
            uses := vec[i64]()
            for b in order {
                w := regalloc_depth_weight(mf.blocks.buf[b].depth)
                live := RegallocBitSet{w: clone(live_out.buf[b].w)}
                ninsts := mf.blocks.buf[b].insts.len
                for x in ninsts - 1..=0 by -1 {
                    i := &mf.blocks.buf[b].insts.buf[x]
                    mir_defs_uses(i, &defs, &uses)
                    for r in defs.items() {
                        if r >= 32 && regalloc_allocate_in_class(r, mf, class) {
                            g.cost.buf[r] += w
                        }
                    }
                    for r in uses.items() {
                        if r >= 32 && regalloc_allocate_in_class(r, mf, class) {
                            g.cost.buf[r] += w
                        }
                    }
                    d, s, is_cp := i.is_copy()
                    if is_cp {
                        if regalloc_allocate_in_class(d, mf, class) && regalloc_allocate_in_class(s, mf, class) && d != s && d != RSP && s != RSP {
                            live.clear(s)
                            mi := g.moves.len
                            g.moves.push((d, s))
                            g.mstate.push(RegallocMSWorklist)
                            g.move_list.buf[d].push(mi)
                            g.move_list.buf[s].push(mi)
                            g.move_wl.push(mi)
                        }
                    }
                    for df in defs.items() {
                        if !regalloc_allocate_in_class(df, mf, class) {
                            continue
                        }
                        // live.iter(), walked in place (the set does not change meanwhile)
                        for wi in 0..live.w.len {
                            bits := live.w.buf[wi]
                            while bits != 0 {
                                l := wi * 64 + i64(ctz(bits))
                                bits &= bits - 1
                                if l != df && regalloc_allocate_in_class(l, mf, class) && !(l < 32 && df < 32) {
                                    g.add_edge(l, df)
                                }
                            }
                        }
                    }
                    // simultaneous defs interfere with each other
                    if defs.len > 1 {
                        for x1 in 0..defs.len {
                            if defs.buf[x1] < 32 || !regalloc_allocate_in_class(defs.buf[x1], mf, class) {
                                continue
                            }
                            for y1 in 0..defs.len {
                                if x1 != y1 && regalloc_allocate_in_class(defs.buf[y1], mf, class) {
                                    g.add_edge(defs.buf[x1], defs.buf[y1])
                                }
                            }
                        }
                    }
                    for df in defs.items() {
                        live.clear(df)
                    }
                    for u in uses.items() {
                        live.set(u)
                    }
                }
            }
            for v in 0..mf.vclass.len {
                if unspillable.buf[v] {
                    g.cost.buf[32 + v] = 1e30
                }
            }
            // make worklists
            for v in 32..n {
                if g.state.buf[v] != RegallocNSInitial {
                    continue
                }
                if g.degree.buf[v] >= k {
                    g.state.buf[v] = RegallocNSSpill
                    g.spill_wl.push(v)
                } else if g.move_related(v) {
                    g.state.buf[v] = RegallocNSFreeze
                    g.freeze_wl.push(v)
                } else {
                    g.state.buf[v] = RegallocNSSimplify
                    g.simplify_wl.push(v)
                }
            }
            g.run()
            // assign colors
            all := vec[i64]()
            if cls == 0 {
                for c in regalloc_gpr_order {
                    all.push(c)
                }
            } else {
                for c in 16..32 {
                    all.push(c)
                }
            }
            while g.stack.len > 0 {
                nd := g.stack.pop()
                var avail [32]bool
                for x in 0..32 {
                    avail[x] = true
                }
                for w in g.adj.buf[nd].items() {
                    a := g.get_alias(w)
                    if g.state.buf[a] == RegallocNSColored || g.state.buf[a] == RegallocNSPre {
                        avail[g.color.buf[a]] = false
                    }
                }
                // biased coloring: prefer the color of a move partner
                pick := 0xFFFFFFFF
                for m in g.move_list.buf[nd].items() {
                    x, y := g.moves.buf[m]
                    o := if g.get_alias(x) == nd { g.get_alias(y) } else { g.get_alias(x) }
                    if g.state.buf[o] == RegallocNSColored || g.state.buf[o] == RegallocNSPre {
                        c := g.color.buf[o]
                        if c != 0xFFFFFFFF && c != RSP && avail[c] && contains(&all, c) {
                            pick = c
                            break
                        }
                    }
                }
                if pick == 0xFFFFFFFF {
                    for c in all.items() {
                        if avail[c] {
                            pick = c
                            break
                        }
                    }
                }
                if pick == 0xFFFFFFFF {
                    g.state.buf[nd] = RegallocNSSpilled
                    spilled.push(nd)
                } else {
                    g.state.buf[nd] = RegallocNSColored
                    g.color.buf[nd] = pick
                }
            }
            for v in 32..n {
                if g.state.buf[v] == RegallocNSCoalesced {
                    a := g.get_alias(v)
                    if g.state.buf[a] == RegallocNSSpilled {
                        spilled.push(v)
                    } else {
                        colors.buf[v] = g.color.buf[a]
                    }
                } else if g.state.buf[v] == RegallocNSColored {
                    colors.buf[v] = g.color.buf[v]
                }
            }
        }
        if spilled.is_empty() {
            // rewrite to physical registers
            // (the mapping `|r| if r >= 32 { colors[r] } else { r }` as a table)
            table := vec[i64]()
            for r in 0..n {
                table.push(if r >= 32 { colors.buf[r] } else { r })
            }
            var used [32]bool
            for b in order {
                insts := mf.blocks.buf[b].insts
                mf.blocks.buf[b].insts = vec[MInst]()
                out := vec[MInst]()
                for x in 0..insts.len {
                    i := insts.buf[x]
                    mir_map_regs(&i, table.items())
                    for y in 0..i.uses.len {
                        if i.uses.buf[y] >= 32 {
                            i.uses.buf[y] = colors.buf[i.uses.buf[y]]
                        }
                    }
                    for y in 0..i.defs.len {
                        if i.defs.buf[y] >= 32 {
                            i.defs.buf[y] = colors.buf[i.defs.buf[y]]
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
                    if !(i.op == MOpCall || i.op == MOpCallInd) {
                        for df in defs.items() {
                            if df < 32 {
                                used[df] = true
                            }
                        }
                    }
                    out.push(i)
                }
                mf.blocks.buf[b].insts = out
            }
            used_callee_saved := vec[i64]()
            for r in 0..16 {
                if used[r] && mir_callee_saved(r) {
                    used_callee_saved.push(r)
                }
            }
            if mf.slots.len > first_spill {
                regalloc_spill_forward(mf, order, first_spill)
            }
            return Alloc{used_callee_saved: used_callee_saved}
        }
        if round > 40 {
            panic(fmt("register allocation did not converge in `", mf.name, "`"))
        }
        regalloc_spill(mf, order, spilled.items(), &unspillable)
    }
}

// can operand `b` of this instruction be a memory operand?
fn regalloc_b_can_be_mem(i *MInst) bool {
    match i.a {
        OpndM(m) => {
            return false
        }
        _ => {}
    }
    op := i.op
    if op == MOpAdd || op == MOpSub || op == MOpAnd || op == MOpOr || op == MOpXor || op == MOpCmp || op == MOpImul ||
        op == MOpAddsd || op == MOpSubsd || op == MOpMulsd || op == MOpDivsd || op == MOpMinsd || op == MOpMaxsd ||
        op == MOpSqrtsd || op == MOpCvtf || op == MOpUcomisd || op == MOpCvtsi2sd || op == MOpCvttsd2si || op == MOpCmov ||
        op == MOpImul3 {
        return true
    }
    if op == MOpMov {
        return i.sz == 8 || i.sz == 4
    }
    if op == MOpMovSd {
        return true
    }
    if op == MOpMovzx || op == MOpMovsx {
        return true
    }
    return false
}

fn regalloc_spill(mf *MFunc, order []i64, spilled []i64, unspillable *Vec[bool]) {
    slot_of := map[i64, i64]()
    for v in spilled {
        s := if mf.wide_xmm && mf.class(v) == 1 { mf.new_slot(16, 16) } else { mf.new_slot(8, 8) }
        slot_of.set(v, s)
    }
    defs := vec[i64]()
    uses := vec[i64]()
    for b in order {
        insts := mf.blocks.buf[b].insts
        mf.blocks.buf[b].insts = vec[MInst]()
        out := vec[MInst]()
        for x in 0..insts.len {
            i := insts.buf[x]
            mir_defs_uses(&i, &defs, &uses)
            touched := vec[i64]()
            for r in defs.items() {
                if slot_of.has(r) {
                    touched.push(r)
                }
            }
            for r in uses.items() {
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
            for v in touched.items() {
                slot, has_slot := slot_of.get(v)
                cls := mf.class(v)
                mem := OpndM(mem_slot(slot, 0))
                mv := if cls == 1 { MOpMovSd } else { MOpMov }
                var msz u8 = if cls == 1 && mf.wide_xmm { 16 } else { 8 }
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
                if is_use && !is_def && eq(i.b, OpndR(v)) && regalloc_b_can_be_mem(&i) {
                    // the only occurrence must be operand b
                    cnt := mir_count_reg(&i, v)
                    if cnt == 1 && !contains(&i.uses, v) {
                        i.b = mem
                        if i.op == MOpMovSd {
                            i.sz = msz
                        }
                        continue
                    }
                }
                if i.op == MOpMov && i.sz == 8 && eq(i.a, OpndR(v)) && is_def && !is_use {
                    match i.b {
                        OpndI(k) => {
                            if k >= -2147483648 && k <= 2147483647 {
                                i.a = mem
                                continue
                            }
                        }
                        _ => {}
                    }
                }
                t := mf.new_vreg(cls)
                unspillable.resize(mf.vclass.len, false)
                unspillable.buf[t - VREG0] = true
                mir_replace_reg(&i, v, t)
                for y in 0..i.uses.len {
                    if i.uses.buf[y] == v {
                        i.uses.buf[y] = t
                    }
                }
                for y in 0..i.defs.len {
                    if i.defs.buf[y] == v {
                        i.defs.buf[y] = t
                    }
                }
                if is_use {
                    out.push(minst_new(mv, msz, OpndR(t), mem))
                }
                if is_def {
                    after.push(minst_new(mv, msz, mem, OpndR(t)))
                }
            }
            out.push(i)
            out.extend(after.items())
        }
        mf.blocks.buf[b].insts = out
    }
}
