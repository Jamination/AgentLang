pub mod emit;
pub mod isel;
pub mod mir;
pub mod regalloc;

use crate::ir::*;
use std::collections::HashMap;

pub struct Compiled {
    pub fid: u32,
    pub code: emit::Code,
}

pub struct Output {
    pub funcs: Vec<Compiled>,
    pub fpool: Vec<u64>,
}

fn reachable_funcs(m: &Module) -> Vec<u32> {
    let mut seen = vec![false; m.funcs.len()];
    let mut work = vec![m.entry];
    seen[m.entry as usize] = true;
    let mut out = Vec::new();
    while let Some(f) = work.pop() {
        out.push(f);
        let func = &m.funcs[f as usize];
        for b in &func.blocks {
            for &v in &b.insts {
                let i = &func.insts[v as usize];
                if matches!(i.op, Op::Call | Op::FAddr) && !seen[i.k as usize] {
                    seen[i.k as usize] = true;
                    work.push(i.k as u32);
                }
            }
        }
    }
    // function pointers stored in global data
    for g in &m.globals {
        for (_, t) in &g.relocs {
            if let RelocTarget::Func(f) = t {
                if !seen[*f as usize] {
                    seen[*f as usize] = true;
                    out.push(*f);
                }
            }
        }
    }
    out.sort();
    out
}

pub fn compile(m: &mut Module, dump_asm: bool) -> Output {
    let fids = reachable_funcs(m);
    let mut fpool: Vec<u64> = Vec::new();
    let mut fpool_ix: HashMap<u64, u32> = HashMap::new();
    let mut funcs = Vec::new();
    for fid in fids {
        {
            let f = &mut m.funcs[fid as usize];
            crate::opt::cleanup::prune_unreachable(f);
            isel::split_critical_edges(f);
            crate::opt::cleanup::trivial_phis(f);
            crate::opt::cleanup::dce(f);
        }
        let f = &m.funcs[fid as usize];
        let cfg = Cfg::new(f);
        let loops = Loops::new(f, &cfg);
        let depths: Vec<u32> = (0..f.blocks.len()).map(|b| loops.depth(b as B)).collect();
        let mut mf = isel::select(f, m, &depths);
        let layout: Vec<u32> = block_layout(f);
        let alloc = regalloc::allocate(&mut mf, &layout);
        let local: Vec<u32> = mf
            .fconsts
            .iter()
            .map(|&bits| {
                *fpool_ix.entry(bits).or_insert_with(|| {
                    fpool.push(bits);
                    (fpool.len() - 1) as u32
                })
            })
            .collect();
        let code = emit::emit(&mut mf, &alloc, &layout, &local);
        if dump_asm {
            print!("{}", mir::print_mfunc(&mf));
        }
        funcs.push(Compiled { fid, code });
    }
    Output { funcs, fpool }
}

// Block order: reverse postorder that prefers the taken ("then") successor as fallthrough,
// with blocks that inevitably trap moved to the end.
fn block_layout(f: &Func) -> Vec<u32> {
    let n = f.blocks.len();
    let mut seen = vec![false; n];
    let mut post = Vec::with_capacity(n);
    let mut stack: Vec<(B, usize)> = vec![(0, 0)];
    seen[0] = true;
    while let Some(&mut (b, ref mut i)) = stack.last_mut() {
        let mut ss = f.succs(b);
        ss.reverse();
        if *i < ss.len() {
            let s = ss[*i];
            *i += 1;
            if !seen[s as usize] {
                seen[s as usize] = true;
                stack.push((s, 0));
            }
        } else {
            post.push(b);
            stack.pop();
        }
    }
    post.reverse();
    // cold: every path from the block ends in a trap
    let mut cold = vec![false; n];
    let mut changed = true;
    while changed {
        changed = false;
        for &b in post.iter().rev() {
            if cold[b as usize] {
                continue;
            }
            let c = match &f.blocks[b as usize].term {
                Term::Trap | Term::None => true,
                Term::Jmp(t) => cold[*t as usize],
                Term::Br(_, t, e) => cold[*t as usize] && cold[*e as usize],
                Term::Ret(_) => false,
            };
            if c {
                cold[b as usize] = true;
                changed = true;
            }
        }
    }
    let mut out: Vec<u32> = post.iter().copied().filter(|b| !cold[*b as usize] || *b == 0).collect();
    out.extend(post.iter().copied().filter(|b| cold[*b as usize] && *b != 0));
    out
}
