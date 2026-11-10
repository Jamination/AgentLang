// Iterated register coalescing (George & Appel) over machine IR.
use super::mir::*;
use std::collections::HashSet;

const GPR_ORDER: [Reg; 15] = [0, 1, 2, 6, 7, 8, 9, 10, 11, 3, 5, 12, 13, 14, 15];

struct BitSet {
    w: Vec<u64>,
}
impl BitSet {
    fn new(n: usize) -> BitSet {
        BitSet { w: vec![0; (n + 63) / 64] }
    }
    fn set(&mut self, i: u32) {
        self.w[(i / 64) as usize] |= 1u64 << (i % 64);
    }
    fn clear(&mut self, i: u32) {
        self.w[(i / 64) as usize] &= !(1u64 << (i % 64));
    }
    fn union_with(&mut self, o: &BitSet) -> bool {
        let mut ch = false;
        for (a, b) in self.w.iter_mut().zip(o.w.iter()) {
            let n = *a | *b;
            if n != *a {
                *a = n;
                ch = true;
            }
        }
        ch
    }
    fn iter(&self) -> impl Iterator<Item = u32> + '_ {
        self.w.iter().enumerate().flat_map(|(wi, &w)| {
            let mut bits = w;
            std::iter::from_fn(move || {
                if bits == 0 {
                    None
                } else {
                    let t = bits.trailing_zeros();
                    bits &= bits - 1;
                    Some(wi as u32 * 64 + t)
                }
            })
        })
    }
}

fn liveness(mf: &MFunc, order: &[u32]) -> Vec<BitSet> {
    let nreg = 32 + mf.vclass.len();
    let nb = mf.blocks.len();
    let mut gen: Vec<BitSet> = (0..nb).map(|_| BitSet::new(nreg)).collect();
    let mut kill: Vec<BitSet> = (0..nb).map(|_| BitSet::new(nreg)).collect();
    let mut defs = Vec::new();
    let mut uses = Vec::new();
    for &b in order {
        let b = b as usize;
        for i in mf.blocks[b].insts.iter().rev() {
            defs_uses(i, &mut defs, &mut uses);
            for &d in &defs {
                gen[b].clear(d);
                kill[b].set(d);
            }
            for &u in &uses {
                gen[b].set(u);
            }
        }
    }
    let mut live_in: Vec<BitSet> = (0..nb).map(|_| BitSet::new(nreg)).collect();
    let mut live_out: Vec<BitSet> = (0..nb).map(|_| BitSet::new(nreg)).collect();
    let mut changed = true;
    while changed {
        changed = false;
        for &b in order.iter().rev() {
            let b = b as usize;
            let mut out = BitSet { w: live_out[b].w.clone() };
            for si in 0..mf.blocks[b].succs.len() {
                let s = mf.blocks[b].succs[si] as usize;
                out.union_with(&live_in[s]);
            }
            live_out[b] = out;
            // in = gen | (out - kill)
            let mut ch = false;
            for wi in 0..live_in[b].w.len() {
                let n = gen[b].w[wi] | (live_out[b].w[wi] & !kill[b].w[wi]);
                if n != live_in[b].w[wi] {
                    live_in[b].w[wi] = n;
                    ch = true;
                }
            }
            changed |= ch;
        }
    }
    live_out
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum NS {
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

#[derive(Clone, Copy, PartialEq, Eq)]
enum MS {
    Worklist,
    Active,
    Coalesced,
    Constrained,
    Frozen,
}

struct Irc {
    k: usize,
    n: usize,
    state: Vec<NS>,
    adj_set: HashSet<u64>,
    adj: Vec<Vec<u32>>,
    degree: Vec<u32>,
    moves: Vec<(u32, u32)>,
    mstate: Vec<MS>,
    move_list: Vec<Vec<u32>>,
    alias: Vec<u32>,
    color: Vec<u32>,
    simplify_wl: Vec<u32>,
    freeze_wl: Vec<u32>,
    spill_wl: Vec<u32>,
    move_wl: Vec<u32>,
    stack: Vec<u32>,
    cost: Vec<f64>,
}

impl Irc {
    fn pre(&self, n: u32) -> bool {
        n < 32
    }
    fn add_edge(&mut self, u: u32, v: u32) {
        if u == v {
            return;
        }
        let key = ((u.min(v) as u64) << 32) | u.max(v) as u64;
        if self.adj_set.insert(key) {
            if !self.pre(u) {
                self.adj[u as usize].push(v);
                self.degree[u as usize] += 1;
            }
            if !self.pre(v) {
                self.adj[v as usize].push(u);
                self.degree[v as usize] += 1;
            }
        }
    }
    fn has_edge(&self, u: u32, v: u32) -> bool {
        let key = ((u.min(v) as u64) << 32) | u.max(v) as u64;
        self.adj_set.contains(&key)
    }
    fn adjacent(&self, n: u32) -> Vec<u32> {
        self.adj[n as usize].iter().copied().filter(|&m| !matches!(self.state[m as usize], NS::Stack | NS::Coalesced)).collect()
    }
    fn node_moves(&self, n: u32) -> Vec<u32> {
        self.move_list[n as usize].iter().copied().filter(|&m| matches!(self.mstate[m as usize], MS::Active | MS::Worklist)).collect()
    }
    fn move_related(&self, n: u32) -> bool {
        self.move_list[n as usize].iter().any(|&m| matches!(self.mstate[m as usize], MS::Active | MS::Worklist))
    }
    fn get_alias(&self, mut n: u32) -> u32 {
        while self.state[n as usize] == NS::Coalesced {
            n = self.alias[n as usize];
        }
        n
    }
    fn enable_moves(&mut self, n: u32) {
        for m in self.node_moves(n) {
            if self.mstate[m as usize] == MS::Active {
                self.mstate[m as usize] = MS::Worklist;
                self.move_wl.push(m);
            }
        }
    }
    fn decrement_degree(&mut self, m: u32) {
        if self.pre(m) {
            return;
        }
        let d = self.degree[m as usize];
        self.degree[m as usize] = d.saturating_sub(1);
        if d as usize == self.k {
            self.enable_moves(m);
            for a in self.adjacent(m) {
                self.enable_moves(a);
            }
            if self.state[m as usize] == NS::Spill {
                if self.move_related(m) {
                    self.state[m as usize] = NS::Freeze;
                    self.freeze_wl.push(m);
                } else {
                    self.state[m as usize] = NS::Simplify;
                    self.simplify_wl.push(m);
                }
            }
        }
    }
    fn simplify(&mut self, n: u32) {
        self.state[n as usize] = NS::Stack;
        self.stack.push(n);
        for m in self.adjacent(n) {
            self.decrement_degree(m);
        }
    }
    fn add_worklist(&mut self, u: u32) {
        if !self.pre(u) && self.state[u as usize] == NS::Freeze && !self.move_related(u) && (self.degree[u as usize] as usize) < self.k {
            self.state[u as usize] = NS::Simplify;
            self.simplify_wl.push(u);
        }
    }
    fn ok(&self, t: u32, r: u32) -> bool {
        self.pre(t) || (self.degree[t as usize] as usize) < self.k || self.has_edge(t, r)
    }
    fn conservative(&self, u: u32, v: u32) -> bool {
        let mut seen: HashSet<u32> = HashSet::new();
        let mut k = 0;
        for n in self.adjacent(u).into_iter().chain(self.adjacent(v)) {
            if seen.insert(n) && (self.pre(n) || self.degree[n as usize] as usize >= self.k) {
                k += 1;
            }
        }
        k < self.k
    }
    fn combine(&mut self, u: u32, v: u32) {
        // v is merged into u
        self.state[v as usize] = NS::Coalesced;
        self.alias[v as usize] = u;
        let ml = self.move_list[v as usize].clone();
        if !self.pre(u) {
            for m in ml {
                if !self.move_list[u as usize].contains(&m) {
                    self.move_list[u as usize].push(m);
                }
            }
            self.cost[u as usize] += self.cost[v as usize];
        }
        self.enable_moves(v);
        let adj_v: Vec<u32> = self.adj[v as usize].iter().copied().filter(|&m| !matches!(self.state[m as usize], NS::Stack | NS::Coalesced)).collect();
        for t in adj_v {
            self.add_edge(t, u);
            self.decrement_degree(t);
        }
        if !self.pre(u) && self.degree[u as usize] as usize >= self.k && self.state[u as usize] == NS::Freeze {
            self.state[u as usize] = NS::Spill;
            self.spill_wl.push(u);
        }
    }
    fn coalesce(&mut self, m: u32) {
        let (d, s) = self.moves[m as usize];
        let x = self.get_alias(d);
        let y = self.get_alias(s);
        let (u, v) = if self.pre(y) { (y, x) } else { (x, y) };
        if u == v {
            self.mstate[m as usize] = MS::Coalesced;
            self.add_worklist(u);
        } else if self.pre(v) || self.has_edge(u, v) {
            self.mstate[m as usize] = MS::Constrained;
            self.add_worklist(u);
            self.add_worklist(v);
        } else {
            let can = if self.pre(u) { self.adjacent(v).iter().all(|&t| self.ok(t, u)) } else { self.conservative(u, v) };
            if can {
                self.mstate[m as usize] = MS::Coalesced;
                self.combine(u, v);
                self.add_worklist(u);
            } else {
                self.mstate[m as usize] = MS::Active;
            }
        }
    }
    fn freeze_moves(&mut self, u: u32) {
        for m in self.node_moves(u) {
            let (x, y) = self.moves[m as usize];
            let v = if self.get_alias(y) == self.get_alias(u) { self.get_alias(x) } else { self.get_alias(y) };
            self.mstate[m as usize] = MS::Frozen;
            if !self.pre(v) && self.state[v as usize] == NS::Freeze && !self.move_related(v) && (self.degree[v as usize] as usize) < self.k {
                self.state[v as usize] = NS::Simplify;
                self.simplify_wl.push(v);
            }
        }
    }
    fn run(&mut self) {
        loop {
            if let Some(n) = self.simplify_wl.pop() {
                if self.state[n as usize] == NS::Simplify {
                    self.simplify(n);
                }
            } else if let Some(m) = self.move_wl.pop() {
                if self.mstate[m as usize] == MS::Worklist {
                    self.coalesce(m);
                }
            } else if let Some(u) = self.freeze_wl.pop() {
                if self.state[u as usize] == NS::Freeze {
                    self.state[u as usize] = NS::Simplify;
                    self.simplify_wl.push(u);
                    self.freeze_moves(u);
                }
            } else {
                // select a spill candidate: lowest cost / degree
                let mut best: Option<(usize, f64)> = None;
                for (i, &n) in self.spill_wl.iter().enumerate() {
                    if self.state[n as usize] != NS::Spill {
                        continue;
                    }
                    let c = self.cost[n as usize] / (self.degree[n as usize].max(1) as f64);
                    if best.map(|b| c < b.1).unwrap_or(true) {
                        best = Some((i, c));
                    }
                }
                match best {
                    Some((i, _)) => {
                        let n = self.spill_wl.swap_remove(i);
                        self.state[n as usize] = NS::Simplify;
                        self.simplify_wl.push(n);
                        self.freeze_moves(n);
                    }
                    None => break,
                }
            }
        }
    }
}

pub struct Alloc {
    pub used_callee_saved: Vec<Reg>,
}

fn spill_slot(o: &Opnd, first_spill: u32) -> Option<u32> {
    match o {
        Opnd::M(m) if m.kind == MemKind::Slot && m.id >= first_spill && m.base == NOREG && m.idx == NOREG && m.disp == 0 => Some(m.id),
        _ => None,
    }
}

// After allocation: reuse registers that still hold the value of a spill slot instead of
// reloading it, and drop stores to slots that are never read.
fn spill_forward(mf: &mut MFunc, order: &[u32], first_spill: u32) {
    let nb = mf.blocks.len();
    let mut npreds = vec![0u32; nb];
    let mut the_pred = vec![u32::MAX; nb];
    for &b in order {
        for &s in &mf.blocks[b as usize].succs {
            npreds[s as usize] += 1;
            the_pred[s as usize] = b;
        }
    }
    let mut out_state: Vec<Option<Vec<(u32, Reg)>>> = vec![None; nb];
    let mut defs = Vec::new();
    let mut uses = Vec::new();
    for (oi, &b) in order.iter().enumerate() {
        let mut st: Vec<(u32, Reg)> = Vec::new();
        if oi != 0 && npreds[b as usize] == 1 {
            if let Some(s) = &out_state[the_pred[b as usize] as usize] {
                st = s.clone();
            }
        }
        let insts = std::mem::take(&mut mf.blocks[b as usize].insts);
        let mut out: Vec<MInst> = Vec::with_capacity(insts.len());
        for mut i in insts {
            let is_store = matches!(i.op, MOp::Mov | MOp::MovSd) && spill_slot(&i.a, first_spill).is_some();
            // uses of a slot whose value is still in a register
            if let Some(s) = spill_slot(&i.b, first_spill) {
                if let Some(&(_, r)) = st.iter().find(|e| e.0 == s) {
                    let full_reload = ((i.op == MOp::Mov && i.sz == 8) || i.op == MOp::MovSd) && matches!(i.a, Opnd::R(_));
                    if full_reload && i.a == Opnd::R(r) {
                        continue;
                    }
                    i.b = Opnd::R(r);
                }
            }
            if matches!(i.op, MOp::Cmp | MOp::Test) {
                if let Some(s) = spill_slot(&i.a, first_spill) {
                    if let Some(&(_, r)) = st.iter().find(|e| e.0 == s) {
                        i.a = Opnd::R(r);
                    }
                }
            }
            defs_uses(&i, &mut defs, &mut uses);
            for &d in &defs {
                st.retain(|e| e.1 != d);
            }
            if is_store {
                let s = spill_slot(&i.a, first_spill).unwrap();
                st.retain(|e| e.0 != s);
                if let Opnd::R(r) = i.b {
                    st.push((s, r));
                }
            } else if let (Some(s), Opnd::R(d)) = (spill_slot(&i.b, first_spill), i.a) {
                if ((i.op == MOp::Mov && i.sz == 8) || i.op == MOp::MovSd) && !st.iter().any(|e| e.0 == s) {
                    st.push((s, d));
                }
            } else if let Some((d, src)) = i.is_copy() {
                // a register copy of a slot value is another home for it
                if let Some(&(s, _)) = st.iter().find(|e| e.1 == src) {
                    st.push((s, d));
                }
            }
            out.push(i);
        }
        mf.blocks[b as usize].insts = out;
        out_state[b as usize] = Some(st);
    }
    // remove stores to slots that are never read
    let mut reads = vec![0u32; mf.slots.len()];
    for &b in order {
        for i in &mf.blocks[b as usize].insts {
            let is_store = matches!(i.op, MOp::Mov | MOp::MovSd) && spill_slot(&i.a, first_spill).is_some();
            for (k, o) in [&i.a, &i.b, &i.c].iter().enumerate() {
                if let Opnd::M(m) = o {
                    if m.kind == MemKind::Slot && m.id >= first_spill && !(k == 0 && is_store) {
                        reads[m.id as usize] += 1;
                    }
                }
            }
        }
    }
    for &b in order {
        mf.blocks[b as usize].insts.retain(|i| {
            let is_store = matches!(i.op, MOp::Mov | MOp::MovSd);
            match (is_store, spill_slot(&i.a, first_spill)) {
                (true, Some(s)) => reads[s as usize] > 0,
                _ => true,
            }
        });
    }
}

// spill weight helper
fn depth_weight(d: u32) -> f64 {
    10f64.powi(d.min(6) as i32)
}

pub fn allocate(mf: &mut MFunc, order: &[u32]) -> Alloc {
    let first_spill = mf.slots.len() as u32;
    let mut unspillable: Vec<bool> = vec![false; mf.vclass.len()];
    let mut round = 0;
    loop {
        round += 1;
        let live_out = liveness(mf, order);
        let n = 32 + mf.vclass.len();
        unspillable.resize(mf.vclass.len(), false);
        let mut spilled: Vec<u32> = Vec::new();
        let mut colors: Vec<u32> = vec![u32::MAX; n];
        for class in 0..2u8 {
            let k = if class == 0 { 15 } else { 16 };
            let mut g = Irc {
                k,
                n,
                state: vec![NS::Other; n],
                adj_set: HashSet::new(),
                adj: vec![Vec::new(); n],
                degree: vec![0; n],
                moves: Vec::new(),
                mstate: Vec::new(),
                move_list: vec![Vec::new(); n],
                alias: vec![0; n],
                color: vec![u32::MAX; n],
                simplify_wl: Vec::new(),
                freeze_wl: Vec::new(),
                spill_wl: Vec::new(),
                move_wl: Vec::new(),
                stack: Vec::new(),
                cost: vec![0.0; n],
            };
            let in_class = |r: Reg, mf: &MFunc| -> bool { mf.class(r) == class };
            for r in 0..32u32 {
                if in_class(r, mf) {
                    g.state[r as usize] = NS::Pre;
                    g.color[r as usize] = r;
                    g.degree[r as usize] = u32::MAX / 2;
                }
            }
            for v in 0..mf.vclass.len() {
                if mf.vclass[v] == class {
                    g.state[32 + v] = NS::Initial;
                }
            }
            // build
            let mut defs = Vec::new();
            let mut uses = Vec::new();
            for &b in order {
                let blk = &mf.blocks[b as usize];
                let w = depth_weight(blk.depth);
                let mut live = BitSet { w: live_out[b as usize].w.clone() };
                for i in blk.insts.iter().rev() {
                    defs_uses(i, &mut defs, &mut uses);
                    for &r in defs.iter().chain(uses.iter()) {
                        if r >= 32 && in_class(r, mf) {
                            g.cost[r as usize] += w;
                        }
                    }
                    if let Some((d, s)) = i.is_copy() {
                        if in_class(d, mf) && in_class(s, mf) && d != s && d != RSP && s != RSP {
                            live.clear(s);
                            let mi = g.moves.len() as u32;
                            g.moves.push((d, s));
                            g.mstate.push(MS::Worklist);
                            g.move_list[d as usize].push(mi);
                            g.move_list[s as usize].push(mi);
                            g.move_wl.push(mi);
                        }
                    }
                    for &d in &defs {
                        if !in_class(d, mf) {
                            continue;
                        }
                        for l in live.iter() {
                            if l != d && in_class(l, mf) && !(l < 32 && d < 32) {
                                g.add_edge(l, d);
                            }
                        }
                    }
                    // simultaneous defs interfere with each other
                    if defs.len() > 1 {
                        for x in 0..defs.len() {
                            if defs[x] < 32 || !in_class(defs[x], mf) {
                                continue;
                            }
                            for y in 0..defs.len() {
                                if x != y && in_class(defs[y], mf) {
                                    g.add_edge(defs[x], defs[y]);
                                }
                            }
                        }
                    }
                    for &d in &defs {
                        live.clear(d);
                    }
                    for &u in &uses {
                        live.set(u);
                    }
                }
            }
            for v in 0..mf.vclass.len() {
                if unspillable[v] {
                    g.cost[32 + v] = 1e30;
                }
            }
            // make worklists
            for v in 32..n as u32 {
                if g.state[v as usize] != NS::Initial {
                    continue;
                }
                if g.degree[v as usize] as usize >= k {
                    g.state[v as usize] = NS::Spill;
                    g.spill_wl.push(v);
                } else if g.move_related(v) {
                    g.state[v as usize] = NS::Freeze;
                    g.freeze_wl.push(v);
                } else {
                    g.state[v as usize] = NS::Simplify;
                    g.simplify_wl.push(v);
                }
            }
            g.run();
            // assign colors
            let all: Vec<Reg> = if class == 0 { GPR_ORDER.to_vec() } else { (16..32).collect() };
            while let Some(nd) = g.stack.pop() {
                let mut avail = [true; 32];
                for &w in &g.adj[nd as usize] {
                    let a = g.get_alias(w);
                    if matches!(g.state[a as usize], NS::Colored | NS::Pre) {
                        avail[g.color[a as usize] as usize] = false;
                    }
                }
                // biased coloring: prefer the color of a move partner
                let mut pick = u32::MAX;
                for &m in &g.move_list[nd as usize] {
                    let (x, y) = g.moves[m as usize];
                    let o = if g.get_alias(x) == nd { g.get_alias(y) } else { g.get_alias(x) };
                    if matches!(g.state[o as usize], NS::Colored | NS::Pre) {
                        let c = g.color[o as usize];
                        if c != u32::MAX && c != RSP && avail[c as usize] && all.contains(&c) {
                            pick = c;
                            break;
                        }
                    }
                }
                if pick == u32::MAX {
                    for &c in &all {
                        if avail[c as usize] {
                            pick = c;
                            break;
                        }
                    }
                }
                if pick == u32::MAX {
                    g.state[nd as usize] = NS::Spilled;
                    spilled.push(nd);
                } else {
                    g.state[nd as usize] = NS::Colored;
                    g.color[nd as usize] = pick;
                }
            }
            for v in 32..n as u32 {
                if g.state[v as usize] == NS::Coalesced {
                    let a = g.get_alias(v);
                    if g.state[a as usize] == NS::Spilled {
                        spilled.push(v);
                    } else {
                        colors[v as usize] = g.color[a as usize];
                    }
                } else if g.state[v as usize] == NS::Colored {
                    colors[v as usize] = g.color[v as usize];
                }
            }
            let _ = g.n;
        }
        if spilled.is_empty() {
            // rewrite to physical registers
            let mut used = [false; 32];
            for &b in order {
                let insts = std::mem::take(&mut mf.blocks[b as usize].insts);
                let mut out = Vec::with_capacity(insts.len());
                for mut i in insts {
                    map_regs(&mut i, &mut |r| if r >= 32 { colors[r as usize] } else { r });
                    for r in i.uses.iter_mut().chain(i.defs.iter_mut()) {
                        if *r >= 32 {
                            *r = colors[*r as usize];
                        }
                    }
                    if let Some((d, s)) = i.is_copy() {
                        if d == s {
                            continue;
                        }
                    }
                    let mut defs = Vec::new();
                    let mut uses = Vec::new();
                    defs_uses(&i, &mut defs, &mut uses);
                    if !matches!(i.op, MOp::Call | MOp::CallInd) {
                        for d in defs {
                            if d < 32 {
                                used[d as usize] = true;
                            }
                        }
                    }
                    out.push(i);
                }
                mf.blocks[b as usize].insts = out;
            }
            let used_callee_saved: Vec<Reg> = (0..16).filter(|&r| used[r as usize] && callee_saved(r)).collect();
            if mf.slots.len() as u32 > first_spill {
                spill_forward(mf, order, first_spill);
            }
            return Alloc { used_callee_saved };
        }
        if round > 40 {
            panic!("register allocation did not converge in `{}`", mf.name);
        }
        spill(mf, order, &spilled, &mut unspillable);
    }
}

// can operand `b` of this instruction be a memory operand?
fn b_can_be_mem(i: &MInst) -> bool {
    use MOp::*;
    if matches!(i.a, Opnd::M(_)) {
        return false;
    }
    match i.op {
        Add | Sub | And | Or | Xor | Cmp | Imul | Addsd | Subsd | Mulsd | Divsd | Sqrtsd | Ucomisd | Cvtsi2sd | Cvttsd2si | Cmov | Imul3 => true,
        Mov => i.sz == 8 || i.sz == 4,
        MovSd => true,
        Movzx | Movsx => true,
        _ => false,
    }
}

fn spill(mf: &mut MFunc, order: &[u32], spilled: &[u32], unspillable: &mut Vec<bool>) {
    let mut slot_of: std::collections::HashMap<u32, u32> = std::collections::HashMap::new();
    for &v in spilled {
        let s = mf.new_slot(8, 8);
        slot_of.insert(v, s);
    }
    let mut defs = Vec::new();
    let mut uses = Vec::new();
    for &b in order {
        let insts = std::mem::take(&mut mf.blocks[b as usize].insts);
        let mut out: Vec<MInst> = Vec::with_capacity(insts.len() + 8);
        for mut i in insts {
            defs_uses(&i, &mut defs, &mut uses);
            let touched: Vec<u32> = {
                let mut t: Vec<u32> = defs.iter().chain(uses.iter()).copied().filter(|r| slot_of.contains_key(r)).collect();
                t.sort();
                t.dedup();
                t
            };
            if touched.is_empty() {
                out.push(i);
                continue;
            }
            let mut after: Vec<MInst> = Vec::new();
            for v in touched {
                let slot = slot_of[&v];
                let cls = mf.class(v);
                let mem = Opnd::M(Mem::slot(slot, 0));
                let mv = if cls == 1 { MOp::MovSd } else { MOp::Mov };
                let is_def = defs.contains(&v);
                let is_use = uses.contains(&v);
                // direct forms that avoid a temporary
                if let Some((d, s)) = i.is_copy() {
                    if s == v && d != v && !slot_of.contains_key(&d) {
                        i.b = mem;
                        continue;
                    }
                    if d == v && s != v && !slot_of.contains_key(&s) {
                        i.a = mem;
                        continue;
                    }
                }
                if is_use && !is_def && i.b == Opnd::R(v) && b_can_be_mem(&i) {
                    // the only occurrence must be operand b
                    let mut cnt = 0;
                    let mut probe = i.clone();
                    map_regs(&mut probe, &mut |r| {
                        if r == v {
                            cnt += 1;
                        }
                        r
                    });
                    if cnt == 1 && !i.uses.contains(&v) {
                        i.b = mem;
                        continue;
                    }
                }
                if i.op == MOp::Mov && i.sz == 8 && i.a == Opnd::R(v) && is_def && !is_use {
                    if let Opnd::I(k) = i.b {
                        if k >= i32::MIN as i64 && k <= i32::MAX as i64 {
                            i.a = mem;
                            continue;
                        }
                    }
                }
                let t = mf.new_vreg(cls);
                unspillable.resize(mf.vclass.len(), false);
                unspillable[(t - VREG0) as usize] = true;
                map_regs(&mut i, &mut |r| if r == v { t } else { r });
                for r in i.uses.iter_mut().chain(i.defs.iter_mut()) {
                    if *r == v {
                        *r = t;
                    }
                }
                if is_use {
                    out.push(MInst::new(mv, 8, Opnd::R(t), mem));
                }
                if is_def {
                    after.push(MInst::new(mv, 8, mem, Opnd::R(t)));
                }
            }
            out.push(i);
            out.extend(after);
        }
        mf.blocks[b as usize].insts = out;
    }
}
