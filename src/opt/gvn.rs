// Dominator-scoped global value numbering for pure instructions, plus propagation of
// branch conditions into dominated blocks (removes repeated checks).
use crate::ir::*;
use std::collections::HashMap;

type Key = (Op, T, Vec<V>, i64);

fn numberable(op: Op) -> bool {
    op.is_pure() || matches!(op, Op::SDiv | Op::UDiv | Op::SRem | Op::URem | Op::Proj)
}

pub fn run(f: &mut Func) -> bool {
    let cfg = Cfg::new(f);
    let mut repl: Vec<V> = vec![NOV; f.insts.len()];
    let mut table: HashMap<Key, V> = HashMap::new();
    let mut known: HashMap<V, bool> = HashMap::new();
    let mut changed = false;
    fn find(repl: &[V], mut v: V) -> V {
        while repl[v as usize] != NOV {
            v = repl[v as usize];
        }
        v
    }
    enum Step {
        Enter(B),
        Exit(Vec<Key>, Vec<(V, Option<bool>)>),
    }
    let mut stack = vec![Step::Enter(0)];
    while let Some(step) = stack.pop() {
        match step {
            Step::Exit(keys, facts) => {
                for k in keys {
                    table.remove(&k);
                }
                for (c, old) in facts.into_iter().rev() {
                    match old {
                        Some(o) => {
                            known.insert(c, o);
                        }
                        None => {
                            known.remove(&c);
                        }
                    }
                }
            }
            Step::Enter(b) => {
                let mut added: Vec<Key> = Vec::new();
                let mut facts: Vec<(V, Option<bool>)> = Vec::new();
                // a block reached only through one arm of a conditional branch knows the condition
                if cfg.preds[b as usize].len() == 1 {
                    let p = cfg.preds[b as usize][0];
                    if let Term::Br(c, t, e) = f.blocks[p as usize].term {
                        if t != e {
                            let c = find(&repl, c);
                            let val = t == b;
                            facts.push((c, known.insert(c, val)));
                            // an equivalent negated compare is also decided
                        }
                    }
                }
                let old = std::mem::take(&mut f.blocks[b as usize].insts);
                let mut new = Vec::with_capacity(old.len());
                for v in old {
                    for ai in 0..f.insts[v as usize].args.len() {
                        let a = f.insts[v as usize].args[ai];
                        let mut r = find(&repl, a);
                        // a condition decided by a dominating branch is a constant here
                        if let Some(&val) = known.get(&r) {
                            if f.insts[r as usize].op != Op::Const {
                                let c = f.mk(Op::Const, T::I8, vec![], val as i64);
                                repl.push(NOV);
                                new.push(c);
                                r = c;
                                changed = true;
                            }
                        }
                        if r != a {
                            f.insts[v as usize].args[ai] = r;
                        }
                    }
                    let i = &f.insts[v as usize];
                    if !numberable(i.op) {
                        new.push(v);
                        continue;
                    }
                    let mut args = i.args.clone();
                    if i.op.is_commutative() && args.len() == 2 && args[0] > args[1] {
                        args.swap(0, 1);
                    }
                    let key: Key = (i.op, i.ty, args, i.k);
                    match table.get(&key) {
                        Some(&w) => {
                            repl[v as usize] = w;
                            changed = true;
                        }
                        None => {
                            table.insert(key.clone(), v);
                            added.push(key);
                            new.push(v);
                        }
                    }
                }
                f.blocks[b as usize].insts = new;
                if let Term::Br(c, t, e) = f.blocks[b as usize].term {
                    let c = find(&repl, c);
                    if let Some(&val) = known.get(&c) {
                        f.blocks[b as usize].term = Term::Jmp(if val { t } else { e });
                        changed = true;
                    }
                }
                stack.push(Step::Exit(added, facts));
                for &c in cfg.children[b as usize].iter().rev() {
                    stack.push(Step::Enter(c));
                }
            }
        }
    }
    if changed {
        f.apply_repl(&mut repl);
        crate::opt::cleanup::prune_unreachable(f);
    }
    changed
}
