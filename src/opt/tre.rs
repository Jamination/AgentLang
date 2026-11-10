// Tail-recursion elimination, including the accumulator form
//     return x + f(args)        (also *, &, |, ^ on integers)
// which becomes a loop that carries the pending operation in an accumulator.
use crate::ir::*;

struct Site {
    block: B,
    call: V,
    // accumulator form: (combining instruction, the other operand)
    acc: Option<(V, V)>,
}

fn identity(op: Op) -> Option<i64> {
    match op {
        Op::Add | Op::Or | Op::Xor => Some(0),
        Op::Mul => Some(1),
        Op::And => Some(-1),
        _ => None,
    }
}

pub fn run(f: &mut Func, fid: u32) -> bool {
    if f.rets.len() > 1 {
        return false;
    }
    // locals whose address is observable would be shared between iterations
    if f.blocks[0].insts.iter().any(|v| f.insts[*v as usize].op == Op::Alloca) {
        return false;
    }
    let uses = f.use_counts();
    let rpo = f.rpo();
    let mut sites: Vec<Site> = Vec::new();
    let mut acc_op: Option<Op> = None;
    for &b in &rpo {
        let rv = match &f.blocks[b as usize].term {
            Term::Ret(vs) => vs.clone(),
            _ => continue,
        };
        let insts = &f.blocks[b as usize].insts;
        if insts.is_empty() {
            continue;
        }
        let n = insts.len();
        let last = insts[n - 1];
        let li = &f.insts[last as usize];
        // plain tail call: [call; ret call] or [call; ret] for no result
        if li.op == Op::Call && li.k as u32 == fid && ((rv.is_empty() && f.rets.is_empty()) || (rv.len() == 1 && rv[0] == last && uses[last as usize] == 1)) {
            sites.push(Site { block: b, call: last, acc: None });
            continue;
        }
        // accumulator form: [call; r = op(x, call); ret r] with the call right before
        if rv.len() == 1 && rv[0] == last && n >= 2 && uses[last as usize] == 1 && li.ty.is_int() {
            if let Some(_) = identity(li.op) {
                let call = insts[n - 2];
                let ci = &f.insts[call as usize];
                if ci.op == Op::Call && ci.k as u32 == fid && uses[call as usize] == 1 && li.args.contains(&call) {
                    let x = if li.args[0] == call { li.args[1] } else { li.args[0] };
                    if x != call && (acc_op.is_none() || acc_op == Some(li.op)) {
                        acc_op = Some(li.op);
                        sites.push(Site { block: b, call, acc: Some((last, x)) });
                    }
                }
            }
        }
    }
    if sites.is_empty() {
        return false;
    }
    // all sites must agree: with an accumulator, plain tail calls are fine too (acc unchanged)
    let ret_ty = f.rets.first().copied().unwrap_or(T::Void);
    // split the entry: parameters stay, the body moves to a loop header
    let header = f.new_block();
    let entry_insts = std::mem::take(&mut f.blocks[0].insts);
    let mut params: Vec<V> = Vec::new();
    let mut keep = Vec::new();
    let mut moved = Vec::new();
    for v in entry_insts {
        match f.insts[v as usize].op {
            Op::Param => {
                params.push(v);
                keep.push(v);
            }
            _ => moved.push(v),
        }
    }
    f.blocks[0].insts = keep;
    let entry_term = std::mem::replace(&mut f.blocks[0].term, Term::Jmp(header));
    f.blocks[header as usize].term = entry_term;
    // successors of the old entry now come from the header
    for s in f.succs(header) {
        for ii in 0..f.blocks[s as usize].insts.len() {
            let v = f.blocks[s as usize].insts[ii];
            if f.insts[v as usize].op != Op::Phi {
                break;
            }
            for p in f.insts[v as usize].pb.iter_mut() {
                if *p == 0 {
                    *p = header;
                }
            }
        }
    }
    // sites located in the old entry block are now in the header
    for s in sites.iter_mut() {
        if s.block == 0 {
            s.block = header;
        }
    }
    // parameter phis (one per declared parameter that has a Param instruction)
    let mut pphi: Vec<(i64, V, V)> = Vec::new(); // (index, param value, phi)
    let mut head: Vec<V> = Vec::new();
    for &p in &params {
        let (ty, k) = (f.insts[p as usize].ty, f.insts[p as usize].k);
        let phi = f.mk(Op::Phi, ty, vec![p], 0);
        f.im(phi).pb = vec![0];
        head.push(phi);
        pphi.push((k, p, phi));
    }
    let acc_phi = match acc_op {
        Some(op) => {
            let idk = identity(op).unwrap();
            let c = f.mk(Op::Const, ret_ty, vec![], canon(ret_ty, idk));
            f.blocks[0].insts.push(c);
            let phi = f.mk(Op::Phi, ret_ty, vec![c], 0);
            f.im(phi).pb = vec![0];
            head.push(phi);
            Some(phi)
        }
        None => None,
    };
    head.extend(moved);
    f.blocks[header as usize].insts = head;
    // uses of parameters become uses of the phis (except in the phis' own entry inputs)
    let mut repl: Vec<V> = vec![NOV; f.insts.len()];
    for &(_, p, phi) in &pphi {
        repl[p as usize] = phi;
    }
    f.apply_repl(&mut repl);
    for &(_, p, phi) in &pphi {
        let i = f.im(phi);
        i.args[0] = p;
    }
    let site_blocks: Vec<B> = sites.iter().map(|s| s.block).collect();
    // rewrite the tail sites
    for s in &sites {
        let b = s.block;
        let call_args = f.insts[s.call as usize].args.clone();
        // new accumulator value
        let new_acc = match (acc_phi, &s.acc) {
            (Some(ap), Some((comb, _))) => {
                // read the operand again: parameters have been replaced by the loop phis
                let ci = &f.insts[*comb as usize];
                let op = ci.op;
                let x = if ci.args[0] == s.call { ci.args[1] } else { ci.args[0] };
                let nv = f.mk(op, ret_ty, vec![ap, x], 0);
                Some(nv)
            }
            (Some(ap), None) => Some(ap),
            _ => None,
        };
        // drop the call (and the combining instruction)
        let drop: Vec<V> = match &s.acc {
            Some((comb, _)) => vec![s.call, *comb],
            None => vec![s.call],
        };
        f.blocks[b as usize].insts.retain(|v| !drop.contains(v));
        if let (Some(nv), Some(_)) = (new_acc, &s.acc) {
            f.blocks[b as usize].insts.push(nv);
        }
        f.blocks[b as usize].term = Term::Jmp(header);
        for &(k, _, phi) in &pphi {
            let a = call_args[k as usize];
            let i = f.im(phi);
            i.args.push(a);
            i.pb.push(b);
        }
        if let (Some(ap), Some(nv)) = (acc_phi, new_acc) {
            let i = f.im(ap);
            i.args.push(nv);
            i.pb.push(b);
        }
    }
    // every other return folds the accumulator in
    if let (Some(ap), Some(op)) = (acc_phi, acc_op) {
        for bi in 0..f.blocks.len() {
            if site_blocks.contains(&(bi as B)) {
                continue;
            }
            if let Term::Ret(vs) = f.blocks[bi].term.clone() {
                if vs.len() == 1 {
                    let nv = f.push(bi as B, op, ret_ty, vec![ap, vs[0]], 0);
                    f.blocks[bi].term = Term::Ret(vec![nv]);
                }
            }
        }
    }
    true
}
