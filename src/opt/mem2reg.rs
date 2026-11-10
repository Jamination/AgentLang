// Promote non-escaping stack slots to SSA values (with scalar replacement of aggregates).
use crate::ir::*;
use std::collections::HashMap;

struct Ctx<'a> {
    f: &'a mut Func,
    cfg: &'a Cfg,
    var_ty: Vec<T>,
    last_store: HashMap<(u32, B), V>,
    def_in: HashMap<(u32, B), V>,
    new_phis: Vec<(B, V)>,
    entry_consts: Vec<V>,
    zero: HashMap<T, V>,
}

impl<'a> Ctx<'a> {
    fn zero_of(&mut self, t: T) -> V {
        if let Some(&z) = self.zero.get(&t) {
            return z;
        }
        let z = if t.is_fp() { self.f.mk(Op::FConst, t, vec![], 0) } else { self.f.mk(Op::Const, t, vec![], 0) };
        self.entry_consts.push(z);
        self.zero.insert(t, z);
        z
    }
    fn read_out(&mut self, var: u32, b: B) -> V {
        if let Some(&v) = self.last_store.get(&(var, b)) {
            return v;
        }
        self.read_in(var, b)
    }
    fn read_in(&mut self, var: u32, b: B) -> V {
        if let Some(&v) = self.def_in.get(&(var, b)) {
            return v;
        }
        let np = self.cfg.preds[b as usize].len();
        let v = if np == 0 {
            self.zero_of(self.var_ty[var as usize])
        } else if np == 1 {
            let p = self.cfg.preds[b as usize][0];
            // guard against a self-loop of a single block
            if p == b {
                self.zero_of(self.var_ty[var as usize])
            } else {
                self.read_out(var, p)
            }
        } else {
            let phi = self.f.mk(Op::Phi, self.var_ty[var as usize], vec![], 0);
            self.def_in.insert((var, b), phi);
            self.new_phis.push((b, phi));
            let preds = self.cfg.preds[b as usize].clone();
            for p in preds {
                let a = self.read_out(var, p);
                let inst = self.f.im(phi);
                inst.args.push(a);
                inst.pb.push(p);
            }
            phi
        };
        self.def_in.insert((var, b), v);
        v
    }
}

pub fn run(f: &mut Func) -> bool {
    let mut any = false;
    for _ in 0..8 {
        if !run_once(f) {
            break;
        }
        any = true;
    }
    any
}

fn run_once(f: &mut Func) -> bool {
    let cfg = Cfg::new(f);
    let n = f.insts.len();
    // users of each value (instruction users only) + escape through terminators
    let mut users: Vec<Vec<V>> = vec![Vec::new(); n];
    let mut term_used = vec![false; n];
    for &b in &cfg.rpo {
        for &v in &f.blocks[b as usize].insts {
            for &a in &f.insts[v as usize].args {
                users[a as usize].push(v);
            }
        }
        for u in f.term_uses(b) {
            term_used[u as usize] = true;
        }
    }
    // access: inst -> var
    let mut access: HashMap<V, u32> = HashMap::new();
    let mut var_ty: Vec<T> = Vec::new();
    let allocas: Vec<V> = f.blocks[0].insts.iter().copied().filter(|v| f.insts[*v as usize].op == Op::Alloca).collect();
    for &a in &allocas {
        let mut escaped = term_used[a as usize];
        let mut derived: Vec<(V, i64)> = vec![(a, 0)];
        let mut is_derived: HashMap<V, i64> = HashMap::new();
        is_derived.insert(a, 0);
        let mut accs: Vec<(V, i64, T)> = Vec::new();
        let mut qi = 0;
        while qi < derived.len() && !escaped {
            let (x, off) = derived[qi];
            qi += 1;
            if term_used[x as usize] {
                escaped = true;
                break;
            }
            for &u in &users[x as usize] {
                let inst = &f.insts[u as usize];
                match inst.op {
                    Op::Add => {
                        let other = if inst.args[0] == x { inst.args[1] } else { inst.args[0] };
                        if other == x {
                            escaped = true;
                            break;
                        }
                        match f.is_const(other) {
                            Some(c) => {
                                if is_derived.insert(u, off + c).is_none() {
                                    derived.push((u, off + c));
                                }
                            }
                            None => {
                                escaped = true;
                                break;
                            }
                        }
                    }
                    Op::Load => accs.push((u, off, inst.ty)),
                    Op::Store => {
                        if inst.args[1] == x || inst.args[0] != x {
                            escaped = true;
                            break;
                        }
                        accs.push((u, off, inst.ty));
                    }
                    _ => {
                        escaped = true;
                        break;
                    }
                }
            }
        }
        if escaped {
            continue;
        }
        // stored values must not be derived pointers of this alloca
        if accs.iter().any(|(u, _, _)| f.insts[*u as usize].op == Op::Store && is_derived.contains_key(&f.insts[*u as usize].args[1])) {
            continue;
        }
        // slots: (offset, type); promotable when no partial overlap with a different slot
        let size = f.insts[a as usize].k;
        let mut slots: Vec<(i64, T)> = Vec::new();
        for &(_, off, t) in &accs {
            if !slots.contains(&(off, t)) {
                slots.push((off, t));
            }
        }
        let mut ok: Vec<bool> = vec![true; slots.len()];
        for i in 0..slots.len() {
            let (o1, t1) = slots[i];
            if o1 < 0 || o1 + t1.size() as i64 > size {
                ok[i] = false;
            }
            for j in 0..slots.len() {
                if i == j {
                    continue;
                }
                let (o2, t2) = slots[j];
                if o1 < o2 + t2.size() as i64 && o2 < o1 + t1.size() as i64 {
                    ok[i] = false;
                }
            }
        }
        let mut slot_var: Vec<u32> = vec![u32::MAX; slots.len()];
        for i in 0..slots.len() {
            if ok[i] {
                slot_var[i] = var_ty.len() as u32;
                var_ty.push(slots[i].1);
            }
        }
        for &(u, off, t) in &accs {
            let si = slots.iter().position(|s| *s == (off, t)).unwrap();
            if ok[si] {
                access.insert(u, slot_var[si]);
            }
        }
    }
    if access.is_empty() {
        return false;
    }
    // last store per (var, block)
    let mut last_store: HashMap<(u32, B), V> = HashMap::new();
    for &b in &cfg.rpo {
        for &v in &f.blocks[b as usize].insts {
            if f.insts[v as usize].op == Op::Store {
                if let Some(&var) = access.get(&v) {
                    last_store.insert((var, b), f.insts[v as usize].args[1]);
                }
            }
        }
    }
    let mut repl: Vec<V> = vec![NOV; n];
    let rpo = cfg.rpo.clone();
    let mut cx = Ctx { f, cfg: &cfg, var_ty, last_store, def_in: HashMap::new(), new_phis: Vec::new(), entry_consts: Vec::new(), zero: HashMap::new() };
    for &b in &rpo {
        let insts = cx.f.blocks[b as usize].insts.clone();
        let mut cur: HashMap<u32, V> = HashMap::new();
        let mut keep: Vec<V> = Vec::with_capacity(insts.len());
        for v in insts {
            match access.get(&v) {
                Some(&var) => {
                    if cx.f.insts[v as usize].op == Op::Store {
                        cur.insert(var, cx.f.insts[v as usize].args[1]);
                    } else {
                        let val = match cur.get(&var) {
                            Some(&x) => x,
                            None => {
                                let x = cx.read_in(var, b);
                                cur.insert(var, x);
                                x
                            }
                        };
                        if repl.len() < cx.f.insts.len() {
                            repl.resize(cx.f.insts.len(), NOV);
                        }
                        repl[v as usize] = val;
                    }
                }
                None => keep.push(v),
            }
        }
        cx.f.blocks[b as usize].insts = keep;
    }
    let new_phis = std::mem::take(&mut cx.new_phis);
    let entry_consts = std::mem::take(&mut cx.entry_consts);
    drop(cx);
    // insert phis at block heads, constants at the entry
    let mut by_block: HashMap<B, Vec<V>> = HashMap::new();
    for (b, p) in new_phis {
        by_block.entry(b).or_default().push(p);
    }
    for (b, mut ps) in by_block {
        ps.extend(f.blocks[b as usize].insts.iter().copied());
        f.blocks[b as usize].insts = ps;
    }
    if !entry_consts.is_empty() {
        // after allocas/phis is not required for constants; put them first
        let mut e = entry_consts;
        e.extend(f.blocks[0].insts.iter().copied());
        f.blocks[0].insts = e;
    }
    repl.resize(f.insts.len(), NOV);
    f.apply_repl(&mut repl);
    crate::opt::cleanup::trivial_phis(f);
    crate::opt::cleanup::dce(f);
    true
}
