// Jump threading through switches, on the machine code after register allocation.
//
// A state machine is a loop around `match state { ... }`: every arm sets the state and goes
// back to the one jump table, an indirect jump that the processor predicts badly. Where the
// state is a constant at the end of a block, the way from there to the switch is known to end
// in one arm: the blocks on the way are copied for that block, and the copy ends with a direct
// jump to the arm instead of the table.
//
//     P:  mov eax, 3 ; jmp L          P:  mov eax, 3 ; jmp L'
//     L:  add r9, 1 ; cmp r9, rsi     L': add r9, 1 ; cmp r9, rsi
//         jl D ; jmp exit                 jl D' ; jmp exit
//     D:  movzx r8, [rdi+r9]          D': movzx r8, [rdi+r9]
//         cmp eax, 11 ; ja default        jmp arm3
//         ... jmp [table + rax*4]
//
// After register allocation a copied block needs no repair: it reads and writes the same
// registers as the original. The registers the dispatch itself writes (the index, the table
// address, the offset) are temporaries of the switch and dead in the arms.
// ALC_DISABLE=jthread turns it off.

// the most instructions copied for one threaded edge, and for one function
priv const JT_PATH_MAX = 24
priv const JT_FUNC_MAX = 1200
// the most blocks between the constant and the switch
priv const JT_DEPTH = 4

// the dispatch at the end of a block (isel switch_term, the jump table form)
priv struct Dispatch {
    block: i64
    start: i64   // its first instruction in the block
    state: i64   // the register switched on
    lo: i64
    span: i64
    wide: bool   // a 64-bit value (else 32 bits)
    dflt: i64
    jtab: i64
    // the registers the dispatch writes
    tmp: [3]i64
}

priv struct Threader {
    mf: *MFunc
    du: Vec[i64]
    preds: Vec[Vec[i64]]
    n0: i64                       // the blocks before the pass: only these are threaded from
    added: i64                    // instructions copied so far
    after: Vec[Vec[i64]]          // per original block: the new blocks laid out after it
    made: Map[str, i64]           // (chain, value) -> the first block of its copy
}

priv fn jt_defs(t: *Threader, i: *MInst, r: i64) -> bool {
    mir_decode(t.mf, i, t.du.items(), 0)
    d := t.du[0]
    nd := d & 255
    for j in 1..1 + nd {
        if t.du[j] == r {
            return true
        }
    }
    return d & (DU_CALL << 16) != 0 && r < VREG0
}

priv fn jt_is_call(op: MOp) -> bool {
    return op == Call || op == CallInd || op == Syscall || op == Ret || op == TailJmp || op == Ud2 || op == JmpInd
}

// the dispatch that block b ends with, if it is one this pass understands
priv fn jt_dispatch(t: *Threader, b: i64) -> Opt[Dispatch] {
    insts := &t.mf.blocks[b].insts
    n := insts.len
    if n < 6 || insts[n - 1].op != JmpInd {
        return None
    }
    d := Dispatch{block: b, jtab: i64(insts[n - 1].tgt)}
    tb := -1
    off := -1
    match (insts[n - 2].op, &insts[n - 2].a, &insts[n - 2].b) {
        (Add, R(x), R(y)) => {
            tb = x
            off = y
        }
        _ => return None
    }
    idx := -1
    match (insts[n - 3].op, &insts[n - 3].a, &insts[n - 3].b) {
        (Movsx, R(x), M(m)) if x == off && i64(m.base) == tb && m.scale == 4 => idx = i64(m.idx)
        _ => return None
    }
    match (insts[n - 4].op, &insts[n - 4].a, &insts[n - 4].b) {
        (Lea, R(x), M(m)) if x == tb && m.kind == MK_JTAB => {}
        _ => return None
    }
    if insts[n - 5].op != Jcc || insts[n - 5].cc != CC_A {
        return None
    }
    d.dflt = i64(insts[n - 5].tgt)
    match (insts[n - 6].op, &insts[n - 6].a, &insts[n - 6].b) {
        (Cmp, R(x), I(k)) if x == idx => {
            d.span = k
            d.wide = insts[n - 6].sz == 8
        }
        _ => return None
    }
    k := n - 7
    if k >= 0 {
        match (insts[k].op, &insts[k].a, &insts[k].b) {
            (Sub, R(x), I(c)) if x == idx => {
                d.lo = c
                k -= 1
            }
            _ => {}
        }
    }
    if k < 0 {
        return None
    }
    match (insts[k].op, &insts[k].a, &insts[k].b) {
        (Mov, R(x), R(y)) if x == idx => d.state = y
        _ => return None
    }
    d.start = k
    d.tmp[0] = idx
    d.tmp[1] = tb
    d.tmp[2] = off
    return Some(d)
}

// where the switch goes for the state value k
priv fn jt_target(t: *Threader, d: *Dispatch, k: i64) -> i64 {
    x := u64(k - d.lo)
    if !d.wide {
        x &= 0xFFFF_FFFF
    }
    if x > u64(d.span) {
        return d.dflt
    }
    return t.mf.jtabs[d.jtab][i64(x)]
}

// The value of the state register at the end of block b, if it is a known constant: set in
// the block, or in the only way into it (`depth` blocks back at most).
priv fn jt_const(t: *Threader, d: *Dispatch, b: i64, depth: i64) -> (i64, bool) {
    insts := &t.mf.blocks[b].insts
    e := insts.len
    if b == d.block {
        e = d.start
    }
    for j in 0..e {
        i := &insts[e - 1 - j]
        match (i.op, &i.a, &i.b) {
            (Mov, R(x), I(k)) if x == d.state && (i.sz == 8 || i.sz == 4) => return (if i.sz == 4 { k & 0xFFFF_FFFF } else { k }, true)
            (Zero, R(x), _) if x == d.state => return (0, true)
            _ => {}
        }
        if jt_defs(t, i, d.state) {
            return (0, false)
        }
    }
    if depth == 0 || t.preds[b].len != 1 {
        return (0, false)
    }
    p := t.preds[b][0]
    if p == b {
        return (0, false)
    }
    if p == d.block {
        // an arm: the state is its case, unless the dispatch itself overwrote the register
        if d.tmp[0] == d.state || d.tmp[1] == d.state || d.tmp[2] == d.state || b == d.dflt {
            return (0, false)
        }
        tab := &t.mf.jtabs[d.jtab]
        found := -1
        for j in 0..tab.len {
            if tab[j] == b {
                if found >= 0 {
                    return (0, false)
                }
                found = j
            }
        }
        if found < 0 {
            return (0, false)
        }
        return (found + d.lo, true)
    }
    return jt_const(t, d, p, depth - 1)
}

// can block b be copied as a step on the way to the switch? (its instruction count, or -1)
priv fn jt_step(t: *Threader, d: *Dispatch, b: i64) -> i64 {
    insts := &t.mf.blocks[b].insts
    for j in 0..insts.len {
        if jt_is_call(insts[j].op) || jt_defs(t, &insts[j], d.state) {
            return -1
        }
    }
    return insts.len
}

// in the instructions of block b, the jumps to `from` go to `to`; false if there is none
priv fn jt_retarget(mf: *MFunc, b: i64, from: i64, to: i64) -> bool {
    insts := &mf.blocks[b].insts
    any := false
    for j in 0..insts.len {
        if (insts[j].op == Jmp || insts[j].op == Jcc) && i64(insts[j].tgt) == from {
            insts[j].tgt = i32(to)
            any = true
        }
    }
    return any
}

// Block p ends with the state k and jumps to chain[0]; chain ends with the dispatch block.
// The jump goes to a copy of the chain that ends in the arm of k.
priv fn jt_thread(t: *Threader, d: *Dispatch, p: i64, chain: []i64, k: i64) {
    key := vec[u8]()
    for c in chain {
        key.extend(fmt(c, ","))
    }
    key.extend(fmt(":", k))
    first, have := t.made.get(key.items())
    if !have {
        size := d.start + 1
        for j in 0..len(chain) - 1 {
            size += t.mf.blocks[chain[j]].insts.len
        }
        if t.added + size > JT_FUNC_MAX {
            return
        }
        t.added += size
        base := t.mf.blocks.len
        first = base
        for j in 0..len(chain) {
            src := &t.mf.blocks[chain[j]]
            nb := MBlock{insts: vec[MInst](), succs: vec[i64](), depth: src.depth}
            if j == len(chain) - 1 {
                for x in 0..d.start {
                    nb.insts.push(src.insts[x])
                }
                ji := minst_new(Jmp, 0, Opnd.None, Opnd.None)
                ji.tgt = i32(jt_target(t, d, k))
                nb.insts.push(ji)
                nb.succs.push(i64(ji.tgt))
            } else {
                for x in 0..src.insts.len {
                    nb.insts.push(src.insts[x])
                }
                for s in src.succs {
                    nb.succs.push(if s == chain[j + 1] { base + j + 1 } else { s })
                }
            }
            t.mf.blocks.push(nb)
            if j < len(chain) - 1 {
                jt_retarget(t.mf, base + j, chain[j + 1], base + j + 1)
            }
            t.after[p].push(base + j)
        }
        t.made.set(clone(key.items()), first)
    }
    jt_retarget(t.mf, p, chain[0], first)
    succs := &t.mf.blocks[p].succs
    for j in 0..succs.len {
        if succs[j] == chain[0] {
            succs[j] = first
        }
    }
}

// the ways into chain[0] from blocks that end with a constant state; a block without one
// that can be copied is tried as a longer chain
priv fn jt_walk(t: *Threader, d: *Dispatch, chain: *Vec[i64], size: i64) {
    head := chain[0]
    // (the list is read before blocks are added: threading changes no list of an old block)
    for p in t.preds[head] {
        if p >= t.n0 || contains(chain, p) {
            continue
        }
        // (only a jump can be redirected, not an entry of a jump table)
        jumps := false
        pi := &t.mf.blocks[p].insts
        for j in 0..pi.len {
            if (pi[j].op == Jmp || pi[j].op == Jcc) && i64(pi[j].tgt) == head {
                jumps = true
            }
        }
        if !jumps {
            continue
        }
        k, known := jt_const(t, d, p, 6)
        if known {
            jt_thread(t, d, p, chain.items(), k)
            continue
        }
        if chain.len > JT_DEPTH {
            continue
        }
        n := jt_step(t, d, p)
        if n < 0 || size + n > JT_PATH_MAX {
            continue
        }
        longer := vec_one(p)
        longer.extend(chain.items())
        jt_walk(t, d, &longer, size + n)
    }
}

// threads the switches of mf; `layout` gets the new blocks after the blocks that jump to them
fn x86_thread_switches(mf: *MFunc, layout: *Vec[i64]) {
    if mf.jtabs.is_empty() {
        return
    }
    n := mf.blocks.len
    t := Threader{mf: mf, du: vec_fill(DU_MAX, 0), preds: vec[Vec[i64]](), n0: n, after: vec[Vec[i64]](), made: map[str, i64]()}
    for _ in 0..n {
        t.preds.push(vec[i64]())
        t.after.push(vec[i64]())
    }
    // jumps through blocks that only jump on go to where those end (emit_emit does the same
    // later): such blocks are no steps of a chain
    fwd := vec_fill(n, 0)
    for b in 0..n {
        fwd[b] = b
        if mf.blocks[b].insts.len == 1 && mf.blocks[b].insts[0].op == Jmp && i64(mf.blocks[b].insts[0].tgt) != b {
            fwd[b] = i64(mf.blocks[b].insts[0].tgt)
        }
    }
    for b in 0..n {
        insts := &mf.blocks[b].insts
        for j in 0..insts.len {
            i := &insts[j]
            if i.op == Jmp || i.op == Jcc {
                x := i64(i.tgt)
                for _ in 0..8 {
                    if fwd[x] == x || fwd[x] == b {
                        break
                    }
                    x = fwd[x]
                }
                i.tgt = i32(x)
                if !contains(&t.preds[i64(i.tgt)], b) {
                    t.preds[i64(i.tgt)].push(b)
                }
            } else if i.op == JmpInd {
                for s in mf.jtabs[i64(i.tgt)] {
                    if !contains(&t.preds[s], b) {
                        t.preds[s].push(b)
                    }
                }
            }
        }
    }
    for b in 0..n {
        match jt_dispatch(&t, b) {
            Some(d) => {
                // the instructions before the dispatch are copied with every thread
                ok := d.start <= JT_PATH_MAX / 2
                for j in 0..d.start {
                    if jt_is_call(mf.blocks[b].insts[j].op) || jt_defs(&t, &mf.blocks[b].insts[j], d.state) {
                        ok = false
                    }
                }
                if ok {
                    chain := vec_one(b)
                    jt_walk(&t, &d, &chain, d.start)
                }
            }
            None => {}
        }
    }
    if t.added == 0 {
        return
    }
    out := vec[i64]()
    for b in layout {
        out.push(b)
        if b < n {
            for x in t.after[b] {
                out.push(x)
            }
        }
    }
    *layout = out
}
