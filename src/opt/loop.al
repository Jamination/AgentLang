// Loop analysis shared by the loop passes (runtime unrolling, loop idioms, LICM's scalar
// promotion; also meant for a loop vectorizer): counted loops, their trip counts, invariance,
// affine address expressions, reductions, copying a loop's blocks, splitting edges.
//
// The loops these helpers describe are the rotated ("do-while") loops the lowering makes of
// `for` and `while` after mem2reg and simplify:
//
//     pre:    ...                       (the preheader: the only way in, ends in `jmp header`)
//             jmp header
//     header: iv = phi [pre: start] [latch: next]
//             ...body (any number of blocks)...
//     latch:  next = iv + step          (step a constant)
//             c = next < end            (end loop-invariant; any integer comparison)
//             br c header exit
//
// The body runs at least once when the preheader is reached (the lowering guards the loop
// with the entry test before the preheader).

// Inst.aux bits on a loop's latch condition (a comparison, whose aux is otherwise unused):
// a loop that runtime unrolling made (main or remainder loop) or that the idiom pass kept as
// the slow path of a fill or copy. The passes would otherwise transform their own output
// again on the next run of the pipeline (local_opt runs again after inlining).
const LOOP_NO_UNROLL = 1
const LOOP_NO_IDIOM = 2

// A counted loop (loop_counted).
struct CLoop {
    li: i64          // the loop in Loops
    header: i64
    latch: i64       // the only latch; it ends in `br cond`
    pre: i64         // the preheader: the only predecessor outside the loop, one successor
    exit: i64        // the latch's successor outside the loop
    cond: i64        // the latch's condition
    back_true: bool  // the latch goes back to the header when cond is true
    iv: i64          // the counter: a header phi
    next: i64        // iv + step: the counter's input from the latch
    step: i64        // a constant, not 0
    start: i64       // the counter's input from the preheader
    end: i64         // loop-invariant
    cmp: Op          // the loop goes on while cmp(next, end) (normalised: back on true, next first)
    ty: T            // the counter's type
    blocks: Vec[i64] // the loop's blocks in reverse postorder (header first)
}

// v is not defined in the loop whose blocks in_loop marks (def_block: the block of every
// instruction, NOV for none)
fn loop_invariant(v: i64, in_loop: []bool, def_block: []i32) -> bool {
    db := def_block[v]
    return db == NOV || !in_loop[db]
}

// is v defined in the loop (an instruction of one of its blocks)?
inline fn loop_defined(v: i64, in_loop: []bool, def_block: []i32) -> bool {
    return v < len(def_block) && def_block[v] != NOV && in_loop[def_block[v]]
}

// Does loop li have no loop nested in it?
fn loop_innermost(loops: *Loops, li: i64) -> bool {
    for k in 0..loops.loops.len {
        match loops.loops[k].parent {
            Some(p) => {
                if p == li {
                    return false
                }
            }
            None => {}
        }
    }
    return true
}

// Recognises loop li as a counted loop (see CLoop). `in_loop` marks its blocks.
fn loop_counted(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block: []i32) -> Opt[CLoop] {
    l := &loops.loops[li]
    h := l.header
    if l.latches.len != 1 {
        return None
    }
    outside := licm_outside_preds(cfg, loops, li, h)
    if outside.len != 1 {
        return None
    }
    pre := outside[0]
    if f.blocks[pre].term != Jmp(h) {
        return None
    }
    latch := l.latches[0]
    c, t, e := match f.blocks[latch].term {
        Br(c0, t0, e0) => (c0, t0, e0)
        _ => return None
    }
    back_true, exit_b := if t == h && !in_loop[e] {
        (true, e)
    } else if e == h && !in_loop[t] {
        (false, t)
    } else {
        return None
    }
    ci := &f.insts[c]
    if !ci.op.is_icmp() || ci.args.len != 2 {
        return None
    }
    op := ci.op
    a := ci.args[0]
    b := ci.args[1]
    if loop_invariant(a, in_loop, def_block) && !loop_invariant(b, in_loop, def_block) {
        op = op.swap_cmp()
        x := a
        a = b
        b = x
    }
    if !loop_invariant(b, in_loop, def_block) {
        return None
    }
    if !back_true {
        op = op.negate_icmp()
    }
    next := a
    ni := &f.insts[next]
    if ni.op != Add || def_block[next] == NOV || !in_loop[def_block[next]] {
        return None
    }
    step := match f.is_const(ni.args[1]) {
        Some(k) => k
        None => return None
    }
    iv := ni.args[0]
    pi := &f.insts[iv]
    if step == 0 || pi.op != Phi || i64(def_block[iv]) != h || pi.args.len != 2 {
        return None
    }
    start := pi.phi_input(pre)
    if start == NOV || pi.phi_input(latch) != next {
        return None
    }
    // the blocks in reverse postorder
    bl := vec[i64]()
    for x in l.blocks {
        bl.push(i64(cfg.rpo_idx[x]))
    }
    sort(bl.items())
    for k in 0..bl.len {
        bl[k] = cfg.rpo[bl[k]]
    }
    return Some(CLoop{li: li, header: h, latch: latch, pre: pre, exit: exit_b, cond: c, back_true: back_true, iv: iv, next: next, step: step, start: start, end: b, cmp: op, ty: pi.ty, blocks: bl})
}

// Can the loop be left only through its latch (to cl.exit) or into a check's failure block
// (opt_is_check_trap) that uses no value of the loop? Loops with such side exits can be copied
// (each copy branches to the same failure blocks) as long as the order of the checks within
// each iteration is kept. Also false for a loop block that returns or traps itself.
fn loop_exits_simple(f: *Func, cl: *CLoop, in_loop: []bool, def_block: []i32) -> bool {
    for b in cl.blocks {
        match f.blocks[b].term {
            Jmp(_), Br(_, _, _) => {}
            _ => return false
        }
        ns, s0, s1 := f.succ_pair(b)
        for k in 0..ns {
            s := if k == 0 { s0 } else { s1 }
            if in_loop[s] || (b == cl.latch && s == cl.exit) {
                continue
            }
            if !opt_is_check_trap(f, s) {
                return false
            }
            for v in f.blocks[s].insts {
                for x in f.insts[v].args {
                    if loop_defined(x, in_loop, def_block) {
                        return false
                    }
                }
            }
        }
    }
    return true
}

// Has the loop no exit but its latch's (no check failure blocks either)?
fn loop_single_exit(f: *Func, cl: *CLoop, in_loop: []bool) -> bool {
    for b in cl.blocks {
        ns, s0, s1 := f.succ_pair(b)
        for k in 0..ns {
            s := if k == 0 { s0 } else { s1 }
            if !in_loop[s] && !(b == cl.latch && s == cl.exit) {
                return false
            }
        }
        match f.blocks[b].term {
            Jmp(_), Br(_, _, _) => {}
            _ => return false
        }
    }
    return true
}

// Does the loop call anything or have another effect on memory than plain loads and stores
// (bulk copies, atomics, system calls)?
fn loop_has_call(f: *Func, cl: *CLoop) -> bool {
    for b in cl.blocks {
        for v in f.blocks[b].insts {
            if f.insts[v].op.clobbers() {
                return true
            }
        }
    }
    return false
}

// the number of instructions of the loop (phis included) plus its terminators
fn loop_size(f: *Func, cl: *CLoop) -> i64 {
    n := 0
    for b in cl.blocks {
        n += f.blocks[b].insts.len + 1
    }
    return n
}

// The values defined in the loop that something outside it uses (a phi input from a loop
// block included), in instruction order without repeats.
fn loop_used_outside(f: *Func, in_loop: []bool, def_block: []i32) -> Vec[i64] {
    seen := map[i64, bool]()
    out := vec[i64]()
    for b in 0..f.blocks.len {
        if in_loop[b] {
            continue
        }
        for v in f.blocks[b].insts {
            for x in f.insts[v].args {
                if loop_defined(x, in_loop, def_block) && !seen.has(x) {
                    seen.set(x, true)
                    out.push(x)
                }
            }
        }
        for x in term_args(&f.blocks[b].term) {
            if loop_defined(x, in_loop, def_block) && !seen.has(x) {
                seen.set(x, true)
                out.push(x)
            }
        }
    }
    sort(out.items())
    return out
}

// The number of iterations is known at compile time (start and end constants): Some(trip),
// for step +-1 only (other loops: None)
fn loop_const_trip(f: *Func, cl: *CLoop) -> Opt[i64] {
    if !loop_trip_known(cl) {
        return None
    }
    s := match f.is_const(cl.start) {
        Some(k) => k
        None => return None
    }
    e := match f.is_const(cl.end) {
        Some(k) => k
        None => return None
    }
    match simplify_fold_icmp(cl.cmp, cl.ty, s, e) {
        Some(true) => {}
        Some(false) => return Some(1)
        None => return None
    }
    d := if cl.step > 0 { u64(e) - u64(s) } else { u64(s) - u64(e) }
    d = d & loop_mask(cl.ty)
    if d >= u64(1) << 62 {
        return None
    }
    return Some(i64(d))
}

// the bits of a value of type ty (as an unsigned mask)
priv fn loop_mask(ty: T) -> u64 {
    return if ty.bits() >= 64 { 0xFFFF_FFFF_FFFF_FFFF } else { (u64(1) << u64(ty.bits())) - 1 }
}

// Is the trip count of the loop computable by loop_trip_count? Loops counting by 1 up to
// `end` (exclusive, signed or unsigned, or `!=`) or by -1 down to it (exclusive).
fn loop_trip_known(cl: *CLoop) -> bool {
    return cl.step == 1 && (cl.cmp == Slt || cl.cmp == Ult || cl.cmp == Ne) || cl.step == -1 && (cl.cmp == Sgt || cl.cmp == Ugt || cl.cmp == Ne)
}

// Appends to block b the condition under which loop_trip_count is the number of iterations
// (an i8 0 / 1): `start cmp end` for a counter that must not wrap around (signed or
// unsigned `<` / `>`), `start != end` for `!=`. When it is false the loop runs once (the body
// is entered whenever the preheader is reached; for `!=` with start == end it would run
// 2^bits times). Only for loop_trip_known loops.
fn loop_trip_guard(f: *Func, cl: *CLoop, b: i64) -> i64 {
    return f.push(b, cl.cmp, I8, vec_of([]i64{cl.start, cl.end}), 0)
}

// Appends to block b the number of iterations of the loop (when loop_trip_guard holds), an
// unsigned number of the counter's type: end - start counting up, start - end counting down.
// Only for loop_trip_known loops.
fn loop_trip_count(f: *Func, cl: *CLoop, b: i64) -> i64 {
    if cl.step > 0 {
        return f.push(b, Sub, cl.ty, vec_of([]i64{cl.end, cl.start}), 0)
    }
    return f.push(b, Sub, cl.ty, vec_of([]i64{cl.start, cl.end}), 0)
}

// a constant of type ty in block b (appended)
fn loop_const(f: *Func, b: i64, ty: T, k: i64) -> i64 {
    return f.push(b, Const, ty, vec[i64](), ir_canon(ty, k))
}

// The coefficient of the counter in v, when v (an i64 value: an address or offset) is affine
// in it: v = c * iv + (invariant), exactly in 64-bit wrapping arithmetic over the iterations
// of the loop. Made of Add, Sub, Mul and Shl by constants, and the counter itself (or its
// sign / zero extension when the loop's comparison is signed / unsigned and it counts by 1,
// so that the narrow counter never wraps between two iterations). None when v is not so.
fn loop_affine_coef(f: *Func, cl: *CLoop, v: i64, in_loop: []bool, def_block: []i32) -> Opt[i64] {
    return affine_rec(f, cl, v, in_loop, def_block, 0)
}

priv fn affine_rec(f: *Func, cl: *CLoop, v: i64, in_loop: []bool, def_block: []i32, depth: i64) -> Opt[i64] {
    if loop_invariant(v, in_loop, def_block) {
        return Some(0)
    }
    if depth > 16 {
        return None
    }
    i := &f.insts[v]
    if v == cl.iv {
        return if cl.ty == I64 { Some(1) } else { None }
    }
    match i.op {
        SExt, ZExt => {
            if i.ty == I64 && i.args[0] == cl.iv && (cl.step == 1 || cl.step == -1) {
                signed := cl.cmp == Slt || cl.cmp == Sgt
                unsigned := cl.cmp == Ult || cl.cmp == Ugt
                if i.op == SExt && signed || i.op == ZExt && unsigned {
                    return Some(1)
                }
            }
            return None
        }
        Add, Sub => {
            if i.ty != I64 {
                return None
            }
            a := match affine_rec(f, cl, i.args[0], in_loop, def_block, depth + 1) {
                Some(k) => k
                None => return None
            }
            b := match affine_rec(f, cl, i.args[1], in_loop, def_block, depth + 1) {
                Some(k) => k
                None => return None
            }
            return Some(if i.op == Add { a + b } else { a - b })
        }
        Mul => {
            if i.ty != I64 {
                return None
            }
            for k in 0..2 {
                match f.is_const(i.args[1 - k]) {
                    Some(m) => {
                        return match affine_rec(f, cl, i.args[k], in_loop, def_block, depth + 1) {
                            Some(c) => Some(c * m)
                            None => None
                        }
                    }
                    None => {}
                }
            }
            return None
        }
        Shl => {
            if i.ty != I64 {
                return None
            }
            match f.is_const(i.args[1]) {
                Some(s) => {
                    if s < 0 || s > 32 {
                        return None
                    }
                    return match affine_rec(f, cl, i.args[0], in_loop, def_block, depth + 1) {
                        Some(c) => Some(c << s)
                        None => None
                    }
                }
                None => return None
            }
        }
        _ => return None
    }
}

// Rebuilds the loop-dependent part of the pure expression v (see loop_affine_coef) at the end
// of block b with the counter replaced by `at` (a value of the counter's type available in
// b): the value v has in the iteration where the counter is `at`.
fn loop_expr_at(f: *Func, cl: *CLoop, b: i64, v: i64, at: i64, in_loop: []bool, def_block: []i32) -> i64 {
    if loop_invariant(v, in_loop, def_block) {
        return v
    }
    if v == cl.iv {
        return at
    }
    src := f.insts[v]
    nargs := src.args.len
    args := vec[i64]()
    for k in 0..nargs {
        args.push(loop_expr_at(f, cl, b, f.insts[v].args[k], at, in_loop, def_block))
    }
    nv := f.push(b, src.op, src.ty, args, src.k)
    return nv
}

// ---------- copying a loop ----------

// Copies the blocks `blocks` (a loop's, or part of one) into new blocks with new instructions.
// `vmap` maps original values to their copies: entries set before the call (for example a
// header phi to the value it has in the copy, an iteration of an unrolled loop) are taken as
// they are and those instructions are not copied; all other instructions of the blocks get a
// copy and an entry. In the copies, arguments, phi inputs and terminator operands with an
// entry are replaced, and every successor or phi input block among `blocks` becomes its copy
// (the others stay: the copy of a loop's latch still branches to the original exit, and the
// copy of its header's phis still has the original preheader as a predecessor; callers
// rewire those). Returns the map of blocks to their copies. (-g: the source locations of the
// copied code are marked as copied, see Func.dtaint.)
fn loop_clone_blocks(f: *Func, blocks: []i64, vmap: *IMap) -> IMap {
    // the copies made here are numbered from n_before on; entries set by the caller are older
    n_before := f.insts.len
    bmap := imap_new(len(blocks))
    for b in blocks {
        bmap.iset(b, f.new_block())
    }
    // allocate the copies first (a phi may use a value defined further down)
    for b in blocks {
        for ii in 0..f.blocks[b].insts.len {
            v := i64(f.blocks[b].insts[ii])
            if vmap.iget(v) >= 0 {
                continue
            }
            src := f.insts[v]
            nv := f.mk(src.op, src.ty, vec[i64](), src.k)
            f.im(nv).aux = src.aux
            f.im(nv).set_srcloc(src.srcloc())
            if f.dexp.len > 0 && src.srcloc() > 0 {
                f.dtaint.push(src.srcloc())
            }
            vmap.iset(v, nv)
        }
    }
    for b in blocks {
        nb := bmap.iget(b)
        n := f.blocks[b].insts.len
        for ii in 0..n {
            v := i64(f.blocks[b].insts[ii])
            nv := vmap.iget(v)
            // (an entry made before the call: not a copy of v)
            if nv < n_before {
                continue
            }
            nargs := f.insts[v].args.len
            args := mkslice[i64](__alloc_raw(nargs * 8), nargs)
            for ai in 0..nargs {
                args[ai] = loop_map_val(vmap, f.insts[v].args[ai])
            }
            if f.insts[v].op == Phi {
                pb := mkslice[i64](__alloc_raw(nargs * 8), nargs)
                vfrom := f.insts[v].from()
                for ai in 0..nargs {
                    pb[ai] = loop_map_blk(&bmap, vfrom[ai])
                }
                f.im(nv).phi_set(args, pb)
            } else {
                f.im(nv).args = args
            }
            f.blocks[nb].insts.push(i32(nv))
        }
        // (loops with other terminators are not copied: see loop_exits_simple)
        f.blocks[nb].term = match f.blocks[b].term {
            Jmp(t) => Jmp(loop_map_blk(&bmap, t))
            Br(c, t, e) => Br(loop_map_val(vmap, c), loop_map_blk(&bmap, t), loop_map_blk(&bmap, e))
            _ => clone(f.blocks[b].term)
        }
    }
    return bmap
}

// the value v maps to (v itself without an entry)
inline fn loop_map_val(vmap: *IMap, v: i64) -> i64 {
    x := vmap.iget(v)
    return if x >= 0 { x } else { v }
}

// the block b maps to (b itself without an entry)
inline fn loop_map_blk(bmap: *IMap, b: i64) -> i64 {
    x := bmap.iget(b)
    return if x >= 0 { x } else { b }
}

// ---------- a main loop and a remainder loop ----------
// The frame that runtime unrolling fills in (and that a vectorizer can): counted loop cl
// (loop_trip_known, loop_exits_simple) becomes a main loop that runs whole groups of u
// iterations and, after it, a copy of the original loop that runs the rest:
//
//     pre:   g = start cmp end (loop_trip_guard), tc, ue = start +- (tc & -u),
//            has_rem = (tc & (u-1)) != 0;  br g chk rpre
//     chk:   br tc >=u u header rpre
//     header..: the main loop (the caller's: it steps the counter by u and its last latch
//            branches back to the header while the counter is not ue, else to mid)
//     mid:   (the caller's instructions: partial results combined);  br has_rem rpre x
//     rpre:  phis: each header phi's start value (from pre and chk) or its value after the
//            main loop (from mid);  jmp rh
//     rh..rl: the remainder, a copy of the original loop (marked LOOP_NO_UNROLL); rl -> x
//     x:     phis of the values used after the loop (from rl or mid);  jmp exit
//
// loop_remainder_begin builds everything but the main loop's latch and mid's contents;
// loop_remainder_end, once the caller knows the value each loop value has after the main
// loop, fills in rpre, x and the uses after the loop. Between the two the main loop's header
// phis still have their inputs from chk (the start values) and from the original latch.
struct Remainder {
    u: i64
    chk: i64
    mid: i64
    rpre: i64
    x: i64
    rh: i64          // the remainder's header
    rl: i64          // the remainder's latch
    rv: IMap         // the loop's values -> their copies in the remainder
    ue: i64          // the counter's value where the main loop stops (in pre)
    has_rem: i64     // an i8 in pre: there are iterations left for the remainder
    hphis: Vec[i64]  // the header phis of the loop
    starts: Vec[i64] // their inputs from the preheader
    backs: Vec[i64]  // their inputs from the original latch
    nb0: i64         // the number of blocks before
}

fn loop_remainder_begin(f: *Func, cl: *CLoop, u: i64) -> Remainder {
    nb0 := f.blocks.len
    h := cl.header
    pre := cl.pre
    ty := cl.ty
    hphis := vec[i64]()
    starts := vec[i64]()
    backs := vec[i64]()
    for v in f.blocks[h].insts {
        if f.insts[v].op != Phi {
            break
        }
        hphis.push(i64(v))
        starts.push(f.insts[v].phi_input(pre))
        backs.push(f.insts[v].phi_input(cl.latch))
    }
    rv := imap_new(64)
    rb := loop_clone_blocks(f, cl.blocks.items(), &rv)
    rh := rb.iget(h)
    rl := rb.iget(cl.latch)
    // the tests in the preheader and in a block after it (two branches rather than an `and`
    // of the conditions: the first is often known and folds away)
    g := loop_trip_guard(f, cl, pre)
    tc := loop_trip_count(f, cl, pre)
    chk := f.new_block()
    big := f.push(chk, Uge, I8, vec_of([]i64{tc, loop_const(f, chk, ty, u)}), 0)
    m := f.push(pre, And, ty, vec_of([]i64{tc, loop_const(f, pre, ty, -u)}), 0)
    ue := f.push(pre, if cl.step > 0 { Add } else { Sub }, ty, vec_of([]i64{cl.start, m}), 0)
    rem := f.push(pre, And, ty, vec_of([]i64{tc, loop_const(f, pre, ty, u - 1)}), 0)
    has_rem := f.push(pre, Ne, I8, vec_of([]i64{rem, loop_const(f, pre, ty, 0)}), 0)
    mid := f.new_block()
    rpre := f.new_block()
    x := f.new_block()
    f.blocks[pre].term = Br(g, chk, rpre)
    f.blocks[chk].term = Br(big, h, rpre)
    f.phi_pred_replace(h, pre, chk)
    f.blocks[rpre].term = Jmp(rh)
    f.blocks[x].term = Jmp(cl.exit)
    f.retarget(rl, cl.exit, x)
    rc := rv.iget(cl.cond)
    f.im(rc).aux = f.insts[rc].aux | LOOP_NO_UNROLL
    return Remainder{u: u, chk: chk, mid: mid, rpre: rpre, x: x, rh: rh, rl: rl, rv: rv, ue: ue, has_rem: has_rem, hphis: hphis, starts: starts, backs: backs, nb0: nb0}
}

// the value v has after the main loop: fin's entry, else v itself (a value from outside)
priv fn rem_final(fin: *IMap, v: i64, in_loop: []bool, def_block: []i32) -> i64 {
    x := fin.iget(v)
    if x >= 0 {
        return x
    }
    assert !loop_defined(v, in_loop, def_block), "loop: no value after the main loop"
    return v
}

// Completes the frame of loop_remainder_begin: `fin` maps the loop's values to the values they
// have in mid after the main loop (every header phi's back-edge input and every value of
// `outside`, loop_used_outside, that is defined in the loop). in_loop and def_block describe
// the original loop as before loop_remainder_begin.
fn loop_remainder_end(f: *Func, cl: *CLoop, rem: *Remainder, fin: *IMap, outside: []i64, in_loop: []bool, def_block: []i32) {
    f.blocks[rem.mid].term = Br(rem.has_rem, rem.rpre, rem.x)
    // rpre: where the remainder starts from
    for pi in 0..rem.hphis.len {
        ph := rem.hphis[pi]
        st := rem.starts[pi]
        sp := f.mk_phi_of(f.insts[ph].ty, []i64{st, st, rem_final(fin, rem.backs[pi], in_loop, def_block)}, []i64{cl.pre, rem.chk, rem.mid})
        f.blocks[rem.rpre].insts.push(i32(sp))
        ri := f.im(rem.rv.iget(ph))
        rfrom := ri.from()
        for k in 0..rfrom.len {
            if rfrom[k] == cl.pre {
                rfrom[k] = rem.rpre
                ri.args[k] = sp
            }
        }
    }
    // x: the values used after the loop
    xmap := imap_new(len(outside))
    for v in outside {
        xp := f.mk_phi_of(f.insts[v].ty, []i64{loop_map_val(&rem.rv, v), rem_final(fin, v, in_loop, def_block)}, []i64{rem.rl, rem.mid})
        f.blocks[rem.x].insts.push(i32(xp))
        xmap.iset(v, xp)
    }
    f.phi_pred_replace(cl.exit, cl.latch, rem.x)
    if len(outside) == 0 {
        return
    }
    // uses after the loop see x's phis (only the latch leaves to them: loop_exits_simple)
    for b in 0..rem.nb0 {
        if in_loop[b] {
            continue
        }
        for v in f.blocks[b].insts {
            args := f.insts[v].args
            for ai in 0..args.len {
                if loop_defined(args[ai], in_loop, def_block) {
                    args[ai] = loop_map_val(&xmap, args[ai])
                }
            }
        }
        match f.blocks[b].term {
            Br(&c, _, _) => {
                if loop_defined(*c, in_loop, def_block) {
                    *c = loop_map_val(&xmap, *c)
                }
            }
            Ret(vs) => {
                for k in 0..vs.len {
                    if loop_defined(vs[k], in_loop, def_block) {
                        vs[k] = loop_map_val(&xmap, vs[k])
                    }
                }
            }
            _ => {}
        }
    }
    // (-g: the variables that had those values are not shown after the loop)
    if f.dexp.len > 0 {
        forget := vec_fill(f.insts.len, i32(NOV))
        for v in outside {
            forget[v] = i32(xmap.iget(v))
        }
        dbg_forget(f, &forget)
    }
}

// ---------- edges ----------

// Puts a new empty block on the edge from -> to (both arms of a branch to `to` included) and
// returns it; the phis of `to` take their inputs from it.
fn loop_split_edge(f: *Func, from: i64, to: i64) -> i64 {
    nb := f.new_block()
    f.blocks[nb].term = Jmp(to)
    f.retarget(from, to, nb)
    f.phi_pred_replace(to, from, nb)
    return nb
}

// ---------- reductions ----------
// A header phi `s` whose every value in the loop is s (op) d, with d independent of s and op
// associative and commutative: the loop can keep several partial results (each starting at
// the identity) and combine them after it, in any order. Integer arithmetic wraps, so this
// is exact for +, *, &, |, ^, min and max; floating-point reductions are never reported (the
// order of IEEE additions must stay as written).
const RED_ADD = 1
const RED_MUL = 2
const RED_AND = 3
const RED_OR = 4
const RED_XOR = 5
const RED_SMIN = 6
const RED_SMAX = 7
const RED_UMIN = 8
const RED_UMAX = 9

struct Reduction {
    phi: i64  // the header phi
    back: i64 // its input from the latch: the result of an iteration
    kind: i64 // RED_*
}

// The kind of reduction for operation op (Sub counts as +: s - d = s + (-d)), 0 if none.
priv fn red_kind_of(op: Op) -> i64 {
    return match op {
        Add, Sub => RED_ADD
        Mul => RED_MUL
        And => RED_AND
        Or => RED_OR
        Xor => RED_XOR
        _ => 0
    }
}

// min / max: cmp(a, b) ? a : b with cmp normalised to the order (a, b)
priv fn red_minmax_kind(cmp: Op) -> i64 {
    return match cmp {
        Slt, Sle => RED_SMIN
        Sgt, Sge => RED_SMAX
        Ult, Ule => RED_UMIN
        Ugt, Uge => RED_UMAX
        _ => 0
    }
}

// Recognises header phi `phi` of loop cl as a reduction (see above). `outside`: the loop's
// values used outside it (loop_used_outside); only the iteration's result may be among them.
// Every instruction that depends on the phi in the loop must be a step of the reduction: an
// operation of its kind with exactly one operand that depends on the phi, a select or phi
// between such values on a condition that does not depend on it, or for min / max the
// compare-and-select pair. Nothing else (a store, a branch, another phi of the header) may
// see the partial values.
fn loop_reduction(f: *Func, cl: *CLoop, phi: i64, in_loop: []bool, def_block: []i32, outside: []i64) -> Opt[Reduction] {
    pi := &f.insts[phi]
    if pi.op != Phi || phi == cl.iv || !pi.ty.is_int() || pi.args.len != 2 {
        return None
    }
    ty := pi.ty
    back := pi.phi_input(cl.latch)
    if back == NOV || back == phi || !loop_defined(back, in_loop, def_block) || contains(outside, phi) {
        return None
    }
    // dep: the loop's values that depend on the phi (the blocks are in reverse postorder and
    // the only back edge is the latch's: one pass finds them all)
    dep := map[i64, bool]()
    dep.set(phi, true)
    members := vec[i64]()
    for b in cl.blocks {
        for v in f.blocks[b].insts {
            if i64(v) == phi {
                continue
            }
            for a in f.insts[v].args {
                if dep.has(a) {
                    if b == cl.header && f.insts[v].op == Phi {
                        // another header phi carries a partial value into the next iteration
                        return None
                    }
                    dep.set(i64(v), true)
                    members.push(i64(v))
                    break
                }
            }
        }
        for x in term_args(&f.blocks[b].term) {
            if dep.has(x) {
                return None
            }
        }
    }
    if !dep.has(back) {
        return None
    }
    // uses of the partial values inside the loop
    uses := map[i64, i64]()
    for b in cl.blocks {
        for v in f.blocks[b].insts {
            for a in f.insts[v].args {
                if dep.has(a) {
                    uses.set(a, uses.get_or(a, 0) + 1)
                }
            }
        }
    }
    kind := 0
    conds := map[i64, bool]()
    for m in members {
        if m != back && contains(outside, m) {
            return None
        }
        i := &f.insts[m]
        k := 0
        if i.op.is_icmp() {
            // the condition of a min / max select (checked there), used by it alone
            if uses.get_or(m, 0) != 1 {
                return None
            }
            continue
        }
        if i.ty != ty {
            return None
        }
        match i.op {
            Add, Sub, Mul, And, Or, Xor => {
                d0 := dep.has(i.args[0])
                d1 := dep.has(i.args[1])
                if d0 == d1 || i.op == Sub && !d0 {
                    return None
                }
                k = red_kind_of(i.op)
            }
            Select => {
                c := i.args[0]
                a := i.args[1]
                bb := i.args[2]
                if dep.has(c) {
                    // min / max: cmp(x, y) ? x : y, one of x, y from the reduction
                    ci := &f.insts[c]
                    if !ci.op.is_icmp() {
                        return None
                    }
                    nc := if ci.args[0] == a && ci.args[1] == bb {
                        ci.op
                    } else if ci.args[0] == bb && ci.args[1] == a {
                        ci.op.swap_cmp()
                    } else {
                        return None
                    }
                    if dep.has(a) == dep.has(bb) {
                        return None
                    }
                    k = red_minmax_kind(nc)
                    if k == 0 {
                        return None
                    }
                    conds.set(c, true)
                } else if !dep.has(a) || !dep.has(bb) {
                    return None
                }
            }
            Phi => {
                // a join inside the body: every input is a partial value
                for a in i.args {
                    if !dep.has(a) {
                        return None
                    }
                }
            }
            _ => return None
        }
        if k != 0 {
            if kind != 0 && kind != k {
                return None
            }
            kind = k
        }
    }
    // a compare among the partial values is only the condition of a min / max select
    for m in members {
        if f.insts[m].op.is_icmp() && !conds.has(m) {
            return None
        }
    }
    if kind == 0 {
        return None
    }
    return Some(Reduction{phi: phi, back: back, kind: kind})
}

// Appends to block b the value a partial result starts from: the identity of the operation
// (for min and max the phi's start value `start`, which may be counted more than once).
fn loop_red_init(f: *Func, b: i64, r: *Reduction, start: i64) -> i64 {
    ty := f.insts[r.phi].ty
    return match r.kind {
        RED_ADD, RED_OR, RED_XOR => loop_const(f, b, ty, 0)
        RED_MUL => loop_const(f, b, ty, 1)
        RED_AND => loop_const(f, b, ty, -1)
        _ => start
    }
}

// Appends to block b the combination of two partial results x and y of reduction r.
fn loop_red_combine(f: *Func, b: i64, r: *Reduction, x: i64, y: i64) -> i64 {
    ty := f.insts[r.phi].ty
    op := match r.kind {
        RED_ADD => Add
        RED_MUL => Mul
        RED_AND => And
        RED_OR => Or
        RED_XOR => Xor
        RED_SMIN => Slt
        RED_SMAX => Sgt
        RED_UMIN => Ult
        _ => Ugt
    }
    if r.kind >= RED_SMIN {
        c := f.push(b, op, I8, vec_of([]i64{x, y}), 0)
        return f.push(b, Select, ty, vec_of([]i64{c, x, y}), 0)
    }
    return f.push(b, op, ty, vec_of([]i64{x, y}), 0)
}

// ---------- the loop passes ----------

// Calls `try(f, cfg, loops, li, in_loop, def_block)` for the innermost loops of f (in_loop
// marks the blocks of loop li; def_block: the block of every instruction) after giving every
// loop a preheader. When `try` changes the function (it returns true) the analyses are made
// again and the loops not yet tried are tried; a loop `try` turned down is not tried again
// (its header keeps its number). At most 32 changes. True if `try` changed something.
fn loop_each_innermost(f: *Func, try: fn(*Func, *Cfg, *Loops, i64, []bool, []i32) -> bool) -> bool {
    changed := false
    skip := vec[bool]()
    rounds: for it in 0..32 {
        _, loops0 := cfg_loops(f)
        if loops0.loops.is_empty() {
            break
        }
        licm_make_preheaders(f)
        cfg, loops := cfg_loops(f)
        def_block := f.block_of()
        in_loop := vec_fill(f.blocks.len, false)
        skip.resize(f.blocks.len, false)
        for li in 0..loops.loops.len {
            h := loops.loops[li].header
            if skip[h] || !loop_innermost(&loops, li) {
                continue
            }
            loops.mark_blocks(li, in_loop.items(), true)
            done := try(f, &cfg, &loops, li, in_loop.items(), def_block.items())
            loops.mark_blocks(li, in_loop.items(), false)
            if done {
                changed = true
                continue rounds
            }
            skip[h] = true
        }
        break
    }
    return changed
}

// ---------- entry conditions ----------

// a and b are the same value: one instruction, or equal constants of one type
priv fn loop_same(f: *Func, a: i64, b: i64) -> bool {
    if a == b {
        return true
    }
    x := &f.insts[a]
    y := &f.insts[b]
    return x.op == Const && y.op == Const && x.ty == y.ty && x.k == y.k
}

// Is `a op b` (an integer comparison) known to hold whenever block `pre` runs? Constants are
// compared; otherwise a block on the only way to `pre` (through blocks with one predecessor)
// branches on that comparison, written either way round, or on its negation to the other arm.
fn loop_known_at(f: *Func, cfg: *Cfg, pre: i64, op: Op, a: i64, b: i64) -> bool {
    match (f.is_const(a), f.is_const(b)) {
        (Some(x), Some(y)) => {
            return simplify_fold_icmp(op, f.insts[a].ty, x, y) == Some(true)
        }
        _ => {}
    }
    blk := pre
    for depth in 0..16 {
        if cfg.preds[blk].len != 1 {
            return false
        }
        p := cfg.preds[blk][0]
        match f.blocks[p].term {
            Br(c, t, e) if t != e => {
                ci := &f.insts[c]
                if ci.op.is_icmp() && ci.args.len == 2 {
                    // the comparison that holds on the way to blk
                    o := if t == blk { ci.op } else { ci.op.negate_icmp() }
                    if o == op && loop_same(f, ci.args[0], a) && loop_same(f, ci.args[1], b) {
                        return true
                    }
                    if o.swap_cmp() == op && loop_same(f, ci.args[1], a) && loop_same(f, ci.args[0], b) {
                        return true
                    }
                }
            }
            _ => {}
        }
        blk = p
    }
    return false
}

// ---------- loop deletion ----------
// A counted loop that certainly ends (loop_trip_known), has no effect (pure instructions only:
// no loads, stores, calls or divisions) and whose values nothing after it uses is not run.
priv fn delete_try(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block: []i32) -> bool {
    cl := match loop_counted(f, cfg, loops, li, in_loop, def_block) {
        Some(c) => c
        None => return false
    }
    if !loop_trip_known(&cl) || !loop_single_exit(f, &cl, in_loop) {
        return false
    }
    for b in cl.blocks {
        for v in f.blocks[b].insts {
            o := f.insts[v].op
            if o != Phi && !o.is_pure() {
                return false
            }
        }
    }
    if loop_used_outside(f, in_loop, def_block).len > 0 {
        return false
    }
    f.blocks[cl.pre].term = Jmp(cl.exit)
    f.phi_pred_replace(cl.exit, cl.latch, cl.pre)
    cleanup_prune_unreachable(f)
    return true
}

// ---------- stepped exit tests ----------
// A loop with a constant step s > 1 (`for i in a..b by s`) is lowered so that its counter
// cannot wrap: it goes on while `cur < end && end - cur >u s` (`cur <= end && end - cur >=u s`
// for `..=`), cur the counter, next = cur + s. When the loop is entered only with
// `start < end` (`<=`), the first comparison holds on every iteration: the next value is
// taken only when it is below end. The test becomes `cur < end - s` (`<=`) when end - s
// cannot wrap (a signed counter starting at a constant at least MIN + s), else
// `end - cur >u s` alone. True if a test changed.
fn loop_stepped_exits(f: *Func) -> bool {
    cfg, loops := cfg_loops(f)
    if loops.loops.is_empty() {
        return false
    }
    def_block := f.block_of()
    changed := false
    for li in 0..loops.loops.len {
        l := &loops.loops[li]
        h := l.header
        if l.latches.len != 1 {
            continue
        }
        latch := l.latches[0]
        outside := licm_outside_preds(&cfg, &loops, li, h)
        if outside.len != 1 {
            continue
        }
        pre := outside[0]
        c, t, e := match f.blocks[latch].term {
            Br(c0, t0, e0) => (c0, t0, e0)
            _ => continue
        }
        if t != h || e == h || f.insts[c].op != And {
            continue
        }
        a0 := f.insts[c].args[0]
        a1 := f.insts[c].args[1]
        first, room := if f.insts[a0].op == Ugt || f.insts[a0].op == Uge { (a1, a0) } else { (a0, a1) }
        ri := &f.insts[room]
        fi := &f.insts[first]
        if ri.op != Ugt && ri.op != Uge || !fi.op.is_icmp() {
            continue
        }
        incl := ri.op == Uge
        dist := &f.insts[ri.args[0]]
        s := ri.args[1]
        sk := match f.is_const(s) {
            Some(k) => k
            None => continue
        }
        if dist.op != Sub || sk <= 0 {
            continue
        }
        end := dist.args[0]
        cur := dist.args[1]
        pi := &f.insts[cur]
        if pi.op != Phi || pi.args.len != 2 || !contains(&f.blocks[h].insts, i32(cur)) {
            continue
        }
        start := pi.phi_input(pre)
        next := pi.phi_input(latch)
        if start == NOV || next == NOV {
            continue
        }
        ni := &f.insts[next]
        if ni.op != Add || ni.args[0] != cur || ni.args[1] != s {
            continue
        }
        op := fi.op
        ok := if incl { op == Sle || op == Ule } else { op == Slt || op == Ult }
        if !ok || fi.args[0] != cur || !loop_same(f, fi.args[1], end) {
            continue
        }
        eb := def_block[end]
        if eb != NOV && loops.contains(li, i64(eb)) || !loop_known_at(f, &cfg, pre, op, start, end) {
            continue
        }
        ty := pi.ty
        signed := op == Slt || op == Sle
        sm := match f.is_const(start) {
            Some(k) => signed && ty == I64 && sk < 1 << 40 && k >= -9223372036854775807 + sk
            None => false
        }
        if sm {
            lim := f.push(pre, Sub, ty, vec_of([]i64{end, s}), 0)
            nc := f.push(latch, op, I8, vec_of([]i64{cur, lim}), 0)
            f.blocks[latch].term = Br(nc, t, e)
        } else {
            f.blocks[latch].term = Br(room, t, e)
        }
        changed = true
    }
    return changed
}

// The loop passes that run after bounds-check hoisting (local_opt in src/opt/mod.al): loop
// deletion, stepped exit tests, loop idioms, induction variables (src/opt/lsr.al), then runtime
// unrolling. True if one changed the
// function (it may have changed in any way: the change counter moves on, see opt_pass).
fn loop_opts(f: *Func) -> bool {
    made := licm_preheaders_made(f)
    ch := false
    if opt_enabled("ldelete") && loop_each_innermost(f, delete_try) {
        ch = true
    }
    if opt_enabled("stepexit") && loop_stepped_exits(f) {
        ch = true
    }
    if opt_enabled("idiom") && idiom_run(f) {
        ch = true
    }
    if opt_enabled("lsr") && lsr_run(f) {
        ch = true
    }
    if opt_enabled("rtunroll") && unroll_runtime(f) {
        ch = true
    }
    if ch || licm_preheaders_made(f) != made {
        f.w.gen += 1
    }
    return ch
}
