pub mod cleanup;
pub mod mem2reg;

use crate::ir::*;

pub fn optimize(m: &mut Module, level: u32) {
    for f in m.funcs.iter_mut() {
        if !f.lowered {
            continue;
        }
        cleanup::prune_unreachable(f);
        mem2reg::run(f);
        cleanup::dce(f);
    }
    let _ = level;
}
