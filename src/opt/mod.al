// The optimizer: pass pipeline per function and the inlining driver.

// debugging aid: ALC_DISABLE=pass1,pass2 switches optimization passes off
// the environment switches, read once
opt_env_read: bool
opt_env_debug: str
opt_env_disable: str
opt_env_has_disable: bool

fn opt_read_env() {
    if !opt_env_read {
        opt_env_read = true
        d, has_d := env_get("ALC_DEBUG")
        opt_env_debug = d
        v, found := env_get("ALC_DISABLE")
        opt_env_disable = v
        opt_env_has_disable = found
    }
}

fn opt_enabled(name: str) -> bool {
    opt_read_env()
    if opt_env_has_disable {
        for x in split(opt_env_disable, ',') {
            if x == name {
                return false
            }
        }
        return true
    }
    return true
}
fn opt_trace(what: str, f: *Func) {
    opt_read_env()
    v := opt_env_debug
    if v == "trace" {
        eprint(fmt("[trace] ", what, " ", f.name, " (size ", f.size(), ")\n"))
    } else if v == "verify" {
        // `what` names the pass about to run, so a failure belongs to the previous one
        e := ir_verify(f)
        if e != "" {
            eprint(fmt("IR verification failed before `", what, "` in ", f.name, ": ", e, "\n", ir_print_func(f, None), "\n"))
            exit(3)
        }
    }
}

fn opt_local_opt(f: *Func, level: i64) {
    opt_trace("local_opt", f)
    cleanup_prune_unreachable(f)
    mem2reg_run(f)
    cleanup_dce(f)
    if level == 0 {
        return
    }
    for it in 0..4 {
        ch := false
        opt_trace("simplify", f)
        if simplify_run(f) {
            ch = true
        }
        opt_trace("gvn", f)
        if opt_enabled("gvn") && gvn_run(f) {
            ch = true
        }
        if opt_enabled("checkmerge") && checkmerge_run(f) {
            ch = true
        }
        opt_trace("loadelim", f)
        if opt_enabled("loadelim") && loadelim_run(f) {
            ch = true
        }
        opt_trace("mem2reg", f)
        if mem2reg_run(f) {
            ch = true
        }
        opt_trace("licm", f)
        if opt_enabled("licm") && licm_run(f) {
            ch = true
        }
        opt_trace("simplify2", f)
        if simplify_run(f) {
            ch = true
        }
        if !ch {
            break
        }
    }
    opt_trace("unroll-phase", f)
    // fully unroll small constant-trip loops (inner loops become constant as outer ones go)
    for it in 0..6 {
        if !opt_enabled("unroll") || !unroll_run(f) {
            break
        }
        opt_trace("after-unroll", f)
        dbg, has_dbg := env_get("ALC_DEBUG")
        if has_dbg && dbg == "unroll" {
            eprint(fmt("after unroll:\n", ir_print_func(f, None), "\n"))
        }
        for it2 in 0..3 {
            ch := false
            if simplify_run(f) {
                ch = true
            }
            if opt_enabled("gvn") && gvn_run(f) {
                ch = true
            }
            if opt_enabled("checkmerge") && checkmerge_run(f) {
                ch = true
            }
            if opt_enabled("loadelim") && loadelim_run(f) {
                ch = true
            }
            if mem2reg_run(f) {
                ch = true
            }
            if opt_enabled("licm") && licm_run(f) {
                ch = true
            }
            if simplify_run(f) {
                ch = true
            }
            if !ch {
                break
            }
        }
    }
    // hoist bounds checks out of counted loops, then clean up what that exposes
    for it in 0..3 {
        if !opt_enabled("bce") || !bce_run(f) {
            break
        }
        opt_trace("after-bce", f)
        gvn_run(f)
        if opt_enabled("checkmerge") {
            checkmerge_run(f)
        }
        opt_trace("after-bce-gvn", f)
        simplify_run(f)
        licm_run(f)
        simplify_run(f)
    }
    cleanup_dce(f)
    opt_trace("end-local-opt", f)
}

fn opt_optimize(m: *Module, level: i64) {
    n := m.funcs.len
    for fid in 0..n {
        f := &m.funcs[fid]
        if f.lowered {
            work_begin()
            cleanup_prune_unreachable(f)
            mem2reg_run(f)
            cleanup_dce(f)
            if level > 0 {
                simplify_run(f)
                if opt_enabled("tre") && tre_run(f, fid) {
                    opt_trace("after-tre", f)
                    simplify_run(f)
                }
            }
            // keep the function, drop the passes' temporary data (see work_begin in base.al)
            work_end()
            m.funcs[fid] = clone(f)
        }
    }
    if level == 0 {
        return
    }
    // call graph facts
    call_counts := vec_fill(n, 0)
    addr_taken := vec_fill(n, false)
    callees := vec_fill(n, vec[i64]())
    for fi in 0..n {
        f := &m.funcs[fi]
        for bi in 0..f.blocks.len {
            for v in f.blocks[bi].insts.items() {
                i := &f.insts[v]
                if i.op == OpCall {
                    call_counts[i.k] += 1
                    callees[fi].push(i.k)
                } else if i.op == OpFAddr {
                    addr_taken[i.k] = true
                }
            }
        }
    }
    addr_taken[m.entry] = true
    // bottom-up order (post-order DFS from every function)
    order := vec[i64]()
    state := vec_fill(n, u8(0))
    for root in 0..n {
        if state[root] != 0 {
            continue
        }
        stack := vec_of([](i64, i64){(root, 0)})
        state[root] = 1
        while stack.len > 0 {
            top := &stack[stack.len - 1]
            fx := top.0
            if top.1 < callees[fx].len {
                c := callees[fx][top.1]
                top.1 += 1
                if state[c] == 0 {
                    state[c] = 1
                    stack.push((c, 0))
                }
            } else {
                order.push(fx)
                stack.pop()
            }
        }
    }
    pol := Policy{small: 40, hinted: 400, single_site: 150, max_caller: 4000}
    done := vec_fill(n, false)
    for fid in order.items() {
        if m.funcs[fid].lowered {
            work_begin()
            opt_local_opt(&m.funcs[fid], level)
            if inline_run(m, fid, done.items(), call_counts.items(), addr_taken.items(), &pol) {
                opt_trace("after-inline", &m.funcs[fid])
                opt_local_opt(&m.funcs[fid], level)
            }
            work_end()
            m.funcs[fid] = clone(&m.funcs[fid])
        }
        done[fid] = true
    }
}
