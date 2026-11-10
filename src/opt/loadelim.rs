// Redundant load elimination, store-to-load forwarding and local dead store elimination.
use super::alias::*;
use crate::ir::*;

#[derive(Clone)]
struct Avail {
    mref_addr: Addr,
    size: i64,
    class: u32,
    ty: T,
    val: V,
    pending_store: Option<V>, // a store not yet observed by any possible reader
}

fn mr(a: &Avail) -> MemRef {
    MemRef { addr: a.mref_addr, size: a.size, class: a.class }
}

pub fn run(f: &mut Func) -> bool {
    let cfg = Cfg::new(f);
    let esc = escaped_allocas(f);
    let mut repl: Vec<V> = vec![NOV; f.insts.len()];
    let mut dead: Vec<bool> = vec![false; f.insts.len()];
    let mut changed = false;
    fn find(repl: &[V], mut v: V) -> V {
        while repl[v as usize] != NOV {
            v = repl[v as usize];
        }
        v
    }
    // state at the end of each block, reused by a child that has that block as its only predecessor
    let mut out_state: Vec<Option<Vec<Avail>>> = vec![None; f.blocks.len()];
    for &b in &cfg.rpo {
        let mut st: Vec<Avail> = Vec::new();
        if cfg.preds[b as usize].len() == 1 {
            let p = cfg.preds[b as usize][0];
            if let Some(s) = &out_state[p as usize] {
                st = s.clone();
                for a in st.iter_mut() {
                    a.pending_store = None;
                }
            }
        }
        for ii in 0..f.blocks[b as usize].insts.len() {
            let v = f.blocks[b as usize].insts[ii];
            for ai in 0..f.insts[v as usize].args.len() {
                let a = f.insts[v as usize].args[ai];
                let r = find(&repl, a);
                if r != a {
                    f.insts[v as usize].args[ai] = r;
                }
            }
            let op = f.insts[v as usize].op;
            match op {
                Op::Load => {
                    let m = memref(f, v);
                    let ty = f.insts[v as usize].ty;
                    let mut hit = None;
                    for a in st.iter() {
                        if a.ty == ty && must_alias(&mr(a), &m) {
                            hit = Some(a.val);
                            break;
                        }
                    }
                    match hit {
                        Some(val) => {
                            repl[v as usize] = val;
                            dead[v as usize] = true;
                            changed = true;
                        }
                        None => {
                            // this load observes any aliasing pending store
                            for a in st.iter_mut() {
                                if a.pending_store.is_some() && may_alias(&mr(a), &m, &esc) {
                                    a.pending_store = None;
                                }
                            }
                            st.push(Avail { mref_addr: m.addr, size: m.size, class: m.class, ty, val: v, pending_store: None });
                        }
                    }
                }
                Op::Store => {
                    let m = memref(f, v);
                    let ty = f.insts[v as usize].ty;
                    let val = f.insts[v as usize].args[1];
                    // a previous unobserved store to exactly this location is dead
                    for a in st.iter() {
                        if let Some(s) = a.pending_store {
                            if must_alias(&mr(a), &m) {
                                dead[s as usize] = true;
                                changed = true;
                            }
                        }
                    }
                    st.retain(|a| !may_alias(&mr(a), &m, &esc));
                    st.push(Avail { mref_addr: m.addr, size: m.size, class: m.class, ty, val, pending_store: Some(v) });
                }
                Op::Call | Op::CallInd | Op::Syscall | Op::MemCpy | Op::MemSet => {
                    // may read or write anything reachable: only non-escaped stack slots survive
                    st.retain(|a| matches!(a.mref_addr.base, Base::Alloca(x) if !esc[x as usize]));
                    if matches!(op, Op::MemCpy | Op::MemSet) {
                        // these take raw pointers that may point into any alloca passed to them
                        st.clear();
                    }
                    for a in st.iter_mut() {
                        a.pending_store = None;
                    }
                }
                _ => {}
            }
        }
        out_state[b as usize] = Some(st);
    }
    if changed {
        for b in f.blocks.iter_mut() {
            b.insts.retain(|v| !dead[*v as usize]);
        }
        f.apply_repl(&mut repl);
    }
    changed
}
