// Iterated register coalescing (George & Appel) over machine IR.
//
// Each round decodes the registers every instruction defines and uses once (mir_decode) into
// one buffer; liveness and the interference graphs of both register classes are built from
// it in one walk. The two classes share the node arrays (their nodes are disjoint) and are
// coloured one after the other. Every list keeps the order in which the textbook algorithm
// fills it: the order of adjacency and move lists decides the colouring.

priv gpr_order := [15]i64{0, 1, 2, 6, 7, 8, 9, 10, 11, 3, 5, 12, 13, 14, 15}

// the general-purpose and the xmm registers that a call clobbers, as bit masks
priv const CLOBBER_GPR: u64 = 0xFC7
priv const CLOBBER_XMM: u64 = 0xFFFF0000

// ---------- decoded instructions ----------
priv struct Dec {
    du: Vec[i64]    // mir_decode entries of all instructions in `order`
    ipos: Vec[i64]  // the entry of each instruction (numbered in `order`), then the end
    binst: Vec[i64] // the first instruction of each block (by position in `order`), then the total
    // for liveness: the registers that some block uses before defining them ("globals"), in
    // the order in which they are first met, and the number of each (or -1)
    globals: Vec[i64]
    gidx: Vec[i64]
    // per block: the globals it uses before defining them (gen[gen_off[oi]..gen_off[oi + 1]]),
    // and the registers it defines (kill, likewise; the call clobbers not included: a call
    // sets kill_call[oi])
    gen_off: Vec[i64]
    gen: Vec[i64]
    kill_off: Vec[i64]
    kill: Vec[i64]
    kill_call: Vec[bool]
}

priv fn decode(mf: *MFunc, order: []i64, n: i64) -> Dec {
    no := len(order)
    total := 0
    for b in order {
        total += mf.blocks[b].insts.len
    }
    du := vec_fill(total * 4 + 4 * DU_MAX, 0)
    ipos := vec_fill(total + 1, 0)
    binst := vec_fill(no + 1, 0)
    globals := vec[i64]()
    gidx := vec_fill(n, -1)
    def_in := vec_fill(n, -1) // the block whose forward scan defined the register last
    gen_off := vec_fill(no + 1, 0)
    gen := vec_fill(total + DU_MAX, 0)
    kill_off := vec_fill(no + 1, 0)
    kill := vec_fill(total + DU_MAX, 0)
    kill_call := vec_fill(no, false)
    ng := 0
    nk := 0
    p := 0
    k := 0
    for oi, b in order {
        binst[oi] = k
        gen_off[oi] = ng
        kill_off[oi] = nk
        insts := &mf.blocks[b].insts
        for x in 0..insts.len {
            if p + DU_MAX > du.len {
                du.resize(2 * du.len, 0)
            }
            if ng + DU_MAX > gen.len {
                gen.resize(2 * gen.len, 0)
            }
            if nk + DU_MAX > kill.len {
                kill.resize(2 * kill.len, 0)
            }
            ipos[k] = p
            q0 := mir_decode(mf, &insts[x], du.items(), p)
            h := du[p]
            q := p + 1 + (h & 255)
            for j in q..q0 {
                u := du[j]
                if def_in[u] != oi {
                    g := gidx[u]
                    if g < 0 {
                        g = globals.len
                        gidx[u] = g
                        globals.push(u)
                    }
                    gen[ng] = g
                    ng += 1
                }
            }
            for j in p + 1..q {
                d := du[j]
                if def_in[d] != oi {
                    def_in[d] = oi
                    kill[nk] = d
                    nk += 1
                }
            }
            if h & (DU_CALL << 16) != 0 {
                kill_call[oi] = true
                for r in CALL_CLOBBER {
                    def_in[r] = oi
                }
            }
            p = q0
            k += 1
        }
    }
    binst[no] = k
    ipos[k] = p
    gen_off[no] = ng
    kill_off[no] = nk
    return Dec{du: du, ipos: ipos, binst: binst, globals: globals, gidx: gidx, gen_off: gen_off, gen: gen, kill_off: kill_off, kill: kill, kill_call: kill_call}
}

// ---------- liveness ----------
// The registers live at the end of each block (by position in `order`): lo[lo_off[oi]..
// lo_off[oi + 1]]. Only a register that some block uses before defining it (upward exposed)
// can be live across a block boundary, so the sets range over those registers only, in the
// order in which they are first met.
priv fn liveness(mf: *MFunc, order: []i64, dec: *Dec, n: i64, lo_off: *Vec[i64], lo: *Vec[i64]) {
    no := len(order)
    *lo_off = vec_fill(no + 1, 0)
    *lo = vec[i64]()
    globals := &dec.globals
    gidx := &dec.gidx
    ng := globals.len
    if ng == 0 {
        return
    }
    nw := (ng + 63) / 64
    // gen: used before being defined; kill: defined (a use before the definition in the
    // same block is gen, so gen and kill can share a register)
    gen := vec_fill(no * nw, u64(0))
    kill := vec_fill(no * nw, u64(0))
    live_in := vec_fill(no * nw, u64(0))
    live_out := vec_fill(no * nw, u64(0))
    for oi in 0..no {
        base := oi * nw
        for x in dec.gen_off[oi]..dec.gen_off[oi + 1] {
            g := dec.gen[x]
            gen[base + (g >> 6)] |= u64(1) << u64(g & 63)
        }
        for x in dec.kill_off[oi]..dec.kill_off[oi + 1] {
            g := gidx[dec.kill[x]]
            if g >= 0 {
                kill[base + (g >> 6)] |= u64(1) << u64(g & 63)
            }
        }
        if dec.kill_call[oi] {
            for r in CALL_CLOBBER {
                g := gidx[r]
                if g >= 0 {
                    kill[base + (g >> 6)] |= u64(1) << u64(g & 63)
                }
            }
        }
    }
    opos := vec_fill(mf.blocks.len, -1)
    for oi, b in order {
        opos[b] = oi
    }
    changed := true
    while changed {
        changed = false
        for oi in no - 1..=0 by -1 {
            b := order[oi]
            base := oi * nw
            for s in mf.blocks[b].succs {
                sp := opos[s]
                if sp < 0 {
                    continue
                }
                sb := sp * nw
                for wi in 0..nw {
                    live_out[base + wi] |= live_in[sb + wi]
                }
            }
            // in = gen | (out - kill)
            for wi in 0..nw {
                x := gen[base + wi] | (live_out[base + wi] & ~kill[base + wi])
                if x != live_in[base + wi] {
                    live_in[base + wi] = x
                    changed = true
                }
            }
        }
    }
    for oi in 0..no {
        lo_off[oi] = lo.len
        for wi in 0..nw {
            bits := live_out[oi * nw + wi]
            while bits != 0 {
                lo.push(globals[wi * 64 + i64(ctz(bits))])
                bits &= bits - 1
            }
        }
    }
    lo_off[no] = lo.len
}

// ---------- per-node lists in one pool ----------
// Every list starts with room for c0 elements; a list that outgrows its room moves to the end
// of the pool with twice the room. (The pool is not zeroed: an element is only read after it
// was written.)
priv struct Lists {
    beg: Vec[i64]
    len: Vec[i64]
    cap: Vec[i64]
    pool: Vec[i64]
}

priv fn lists_new(n: i64, c0: i64) -> Lists {
    l := Lists{beg: vec_fill(n, 0), len: vec_fill(n, 0), cap: vec_fill(n, c0), pool: vec[i64]()}
    for x in 0..n {
        l.beg[x] = x * c0
    }
    l.pool.reserve(2 * n * c0)
    l.pool.len = n * c0
    return l
}

priv inline fn lpush(self: *Lists, n: i64, x: i64) {
    l := self.len[n]
    if l == self.cap[n] {
        self.lgrow(n)
    }
    self.pool[self.beg[n] + l] = x
    self.len[n] = l + 1
}

priv noinline fn lgrow(self: *Lists, n: i64) {
    l := self.len[n]
    nc := max(4, 2 * l)
    nb := self.pool.len
    self.pool.reserve(nb + nc)
    self.pool.len = nb + nc
    ob := self.beg[n]
    for j in 0..l {
        self.pool[nb + j] = self.pool[ob + j]
    }
    self.beg[n] = nb
    self.cap[n] = nc
}

// the list of n (a view: valid until the list changes)
priv inline fn lget(self: *Lists, n: i64) -> []i64 {
    b := self.beg[n]
    return self.pool[b..b + self.len[n]]
}

// appends the list of v to the one of u (the longer one keeps its place) and empties v's
priv fn merge_moves(self: *Lists, u: i64, v: i64) {
    if self.len[v] > self.len[u] {
        swap(&self.beg[u], &self.beg[v])
        swap(&self.len[u], &self.len[v])
        swap(&self.cap[u], &self.cap[v])
    }
    vb := self.beg[v]
    for j in 0..self.len[v] {
        self.lpush(u, self.pool[vb + j])
    }
    self.len[v] = 0
    self.cap[v] = 0
}

// ---------- the live set while building ----------
// a set of registers with constant-time insertion and removal whose members can be walked
// in time proportional to their number
priv struct RegSet {
    members: Vec[i64] // the first cnt elements
    cnt: i64
    pos: Vec[i64] // index in members, or -1
}

priv fn regset_new(n: i64) -> RegSet {
    return RegSet{members: vec_fill(n, 0), cnt: 0, pos: vec_fill(n, -1)}
}

priv inline fn add(self: *RegSet, r: i64) {
    if self.pos[r] < 0 {
        self.pos[r] = self.cnt
        self.members[self.cnt] = r
        self.cnt += 1
    }
}

priv inline fn remove(self: *RegSet, r: i64) {
    p := self.pos[r]
    if p >= 0 {
        self.cnt -= 1
        last := self.members[self.cnt]
        if last != r {
            self.members[p] = last
            self.pos[last] = p
        }
        self.pos[r] = -1
    }
}

priv fn clear_all(self: *RegSet) {
    for x in 0..self.cnt {
        self.pos[self.members[x]] = -1
    }
    self.cnt = 0
}

// ---------- the interference graph ----------
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
}

priv enum MS {
    Worklist,
    Active,
    Coalesced,
    Constrained,
    Frozen,
}

// Nodes 0..31 are the machine registers (precolored), the others the virtual registers of
// both classes.
priv struct Irc {
    k: i64 // colours of the class being coloured
    n: i64
    nv: i64 // virtual registers: n - 32
    state: Vec[NS]
    pmask: Vec[u64]          // the machine registers each node interferes with
    adj_set: Map[u64, bool]  // the edges between virtual registers (graphs too large for adj_bits)
    adj_bits: Vec[u64]       // the same as a bit matrix, nv x nv (empty: adj_set is used)
    adj: Lists
    degree: Vec[i64]
    moves: Vec[(i64, i64)]
    mstate: Vec[MS]
    move_list: Lists // every move of the node (for biased coloring)
    act_list: Lists  // its moves that may still be coalesced (finished ones are dropped)
    alias: Vec[i64]
    color: Vec[i64]
    simplify_wl: Vec[i64]
    freeze_wl: Vec[i64]
    spill_wl: Vec[i64]
    move_wl: Vec[i64]
    stack: Vec[i64]
    cost: Vec[f64]
    seen: Vec[i64] // stamps of the Briggs test
    stamp: i64
    // cost / degree of each node for the choice of a spill candidate, recomputed only after
    // its cost or degree changed (rdirty)
    ratio: Vec[f64]
    rdirty: Vec[bool]
}

// the edge between machine register r and virtual register v, if new
priv inline fn pre_edge(self: *Irc, r: i64, v: i64) {
    bit := u64(1) << u64(r)
    if self.pmask[v] & bit == 0 {
        self.pmask[v] |= bit
        self.adj.lpush(v, r)
        self.degree[v] += 1
    }
}

// the edge between virtual registers u != v, if new (the lists of u, then of v)
priv fn virt_edge(self: *Irc, u: i64, v: i64) {
    if self.adj_bits.len > 0 {
        x := (u - 32) * self.nv + (v - 32)
        w := self.adj_bits[x >> 6]
        bit := u64(1) << u64(x & 63)
        if w & bit != 0 {
            return
        }
        self.adj_bits[x >> 6] = w | bit
        y := (v - 32) * self.nv + (u - 32)
        self.adj_bits[y >> 6] |= u64(1) << u64(y & 63)
    } else {
        key := (u64(min(u, v)) << 32) | u64(max(u, v))
        if self.adj_set.has(key) {
            return
        }
        self.adj_set.set(key, true)
    }
    self.adj.lpush(u, v)
    self.degree[u] += 1
    self.adj.lpush(v, u)
    self.degree[v] += 1
}

priv fn add_edge(self: *Irc, u: i64, v: i64) {
    if u == v {
        return
    }
    if u < 32 {
        if v >= 32 {
            self.pre_edge(u, v)
        }
        // (between machine registers: never asked for)
        return
    }
    if v < 32 {
        self.pre_edge(v, u)
        return
    }
    self.virt_edge(u, v)
}

// (an edge between two machine registers is never asked for)
priv fn has_edge(self: *Irc, u: i64, v: i64) -> bool {
    if u < 32 {
        return v >= 32 && (self.pmask[v] >> u64(u)) & 1 != 0
    }
    if v < 32 {
        return (self.pmask[u] >> u64(v)) & 1 != 0
    }
    if self.adj_bits.len > 0 {
        x := (u - 32) * self.nv + (v - 32)
        return (self.adj_bits[x >> 6] >> u64(x & 63)) & 1 != 0
    }
    return self.adj_set.has((u64(min(u, v)) << 32) | u64(max(u, v)))
}

// is the neighbour m still in the graph? (Callers walk self.adj[n] and skip the others: a
// list of the remaining neighbours per call filled the arena with gigabytes for nodes that
// interfere with thousands of others.)
priv inline fn in_graph(self: *Irc, m: i64) -> bool {
    st := self.state[m]
    return !(st == Stack || st == Coalesced)
}

// A move that is coalesced, constrained or frozen never becomes active again: it is dropped
// from act_list when met, so that nodes with thousands of moves do not cost quadratic time.
// (The result is a view of the list: it stays valid while other lists change.)
priv fn node_moves(self: *Irc, n: i64) -> []i64 {
    l := self.act_list.lget(n)
    k := 0
    for x in 0..len(l) {
        ms := self.mstate[l[x]]
        if ms == Active || ms == Worklist {
            l[k] = l[x]
            k += 1
        }
    }
    self.act_list.len[n] = k
    return l[..k]
}

priv fn move_related(self: *Irc, n: i64) -> bool {
    b := self.act_list.beg[n]
    l := self.act_list.len[n]
    while l > 0 {
        ms := self.mstate[self.act_list.pool[b + l - 1]]
        if ms == Active || ms == Worklist {
            self.act_list.len[n] = l
            return true
        }
        l -= 1
    }
    self.act_list.len[n] = 0
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

priv inline fn decrement_degree(self: *Irc, m: i64) {
    if m < 32 {
        return
    }
    d := self.degree[m]
    // saturating_sub(1)
    self.degree[m] = if d > 0 { d - 1 } else { 0 }
    self.rdirty[m] = true
    if d == self.k {
        self.degree_fell(m)
    }
}

// the degree of m fell below k
priv fn degree_fell(self: *Irc, m: i64) {
    self.enable_moves(m)
    for a in self.adj.lget(m) {
        if self.in_graph(a) {
            self.enable_moves(a)
        }
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

priv fn simplify(self: *Irc, n: i64) {
    self.state[n] = Stack
    self.stack.push(n)
    k := self.k
    for m in self.adj.lget(n) {
        // (in_graph and decrement_degree)
        if m < 32 {
            continue
        }
        st := self.state[m]
        if st == Stack || st == Coalesced {
            continue
        }
        d := self.degree[m]
        self.degree[m] = if d > 0 { d - 1 } else { 0 }
        self.rdirty[m] = true
        if d == k {
            self.degree_fell(m)
        }
    }
}

priv fn add_worklist(self: *Irc, u: i64) {
    if u >= 32 && self.state[u] == Freeze && !self.move_related(u) && self.degree[u] < self.k {
        self.state[u] = Simplify
        self.simplify_wl.push(u)
    }
}

priv fn ok(self: *Irc, t: i64, r: i64) -> bool {
    return t < 32 || self.degree[t] < self.k || self.has_edge(t, r)
}

priv fn conservative(self: *Irc, u: i64, v: i64) -> bool {
    // George's test from the side of the node with fewer neighbours first: cheap, and the
    // Briggs test below walks both neighbourhoods (quadratic for a node that interferes with
    // thousands of others and is the target of thousands of moves)
    x := u
    y := v
    if self.adj.len[v] > self.adj.len[u] {
        x = v
        y = u
    }
    george := true
    for t in self.adj.lget(x) {
        st := self.state[t]
        if st == Stack || st == Coalesced {
            continue
        }
        if !self.ok(t, y) {
            george = false
            break
        }
    }
    if george {
        return true
    }
    // Briggs: fewer than k neighbours of significant degree (each counted once: marked with
    // a stamp of this test)
    self.stamp += 1
    k := 0
    for w in 0..2 {
        for n in self.adj.lget(if w == 0 { u } else { v }) {
            if self.in_graph(n) && self.seen[n] != self.stamp {
                self.seen[n] = self.stamp
                if n < 32 || self.degree[n] >= self.k {
                    k += 1
                    if k >= self.k {
                        return false
                    }
                }
            }
        }
    }
    return true
}

priv fn combine(self: *Irc, u: i64, v: i64) {
    // v is merged into u
    self.state[v] = Coalesced
    self.alias[v] = u
    // a move may then be listed twice: harmless (its state is checked where it is used)
    nm := self.node_moves(v)
    if u >= 32 {
        self.move_list.merge_moves(u, v)
        self.act_list.merge_moves(u, v)
        self.cost[u] += self.cost[v]
    }
    for m in nm {
        if self.mstate[m] == Active {
            self.mstate[m] = Worklist
            self.move_wl.push(m)
        }
    }
    for t in self.adj.lget(v) {
        if self.in_graph(t) {
            self.add_edge(t, u)
            self.decrement_degree(t)
        }
    }
    // (cost and degree of u changed)
    self.rdirty[u] = true
    if u >= 32 && self.degree[u] >= self.k && self.state[u] == Freeze {
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
    if y < 32 {
        u = y
        v = x
    }
    if u == v {
        self.mstate[m] = Coalesced
        self.add_worklist(u)
    } else if v < 32 || self.has_edge(u, v) {
        self.mstate[m] = Constrained
        self.add_worklist(u)
        self.add_worklist(v)
    } else {
        can := false
        if u < 32 {
            can = true
            for t in self.adj.lget(v) {
                if self.in_graph(t) && !self.ok(t, u) {
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
        if v >= 32 && self.state[v] == Freeze && !self.move_related(v) && self.degree[v] < self.k {
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
            bi := -1
            bc: f64 = 0.0
            for i in 0..self.spill_wl.len {
                n := self.spill_wl[i]
                if self.state[n] != Spill {
                    continue
                }
                if self.rdirty[n] {
                    self.ratio[n] = self.cost[n] / f64(max(self.degree[n], 1))
                    self.rdirty[n] = false
                }
                c := self.ratio[n]
                if bi < 0 || c < bc {
                    bi = i
                    bc = c
                }
            }
            if bi < 0 {
                break
            }
            n := self.spill_wl.swap_remove(bi)
            self.state[n] = Simplify
            self.simplify_wl.push(n)
            self.freeze_moves(n)
        }
    }
}

// pops the stack of class `cls`, assigning colours; appends what cannot be coloured to `spilled`
// and sets `colors` of the virtual registers of the class
priv fn select(g: *Irc, cls: u8, vcls: []u8, spilled: *Vec[i64], colors: *Vec[i64]) {
    while g.stack.len > 0 {
        nd := g.stack.pop()
        avail: u64 = 0xFFFFFFFF
        for w in g.adj.lget(nd) {
            a := g.get_alias(w)
            if g.state[a] == Colored || g.state[a] == Pre {
                avail &= ~(u64(1) << u64(g.color[a]))
            }
        }
        // biased coloring: prefer the color of a move partner
        pick := -1
        for m in g.move_list.lget(nd) {
            x, y := g.moves[m]
            o := if g.get_alias(x) == nd { g.get_alias(y) } else { g.get_alias(x) }
            if g.state[o] == Colored || g.state[o] == Pre {
                c := g.color[o]
                // (c is a register of the class: the test `c in all` of the colours)
                if c >= 0 && c != RSP && (avail >> u64(c)) & 1 != 0 && (if cls == 0 { c < 16 } else { c >= 16 && c < 32 }) {
                    pick = c
                    break
                }
            }
        }
        if pick < 0 {
            if cls == 0 {
                for c in gpr_order {
                    if (avail >> u64(c)) & 1 != 0 {
                        pick = c
                        break
                    }
                }
            } else {
                for c in 16..32 {
                    if (avail >> u64(c)) & 1 != 0 {
                        pick = c
                        break
                    }
                }
            }
        }
        if pick < 0 {
            g.state[nd] = Spilled
            spilled.push(nd)
        } else {
            g.state[nd] = Colored
            g.color[nd] = pick
        }
    }
    for v in 32..g.n {
        if vcls[v] != cls {
            continue
        }
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

// spill weight helper
priv fn depth_weight(d: i64) -> f64 {
    // 10f64.powi(min(d, 6))
    w: f64 = 1.0
    for x in 0..min(d, 6) {
        w *= 10.0
    }
    return w
}

// adds the call clobbers of class `mask` as neighbours of every virtual register of the
// class in `live` (what adding the edges clobber x live member gives, list by list)
priv fn clobber_edges(g: *Irc, live: *RegSet, vcls: []u8, cls: u8, mask: u64) {
    for l in live.members[..live.cnt] {
        if l < 32 || vcls[l] != cls {
            continue
        }
        nw := mask & ~g.pmask[l]
        if nw == 0 {
            continue
        }
        g.pmask[l] |= nw
        while nw != 0 {
            g.adj.lpush(l, i64(ctz(nw)))
            g.degree[l] += 1
            nw &= nw - 1
        }
    }
}

// the edges of a definition of df with the members of `live` of its class (add_edge(l, df)
// for each member l in order)
priv fn def_edges(g: *Irc, live: *RegSet, vcls: []u8, df: i64) {
    c := vcls[df]
    ms := live.members[..live.cnt]
    if df < 32 {
        for l in ms {
            if l >= 32 && vcls[l] == c {
                g.pre_edge(df, l)
            }
        }
        return
    }
    if g.adj_bits.len == 0 {
        for l in ms {
            if l != df && vcls[l] == c {
                g.add_edge(l, df)
            }
        }
        return
    }
    row := (df - 32) * g.nv - 32
    for l in ms {
        if l == df || vcls[l] != c {
            continue
        }
        if l < 32 {
            g.pre_edge(l, df)
            continue
        }
        x := row + l
        if (g.adj_bits[x >> 6] >> u64(x & 63)) & 1 == 0 {
            g.virt_edge(l, df)
        }
    }
}

// the interference graphs of both classes; returns the move worklist of class 1 (that of
// class 0 is g.move_wl)
priv fn build(g: *Irc, mf: *MFunc, order: []i64, dec: *Dec, vcls: []u8, lo_off: *Vec[i64], lo: *Vec[i64]) -> Vec[i64] {
    n := g.n
    du := dec.du.items()
    mwl1 := vec[i64]()
    // the live set as the walk of each class sees it (a copy leaves the set of its class
    // for a moment, which changes the order of its members); a class without virtual
    // registers gets no edges and needs no set
    use0 := false
    use1 := false
    for v in 32..n {
        if vcls[v] == 0 {
            use0 = true
        } else {
            use1 = true
        }
    }
    live0 := regset_new(if use0 { n } else { 0 })
    live1 := regset_new(if use1 { n } else { 0 })
    for oi, b in order {
        w := depth_weight(mf.blocks[b].depth)
        if use0 {
            live0.clear_all()
            for x in lo_off[oi]..lo_off[oi + 1] {
                live0.add(lo[x])
            }
        }
        if use1 {
            live1.clear_all()
            for x in lo_off[oi]..lo_off[oi + 1] {
                live1.add(lo[x])
            }
        }
        for k in dec.binst[oi + 1] - 1..=dec.binst[oi] by -1 {
            p := dec.ipos[k]
            h := du[p]
            nd := h & 255
            q := p + 1 + nd
            e := q + ((h >> 8) & 255)
            for j in p + 1..e {
                r := du[j]
                if r >= 32 {
                    g.cost[r] += w
                }
            }
            if h & (DU_COPY << 16) != 0 {
                d := du[p + 1]
                s := du[p + 2]
                c := vcls[d]
                if vcls[s] == c && d != s && d != RSP && s != RSP {
                    mi := g.moves.len
                    g.moves.push((d, s))
                    g.mstate.push(Worklist)
                    g.move_list.lpush(d, mi)
                    g.move_list.lpush(s, mi)
                    g.act_list.lpush(d, mi)
                    g.act_list.lpush(s, mi)
                    if c == 0 {
                        if use0 {
                            live0.remove(s)
                        }
                        g.move_wl.push(mi)
                    } else {
                        if use1 {
                            live1.remove(s)
                        }
                        mwl1.push(mi)
                    }
                }
            }
            for j in p + 1..q {
                df := du[j]
                if vcls[df] == 0 {
                    if use0 {
                        def_edges(g, &live0, vcls, df)
                    }
                } else if use1 {
                    def_edges(g, &live1, vcls, df)
                }
            }
            call := h & (DU_CALL << 16) != 0
            if call {
                if use0 {
                    clobber_edges(g, &live0, vcls, 0, CLOBBER_GPR)
                }
                if use1 {
                    clobber_edges(g, &live1, vcls, 1, CLOBBER_XMM)
                }
            }
            // simultaneous defs interfere with each other (the call clobbers are machine
            // registers, which need no edges among themselves)
            if nd > 1 {
                for x1 in p + 1..q {
                    if du[x1] < 32 {
                        continue
                    }
                    for y1 in p + 1..q {
                        if x1 != y1 && vcls[du[y1]] == vcls[du[x1]] {
                            g.add_edge(du[x1], du[y1])
                        }
                    }
                }
            }
            if use0 {
                for j in p + 1..q {
                    live0.remove(du[j])
                }
                if call {
                    for r in CALL_CLOBBER {
                        live0.remove(r)
                    }
                }
                for j in q..e {
                    live0.add(du[j])
                }
            }
            if use1 {
                for j in p + 1..q {
                    live1.remove(du[j])
                }
                if call {
                    for r in CALL_CLOBBER {
                        live1.remove(r)
                    }
                }
                for j in q..e {
                    live1.add(du[j])
                }
            }
        }
    }
    return mwl1
}

struct Alloc {
    used_callee_saved: Vec[i64]
}

priv fn spill_slot(o: *Opnd, first_spill: i64) -> i64 {
    match o {
        M(&m) => {
            if m.kind == MK_SLOT && i64(m.id) >= first_spill && m.base == NOREG && m.idx == NOREG && m.disp == 0 {
                return i64(m.id)
            }
        }
        _ => {}
    }
    return -1
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
    the_pred := vec_fill(nb, -1)
    for b in order {
        for s in mf.blocks[b].succs {
            npreds[s] += 1
            the_pred[s] = b
        }
    }
    no_state: Opt[Vec[(i64, i64)]] = None
    out_state := vec_fill(nb, no_state)
    du := vec_fill(DU_MAX, 0)
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
        insts := &mf.blocks[b].insts
        n := 0
        for x in 0..insts.len {
            i := &insts[x]
            sa := spill_slot(&i.a, first_spill)
            is_store := (i.op == Mov || i.op == MovSd) && sa >= 0
            // uses of a slot whose value is still in a register
            sb := spill_slot(&i.b, first_spill)
            if sb >= 0 {
                fi := find_slot(&st, sb)
                if fi >= 0 {
                    r := st[fi].1
                    full_reload := ((i.op == Mov && i.sz == 8) || i.op == MovSd) && is_r(i.a)
                    if full_reload && i.a == R(r) {
                        continue
                    }
                    i.b = R(r)
                }
            }
            if (i.op == Cmp || i.op == Test) && sa >= 0 {
                fi := find_slot(&st, sa)
                if fi >= 0 {
                    i.a = R(st[fi].1)
                }
            }
            if st.len > 0 {
                mir_decode(mf, i, du.items(), 0)
                h := du[0]
                for j in 1..1 + (h & 255) {
                    retain_reg_ne(&st, du[j])
                }
                if h & (DU_CALL << 16) != 0 {
                    for r in CALL_CLOBBER {
                        retain_reg_ne(&st, r)
                    }
                }
            }
            if is_store {
                retain_slot_ne(&st, sa)
                match i.b {
                    R(r) => st.push((sa, r))
                    _ => {}
                }
            } else {
                sb2 := spill_slot(&i.b, first_spill)
                match i.a {
                    R(d) if sb2 >= 0 => {
                        if ((i.op == Mov && i.sz == 8) || i.op == MovSd) && find_slot(&st, sb2) < 0 {
                            st.push((sb2, d))
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
            if n != x {
                insts[n] = insts[x]
            }
            n += 1
        }
        insts.len = n
        out_state[b] = Some(st)
    }
    // remove stores to slots that are never read
    reads := vec_fill(mf.slots.len, 0)
    for b in order {
        insts := &mf.blocks[b].insts
        for x in 0..insts.len {
            i := &insts[x]
            is_store := (i.op == Mov || i.op == MovSd) && spill_slot(&i.a, first_spill) >= 0
            match &i.a {
                M(&m) if m.kind == MK_SLOT && i64(m.id) >= first_spill && !is_store => reads[i64(m.id)] += 1
                _ => {}
            }
            match &i.b {
                M(&m) if m.kind == MK_SLOT && i64(m.id) >= first_spill => reads[i64(m.id)] += 1
                _ => {}
            }
        }
    }
    for b in order {
        // insts.retain(..)
        insts := &mf.blocks[b].insts
        n := 0
        for x in 0..insts.len {
            i := &insts[x]
            keep := true
            if i.op == Mov || i.op == MovSd {
                s := spill_slot(&i.a, first_spill)
                if s >= 0 {
                    keep = reads[s] > 0
                }
            }
            if keep {
                if n != x {
                    insts[n] = insts[x]
                }
                n += 1
            }
        }
        insts.len = n
    }
}

fn regalloc_allocate(mf: *MFunc, order: []i64) -> Alloc {
    first_spill := mf.slots.len
    unspillable := vec_fill(mf.vclass.len, false)
    round := 0
    loop {
        round += 1
        n := 32 + mf.vclass.len
        unspillable.resize(mf.vclass.len, false)
        // the graphs of a round are thrown away at the start of the next one
        scratch_reset()
        scratch_on()
        dec := decode(mf, order, n)
        vcls := vec_fill(n, u8(0))
        for r in 16..32 {
            vcls[r] = 1
        }
        for v in 0..mf.vclass.len {
            vcls[32 + v] = mf.vclass[v]
        }
        lo_off := vec[i64]()
        lo := vec[i64]()
        liveness(mf, order, &dec, n, &lo_off, &lo)
        nv := n - 32
        g := Irc{
            k: 15,
            n: n,
            nv: nv,
            state: vec_fill(n, Initial),
            pmask: vec_fill(n, u64(0)),
            adj_set: map[u64, bool](),
            // a bit matrix up to 16 MB (11585 virtual registers), a hash set beyond
            adj_bits: if nv <= 11585 { vec_fill((nv * nv + 64) / 64, u64(0)) } else { vec[u64]() },
            adj: lists_new(n, 8),
            degree: vec_fill(n, 0),
            moves: vec[(i64, i64)](),
            mstate: vec[MS](),
            move_list: lists_new(n, 2),
            act_list: lists_new(n, 2),
            alias: vec_fill(n, 0),
            color: vec_fill(n, -1),
            simplify_wl: vec[i64](),
            freeze_wl: vec[i64](),
            spill_wl: vec[i64](),
            move_wl: vec[i64](),
            stack: vec[i64](),
            cost: vec_fill(n, f64(0.0)),
            seen: vec_fill(n, 0),
            stamp: 0,
            ratio: vec_fill(n, f64(0.0)),
            rdirty: vec_fill(n, true),
        }
        for r in 0..32 {
            g.state[r] = Pre
            g.color[r] = r
            g.degree[r] = 0xFFFFFFFF / 2
        }
        mwl1 := build(&g, mf, order, &dec, vcls.items(), &lo_off, &lo)
        for v in 0..mf.vclass.len {
            if unspillable[v] {
                g.cost[32 + v] = 1e30
            }
        }
        spilled := vec[i64]()
        colors := vec_fill(n, -1)
        for cls in 0..2 {
            c := u8(cls)
            g.k = if cls == 0 { 15 } else { 16 }
            if cls == 1 {
                g.move_wl = mwl1
                g.spill_wl.clear()
            }
            // make worklists
            for v in 32..n {
                if vcls[v] != c {
                    continue
                }
                if g.degree[v] >= g.k {
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
            select(&g, c, vcls.items(), &spilled, &colors)
        }
        scratch_off()
        spilled = clone(spilled)
        colors = clone(colors)
        if spilled.is_empty() {
            used := rewrite(mf, order, &dec, colors.items())
            used_callee_saved := vec[i64]()
            for r in 0..16 {
                if (used >> u64(r)) & 1 != 0 && mir_callee_saved(r) {
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
        spill(mf, order, &dec, spilled.items(), &unspillable)
    }
}

// rewrites the virtual registers to their colours (in place; copies that became `mov r, r`
// go away); returns the registers defined outside calls as a bit mask
priv fn rewrite(mf: *MFunc, order: []i64, dec: *Dec, colors: []i64) -> u64 {
    // (the mapping `|r| if r >= 32 { colors[r] } else { r }` as a table)
    table := vec_fill(len(colors), 0)
    for r in 0..len(colors) {
        table[r] = if r >= 32 { colors[r] } else { r }
    }
    du := dec.du.items()
    used: u64 = 0
    k := 0
    for b in order {
        insts := &mf.blocks[b].insts
        n := 0
        for x in 0..insts.len {
            p := dec.ipos[k]
            k += 1
            h := du[p]
            if h & (DU_COPY << 16) != 0 && table[du[p + 1]] == table[du[p + 2]] {
                continue
            }
            if h & (DU_CALL << 16) == 0 {
                for j in p + 1..p + 1 + (h & 255) {
                    used |= u64(1) << u64(table[du[j]])
                }
            }
            mir_map_regs(&insts[x], table.items())
            if n != x {
                insts[n] = insts[x]
            }
            n += 1
        }
        insts.len = n
    }
    return used
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

// is r one of the registers du[a..b]?
priv fn du_has(du: []i64, a: i64, b: i64, r: i64) -> bool {
    for j in a..b {
        if du[j] == r {
            return true
        }
    }
    return false
}

// rewrites the instructions that use or define a spilled register: a memory operand where
// the instruction allows one, else a fresh unspillable register loaded before / stored after
priv fn spill(mf: *MFunc, order: []i64, dec: *Dec, spilled: []i64, unspillable: *Vec[bool]) {
    slot_of := vec_fill(32 + mf.vclass.len, -1)
    for v in spilled {
        slot_of[v] = if mf.wide_xmm && mf.class(v) == 1 { mf.new_slot(16, 16) } else { mf.new_slot(8, 8) }
    }
    du := dec.du.items()
    touched: [48]i64
    after := vec[MInst]()
    for oi, b in order {
        // only blocks with an instruction that touches a spilled register change
        k0 := dec.binst[oi]
        k1 := dec.binst[oi + 1]
        any := false
        for k in k0..k1 {
            p := dec.ipos[k]
            h := du[p]
            for j in p + 1..p + 1 + (h & 255) + ((h >> 8) & 255) {
                if slot_of[du[j]] >= 0 {
                    any = true
                    break
                }
            }
            if any {
                break
            }
        }
        if !any {
            continue
        }
        insts := mf.blocks[b].insts
        out := vec[MInst]()
        out.reserve(insts.len + 16)
        for x in 0..insts.len {
            p := dec.ipos[k0 + x]
            h := du[p]
            nd := h & 255
            q := p + 1 + nd
            e := q + ((h >> 8) & 255)
            // the spilled registers it touches, ascending, each once
            nt := 0
            for j in p + 1..e {
                r := du[j]
                if slot_of[r] < 0 {
                    continue
                }
                y := 0
                while y < nt && touched[y] < r {
                    y += 1
                }
                if y < nt && touched[y] == r {
                    continue
                }
                z := nt
                while z > y {
                    touched[z] = touched[z - 1]
                    z -= 1
                }
                touched[y] = r
                nt += 1
            }
            if nt == 0 {
                out.push(insts[x])
                continue
            }
            i := insts[x]
            after.clear()
            for ti in 0..nt {
                v := touched[ti]
                slot := slot_of[v]
                cls := mf.class(v)
                mem := M(mem_slot(slot, 0))
                mv := if cls == 1 { MovSd } else { Mov }
                msz: u8 = if cls == 1 && mf.wide_xmm { 16 } else { 8 }
                is_def := du_has(du, p + 1, q, v)
                is_use := du_has(du, q, e, v)
                // direct forms that avoid a temporary
                d, s, is_cp := i.is_copy()
                if is_cp {
                    if s == v && d != v && !(d < slot_of.len && slot_of[d] >= 0) {
                        i.b = mem
                        i.sz = msz
                        continue
                    }
                    if d == v && s != v && !(s < slot_of.len && slot_of[s] >= 0) {
                        i.a = mem
                        i.sz = msz
                        continue
                    }
                }
                if is_use && !is_def && i.b == R(v) && b_can_be_mem(&i) {
                    // the only occurrence must be operand b
                    if mir_count_reg(&i, v) == 1 {
                        i.b = mem
                        if i.op == MovSd {
                            i.sz = msz
                        }
                        continue
                    }
                }
                if i.op == Mov && i.sz == 8 && i.a == R(v) && is_def && !is_use {
                    match i.b {
                        I(c) if c >= -2147483648 && c <= 2147483647 => {
                            i.a = mem
                            continue
                        }
                        _ => {}
                    }
                }
                t := mf.new_vreg(cls)
                unspillable.push(true)
                mir_replace_reg(&i, v, t)
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
