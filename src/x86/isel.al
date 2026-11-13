// Instruction selection: SSA IR -> x86-64 machine IR with virtual registers.

// A header phi `p` whose old value is needed after the loop is found in the register of the
// header phi `q` that receives it on the back edge.
priv struct ExitAlias {
    p: i64
    q: i64
    header: i64
}

priv fn term_is_ret(t: Term) -> bool {
    match t {
        Ret(vs) => true
        _ => false
    }
}

// can the back edge latch -> header stay unsplit? returns the aliases needed after the loop
priv fn split_critical_edges_analyze(f: *Func, cfg: *Cfg, loops: *Loops, def_block: *Vec[i64], cx: *SplitCx, latch: i64, header: i64, other: i64, c: i64) -> (Vec[ExitAlias], bool) {
    none := vec[ExitAlias]()
    if !cfg.reachable(latch) || !cfg.dom(header, latch) {
        return (none, false)
    }
    li := -1
    for x in 0..loops.loops.len {
        if loops.loops[x].header == header {
            li = x
            break
        }
    }
    if li < 0 {
        return (none, false)
    }
    l := &loops.loops[li]
    if l.latches.len != 1 || loops.contains(li, other) {
        return (none, false)
    }
    phis := vec[i64]()
    for v in f.blocks[header].insts {
        if f.insts[v].op != Phi {
            break
        }
        phis.push(v)
    }
    if phis.is_empty() {
        return (none, false)
    }
    // the branch condition (and what gets folded into it) must not read the header phis
    fn is_hphi(f: *Func, def_block: *Vec[i64], header: i64, v: i64) -> bool {
        f.insts[v].op == Phi && def_block[v] == header
    }
    // operands folded into the compare are evaluated after the copies: they must not
    // depend on a header phi through anything that gets folded (addresses, test operands)
    fn tree_has(f: *Func, v: i64, depth: i64, def_block: *Vec[i64], header: i64) -> bool {
        if is_hphi(f, def_block, header, v) {
            return true
        }
        i := &f.insts[v]
        if !(i.op == Add || i.op == Sub || i.op == Shl || i.op == Mul || i.op == Load || i.op == And) {
            return false
        }
        if depth == 0 {
            return true
        }
        for a in i.args {
            if tree_has(f, a, depth - 1, def_block, header) {
                return true
            }
        }
        return false
    }
    ci := &f.insts[c]
    if is_hphi(f, def_block, header, c) {
        return (none, false)
    }
    if ci.op.is_cmp() {
        for a in ci.args {
            if is_hphi(f, def_block, header, a) {
                return (none, false)
            }
        }
    }
    for a in ci.args {
        ai := &f.insts[a]
        if (ai.op == And || ai.op == Load) && tree_has(f, a, 12, def_block, header) {
            return (none, false)
        }
    }
    // every other way out of the loop must be a trap
    trap_exits := vec[i64]()
    for b in l.blocks {
        ss := f.succs(b)
        for s in ss {
            if loops.contains(li, s) || (b == latch && s == other) {
                continue
            }
            if f.blocks[s].term != Trap {
                return (none, false)
            }
            trap_exits.push(s)
        }
        if term_is_ret(f.blocks[b].term) {
            return (none, false)
        }
    }
    // Instruction selection may evaluate address arithmetic and compares lazily at their
    // use. Anything computed from a header phi inside the loop that could be re-evaluated
    // after the loop would then read the already-updated phi register: keep the edge split.
    // (cx.der: the phis and what is derived from them lazily inside the loop; cx.inl: the
    // blocks of the loop; both are cleared again before returning)
    cx.uses_index(f)
    derived := clone(phis)
    for p in phis {
        cx.der[p] = true
    }
    for b in l.blocks {
        cx.inl[b] = true
    }
    qi := 0
    while qi < derived.len {
        x := derived[qi]
        qi += 1
        for j in cx.uoff[x]..cx.uoff[x + 1] {
            u := cx.uuser[j]
            if u < 0 || cx.der[u] || !cx.inl[cx.ublk[j]] {
                continue
            }
            ui := &f.insts[u]
            if ui.op == Add || ui.op == Sub || ui.op == Shl || ui.op == Mul || ui.op == And || ui.op.is_cmp() {
                cx.der[u] = true
                derived.push(u)
            }
        }
    }
    for b in l.blocks {
        cx.inl[b] = false
    }
    for x in derived {
        cx.der[x] = false
    }
    // after the loop no derived value may be used, and the phis used there need a partner
    // that receives them on the back edge
    for x in derived[phis.len..] {
        for j in cx.uoff[x]..cx.uoff[x + 1] {
            b := cx.ublk[j]
            if cfg.reachable(b) && !loops.contains(li, b) {
                return (none, false)
            }
        }
    }
    // the uses of the phis after the loop, in the order of the function: (position, block, phi)
    used := vec[(i64, i64, i64)]()
    for p in phis {
        for j in cx.uoff[p]..cx.uoff[p + 1] {
            b := cx.ublk[j]
            if cfg.reachable(b) && !loops.contains(li, b) {
                used.push((cx.uord[j], b, p))
            }
        }
    }
    sort_by(used.items(), fn(x: (i64, i64, i64), y: (i64, i64, i64)) -> bool { x.0 < y.0 })
    out := vec[ExitAlias]()
    for ui in 0..used.len {
        _, b, p := used[ui]
        if (ui == 0 || used[ui - 1].1 != b) && contains(&trap_exits, b) {
            return (none, false)
        }
        partner := -1
        for q in phis {
            qinst := &f.insts[q]
            if q == p {
                continue
            }
            found := false
            n := min(qinst.pb.len, qinst.args.len)
            for j in 0..n {
                if qinst.pb[j] == latch && qinst.args[j] == p {
                    found = true
                    break
                }
            }
            if found {
                partner = q
                break
            }
        }
        if partner < 0 {
            return (none, false)
        }
        out.push(ExitAlias{p: p, q: partner, header: header})
    }
    return (out, true)
}

// what the analysis of the back edges of a function shares: marks, and the uses of every
// value (built on first need)
priv struct SplitCx {
    der: Vec[bool]
    inl: Vec[bool]
    built: bool
    // the uses of value v: uuser[uoff[v]..uoff[v + 1]] (the using instruction, -1 for a
    // terminator), ublk (its block) and uord (its position in the function: blocks in order,
    // instructions, then the terminator, each operand in order)
    uoff: Vec[i64]
    uuser: Vec[i64]
    ublk: Vec[i64]
    uord: Vec[i64]
}

priv fn term_args(t: *Term) -> []i64 {
    match t {
        Br(&c, _, _) => return mkslice[i64](cast[*i64](c), 1)
        Ret(vs) => return vs.items()
        _ => return nil
    }
}

priv fn uses_index(cx: *SplitCx, f: *Func) {
    if cx.built {
        return
    }
    cx.built = true
    n := f.insts.len
    nb := f.blocks.len
    cnt := vec_fill(n + 1, 0)
    for b in 0..nb {
        for v in f.blocks[b].insts {
            for a in f.insts[v].args {
                cnt[a + 1] += 1
            }
        }
        for a in term_args(&f.blocks[b].term) {
            cnt[a + 1] += 1
        }
    }
    for v in 0..n {
        cnt[v + 1] += cnt[v]
    }
    total := cnt[n]
    cx.uoff = clone(cnt)
    cx.uuser = vec_fill(total, 0)
    cx.ublk = vec_fill(total, 0)
    cx.uord = vec_fill(total, 0)
    ord := 0
    for b in 0..nb {
        for v in f.blocks[b].insts {
            for a in f.insts[v].args {
                x := cnt[a]
                cnt[a] = x + 1
                cx.uuser[x] = v
                cx.ublk[x] = b
                cx.uord[x] = ord
                ord += 1
            }
        }
        for a in term_args(&f.blocks[b].term) {
            x := cnt[a]
            cnt[a] = x + 1
            cx.uuser[x] = -1
            cx.ublk[x] = b
            cx.uord[x] = ord
            ord += 1
        }
    }
}

// Split critical edges so that phi copies have a place to live. A loop back edge is left alone
// when the loop is only left through its latch (or through traps): its copies are emitted in
// the latch before the branch, and uses of header phis after the loop are redirected.
fn isel_split_critical_edges(f: *Func) -> Vec[ExitAlias] {
    preds := f.preds()
    nb := f.blocks.len
    // Only a back edge can stay unsplit, and a back edge goes back in the reverse postorder
    // (or is a self loop): the dominators and loops are computed for the first such edge.
    rpo := f.rpo()
    ridx := vec_fill(nb, -1)
    for i, b in rpo {
        ridx[b] = i
    }
    ready := false
    cfg: Cfg
    loops: Loops
    def_block: Vec[i64]
    cx: SplitCx
    aliases := vec[ExitAlias]()
    // decide first (on the unmodified CFG), then split
    keep := vec[(i64, i64)]()
    for b in 0..nb {
        tm := f.blocks[b].term
        match tm {
            Br(c, t, e) => {
                if t == e {
                    continue
                }
                for w in 0..2 {
                    s := if w == 0 { t } else { e }
                    other := if w == 0 { e } else { t }
                    if preds[s].len > 1 && ridx[b] >= 0 && ridx[s] <= ridx[b] {
                        if !ready {
                            ready = true
                            cfg = cfg_new(f)
                            loops = loops_new(f, &cfg)
                            def_block = f.block_of()
                            cx = SplitCx{der: vec_fill(f.insts.len, false), inl: vec_fill(nb, false), built: false, uoff: vec[i64](), uuser: vec[i64](), ublk: vec[i64](), uord: vec[i64]()}
                        }
                        al, ok := split_critical_edges_analyze(f, &cfg, &loops, &def_block, &cx, b, s, other, c)
                        if ok {
                            aliases.extend(al.items())
                            keep.push((b, s))
                        }
                    }
                }
            }
            _ => {}
        }
    }
    for b in 0..nb {
        tm := f.blocks[b].term
        match tm {
            Br(c, t, e) => {
                if t == e {
                    f.blocks[b].term = Jmp(t)
                    continue
                }
                nt := t
                ne := e
                for which in 0..2 {
                    s := if which == 0 { t } else { e }
                    if preds[s].len > 1 {
                        if contains(&keep, (b, s)) {
                            continue
                        }
                        nbk := f.new_block()
                        f.blocks[nbk].term = Jmp(s)
                        for ii in 0..f.blocks[s].insts.len {
                            v := f.blocks[s].insts[ii]
                            if f.insts[v].op != Phi {
                                continue
                            }
                            for j in 0..f.insts[v].pb.len {
                                if f.insts[v].pb[j] == b {
                                    f.insts[v].pb[j] = nbk
                                }
                            }
                        }
                        if which == 0 {
                            nt = nbk
                        } else {
                            ne = nbk
                        }
                    }
                }
                f.blocks[b].term = Br(c, nt, ne)
            }
            _ => {}
        }
    }
    return aliases
}

priv fn sz_of(t: T) -> u8 {
    match t {
        I8 => 1
        I16 => 2
        I32 => 4
        _ => 8
    }
}

// operation size for wrap-around arithmetic: narrow types use 32-bit instructions
priv fn osz(t: T) -> u8 {
    match t {
        I64 => 8
        _ => 4
    }
}

priv fn fits32(k: i64) -> bool {
    return k >= -2147483648 && k <= 2147483647
}

// operation size of an xmm type: scalar single, scalar double, packed
priv fn fsz(t: T) -> u8 {
    match t {
        F32 => 4
        F64 => 8
        _ => 16
    }
}

// size of a plain memory move of an xmm type (vec3 takes two moves)
priv fn fsz_mem(t: T) -> u8 {
    match t {
        F32 => 4
        F64, V2 => 8
        _ => 16
    }
}

// is v the integer constant k? (`f.is_const(v) == Some(k)`)
priv fn const_is(f: *Func, v: i64, k: i64) -> bool {
    match f.is_const(v) {
        Some(x) => x == k
        None => false
    }
}

priv struct Sel {
    f: *Func
    m: *Module
    mf: MFunc
    vreg: Vec[i64]
    uses: Vec[i64]
    needed: Vec[bool]
    addr_only: Vec[bool]
    blk_of: Vec[i64]
    slot_of: Vec[i64] // the frame slot of each alloca, or -1
    projs: Map[i64, Vec[(i64, i64)]]
    out: Vec[MInst] // the instructions of the block being selected, in chunks (see isel_select)
    fconst_ix: Map[Bits128, i64]
    // memory-clobber counter position of each instruction within its block (for load folding)
    clob: Vec[i64]
    cur_clob: i64
    cur_block: i64
    // a header phi whose old value is found in another phi after its loop: that phi and the
    // loop, or -1
    ea_q: Vec[i64]
    ea_loop: Vec[i64]
    param_of: Vec[i64] // the Param instruction of each parameter, or -1
    loops: Loops
}

// ---------- frame slots of allocas ----------
// Allocas whose address is only used to load, store, copy and fill (directly or plus an
// offset: never passed to a call, stored, compared, merged or returned) share a frame slot
// when their contents are never needed at the same time. Inlining leaves many such
// temporaries (aggregate results and their copies): without sharing they sum up to frames of
// tens of kilobytes.
priv fn bits_has(b: *Vec[u64], base: i64, i: i64) -> bool {
    return (b[base + i / 64] >> u64(i % 64)) & 1 != 0
}

priv fn bits_set(b: *Vec[u64], base: i64, i: i64) {
    b[base + i / 64] |= u64(1) << u64(i % 64)
}

priv fn bits_clear(b: *Vec[u64], base: i64, i: i64) {
    b[base + i / 64] &= ~(u64(1) << u64(i % 64))
}

// the candidate number of the alloca an address is derived from, or -1
priv fn slot_cand(root: *Vec[i64], cand: *Vec[i64], a: i64) -> i64 {
    r := root[a]
    if r < 0 {
        return -1
    }
    return cand[r]
}

// the memory effect of instruction v on the candidate allocas: (written, read, killed): the
// candidate numbers or -1; killed when the whole alloca is overwritten
priv fn slot_effect(f: *Func, v: i64, root: *Vec[i64], cand: *Vec[i64], allocas: *Vec[i64]) -> (i64, i64, bool) {
    i := &f.insts[v]
    match i.op {
        Load => return (-1, slot_cand(root, cand, i.args[0]), false)
        Store => return (slot_cand(root, cand, i.args[0]), -1, false)
        MemCpy, MemSet => {
            w := slot_cand(root, cand, i.args[0])
            r := -1
            if i.op == MemCpy {
                r = slot_cand(root, cand, i.args[1])
            }
            kill := false
            if w >= 0 && allocas[root[i.args[0]]] == i.args[0] {
                match f.is_const(i.args[2]) {
                    Some(n) => kill = n == f.insts[i.args[0]].k
                    None => {}
                }
            }
            return (w, r, kill)
        }
        _ => return (-1, -1, false)
    }
}

// the frame slot of every alloca (by instruction; -1 for other instructions)
priv fn alloca_slots(f: *Func, mf: *MFunc) -> Vec[i64] {
    n := f.insts.len
    slot_of := vec_fill(n, -1)
    allocas := vec[i64]()
    for v in f.blocks[0].insts {
        if f.insts[v].op == Alloca {
            allocas.push(v)
        }
    }
    if allocas.is_empty() {
        return slot_of
    }
    nb := f.blocks.len
    // the alloca (index into allocas) an address is derived from, or -1
    root := vec_fill(n, -1)
    for ai in 0..allocas.len {
        root[allocas[ai]] = ai
    }
    // (the passes visit the Adds in block order; after the first pass only the Adds without
    // a root yet can change)
    adds := vec[i64]()
    changed := false
    for bi in 0..nb {
        for v in f.blocks[bi].insts {
            i := &f.insts[v]
            if i.op == Add && root[v] < 0 {
                a := root[i.args[0]]
                b := root[i.args[1]]
                if (a >= 0) != (b >= 0) {
                    root[v] = max(a, b)
                    changed = true
                } else {
                    adds.push(v)
                }
            }
        }
    }
    while changed {
        changed = false
        k := 0
        for v in adds {
            i := &f.insts[v]
            if root[v] < 0 {
                a := root[i.args[0]]
                b := root[i.args[1]]
                if (a >= 0) != (b >= 0) {
                    root[v] = max(a, b)
                    changed = true
                    continue
                }
                adds[k] = v
                k += 1
            }
        }
        adds.len = k
    }
    escaped := vec_fill(allocas.len, false)
    for bi in 0..nb {
        for v in f.blocks[bi].insts {
            i := &f.insts[v]
            for j in 0..i.args.len {
                r := root[i.args[j]]
                if r < 0 {
                    continue
                }
                ok := match i.op {
                    Load, MemSet => j == 0
                    Store => j == 0 && root[i.args[1]] < 0
                    MemCpy => j <= 1
                    Add => root[v] >= 0
                    _ => false
                }
                if !ok {
                    escaped[r] = true
                }
            }
        }
        match f.blocks[bi].term {
            Br(c, _, _) => {
                if root[c] >= 0 {
                    escaped[root[c]] = true
                }
            }
            Ret(vs) => {
                for a in vs {
                    if root[a] >= 0 {
                        escaped[root[a]] = true
                    }
                }
            }
            _ => {}
        }
    }
    // candidates: allocas worth sharing
    cand := vec_fill(allocas.len, -1)
    members := vec[i64]()
    for ai in 0..allocas.len {
        if !escaped[ai] && f.insts[allocas[ai]].k >= 16 && members.len < 4096 {
            cand[ai] = members.len
            members.push(ai)
        }
    }
    k := members.len
    if k >= 2 {
        w := (k + 63) / 64
        // the instructions with an effect on the candidates, per block in order: (written,
        // read, killed) in eff[eff_off[b]..eff_off[b + 1]]
        eff_off := vec_fill(nb + 1, 0)
        eff := vec[(i64, i64, bool)]()
        for b in 0..nb {
            eff_off[b] = eff.len
            for v in f.blocks[b].insts {
                wr, rd, kill := slot_effect(f, v, &root, &cand, &allocas)
                if wr >= 0 || rd >= 0 {
                    eff.push((wr, rd, kill))
                }
            }
        }
        eff_off[nb] = eff.len
        // live: some path leads to a read without a whole overwrite before it
        live_in := vec_fill(nb * w, u64(0))
        live := vec_fill(w, u64(0))
        succs := vec[Vec[i64]]()
        for b in 0..nb {
            succs.push(f.succs(b))
        }
        changed = true
        while changed {
            changed = false
            for b in nb - 1..=0 by -1 {
                for x in 0..w {
                    live[x] = 0
                }
                for sb in succs[b] {
                    for x in 0..w {
                        live[x] |= live_in[sb * w + x]
                    }
                }
                for ei in eff_off[b + 1] - 1..=eff_off[b] by -1 {
                    wr, rd, kill := eff[ei]
                    if kill {
                        bits_clear(&live, 0, wr)
                    }
                    if rd >= 0 {
                        bits_set(&live, 0, rd)
                    }
                }
                for x in 0..w {
                    if live_in[b * w + x] != live[x] {
                        live_in[b * w + x] = live[x]
                        changed = true
                    }
                }
            }
        }
        // interference: a write while the other one is live, or a read and a write in one copy
        interf := vec_fill(k * w, u64(0))
        for b in 0..nb {
            for x in 0..w {
                live[x] = 0
            }
            for sb in succs[b] {
                for x in 0..w {
                    live[x] |= live_in[sb * w + x]
                }
            }
            for ei in eff_off[b + 1] - 1..=eff_off[b] by -1 {
                wr, rd, kill := eff[ei]
                if wr >= 0 {
                    for x in 0..w {
                        interf[wr * w + x] |= live[x]
                    }
                    if rd >= 0 {
                        bits_set(&interf, wr * w, rd)
                    }
                }
                if kill {
                    bits_clear(&live, 0, wr)
                }
                if rd >= 0 {
                    bits_set(&live, 0, rd)
                }
            }
        }
        // greedy, largest first; what is live on entry keeps a slot of its own
        order := vec[(i64, i64)]()
        for c in 0..k {
            if !bits_has(&live_in, 0, c) {
                order.push((f.insts[allocas[members[c]]].k, c))
            }
        }
        sort_by(order.items(), fn(a: (i64, i64), b: (i64, i64)) -> bool { a.0 > b.0 })
        groups := vec[Vec[i64]]()
        for sc in order {
            c := sc.1
            gi := -1
            next: for g in 0..groups.len {
                for o in groups[g] {
                    if bits_has(&interf, c * w, o) || bits_has(&interf, o * w, c) {
                        continue next
                    }
                }
                gi = g
                break
            }
            if gi < 0 {
                groups.push(vec[i64]())
                gi = groups.len - 1
            }
            groups[gi].push(c)
        }
        for g in groups {
            size := 0
            align := 1
            for c in g {
                size = max(size, f.insts[allocas[members[c]]].k)
                align = max(align, f.insts[allocas[members[c]]].aux)
            }
            sl := new_slot(mf, size, align)
            for c in g {
                slot_of[allocas[members[c]]] = sl
            }
        }
    }
    for v in allocas {
        if slot_of[v] < 0 {
            slot_of[v] = new_slot(mf, f.insts[v].k, f.insts[v].aux)
        }
    }
    return slot_of
}

// (rpo and loops: of f as it is now; loops is empty for a function without a cycle)
fn isel_select(f: *Func, m: *Module, rpo: []i64, loops: Loops, depths: []i64, aliases: []ExitAlias) -> MFunc {
    n := f.insts.len
    ea_q := vec_fill(n, -1)
    ea_loop := vec_fill(n, -1)
    for a in aliases {
        for li in 0..loops.loops.len {
            if loops.loops[li].header == a.header {
                ea_q[a.p] = a.q
                ea_loop[a.p] = li
                break
            }
        }
    }
    wide_xmm := false
    for ii in 0..f.insts.len {
        if f.insts[ii].ty.is_vec() {
            wide_xmm = true
            break
        }
    }
    s := Sel{
        f: f,
        m: m,
        mf: MFunc{
            name: f.name,
            blocks: vec[MBlock](),
            vclass: vec[u8](),
            slots: vec[(i64, i64)](),
            out_args: 0,
            fconsts: vec[Bits128](),
            has_calls: false,
            wide_xmm: wide_xmm,
            xuses: vec[i64](),
        },
        vreg: vec_fill(n, NOREG),
        uses: f.use_counts(),
        needed: vec_fill(n, false),
        addr_only: vec_fill(n, true),
        blk_of: f.block_of(),
        slot_of: vec[i64](),
        projs: map[i64, Vec[(i64, i64)]](),
        out: vec[MInst](),
        fconst_ix: map[Bits128, i64](),
        clob: vec_fill(n, 0),
        cur_clob: 0,
        cur_block: 0,
        ea_q: ea_q,
        ea_loop: ea_loop,
        param_of: vec_fill(f.params.len, -1),
        loops: loops,
    }
    nb := f.blocks.len
    s.mf.blocks.reserve(nb)
    for b in 0..nb {
        s.mf.blocks.push(MBlock{insts: vec[MInst](), succs: f.succs(b), depth: if b < len(depths) { depths[b] } else { 0 }, align: false})
    }
    // per-value facts
    bclob := vec_fill(nb, 0) // the clobber count at the end of each block
    for bi in 0..nb {
        b := &f.blocks[bi]
        nclob := 0
        for pi in 0..b.insts.len {
            v := b.insts[pi]
            s.clob[v] = nclob
            i := &f.insts[v]
            if cleanup_is_root(i.op) {
                nclob += 1
            }
            match i.op {
                Load => {}
                Store => {
                    s.addr_only[i.args[1]] = false
                }
                Proj => {
                    a0 := i.args[0]
                    pl, has := s.projs.get(a0)
                    if !has {
                        pl = vec[(i64, i64)]()
                    }
                    pl.push((i.k, v))
                    s.projs.set(a0, pl)
                    s.addr_only[a0] = false
                }
                Param => {
                    if i.k >= 0 && i.k < s.param_of.len {
                        s.param_of[i.k] = v
                    }
                    for a in i.args {
                        s.addr_only[a] = false
                    }
                }
                _ => {
                    for a in i.args {
                        s.addr_only[a] = false
                    }
                }
            }
        }
        bclob[bi] = nclob
        match b.term {
            Br(c, t, e) => {
                s.addr_only[c] = false
            }
            Ret(vs) => {
                for v in vs {
                    s.addr_only[v] = false
                }
            }
            _ => {}
        }
    }
    s.slot_of = alloca_slots(f, &s.mf)
    // Each block is selected backwards: the terminator, then the instructions from the last
    // one, then (entry block) the parameters. Every piece appends its instructions to s.out
    // in order (a chunk); the block is the chunks in the reverse order.
    starts := vec[i64]()
    for ri in rpo.len - 1..=0 by -1 {
        b := rpo[ri]
        s.cur_block = b
        s.cur_clob = bclob[b]
        s.out.clear()
        starts.clear()
        // terminator (with phi copies for the unique successor)
        starts.push(0)
        s.term(b)
        for vi in f.blocks[b].insts.len - 1..=0 by -1 {
            v := f.blocks[b].insts[vi]
            op := f.insts[v].op
            if op == Const && s.needed[v] {
                // a wide constant kept in a register (so that loops do not rebuild it)
                starts.push(s.out.len)
                d := s.vr(v)
                s.out.push(minst_new(Mov, 8, R(d), I(f.insts[v].k)))
                continue
            }
            if op == Phi || op == Param || op == Alloca || op == Const || op == FConst || op == GAddr || op == FAddr || op == Proj {
                continue
            }
            if cleanup_is_root(op) || s.needed[v] {
                starts.push(s.out.len)
                s.cur_clob = s.clob[v]
                s.inst(v)
            }
        }
        if b == 0 {
            starts.push(s.out.len)
            s.params()
        }
        insts := vec[MInst]()
        insts.reserve(s.out.len)
        end := s.out.len
        for c in starts.len - 1..=0 by -1 {
            insts.extend(s.out[starts[c]..end])
            end = starts[c]
        }
        s.mf.blocks[b].insts = insts
    }
    return s.mf
}

priv fn e(self: *Sel, op: MOp, sz: u8, a: Opnd, b: Opnd) {
    self.out.push(minst_new(op, sz, a, b))
}

priv fn shufps(self: *Sel, d: i64, s: i64, imm: i64) {
    mi := minst_new(Shufps, 16, R(d), R(s))
    mi.tgt = i32(imm)
    self.out.push(mi)
}

priv fn class_of(self: *Sel, v: i64) -> u8 {
    if self.f.insts[v].ty.is_fp() {
        return 1
    }
    return 0
}

// the vreg holding IR value v (allocated on demand)
priv fn vr(self: *Sel, v: i64) -> i64 {
    if self.vreg[v] == NOREG {
        c := self.class_of(v)
        self.vreg[v] = new_vreg(&self.mf, c)
    }
    return self.vreg[v]
}

priv fn fconst(self: *Sel, bits: Bits128) -> Mem {
    ix, has := self.fconst_ix.get(bits)
    if !has {
        self.mf.fconsts.push(bits)
        ix = self.mf.fconsts.len - 1
        self.fconst_ix.set(bits, ix)
    }
    return Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MK_FCONST, id: i32(ix)}
}

// the frame slot of the alloca v (`self.slot_of[&v]`)
priv fn isel_slot_of(s: *Sel, v: i64) -> i64 {
    sl := s.slot_of[v]
    assert sl >= 0, "isel: alloca without a slot"
    return sl
}

// a register holding v at the current point (materializes constants and addresses)
priv fn reg(self: *Sel, v: i64) -> i64 {
    i := &self.f.insts[v]
    if i.op == Const && (fits32(i.k) || self.blk_of[v] == self.cur_block) {
        r := new_vreg(&self.mf, 0)
        self.e(Mov, 8, R(r), I(i.k))
        return r
    }
    if i.op == FConst {
        r := new_vreg(&self.mf, 1)
        if i.k == 0 {
            self.e(Zero, 8, R(r), Opnd.None)
        } else {
            m := self.fconst(Bits128{lo: u64(i.k), hi: 0})
            self.e(MovSd, 8, R(r), M(m))
        }
        return r
    }
    if i.op == GAddr {
        r := new_vreg(&self.mf, 0)
        self.e(Mov, 8, R(r), Opnd.GAddr(i.k, 0))
        return r
    }
    if i.op == FAddr {
        r := new_vreg(&self.mf, 0)
        self.e(Mov, 8, R(r), Opnd.FAddr(i.k))
        return r
    }
    if i.op == Alloca {
        r := new_vreg(&self.mf, 0)
        sl := isel_slot_of(self, v)
        self.e(Lea, 8, R(r), M(mem_slot(sl, 0)))
        return r
    }
    q := self.ea_q[v]
    if q >= 0 {
        if !contains(&self.loops, self.ea_loop[v], self.cur_block) {
            // after the loop the old value of this phi lives in its partner
            self.needed[q] = true
            return self.vr(q)
        }
    }
    self.needed[v] = true
    return self.vr(v)
}

// register or 32-bit immediate
priv fn rmi(self: *Sel, v: i64) -> Opnd {
    match self.f.is_const(v) {
        Some(k) if fits32(k) => I(k)
        _ => R(self.reg(v))
    }
}

// can the load `v` be folded into the instruction currently being selected?
priv fn can_fold_load(self: *Sel, v: i64) -> bool {
    i := &self.f.insts[v]
    return i.op == Load &&
        self.uses[v] == 1 &&
        self.blk_of[v] == self.cur_block &&
        self.clob[v] == self.cur_clob &&
        self.vreg[v] == NOREG &&
        !self.needed[v]
}

priv fn load_mem(self: *Sel, v: i64) -> Opt[Mem] {
    if !self.can_fold_load(v) {
        return None
    }
    a := self.f.insts[v].args[0]
    return Some(self.addr(a))
}

// register, 32-bit immediate, or a folded load of the full operation width
priv fn rmi_mem(self: *Sel, v: i64, ty: T) -> Opnd {
    if (ty == I32 || ty == I64) && self.f.insts[v].ty == ty {
        match self.load_mem(v) {
            Some(m) => {
                return M(m)
            }
            None => {}
        }
    }
    return self.rmi(v)
}

// xmm register or memory (float constant or folded load)
priv fn xm(self: *Sel, v: i64) -> Opnd {
    i := &self.f.insts[v]
    if i.op == FConst && i.k != 0 {
        m := self.fconst(Bits128{lo: u64(i.k), hi: 0})
        return M(m)
    }
    if i.ty.is_vec() {
        // packed operations need aligned memory operands: vector loads are never folded
        return R(self.reg(v))
    }
    match self.load_mem(v) {
        Some(m) => M(m)
        None => R(self.reg(v))
    }
}

// ---------- addressing modes ----------
priv fn foldable_add_leafy(s: *Sel, a: i64) -> bool {
    op := s.f.insts[a].op
    return op == Const || op == GAddr || op == Alloca
}

priv fn foldable_add(self: *Sel, v: i64) -> bool {
    i := &self.f.insts[v]
    if i.op != Add || i.ty != I64 {
        return false
    }
    if self.uses[v] <= 1 || self.addr_only[v] {
        return true
    }
    // x + const never lengthens live ranges
    return foldable_add_leafy(self, i.args[0]) || foldable_add_leafy(self, i.args[1])
}

priv fn addr_term(self: *Sel, v: i64, m: *Mem, depth: i64) {
    i := &self.f.insts[v]
    if i.op == Const && fits32(i.k) && fits32(i64(m.disp) + i.k) {
        m.disp += i32(i.k)
        return
    }
    if i.op == GAddr && m.kind == MK_NORMAL {
        m.kind = MK_GLOBAL
        m.id = i32(i.k)
        return
    }
    if i.op == Alloca && m.kind == MK_NORMAL && m.base == NOREG {
        m.kind = MK_SLOT
        m.id = i32(isel_slot_of(self, v))
        return
    }
    if i.op == Add && depth < 8 && self.foldable_add(v) {
        a := i.args[0]
        b := i.args[1]
        self.addr_term(a, m, depth + 1)
        self.addr_term(b, m, depth + 1)
        return
    }
    if (i.op == Shl || i.op == Mul) && m.idx == NOREG && i.ty == I64 {
        match self.f.is_const(i.args[1]) {
            Some(k) => {
                scale: u8 = 0
                if i.op == Shl {
                    if k >= 1 && k <= 3 {
                        scale = u8(1) << k
                    }
                } else if k == 2 || k == 4 || k == 8 {
                    scale = u8(k)
                }
                if scale != 0 {
                    x := i.args[0]
                    m.idx = i32(self.reg(x))
                    m.scale = scale
                    return
                }
            }
            None => {}
        }
    }
    r := self.reg(v)
    base_free := m.base == NOREG && m.kind != MK_SLOT
    if base_free {
        m.base = i32(r)
    } else if m.idx == NOREG {
        m.idx = i32(r)
        m.scale = 1
    } else {
        // out of components: collapse what we have into a temporary
        t := new_vreg(&self.mf, 0)
        self.e(Lea, 8, R(t), M(*m))
        *m = mem_new()
        m.base = i32(t)
        m.idx = i32(r)
        m.scale = 1
    }
}

priv fn addr(self: *Sel, v: i64) -> Mem {
    m := mem_new()
    self.addr_term(v, &m, 0)
    return m
}

// ---------- parameters ----------
fn params(self: *Sel) {
    ni := 0
    nf := 0
    nstack := 0
    params := self.f.params
    for pi in 0..params.len {
        t := params[pi]
        pv := self.param_of[pi]
        want := pv >= 0 && self.needed[pv]
        if t.is_fp() {
            if nf < NUM_FLOAT_ARGS {
                if want {
                    d := self.vr(pv)
                    self.e(MovSd, 8, R(d), R(XMM0 + nf))
                }
                nf += 1
            } else {
                if want {
                    d := self.vr(pv)
                    m := Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MK_INARG, id: i32(nstack)}
                    self.e(MovSd, fsz(t), R(d), M(m))
                }
                nstack += if t.is_vec() { 2 } else { 1 }
            }
        } else if ni < len(INT_ARGS) {
            if want {
                d := self.vr(pv)
                self.e(Mov, 8, R(d), R(INT_ARGS[ni]))
            }
            ni += 1
        } else {
            if want {
                d := self.vr(pv)
                m := Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MK_INARG, id: i32(nstack)}
                self.e(Mov, 8, R(d), M(m))
            }
            nstack += 1
        }
    }
}

// ---------- terminators ----------
priv fn phi_copies(self: *Sel, b: i64, s: i64) {
    // parallel copies for the phis of s along edge b -> s
    moves := vec[(i64, Opnd, u8)]()
    phis := vec[i64]()
    for v in self.f.blocks[s].insts {
        if self.f.insts[v].op != Phi {
            break
        }
        phis.push(v)
    }
    for p in phis {
        self.needed[p] = true
        inst := &self.f.insts[p]
        ai := index_of(inst.pb.items(), b)
        if ai < 0 {
            continue
        }
        src := inst.args[ai]
        cls := self.class_of(p)
        d := self.vr(p)
        si := &self.f.insts[src]
        so: Opnd
        if si.op == Const {
            so = I(si.k)
        } else if si.op == GAddr {
            so = Opnd.GAddr(si.k, 0)
        } else if si.op == FAddr {
            so = Opnd.FAddr(si.k)
        } else if si.op == FConst && si.k == 0 {
            so = Opnd.None
        } else if si.op == FConst {
            so = M(self.fconst(Bits128{lo: u64(si.k), hi: 0}))
        } else if si.op == Alloca {
            so = M(mem_slot(isel_slot_of(self, src), 0))
        } else {
            r := self.reg(src)
            if r == d {
                continue
            }
            so = R(r)
        }
        moves.push((d, so, cls))
    }
    // sequentialize: register sources first, respecting dependencies
    pending := vec[(i64, Opnd, u8)]()
    for mv in moves {
        if is_r(mv.1) {
            pending.push(mv)
        }
    }
    while !pending.is_empty() {
        progressed := false
        i := 0
        while i < pending.len {
            d := pending[i].0
            blocked := false
            for j in 0..pending.len {
                if j != i && pending[j].1 == R(d) {
                    blocked = true
                    break
                }
            }
            if !blocked {
                mv := pending.remove(i)
                self.e(if mv.2 == 1 { MovSd } else { Mov }, 8, R(mv.0), mv.1)
                progressed = true
            } else {
                i += 1
            }
        }
        if !progressed {
            // cycle: save one destination in a temporary
            d := pending[0].0
            cls := pending[0].2
            t := new_vreg(&self.mf, cls)
            self.e(if cls == 1 { MovSd } else { Mov }, 8, R(t), R(d))
            for j in 0..pending.len {
                if pending[j].1 == R(d) {
                    pending[j].1 = R(t)
                }
            }
        }
    }
    for mv in moves {
        d := mv.0
        s2 := mv.1
        match s2 {
            R(r) => {}
            Opnd.None => self.e(Zero, 8, R(d), Opnd.None)
            M(m) => {
                if m.kind == MK_SLOT {
                    self.e(Lea, 8, R(d), s2)
                } else {
                    self.e(MovSd, 8, R(d), s2)
                }
            }
            _ => self.e(Mov, 8, R(d), s2)
        }
    }
}

// emit a flag-setting compare for IR compare `c`; returns the condition code(s) to test
// result: (cc, extra) where extra: 0 = none, 1 = "and not parity" (FEq), 2 = "or parity" (FNe)
priv fn cmp_flags(self: *Sel, c: i64) -> (u8, u8) {
    i := &self.f.insts[c]
    a := i.args[0]
    b := i.args[1]
    at := self.f.insts[a].ty
    if i.op.is_icmp() {
        sz := sz_of(at)
        op := i.op
        x := a
        y := b
        // constant on the left: swap
        if is_some(self.f.is_const(x)) && !is_some(self.f.is_const(y)) {
            tmp := x
            x = y
            y = tmp
            op = op.swap_cmp()
        }
        cc := match op {
            Eq => CC_E
            Ne => CC_NE
            Slt => CC_L
            Sle => CC_LE
            Sgt => CC_G
            Sge => CC_GE
            Ult => CC_B
            Ule => CC_BE
            Ugt => CC_A
            _ => CC_AE
        }
        if const_is(self.f, y, 0) && (op == Eq || op == Ne || op == Slt || op == Sle || op == Sgt || op == Sge) && !self.can_fold_load(x) {
            // test x, x  (or test a, b for (a & b) ==/!= 0)
            xi := &self.f.insts[x]
            if (op == Eq || op == Ne) && xi.op == And && self.uses[x] == 1 && self.blk_of[x] == self.cur_block {
                p := xi.args[0]
                q := xi.args[1]
                pr := self.reg(p)
                qo := self.rmi(q)
                self.e(Test, sz, R(pr), qo)
                return (cc, 0)
            }
            xr := self.reg(x)
            self.e(Test, sz, R(xr), R(xr))
            return (cc, 0)
        }
        // memory operands: cmp [mem], imm  /  cmp reg, [mem]
        match self.f.is_const(y) {
            Some(k) if fits32(k) => {
                match self.load_mem(x) {
                    Some(m) => {
                        self.e(Cmp, sz, M(m), I(k))
                        return (cc, 0)
                    }
                    None => {}
                }
            }
            _ => {}
        }
        xr := self.reg(x)
        yo := match self.load_mem(y) {
            Some(m) => M(m)
            None => self.rmi(y)
        }
        self.e(Cmp, sz, R(xr), yo)
        return (cc, 0)
    }
    // float compares: arrange operands so that unordered yields false
    if i.op == FLt || i.op == FLe {
        br := self.reg(b)
        ao := self.xm(a)
        self.e(Ucomisd, fsz(at), R(br), ao)
        return (if i.op == FLt { CC_A } else { CC_AE }, 0)
    }
    if i.op == FGt || i.op == FGe {
        ar := self.reg(a)
        bo := self.xm(b)
        self.e(Ucomisd, fsz(at), R(ar), bo)
        return (if i.op == FGt { CC_A } else { CC_AE }, 0)
    }
    if i.op == FEq {
        ar := self.reg(a)
        bo := self.xm(b)
        self.e(Ucomisd, fsz(at), R(ar), bo)
        return (CC_E, 1)
    }
    ar := self.reg(a)
    bo := self.xm(b)
    self.e(Ucomisd, fsz(at), R(ar), bo)
    return (CC_NE, 2)
}

priv fn jcc(self: *Sel, cc: u8, t: i64) {
    i := minst_new(Jcc, 0, Opnd.None, Opnd.None)
    i.cc = cc
    i.tgt = i32(t)
    self.out.push(i)
}

priv fn jmp(self: *Sel, t: i64) {
    i := minst_new(Jmp, 0, Opnd.None, Opnd.None)
    i.tgt = i32(t)
    self.out.push(i)
}

priv fn term(self: *Sel, b: i64) {
    tm := self.f.blocks[b].term
    match tm {
        Jmp(t) => {
            self.phi_copies(b, t)
            self.jmp(t)
        }
        Br(c, t, e) => {
            // an unsplit loop back edge: its phi copies go before the compare
            for s in ([2]i64{t, e}) {
                has_phi := false
                if self.f.blocks[s].insts.len > 0 {
                    has_phi = self.f.insts[self.f.blocks[s].insts[0]].op == Phi
                }
                if has_phi {
                    self.phi_copies(b, s)
                }
            }
            ci := &self.f.insts[c]
            if ci.op.is_cmp() {
                cf := self.cmp_flags(c)
                cc := cf.0
                extra := cf.1
                if extra == 0 {
                    self.jcc(cc, t)
                    self.jmp(e)
                } else if extra == 1 {
                    // true iff ZF && !PF
                    self.jcc(CC_NE, e)
                    self.jcc(CC_P, e)
                    self.jmp(t)
                } else {
                    // true iff !ZF || PF
                    self.jcc(CC_NE, t)
                    self.jcc(CC_P, t)
                    self.jmp(e)
                }
            } else {
                r := self.reg(c)
                self.e(Test, 1, R(r), R(r))
                self.jcc(CC_NE, t)
                self.jmp(e)
            }
        }
        Ret(vals) => {
            ni := 0
            nf := 0
            used := vec[i64]()
            moves := vec[(i64, i64)]()
            for v in vals {
                if self.f.insts[v].ty.is_fp() {
                    moves.push((XMM0 + nf, v))
                    nf += 1
                } else {
                    moves.push((INT_RETS[ni], v))
                    ni += 1
                }
            }
            // evaluate sources into vregs first, then move to the fixed registers
            srcs := vec[(i64, Opnd, bool)]()
            for mv in moves {
                v := mv.1
                isf := self.f.insts[v].ty.is_fp()
                o: Opnd
                if !isf {
                    o = self.mov_src(v)
                } else {
                    o = R(self.reg(v))
                }
                srcs.push((mv.0, o, isf))
            }
            for sv in srcs {
                self.e(if sv.2 { MovSd } else { Mov }, 8, R(sv.0), sv.1)
                used.push(sv.0)
            }
            self.out.push(self.mf.mir_with_uses(MOp.Ret, 0, Opnd.None, used.items()))
        }
        Trap, Term.None => {
            self.e(Ud2, 0, Opnd.None, Opnd.None)
        }
    }
}

// a source operand for a full-width integer move: immediate, symbol address or register
priv fn mov_src(self: *Sel, v: i64) -> Opnd {
    i := &self.f.insts[v]
    if i.op == Const {
        return I(i.k)
    }
    if i.op == GAddr {
        return Opnd.GAddr(i.k, 0)
    }
    if i.op == FAddr {
        return Opnd.FAddr(i.k)
    }
    return R(self.reg(v))
}

// ---------- instructions ----------
priv fn binop(self: *Sel, v: i64, mop: MOp, commutative: bool) {
    i := &self.f.insts[v]
    a := i.args[0]
    b := i.args[1]
    ty := i.ty
    sz := osz(ty)
    wide := ty == I32 || ty == I64
    if commutative && wide && !self.can_fold_load(b) && self.can_fold_load(a) {
        tmp := a
        a = b
        b = tmp
    } else if commutative && !self.can_fold_load(b) && !is_some(self.f.is_const(a)) && self.uses[a] > 1 && self.uses[b] == 1 && !is_some(self.f.is_const(b)) {
        tmp := a
        a = b
        b = tmp
    }
    d := self.vr(v)
    ar := self.reg(a)
    bo := self.rmi_mem(b, ty)
    self.e(Mov, 8, R(d), R(ar))
    self.e(mop, sz, R(d), bo)
}

priv fn fbinop_is_c(s: *Sel, x: i64) -> bool {
    return s.f.insts[x].op == FConst
}

priv fn fbinop(self: *Sel, v: i64, mop: MOp, commutative: bool) {
    i := &self.f.insts[v]
    a := i.args[0]
    b := i.args[1]
    if commutative && !self.can_fold_load(b) && (fbinop_is_c(self, a) || self.can_fold_load(a) || (self.uses[a] > 1 && self.uses[b] == 1 && !fbinop_is_c(self, b))) {
        tmp := a
        a = b
        b = tmp
    }
    d := self.vr(v)
    ar := self.reg(a)
    bo := self.xm(b)
    sz := fsz(self.f.insts[v].ty)
    self.e(MovSd, 8, R(d), R(ar))
    self.e(mop, sz, R(d), bo)
}

priv fn zext_free(self: *Sel, v: i64) -> bool {
    i := &self.f.insts[v]
    op := i.op
    if i.ty != I32 {
        return false
    }
    if op == Shl || op == LShr || op == AShr || op == Rotl || op == Rotr {
        // a shift or rotation by 0 (also a count in a register that is 0 modulo 32) leaves
        // the register as it was, upper half included
        return match self.f.is_const(i.args[1]) {
            Some(k) => k & 31 != 0
            None => false
        }
    }
    return op == Add || op == Sub || op == Mul || op == And || op == Or || op == Xor ||
        op == Load || op == ZExt || op == SDiv || op == UDiv || op == SRem || op == URem || op == Bswap
}

// value extended to 32 bits (for narrow division/shift inputs)
priv fn ext32(self: *Sel, v: i64, signed: bool) -> i64 {
    t := self.f.insts[v].ty
    r := self.reg(v)
    if t == I8 || t == I16 {
        d := new_vreg(&self.mf, 0)
        i := minst_new(if signed { Movsx } else { Movzx }, sz_of(t), R(d), R(r))
        i.sz2 = 4
        self.out.push(i)
        return d
    }
    return r
}

priv fn inst(self: *Sel, v: i64) {
    i := &self.f.insts[v]
    ty := i.ty
    match i.op {
        Add => {
            if ty == I64 {
                m := mem_new()
                self.addr_term(i.args[0], &m, 1)
                self.addr_term(i.args[1], &m, 1)
                d := self.vr(v)
                simple := m.kind == MK_NORMAL && m.idx == NOREG && m.base != NOREG
                if simple && m.disp == 0 {
                    self.e(Mov, 8, R(d), R(i64(m.base)))
                } else if simple && self.uses_of_reg_single(i, i64(m.base)) {
                    self.e(Mov, 8, R(d), R(i64(m.base)))
                    self.e(MOp.Add, 8, R(d), I(i64(m.disp)))
                } else if m.kind == MK_NORMAL && m.base != NOREG && m.idx != NOREG && m.scale == 1 && m.disp == 0 {
                    // a + b: two-address add when one side dies here
                    a := i.args[0]
                    b := i.args[1]
                    ra := i64(m.base)
                    rb := i64(m.idx)
                    direct := self.vreg[a] == ra && self.vreg[b] == rb
                    if direct && self.dies_here(a) {
                        self.e(Mov, 8, R(d), R(ra))
                        self.e(MOp.Add, 8, R(d), R(rb))
                    } else if direct && self.dies_here(b) {
                        self.e(Mov, 8, R(d), R(rb))
                        self.e(MOp.Add, 8, R(d), R(ra))
                    } else {
                        self.e(Lea, 8, R(d), M(m))
                    }
                } else if m.kind == MK_GLOBAL && m.base == NOREG && m.idx == NOREG {
                    self.e(Mov, 8, R(d), GAddr(i64(m.id), i64(m.disp)))
                } else {
                    self.e(Lea, 8, R(d), M(m))
                }
            } else {
                self.binop(v, MOp.Add, true)
            }
        }
        Sub => {
            // 0 - x => neg
            if const_is(self.f, i.args[0], 0) {
                d := self.vr(v)
                r := self.reg(i.args[1])
                self.e(Mov, 8, R(d), R(r))
                self.e(Neg, osz(ty), R(d), Opnd.None)
            } else {
                self.binop(v, MOp.Sub, false)
            }
        }
        Mul => {
            a := i.args[0]
            b := i.args[1]
            if is_some(self.f.is_const(a)) {
                tmp := a
                a = b
                b = tmp
            }
            d := self.vr(v)
            match self.f.is_const(b) {
                Some(k) if fits32(k) => {
                    ar := self.reg(a)
                    mi := minst_new(Imul3, osz(ty), R(d), R(ar))
                    mi.tgt = i32(k)
                    self.out.push(mi)
                }
                Some(_) => {
                    // a constant too wide for an immediate: multiply two registers
                    ar := self.reg(a)
                    br := self.reg(b)
                    self.e(Mov, 8, R(d), R(ar))
                    self.e(Imul, osz(ty), R(d), R(br))
                }
                None => self.binop(v, Imul, true)
            }
        }
        And => {
            // masks that are zero-extensions
            match self.f.is_const(i.args[1]) {
                Some(k) if (k == 0xFF || k == 0xFFFF) && ty != I8 => {
                    d := self.vr(v)
                    r := self.reg(i.args[0])
                    mi := minst_new(Movzx, if k == 0xFF { 1 } else { 2 }, R(d), R(r))
                    mi.sz2 = 4
                    self.out.push(mi)
                }
                Some(k) if k == 0xFFFF_FFFF && ty == I64 => {
                    d := self.vr(v)
                    r := self.reg(i.args[0])
                    self.e(Mov, 4, R(d), R(r))
                }
                _ => self.binop(v, MOp.And, true)
            }
        }
        Or => self.binop(v, MOp.Or, true)
        Xor => {
            if const_is(self.f, i.args[1], -1) {
                d := self.vr(v)
                r := self.reg(i.args[0])
                self.e(Mov, 8, R(d), R(r))
                self.e(Not, osz(ty), R(d), Opnd.None)
            } else {
                self.binop(v, MOp.Xor, true)
            }
        }
        Shl, LShr, AShr, Rotl, Rotr => {
            mop := match i.op {
                Shl => MOp.Shl
                LShr => MOp.Shr
                AShr => Sar
                Rotl => Rol
                _ => Ror
            }
            sz := sz_of(ty)
            d := self.vr(v)
            bits := ty.bits()
            match self.f.is_const(i.args[1]) {
                Some(k0) => {
                    r := self.reg(i.args[0])
                    self.e(Mov, 8, R(d), R(r))
                    k := k0 & (bits - 1)
                    if k != 0 {
                        self.e(mop, sz, R(d), I(k))
                    }
                }
                None => {
                    cnt := self.reg(i.args[1])
                    r := self.reg(i.args[0])
                    self.e(Mov, 8, R(RCX), R(cnt))
                    if sz < 4 {
                        self.e(MOp.And, 4, R(RCX), I(bits - 1))
                    }
                    self.e(Mov, 8, R(d), R(r))
                    self.e(mop, sz, R(d), R(RCX))
                }
            }
        }
        SDiv, UDiv, SRem, URem => {
            signed := i.op == SDiv || i.op == SRem
            sz := osz(ty)
            d := self.vr(v)
            a := self.ext32(i.args[0], signed)
            b := self.ext32(i.args[1], signed)
            self.e(Mov, 8, R(RAX), R(a))
            if signed {
                self.e(Cqo, sz, Opnd.None, Opnd.None)
                self.e(Idiv, sz, R(b), Opnd.None)
            } else {
                self.e(Zero, 4, R(RDX), Opnd.None)
                self.e(Div, sz, R(b), Opnd.None)
            }
            res := if i.op == SDiv || i.op == UDiv { RAX } else { RDX }
            self.e(Mov, 8, R(d), R(res))
        }
        MulHiS, MulHiU => {
            d := self.vr(v)
            a := self.reg(i.args[0])
            b := self.reg(i.args[1])
            self.e(Mov, 8, R(RAX), R(a))
            self.e(if i.op == MulHiS { Imul1 } else { Mul1 }, osz(ty), R(b), Opnd.None)
            self.e(Mov, 8, R(d), R(RDX))
        }
        FAdd => self.fbinop(v, Addsd, true)
        FMul => self.fbinop(v, Mulsd, true)
        FSub => self.fbinop(v, Subsd, false)
        FDiv => self.fbinop(v, Divsd, false)
        FMin => self.fbinop(v, Minsd, false)
        FMax => self.fbinop(v, Maxsd, false)
        FSqrt => {
            d := self.vr(v)
            s := self.xm(i.args[0])
            self.e(Zero, 8, R(d), Opnd.None)
            self.e(Sqrtsd, fsz(ty), R(d), s)
        }
        FNeg, FAbs => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            neg := i.op == FNeg
            // the 128-bit mask as two halves
            mask: Bits128
            if ty == F64 {
                if neg {
                    mask = Bits128{lo: 0x8000_0000_0000_0000, hi: 0}
                } else {
                    mask = Bits128{lo: 0x7FFF_FFFF_FFFF_FFFF, hi: 0}
                }
            } else {
                lane: u64 = if neg { 0x8000_0000 } else { 0x7FFF_FFFF }
                // lane | lane << 32 | lane << 64 | lane << 96
                mask = Bits128{lo: lane | lane << 32, hi: lane | lane << 32}
            }
            m := self.fconst(mask)
            self.e(MovSd, 8, R(d), R(s))
            self.e(if neg { Xorpd } else { Andpd }, if ty == F64 { 8 } else { 16 }, R(d), M(m))
        }
        SExt => {
            d := self.vr(v)
            st := self.f.insts[i.args[0]].ty
            s := match self.load_mem(i.args[0]) {
                Some(m) => M(m)
                None => R(self.reg(i.args[0]))
            }
            mi := minst_new(Movsx, sz_of(st), R(d), s)
            mi.sz2 = if ty == I64 { 8 } else { 4 }
            self.out.push(mi)
        }
        ZExt => {
            d := self.vr(v)
            src := i.args[0]
            st := self.f.insts[src].ty
            match self.load_mem(src) {
                Some(m) => {
                    if st == I32 {
                        self.e(Mov, 4, R(d), M(m))
                    } else {
                        mi := minst_new(Movzx, sz_of(st), R(d), M(m))
                        mi.sz2 = 4
                        self.out.push(mi)
                    }
                    return
                }
                None => {}
            }
            s := self.reg(src)
            if st == I32 {
                if self.zext_free(src) {
                    self.e(Mov, 8, R(d), R(s))
                } else {
                    self.e(Mov, 4, R(d), R(s))
                }
            } else if self.f.insts[src].op == Load {
                // byte loads are already zero-extended
                self.e(Mov, 8, R(d), R(s))
            } else {
                mi := minst_new(Movzx, sz_of(st), R(d), R(s))
                mi.sz2 = 4
                self.out.push(mi)
            }
        }
        Trunc => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(Mov, 8, R(d), R(s))
        }
        SIToF => {
            d := self.vr(v)
            st := self.f.insts[i.args[0]].ty
            s: Opnd
            if st == I32 || st == I64 {
                s = match self.load_mem(i.args[0]) {
                    Some(m) => M(m)
                    None => R(self.reg(i.args[0]))
                }
            } else {
                s = R(self.ext32(i.args[0], true))
            }
            self.e(Zero, 8, R(d), Opnd.None)
            mi := minst_new(Cvtsi2sd, if st == I64 { 8 } else { 4 }, R(d), s)
            mi.sz2 = fsz(ty)
            self.out.push(mi)
        }
        FToSI => {
            d := self.vr(v)
            s := self.xm(i.args[0])
            mi := minst_new(Cvttsd2si, if ty == I64 { 8 } else { 4 }, R(d), s)
            mi.sz2 = fsz(self.f.insts[i.args[0]].ty)
            self.out.push(mi)
        }
        BitsToF => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(MovqToX, fsz(ty), R(d), R(s))
        }
        FToBits => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(MovqToR, fsz(self.f.insts[i.args[0]].ty), R(d), R(s))
        }
        Select => {
            d := self.vr(v)
            c := i.args[0]
            a := self.reg(i.args[1])
            b := self.mov_src(i.args[2])
            self.e(Mov, 8, R(d), b)
            ci := &self.f.insts[c]
            cc: u8
            if ci.op.is_icmp() {
                cf := self.cmp_flags(c)
                cc = cf.0
            } else {
                r := self.reg(c)
                self.e(Test, 1, R(r), R(r))
                cc = CC_NE
            }
            mi := minst_new(Cmov, if ty == I64 { 8 } else { 4 }, R(d), R(a))
            mi.cc = cc
            self.out.push(mi)
        }
        Load => {
            d := self.vr(v)
            m := self.addr(i.args[0])
            match ty {
                F64, F32, V2, V4 => self.e(MovSd, fsz_mem(ty), R(d), M(m))
                V3 => {
                    // x, y as one 8-byte load; z joins as the upper half
                    t := new_vreg(&self.mf, 1)
                    hi := m
                    hi.disp += 8
                    self.e(MovSd, 8, R(d), M(m))
                    self.e(MovSd, 4, R(t), M(hi))
                    self.shufps(d, t, 0x44)
                }
                I8, I16 => {
                    mi := minst_new(Movzx, sz_of(ty), R(d), M(m))
                    mi.sz2 = 4
                    self.out.push(mi)
                }
                _ => self.e(Mov, sz_of(ty), R(d), M(m))
            }
        }
        Store => {
            val := i.args[1]
            vi := &self.f.insts[val]
            if ty.is_fp() {
                if vi.op == FConst && (vi.k == 0 || ty == F32) {
                    m := self.addr(i.args[0])
                    if ty == V3 || ty == V4 {
                        hi := m
                        hi.disp += 8
                        self.e(Mov, 8, M(m), I(0))
                        self.e(Mov, if ty == V3 { 4 } else { 8 }, M(hi), I(0))
                    } else {
                        self.e(Mov, if ty == F32 { 4 } else { 8 }, M(m), I(i64(i32(vi.k))))
                    }
                } else if ty == V3 {
                    r := self.reg(val)
                    m := self.addr(i.args[0])
                    t := new_vreg(&self.mf, 1)
                    hi := m
                    hi.disp += 8
                    self.e(MovSd, 8, M(m), R(r))
                    self.e(MovSd, 8, R(t), R(r))
                    self.shufps(t, t, 2)
                    self.e(MovSd, 4, M(hi), R(t))
                } else {
                    r := self.reg(val)
                    m := self.addr(i.args[0])
                    self.e(MovSd, fsz_mem(ty), M(m), R(r))
                }
            } else {
                src: Opnd
                if vi.op == Const && fits32(vi.k) {
                    src = I(vi.k)
                } else {
                    src = R(self.reg(val))
                }
                m := self.addr(i.args[0])
                self.e(Mov, sz_of(ty), M(m), src)
            }
        }
        Call, CallInd => self.call(v, i)
        Syscall => {
            sr := [7]i64{RAX, RDI, RSI, RDX, R10, R8, R9}
            srcs := vec[Opnd]()
            for a in i.args {
                srcs.push(self.mov_src(a))
            }
            used := vec[i64]()
            for k in 0..srcs.len {
                self.e(Mov, 8, R(sr[k]), srcs[k])
                used.push(sr[k])
            }
            self.out.push(self.mf.mir_with_uses(MOp.Syscall, 0, Opnd.None, used.items()))
            if self.needed[v] {
                d := self.vr(v)
                self.e(Mov, 8, R(d), R(RAX))
            }
        }
        MemCpy, MemSet => {
            d := self.mov_src(i.args[0])
            s := self.mov_src(i.args[1])
            n := self.mov_src(i.args[2])
            self.e(Mov, 8, R(RDI), d)
            self.e(Mov, 8, R(if i.op == MemCpy { RSI } else { RAX }), s)
            self.e(Mov, 8, R(RCX), n)
            self.e(if i.op == MemCpy { RepMovsb } else { RepStosb }, 0, Opnd.None, Opnd.None)
        }
        FExt, FTrunc => {
            d := self.vr(v)
            s := self.xm(i.args[0])
            self.e(Zero, 8, R(d), Opnd.None)
            self.e(Cvtf, fsz(ty), R(d), s)
        }
        VSplat => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(MovSd, 8, R(d), R(s))
            self.shufps(d, d, 0)
        }
        VBuild => {
            d := self.vr(v)
            consts := vec[Opt[u32]]()
            all_const := true
            for a in i.args {
                if self.f.insts[a].op == FConst {
                    consts.push(Some(u32(self.f.insts[a].k)))
                } else {
                    consts.push(None)
                    all_const = false
                }
            }
            if all_const {
                // bits |= (c as u128) << (32 * k), on the two halves
                bits := Bits128{lo: 0, hi: 0}
                for k in 0..consts.len {
                    match consts[k] {
                        Some(c) => {
                            sh := (32 * k) & 127
                            if sh < 64 {
                                bits.lo |= u64(c) << sh
                            } else {
                                bits.hi |= u64(c) << (sh - 64)
                            }
                        }
                        None => {}
                    }
                }
                if bits.lo == 0 && bits.hi == 0 {
                    self.e(Zero, 8, R(d), Opnd.None)
                } else {
                    m := self.fconst(bits)
                    self.e(MovSd, 16, R(d), M(m))
                }
                return
            }
            rs := vec[i64]()
            for a in i.args {
                rs.push(self.reg(a))
            }
            self.e(MovSd, 8, R(d), R(rs[0]))
            self.e(Unpcklps, 16, R(d), R(rs[1]))
            if rs.len == 3 {
                self.shufps(d, rs[2], 0x44)
            } else if rs.len == 4 {
                t := new_vreg(&self.mf, 1)
                self.e(MovSd, 8, R(t), R(rs[2]))
                self.e(Unpcklps, 16, R(t), R(rs[3]))
                self.shufps(d, t, 0x44)
            }
        }
        VExt => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(MovSd, 8, R(d), R(s))
            if i.k != 0 {
                self.shufps(d, d, i.k)
            }
        }
        VIns => {
            d := self.vr(v)
            x := self.reg(i.args[0])
            s := self.reg(i.args[1])
            k := i.k
            if k == 0 {
                self.e(MovSd, 8, R(d), R(x))
                self.e(Movlo, 4, R(d), R(s))
            } else if k == 1 {
                // [x0, s, x1, s1] then lanes 2, 3 from x
                self.e(MovSd, 8, R(d), R(x))
                self.e(Unpcklps, 16, R(d), R(s))
                self.shufps(d, x, 0xE4)
            } else {
                // t = [s, s, x3, x3] (lane 2) or [s, s, x2, x2] (lane 3)
                t := new_vreg(&self.mf, 1)
                self.e(MovSd, 8, R(t), R(s))
                self.shufps(t, x, if k == 2 { 0xF0 } else { 0xA0 })
                self.e(MovSd, 8, R(d), R(x))
                self.shufps(d, t, if k == 2 { 0x84 } else { 0x24 })
            }
        }
        VShuf => {
            d := self.vr(v)
            a := self.reg(i.args[0])
            self.e(MovSd, 8, R(d), R(a))
            if i.args[0] == i.args[1] {
                self.shufps(d, d, i.k)
            } else {
                b := self.reg(i.args[1])
                self.shufps(d, b, i.k)
            }
        }
        Bswap, Popcnt, Ctz, Clz => {
            d := self.vr(v)
            sz := osz(ty)
            if i.op == Bswap {
                s := self.reg(i.args[0])
                self.e(Mov, 8, R(d), R(s))
                self.e(MOp.Bswap, sz, R(d), Opnd.None)
                if ty == I16 {
                    self.e(Shr, 4, R(d), I(16))
                } else if ty == I8 {
                    self.e(Shr, 4, R(d), I(24))
                }
            } else {
                s := self.ext32(i.args[0], false)
                mop := match i.op {
                    Popcnt => MOp.Popcnt
                    Ctz => Tzcnt
                    _ => Lzcnt
                }
                self.e(mop, sz, R(d), R(s))
                if i.op == Clz && (ty == I8 || ty == I16) {
                    self.e(MOp.Sub, 4, R(d), I(32 - ty.bits()))
                }
                if i.op == Ctz && (ty == I8 || ty == I16) {
                    // tzcnt of a zero-extended zero gives 32: clamp to the type width
                    t := new_vreg(&self.mf, 0)
                    self.e(Mov, 8, R(t), I(ty.bits()))
                    self.e(Cmp, 4, R(d), R(t))
                    mi := minst_new(Cmov, 4, R(d), R(t))
                    mi.cc = CC_A
                    self.out.push(mi)
                }
            }
        }
        _ => {
            // (no other arm is a compare)
            if i.op.is_cmp() {
                d := self.vr(v)
                cf := self.cmp_flags(v)
                cc := cf.0
                extra := cf.1
                s := minst_new(Setcc, 1, R(d), Opnd.None)
                s.cc = cc
                self.out.push(s)
                if extra != 0 {
                    t := new_vreg(&self.mf, 0)
                    s2 := minst_new(Setcc, 1, R(t), Opnd.None)
                    s2.cc = if extra == 1 { CC_NP } else { CC_P }
                    self.out.push(s2)
                    self.e(if extra == 1 { MOp.And } else { MOp.Or }, 4, R(d), R(t))
                }
            } else {
                // the variant name without its `Op` prefix, as `{:?}` prints it
                panic(fmt("isel: unhandled op ", fmt(i.op)[2..]))
            }
        }
    }
}

// a value with a single use that is defined in the block being selected ends its life at
// that use, so a two-address instruction can reuse its register
priv fn dies_here(self: *Sel, v: i64) -> bool {
    return self.uses[v] == 1 && self.blk_of[v] == self.cur_block && self.f.insts[v].op != Phi
}

priv fn uses_of_reg_single(self: *Sel, i: *Inst, base: i64) -> bool {
    // x + const where x dies here: two-address add coalesces
    for a in i.args {
        if self.vreg[a] == base {
            return self.dies_here(a)
        }
    }
    return false
}

priv fn call(self: *Sel, v: i64, i: *Inst) {
    self.mf.has_calls = true
    target: Opt[i64] = None
    args := i.args.items()
    if i.op == CallInd {
        target = Some(i.args[0])
        args = args[1..]
    }
    // evaluate sources
    ni := 0
    nf := 0
    nstack := 0
    reg_moves := vec[(i64, Opnd, bool)]()
    stack_moves := vec[(i64, Opnd, u8)]()
    for a in args {
        at := self.f.insts[a].ty
        if at.is_fp() {
            r := R(self.reg(a))
            if nf < NUM_FLOAT_ARGS {
                reg_moves.push((XMM0 + nf, r, true))
                nf += 1
            } else {
                stack_moves.push((nstack, r, fsz(at)))
                nstack += if at.is_vec() { 2 } else { 1 }
            }
        } else if ni < len(INT_ARGS) {
            s := self.mov_src(a)
            reg_moves.push((INT_ARGS[ni], s, false))
            ni += 1
        } else {
            ms := self.mov_src(a)
            s := match ms {
                I(k) if fits32(k) => I(k)
                R(r) => R(r)
                _ => R(self.reg(a))
            }
            stack_moves.push((nstack, s, 0))
            nstack += 1
        }
    }
    tr: Opt[i64] = match target {
        Some(t) => Some(self.reg(t))
        None => None
    }
    self.mf.out_args = max(self.mf.out_args, nstack)
    for sm in stack_moves {
        m := Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MK_OUTARG, id: i32(sm.0)}
        if sm.2 != 0 {
            self.e(MovSd, sm.2, M(m), sm.1)
        } else {
            self.e(Mov, 8, M(m), sm.1)
        }
    }
    used := vec[i64]()
    for rm in reg_moves {
        self.e(if rm.2 { MovSd } else { Mov }, 8, R(rm.0), rm.1)
        used.push(rm.0)
    }
    if i.op == CallInd && i.aux == 1 {
        // C calling convention: al = number of vector registers used (for variadic callees)
        self.e(Mov, 4, R(RAX), I(nf))
        used.push(RAX)
    }
    match tr {
        Some(r) => {
            self.out.push(self.mf.mir_with_uses(MOp.CallInd, 8, R(r), used.items()))
        }
        None => {
            c := self.mf.mir_with_uses(MOp.Call, 0, Opnd.None, used.items())
            c.tgt = i32(i.k)
            self.out.push(c)
        }
    }
    // results
    if i.ty != Void {
        if self.needed[v] {
            d := self.vr(v)
            if i.ty.is_fp() {
                self.e(MovSd, 8, R(d), R(XMM0))
            } else {
                self.e(Mov, 8, R(d), R(RAX))
            }
        }
    } else {
        ps, has := self.projs.get(v)
        if has {
            // multi-value results: assign registers in order of result index
            by_idx := clone(ps)
            sort_by(by_idx.items(), fn(a: (i64, i64), b: (i64, i64)) -> bool { a.0 < b.0 || (a.0 == b.0 && a.1 < b.1) })
            maxi := -1
            for p in by_idx {
                if p.0 > maxi {
                    maxi = p.0
                }
            }
            // result types: from callee signature when known, else from projections
            types := vec[T]()
            if i.op == Call {
                types = clone(self.m.funcs[i.k].rets)
            } else {
                for k in 0..=maxi {
                    t := I64
                    for p in by_idx {
                        if p.0 == k {
                            t = self.f.insts[p.1].ty
                            break
                        }
                    }
                    types.push(t)
                }
            }
            ni2 := 0
            nf2 := 0
            locs := vec[i64]()
            for t in types {
                if t.is_fp() {
                    locs.push(XMM0 + nf2)
                    nf2 += 1
                } else {
                    locs.push(INT_RETS[ni2])
                    ni2 += 1
                }
            }
            for kp in by_idx {
                k := kp.0
                p := kp.1
                if !self.needed[p] {
                    continue
                }
                d := self.vr(p)
                isf := self.f.insts[p].ty.is_fp()
                self.e(if isf { MovSd } else { Mov }, 8, R(d), R(locs[k]))
            }
        }
    }
}
