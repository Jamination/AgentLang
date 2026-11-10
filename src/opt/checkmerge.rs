// Merge runs of bounds checks with constant indices against the same length:
//   k1 <u len; ...; k2 <u len   (no calls in between, k2 > k1)
// becomes a single check of the largest index at the position of the first one. A failing
// later check would end the program anyway and nothing observable happens in between.
use crate::ir::*;

fn is_trap_block(f: &Func, b: B) -> bool {
    f.blocks[b as usize].term == Term::Trap && !f.blocks[b as usize].insts.iter().any(|v| f.insts[*v as usize].op == Op::Phi)
}

// (len value, constant index) of a check condition `len >u k` / `k <u len`
fn const_check(f: &Func, c: V) -> Option<(V, i64)> {
    let i = &f.insts[c as usize];
    match i.op {
        Op::Ugt => f.is_const(i.args[1]).map(|k| (i.args[0], k)),
        Op::Ult => f.is_const(i.args[0]).map(|k| (i.args[1], k)),
        _ => None,
    }
}

pub fn run(f: &mut Func) -> bool {
    let preds = f.preds();
    let mut changed = false;
    let rpo = f.rpo();
    for &b in &rpo {
        let (c, ok, trap) = match f.blocks[b as usize].term {
            Term::Br(c, t, e) => (c, t, e),
            _ => continue,
        };
        if !is_trap_block(f, trap) {
            continue;
        }
        let (len, k0) = match const_check(f, c) {
            Some(x) => x,
            None => continue,
        };
        if f.insts[len as usize].ty != T::I64 || k0 < 0 {
            continue;
        }
        let mut kmax = k0;
        let mut cur = ok;
        let mut steps = 0;
        loop {
            steps += 1;
            if steps > 256 || preds[cur as usize].len() != 1 || cur == b {
                break;
            }
            if f.blocks[cur as usize].insts.iter().any(|v| matches!(f.insts[*v as usize].op, Op::Call | Op::CallInd | Op::Syscall | Op::Phi)) {
                break;
            }
            match f.blocks[cur as usize].term {
                Term::Jmp(t) => cur = t,
                Term::Br(c2, t2, e2) if is_trap_block(f, e2) => {
                    match const_check(f, c2) {
                        Some((len2, k2)) if len2 == len && k2 >= 0 => {
                            kmax = kmax.max(k2);
                            f.blocks[cur as usize].term = Term::Jmp(t2);
                            changed = true;
                        }
                        _ => {}
                    }
                    cur = t2;
                }
                _ => break,
            }
        }
        if kmax > k0 {
            let kc = f.push(b, Op::Const, T::I64, vec![], kmax);
            let nc = f.push(b, Op::Ugt, T::I8, vec![len, kc], 0);
            f.blocks[b as usize].term = Term::Br(nc, ok, trap);
        }
    }
    if changed {
        super::cleanup::prune_unreachable(f);
    }
    changed
}
