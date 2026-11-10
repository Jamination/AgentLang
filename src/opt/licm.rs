// Loop-invariant code motion (with preheader creation).
use super::alias::*;
use crate::ir::*;

pub fn make_preheaders(f: &mut Func) -> bool {
    let cfg = Cfg::new(f);
    let loops = Loops::new(f, &cfg);
    let mut changed = false;
    for li in 0..loops.loops.len() {
        let h = loops.loops[li].header;
        let outside: Vec<B> = cfg.preds[h as usize].iter().copied().filter(|p| !loops.contains(li, *p)).collect();
        if outside.is_empty() {
            continue;
        }
        if outside.len() == 1 && f.succs(outside[0]).len() == 1 {
            continue;
        }
        let p = f.new_block();
        f.blocks[p as usize].term = Term::Jmp(h);
        for &o in &outside {
            match &mut f.blocks[o as usize].term {
                Term::Jmp(t) => {
                    if *t == h {
                        *t = p;
                    }
                }
                Term::Br(_, a, b) => {
                    if *a == h {
                        *a = p;
                    }
                    if *b == h {
                        *b = p;
                    }
                }
                _ => {}
            }
        }
        // fix header phis
        let hinsts = f.blocks[h as usize].insts.clone();
        for v in hinsts {
            if f.insts[v as usize].op != Op::Phi {
                break;
            }
            let inst = f.insts[v as usize].clone();
            let mut out_vals: Vec<(B, V)> = Vec::new();
            let mut keep_args = Vec::new();
            let mut keep_pb = Vec::new();
            for (k, &pb) in inst.pb.iter().enumerate() {
                if outside.contains(&pb) {
                    out_vals.push((pb, inst.args[k]));
                } else {
                    keep_args.push(inst.args[k]);
                    keep_pb.push(pb);
                }
            }
            let incoming = if out_vals.iter().all(|x| x.1 == out_vals[0].1) {
                out_vals[0].1
            } else {
                let np = f.mk(Op::Phi, inst.ty, out_vals.iter().map(|x| x.1).collect(), 0);
                f.im(np).pb = out_vals.iter().map(|x| x.0).collect();
                f.blocks[p as usize].insts.push(np);
                np
            };
            keep_args.push(incoming);
            keep_pb.push(p);
            let i = f.im(v);
            i.args = keep_args;
            i.pb = keep_pb;
        }
        changed = true;
    }
    changed
}

pub fn run(f: &mut Func) -> bool {
    let mut changed = make_preheaders(f);
    let cfg = Cfg::new(f);
    let loops = Loops::new(f, &cfg);
    if loops.loops.is_empty() {
        return changed;
    }
    let esc = escaped_allocas(f);
    let mut def_block = f.block_of();
    let mut order: Vec<usize> = (0..loops.loops.len()).collect();
    order.sort_by(|a, b| loops.loops[*b].depth.cmp(&loops.loops[*a].depth));
    for li in order {
        let l = &loops.loops[li];
        let h = l.header;
        let outside: Vec<B> = cfg.preds[h as usize].iter().copied().filter(|p| !loops.contains(li, *p)).collect();
        if outside.len() != 1 || f.succs(outside[0]).len() != 1 {
            continue;
        }
        let pre = outside[0];
        let mut in_loop = vec![false; f.blocks.len()];
        for &b in &l.blocks {
            in_loop[b as usize] = true;
        }
        let mut blocks: Vec<B> = l.blocks.clone();
        blocks.sort_by_key(|b| cfg.rpo_idx[*b as usize]);
        // memory effects and exits
        let mut stores: Vec<MemRef> = Vec::new();
        let mut has_call = false;
        let mut exiting: Vec<B> = Vec::new();
        for &b in &blocks {
            for &v in &f.blocks[b as usize].insts {
                match f.insts[v as usize].op {
                    Op::Store => stores.push(memref(f, v)),
                    Op::Call | Op::CallInd | Op::Syscall | Op::MemCpy | Op::MemSet => has_call = true,
                    _ => {}
                }
            }
            if f.succs(b).iter().any(|s| !in_loop[*s as usize]) || matches!(f.blocks[b as usize].term, Term::Ret(_) | Term::Trap) {
                exiting.push(b);
            }
        }
        let guaranteed = |b: B| -> bool { exiting.iter().all(|e| cfg.dom(b, *e)) && l.latches.iter().all(|t| cfg.dom(b, *t)) };
        loop {
            let mut moved = false;
            for &b in &blocks {
                let insts = f.blocks[b as usize].insts.clone();
                let mut keep = Vec::with_capacity(insts.len());
                for v in insts {
                    let i = &f.insts[v as usize];
                    let invariant_args = i.args.iter().all(|a| {
                        let db = def_block[*a as usize];
                        db == u32::MAX || !in_loop[db as usize]
                    });
                    let mut ok = false;
                    if invariant_args {
                        if i.op.is_pure() {
                            ok = true;
                        } else if matches!(i.op, Op::SDiv | Op::UDiv | Op::SRem | Op::URem) {
                            let safe_const = match f.is_const(i.args[1]) {
                                Some(k) => k != 0 && !(k == -1 && matches!(i.op, Op::SDiv | Op::SRem)),
                                None => false,
                            };
                            ok = safe_const || guaranteed(b);
                        } else if i.op == Op::Load {
                            let m = memref(f, v);
                            let private = matches!(m.addr.base, Base::Alloca(x) if !esc[x as usize]);
                            let safe_addr = matches!(m.addr.base, Base::Alloca(_) | Base::Global(_)) && m.addr.off.is_some();
                            if (!has_call || private) && !stores.iter().any(|s| may_alias(s, &m, &esc)) && (safe_addr || guaranteed(b)) {
                                ok = true;
                            }
                        }
                    }
                    if ok {
                        f.blocks[pre as usize].insts.push(v);
                        def_block[v as usize] = pre;
                        moved = true;
                    } else {
                        keep.push(v);
                    }
                }
                f.blocks[b as usize].insts = keep;
            }
            if !moved {
                break;
            }
            changed = true;
        }
    }
    changed
}
