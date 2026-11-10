pub mod alias;
pub mod bce;
pub mod checkmerge;
pub mod cleanup;
pub mod gvn;
pub mod inline;
pub mod licm;
pub mod loadelim;
pub mod mem2reg;
pub mod simplify;
pub mod tre;
pub mod unroll;

use crate::ir::*;

// debugging aid: ALC_DISABLE=pass1,pass2 switches optimization passes off
pub fn enabled(name: &str) -> bool {
    match std::env::var("ALC_DISABLE") {
        Ok(v) => !v.split(',').any(|x| x == name),
        Err(_) => true,
    }
}

pub fn trace(what: &str, f: &Func) {
    match std::env::var("ALC_DEBUG").as_deref() {
        Ok("trace") => eprintln!("[trace] {} {} (size {})", what, f.name, f.size()),
        Ok("verify") => {
            // `what` names the pass about to run, so a failure belongs to the previous one
            if let Err(e) = verify(f) {
                eprintln!("IR verification failed before `{}` in {}: {}\n{}", what, f.name, e, print_func(f, None));
                std::process::exit(3);
            }
        }
        _ => {}
    }
}

fn local_opt(f: &mut Func, level: u32) {
    trace("local_opt", f);
    cleanup::prune_unreachable(f);
    mem2reg::run(f);
    cleanup::dce(f);
    if level == 0 {
        return;
    }
    for _ in 0..4 {
        let mut ch = false;
        trace("simplify", f);
        ch |= simplify::run(f);
        trace("gvn", f);
        ch |= enabled("gvn") && gvn::run(f);
        ch |= enabled("checkmerge") && checkmerge::run(f);
        trace("loadelim", f);
        ch |= enabled("loadelim") && loadelim::run(f);
        trace("mem2reg", f);
        ch |= mem2reg::run(f);
        trace("licm", f);
        ch |= enabled("licm") && licm::run(f);
        trace("simplify2", f);
        ch |= simplify::run(f);
        if !ch {
            break;
        }
    }
    trace("unroll-phase", f);
    // fully unroll small constant-trip loops (inner loops become constant as outer ones go)
    for _ in 0..6 {
        if !enabled("unroll") || !unroll::run(f) {
            break;
        }
        trace("after-unroll", f);
        if std::env::var("ALC_DEBUG").map(|v| v == "unroll").unwrap_or(false) {
            eprintln!("after unroll:\n{}", print_func(f, None));
        }
        for _ in 0..3 {
            let mut ch = false;
            ch |= simplify::run(f);
            ch |= enabled("gvn") && gvn::run(f);
            ch |= enabled("checkmerge") && checkmerge::run(f);
            ch |= enabled("loadelim") && loadelim::run(f);
            ch |= mem2reg::run(f);
            ch |= enabled("licm") && licm::run(f);
            ch |= simplify::run(f);
            if !ch {
                break;
            }
        }
    }
    // hoist bounds checks out of counted loops, then clean up what that exposes
    for _ in 0..3 {
        if !enabled("bce") || !bce::run(f) {
            break;
        }
        trace("after-bce", f);
        gvn::run(f);
        if enabled("checkmerge") {
            checkmerge::run(f);
        }
        trace("after-bce-gvn", f);
        simplify::run(f);
        licm::run(f);
        simplify::run(f);
    }
    cleanup::dce(f);
    trace("end-local-opt", f);
}

pub fn optimize(m: &mut Module, level: u32) {
    let n = m.funcs.len();
    for (fid, f) in m.funcs.iter_mut().enumerate() {
        if f.lowered {
            cleanup::prune_unreachable(f);
            mem2reg::run(f);
            cleanup::dce(f);
            if level > 0 {
                simplify::run(f);
                if enabled("tre") && tre::run(f, fid as u32) {
                    trace("after-tre", f);
                    simplify::run(f);
                }
            }
        }
    }
    if level == 0 {
        return;
    }
    // call graph facts
    let mut call_counts = vec![0u32; n];
    let mut addr_taken = vec![false; n];
    let mut callees: Vec<Vec<u32>> = vec![Vec::new(); n];
    for (fi, f) in m.funcs.iter().enumerate() {
        for b in &f.blocks {
            for &v in &b.insts {
                let i = &f.insts[v as usize];
                match i.op {
                    Op::Call => {
                        call_counts[i.k as usize] += 1;
                        callees[fi].push(i.k as u32);
                    }
                    Op::FAddr => addr_taken[i.k as usize] = true,
                    _ => {}
                }
            }
        }
    }
    addr_taken[m.entry as usize] = true;
    // bottom-up order (post-order DFS from every function)
    let mut order: Vec<u32> = Vec::new();
    let mut state = vec![0u8; n];
    for root in 0..n as u32 {
        if state[root as usize] != 0 {
            continue;
        }
        let mut stack: Vec<(u32, usize)> = vec![(root, 0)];
        state[root as usize] = 1;
        while let Some(&mut (fx, ref mut ci)) = stack.last_mut() {
            if *ci < callees[fx as usize].len() {
                let c = callees[fx as usize][*ci];
                *ci += 1;
                if state[c as usize] == 0 {
                    state[c as usize] = 1;
                    stack.push((c, 0));
                }
            } else {
                order.push(fx);
                stack.pop();
            }
        }
    }
    let pol = inline::Policy { small: 40, hinted: 400, single_site: 150, max_caller: 4000 };
    let mut done = vec![false; n];
    for fid in order {
        if m.funcs[fid as usize].lowered {
            local_opt(&mut m.funcs[fid as usize], level);
            if inline::run(m, fid, &done, &call_counts, &addr_taken, &pol) {
                trace("after-inline", &m.funcs[fid as usize]);
                local_opt(&mut m.funcs[fid as usize], level);
            }
        }
        done[fid as usize] = true;
    }
}
