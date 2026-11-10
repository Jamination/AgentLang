// Bounds-check hoisting.
//
// A check `idx <u len` that runs on every iteration of a counted loop is replaced by checks in
// the loop preheader. This is only done for loops that cannot be left in any other way than
// through their counting test or a failing check, and that contain no calls: for such loops a
// check that fails at some iteration would end the program anyway, so failing early is not
// observable (apart from which of several failing accesses is reported).
use super::licm::make_preheaders;
use crate::ir::*;

struct Iv {
    phi: V,
    start: V,
    step: i64,
    end: V,
    cmp: Op,
    ty: T,
}

// index expression: ext(inner(iv)) where inner is iv +/- invariants
struct Affine {
    ext: Option<Op>,
    // root of the inner expression (the value below the extension)
    inner: V,
    // +1 when the index grows with the induction variable, -1 when it shrinks
    dir: i64,
}

fn is_trap_block(f: &Func, b: B) -> bool {
    f.blocks[b as usize].term == Term::Trap && !f.blocks[b as usize].insts.iter().any(|v| f.insts[*v as usize].op == Op::Phi)
}

fn find_iv(f: &Func, header: B, latch: B, pre: B, in_loop: &[bool], def_block: &[B]) -> Option<Iv> {
    let (c, t, e) = match f.blocks[latch as usize].term {
        Term::Br(c, t, e) => (c, t, e),
        _ => return None,
    };
    if t != header || in_loop[e as usize] {
        return None;
    }
    let ci = &f.insts[c as usize];
    if !ci.op.is_icmp() {
        return None;
    }
    let (next, end) = (ci.args[0], ci.args[1]);
    let invariant = |v: V| def_block[v as usize] == u32::MAX || !in_loop[def_block[v as usize] as usize];
    if !invariant(end) {
        return None;
    }
    let ni = &f.insts[next as usize];
    if ni.op != Op::Add {
        return None;
    }
    let step = f.is_const(ni.args[1])?;
    let phi = ni.args[0];
    let pi = &f.insts[phi as usize];
    if pi.op != Op::Phi || def_block[phi as usize] != header || pi.args.len() != 2 {
        return None;
    }
    let mut start = NOV;
    let mut back = NOV;
    for (k, &pb) in pi.pb.iter().enumerate() {
        if pb == pre {
            start = pi.args[k];
        } else if pb == latch {
            back = pi.args[k];
        }
    }
    if start == NOV || back != next {
        return None;
    }
    let ty = pi.ty;
    let ok = match (step, ci.op) {
        (1, Op::Slt) | (1, Op::Ult) | (-1, Op::Sgt) | (-1, Op::Ugt) => true,
        (1, Op::Sle) | (1, Op::Ule) | (-1, Op::Sge) | (-1, Op::Uge) => {
            // inclusive bounds must not sit at the edge of the type (the counter would wrap)
            match f.is_const(end) {
                Some(k) => {
                    let bits = ty.bits();
                    let (smin, smax) = if bits == 64 { (i64::MIN, i64::MAX) } else { (-(1i64 << (bits - 1)), (1i64 << (bits - 1)) - 1) };
                    match ci.op {
                        Op::Sle => k != smax,
                        Op::Sge => k != smin,
                        Op::Ule => k != -1,
                        _ => k != 0,
                    }
                }
                None => false,
            }
        }
        _ => false,
    };
    if !ok {
        return None;
    }
    Some(Iv { phi, start, step, end, cmp: ci.op, ty })
}

// match idx as ext(inner) with inner = iv, inner + inv, inner - inv or inv - inner
fn match_affine(f: &Func, idx: V, iv: &Iv, in_loop: &[bool], def_block: &[B]) -> Option<Affine> {
    let invariant = |v: V| def_block[v as usize] == u32::MAX || !in_loop[def_block[v as usize] as usize];
    let (ext, inner) = {
        let i = &f.insts[idx as usize];
        if matches!(i.op, Op::SExt | Op::ZExt) && !invariant(idx) {
            (Some(i.op), i.args[0])
        } else {
            (None, idx)
        }
    };
    // walk down the inner chain
    let mut dir = 1i64;
    let mut v = inner;
    let mut depth = 0;
    loop {
        if v == iv.phi {
            break;
        }
        depth += 1;
        if depth > 8 {
            return None;
        }
        let i = &f.insts[v as usize];
        if i.ty != iv.ty {
            return None;
        }
        match i.op {
            Op::Add => {
                let (a, b) = (i.args[0], i.args[1]);
                if invariant(b) && !invariant(a) {
                    v = a;
                } else if invariant(a) && !invariant(b) {
                    v = b;
                } else {
                    return None;
                }
            }
            Op::Sub => {
                let (a, b) = (i.args[0], i.args[1]);
                if invariant(b) && !invariant(a) {
                    v = a;
                } else if invariant(a) && !invariant(b) {
                    dir = -dir;
                    v = b;
                } else {
                    return None;
                }
            }
            _ => return None,
        }
    }
    if f.insts[inner as usize].ty != iv.ty {
        return None;
    }
    Some(Affine { ext, inner, dir: dir * iv.step })
}

// rebuild the index expression in block `pre` with the induction variable replaced by `at`
fn clone_at(f: &mut Func, pre: B, v: V, iv_phi: V, at: V, in_loop: &[bool], def_block: &[B]) -> V {
    if v == iv_phi {
        return at;
    }
    let db = def_block.get(v as usize).copied().unwrap_or(u32::MAX);
    if db == u32::MAX || !in_loop[db as usize] {
        return v;
    }
    let i = f.insts[v as usize].clone();
    let args: Vec<V> = i.args.iter().map(|a| clone_at(f, pre, *a, iv_phi, at, in_loop, def_block)).collect();
    f.push(pre, i.op, i.ty, args, i.k)
}

fn hoist_in_loop(f: &mut Func, cfg: &Cfg, loops: &Loops, li: usize) -> bool {
    let l = &loops.loops[li];
    let h = l.header;
    let outside: Vec<B> = cfg.preds[h as usize].iter().copied().filter(|p| !loops.contains(li, *p)).collect();
    if outside.len() != 1 || f.succs(outside[0]).len() != 1 || l.latches.len() != 1 {
        return false;
    }
    let pre = outside[0];
    let latch = l.latches[0];
    let mut in_loop = vec![false; f.blocks.len()];
    for &b in &l.blocks {
        in_loop[b as usize] = true;
    }
    // the loop may only be left through its latch or through failing checks, and has no calls
    for &b in &l.blocks {
        for &v in &f.blocks[b as usize].insts {
            if matches!(f.insts[v as usize].op, Op::Call | Op::CallInd | Op::Syscall) {
                return false;
            }
        }
        match &f.blocks[b as usize].term {
            Term::Ret(_) | Term::Trap | Term::None => return false,
            _ => {}
        }
        for s in f.succs(b) {
            if !in_loop[s as usize] && b != latch && !is_trap_block(f, s) {
                return false;
            }
        }
    }
    let def_block = f.block_of();
    let iv = find_iv(f, h, latch, pre, &in_loop, &def_block);
    let invariant = |v: V| def_block[v as usize] == u32::MAX || !in_loop[def_block[v as usize] as usize];
    // collect candidate checks
    enum Kind {
        Invariant,
        Affine(Affine),
    }
    let mut cands: Vec<(B, V, B, B, V, V, Kind)> = Vec::new(); // block, cond, ok, trap, idx, len
    for &b in &l.blocks {
        let (c, t, e) = match f.blocks[b as usize].term {
            Term::Br(c, t, e) => (c, t, e),
            _ => continue,
        };
        if !in_loop[t as usize] || in_loop[e as usize] || !is_trap_block(f, e) || b == latch {
            continue;
        }
        if !cfg.dom(b, latch) {
            continue;
        }
        let ci = &f.insts[c as usize];
        let (idx, len) = match ci.op {
            Op::Ult => (ci.args[0], ci.args[1]),
            Op::Ugt => (ci.args[1], ci.args[0]),
            _ => continue,
        };
        if f.insts[idx as usize].ty != T::I64 || !invariant(len) {
            continue;
        }
        if invariant(idx) {
            if invariant(c) {
                cands.push((b, c, t, e, idx, len, Kind::Invariant));
            }
            continue;
        }
        if let Some(iv) = &iv {
            if let Some(a) = match_affine(f, idx, iv, &in_loop, &def_block) {
                cands.push((b, c, t, e, idx, len, Kind::Affine(a)));
            }
        }
    }
    if cands.is_empty() {
        return false;
    }
    // the last value taken by the induction variable (guarded against zero-trip shapes)
    let mut last_eff = NOV;
    if let Some(iv) = &iv {
        if cands.iter().any(|c| matches!(c.6, Kind::Affine(_))) {
            let enters = f.push(pre, iv.cmp, T::I8, vec![iv.start, iv.end], 0);
            let last = match iv.cmp {
                Op::Slt | Op::Ult => {
                    let one = f.push(pre, Op::Const, iv.ty, vec![], 1);
                    f.push(pre, Op::Sub, iv.ty, vec![iv.end, one], 0)
                }
                Op::Sgt | Op::Ugt => {
                    let one = f.push(pre, Op::Const, iv.ty, vec![], 1);
                    f.push(pre, Op::Add, iv.ty, vec![iv.end, one], 0)
                }
                _ => iv.end,
            };
            last_eff = f.push(pre, Op::Select, iv.ty, vec![enters, last, iv.start], 0);
        }
    }
    // build the chain of hoisted checks: pre -> n1 -> ... -> header
    let mut cur = pre;
    let mut add_check = |f: &mut Func, cur: &mut B, cond: V, trap: B| {
        let nb = f.new_block();
        f.blocks[nb as usize].term = Term::Jmp(h);
        f.blocks[*cur as usize].term = Term::Br(cond, nb, trap);
        *cur = nb;
    };
    for (b, c, ok, trap, idx, len, kind) in cands {
        match kind {
            Kind::Invariant => {
                add_check(f, &mut cur, c, trap);
            }
            Kind::Affine(a) => {
                let iv = iv.as_ref().unwrap();
                // computations go into `pre` (it dominates the whole chain)
                let build = |f: &mut Func, at: V| -> V {
                    let inner = clone_at(f, pre, a.inner, iv.phi, at, &in_loop, &def_block);
                    match a.ext {
                        Some(op) => f.push(pre, op, T::I64, vec![inner], 0),
                        None => inner,
                    }
                };
                let e_first = build(f, iv.start);
                let e_last = build(f, last_eff);
                let c1 = f.push(pre, Op::Ult, T::I8, vec![e_first, len], 0);
                let c2 = f.push(pre, Op::Ult, T::I8, vec![e_last, len], 0);
                let c3 = if a.dir > 0 { f.push(pre, Op::Ule, T::I8, vec![e_first, e_last], 0) } else { f.push(pre, Op::Ule, T::I8, vec![e_last, e_first], 0) };
                add_check(f, &mut cur, c1, trap);
                add_check(f, &mut cur, c2, trap);
                add_check(f, &mut cur, c3, trap);
                let _ = idx;
            }
        }
        f.blocks[b as usize].term = Term::Jmp(ok);
    }
    // header phis now come from the end of the chain
    if cur != pre {
        for ii in 0..f.blocks[h as usize].insts.len() {
            let v = f.blocks[h as usize].insts[ii];
            if f.insts[v as usize].op != Op::Phi {
                break;
            }
            for p in f.insts[v as usize].pb.iter_mut() {
                if *p == pre {
                    *p = cur;
                }
            }
        }
    }
    true
}

pub fn run(f: &mut Func) -> bool {
    let mut changed = false;
    for _ in 0..200 {
        make_preheaders(f);
        let cfg = Cfg::new(f);
        let loops = Loops::new(f, &cfg);
        let mut order: Vec<usize> = (0..loops.loops.len()).collect();
        order.sort_by(|a, b| loops.loops[*b].depth.cmp(&loops.loops[*a].depth));
        let mut did = false;
        for li in order {
            if hoist_in_loop(f, &cfg, &loops, li) {
                did = true;
                break;
            }
        }
        if !did {
            break;
        }
        changed = true;
        super::cleanup::prune_unreachable(f);
    }
    changed
}
