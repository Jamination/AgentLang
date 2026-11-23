// Multi-way branches in the optimiser (a step of simplify_cfg, see switch_simplify):
// - a Switch on a constant becomes a jump; cases that go to the default are dropped, a Switch
//   left with no case becomes a jump, with one a two-way branch (switch_fold);
// - a chain of equality tests of one value against constants (what `match` on integers and
//   enum tags and `if x == a {..} else if x == b {..}` become) becomes one Switch
//   (switch_form; at least SW_MIN_KEYS keys);
// - two range tests of one value against constants that together test an interval
//   (`c >= lo && c <= hi`, `c < lo || c > hi`) become one unsigned compare (switch_range);
// - a block that only branches again on a condition its predecessor already decided is
//   skipped (thread_known): `match` on a pointer to an enum tests for nil before every tag
//   test, and once those tests are gone the tag tests form a Switch.
// The back ends choose how a Switch is compiled (x86/isel.al, arm64/isel.al: jump table,
// bit tests, binary search).

const SW_MIN_KEYS = 3

// true if it changed something
fn switch_simplify(f: *Func) -> bool {
    changed := false
    for b in 0..f.blocks.len {
        if f.is_switch(b) && switch_fold(f, b) {
            changed = true
        }
    }
    if opt_enabled("threadknown") && thread_known(f) {
        changed = true
    }
    if opt_enabled("ranges") && switch_ranges(f) {
        changed = true
    }
    if opt_enabled("switch") && switch_form_all(f) {
        changed = true
    }
    return changed
}

// ---------- folding ----------
priv fn switch_fold(f: *Func, b: i64) -> bool {
    c, tab := match f.blocks[b].term {
        Switch(c1, t1) => (c1, t1)
        _ => return false
    }
    ci := &f.insts[c]
    if ci.op == Const {
        f.blocks[b].term = Jmp(sw_target_of(&tab, ci.k))
        return true
    }
    d := sw_default(&tab)
    n := sw_ncases(&tab)
    nt := sw_ntargets(&tab)
    used := vec_fill(nt, false)
    used[0] = true
    keep := 0
    for i in 0..n {
        if sw_case_target(&tab, i) != d {
            keep += 1
        }
        used[tab[1 + nt + 2 * i + 1]] = true
    }
    if keep == n && !used.contains(false) {
        return false
    }
    ks := vec[i64]()
    ts := vec[i64]()
    for i in 0..n {
        t := sw_case_target(&tab, i)
        if t != d {
            ks.push(sw_key(&tab, i))
            ts.push(t)
        }
    }
    if ks.len == 0 {
        f.blocks[b].term = Jmp(d)
    } else if ks.len == 1 {
        k := f.push(b, Const, f.insts[c].ty, vec[i64](), ks[0])
        e := f.push(b, Eq, I8, vec_two(c, k), 0)
        f.blocks[b].term = Br(e, ts[0], d)
    } else {
        f.blocks[b].term = Switch(c, sw_new(d, ks.items(), ts.items()))
    }
    return true
}

// ---------- tests of one value against constants ----------
// cmp(x, k) of instruction c with x an integer value and k a constant of its type, the
// constant on the right: (op, x, k), or (Op.Add, NOV, 0) if c is not such a compare
priv fn const_cmp(f: *Func, c: i64) -> (Op, i64, i64) {
    none := (Op.Add, NOV, 0)
    ci := &f.insts[c]
    if !ci.op.is_icmp() || ci.args.len != 2 {
        return none
    }
    a0 := ci.args[0]
    a1 := ci.args[1]
    op := ci.op
    x := a0
    kv := a1
    if f.insts[a0].op == Const && f.insts[a1].op != Const {
        x = a1
        kv = a0
        op = op.swap_cmp()
    } else if f.insts[a1].op != Const || f.insts[a0].op == Const {
        return none
    }
    ty := f.insts[x].ty
    if !ty.is_int() || f.insts[kv].ty != ty {
        return none
    }
    return (op, x, f.insts[kv].k)
}

// block nb holds only constants and (at most) the instruction c (no phis)
priv fn only_consts_and(f: *Func, nb: i64, c: i64) -> bool {
    for v in f.blocks[nb].insts {
        op := f.insts[v].op
        if op != Const && i64(v) != c {
            return false
        }
    }
    return true
}

// do the phis of block s take the same value from blocks q1 and q2 (both predecessors)
priv fn phis_agree(f: *Func, s: i64, q1: i64, q2: i64) -> bool {
    for v in f.blocks[s].insts {
        i := &f.insts[v]
        if i.op != Phi {
            break
        }
        if i.phi_input(q1) != i.phi_input(q2) {
            return false
        }
    }
    return true
}

// the inputs of the phis of block s from the blocks of `gone` become one input from p (they
// agree, see phis_agree; p may already have one)
priv fn phis_merge_into(f: *Func, s: i64, p: i64, gone: *Vec[i64]) {
    for ii in 0..f.blocks[s].insts.len {
        v := f.blocks[s].insts[ii]
        if f.insts[v].op != Phi {
            break
        }
        i := f.im(i64(v))
        val := i.phi_input(p)
        k := 0
        while k < i.args.len {
            if contains(gone, i.from()[k]) {
                if val == NOV {
                    val = i.args[k]
                }
                i.phi_remove(k)
            } else {
                k += 1
            }
        }
        if val != NOV && i.phi_input(p) == NOV {
            i.phi_add(val, p)
        }
    }
}

// the blocks of `chain` (no longer reached) give their instructions to p and go
priv fn absorb(f: *Func, p: i64, chain: *Vec[i64], dead: *Vec[bool]) {
    for nb in chain {
        moved := f.blocks[nb].insts
        f.blocks[nb].insts = vec[i32]()
        f.blocks[p].insts.extend(moved.items())
        f.blocks[nb].term = Term.None
        dead[nb] = true
    }
}

// ---------- chains of equality tests ----------
priv fn switch_form_all(f: *Func) -> bool {
    rpo, preds := f.rpo_preds()
    dead := vec_fill(f.blocks.len, false)
    changed := false
    for p in rpo {
        if !dead[p] && switch_form(f, p, &preds, &dead) {
            changed = true
        }
    }
    return changed
}

// The equality test that ends block b: (x, key, target if equal, target if not) for a branch
// on x == key or x != key with t != e; x = NOV if none.
priv fn eq_branch(f: *Func, b: i64) -> (i64, i64, i64, i64) {
    c, t, e := match f.blocks[b].term {
        Br(c1, t1, e1) if t1 != e1 => (c1, t1, e1)
        _ => return (NOV, 0, 0, 0)
    }
    op, x, k := const_cmp(f, c)
    if x == NOV || op != Eq && op != Ne {
        return (NOV, 0, 0, 0)
    }
    return if op == Eq { (x, k, t, e) } else { (x, k, e, t) }
}

// Block p ends a chain of tests of one value: the following tests (blocks reached only from
// the test before when it fails, that hold nothing but constants and their test) join p's
// test in one Switch. `preds` may be stale for blocks of chains made before (see the caller);
// it is only trusted for a block whose single predecessor is alive.
priv fn switch_form(f: *Func, p: i64, preds: *Vec[Vec[i64]], dead: *Vec[bool]) -> bool {
    x := NOV
    keys := vec[i64]()
    tgts := vec[i64]()
    next := 0
    was_switch := false
    match f.blocks[p].term {
        Switch(c, tab) => {
            x = c
            ks, ts := sw_cases(&tab)
            keys = ks
            tgts = ts
            next = sw_default(&tab)
            was_switch = true
        }
        _ => {
            x0, k, t, e := eq_branch(f, p)
            if x0 == NOV {
                return false
            }
            x = x0
            keys.push(k)
            tgts.push(t)
            next = e
        }
    }
    chain := vec[i64]()
    last := p
    loop {
        nb := next
        if nb == 0 || nb == p || dead[nb] || preds[nb].len != 1 || preds[nb][0] != last || contains(&chain, nb) {
            break
        }
        nkeys := vec[i64]()
        ntgts := vec[i64]()
        nnext := 0
        match f.blocks[nb].term {
            Switch(c, tab) => {
                if c != x || !only_consts_and(f, nb, NOV) {
                    break
                }
                ks, ts := sw_cases(&tab)
                nkeys = ks
                ntgts = ts
                nnext = sw_default(&tab)
            }
            Br(c, _, _) => {
                x2, k, t, e := eq_branch(f, nb)
                if x2 != x || !only_consts_and(f, nb, c) {
                    break
                }
                nkeys.push(k)
                ntgts.push(t)
                nnext = e
            }
            _ => break
        }
        // the phis of the blocks nb goes to must take the same value from nb as from the
        // blocks of the chain that go there too (they all become p)
        agree := true
        for si in 0..f.nsucc(nb) {
            s := f.succ_at(nb, si)
            if !phis_agree(f, s, nb, p) && f.has_succ(p, s) {
                agree = false
            }
            for q in chain {
                if f.has_succ(q, s) && !phis_agree(f, s, nb, q) {
                    agree = false
                }
            }
        }
        if !agree {
            break
        }
        for i in 0..nkeys.len {
            // (a key tested before never gets here)
            if !contains(&keys, nkeys[i]) {
                keys.push(nkeys[i])
                tgts.push(ntgts[i])
            }
        }
        chain.push(nb)
        last = nb
        next = nnext
    }
    if chain.is_empty() || !was_switch && keys.len < SW_MIN_KEYS {
        return false
    }
    // the targets get p for the blocks of the chain
    done := vec_one(next)
    for t in tgts {
        if !contains(&done, t) {
            done.push(t)
        }
    }
    for s in done {
        phis_merge_into(f, s, p, &chain)
    }
    absorb(f, p, &chain, dead)
    f.blocks[p].term = Switch(x, sw_new(next, keys.items(), tgts.items()))
    return true
}

// ---------- range tests ----------
// the values of type ty for which cmp(x, k) holds (op an integer compare but Ne), as an
// interval [lo, hi] of the order of the compare, where values are u64 (biased by the sign
// bit for a signed compare); (false, ..) if none or Ne
priv fn is_signed_cmp(op: Op) -> bool {
    return op == Slt || op == Sle || op == Sgt || op == Sge
}

// (an Eq is an interval in either order: `signed` chooses)
priv fn cmp_interval(op: Op, ty: T, k: i64, signed: bool) -> (bool, u64, u64) {
    bits := i64(ty.bits())
    m := if bits >= 64 { ~u64(0) } else { (u64(1) << bits) - 1 }
    kb := u64(k) & m
    if signed {
        kb ^= u64(1) << (bits - 1)
    }
    match op {
        Eq => return (true, kb, kb)
        Slt, Ult => return (kb != 0, 0, kb - 1)
        Sle, Ule => return (true, 0, kb)
        Sgt, Ugt => return (kb != m, kb + 1, m)
        Sge, Uge => return (true, kb, m)
        _ => return (false, 0, 0)
    }
}

priv fn switch_ranges(f: *Func) -> bool {
    rpo, preds := f.rpo_preds()
    dead := vec_fill(f.blocks.len, false)
    changed := false
    for p in rpo {
        if !dead[p] && switch_range(f, p, &preds, &dead) {
            changed = true
        }
    }
    return changed
}

// Block p branches on cmp1(x, k1) to X or to nb, and nb (reached only from p, holding only
// constants and its test) on cmp2(x, k2) to X or Y: p tests whether x is in one interval
// (when both tests together say so) and goes to Y or X; nb goes.
priv fn switch_range(f: *Func, p: i64, preds: *Vec[Vec[i64]], dead: *Vec[bool]) -> bool {
    c1, t1, e1 := match f.blocks[p].term {
        Br(c, t, e) if t != e => (c, t, e)
        _ => return false
    }
    op1, x, k1 := const_cmp(f, c1)
    if x == NOV || op1 == Ne {
        return false
    }
    // p: x in A -> bx, else nb
    nb := e1
    bx := t1
    neg1 := false
    if nb == 0 || nb == p || dead[nb] || preds[nb].len != 1 || preds[nb][0] != p {
        nb = t1
        bx = e1
        neg1 = true
        if nb == 0 || nb == p || dead[nb] || preds[nb].len != 1 || preds[nb][0] != p {
            return false
        }
    }
    c2, t2, e2 := match f.blocks[nb].term {
        Br(c, t, e) if t != e => (c, t, e)
        _ => return false
    }
    op2, x2, k2 := const_cmp(f, c2)
    if x2 != x || op2 == Ne || !only_consts_and(f, nb, c2) || t2 == nb || e2 == nb {
        return false
    }
    // the blocks reached: x in `in` -> yin, else bx
    yin := 0
    neg2 := false
    if e2 == bx {
        yin = t2
    } else if t2 == bx {
        yin = e2
        neg2 = true
    } else {
        return false
    }
    if yin == p || !phis_agree(f, bx, p, nb) {
        return false
    }
    // in = not A and (B, or not B): A = cmp1 (or its negation when nb is p's true arm)
    a_op := if neg1 { op1 } else { op1.negate_icmp() }
    b_op := if neg2 { op2.negate_icmp() } else { op2 }
    ty := f.insts[x].ty
    s1 := if a_op == Eq { is_signed_cmp(b_op) } else { is_signed_cmp(a_op) }
    if b_op != Eq && is_signed_cmp(b_op) != s1 {
        return false
    }
    ok1, lo1, hi1 := cmp_interval(a_op, ty, k1, s1)
    ok2, lo2, hi2 := cmp_interval(b_op, ty, k2, s1)
    if !ok1 || !ok2 {
        return false
    }
    lo := max(lo1, lo2)
    hi := min(hi1, hi2)
    if lo > hi {
        return false
    }
    bits := i64(ty.bits())
    m := if bits >= 64 { ~u64(0) } else { (u64(1) << bits) - 1 }
    if lo == 0 && hi == m {
        return false
    }
    bias := if s1 { u64(1) << (bits - 1) } else { u64(0) }
    lov := ir_canon(ty, i64(lo ^ bias))
    // p tests x - lo <= hi - lo (unsigned, in the width of x)
    kc := f.push(p, Const, ty, vec[i64](), lov)
    d := f.push(p, Sub, ty, vec_two(x, kc), 0)
    wc := f.push(p, Const, ty, vec[i64](), ir_canon(ty, i64(hi - lo)))
    u := f.push(p, Ule, I8, vec_two(d, wc), 0)
    chain := vec_one(nb)
    // yin's phis: the input from nb now comes from p; bx keeps p's (they agree)
    phis_merge_into(f, bx, p, &chain)
    f.phi_pred_replace(yin, nb, p)
    absorb(f, p, &chain, dead)
    f.blocks[p].term = Br(u, yin, bx)
    return true
}

// ---------- for the back ends ----------
// How the back ends compile a Switch with these cases (keys ascending, targets, default):
// SW_BITS: x - lo is checked against the span, then one bit test of a 64-bit mask per target
// (a span below 64, at most 3 targets besides the default, enough keys); SW_TABLE: x - lo is
// checked against the span, then a jump table (at least 4 keys that fill at least 10 % of a
// span below 2^16: the density LLVM accepts when not optimising for size); SW_CHAIN: a
// compare per key.
const SW_CHAIN = 0
const SW_BITS = 1
const SW_TABLE = 2

fn switch_leaf_kind(ks: []i64, ts: []i64, d: i64) -> i64 {
    n := len(ks)
    if n == 0 {
        return SW_CHAIN
    }
    span := u64(ks[n - 1] - ks[0])
    ntargets := 0
    seen := vec[i64]()
    for t in ts {
        if t != d && !contains(&seen, t) {
            seen.push(t)
            ntargets += 1
            if ntargets > 3 {
                break
            }
        }
    }
    // (a bit test per target instead of a compare per key)
    if span < 64 && ntargets <= 3 && n >= 3 && n >= 2 * ntargets + 1 {
        return SW_BITS
    }
    if n >= 4 && span < 0xFFFF && u64(n) * 100 >= 10 * (span + 1) {
        return SW_TABLE
    }
    return SW_CHAIN
}

// Before instruction selection: a Switch that is not one jump table or one set of bit tests
// becomes a binary search (x < key) down to such Switches and short chains of equality tests
// (as two-way branches, which the back ends compile well). True if it changed something.
fn switch_lower(f: *Func, leaves: bool) -> bool {
    changed := false
    nb := f.blocks.len
    for b in 0..nb {
        x, tab := match f.blocks[b].term {
            Switch(c, t) => (c, t)
            _ => continue
        }
        ks, ts := sw_cases(&tab)
        d := sw_default(&tab)
        if leaves && ks.len > 0 && switch_leaf_kind(ks.items(), ts.items(), d) != SW_CHAIN {
            continue
        }
        // the blocks that now go to each target (for its phis)
        edges := vec[(i64, i64)]()
        lower_range(f, b, x, ks.items(), ts.items(), d, leaves, &edges)
        targets := sw_cases(&tab).1
        targets.push(d)
        fixed := vec[i64]()
        for s in targets {
            if contains(&fixed, s) {
                continue
            }
            fixed.push(s)
            ps := vec[i64]()
            for e in edges {
                if e.0 == s && !contains(&ps, e.1) {
                    ps.push(e.1)
                }
            }
            for ii in 0..f.blocks[s].insts.len {
                v := f.blocks[s].insts[ii]
                if f.insts[v].op != Phi {
                    break
                }
                i := f.im(i64(v))
                val := i.phi_input(b)
                k := index_of(i.from(), b)
                if k < 0 {
                    continue
                }
                i.phi_remove(k)
                for p in ps {
                    f.im(i64(v)).phi_add(val, p)
                }
            }
        }
        changed = true
    }
    return changed
}

// ends block blk (no terminator yet, or the Switch being lowered) with the test of x against
// keys ks (ascending) going to ts, other values to d; edges gets (target, block) for every edge
// to a target
priv fn lower_range(f: *Func, blk: i64, x: i64, ks: []i64, ts: []i64, d: i64, leaves: bool, edges: *Vec[(i64, i64)]) {
    n := len(ks)
    ty := f.insts[x].ty
    if leaves && n > 0 && switch_leaf_kind(ks, ts, d) != SW_CHAIN {
        f.blocks[blk].term = Switch(x, sw_new(d, ks, ts))
        for t in ts {
            edges.push((t, blk))
        }
        edges.push((d, blk))
        return
    }
    if n <= 3 {
        // a chain of equality tests
        cur := blk
        for i in 0..n {
            k := f.push(cur, Const, ty, vec[i64](), ks[i])
            e := f.push(cur, Eq, I8, vec_two(x, k), 0)
            next := if i + 1 < n { f.new_block() } else { d }
            if ts[i] == next {
                // (a key that goes where the next test goes needs no test)
                f.blocks[cur].term = Jmp(next)
            } else {
                f.blocks[cur].term = Br(e, ts[i], next)
                edges.push((ts[i], cur))
            }
            if i + 1 == n {
                edges.push((d, cur))
            }
            cur = next
        }
        if n == 0 {
            f.blocks[blk].term = Jmp(d)
            edges.push((d, blk))
        }
        return
    }
    // binary search: x < ks[mid] goes left
    mid := n / 2
    left := f.new_block()
    right := f.new_block()
    k := f.push(blk, Const, ty, vec[i64](), ks[mid])
    c := f.push(blk, Slt, I8, vec_two(x, k), 0)
    f.blocks[blk].term = Br(c, left, right)
    lower_range(f, left, x, ks[..mid], ts[..mid], d, leaves, edges)
    lower_range(f, right, x, ks[mid..], ts[mid..], d, leaves, edges)
}

// ---------- conditions decided before ----------
// The value of condition c on the edge p -> b: 2 true, 1 false, 0 unknown. p branches on c,
// or a block above p (through blocks with one predecessor, none of them `touched`: preds is
// stale for those) does and p is on one side of it.
priv fn known_on_edge(f: *Func, preds: *Vec[Vec[i64]], touched: *Vec[bool], p: i64, b: i64, c: i64) -> u8 {
    q := b
    r := p
    for depth in 0..8 {
        match f.blocks[r].term {
            Br(c1, x, y) if c1 == c && x != y => {
                if q == x {
                    return 2
                }
                if q == y {
                    return 1
                }
                return 0
            }
            _ => {}
        }
        if touched[r] || preds[r].len != 1 || r == 0 {
            return 0
        }
        q = r
        r = preds[r][0]
    }
    return 0
}

// A block b (not a loop header) that holds nothing and branches on c: a predecessor where c is
// known goes straight to the target c chooses. (Only edges that are not back edges move, so
// the loops stay as they were.)
priv fn thread_known(f: *Func) -> bool {
    rpo, preds := f.rpo_preds()
    n := f.blocks.len
    ridx := vec_fill(n, -1)
    for i, b in rpo {
        ridx[b] = i
    }
    touched := vec_fill(n, false)
    changed := false
    for b in rpo {
        if b == 0 || touched[b] || !f.blocks[b].insts.is_empty() {
            continue
        }
        c, t, e := match f.blocks[b].term {
            Br(c1, t1, e1) if t1 != e1 && t1 != b && e1 != b => (c1, t1, e1)
            _ => continue
        }
        header := false
        for p in preds[b] {
            if ridx[p] >= ridx[b] {
                header = true
            }
        }
        if header {
            continue
        }
        for p in preds[b] {
            if !f.has_succ(p, b) {
                continue
            }
            k := known_on_edge(f, &preds, &touched, p, b, c)
            if k == 0 {
                continue
            }
            tgt := if k == 2 { t } else { e }
            // (p reaching tgt already would need two inputs in its phis)
            if f.has_succ(p, tgt) {
                continue
            }
            for ii in 0..f.blocks[tgt].insts.len {
                v := f.blocks[tgt].insts[ii]
                if f.insts[v].op != Phi {
                    break
                }
                val := f.insts[v].phi_input(b)
                if val != NOV {
                    f.im(i64(v)).phi_add(val, p)
                }
            }
            f.retarget(p, b, tgt)
            touched[tgt] = true
            changed = true
        }
    }
    return changed
}
