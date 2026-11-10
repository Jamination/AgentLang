// Function inlining.
use crate::ir::*;
use std::collections::HashMap;

pub fn cost(f: &Func) -> usize {
    let mut n = 0;
    for b in &f.blocks {
        for &v in &b.insts {
            if !matches!(f.insts[v as usize].op, Op::Const | Op::FConst | Op::Param | Op::GAddr | Op::FAddr | Op::Alloca | Op::Phi | Op::Proj) {
                n += 1;
            }
        }
        if b.term != Term::None {
            n += 1;
        }
    }
    n
}

// inline one call site: `call` (in block `cb`) to callee `g`
pub fn inline_call(f: &mut Func, cb: B, call: V, g: &Func) {
    let pos = f.blocks[cb as usize].insts.iter().position(|v| *v == call).unwrap();
    let call_inst = f.insts[call as usize].clone();
    // split the block
    let cont = f.new_block();
    let tail: Vec<V> = f.blocks[cb as usize].insts.split_off(pos + 1);
    f.blocks[cb as usize].insts.pop();
    f.blocks[cont as usize].insts = tail;
    let old_term = std::mem::replace(&mut f.blocks[cb as usize].term, Term::None);
    f.blocks[cont as usize].term = old_term;
    for s in f.succs(cont) {
        for ii in 0..f.blocks[s as usize].insts.len() {
            let v = f.blocks[s as usize].insts[ii];
            if f.insts[v as usize].op != Op::Phi {
                break;
            }
            for p in f.insts[v as usize].pb.iter_mut() {
                if *p == cb {
                    *p = cont;
                }
            }
        }
    }
    // clone callee
    let grpo = g.rpo();
    let mut bmap: HashMap<B, B> = HashMap::new();
    for &gb in &grpo {
        bmap.insert(gb, f.new_block());
    }
    let mut vmap: Vec<V> = vec![NOV; g.insts.len()];
    for &gb in &grpo {
        for &gv in &g.blocks[gb as usize].insts {
            let gi = &g.insts[gv as usize];
            if gi.op == Op::Param {
                vmap[gv as usize] = call_inst.args[gi.k as usize];
                continue;
            }
            let nv = f.mk(gi.op, gi.ty, Vec::new(), gi.k);
            f.im(nv).aux = gi.aux;
            vmap[gv as usize] = nv;
        }
    }
    let mut rets: Vec<(B, Vec<V>)> = Vec::new();
    let mut allocas: Vec<V> = Vec::new();
    for &gb in &grpo {
        let nb = bmap[&gb];
        for &gv in &g.blocks[gb as usize].insts {
            let gi = &g.insts[gv as usize];
            if gi.op == Op::Param {
                continue;
            }
            let nv = vmap[gv as usize];
            let args: Vec<V> = gi.args.iter().map(|a| vmap[*a as usize]).collect();
            let pb: Vec<B> = gi.pb.iter().map(|p| bmap.get(p).copied().unwrap_or(u32::MAX)).collect();
            // drop phi inputs from blocks that were unreachable in the callee
            if gi.op == Op::Phi && pb.contains(&u32::MAX) {
                let mut a2 = Vec::new();
                let mut p2 = Vec::new();
                for (k, p) in pb.iter().enumerate() {
                    if *p != u32::MAX {
                        a2.push(args[k]);
                        p2.push(*p);
                    }
                }
                f.im(nv).args = a2;
                f.im(nv).pb = p2;
            } else {
                f.im(nv).args = args;
                f.im(nv).pb = pb;
            }
            if gi.op == Op::Alloca {
                allocas.push(nv);
            } else {
                f.blocks[nb as usize].insts.push(nv);
            }
        }
        f.blocks[nb as usize].term = match &g.blocks[gb as usize].term {
            Term::Jmp(t) => Term::Jmp(bmap[t]),
            Term::Br(c, t, e) => Term::Br(vmap[*c as usize], bmap[t], bmap[e]),
            Term::Ret(vs) => {
                rets.push((nb, vs.iter().map(|v| vmap[*v as usize]).collect()));
                Term::Jmp(cont)
            }
            Term::Trap => Term::Trap,
            Term::None => Term::Trap,
        };
    }
    // allocas live in the caller's entry block
    if !allocas.is_empty() {
        let mut e = allocas;
        e.extend(f.blocks[0].insts.iter().copied());
        f.blocks[0].insts = e;
    }
    f.blocks[cb as usize].term = Term::Jmp(bmap[&0]);
    // results
    let nrets = g.rets.len();
    let mut results: Vec<V> = Vec::new();
    for k in 0..nrets {
        if rets.is_empty() {
            // callee never returns: any value will do
            let z = if g.rets[k].is_fp() { f.mk(Op::FConst, g.rets[k], vec![], 0) } else { f.mk(Op::Const, g.rets[k], vec![], 0) };
            f.blocks[0].insts.insert(0, z);
            results.push(z);
        } else if rets.len() == 1 {
            results.push(rets[0].1[k]);
        } else {
            let phi = f.mk(Op::Phi, g.rets[k], rets.iter().map(|r| r.1[k]).collect(), 0);
            f.im(phi).pb = rets.iter().map(|r| r.0).collect();
            f.blocks[cont as usize].insts.insert(k, phi);
            results.push(phi);
        }
    }
    let mut repl: Vec<V> = vec![NOV; f.insts.len()];
    if nrets == 1 {
        repl[call as usize] = results[0];
    } else if nrets > 1 {
        // projections of the call
        for b in 0..f.blocks.len() {
            for ii in 0..f.blocks[b].insts.len() {
                let v = f.blocks[b].insts[ii];
                let i = &f.insts[v as usize];
                if i.op == Op::Proj && i.args[0] == call {
                    repl[v as usize] = results[i.k as usize];
                }
            }
        }
        for b in f.blocks.iter_mut() {
            b.insts.retain(|v| repl[*v as usize] == NOV);
        }
    }
    f.apply_repl(&mut repl);
}

pub struct Policy {
    pub small: usize,
    pub hinted: usize,
    pub single_site: usize,
    pub max_caller: usize,
}

// inline eligible calls in function `fid`; `done[g]` marks callees that are final
pub fn run(m: &mut Module, fid: u32, done: &[bool], call_counts: &[u32], addr_taken: &[bool], pol: &Policy) -> bool {
    let mut any = false;
    let mut budget = 400;
    let mut sizes: HashMap<u32, usize> = HashMap::new();
    loop {
        if budget == 0 {
            break;
        }
        let caller_size = cost(&m.funcs[fid as usize]);
        if caller_size > pol.max_caller {
            break;
        }
        // find the next inlinable call
        let mut found: Option<(B, V, u32)> = None;
        {
            let f = &m.funcs[fid as usize];
            'outer: for b in f.rpo() {
                for &v in &f.blocks[b as usize].insts {
                    let i = &f.insts[v as usize];
                    if i.op != Op::Call {
                        continue;
                    }
                    let g = i.k as u32;
                    if g == fid || !done[g as usize] {
                        continue;
                    }
                    let gf = &m.funcs[g as usize];
                    if gf.inline < 0 || gf.noreturn || !gf.lowered {
                        continue;
                    }
                    let size = *sizes.entry(g).or_insert_with(|| cost(gf));
                    let limit = if gf.inline > 0 {
                        pol.hinted
                    } else if call_counts[g as usize] == 1 && !addr_taken[g as usize] {
                        pol.single_site
                    } else {
                        pol.small
                    };
                    if size <= limit {
                        found = Some((b, v, g));
                        break 'outer;
                    }
                }
            }
        }
        match found {
            Some((b, v, g)) => {
                let gf = m.funcs[g as usize].clone();
                inline_call(&mut m.funcs[fid as usize], b, v, &gf);
                any = true;
                budget -= 1;
            }
            None => break,
        }
    }
    any
}
