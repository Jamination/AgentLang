// Full unrolling of loops with a small constant trip count.
use super::licm::make_preheaders;
use super::simplify::fold_icmp;
use crate::ir::*;
use std::collections::HashMap;

pub const MAX_TRIP: usize = 16;
pub const MAX_UNROLLED_SIZE: usize = 640;

struct Plan {
    blocks: Vec<B>,
    header: B,
    latch: B,
    pre: B,
    exit: B,
    // number of copies of the body
    trip: usize,
    // true: the loop disappears; false: the copies form a loop again (trip count is a multiple)
    full: bool,
}

pub const MAX_PARTIAL_SIZE: usize = 400;

fn analyze(f: &Func, cfg: &Cfg, loops: &Loops, li: usize) -> Option<Plan> {
    let l = &loops.loops[li];
    let h = l.header;
    let outside: Vec<B> = cfg.preds[h as usize].iter().copied().filter(|p| !loops.contains(li, *p)).collect();
    if outside.len() != 1 || f.succs(outside[0]).len() != 1 || l.latches.len() != 1 {
        return None;
    }
    let pre = outside[0];
    let latch = l.latches[0];
    let mut in_loop = vec![false; f.blocks.len()];
    for &b in &l.blocks {
        in_loop[b as usize] = true;
    }
    let (c, t, e) = match f.blocks[latch as usize].term {
        Term::Br(c, t, e) => (c, t, e),
        _ => return None,
    };
    let (back_true, exit) = if t == h && !in_loop[e as usize] {
        (true, e)
    } else if e == h && !in_loop[t as usize] {
        (false, t)
    } else {
        return None;
    };
    // counted loop with constant bounds
    let ci = &f.insts[c as usize];
    if !ci.op.is_icmp() {
        return None;
    }
    let (next, end) = (ci.args[0], ci.args[1]);
    let endk = f.is_const(end)?;
    let ni = &f.insts[next as usize];
    if ni.op != Op::Add {
        return None;
    }
    let step = f.is_const(ni.args[1])?;
    let phi = ni.args[0];
    let pi = &f.insts[phi as usize];
    if pi.op != Op::Phi || pi.args.len() != 2 || !f.blocks[h as usize].insts.contains(&phi) {
        return None;
    }
    let mut start = None;
    let mut back = NOV;
    for (k, &pb) in pi.pb.iter().enumerate() {
        if pb == pre {
            start = f.is_const(pi.args[k]);
        } else if pb == latch {
            back = pi.args[k];
        }
    }
    let start = start?;
    if back != next || step == 0 {
        return None;
    }
    let ty = pi.ty;
    let mut trip = 0usize;
    let mut i = start;
    loop {
        trip += 1;
        if trip > 1 << 16 {
            return None;
        }
        let nx = canon(ty, i.wrapping_add(step));
        let cont = fold_icmp(ci.op, ty, nx, endk)? == back_true;
        if !cont {
            break;
        }
        i = nx;
    }
    // longest chain of header phis that only shift values along (h = g; g = f; ...)
    let hphis: Vec<V> = f.blocks[h as usize].insts.iter().copied().take_while(|v| f.insts[*v as usize].op == Op::Phi).collect();
    let back_of = |ph: V| -> V {
        let i = &f.insts[ph as usize];
        i.pb.iter().zip(i.args.iter()).find(|(pb, _)| **pb == latch).map(|(_, a)| *a).unwrap_or(NOV)
    };
    let mut chain = 1usize;
    for &ph in &hphis {
        let mut len = 1usize;
        let mut cur = ph;
        loop {
            let b = back_of(cur);
            if b == NOV || b == ph || !hphis.contains(&b) || len > 16 {
                break;
            }
            len += 1;
            cur = b;
        }
        chain = chain.max(len);
    }
    // size and exits
    let def_block = f.block_of();
    let mut size = 0usize;
    for &b in &l.blocks {
        size += f.blocks[b as usize].insts.len() + 1;
        match &f.blocks[b as usize].term {
            Term::Ret(_) | Term::None | Term::Trap => return None,
            _ => {}
        }
        for s in f.succs(b) {
            if in_loop[s as usize] || (b == latch && s == exit) {
                continue;
            }
            // side exits must be traps that do not look at loop values
            let sb = &f.blocks[s as usize];
            if sb.term != Term::Trap {
                return None;
            }
            for &v in &sb.insts {
                let inst = &f.insts[v as usize];
                if inst.op == Op::Phi {
                    return None;
                }
                if inst.args.iter().any(|a| def_block[*a as usize] != u32::MAX && in_loop[def_block[*a as usize] as usize]) {
                    return None;
                }
            }
        }
    }
    if trip <= MAX_TRIP && size * trip <= MAX_UNROLLED_SIZE {
        return Some(Plan { blocks: l.blocks.clone(), header: h, latch, pre, exit, trip, full: true });
    }
    // partial: unrolling by the shift-chain length turns the per-iteration register shuffle into
    // plain renaming
    if super::enabled("partial") && chain >= 2 && chain <= 8 && trip % chain == 0 && trip > chain && size * chain <= MAX_PARTIAL_SIZE {
        return Some(Plan { blocks: l.blocks.clone(), header: h, latch, pre, exit, trip: chain, full: false });
    }
    None
}

fn apply(f: &mut Func, p: &Plan) {
    let n0 = f.insts.len();
    let nb0 = f.blocks.len();
    let mut in_loop = vec![false; nb0];
    for &b in &p.blocks {
        in_loop[b as usize] = true;
    }
    let def_block = f.block_of();
    let loop_def = |v: V| -> bool { (v as usize) < n0 && def_block[v as usize] != u32::MAX && in_loop[def_block[v as usize] as usize] };
    let hphis: Vec<V> = f.blocks[p.header as usize].insts.iter().copied().take_while(|v| f.insts[*v as usize].op == Op::Phi).collect();
    // (start value, back-edge value) of each header phi
    let mut phi_in: HashMap<V, (V, V)> = HashMap::new();
    for &ph in &hphis {
        let i = &f.insts[ph as usize];
        let mut s = NOV;
        let mut bk = NOV;
        for (k, &pb) in i.pb.iter().enumerate() {
            if pb == p.pre {
                s = i.args[k];
            } else if pb == p.latch {
                bk = i.args[k];
            }
        }
        phi_in.insert(ph, (s, bk));
    }
    // copy 0 is the original body; prev maps original values to their copy in the previous iteration
    let mut prev: Vec<V> = (0..n0 as V).collect();
    let mut prev_latch = p.latch;
    let orig_latch_term = f.blocks[p.latch as usize].term.clone();
    let mut prev_header_of_last = p.header;
    let exit_is_true_target = matches!(f.blocks[p.latch as usize].term, Term::Br(_, t, _) if t == p.exit);
    let _ = exit_is_true_target;
    for _k in 1..p.trip {
        let mut bmap: HashMap<B, B> = HashMap::new();
        for &b in &p.blocks {
            bmap.insert(b, f.new_block());
        }
        let mut cur: Vec<V> = vec![NOV; n0];
        let look = |m: &Vec<V>, v: V| -> V {
            if loop_def(v) {
                m[v as usize]
            } else {
                v
            }
        };
        for &ph in &hphis {
            let (_, bk) = phi_in[&ph];
            cur[ph as usize] = look(&prev, bk);
        }
        // allocate ids
        for &b in &p.blocks {
            for ii in 0..f.blocks[b as usize].insts.len() {
                let v = f.blocks[b as usize].insts[ii];
                if (v as usize) >= n0 || cur[v as usize] != NOV {
                    continue;
                }
                if b == p.header && f.insts[v as usize].op == Op::Phi {
                    continue;
                }
                let (op, ty, k, aux) = {
                    let i = &f.insts[v as usize];
                    (i.op, i.ty, i.k, i.aux)
                };
                let nv = f.mk(op, ty, Vec::new(), k);
                f.im(nv).aux = aux;
                cur[v as usize] = nv;
            }
        }
        for &b in &p.blocks {
            let nb = bmap[&b];
            let insts = f.blocks[b as usize].insts.clone();
            for v in insts {
                if (v as usize) >= n0 {
                    continue;
                }
                if b == p.header && f.insts[v as usize].op == Op::Phi {
                    continue;
                }
                let nv = cur[v as usize];
                let args: Vec<V> = f.insts[v as usize].args.iter().map(|a| look(&cur, *a)).collect();
                let pb: Vec<B> = f.insts[v as usize].pb.iter().map(|x| bmap.get(x).copied().unwrap_or(*x)).collect();
                f.im(nv).args = args;
                f.im(nv).pb = pb;
                f.blocks[nb as usize].insts.push(nv);
            }
            let src_term = if b == p.latch { orig_latch_term.clone() } else { f.blocks[b as usize].term.clone() };
            let term = match src_term {
                Term::Jmp(t) => Term::Jmp(bmap.get(&t).copied().unwrap_or(t)),
                Term::Br(c, t, e) => Term::Br(look(&cur, c), bmap.get(&t).copied().unwrap_or(t), bmap.get(&e).copied().unwrap_or(e)),
                other => other,
            };
            f.blocks[nb as usize].term = term;
        }
        // the previous copy's latch falls into this copy
        f.blocks[prev_latch as usize].term = Term::Jmp(bmap[&p.header]);
        prev_latch = bmap[&p.latch];
        prev_header_of_last = bmap[&p.header];
        prev = cur;
    }
    let _ = prev_header_of_last;
    if p.full {
        // the last copy leaves the loop
        f.blocks[prev_latch as usize].term = Term::Jmp(p.exit);
    } else if p.trip > 1 {
        // the last copy branches back to the first one
        if let Term::Br(_, t, e) = &mut f.blocks[prev_latch as usize].term {
            if *t != p.exit {
                *t = p.header;
            }
            if *e != p.exit {
                *e = p.header;
            }
        }
    }
    // exit phis and uses after the loop see the last copy
    if p.trip > 1 {
        let last = &prev;
        for b in 0..nb0 {
            if in_loop[b] {
                continue;
            }
            for ii in 0..f.blocks[b].insts.len() {
                let v = f.blocks[b].insts[ii];
                for ai in 0..f.insts[v as usize].args.len() {
                    let a = f.insts[v as usize].args[ai];
                    if loop_def(a) {
                        f.insts[v as usize].args[ai] = last[a as usize];
                    }
                }
                if f.insts[v as usize].op == Op::Phi && b as B == p.exit {
                    for pb in f.insts[v as usize].pb.iter_mut() {
                        if *pb == p.latch {
                            *pb = prev_latch;
                        }
                    }
                }
            }
            match &mut f.blocks[b].term {
                Term::Br(c, _, _) => {
                    if loop_def(*c) {
                        *c = last[*c as usize];
                    }
                }
                Term::Ret(vs) => {
                    for v in vs.iter_mut() {
                        if loop_def(*v) {
                            *v = last[*v as usize];
                        }
                    }
                }
                _ => {}
            }
        }
    }
    if !p.full {
        // header phis stay: their back-edge inputs now come from the last copy
        if p.trip > 1 {
            for &ph in &hphis {
                let (_, bk) = phi_in[&ph];
                let nv = if loop_def(bk) { prev[bk as usize] } else { bk };
                let i = f.im(ph);
                for k in 0..i.pb.len() {
                    if i.pb[k] == p.latch {
                        i.pb[k] = prev_latch;
                        i.args[k] = nv;
                    }
                }
            }
        }
        return;
    }
    // copy 0: header phis take their initial values
    let mut repl: Vec<V> = vec![NOV; f.insts.len()];
    for &ph in &hphis {
        repl[ph as usize] = phi_in[&ph].0;
    }
    f.blocks[p.header as usize].insts.retain(|v| !hphis.contains(v));
    f.apply_repl(&mut repl);
}

pub fn run(f: &mut Func) -> bool {
    let mut changed = false;
    for _ in 0..64 {
        if f.size() > 8000 {
            break;
        }
        make_preheaders(f);
        let cfg = Cfg::new(f);
        let loops = Loops::new(f, &cfg);
        let mut order: Vec<usize> = (0..loops.loops.len()).collect();
        order.sort_by(|a, b| loops.loops[*b].depth.cmp(&loops.loops[*a].depth));
        let mut plan = None;
        for li in order {
            if let Some(p) = analyze(f, &cfg, &loops, li) {
                plan = Some(p);
                break;
            }
        }
        match plan {
            Some(p) => {
                apply(f, &p);
                super::cleanup::prune_unreachable(f);
                changed = true;
            }
            None => break,
        }
    }
    changed
}
