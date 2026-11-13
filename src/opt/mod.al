// The optimizer: pass pipeline per function and the inlining driver.

// debugging aid: ALC_DISABLE=pass1,pass2 switches optimization passes off
// the environment switches, read once
priv env_read: bool
priv env_debug: str
priv env_disable: str
priv env_has_disable: bool

priv fn read_env() {
    if !env_read {
        env_read = true
        d, has_d := env_get("ALC_DEBUG")
        env_debug = d
        v, found := env_get("ALC_DISABLE")
        env_disable = v
        env_has_disable = found
    }
}

fn opt_enabled(name: str) -> bool {
    read_env()
    if env_has_disable {
        for x in split(env_disable, ',') {
            if x == name {
                return false
            }
        }
        return true
    }
    return true
}

// check_fail[k]: function k ends the program for a failed run-time check (__bounds_fail,
// __div_fail, __step_fail); set by opt_optimize before any work_begin
priv check_fail: Vec[bool]

// Is block `b` the failure exit of a run-time check: a trap block whose calls only report the
// failure? Other trap blocks (after `exit`, `panic`, a failed `assert`) are observable ways out,
// so passes that move a failing check earlier must not treat them as check failures.
fn opt_is_check_trap(f: *Func, b: i64) -> bool {
    if !is_trap_block(f, b) {
        return false
    }
    for v in f.blocks[b].insts {
        i := &f.insts[v]
        if i.op == CallInd || i.op == Syscall {
            return false
        }
        if i.op == Call && !(i.k >= 0 && i.k < check_fail.len && check_fail[i.k]) {
            return false
        }
    }
    return true
}
fn opt_trace(what: str, f: *Func) {
    read_env()
    v := env_debug
    if v == "trace" {
        eput(fmt("[trace] ", what, " ", f.name, " (size ", f.size(), ")\n"))
    } else if v == "verify" {
        // `what` names the pass about to run, so a failure belongs to the previous one
        e := ir_verify(f)
        if e != "" {
            eput(fmt("IR verification failed before `", what, "` in ", f.name, ": ", e, "\n", ir_print_func(f, None), "\n"))
            exit(3)
        }
    }
}

// ---------- keeping a function after work_end() ----------
// After work_end() the parts of the function made while working are in the discarded work
// region; they get new memory in the main arena (as `clone(*f)` would). A list still in the
// main arena (never moved while working) is kept: nothing else refers to it. A list made while
// working that is empty but has room is replaced too (a later push would write into the
// discarded region).
priv fn in_main(p: i64) -> bool {
    // the main arena is the one in use after work_end()
    return p >= __heap_base && p < __heap_end
}

priv inline fn keep_list(l: *Vec[i64]) {
    if len(l.buf) > 0 && !in_main(cast[i64](ptr(l.buf))) {
        *l = vec_of(l.items())
    }
}

// the argument lists made while working move to one new buffer (a phi's with the blocks of
// its inputs, without spare room); an empty one no longer points anywhere
priv fn keep_args(f: *Func) {
    total := 0
    for v in 0..f.insts.len {
        i := &f.insts[v]
        n := len(i.args)
        if n == 0 {
            continue
        }
        if !in_main(cast[i64](ptr(i.args))) {
            total += if i.op == Phi { 2 * n } else { n }
        }
    }
    buf := mkslice[i64](__alloc_raw(total * 8), total)
    at := 0
    for v in 0..f.insts.len {
        i := &f.insts[v]
        n := len(i.args)
        if n == 0 {
            i.args = nil
            i.cap = 0
            continue
        }
        if in_main(cast[i64](ptr(i.args))) {
            continue
        }
        memcopy(ptr(buf[at..]), ptr(i.args), n * 8)
        if i.op == Phi {
            memcopy(ptr(buf[at + n..]), ptr(i.from()), n * 8)
            i.args = buf[at..at + n]
            i.cap = i32(n)
            at += 2 * n
        } else {
            i.args = buf[at..at + n]
            at += n
        }
    }
}

priv fn keep_func(f: *Func) {
    if len(f.name) > 0 && !in_main(cast[i64](ptr(f.name))) {
        f.name = clone(f.name)
    }
    if len(f.params.buf) > 0 && !in_main(cast[i64](ptr(f.params.buf))) {
        f.params = clone(f.params)
    }
    if len(f.rets.buf) > 0 && !in_main(cast[i64](ptr(f.rets.buf))) {
        f.rets = clone(f.rets)
    }
    if len(f.insts.buf) > 0 && !in_main(cast[i64](ptr(f.insts.buf))) {
        f.insts = vec_of(f.insts.items())
    }
    keep_args(f)
    if len(f.blocks.buf) > 0 && !in_main(cast[i64](ptr(f.blocks.buf))) {
        f.blocks = vec_of(f.blocks.items())
    }
    for b in 0..f.blocks.len {
        blk := &f.blocks[b]
        keep_list(&blk.insts)
        match blk.term {
            Ret(&vs) => keep_list(vs)
            _ => {}
        }
    }
}

// ---------- passes that cannot change anything are not run ----------
// Every pass is a function of the IR of the function and tells whether it changed it (also for
// what the passes it calls do; unroll_run and bce_run may add preheaders without saying so:
// a preheader made counts as a change). `sk_gen` counts the changes; a pass that reported no
// change when it was last run at the current count would report no change again: it is
// skipped. Some passes are also known to be clean after a change (see opt_pass).
priv sk_gen: i64
priv sk_clean: [16]i64 // sk_gen + 1 when pass k is known to change nothing

// keys of the passes (simplify_run's parts use 7..9)
const PASS_PRUNE = 0
const PASS_MEM2REG = 1
const PASS_DCE = 2
const PASS_GVN = 3
const PASS_CHECKMERGE = 4
const PASS_LOADELIM = 5
const PASS_LICM = 6
const PASS_CFG = 8
const PASS_PHIS = 9

fn opt_pass(k: i64, f: *Func, p: fn(*Func) -> bool) -> bool {
    if sk_clean[k] == sk_gen + 1 {
        return false
    }
    prune_clean := sk_clean[PASS_PRUNE] == sk_gen + 1
    // every pass but simplify_cfg (which folds branches first) asks for its first CFG analysis
    // before it changes anything
    ir_memo_pass(sk_gen, k != PASS_CFG)
    if p(f) {
        sk_gen += 1
        now := sk_gen + 1
        // passes that leave nothing for a second run of themselves
        if k == PASS_PRUNE || k == PASS_DCE || k == PASS_PHIS {
            sk_clean[k] = now
        }
        if k == PASS_MEM2REG && mem2reg_settled() {
            // its last change ended with trivial phis and DCE (DCE removes no input of a live
            // phi), then a round found nothing; it keeps the CFG and the phi blocks of the
            // phis there are, and gives its phis the predecessors: a pruned function stays so
            sk_clean[PASS_MEM2REG] = now
            sk_clean[PASS_PHIS] = now
            sk_clean[PASS_DCE] = now
            if prune_clean {
                sk_clean[PASS_PRUNE] = now
            }
        }
        return true
    }
    sk_clean[k] = sk_gen + 1
    if k == PASS_CFG {
        // simplify_cfg begins with prune: it found nothing either
        sk_clean[PASS_PRUNE] = sk_gen + 1
    }
    return false
}

// the number of reported changes so far: equal numbers at the starts of two passes mean the
// same IR (every work session starts with a new number)
fn opt_gen() -> i64 {
    return sk_gen
}

// the IR may have changed in any way
priv fn sk_forget() {
    sk_gen += 1
}

// the passes that are clean now, as a bit set
priv fn sk_save() -> i64 {
    bits := 0
    for k in 0..16 {
        if sk_clean[k] == sk_gen + 1 {
            bits |= 1 << k
        }
    }
    return bits
}

priv fn sk_restore(bits: i64) {
    sk_forget()
    for k in 0..16 {
        if bits & (1 << k) != 0 {
            sk_clean[k] = sk_gen + 1
        }
    }
}

priv fn local_opt(f: *Func, level: i64) {
    opt_trace("local_opt", f)
    opt_pass(PASS_PRUNE, f, cleanup_prune_unreachable)
    opt_pass(PASS_MEM2REG, f, mem2reg_run)
    opt_pass(PASS_DCE, f, cleanup_dce)
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
        if opt_enabled("gvn") && opt_pass(PASS_GVN, f, gvn_run) {
            ch = true
        }
        if opt_enabled("checkmerge") && opt_pass(PASS_CHECKMERGE, f, checkmerge_run) {
            ch = true
        }
        opt_trace("loadelim", f)
        if opt_enabled("loadelim") && opt_pass(PASS_LOADELIM, f, loadelim_run) {
            ch = true
        }
        opt_trace("mem2reg", f)
        if opt_pass(PASS_MEM2REG, f, mem2reg_run) {
            ch = true
        }
        opt_trace("licm", f)
        if opt_enabled("licm") && opt_pass(PASS_LICM, f, licm_run) {
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
        if !opt_enabled("unroll") {
            break
        }
        made := licm_preheaders_made()
        unrolled := unroll_run(f)
        // (preheaders change the function without being reported)
        if unrolled || licm_preheaders_made() != made {
            sk_forget()
        }
        if !unrolled {
            break
        }
        opt_trace("after-unroll", f)
        dbg, has_dbg := env_get("ALC_DEBUG")
        if has_dbg && dbg == "unroll" {
            eput(fmt("after unroll:\n", ir_print_func(f, None), "\n"))
        }
        for it2 in 0..3 {
            ch := false
            if simplify_run(f) {
                ch = true
            }
            if opt_enabled("gvn") && opt_pass(PASS_GVN, f, gvn_run) {
                ch = true
            }
            if opt_enabled("checkmerge") && opt_pass(PASS_CHECKMERGE, f, checkmerge_run) {
                ch = true
            }
            if opt_enabled("loadelim") && opt_pass(PASS_LOADELIM, f, loadelim_run) {
                ch = true
            }
            if opt_pass(PASS_MEM2REG, f, mem2reg_run) {
                ch = true
            }
            if opt_enabled("licm") && opt_pass(PASS_LICM, f, licm_run) {
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
        if !opt_enabled("bce") {
            break
        }
        made := licm_preheaders_made()
        hoisted := bce_run(f)
        if hoisted || licm_preheaders_made() != made {
            sk_forget()
        }
        if !hoisted {
            break
        }
        opt_trace("after-bce", f)
        opt_pass(PASS_GVN, f, gvn_run)
        if opt_enabled("checkmerge") {
            opt_pass(PASS_CHECKMERGE, f, checkmerge_run)
        }
        opt_trace("after-bce-gvn", f)
        simplify_run(f)
        opt_pass(PASS_LICM, f, licm_run)
        simplify_run(f)
    }
    opt_pass(PASS_DCE, f, cleanup_dce)
    opt_trace("end-local-opt", f)
}

// first_done[fid]: opt_first has run for the function; clean_at[fid]: the passes that are clean
// (see opt_pass) at its end (the function does not change until its local_opt)
priv first_done: Vec[bool]
priv clean_at: Vec[i64]
// clean_end[fid]: the passes that are clean when the optimisation of the function is over (it
// does not change until the back end compiles it; one module per run of the compiler)
priv clean_end: Vec[i64]

// The cleanups the back end runs first (prune, trivial phis, DCE), each skipped where the
// optimiser left the function clean for it.
fn opt_backend_cleanup(f: *Func, fid: i64) {
    bits := 0
    if fid < clean_end.len {
        bits = clean_end[fid]
    }
    sk_restore(bits)
    opt_pass(PASS_PRUNE, f, cleanup_prune_unreachable)
    opt_pass(PASS_PHIS, f, cleanup_trivial_phis)
    opt_pass(PASS_DCE, f, cleanup_dce)
}

// The first part of the optimisation of one function, also callable right after the function
// is lowered (opt_optimize then skips it): prune, mem2reg, dce and, when optimising, simplify
// and tail recursion. It reads nothing of the module but the function (not the alias classes
// of loads and stores either) and makes no loads or stores.
fn opt_first(m: *Module, fid: i64, level: i64) {
    // (grown in the main arena, before work_begin)
    if first_done.len < m.funcs.len {
        first_done.resize(m.funcs.len, false)
        clean_at.resize(m.funcs.len, 0)
        clean_end.resize(m.funcs.len, 0)
    }
    f := &m.funcs[fid]
    if !f.lowered || first_done[fid] {
        return
    }
    first_done[fid] = true
    work_begin()
    ir_memo_begin(f)
    // at -O0 only mem2reg adds instructions: keep the list in the main arena
    ir_insts_main = level == 0
    sk_forget()
    opt_pass(PASS_PRUNE, f, cleanup_prune_unreachable)
    opt_pass(PASS_MEM2REG, f, mem2reg_run)
    opt_pass(PASS_DCE, f, cleanup_dce)
    if level > 0 {
        simplify_run(f)
        if opt_enabled("tre") && tre_run(f, fid) {
            sk_forget()
            opt_trace("after-tre", f)
            simplify_run(f)
        }
        clean_at[fid] = sk_save()
    } else {
        clean_end[fid] = sk_save()
    }
    // keep the function, drop the passes' temporary data (see work_begin in base.al)
    ir_memo_end()
    work_end()
    ir_insts_main = false
    keep_func(f)
}

fn opt_optimize(m: *Module, level: i64) {
    n := m.funcs.len
    check_fail = vec_fill(n, false)
    for fid in 0..n {
        nm := m.funcs[fid].name
        check_fail[fid] = nm == "__bounds_fail" || nm == "__div_fail" || nm == "__step_fail"
    }
    for fid in 0..n {
        opt_first(m, fid, level)
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
            for v in f.blocks[bi].insts {
                i := &f.insts[v]
                if i.op == Call {
                    call_counts[i.k] += 1
                    callees[fi].push(i.k)
                } else if i.op == FAddr {
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
    costs := vec_fill(n, -1)
    for fid in order {
        if m.funcs[fid].lowered {
            work_begin()
            ir_memo_begin(&m.funcs[fid])
            sk_restore(clean_at[fid])
            local_opt(&m.funcs[fid], level)
            if inline_run(m, fid, done.items(), call_counts.items(), addr_taken.items(), &pol, costs.items()) {
                sk_forget()
                opt_trace("after-inline", &m.funcs[fid])
                local_opt(&m.funcs[fid], level)
            }
            ir_memo_end()
            work_end()
            clean_end[fid] = sk_save()
            keep_func(&m.funcs[fid])
        }
        done[fid] = true
    }
}
