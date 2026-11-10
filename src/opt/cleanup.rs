// CFG cleanup and dead code elimination.
use crate::ir::*;

// remove phi inputs from non-predecessors, drop unreachable blocks' contents
pub fn prune_unreachable(f: &mut Func) -> bool {
    let rpo = f.rpo();
    let mut reach = vec![false; f.blocks.len()];
    for &b in &rpo {
        reach[b as usize] = true;
    }
    let mut changed = false;
    for b in 0..f.blocks.len() {
        if !reach[b] && (!f.blocks[b].insts.is_empty() || f.blocks[b].term != Term::None) {
            f.blocks[b].insts.clear();
            f.blocks[b].term = Term::None;
            changed = true;
        }
    }
    let preds = f.preds();
    for &b in &rpo {
        for ii in 0..f.blocks[b as usize].insts.len() {
            let v = f.blocks[b as usize].insts[ii];
            if f.insts[v as usize].op != Op::Phi {
                continue;
            }
            let inst = &mut f.insts[v as usize];
            let mut k = 0;
            while k < inst.pb.len() {
                if !preds[b as usize].contains(&inst.pb[k]) {
                    inst.pb.remove(k);
                    inst.args.remove(k);
                    changed = true;
                } else {
                    k += 1;
                }
            }
        }
    }
    changed
}

pub fn is_root(op: Op) -> bool {
    matches!(op, Op::Store | Op::Call | Op::CallInd | Op::Syscall | Op::MemCpy | Op::MemSet)
}

pub fn dce(f: &mut Func) -> bool {
    let n = f.insts.len();
    let mut live = vec![false; n];
    let mut work: Vec<V> = Vec::new();
    for b in &f.blocks {
        for &v in &b.insts {
            if is_root(f.insts[v as usize].op) {
                live[v as usize] = true;
                work.push(v);
            }
        }
        match &b.term {
            Term::Br(c, _, _) => {
                if !live[*c as usize] {
                    live[*c as usize] = true;
                    work.push(*c);
                }
            }
            Term::Ret(vs) => {
                for v in vs {
                    if !live[*v as usize] {
                        live[*v as usize] = true;
                        work.push(*v);
                    }
                }
            }
            _ => {}
        }
    }
    while let Some(v) = work.pop() {
        for ai in 0..f.insts[v as usize].args.len() {
            let a = f.insts[v as usize].args[ai];
            if !live[a as usize] {
                live[a as usize] = true;
                work.push(a);
            }
        }
    }
    let mut changed = false;
    for b in f.blocks.iter_mut() {
        let before = b.insts.len();
        b.insts.retain(|v| live[*v as usize]);
        if b.insts.len() != before {
            changed = true;
        }
    }
    changed
}

// remove phis whose inputs are all the same value
pub fn trivial_phis(f: &mut Func) -> bool {
    let mut repl: Vec<V> = vec![NOV; f.insts.len()];
    fn res(repl: &[V], mut v: V) -> V {
        while repl[v as usize] != NOV {
            v = repl[v as usize];
        }
        v
    }
    let mut any = false;
    loop {
        let mut changed = false;
        for bi in 0..f.blocks.len() {
            for ii in 0..f.blocks[bi].insts.len() {
                let v = f.blocks[bi].insts[ii];
                if f.insts[v as usize].op != Op::Phi || repl[v as usize] != NOV {
                    continue;
                }
                let mut same = NOV;
                let mut trivial = true;
                for &a in &f.insts[v as usize].args {
                    let a = res(&repl, a);
                    if a == v || a == same {
                        continue;
                    }
                    if same != NOV {
                        trivial = false;
                        break;
                    }
                    same = a;
                }
                if trivial && same != NOV {
                    repl[v as usize] = same;
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
        any = true;
    }
    if any {
        for b in f.blocks.iter_mut() {
            b.insts.retain(|v| repl[*v as usize] == NOV);
        }
        f.apply_repl(&mut repl);
    }
    any
}
