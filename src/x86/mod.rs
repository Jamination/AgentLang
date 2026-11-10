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
        let layout: Vec<u32> = cfg.rpo.clone();
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
