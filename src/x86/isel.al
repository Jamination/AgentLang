// Instruction selection: SSA IR -> x86-64 machine IR with virtual registers.

// A header phi `p` whose old value is needed after the loop is found in the register of the
// header phi `q` that receives it on the back edge.
struct ExitAlias {
    p i64
    q i64
    header i64
}

fn isel_split_critical_edges_is_hphi(f *Func, def_block *Vec[i64], header i64, v i64) bool {
    return f.insts[v].op == OpPhi && def_block[v] == header
}

// operands folded into the compare are evaluated after the copies: they must not
// depend on a header phi through anything that gets folded (addresses, test operands)
fn isel_split_critical_edges_tree_has(f *Func, v i64, depth i64, def_block *Vec[i64], header i64) bool {
    if isel_split_critical_edges_is_hphi(f, def_block, header, v) {
        return true
    }
    i := &f.insts[v]
    if !(i.op == OpAdd || i.op == OpSub || i.op == OpShl || i.op == OpMul || i.op == OpLoad || i.op == OpAnd) {
        return false
    }
    if depth == 0 {
        return true
    }
    for a in i.args.items() {
        if isel_split_critical_edges_tree_has(f, a, depth - 1, def_block, header) {
            return true
        }
    }
    return false
}

fn isel_term_is_trap(t Term) bool {
    match t {
        TermTrap => true
        _ => false
    }
}

fn isel_term_is_ret(t Term) bool {
    match t {
        TermRet(vs) => true
        _ => false
    }
}

// can the back edge latch -> header stay unsplit? returns the aliases needed after the loop
fn isel_split_critical_edges_analyze(f *Func, cfg *Cfg, loops *Loops, def_block *Vec[i64], nb i64, latch i64, header i64, other i64, c i64) (Vec[ExitAlias], bool) {
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
    for v in f.blocks[header].insts.items() {
        if f.insts[v].op != OpPhi {
            break
        }
        phis.push(v)
    }
    if phis.is_empty() {
        return (none, false)
    }
    // the branch condition (and what gets folded into it) must not read the header phis
    ci := &f.insts[c]
    if isel_split_critical_edges_is_hphi(f, def_block, header, c) {
        return (none, false)
    }
    if ci.op.is_cmp() {
        for a in ci.args.items() {
            if isel_split_critical_edges_is_hphi(f, def_block, header, a) {
                return (none, false)
            }
        }
    }
    for a in ci.args.items() {
        ai := &f.insts[a]
        if (ai.op == OpAnd || ai.op == OpLoad) && isel_split_critical_edges_tree_has(f, a, 12, def_block, header) {
            return (none, false)
        }
    }
    // every other way out of the loop must be a trap
    trap_exits := vec[i64]()
    for b in l.blocks.items() {
        ss := f.succs(b)
        for s in ss.items() {
            if loops.contains(li, s) || (b == latch && s == other) {
                continue
            }
            if !isel_term_is_trap(f.blocks[s].term) {
                return (none, false)
            }
            trap_exits.push(s)
        }
        if isel_term_is_ret(f.blocks[b].term) {
            return (none, false)
        }
    }
    // Instruction selection may evaluate address arithmetic and compares lazily at their
    // use. Anything computed from a header phi inside the loop that could be re-evaluated
    // after the loop would then read the already-updated phi register: keep the edge split.
    derived := clone(&phis)
    qi := 0
    while qi < derived.len {
        x := derived[qi]
        qi += 1
        for b in l.blocks.items() {
            for u in f.blocks[b].insts.items() {
                ui := &f.insts[u]
                lazy := ui.op == OpAdd || ui.op == OpSub || ui.op == OpShl || ui.op == OpMul || ui.op == OpAnd || ui.op.is_cmp()
                if lazy && contains(&ui.args, x) && !contains(&derived, u) {
                    derived.push(u)
                }
            }
        }
    }
    for b in 0..nb {
        if !cfg.reachable(b) || loops.contains(li, b) {
            continue
        }
        for v in f.blocks[b].insts.items() {
            for a in f.insts[v].args.items() {
                if contains(&derived, a) && !contains(&phis, a) {
                    return (none, false)
                }
            }
        }
        tu := f.term_uses(b)
        for a in tu.items() {
            if contains(&derived, a) && !contains(&phis, a) {
                return (none, false)
            }
        }
    }
    // phis used after the loop need a partner that receives them on the back edge
    out := vec[ExitAlias]()
    for b in 0..nb {
        if !cfg.reachable(b) || loops.contains(li, b) {
            continue
        }
        used := vec[i64]()
        for v in f.blocks[b].insts.items() {
            for a in f.insts[v].args.items() {
                if contains(&phis, a) {
                    used.push(a)
                }
            }
        }
        tu := f.term_uses(b)
        for a in tu.items() {
            if contains(&phis, a) {
                used.push(a)
            }
        }
        if used.is_empty() {
            continue
        }
        if contains(&trap_exits, b) {
            return (none, false)
        }
        for p in used.items() {
            partner := -1
            for q in phis.items() {
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
    }
    return (out, true)
}

// Split critical edges so that phi copies have a place to live. A loop back edge is left alone
// when the loop is only left through its latch (or through traps): its copies are emitted in
// the latch before the branch, and uses of header phis after the loop are redirected.
fn isel_split_critical_edges(f *Func) Vec[ExitAlias] {
    cfg := cfg_new(f)
    loops := loops_new(f, &cfg)
    preds := f.preds()
    nb := f.blocks.len
    def_block := f.block_of()
    aliases := vec[ExitAlias]()
    // decide first (on the unmodified CFG), then split
    keep := vec[(i64, i64)]()
    for b in 0..nb {
        tm := f.blocks[b].term
        match tm {
            TermBr(c, t, e) => {
                if t == e {
                    continue
                }
                for w in 0..2 {
                    s := if w == 0 { t } else { e }
                    other := if w == 0 { e } else { t }
                    if preds[s].len > 1 {
                        al, ok := isel_split_critical_edges_analyze(f, &cfg, &loops, &def_block, nb, b, s, other, c)
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
            TermBr(c, t, e) => {
                if t == e {
                    f.blocks[b].term = TermJmp(t)
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
                        f.blocks[nbk].term = TermJmp(s)
                        for ii in 0..f.blocks[s].insts.len {
                            v := f.blocks[s].insts[ii]
                            if f.insts[v].op != OpPhi {
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
                f.blocks[b].term = TermBr(c, nt, ne)
            }
            _ => {}
        }
    }
    return aliases
}

fn isel_sz_of(t T) u8 {
    match t {
        TI8 => 1
        TI16 => 2
        TI32 => 4
        _ => 8
    }
}

// operation size for wrap-around arithmetic: narrow types use 32-bit instructions
fn isel_osz(t T) u8 {
    match t {
        TI64 => 8
        _ => 4
    }
}

fn isel_fits32(k i64) bool {
    return k >= -2147483648 && k <= 2147483647
}

// operation size of an xmm type: scalar single, scalar double, packed
fn isel_fsz(t T) u8 {
    match t {
        TF32 => 4
        TF64 => 8
        _ => 16
    }
}

// size of a plain memory move of an xmm type (vec3 takes two moves)
fn isel_fsz_mem(t T) u8 {
    match t {
        TF32 => 4
        TF64, TV2 => 8
        _ => 16
    }
}

// is v the integer constant k? (`f.is_const(v) == Some(k)`)
fn isel_const_is(f *Func, v i64, k i64) bool {
    match f.is_const(v) {
        Some(x) => x == k
        None => false
    }
}

fn isel_is_r(o Opnd) bool {
    match o {
        OpndR(r) => true
        _ => false
    }
}

// order of (result index, value) pairs
fn isel_proj_less(a (i64, i64), b (i64, i64)) bool {
    return a.0 < b.0 || (a.0 == b.0 && a.1 < b.1)
}

struct IselSel {
    f *Func
    m *Module
    mf MFunc
    vreg Vec[i64]
    uses Vec[i64]
    needed Vec[bool]
    addr_only Vec[bool]
    blk_of Vec[i64]
    slot_of Map[i64, i64]
    projs Map[i64, Vec[(i64, i64)]]
    out Vec[MInst]
    fconst_ix Map[Bits128, i64]
    // memory-clobber counter position of each instruction within its block (for load folding)
    pos_in_block Vec[i64]
    clob Vec[i64]
    cur_clob i64
    cur_block i64
    exit_alias Map[i64, (i64, i64)]
    loops Loops
}

// moves the instructions selected into s.out to the end of rev, in reverse order
fn isel_drain_rev(s *IselSel, rev *Vec[MInst]) {
    k := s.out.len - 1
    while k >= 0 {
        rev.push(s.out[k])
        k -= 1
    }
    s.out.clear()
}

fn isel_select(f *Func, m *Module, depths []i64, aliases []ExitAlias) MFunc {
    n := f.insts.len
    cfg := cfg_new(f)
    loops := loops_new(f, &cfg)
    exit_alias := map[i64, (i64, i64)]()
    for a in aliases {
        for li in 0..loops.loops.len {
            if loops.loops[li].header == a.header {
                exit_alias.set(a.p, (a.q, li))
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
    s := IselSel{
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
        },
        vreg: vec_fill(n, NOREG),
        uses: f.use_counts(),
        needed: vec_fill(n, false),
        addr_only: vec_fill(n, true),
        blk_of: f.block_of(),
        slot_of: map[i64, i64](),
        projs: map[i64, Vec[(i64, i64)]](),
        out: vec[MInst](),
        fconst_ix: map[Bits128, i64](),
        pos_in_block: vec_fill(n, 0),
        clob: vec_fill(n, 0),
        cur_clob: 0,
        cur_block: 0,
        exit_alias: exit_alias,
        loops: loops,
    }
    for b in 0..f.blocks.len {
        s.mf.blocks.push(MBlock{insts: vec[MInst](), succs: f.succs(b), depth: if b < len(depths) { depths[b] } else { 0 }, align: false})
    }
    // per-value facts
    for bi in 0..f.blocks.len {
        b := &f.blocks[bi]
        nclob := 0
        for pi in 0..b.insts.len {
            v := b.insts[pi]
            s.pos_in_block[v] = pi
            s.clob[v] = nclob
            if cleanup_is_root(f.insts[v].op) {
                nclob += 1
            }
            i := &f.insts[v]
            match i.op {
                OpLoad => {}
                OpStore => {
                    s.addr_only[i.args[1]] = false
                }
                OpProj => {
                    a0 := i.args[0]
                    pl, has := s.projs.get(a0)
                    if !has {
                        pl = vec[(i64, i64)]()
                    }
                    pl.push((i.k, v))
                    s.projs.set(a0, pl)
                    s.addr_only[a0] = false
                }
                _ => {
                    for a in i.args.items() {
                        s.addr_only[a] = false
                    }
                }
            }
        }
        bt := b.term
        match bt {
            TermBr(c, t, e) => {
                s.addr_only[c] = false
            }
            TermRet(vs) => {
                for v in vs.items() {
                    s.addr_only[v] = false
                }
            }
            _ => {}
        }
    }
    for v in f.blocks[0].insts.items() {
        if f.insts[v].op == OpAlloca {
            sl := new_slot(&s.mf, f.insts[v].k, f.insts[v].aux)
            s.slot_of.set(v, sl)
        }
    }
    rpo := f.rpo()
    for ri in rpo.len - 1..=0 by -1 {
        b := rpo[ri]
        s.cur_block = b
        nroot := 0
        for v in f.blocks[b].insts.items() {
            if cleanup_is_root(f.insts[v].op) {
                nroot += 1
            }
        }
        s.cur_clob = nroot
        rev := vec[MInst]()
        // terminator (with phi copies for the unique successor)
        s.out.clear()
        s.term(b)
        isel_drain_rev(&s, &rev)
        for vi in f.blocks[b].insts.len - 1..=0 by -1 {
            v := f.blocks[b].insts[vi]
            op := f.insts[v].op
            if op == OpConst && s.needed[v] {
                // a wide constant kept in a register (so that loops do not rebuild it)
                d := s.vr(v)
                rev.push(minst_new(MOpMov, 8, OpndR(d), OpndI(f.insts[v].k)))
                continue
            }
            if op == OpPhi || op == OpParam || op == OpAlloca || op == OpConst || op == OpFConst || op == OpGAddr || op == OpFAddr || op == OpProj {
                continue
            }
            if cleanup_is_root(op) || s.needed[v] {
                s.out.clear()
                s.cur_clob = s.clob[v]
                s.inst(v)
                isel_drain_rev(&s, &rev)
            }
        }
        if b == 0 {
            s.out.clear()
            s.params()
            isel_drain_rev(&s, &rev)
        }
        reverse(rev.items())
        s.mf.blocks[b].insts = rev
    }
    return s.mf
}

fn e(self *IselSel, op MOp, sz u8, a Opnd, b Opnd) {
    self.out.push(minst_new(op, sz, a, b))
}

fn shufps(self *IselSel, d i64, s i64, imm i64) {
    mi := minst_new(MOpShufps, 16, OpndR(d), OpndR(s))
    mi.c = OpndI(imm)
    self.out.push(mi)
}

fn class_of(self *IselSel, v i64) u8 {
    if self.f.insts[v].ty.is_fp() {
        return 1
    }
    return 0
}

// the vreg holding IR value v (allocated on demand)
fn vr(self *IselSel, v i64) i64 {
    if self.vreg[v] == NOREG {
        c := self.class_of(v)
        self.vreg[v] = new_vreg(&self.mf, c)
    }
    return self.vreg[v]
}

fn fconst(self *IselSel, bits Bits128) Mem {
    ix, has := self.fconst_ix.get(bits)
    if !has {
        self.mf.fconsts.push(bits)
        ix = self.mf.fconsts.len - 1
        self.fconst_ix.set(bits, ix)
    }
    return Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKindFConst, id: ix}
}

// the frame slot of the alloca v (`self.slot_of[&v]`)
fn isel_slot_of(s *IselSel, v i64) i64 {
    sl, ok := s.slot_of.get(v)
    assert ok, "isel: alloca without a slot"
    return sl
}

// a register holding v at the current point (materializes constants and addresses)
fn reg(self *IselSel, v i64) i64 {
    i := &self.f.insts[v]
    if i.op == OpConst && (isel_fits32(i.k) || self.blk_of[v] == self.cur_block) {
        r := new_vreg(&self.mf, 0)
        self.e(MOpMov, 8, OpndR(r), OpndI(i.k))
        return r
    }
    if i.op == OpFConst {
        r := new_vreg(&self.mf, 1)
        if i.k == 0 {
            self.e(MOpZero, 8, OpndR(r), OpndNone)
        } else {
            m := self.fconst(Bits128{lo: u64(i.k), hi: 0})
            self.e(MOpMovSd, 8, OpndR(r), OpndM(m))
        }
        return r
    }
    if i.op == OpGAddr {
        r := new_vreg(&self.mf, 0)
        self.e(MOpMov, 8, OpndR(r), OpndGAddr(i.k, 0))
        return r
    }
    if i.op == OpFAddr {
        r := new_vreg(&self.mf, 0)
        self.e(MOpMov, 8, OpndR(r), OpndFAddr(i.k))
        return r
    }
    if i.op == OpAlloca {
        r := new_vreg(&self.mf, 0)
        sl := isel_slot_of(self, v)
        self.e(MOpLea, 8, OpndR(r), OpndM(mem_slot(sl, 0)))
        return r
    }
    qa, has := self.exit_alias.get(v)
    if has {
        if !contains(&self.loops, qa.1, self.cur_block) {
            // after the loop the old value of this phi lives in its partner
            self.needed[qa.0] = true
            return self.vr(qa.0)
        }
    }
    self.needed[v] = true
    return self.vr(v)
}

// register or 32-bit immediate
fn rmi(self *IselSel, v i64) Opnd {
    match self.f.is_const(v) {
        Some(k) => {
            if isel_fits32(k) {
                return OpndI(k)
            }
        }
        None => {}
    }
    return OpndR(self.reg(v))
}

// can the load `v` be folded into the instruction currently being selected?
fn can_fold_load(self *IselSel, v i64) bool {
    i := &self.f.insts[v]
    return i.op == OpLoad &&
        self.uses[v] == 1 &&
        self.blk_of[v] == self.cur_block &&
        self.clob[v] == self.cur_clob &&
        self.vreg[v] == NOREG &&
        !self.needed[v]
}

fn load_mem(self *IselSel, v i64) Opt[Mem] {
    if !self.can_fold_load(v) {
        return None
    }
    a := self.f.insts[v].args[0]
    return Some(self.addr(a))
}

// register, 32-bit immediate, or a folded load of the full operation width
fn rmi_mem(self *IselSel, v i64, ty T) Opnd {
    if (ty == TI32 || ty == TI64) && self.f.insts[v].ty == ty {
        match self.load_mem(v) {
            Some(m) => {
                return OpndM(m)
            }
            None => {}
        }
    }
    return self.rmi(v)
}

// xmm register or memory (float constant or folded load)
fn xm(self *IselSel, v i64) Opnd {
    i := &self.f.insts[v]
    if i.op == OpFConst && i.k != 0 {
        m := self.fconst(Bits128{lo: u64(i.k), hi: 0})
        return OpndM(m)
    }
    if i.ty.is_vec() {
        // packed operations need aligned memory operands: vector loads are never folded
        return OpndR(self.reg(v))
    }
    match self.load_mem(v) {
        Some(m) => {
            return OpndM(m)
        }
        None => {}
    }
    return OpndR(self.reg(v))
}

// ---------- addressing modes ----------
fn isel_foldable_add_leafy(s *IselSel, a i64) bool {
    op := s.f.insts[a].op
    return op == OpConst || op == OpGAddr || op == OpAlloca
}

fn foldable_add(self *IselSel, v i64) bool {
    i := &self.f.insts[v]
    if i.op != OpAdd || i.ty != TI64 {
        return false
    }
    if self.uses[v] <= 1 || self.addr_only[v] {
        return true
    }
    // x + const never lengthens live ranges
    return isel_foldable_add_leafy(self, i.args[0]) || isel_foldable_add_leafy(self, i.args[1])
}

fn addr_term(self *IselSel, v i64, m *Mem, depth i64) {
    i := &self.f.insts[v]
    if i.op == OpConst && isel_fits32(i.k) && isel_fits32(i64(m.disp) + i.k) {
        m.disp += i32(i.k)
        return
    }
    if i.op == OpGAddr && m.kind == MemKindNormal {
        m.kind = MemKindGlobal
        m.id = i.k
        return
    }
    if i.op == OpAlloca && m.kind == MemKindNormal && m.base == NOREG {
        m.kind = MemKindSlot
        m.id = isel_slot_of(self, v)
        return
    }
    if i.op == OpAdd && depth < 8 && self.foldable_add(v) {
        a := i.args[0]
        b := i.args[1]
        self.addr_term(a, m, depth + 1)
        self.addr_term(b, m, depth + 1)
        return
    }
    if (i.op == OpShl || i.op == OpMul) && m.idx == NOREG && i.ty == TI64 {
        match self.f.is_const(i.args[1]) {
            Some(k) => {
                var scale u8 = 0
                if i.op == OpShl {
                    if k >= 1 && k <= 3 {
                        scale = u8(1) << k
                    }
                } else if k == 2 || k == 4 || k == 8 {
                    scale = u8(k)
                }
                if scale != 0 {
                    x := i.args[0]
                    m.idx = self.reg(x)
                    m.scale = scale
                    return
                }
            }
            None => {}
        }
    }
    r := self.reg(v)
    base_free := m.base == NOREG && m.kind != MemKindSlot
    if base_free {
        m.base = r
    } else if m.idx == NOREG {
        m.idx = r
        m.scale = 1
    } else {
        // out of components: collapse what we have into a temporary
        t := new_vreg(&self.mf, 0)
        self.e(MOpLea, 8, OpndR(t), OpndM(*m))
        *m = mem_new()
        m.base = t
        m.idx = r
        m.scale = 1
    }
}

fn addr(self *IselSel, v i64) Mem {
    m := mem_new()
    self.addr_term(v, &m, 0)
    return m
}

// ---------- parameters ----------
fn params(self *IselSel) {
    ni := 0
    nf := 0
    nstack := 0
    // locate Param instructions by index
    by_index := map[i64, i64]()
    for bi in 0..self.f.blocks.len {
        for v in self.f.blocks[bi].insts.items() {
            if self.f.insts[v].op == OpParam {
                by_index.set(self.f.insts[v].k, v)
            }
        }
    }
    params := self.f.params
    for pi in 0..params.len {
        t := params[pi]
        pv, has := by_index.get(pi)
        want := has && self.needed[pv]
        if t.is_fp() {
            if nf < NUM_FLOAT_ARGS {
                if want {
                    d := self.vr(pv)
                    self.e(MOpMovSd, 8, OpndR(d), OpndR(XMM0 + nf))
                }
                nf += 1
            } else {
                if want {
                    d := self.vr(pv)
                    m := Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKindInArg, id: nstack}
                    self.e(MOpMovSd, isel_fsz(t), OpndR(d), OpndM(m))
                }
                nstack += if t.is_vec() { 2 } else { 1 }
            }
        } else if ni < len(INT_ARGS) {
            if want {
                d := self.vr(pv)
                self.e(MOpMov, 8, OpndR(d), OpndR(INT_ARGS[ni]))
            }
            ni += 1
        } else {
            if want {
                d := self.vr(pv)
                m := Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKindInArg, id: nstack}
                self.e(MOpMov, 8, OpndR(d), OpndM(m))
            }
            nstack += 1
        }
    }
}

// ---------- terminators ----------
fn phi_copies(self *IselSel, b i64, s i64) {
    // parallel copies for the phis of s along edge b -> s
    moves := vec[(i64, Opnd, u8)]()
    phis := vec[i64]()
    for v in self.f.blocks[s].insts.items() {
        if self.f.insts[v].op != OpPhi {
            break
        }
        phis.push(v)
    }
    for p in phis.items() {
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
        var so Opnd
        if si.op == OpConst {
            so = OpndI(si.k)
        } else if si.op == OpGAddr {
            so = OpndGAddr(si.k, 0)
        } else if si.op == OpFAddr {
            so = OpndFAddr(si.k)
        } else if si.op == OpFConst && si.k == 0 {
            so = OpndNone
        } else if si.op == OpFConst {
            so = OpndM(self.fconst(Bits128{lo: u64(si.k), hi: 0}))
        } else if si.op == OpAlloca {
            so = OpndM(mem_slot(isel_slot_of(self, src), 0))
        } else {
            r := self.reg(src)
            if r == d {
                continue
            }
            so = OpndR(r)
        }
        moves.push((d, so, cls))
    }
    // sequentialize: register sources first, respecting dependencies
    pending := vec[(i64, Opnd, u8)]()
    for mv in moves.items() {
        if isel_is_r(mv.1) {
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
                if j != i && eq(pending[j].1, OpndR(d)) {
                    blocked = true
                    break
                }
            }
            if !blocked {
                mv := pending.remove(i)
                self.e(if mv.2 == 1 { MOpMovSd } else { MOpMov }, 8, OpndR(mv.0), mv.1)
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
            self.e(if cls == 1 { MOpMovSd } else { MOpMov }, 8, OpndR(t), OpndR(d))
            for j in 0..pending.len {
                if eq(pending[j].1, OpndR(d)) {
                    pending[j].1 = OpndR(t)
                }
            }
        }
    }
    for mv in moves.items() {
        d := mv.0
        s2 := mv.1
        match s2 {
            OpndR(r) => {}
            OpndNone => self.e(MOpZero, 8, OpndR(d), OpndNone)
            OpndM(m) => {
                if m.kind == MemKindSlot {
                    self.e(MOpLea, 8, OpndR(d), s2)
                } else {
                    self.e(MOpMovSd, 8, OpndR(d), s2)
                }
            }
            _ => self.e(MOpMov, 8, OpndR(d), s2)
        }
    }
}

// emit a flag-setting compare for IR compare `c`; returns the condition code(s) to test
// result: (cc, extra) where extra: 0 = none, 1 = "and not parity" (FEq), 2 = "or parity" (FNe)
fn cmp_flags(self *IselSel, c i64) (u8, u8) {
    i := &self.f.insts[c]
    a := i.args[0]
    b := i.args[1]
    at := self.f.insts[a].ty
    if i.op.is_icmp() {
        sz := isel_sz_of(at)
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
            OpEq => CC_E
            OpNe => CC_NE
            OpSlt => CC_L
            OpSle => CC_LE
            OpSgt => CC_G
            OpSge => CC_GE
            OpUlt => CC_B
            OpUle => CC_BE
            OpUgt => CC_A
            _ => CC_AE
        }
        if isel_const_is(self.f, y, 0) && (op == OpEq || op == OpNe || op == OpSlt || op == OpSle || op == OpSgt || op == OpSge) && !self.can_fold_load(x) {
            // test x, x  (or test a, b for (a & b) ==/!= 0)
            xi := &self.f.insts[x]
            if (op == OpEq || op == OpNe) && xi.op == OpAnd && self.uses[x] == 1 && self.blk_of[x] == self.cur_block {
                p := xi.args[0]
                q := xi.args[1]
                pr := self.reg(p)
                qo := self.rmi(q)
                self.e(MOpTest, sz, OpndR(pr), qo)
                return (cc, 0)
            }
            xr := self.reg(x)
            self.e(MOpTest, sz, OpndR(xr), OpndR(xr))
            return (cc, 0)
        }
        // memory operands: cmp [mem], imm  /  cmp reg, [mem]
        match self.f.is_const(y) {
            Some(k) => {
                if isel_fits32(k) {
                    match self.load_mem(x) {
                        Some(m) => {
                            self.e(MOpCmp, sz, OpndM(m), OpndI(k))
                            return (cc, 0)
                        }
                        None => {}
                    }
                }
            }
            None => {}
        }
        xr := self.reg(x)
        var yo Opnd
        match self.load_mem(y) {
            Some(m) => {
                yo = OpndM(m)
            }
            None => {
                yo = self.rmi(y)
            }
        }
        self.e(MOpCmp, sz, OpndR(xr), yo)
        return (cc, 0)
    }
    // float compares: arrange operands so that unordered yields false
    if i.op == OpFLt || i.op == OpFLe {
        br := self.reg(b)
        ao := self.xm(a)
        self.e(MOpUcomisd, isel_fsz(at), OpndR(br), ao)
        return (if i.op == OpFLt { CC_A } else { CC_AE }, 0)
    }
    if i.op == OpFGt || i.op == OpFGe {
        ar := self.reg(a)
        bo := self.xm(b)
        self.e(MOpUcomisd, isel_fsz(at), OpndR(ar), bo)
        return (if i.op == OpFGt { CC_A } else { CC_AE }, 0)
    }
    if i.op == OpFEq {
        ar := self.reg(a)
        bo := self.xm(b)
        self.e(MOpUcomisd, isel_fsz(at), OpndR(ar), bo)
        return (CC_E, 1)
    }
    ar := self.reg(a)
    bo := self.xm(b)
    self.e(MOpUcomisd, isel_fsz(at), OpndR(ar), bo)
    return (CC_NE, 2)
}

fn jcc(self *IselSel, cc u8, t i64) {
    i := minst_new(MOpJcc, 0, OpndNone, OpndNone)
    i.cc = cc
    i.tgt = t
    self.out.push(i)
}

fn jmp(self *IselSel, t i64) {
    i := minst_new(MOpJmp, 0, OpndNone, OpndNone)
    i.tgt = t
    self.out.push(i)
}

fn term(self *IselSel, b i64) {
    tm := self.f.blocks[b].term
    match tm {
        TermJmp(t) => {
            self.phi_copies(b, t)
            self.jmp(t)
        }
        TermBr(c, t, e) => {
            // an unsplit loop back edge: its phi copies go before the compare
            for s in ([2]i64{t, e}) {
                has_phi := false
                if self.f.blocks[s].insts.len > 0 {
                    has_phi = self.f.insts[self.f.blocks[s].insts[0]].op == OpPhi
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
                self.e(MOpTest, 1, OpndR(r), OpndR(r))
                self.jcc(CC_NE, t)
                self.jmp(e)
            }
        }
        TermRet(vals) => {
            ni := 0
            nf := 0
            used := vec[i64]()
            moves := vec[(i64, i64)]()
            for v in vals.items() {
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
            for mv in moves.items() {
                v := mv.1
                isf := self.f.insts[v].ty.is_fp()
                var o Opnd
                if !isf {
                    o = self.mov_src(v)
                } else {
                    o = OpndR(self.reg(v))
                }
                srcs.push((mv.0, o, isf))
            }
            for sv in srcs.items() {
                self.e(if sv.2 { MOpMovSd } else { MOpMov }, 8, OpndR(sv.0), sv.1)
                used.push(sv.0)
            }
            i := minst_new(MOpRet, 0, OpndNone, OpndNone)
            i.uses = used
            self.out.push(i)
        }
        TermTrap => {
            self.e(MOpUd2, 0, OpndNone, OpndNone)
        }
        TermNone => {
            self.e(MOpUd2, 0, OpndNone, OpndNone)
        }
    }
}

// a source operand for a full-width integer move: immediate, symbol address or register
fn mov_src(self *IselSel, v i64) Opnd {
    i := &self.f.insts[v]
    if i.op == OpConst {
        return OpndI(i.k)
    }
    if i.op == OpGAddr {
        return OpndGAddr(i.k, 0)
    }
    if i.op == OpFAddr {
        return OpndFAddr(i.k)
    }
    return OpndR(self.reg(v))
}

// ---------- instructions ----------
fn binop(self *IselSel, v i64, mop MOp, commutative bool) {
    i := &self.f.insts[v]
    a := i.args[0]
    b := i.args[1]
    ty := i.ty
    sz := isel_osz(ty)
    wide := ty == TI32 || ty == TI64
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
    self.e(MOpMov, 8, OpndR(d), OpndR(ar))
    self.e(mop, sz, OpndR(d), bo)
}

fn isel_fbinop_is_c(s *IselSel, x i64) bool {
    return s.f.insts[x].op == OpFConst
}

fn fbinop(self *IselSel, v i64, mop MOp, commutative bool) {
    i := &self.f.insts[v]
    a := i.args[0]
    b := i.args[1]
    if commutative && !self.can_fold_load(b) && (isel_fbinop_is_c(self, a) || self.can_fold_load(a) || (self.uses[a] > 1 && self.uses[b] == 1 && !isel_fbinop_is_c(self, b))) {
        tmp := a
        a = b
        b = tmp
    }
    d := self.vr(v)
    ar := self.reg(a)
    bo := self.xm(b)
    sz := isel_fsz(self.f.insts[v].ty)
    self.e(MOpMovSd, 8, OpndR(d), OpndR(ar))
    self.e(mop, sz, OpndR(d), bo)
}

fn zext_free(self *IselSel, v i64) bool {
    i := &self.f.insts[v]
    op := i.op
    return i.ty == TI32 &&
        (op == OpAdd || op == OpSub || op == OpMul || op == OpAnd || op == OpOr || op == OpXor || op == OpShl || op == OpLShr || op == OpAShr ||
        op == OpRotl || op == OpRotr || op == OpLoad || op == OpZExt || op == OpSDiv || op == OpUDiv || op == OpSRem || op == OpURem || op == OpBswap)
}

// value extended to 32 bits (for narrow division/shift inputs)
fn ext32(self *IselSel, v i64, signed bool) i64 {
    t := self.f.insts[v].ty
    r := self.reg(v)
    if t == TI8 || t == TI16 {
        d := new_vreg(&self.mf, 0)
        i := minst_new(if signed { MOpMovsx } else { MOpMovzx }, isel_sz_of(t), OpndR(d), OpndR(r))
        i.sz2 = 4
        self.out.push(i)
        return d
    }
    return r
}

fn inst(self *IselSel, v i64) {
    // (the Rust clones the instruction only to release the borrow; nothing here changes it)
    i := &self.f.insts[v]
    ty := i.ty
    match i.op {
        OpAdd => {
            if ty == TI64 {
                m := mem_new()
                self.addr_term(i.args[0], &m, 1)
                self.addr_term(i.args[1], &m, 1)
                d := self.vr(v)
                simple := m.kind == MemKindNormal && m.idx == NOREG && m.base != NOREG
                if simple && m.disp == 0 {
                    self.e(MOpMov, 8, OpndR(d), OpndR(m.base))
                } else if simple && self.uses_of_reg_single(i, m.base) {
                    self.e(MOpMov, 8, OpndR(d), OpndR(m.base))
                    self.e(MOpAdd, 8, OpndR(d), OpndI(i64(m.disp)))
                } else if m.kind == MemKindNormal && m.base != NOREG && m.idx != NOREG && m.scale == 1 && m.disp == 0 {
                    // a + b: two-address add when one side dies here
                    a := i.args[0]
                    b := i.args[1]
                    ra := m.base
                    rb := m.idx
                    direct := self.vreg[a] == ra && self.vreg[b] == rb
                    if direct && self.dies_here(a) {
                        self.e(MOpMov, 8, OpndR(d), OpndR(ra))
                        self.e(MOpAdd, 8, OpndR(d), OpndR(rb))
                    } else if direct && self.dies_here(b) {
                        self.e(MOpMov, 8, OpndR(d), OpndR(rb))
                        self.e(MOpAdd, 8, OpndR(d), OpndR(ra))
                    } else {
                        self.e(MOpLea, 8, OpndR(d), OpndM(m))
                    }
                } else if m.kind == MemKindGlobal && m.base == NOREG && m.idx == NOREG {
                    self.e(MOpMov, 8, OpndR(d), OpndGAddr(m.id, i64(m.disp)))
                } else {
                    self.e(MOpLea, 8, OpndR(d), OpndM(m))
                }
            } else {
                self.binop(v, MOpAdd, true)
            }
        }
        OpSub => {
            // 0 - x => neg
            if isel_const_is(self.f, i.args[0], 0) {
                d := self.vr(v)
                r := self.reg(i.args[1])
                self.e(MOpMov, 8, OpndR(d), OpndR(r))
                self.e(MOpNeg, isel_osz(ty), OpndR(d), OpndNone)
            } else {
                self.binop(v, MOpSub, false)
            }
        }
        OpMul => {
            a := i.args[0]
            b := i.args[1]
            if is_some(self.f.is_const(a)) {
                tmp := a
                a = b
                b = tmp
            }
            d := self.vr(v)
            match self.f.is_const(b) {
                Some(k) => {
                    if isel_fits32(k) {
                        ar := self.reg(a)
                        mi := minst_new(MOpImul3, isel_osz(ty), OpndR(d), OpndR(ar))
                        mi.c = OpndI(k)
                        self.out.push(mi)
                    } else {
                        // a constant too wide for an immediate: multiply two registers
                        ar := self.reg(a)
                        br := self.reg(b)
                        self.e(MOpMov, 8, OpndR(d), OpndR(ar))
                        self.e(MOpImul, isel_osz(ty), OpndR(d), OpndR(br))
                    }
                }
                None => self.binop(v, MOpImul, true)
            }
        }
        OpAnd => {
            // masks that are zero-extensions
            match self.f.is_const(i.args[1]) {
                Some(k) => {
                    if (k == 0xFF || k == 0xFFFF) && ty != TI8 {
                        d := self.vr(v)
                        r := self.reg(i.args[0])
                        mi := minst_new(MOpMovzx, if k == 0xFF { 1 } else { 2 }, OpndR(d), OpndR(r))
                        mi.sz2 = 4
                        self.out.push(mi)
                        return
                    }
                    if k == 0xFFFF_FFFF && ty == TI64 {
                        d := self.vr(v)
                        r := self.reg(i.args[0])
                        self.e(MOpMov, 4, OpndR(d), OpndR(r))
                        return
                    }
                }
                None => {}
            }
            self.binop(v, MOpAnd, true)
        }
        OpOr => self.binop(v, MOpOr, true)
        OpXor => {
            if isel_const_is(self.f, i.args[1], -1) {
                d := self.vr(v)
                r := self.reg(i.args[0])
                self.e(MOpMov, 8, OpndR(d), OpndR(r))
                self.e(MOpNot, isel_osz(ty), OpndR(d), OpndNone)
            } else {
                self.binop(v, MOpXor, true)
            }
        }
        OpShl, OpLShr, OpAShr, OpRotl, OpRotr => {
            mop := match i.op {
                OpShl => MOpShl
                OpLShr => MOpShr
                OpAShr => MOpSar
                OpRotl => MOpRol
                _ => MOpRor
            }
            sz := isel_sz_of(ty)
            d := self.vr(v)
            bits := ty.bits()
            match self.f.is_const(i.args[1]) {
                Some(k0) => {
                    r := self.reg(i.args[0])
                    self.e(MOpMov, 8, OpndR(d), OpndR(r))
                    k := k0 & (bits - 1)
                    if k != 0 {
                        self.e(mop, sz, OpndR(d), OpndI(k))
                    }
                }
                None => {
                    cnt := self.reg(i.args[1])
                    r := self.reg(i.args[0])
                    self.e(MOpMov, 8, OpndR(RCX), OpndR(cnt))
                    if sz < 4 {
                        self.e(MOpAnd, 4, OpndR(RCX), OpndI(bits - 1))
                    }
                    self.e(MOpMov, 8, OpndR(d), OpndR(r))
                    self.e(mop, sz, OpndR(d), OpndR(RCX))
                }
            }
        }
        OpSDiv, OpUDiv, OpSRem, OpURem => {
            signed := i.op == OpSDiv || i.op == OpSRem
            sz := isel_osz(ty)
            d := self.vr(v)
            a := self.ext32(i.args[0], signed)
            b := self.ext32(i.args[1], signed)
            self.e(MOpMov, 8, OpndR(RAX), OpndR(a))
            if signed {
                self.e(MOpCqo, sz, OpndNone, OpndNone)
                self.e(MOpIdiv, sz, OpndR(b), OpndNone)
            } else {
                self.e(MOpZero, 4, OpndR(RDX), OpndNone)
                self.e(MOpDiv, sz, OpndR(b), OpndNone)
            }
            res := if i.op == OpSDiv || i.op == OpUDiv { RAX } else { RDX }
            self.e(MOpMov, 8, OpndR(d), OpndR(res))
        }
        OpMulHiS, OpMulHiU => {
            d := self.vr(v)
            a := self.reg(i.args[0])
            b := self.reg(i.args[1])
            self.e(MOpMov, 8, OpndR(RAX), OpndR(a))
            self.e(if i.op == OpMulHiS { MOpImul1 } else { MOpMul1 }, isel_osz(ty), OpndR(b), OpndNone)
            self.e(MOpMov, 8, OpndR(d), OpndR(RDX))
        }
        OpFAdd => self.fbinop(v, MOpAddsd, true)
        OpFMul => self.fbinop(v, MOpMulsd, true)
        OpFSub => self.fbinop(v, MOpSubsd, false)
        OpFDiv => self.fbinop(v, MOpDivsd, false)
        OpFMin => self.fbinop(v, MOpMinsd, false)
        OpFMax => self.fbinop(v, MOpMaxsd, false)
        OpFSqrt => {
            d := self.vr(v)
            s := self.xm(i.args[0])
            self.e(MOpZero, 8, OpndR(d), OpndNone)
            self.e(MOpSqrtsd, isel_fsz(ty), OpndR(d), s)
        }
        OpFNeg, OpFAbs => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            neg := i.op == OpFNeg
            // the 128-bit mask as two halves
            var mask Bits128
            if ty == TF64 {
                if neg {
                    mask = Bits128{lo: 0x8000_0000_0000_0000, hi: 0}
                } else {
                    mask = Bits128{lo: 0x7FFF_FFFF_FFFF_FFFF, hi: 0}
                }
            } else {
                var lane u64 = if neg { 0x8000_0000 } else { 0x7FFF_FFFF }
                // lane | lane << 32 | lane << 64 | lane << 96
                mask = Bits128{lo: lane | lane << 32, hi: lane | lane << 32}
            }
            m := self.fconst(mask)
            self.e(MOpMovSd, 8, OpndR(d), OpndR(s))
            self.e(if neg { MOpXorpd } else { MOpAndpd }, if ty == TF64 { 8 } else { 16 }, OpndR(d), OpndM(m))
        }
        OpSExt => {
            d := self.vr(v)
            st := self.f.insts[i.args[0]].ty
            var s Opnd
            match self.load_mem(i.args[0]) {
                Some(m) => {
                    s = OpndM(m)
                }
                None => {
                    s = OpndR(self.reg(i.args[0]))
                }
            }
            mi := minst_new(MOpMovsx, isel_sz_of(st), OpndR(d), s)
            mi.sz2 = if ty == TI64 { 8 } else { 4 }
            self.out.push(mi)
        }
        OpZExt => {
            d := self.vr(v)
            src := i.args[0]
            st := self.f.insts[src].ty
            match self.load_mem(src) {
                Some(m) => {
                    if st == TI32 {
                        self.e(MOpMov, 4, OpndR(d), OpndM(m))
                    } else {
                        mi := minst_new(MOpMovzx, isel_sz_of(st), OpndR(d), OpndM(m))
                        mi.sz2 = 4
                        self.out.push(mi)
                    }
                    return
                }
                None => {}
            }
            s := self.reg(src)
            if st == TI32 {
                if self.zext_free(src) {
                    self.e(MOpMov, 8, OpndR(d), OpndR(s))
                } else {
                    self.e(MOpMov, 4, OpndR(d), OpndR(s))
                }
            } else if self.f.insts[src].op == OpLoad {
                // byte loads are already zero-extended
                self.e(MOpMov, 8, OpndR(d), OpndR(s))
            } else {
                mi := minst_new(MOpMovzx, isel_sz_of(st), OpndR(d), OpndR(s))
                mi.sz2 = 4
                self.out.push(mi)
            }
        }
        OpTrunc => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(MOpMov, 8, OpndR(d), OpndR(s))
        }
        OpSIToF => {
            d := self.vr(v)
            st := self.f.insts[i.args[0]].ty
            var s Opnd
            if st == TI32 || st == TI64 {
                match self.load_mem(i.args[0]) {
                    Some(m) => {
                        s = OpndM(m)
                    }
                    None => {
                        s = OpndR(self.reg(i.args[0]))
                    }
                }
            } else {
                s = OpndR(self.ext32(i.args[0], true))
            }
            self.e(MOpZero, 8, OpndR(d), OpndNone)
            mi := minst_new(MOpCvtsi2sd, if st == TI64 { 8 } else { 4 }, OpndR(d), s)
            mi.sz2 = isel_fsz(ty)
            self.out.push(mi)
        }
        OpFToSI => {
            d := self.vr(v)
            s := self.xm(i.args[0])
            mi := minst_new(MOpCvttsd2si, if ty == TI64 { 8 } else { 4 }, OpndR(d), s)
            mi.sz2 = isel_fsz(self.f.insts[i.args[0]].ty)
            self.out.push(mi)
        }
        OpBitsToF => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(MOpMovqToX, isel_fsz(ty), OpndR(d), OpndR(s))
        }
        OpFToBits => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(MOpMovqToR, isel_fsz(self.f.insts[i.args[0]].ty), OpndR(d), OpndR(s))
        }
        OpSelect => {
            d := self.vr(v)
            c := i.args[0]
            a := self.reg(i.args[1])
            b := self.mov_src(i.args[2])
            self.e(MOpMov, 8, OpndR(d), b)
            ci := &self.f.insts[c]
            var cc u8
            if ci.op.is_icmp() {
                cf := self.cmp_flags(c)
                cc = cf.0
            } else {
                r := self.reg(c)
                self.e(MOpTest, 1, OpndR(r), OpndR(r))
                cc = CC_NE
            }
            mi := minst_new(MOpCmov, if ty == TI64 { 8 } else { 4 }, OpndR(d), OpndR(a))
            mi.cc = cc
            self.out.push(mi)
        }
        OpLoad => {
            d := self.vr(v)
            m := self.addr(i.args[0])
            match ty {
                TF64, TF32, TV2, TV4 => self.e(MOpMovSd, isel_fsz_mem(ty), OpndR(d), OpndM(m))
                TV3 => {
                    // x, y as one 8-byte load; z joins as the upper half
                    t := new_vreg(&self.mf, 1)
                    hi := m
                    hi.disp += 8
                    self.e(MOpMovSd, 8, OpndR(d), OpndM(m))
                    self.e(MOpMovSd, 4, OpndR(t), OpndM(hi))
                    self.shufps(d, t, 0x44)
                }
                TI8, TI16 => {
                    mi := minst_new(MOpMovzx, isel_sz_of(ty), OpndR(d), OpndM(m))
                    mi.sz2 = 4
                    self.out.push(mi)
                }
                _ => self.e(MOpMov, isel_sz_of(ty), OpndR(d), OpndM(m))
            }
        }
        OpStore => {
            val := i.args[1]
            vi := &self.f.insts[val]
            if ty.is_fp() {
                if vi.op == OpFConst && (vi.k == 0 || ty == TF32) {
                    m := self.addr(i.args[0])
                    if ty == TV3 || ty == TV4 {
                        hi := m
                        hi.disp += 8
                        self.e(MOpMov, 8, OpndM(m), OpndI(0))
                        self.e(MOpMov, if ty == TV3 { 4 } else { 8 }, OpndM(hi), OpndI(0))
                    } else {
                        self.e(MOpMov, if ty == TF32 { 4 } else { 8 }, OpndM(m), OpndI(i64(i32(vi.k))))
                    }
                } else if ty == TV3 {
                    r := self.reg(val)
                    m := self.addr(i.args[0])
                    t := new_vreg(&self.mf, 1)
                    hi := m
                    hi.disp += 8
                    self.e(MOpMovSd, 8, OpndM(m), OpndR(r))
                    self.e(MOpMovSd, 8, OpndR(t), OpndR(r))
                    self.shufps(t, t, 2)
                    self.e(MOpMovSd, 4, OpndM(hi), OpndR(t))
                } else {
                    r := self.reg(val)
                    m := self.addr(i.args[0])
                    self.e(MOpMovSd, isel_fsz_mem(ty), OpndM(m), OpndR(r))
                }
            } else {
                var src Opnd
                if vi.op == OpConst && isel_fits32(vi.k) {
                    src = OpndI(vi.k)
                } else {
                    src = OpndR(self.reg(val))
                }
                m := self.addr(i.args[0])
                self.e(MOpMov, isel_sz_of(ty), OpndM(m), src)
            }
        }
        OpCall, OpCallInd => self.call(v, i)
        OpSyscall => {
            sr := [7]i64{RAX, RDI, RSI, RDX, R10, R8, R9}
            srcs := vec[Opnd]()
            for a in i.args.items() {
                srcs.push(self.mov_src(a))
            }
            used := vec[i64]()
            for k in 0..srcs.len {
                self.e(MOpMov, 8, OpndR(sr[k]), srcs[k])
                used.push(sr[k])
            }
            mi := minst_new(MOpSyscall, 0, OpndNone, OpndNone)
            mi.uses = used
            self.out.push(mi)
            if self.needed[v] {
                d := self.vr(v)
                self.e(MOpMov, 8, OpndR(d), OpndR(RAX))
            }
        }
        OpMemCpy, OpMemSet => {
            d := self.mov_src(i.args[0])
            s := self.mov_src(i.args[1])
            n := self.mov_src(i.args[2])
            self.e(MOpMov, 8, OpndR(RDI), d)
            self.e(MOpMov, 8, OpndR(if i.op == OpMemCpy { RSI } else { RAX }), s)
            self.e(MOpMov, 8, OpndR(RCX), n)
            self.e(if i.op == OpMemCpy { MOpRepMovsb } else { MOpRepStosb }, 0, OpndNone, OpndNone)
        }
        OpFExt, OpFTrunc => {
            d := self.vr(v)
            s := self.xm(i.args[0])
            self.e(MOpZero, 8, OpndR(d), OpndNone)
            self.e(MOpCvtf, isel_fsz(ty), OpndR(d), s)
        }
        OpVSplat => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(MOpMovSd, 8, OpndR(d), OpndR(s))
            self.shufps(d, d, 0)
        }
        OpVBuild => {
            d := self.vr(v)
            consts := vec[Opt[u32]]()
            all_const := true
            for a in i.args.items() {
                if self.f.insts[a].op == OpFConst {
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
                    self.e(MOpZero, 8, OpndR(d), OpndNone)
                } else {
                    m := self.fconst(bits)
                    self.e(MOpMovSd, 16, OpndR(d), OpndM(m))
                }
                return
            }
            rs := vec[i64]()
            for a in i.args.items() {
                rs.push(self.reg(a))
            }
            self.e(MOpMovSd, 8, OpndR(d), OpndR(rs[0]))
            self.e(MOpUnpcklps, 16, OpndR(d), OpndR(rs[1]))
            if rs.len == 3 {
                self.shufps(d, rs[2], 0x44)
            } else if rs.len == 4 {
                t := new_vreg(&self.mf, 1)
                self.e(MOpMovSd, 8, OpndR(t), OpndR(rs[2]))
                self.e(MOpUnpcklps, 16, OpndR(t), OpndR(rs[3]))
                self.shufps(d, t, 0x44)
            }
        }
        OpVExt => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(MOpMovSd, 8, OpndR(d), OpndR(s))
            if i.k != 0 {
                self.shufps(d, d, i.k)
            }
        }
        OpVIns => {
            d := self.vr(v)
            x := self.reg(i.args[0])
            s := self.reg(i.args[1])
            k := i.k
            if k == 0 {
                self.e(MOpMovSd, 8, OpndR(d), OpndR(x))
                self.e(MOpMovlo, 4, OpndR(d), OpndR(s))
            } else if k == 1 {
                // [x0, s, x1, s1] then lanes 2, 3 from x
                self.e(MOpMovSd, 8, OpndR(d), OpndR(x))
                self.e(MOpUnpcklps, 16, OpndR(d), OpndR(s))
                self.shufps(d, x, 0xE4)
            } else {
                // t = [s, s, x3, x3] (lane 2) or [s, s, x2, x2] (lane 3)
                t := new_vreg(&self.mf, 1)
                self.e(MOpMovSd, 8, OpndR(t), OpndR(s))
                self.shufps(t, x, if k == 2 { 0xF0 } else { 0xA0 })
                self.e(MOpMovSd, 8, OpndR(d), OpndR(x))
                self.shufps(d, t, if k == 2 { 0x84 } else { 0x24 })
            }
        }
        OpVShuf => {
            d := self.vr(v)
            a := self.reg(i.args[0])
            self.e(MOpMovSd, 8, OpndR(d), OpndR(a))
            if i.args[0] == i.args[1] {
                self.shufps(d, d, i.k)
            } else {
                b := self.reg(i.args[1])
                self.shufps(d, b, i.k)
            }
        }
        OpBswap, OpPopcnt, OpCtz, OpClz => {
            d := self.vr(v)
            sz := isel_osz(ty)
            if i.op == OpBswap {
                s := self.reg(i.args[0])
                self.e(MOpMov, 8, OpndR(d), OpndR(s))
                self.e(MOpBswap, sz, OpndR(d), OpndNone)
                if ty == TI16 {
                    self.e(MOpShr, 4, OpndR(d), OpndI(16))
                } else if ty == TI8 {
                    self.e(MOpShr, 4, OpndR(d), OpndI(24))
                }
            } else {
                s := self.ext32(i.args[0], false)
                mop := match i.op {
                    OpPopcnt => MOpPopcnt
                    OpCtz => MOpTzcnt
                    _ => MOpLzcnt
                }
                self.e(mop, sz, OpndR(d), OpndR(s))
                if i.op == OpClz && (ty == TI8 || ty == TI16) {
                    self.e(MOpSub, 4, OpndR(d), OpndI(32 - ty.bits()))
                }
                if i.op == OpCtz && (ty == TI8 || ty == TI16) {
                    // tzcnt of a zero-extended zero gives 32: clamp to the type width
                    t := new_vreg(&self.mf, 0)
                    self.e(MOpMov, 8, OpndR(t), OpndI(ty.bits()))
                    self.e(MOpCmp, 4, OpndR(d), OpndR(t))
                    mi := minst_new(MOpCmov, 4, OpndR(d), OpndR(t))
                    mi.cc = CC_A
                    self.out.push(mi)
                }
            }
        }
        _ => {
            // (in the Rust this arm sits between FNeg/FAbs and SExt; no other arm is a compare)
            if i.op.is_cmp() {
                d := self.vr(v)
                cf := self.cmp_flags(v)
                cc := cf.0
                extra := cf.1
                s := minst_new(MOpSetcc, 1, OpndR(d), OpndNone)
                s.cc = cc
                self.out.push(s)
                if extra != 0 {
                    t := new_vreg(&self.mf, 0)
                    s2 := minst_new(MOpSetcc, 1, OpndR(t), OpndNone)
                    s2.cc = if extra == 1 { CC_NP } else { CC_P }
                    self.out.push(s2)
                    self.e(if extra == 1 { MOpAnd } else { MOpOr }, 4, OpndR(d), OpndR(t))
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
fn dies_here(self *IselSel, v i64) bool {
    return self.uses[v] == 1 && self.blk_of[v] == self.cur_block && self.f.insts[v].op != OpPhi
}

fn uses_of_reg_single(self *IselSel, i *Inst, base i64) bool {
    // x + const where x dies here: two-address add coalesces
    for a in i.args.items() {
        if self.vreg[a] == base {
            return self.dies_here(a)
        }
    }
    return false
}

fn call(self *IselSel, v i64, i *Inst) {
    self.mf.has_calls = true
    var target Opt[i64] = None
    args := i.args.items()
    if i.op == OpCallInd {
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
            r := OpndR(self.reg(a))
            if nf < NUM_FLOAT_ARGS {
                reg_moves.push((XMM0 + nf, r, true))
                nf += 1
            } else {
                stack_moves.push((nstack, r, isel_fsz(at)))
                nstack += if at.is_vec() { 2 } else { 1 }
            }
        } else if ni < len(INT_ARGS) {
            s := self.mov_src(a)
            reg_moves.push((INT_ARGS[ni], s, false))
            ni += 1
        } else {
            ms := self.mov_src(a)
            var s Opnd
            match ms {
                OpndI(k) => {
                    if isel_fits32(k) {
                        s = OpndI(k)
                    } else {
                        s = OpndR(self.reg(a))
                    }
                }
                OpndR(r) => {
                    s = OpndR(r)
                }
                _ => {
                    s = OpndR(self.reg(a))
                }
            }
            stack_moves.push((nstack, s, 0))
            nstack += 1
        }
    }
    var tr Opt[i64] = None
    match target {
        Some(t) => {
            tr = Some(self.reg(t))
        }
        None => {}
    }
    self.mf.out_args = max(self.mf.out_args, nstack)
    for sm in stack_moves.items() {
        m := Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKindOutArg, id: sm.0}
        if sm.2 != 0 {
            self.e(MOpMovSd, sm.2, OpndM(m), sm.1)
        } else {
            self.e(MOpMov, 8, OpndM(m), sm.1)
        }
    }
    used := vec[i64]()
    for rm in reg_moves.items() {
        self.e(if rm.2 { MOpMovSd } else { MOpMov }, 8, OpndR(rm.0), rm.1)
        used.push(rm.0)
    }
    var c MInst
    match tr {
        Some(r) => {
            c = minst_new(MOpCallInd, 8, OpndR(r), OpndNone)
        }
        None => {
            c = minst_new(MOpCall, 0, OpndNone, OpndNone)
            c.tgt = i.k
        }
    }
    if i.op == OpCallInd && i.aux == 1 {
        // C calling convention: al = number of vector registers used (for variadic callees)
        self.e(MOpMov, 4, OpndR(RAX), OpndI(nf))
        used.push(RAX)
    }
    c.uses = used
    self.out.push(c)
    // results
    // (the Rust also computes an unused `nrets` here)
    if i.ty != TVoid {
        if self.needed[v] {
            d := self.vr(v)
            if i.ty.is_fp() {
                self.e(MOpMovSd, 8, OpndR(d), OpndR(XMM0))
            } else {
                self.e(MOpMov, 8, OpndR(d), OpndR(RAX))
            }
        }
    } else {
        ps, has := self.projs.get(v)
        if has {
            // multi-value results: assign registers in order of result index
            by_idx := clone(&ps)
            sort_by(by_idx.items(), isel_proj_less)
            maxi := -1
            for p in by_idx.items() {
                if p.0 > maxi {
                    maxi = p.0
                }
            }
            // result types: from callee signature when known, else from projections
            types := vec[T]()
            if i.op == OpCall {
                types = clone(&self.m.funcs[i.k].rets)
            } else {
                for k in 0..=maxi {
                    t := TI64
                    for p in by_idx.items() {
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
            for t in types.items() {
                if t.is_fp() {
                    locs.push(XMM0 + nf2)
                    nf2 += 1
                } else {
                    locs.push(INT_RETS[ni2])
                    ni2 += 1
                }
            }
            for kp in by_idx.items() {
                k := kp.0
                p := kp.1
                if !self.needed[p] {
                    continue
                }
                d := self.vr(p)
                isf := self.f.insts[p].ty.is_fp()
                self.e(if isf { MOpMovSd } else { MOpMov }, 8, OpndR(d), OpndR(locs[k]))
            }
        }
    }
}
