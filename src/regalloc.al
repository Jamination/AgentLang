// Iterated register coalescing (George & Appel) over machine IR, for both back ends: the
// target-independent part. src/x86/regalloc.al and src/arm64/regalloc.al instantiate it with
// their machine function type F (MFunc, AFunc) and instruction type I (MInst, AInst), and
// supply what differs as public functions overloaded on those types (`inline`, so that an
// instance compiles to what a copy of this file for one target would: see "Register
// allocation" in docs/BOOTSTRAP.md):
//
//   ra_npre(mf) -> i64                  nodes below it are the machine registers (precoloured);
//                                       the virtual registers are numbered from it
//   ra_class(mf, r) -> u8               register class of a node: 0 general, 1 float / vector
//   ra_decode(mf, i, du, p) -> i64      the registers instruction i defines and uses, in the
//                                       format of mir_decode (src/x86/mir.al); the operand
//                                       constraints (x86 two-address and fixed registers, the
//                                       early-clobber operands of the arm64 atomic loops) are
//                                       expressed there, as defs, uses and machine registers
//   ra_call_clobber(mf) -> []i64        the machine registers a call (DU_CALL) defines
//   ra_clobber_mask(mf, cls) -> u64     the same, of class cls, as a bit mask
//   ra_order(mf, cls) -> []i64          the allocatable registers of the class, in the order
//                                       they are tried (its length is the number of colours)
//   ra_allocatable(mf, cls, c) -> bool  is machine register c a colour of class cls?
//   ra_coalescable(mf, d, s) -> bool    may the copy d <- s be coalesced?
//   ra_map_regs(i, table)               renames the registers of i (r -> table[r])
//   ra_replace_reg(i, from, to)         renames one register of i
//   ra_new_vreg(mf, cls) -> i64         a new virtual register
//   ra_spill_slot(mf, v) -> i64         a new frame slot for spilled register v
//   ra_spill_direct(mf, i, v, slot, is_def, is_use, nt, slot_of) -> bool
//                                       rewrites instruction i to access the slot of spilled v
//                                       directly (a memory operand, a copy that becomes the
//                                       load or store), if it can; nt: the number of spilled
//                                       registers i touches
//   ra_spill_load(mf, cls, r, slot) -> I, ra_spill_store(mf, cls, r, slot) -> I
//                                       spill code: register r of class cls <-> the slot
//   ra_spill_forward(mf, order, first_spill)
//                                       after the allocation, when something was spilled:
//                                       forwards spill slots kept in registers, removes dead
//                                       stores (the shape of spill code is the target's)
//
// Each round decodes the registers every instruction defines and uses once (ra_decode) into
// one buffer; liveness and the interference graphs of both register classes are built from
// it in one walk. The two classes share the node arrays (their nodes are disjoint) and are
// coloured one after the other. Every list keeps the order in which the textbook algorithm
// fills it: the order of adjacency and move lists decides the colouring.

// ---------- the result ----------
// Where each register of a function ended up (by node number: machine registers below
// ra_npre are themselves). The allocation has rewritten the machine IR to machine registers
// already; this is what is no longer visible there, for whoever maps the virtual registers of
// isel to places (debug information for register-allocated variables): a virtual register is
// in machine register reg[r] (-1: none) for its whole life, or it was spilled and lives in
// frame slot slot[r] (-1 or past the end: not spilled; then only the registers that stand in
// for it at each access, which are other nodes, hold it for a moment).
struct RaAssign {
    reg: Vec[i64]
    slot: Vec[i64]
}

// the machine register of node r, or -1 (spilled, or not a node of the function)
fn ra_reg(a: *RaAssign, r: i64) -> i64 {
    return if r >= 0 && r < a.reg.len { a.reg[r] } else { -1 }
}

// the spill slot of node r, or -1
fn ra_slot(a: *RaAssign, r: i64) -> i64 {
    return if r >= 0 && r < a.slot.len { a.slot[r] } else { -1 }
}

struct RaResult {
    used: u64 // the machine registers written outside calls, as a bit mask
    assign: RaAssign
}

// ---------- decoded instructions ----------
priv struct Dec {
    du: Vec[i64]    // ra_decode entries of all instructions in `order`
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

priv fn decode[F](mf: *F, order: []i64, n: i64) -> Dec {
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
            q0 := ra_decode(mf, &insts[x], du.items(), p)
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
                for r in ra_call_clobber(mf) {
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
priv fn liveness[F](mf: *F, order: []i64, dec: *Dec, n: i64, lo_off: *Vec[i64], lo: *Vec[i64]) {
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
            for r in ra_call_clobber(mf) {
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
    copy(self.pool[nb..nb + l], self.pool[ob..ob + l])
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

// Nodes below npre() are the machine registers (precolored), the others the virtual registers
// of both classes.
priv struct Irc[F] {
    k: i64 // colours of the class being coloured
    n: i64
    nv: i64 // virtual registers: n - npre()
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
    mf: *F // the function (its type is the target)
}

// the number of machine registers of the target (a constant of each instance: ra_npre is an
// inline function of the target that ignores its argument)
priv inline fn npre[F](self: *Irc[F]) -> i64 {
    mf: *F
    return ra_npre(mf)
}

// the edge between machine register r and virtual register v, if new
priv inline fn pre_edge[F](self: *Irc[F], r: i64, v: i64) {
    bit := u64(1) << u64(r)
    if self.pmask[v] & bit == 0 {
        self.pmask[v] |= bit
        self.adj.lpush(v, r)
        self.degree[v] += 1
    }
}

// the edge between virtual registers u != v, if new (the lists of u, then of v)
priv fn virt_edge[F](self: *Irc[F], u: i64, v: i64) {
    if self.adj_bits.len > 0 {
        x := (u - self.npre()) * self.nv + (v - self.npre())
        w := self.adj_bits[x >> 6]
        bit := u64(1) << u64(x & 63)
        if w & bit != 0 {
            return
        }
        self.adj_bits[x >> 6] = w | bit
        y := (v - self.npre()) * self.nv + (u - self.npre())
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

priv fn add_edge[F](self: *Irc[F], u: i64, v: i64) {
    if u == v {
        return
    }
    if u < self.npre() {
        if v >= self.npre() {
            self.pre_edge(u, v)
        }
        // (between machine registers: never asked for)
        return
    }
    if v < self.npre() {
        self.pre_edge(v, u)
        return
    }
    self.virt_edge(u, v)
}

// (an edge between two machine registers is never asked for)
priv fn has_edge[F](self: *Irc[F], u: i64, v: i64) -> bool {
    if u < self.npre() {
        return v >= self.npre() && (self.pmask[v] >> u64(u)) & 1 != 0
    }
    if v < self.npre() {
        return (self.pmask[u] >> u64(v)) & 1 != 0
    }
    if self.adj_bits.len > 0 {
        x := (u - self.npre()) * self.nv + (v - self.npre())
        return (self.adj_bits[x >> 6] >> u64(x & 63)) & 1 != 0
    }
    return self.adj_set.has((u64(min(u, v)) << 32) | u64(max(u, v)))
}

// is the neighbour m still in the graph? (Callers walk self.adj[n] and skip the others: a
// list of the remaining neighbours per call filled the arena with gigabytes for nodes that
// interfere with thousands of others.)
priv inline fn in_graph[F](self: *Irc[F], m: i64) -> bool {
    st := self.state[m]
    return !(st == Stack || st == Coalesced)
}

// A move that is coalesced, constrained or frozen never becomes active again: it is dropped
// from act_list when met, so that nodes with thousands of moves do not cost quadratic time.
// (The result is a view of the list: it stays valid while other lists change.)
priv fn node_moves[F](self: *Irc[F], n: i64) -> []i64 {
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

priv fn move_related[F](self: *Irc[F], n: i64) -> bool {
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

priv fn get_alias[F](self: *Irc[F], n0: i64) -> i64 {
    n := n0
    while self.state[n] == Coalesced {
        n = self.alias[n]
    }
    return n
}

priv fn enable_moves[F](self: *Irc[F], n: i64) {
    nm := self.node_moves(n)
    for m in nm {
        if self.mstate[m] == Active {
            self.mstate[m] = Worklist
            self.move_wl.push(m)
        }
    }
}

priv inline fn decrement_degree[F](self: *Irc[F], m: i64) {
    if m < self.npre() {
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
priv fn degree_fell[F](self: *Irc[F], m: i64) {
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

priv fn simplify[F](self: *Irc[F], n: i64) {
    self.state[n] = Stack
    self.stack.push(n)
    k := self.k
    for m in self.adj.lget(n) {
        // (in_graph and decrement_degree)
        if m < self.npre() {
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

priv fn add_worklist[F](self: *Irc[F], u: i64) {
    if u >= self.npre() && self.state[u] == Freeze && !self.move_related(u) && self.degree[u] < self.k {
        self.state[u] = Simplify
        self.simplify_wl.push(u)
    }
}

priv fn ok[F](self: *Irc[F], t: i64, r: i64) -> bool {
    return t < self.npre() || self.degree[t] < self.k || self.has_edge(t, r)
}

priv fn conservative[F](self: *Irc[F], u: i64, v: i64) -> bool {
    // George's test from the side of the node with fewer neighbours first: cheap, and the
    // Briggs test below walks both neighbourhoods (quadratic for a node that interferes with
    // thousands of others and is the target of thousands of moves)
    x, y := if self.adj.len[v] > self.adj.len[u] { (v, u) } else { (u, v) }
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
    for w in [2]i64{u, v} {
        for n in self.adj.lget(w) {
            if self.in_graph(n) && self.seen[n] != self.stamp {
                self.seen[n] = self.stamp
                if n < self.npre() || self.degree[n] >= self.k {
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

priv fn combine[F](self: *Irc[F], u: i64, v: i64) {
    // v is merged into u
    self.state[v] = Coalesced
    self.alias[v] = u
    // a move may then be listed twice: harmless (its state is checked where it is used)
    // (before the merge, which empties v's lists)
    self.enable_moves(v)
    if u >= self.npre() {
        self.move_list.merge_moves(u, v)
        self.act_list.merge_moves(u, v)
        self.cost[u] += self.cost[v]
    }
    for t in self.adj.lget(v) {
        if self.in_graph(t) {
            self.add_edge(t, u)
            self.decrement_degree(t)
        }
    }
    // (cost and degree of u changed)
    self.rdirty[u] = true
    if u >= self.npre() && self.degree[u] >= self.k && self.state[u] == Freeze {
        self.state[u] = Spill
        self.spill_wl.push(u)
    }
}

priv fn coalesce[F](self: *Irc[F], m: i64) {
    d, s := self.moves[m]
    x := self.get_alias(d)
    y := self.get_alias(s)
    u, v := if y < self.npre() { (y, x) } else { (x, y) }
    if u == v {
        self.mstate[m] = Coalesced
        self.add_worklist(u)
    } else if v < self.npre() || self.has_edge(u, v) {
        self.mstate[m] = Constrained
        self.add_worklist(u)
        self.add_worklist(v)
    } else {
        can := false
        if u < self.npre() {
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

priv fn freeze_moves[F](self: *Irc[F], u: i64) {
    nm := self.node_moves(u)
    for m in nm {
        x, y := self.moves[m]
        v := if self.get_alias(y) == self.get_alias(u) { self.get_alias(x) } else { self.get_alias(y) }
        self.mstate[m] = Frozen
        self.add_worklist(v)
    }
}

priv fn run[F](self: *Irc[F]) {
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
priv fn select[F](g: *Irc[F], cls: u8, vcls: []u8, spilled: *Vec[i64], colors: *Vec[i64]) {
    mf := g.mf
    while g.stack.len > 0 {
        nd := g.stack.pop()
        avail: u64 = ~u64(0)
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
                if c >= 0 && (avail >> u64(c)) & 1 != 0 && ra_allocatable(mf, cls, c) {
                    pick = c
                    break
                }
            }
        }
        if pick < 0 {
            for c in ra_order(mf, cls) {
                if (avail >> u64(c)) & 1 != 0 {
                    pick = c
                    break
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
    for v in g.npre()..g.n {
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

// spill weight of a block at loop depth d: 10^min(d, 6)
priv const DEPTH_W = [7]f64{1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0}

priv fn depth_weight(d: i64) -> f64 {
    return DEPTH_W[min(d, 6)]
}

// adds the call clobbers of class `mask` as neighbours of every virtual register of the
// class in `live` (what adding the edges clobber x live member gives, list by list)
priv fn clobber_edges[F](g: *Irc[F], live: *RegSet, vcls: []u8, cls: u8, mask: u64) {
    for l in live.members[..live.cnt] {
        if l < g.npre() || vcls[l] != cls {
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
priv fn def_edges[F](g: *Irc[F], live: *RegSet, vcls: []u8, df: i64) {
    c := vcls[df]
    ms := live.members[..live.cnt]
    if df < g.npre() {
        for l in ms {
            if l >= g.npre() && vcls[l] == c {
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
    row := (df - g.npre()) * g.nv - g.npre()
    for l in ms {
        if l == df || vcls[l] != c {
            continue
        }
        if l < g.npre() {
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
priv fn build[F](g: *Irc[F], order: []i64, dec: *Dec, vcls: []u8, lo_off: *Vec[i64], lo: *Vec[i64]) -> Vec[i64] {
    mf := g.mf
    n := g.n
    du := dec.du.items()
    mwl1 := vec[i64]()
    // the live set as the walk of each class sees it (a copy leaves the set of its class
    // for a moment, which changes the order of its members); a class without virtual
    // registers gets no edges and needs no set
    use0 := false
    use1 := false
    for v in g.npre()..n {
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
                if r >= g.npre() {
                    g.cost[r] += w
                }
            }
            if h & (DU_COPY << 16) != 0 {
                d := du[p + 1]
                s := du[p + 2]
                c := vcls[d]
                if vcls[s] == c && d != s && ra_coalescable(mf, d, s) {
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
                    clobber_edges(g, &live0, vcls, 0, ra_clobber_mask(mf, 0))
                }
                if use1 {
                    clobber_edges(g, &live1, vcls, 1, ra_clobber_mask(mf, 1))
                }
            }
            // simultaneous defs interfere with each other (the call clobbers are machine
            // registers, which need no edges among themselves)
            if nd > 1 {
                for x1 in p + 1..q {
                    if du[x1] < g.npre() {
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
                    for r in ra_call_clobber(mf) {
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
                    for r in ra_call_clobber(mf) {
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

// ---------- the allocation ----------
// Colours the virtual registers of mf (blocks in `order`, the layout) with machine registers,
// spilling to new frame slots and colouring again until nothing is spilled, and rewrites the
// instructions to the machine registers. (w: the Work of the thread, whose scratch region
// holds the graphs of a round)
fn ra_allocate[F, I](mf: *F, order: []i64, w: *Work) -> RaResult {
    npre := ra_npre(mf)
    first_spill := mf.slots.len
    unspillable := vec_fill(mf.vclass.len, false)
    // the spill slot of each register spilled so far (by node; RaAssign.slot)
    slots := vec[i64]()
    round := 0
    loop {
        round += 1
        n := npre + mf.vclass.len
        unspillable.resize(mf.vclass.len, false)
        // the graphs of a round are thrown away at the start of the next one
        scratch_reset(w)
        scratch_on(w)
        dec := decode(mf, order, n)
        vcls := vec_fill(n, u8(0))
        for r in 0..npre {
            vcls[r] = ra_class(mf, r)
        }
        copy(vcls[npre..], mf.vclass.items())
        lo_off := vec[i64]()
        lo := vec[i64]()
        liveness(mf, order, &dec, n, &lo_off, &lo)
        nv := n - npre
        g := Irc[F]{
            mf: mf,
            k: len(ra_order(mf, 0)),
            n: n,
            nv: nv,
            state: vec_fill(n, Initial),
            pmask: vec_fill(n, u64(0)),
            // a bit matrix up to 16 MB (11585 virtual registers), a hash set (adj_set) beyond
            adj_bits: if nv <= 11585 { vec_fill((nv * nv + 64) / 64, u64(0)) } else { vec[u64]() },
            adj: lists_new(n, 8),
            degree: vec_fill(n, 0),
            move_list: lists_new(n, 2),
            act_list: lists_new(n, 2),
            alias: vec_fill(n, 0),
            color: vec_fill(n, -1),
            cost: vec_fill(n, f64(0.0)),
            seen: vec_fill(n, 0),
            ratio: vec_fill(n, f64(0.0)),
            rdirty: vec_fill(n, true),
        }
        for r in 0..npre {
            g.state[r] = Pre
            g.color[r] = r
            g.degree[r] = 0xFFFFFFFF / 2
        }
        mwl1 := build(&g, order, &dec, vcls.items(), &lo_off, &lo)
        for v in 0..mf.vclass.len {
            if unspillable[v] {
                g.cost[npre + v] = 1e30
            }
        }
        spilled := vec[i64]()
        colors := vec_fill(n, -1)
        for cls in 0..2 {
            c := u8(cls)
            g.k = len(ra_order(mf, c))
            if cls == 1 {
                g.move_wl = mwl1
                g.spill_wl.clear()
            }
            // make worklists
            for v in npre..n {
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
        scratch_off(w)
        spilled = clone(spilled)
        colors = clone(colors)
        if spilled.is_empty() {
            used := rewrite(mf, order, &dec, colors.items())
            if mf.slots.len > first_spill {
                ra_spill_forward(mf, order, first_spill)
            }
            // the final assignment: colors by node (the machine registers are themselves);
            // a register spilled in an earlier round is in its slot, not in a register
            for r in 0..npre {
                colors[r] = r
            }
            for r in 0..slots.len {
                if slots[r] >= 0 {
                    colors[r] = -1
                }
            }
            return RaResult{used: used, assign: RaAssign{reg: colors, slot: slots}}
        }
        if round > 40 {
            panic(fmt("register allocation did not converge in `", mf.name, "`"))
        }
        spill[F, I](mf, order, &dec, spilled.items(), &unspillable, &slots)
    }
}

// rewrites the virtual registers to their colours (in place; copies that became `mov r, r`
// go away); returns the registers defined outside calls as a bit mask
priv fn rewrite[F](mf: *F, order: []i64, dec: *Dec, colors: []i64) -> u64 {
    npre := ra_npre(mf)
    // (r >= npre becomes colors[r], a machine register stays)
    table := vec_fill(len(colors), 0)
    for r in 0..len(colors) {
        table[r] = if r >= npre { colors[r] } else { r }
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
            ra_map_regs(&insts[x], table.items())
            if n != x {
                insts[n] = insts[x]
            }
            n += 1
        }
        insts.len = n
    }
    return used
}

// rewrites the instructions that use or define a spilled register: a direct access to the
// slot where the target has one (ra_spill_direct), else a fresh unspillable register loaded
// before / stored after; records the slots in `slots` (by node)
priv fn spill[F, I](mf: *F, order: []i64, dec: *Dec, spilled: []i64, unspillable: *Vec[bool], slots: *Vec[i64]) {
    slot_of := vec_fill(ra_npre(mf) + mf.vclass.len, -1)
    for v in spilled {
        slot_of[v] = ra_spill_slot(mf, v)
    }
    slots.resize(slot_of.len, -1)
    for v in spilled {
        slots[v] = slot_of[v]
    }
    du := dec.du.items()
    touched: [48]i64
    after := vec[I]()
    for oi, b in order {
        // only blocks with an instruction that touches a spilled register change
        k0 := dec.binst[oi]
        k1 := dec.binst[oi + 1]
        any := false
        scan: for k in k0..k1 {
            p := dec.ipos[k]
            h := du[p]
            for j in p + 1..p + 1 + (h & 255) + ((h >> 8) & 255) {
                if slot_of[du[j]] >= 0 {
                    any = true
                    break scan
                }
            }
        }
        if !any {
            continue
        }
        insts := mf.blocks[b].insts
        out := vec[I]()
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
                is_def := contains(du[p + 1..q], v)
                is_use := contains(du[q..e], v)
                if ra_spill_direct(mf, &i, v, slot, is_def, is_use, nt, slot_of.items()) {
                    continue
                }
                cls := ra_class(mf, v)
                t := ra_new_vreg(mf, cls)
                unspillable.push(true)
                ra_replace_reg(&i, v, t)
                if is_use {
                    out.push(ra_spill_load(mf, cls, t, slot))
                }
                if is_def {
                    after.push(ra_spill_store(mf, cls, t, slot))
                }
            }
            out.push(i)
            out.extend(after.items())
        }
        mf.blocks[b].insts = out
    }
}

// ---------- for the targets' ra_spill_forward ----------
// The state of a block: which registers hold the value of which spill slots, as pairs
// (slot, register).

// index of the first entry of `st` for slot `s`, or -1
fn ra_st_slot(st: *Vec[(i64, i64)], s: i64) -> i64 {
    for x in 0..st.len {
        if st[x].0 == s {
            return x
        }
    }
    return -1
}

// index of the first entry of `st` held in register `r`, or -1
fn ra_st_reg(st: *Vec[(i64, i64)], r: i64) -> i64 {
    for x in 0..st.len {
        if st[x].1 == r {
            return x
        }
    }
    return -1
}

// removes the entries held in register d
fn ra_st_drop_reg(st: *Vec[(i64, i64)], d: i64) {
    st.retain(d, fn(d: i64, e: (i64, i64)) -> bool { e.1 != d })
}

// removes the entries for slot s
fn ra_st_drop_slot(st: *Vec[(i64, i64)], s: i64) {
    st.retain(s, fn(s: i64, e: (i64, i64)) -> bool { e.0 != s })
}
