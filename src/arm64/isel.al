// Instruction selection for arm64: SSA IR -> arm64 machine IR (src/arm64/mir.al) with virtual
// registers. The shape follows src/x86/isel.al (each block selected backwards, values computed
// where they are needed, addresses folded into the memory operands of loads and stores), with
// fewer special cases: every IR operation has one plain selection here.
//
// Narrow integers (I8, I16) live in registers with undefined upper bits, as on x86-64: the
// operations whose result depends on them (compares, right shifts, division, extensions)
// extend their operands first; I32 operations use the W registers, which zero the upper half.

// Splits every edge from a block with two successors to one with several predecessors or with
// phis, so that the phi copies of an edge always have a block of their own that ends in a
// jump; a branch with two equal targets becomes a jump.
fn a_split_critical_edges(f: *Func) {
    preds := f.preds()
    nb := f.blocks.len
    has_phi := vec_fill(nb, false)
    for b in 0..nb {
        ins := &f.blocks[b].insts
        has_phi[b] = ins.len > 0 && f.insts[ins[0]].op == Phi
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
                    if preds[s].len > 1 || has_phi[s] {
                        nbk := f.new_block()
                        f.blocks[nbk].term = Jmp(s)
                        f.phi_pred_replace(s, b, nbk)
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
}

// the offset of every thread-local global in the thread block (layout_tls), set before any
// function is selected (the back end's threads only read it); an access is TPIDR_EL0 + 16 +
// offset (TLS variant I: the 16-byte thread control block, then the block)
priv tls_off: Vec[i64]

fn a_isel_init(m: *Module) {
    tls_off = vec_fill(m.globals.len, 0)
    layout_tls(m, &tls_off, false)
}

// a memory operand: [base + imm], [base + (idx << sh)], a frame slot + imm, an argument word
priv struct AM {
    k: u8
    base: i64
    idx: i64
    sh: i64
    imm: i64
    id: i64
}

priv fn am_reg(r: i64, imm: i64) -> AM {
    return AM{k: AK_NORMAL, base: r, idx: NOREG, sh: 0, imm: imm, id: 0}
}

priv struct Sel {
    f: *Func
    m: *Module
    mf: AFunc
    vreg: Vec[i32]
    uses: Vec[i32]
    needed: Vec[bool]
    blk_of: Vec[i32]
    slot_of: Vec[i32]
    projs: Map[i64, Vec[(i64, i64)]]
    out: Vec[AInst]
    fconst_ix: Map[Bits128, i64]
    param_of: Vec[i64]
    cur_block: i64
}

priv fn sz_of(t: T) -> u8 {
    match t {
        I8 => 1
        I16 => 2
        I32 => 4
        _ => 8
    }
}

// the register size of integer arithmetic: W registers for everything narrower than 64 bits
priv fn osz(t: T) -> u8 {
    return if t == I64 { 8 } else { 4 }
}

// the size of a floating-point operation: single, double, four lanes
priv fn fsz(t: T) -> u8 {
    match t {
        F32 => 4
        F64 => 8
        _ => 16
    }
}

fn a_isel_select(f: *Func, m: *Module, rpo: []i64, depths: []i64) -> AFunc {
    n := f.insts.len
    s := Sel{
        f: f,
        m: m,
        mf: AFunc{name: f.name},
        vreg: vec_fill(n, i32(NOREG)),
        uses: f.use_counts(),
        needed: vec_fill(n, false),
        blk_of: f.block_of(),
        param_of: vec_fill(f.params.len, -1),
    }
    nb := f.blocks.len
    s.mf.blocks.reserve(nb)
    for b in 0..nb {
        s.mf.blocks.push(ABlock{insts: vec[AInst](), succs: f.succs(b), depth: if b < len(depths) { depths[b] } else { 0 }})
    }
    for bi in 0..nb {
        for v in f.blocks[bi].insts {
            i := &f.insts[v]
            match i.op {
                Proj => {
                    pl, _ := s.projs.get(i.args[0])
                    pl.push((i.k, i64(v)))
                    s.projs.set(i.args[0], pl)
                }
                Param => {
                    if i.k >= 0 && i.k < s.param_of.len {
                        s.param_of[i.k] = i64(v)
                    }
                }
                _ => {}
            }
        }
    }
    s.slot_of = vec_fill(n, i32(-1))
    for v in f.blocks[0].insts {
        if f.insts[v].op == Alloca {
            s.slot_of[v] = i32(s.mf.a_new_slot(f.insts[v].k, max(i64(f.insts[v].aux), 1)))
        }
    }
    // each block backwards: the terminator, then the instructions from the last one, then
    // (entry block) the parameters; every piece is a chunk of s.out, the block is the chunks
    // in reverse order
    starts := vec[i64]()
    for ri in rpo.len - 1..=0 by -1 {
        b := rpo[ri]
        s.cur_block = b
        s.out.clear()
        starts.clear()
        starts.push(0)
        s.term(b)
        tloc: i32 = 0
        for vi in f.blocks[b].insts.len - 1..=0 by -1 {
            tloc = f.insts[f.blocks[b].insts[vi]].srcloc()
            if tloc != 0 {
                break
            }
        }
        s.stamp(0, tloc)
        for vi in f.blocks[b].insts.len - 1..=0 by -1 {
            v := i64(f.blocks[b].insts[vi])
            op := f.insts[v].op
            if op == Const && s.needed[v] {
                // a wide constant kept in a register (so that loops do not rebuild it)
                starts.push(s.out.len)
                s.movi(s.vr(v), f.insts[v].k)
                continue
            }
            if op == Phi || op == Param || op == Alloca || op == Const || op == FConst || op == GAddr || op == FAddr || op == Proj {
                continue
            }
            if cleanup_is_root(op) || s.needed[v] {
                starts.push(s.out.len)
                s.inst(v)
                s.stamp(starts.last(), f.insts[v].srcloc())
            }
        }
        if b == 0 {
            starts.push(s.out.len)
            s.params()
        }
        insts := vec[AInst]()
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

priv fn stamp(self: *Sel, from: i64, loc: i32) {
    for k in from..self.out.len {
        self.out[k].loc = loc
    }
}

// ---------- emitting ----------
priv fn e(self: *Sel, op: AOp, sz: u8, d: i64, n: i64, m: i64) {
    self.out.push(ainst(op, sz, d, n, m))
}

priv fn ei(self: *Sel, op: AOp, sz: u8, d: i64, n: i64, imm: i64) {
    i := ainst(op, sz, d, n, NOREG)
    i.imm = imm
    self.out.push(i)
}

priv fn movi(self: *Sel, d: i64, k: i64) {
    self.ei(MovI, 8, d, NOREG, k)
}

priv fn mov(self: *Sel, d: i64, n: i64) {
    self.e(Mov, 8, d, n, NOREG)
}

priv fn fmov(self: *Sel, d: i64, n: i64) {
    self.e(FMov, 16, d, n, NOREG)
}

priv fn gp(self: *Sel) -> i64 {
    return self.mf.a_new_vreg(0)
}

priv fn fp(self: *Sel) -> i64 {
    return self.mf.a_new_vreg(1)
}

// a load (op Ldr, Ldrs, FLdr: the register d) or store (Str, FStr: the register a) of sz
// bytes at the memory operand am
priv fn mem(self: *Sel, op: AOp, sz: u8, reg: i64, am: AM) {
    i := ainst(op, sz, NOREG, am.base, am.idx)
    if op == Str || op == FStr {
        i.a = i32(reg)
    } else {
        i.d = i32(reg)
    }
    i.k = am.k
    i.sh = u8(am.sh)
    i.imm = am.imm
    i.id = i32(am.id)
    self.out.push(i)
}

priv fn class_of(self: *Sel, v: i64) -> u8 {
    return if self.f.insts[v].ty.is_fp() { 1 } else { 0 }
}

// the vreg holding IR value v (made on demand)
priv fn vr(self: *Sel, v: i64) -> i64 {
    if self.vreg[v] == NOREG {
        self.vreg[v] = i32(self.mf.a_new_vreg(self.class_of(v)))
    }
    return i64(self.vreg[v])
}

priv fn fconst(self: *Sel, bits: Bits128) -> i64 {
    ix, has := self.fconst_ix.get(bits)
    if !has {
        assert self.mf.fconsts.len < 0x7FFFFFFF, "isel: too many float constants in a function"
        self.mf.fconsts.push(bits)
        ix = self.mf.fconsts.len - 1
        self.fconst_ix.set(bits, ix)
    }
    return ix
}

priv fn fconst_load(self: *Sel, d: i64, bits: Bits128, sz: u8) {
    i := ainst(FConst, sz, d, NOREG, NOREG)
    i.id = i32(self.fconst(bits))
    self.out.push(i)
}

// a constant that one instruction makes (MOVZ, MOVN): cheaper to repeat than to keep
priv fn cheap(k: i64) -> bool {
    return (k >= 0 && k < 0x10000) || (k < 0 && k >= -0x10000)
}

// a register holding v at the current point (materializes constants and addresses)
priv fn reg(self: *Sel, v: i64) -> i64 {
    i := &self.f.insts[v]
    match i.op {
        Const if cheap(i.k) || i64(self.blk_of[v]) == self.cur_block => {
            r := self.gp()
            self.movi(r, i.k)
            return r
        }
        FConst => {
            r := self.fp()
            if i.k == 0 {
                self.e(FZero, 16, r, NOREG, NOREG)
            } else {
                self.fconst_load(r, Bits128{lo: u64(i.k), hi: 0}, if i.ty == F32 { 4 } else { 8 })
            }
            return r
        }
        GAddr => {
            r := self.gp()
            if self.m.globals[i.k].tls {
                self.e(Mrs, 8, r, NOREG, NOREG)
                self.ei(AddI, 8, r, r, 16 + tls_off[i.k])
            } else {
                ai := ainst(AdrG, 8, r, NOREG, NOREG)
                ai.id = i32(i.k)
                self.out.push(ai)
            }
            return r
        }
        FAddr => {
            r := self.gp()
            ai := ainst(AdrF, 8, r, NOREG, NOREG)
            ai.id = i32(i.k)
            self.out.push(ai)
            return r
        }
        Alloca => {
            r := self.gp()
            self.mem(AdrS, 8, r, AM{k: AK_SLOT, base: NOREG, idx: NOREG, sh: 0, imm: 0, id: i64(self.slot_of[v])})
            return r
        }
        _ => {}
    }
    self.needed[v] = true
    return self.vr(v)
}

// v extended to 32 bits (for the operations that read every bit: compares, division, right
// shifts of narrow types)
priv fn ext32(self: *Sel, v: i64, signed: bool) -> i64 {
    t := self.f.insts[v].ty
    r := self.reg(v)
    if t == I8 || t == I16 {
        d := self.gp()
        op := if t == I8 { if signed { Sxtb } else { Uxtb } } else { if signed { Sxth } else { Uxth } }
        self.e(op, 4, d, r, NOREG)
        return d
    }
    return r
}

// ---------- addressing ----------
priv fn addr_into(self: *Sel, v: i64, am: *AM, depth: i64) {
    i := &self.f.insts[v]
    if i.op == Alloca && am.k == AK_NORMAL && am.base == NOREG && am.idx == NOREG {
        am.k = AK_SLOT
        am.id = i64(self.slot_of[v])
        return
    }
    if i.op == Add && i.ty == I64 && depth < 8 {
        a := i.args[0]
        b := i.args[1]
        if is_some(self.f.is_const(a)) {
            swap(&a, &b)
        }
        match self.f.is_const(b) {
            Some(c) if c > -(1 << 31) && c < (1 << 31) => {
                am.imm += c
                self.addr_into(a, am, depth + 1)
                return
            }
            _ => {}
        }
        // base + (index << size)
        bi := &self.f.insts[b]
        if am.k == AK_NORMAL && am.base == NOREG && am.idx == NOREG && am.imm == 0 && bi.op == Shl && bi.ty == I64 {
            match self.f.is_const(bi.args[1]) {
                Some(k) if k >= 0 && k <= 4 => {
                    am.base = self.reg(a)
                    am.idx = self.reg(bi.args[0])
                    am.sh = k
                    return
                }
                _ => {}
            }
        }
    }
    r := self.reg(v)
    if am.k == AK_NORMAL && am.base == NOREG {
        am.base = r
        return
    }
    // a slot plus a register: the slot's address first
    t := self.gp()
    self.mem(AdrS, 8, t, *am)
    self.e(AddR, 8, t, t, r)
    *am = am_reg(t, 0)
}

priv fn addr(self: *Sel, v: i64) -> AM {
    am := AM{k: AK_NORMAL, base: NOREG, idx: NOREG, sh: 0, imm: 0, id: 0}
    self.addr_into(v, &am, 0)
    return am
}

// ---------- parameters ----------
priv fn params(self: *Sel) {
    ni := 0
    nf := 0
    nstack := 0
    for pi, t in self.f.params {
        pv := self.param_of[pi]
        want := pv >= 0 && self.needed[pv]
        if t.is_fp() {
            if nf < A_NARG {
                if want {
                    self.fmov(self.vr(pv), A_V0 + nf)
                }
                nf += 1
            } else {
                if want {
                    self.mem(FLdr, if t.is_vec() { 16 } else { fsz(t) }, self.vr(pv), AM{k: AK_INARG, base: NOREG, idx: NOREG, sh: 0, imm: 0, id: nstack})
                }
                nstack += if t.is_vec() { 2 } else { 1 }
            }
        } else if ni < A_NARG {
            if want {
                self.mov(self.vr(pv), ni)
            }
            ni += 1
        } else {
            if want {
                self.mem(Ldr, 8, self.vr(pv), AM{k: AK_INARG, base: NOREG, idx: NOREG, sh: 0, imm: 0, id: nstack})
            }
            nstack += 1
        }
    }
}

// ---------- terminators ----------
priv fn phi_copies(self: *Sel, b: i64, s: i64) {
    // parallel copies: (destination, source register or NOREG, the IR value of the source)
    moves := vec[(i64, i64, i64)]()
    for v in self.f.blocks[s].insts {
        if self.f.insts[v].op != Phi {
            break
        }
        p := i64(v)
        self.needed[p] = true
        inst := &self.f.insts[p]
        ai := index_of(inst.from(), b)
        if ai < 0 {
            continue
        }
        src := inst.args[ai]
        d := self.vr(p)
        op := self.f.insts[src].op
        if op == Const || op == FConst || op == GAddr || op == FAddr || op == Alloca {
            moves.push((d, NOREG, src))
            continue
        }
        r := self.reg(src)
        if r != d {
            moves.push((d, r, src))
        }
    }
    // register sources first, in an order that reads every source before it is overwritten
    pending := vec[(i64, i64, i64)]()
    for mv in moves {
        if mv.1 != NOREG {
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
                if j != i && pending[j].1 == d {
                    blocked = true
                    break
                }
            }
            if !blocked {
                mv := pending.remove(i)
                if self.mf.a_class(mv.0) == 1 {
                    self.fmov(mv.0, mv.1)
                } else {
                    self.mov(mv.0, mv.1)
                }
                progressed = true
            } else {
                i += 1
            }
        }
        if !progressed {
            // a cycle: one destination is saved in a temporary
            d := pending[0].0
            cls := self.mf.a_class(d)
            t := self.mf.a_new_vreg(cls)
            if cls == 1 {
                self.fmov(t, d)
            } else {
                self.mov(t, d)
            }
            for j in 0..pending.len {
                if pending[j].1 == d {
                    pending[j].1 = t
                }
            }
        }
    }
    // constants and addresses last (they read no register a copy writes)
    for mv in moves {
        if mv.1 == NOREG {
            r := self.reg(mv.2)
            if self.mf.a_class(mv.0) == 1 {
                self.fmov(mv.0, r)
            } else {
                self.mov(mv.0, r)
            }
        }
    }
}

priv fn branch(self: *Sel, op: AOp, cc: i64, t: i64) {
    i := ainst(op, 0, NOREG, NOREG, NOREG)
    i.cc = u8(cc)
    i.id = i32(t)
    self.out.push(i)
}

// the condition code under which the IR compare c holds, after the flag-setting instruction
// this emits
priv fn cmp_flags(self: *Sel, c: i64) -> i64 {
    i := &self.f.insts[c]
    a := i.args[0]
    b := i.args[1]
    at := self.f.insts[a].ty
    if i.op.is_icmp() {
        op := i.op
        if is_some(self.f.is_const(a)) && !is_some(self.f.is_const(b)) {
            swap(&a, &b)
            op = op.swap_cmp()
        }
        cc := match op {
            Eq => A64_EQ
            Ne => A64_NE
            Slt => A64_LT
            Sle => A64_LE
            Sgt => A64_GT
            Sge => A64_GE
            Ult => A64_LO
            Ule => A64_LS
            Ugt => A64_HI
            _ => A64_HS
        }
        signed := op == Slt || op == Sle || op == Sgt || op == Sge
        sz := osz(at)
        x := self.ext32(a, signed)
        match self.f.is_const(b) {
            Some(k) => {
                // (a narrow constant is canonical: sign-extended, as the extended operand)
                k2 := if (at == I8 || at == I16) && !signed { k & ((1 << at.bits()) - 1) } else { k }
                self.ei(CmpI, sz, NOREG, x, k2)
                return cc
            }
            _ => {}
        }
        y := self.ext32(b, signed)
        self.e(CmpR, sz, NOREG, x, y)
        return cc
    }
    // floating point: unordered makes every condition but NE false
    x := self.reg(a)
    y := self.reg(b)
    self.e(Fcmp, fsz(at), NOREG, x, y)
    return match i.op {
        FEq => A64_EQ
        FNe => A64_NE
        FLt => A64_MI
        FLe => A64_LS
        FGt => A64_GT
        _ => A64_GE
    }
}

// flags for a condition value c (a compare, or a bool in a register): the condition code
priv fn cond(self: *Sel, c: i64) -> i64 {
    if self.f.insts[c].op.is_cmp() {
        return self.cmp_flags(c)
    }
    r := self.reg(c)
    self.ei(TstI, 4, NOREG, r, 0xFF)
    return A64_NE
}

priv fn term(self: *Sel, b: i64) {
    tm := self.f.blocks[b].term
    match tm {
        Jmp(t) => {
            self.phi_copies(b, t)
            self.branch(B, 0, t)
        }
        Br(c, t, e) => {
            // (a_split_critical_edges: the successors of a branch have no phis)
            cc := self.cond(c)
            self.branch(Bcc, cc, t)
            self.branch(B, 0, e)
        }
        Ret(vals) => {
            ni := 0
            nf := 0
            srcs := vec[(i64, i64)]()
            for v in vals {
                if self.f.insts[v].ty.is_fp() {
                    srcs.push((A_V0 + nf, self.reg(v)))
                    nf += 1
                } else {
                    srcs.push((ni, self.reg(v)))
                    ni += 1
                }
            }
            used := vec[i64]()
            for sv in srcs {
                if sv.0 >= A_V0 {
                    self.fmov(sv.0, sv.1)
                } else {
                    self.mov(sv.0, sv.1)
                }
                used.push(sv.0)
            }
            self.out.push(self.mf.a_with_uses(Ret, used.items()))
        }
        Trap, Term.None => self.e(Brk, 0, NOREG, NOREG, NOREG)
    }
}

// ---------- instructions ----------
priv fn binop(self: *Sel, v: i64, op: AOp, iop: AOp) {
    i := &self.f.insts[v]
    a := i.args[0]
    b := i.args[1]
    if is_some(self.f.is_const(a)) && op != SubR {
        swap(&a, &b)
    }
    d := self.vr(v)
    sz := osz(i.ty)
    match self.f.is_const(b) {
        Some(k) => {
            self.ei(iop, sz, d, self.reg(a), k)
            return
        }
        _ => {}
    }
    x := self.reg(a)
    y := self.reg(b)
    self.e(op, sz, d, x, y)
}

priv fn fbinop(self: *Sel, v: i64, op: AOp) {
    i := &self.f.insts[v]
    x := self.reg(i.args[0])
    y := self.reg(i.args[1])
    self.e(op, fsz(i.ty), self.vr(v), x, y)
}

priv fn shift(self: *Sel, v: i64) {
    i := &self.f.insts[v]
    ty := i.ty
    bits := ty.bits()
    d := self.vr(v)
    narrow := ty == I8 || ty == I16
    sz := osz(ty)
    // the value as the shift must see it: right shifts of narrow types extended, rotations of
    // them zero-extended
    signed := i.op == AShr
    x := if narrow && i.op != Shl { self.ext32(i.args[0], signed) } else { self.reg(i.args[0]) }
    match self.f.is_const(i.args[1]) {
        Some(k0) => {
            k := k0 & (bits - 1)
            if k == 0 {
                self.mov(d, x)
                return
            }
            match i.op {
                Shl => self.ei(LslI, sz, d, x, k)
                LShr => self.ei(LsrI, sz, d, x, k)
                AShr => self.ei(AsrI, sz, d, x, k)
                _ => {
                    // rotation right by r
                    r := if i.op == Rotr { k } else { bits - k }
                    if narrow {
                        t := self.gp()
                        self.ei(LsrI, 4, t, x, r)
                        u := self.gp()
                        self.ei(LslI, 4, u, x, bits - r)
                        self.e(OrrR, 4, d, t, u)
                    } else {
                        self.ei(RorI, sz, d, x, r)
                    }
                }
            }
        }
        None => {
            c := self.reg(i.args[1])
            if narrow {
                c2 := self.gp()
                self.ei(AndI, 4, c2, c, bits - 1)
                c = c2
            }
            match i.op {
                Shl => self.e(Lslv, sz, d, x, c)
                LShr => self.e(Lsrv, sz, d, x, c)
                AShr => self.e(Asrv, sz, d, x, c)
                _ => {
                    if narrow {
                        // (x >> r) | (x << (bits - r)), r the count of the rotation right
                        r := c
                        if i.op == Rotl {
                            r = self.gp()
                            nb := self.gp()
                            self.movi(nb, bits)
                            self.e(SubR, 4, r, nb, c)
                            self.ei(AndI, 4, r, r, bits - 1)
                        }
                        l := self.gp()
                        nb2 := self.gp()
                        self.movi(nb2, bits)
                        self.e(SubR, 4, l, nb2, r)
                        t := self.gp()
                        self.e(Lsrv, 4, t, x, r)
                        u := self.gp()
                        self.e(Lslv, 4, u, x, l)
                        self.e(OrrR, 4, d, t, u)
                    } else if i.op == Rotr {
                        self.e(Rorv, sz, d, x, c)
                    } else {
                        // a rotation left by c is one right by -c (the count is taken modulo the size)
                        nc := self.gp()
                        self.e(Neg, sz, nc, c, NOREG)
                        self.e(Rorv, sz, d, x, nc)
                    }
                }
            }
        }
    }
}

priv fn inst(self: *Sel, v: i64) {
    i := &self.f.insts[v]
    ty := i.ty
    match i.op {
        Add => self.binop(v, AddR, AddI)
        Sub => {
            if self.f.is_const(i.args[0]) == Some(0) {
                self.e(Neg, osz(ty), self.vr(v), self.reg(i.args[1]), NOREG)
            } else {
                self.binop(v, SubR, SubI)
            }
        }
        Mul => {
            a := i.args[0]
            b := i.args[1]
            if is_some(self.f.is_const(a)) {
                swap(&a, &b)
            }
            d := self.vr(v)
            match self.f.is_const(b) {
                Some(k) if k > 0 && k & (k - 1) == 0 => {
                    self.ei(LslI, osz(ty), d, self.reg(a), i64(ctz(u64(k))))
                }
                _ => self.e(Mul, osz(ty), d, self.reg(a), self.reg(b))
            }
        }
        And => {
            if self.f.is_const(i.args[1]) == Some(0xFF) && ty != I8 {
                self.e(Uxtb, 4, self.vr(v), self.reg(i.args[0]), NOREG)
            } else if self.f.is_const(i.args[1]) == Some(0xFFFF) && ty != I8 && ty != I16 {
                self.e(Uxth, 4, self.vr(v), self.reg(i.args[0]), NOREG)
            } else if self.f.is_const(i.args[1]) == Some(0xFFFF_FFFF) && ty == I64 {
                self.e(Mov, 4, self.vr(v), self.reg(i.args[0]), NOREG)
            } else {
                self.binop(v, AndR, AndI)
            }
        }
        Or => self.binop(v, OrrR, OrrI)
        Xor => {
            if self.f.is_const(i.args[1]) == Some(-1) {
                self.e(Mvn, osz(ty), self.vr(v), self.reg(i.args[0]), NOREG)
            } else {
                self.binop(v, EorR, EorI)
            }
        }
        Shl, LShr, AShr, Rotl, Rotr => self.shift(v)
        SDiv, UDiv, SRem, URem => {
            signed := i.op == SDiv || i.op == SRem
            sz := osz(ty)
            x := self.ext32(i.args[0], signed)
            y := self.ext32(i.args[1], signed)
            match self.f.is_const(i.args[1]) {
                Some(k) if k != 0 => {}
                _ => {
                    // x86-64 faults on a division by zero, checked or not (SIGFPE): so does this
                    self.e(DivTrap, sz, NOREG, y, NOREG)
                }
            }
            d := self.vr(v)
            op := if signed { Sdiv } else { Udiv }
            if i.op == SDiv || i.op == UDiv {
                self.e(op, sz, d, x, y)
            } else {
                q := self.gp()
                self.e(op, sz, q, x, y)
                // d = x - q * y
                mi := ainst(Msub, sz, d, q, y)
                mi.a = i32(x)
                self.out.push(mi)
            }
        }
        MulHiS, MulHiU => {
            signed := i.op == MulHiS
            d := self.vr(v)
            if ty == I64 {
                self.e(if signed { Smulh } else { Umulh }, 8, d, self.reg(i.args[0]), self.reg(i.args[1]))
            } else {
                x := self.ext32(i.args[0], signed)
                y := self.ext32(i.args[1], signed)
                t := self.gp()
                self.e(if signed { Smull } else { Umull }, 8, t, x, y)
                self.ei(if signed { AsrI } else { LsrI }, 8, d, t, 32)
            }
        }
        FAdd => self.fbinop(v, Fadd)
        FSub => self.fbinop(v, Fsub)
        FMul => self.fbinop(v, Fmul)
        FDiv => self.fbinop(v, Fdiv)
        FMin, FMax => {
            // a < b ? a : b and a > b ? a : b, as on x86-64 (unordered: b)
            x := self.reg(i.args[0])
            y := self.reg(i.args[1])
            d := self.vr(v)
            if ty.is_vec() {
                self.e(if i.op == FMin { VMin } else { VMax }, 16, d, x, y)
            } else {
                self.e(Fcmp, fsz(ty), NOREG, x, y)
                fi := ainst(Fcsel, fsz(ty), d, x, y)
                fi.cc = u8(if i.op == FMin { A64_MI } else { A64_GT })
                self.out.push(fi)
            }
        }
        FSqrt => self.e(Fsqrt, fsz(ty), self.vr(v), self.reg(i.args[0]), NOREG)
        FNeg => self.e(Fneg, fsz(ty), self.vr(v), self.reg(i.args[0]), NOREG)
        FAbs => self.e(Fabs, fsz(ty), self.vr(v), self.reg(i.args[0]), NOREG)
        FExt => self.e(Fcvt, 8, self.vr(v), self.reg(i.args[0]), NOREG)
        FTrunc => self.e(Fcvt, 4, self.vr(v), self.reg(i.args[0]), NOREG)
        SExt => {
            st := self.f.insts[i.args[0]].ty
            op := match st {
                I8 => Sxtb
                I16 => Sxth
                _ => Sxtw
            }
            self.e(op, if ty == I64 { 8 } else { 4 }, self.vr(v), self.reg(i.args[0]), NOREG)
        }
        ZExt => {
            src := i.args[0]
            st := self.f.insts[src].ty
            d := self.vr(v)
            s := self.reg(src)
            if self.f.insts[src].op == Load {
                // loads zero-extend
                self.mov(d, s)
            } else {
                match st {
                    I8 => self.e(Uxtb, 4, d, s, NOREG)
                    I16 => self.e(Uxth, 4, d, s, NOREG)
                    _ => self.e(Mov, 4, d, s, NOREG)
                }
            }
        }
        Trunc => self.mov(self.vr(v), self.reg(i.args[0]))
        SIToF => {
            st := self.f.insts[i.args[0]].ty
            s := self.ext32(i.args[0], true)
            si := ainst(Scvtf, fsz(ty), self.vr(v), s, NOREG)
            si.k = if st == I64 { 8 } else { 4 }
            self.out.push(si)
        }
        FToSI => {
            ci := ainst(Fcvtzs, if ty == I64 { 8 } else { 4 }, self.vr(v), self.reg(i.args[0]), NOREG)
            ci.k = fsz(self.f.insts[i.args[0]].ty)
            self.out.push(ci)
        }
        BitsToF => self.e(FmovToV, fsz(ty), self.vr(v), self.reg(i.args[0]), NOREG)
        FToBits => self.e(FmovToX, fsz(self.f.insts[i.args[0]].ty), self.vr(v), self.reg(i.args[0]), NOREG)
        Select => {
            c := i.args[0]
            x := self.reg(i.args[1])
            y := self.reg(i.args[2])
            cc := self.cond(c)
            d := self.vr(v)
            si := ainst(if ty.is_fp() { Fcsel } else { Csel }, if ty.is_fp() { fsz(ty) } else { 8 }, d, x, y)
            si.cc = u8(cc)
            self.out.push(si)
        }
        Load => {
            d := self.vr(v)
            am := self.addr(i.args[0])
            match ty {
                F32 => self.mem(FLdr, 4, d, am)
                F64, V2 => self.mem(FLdr, 8, d, am)
                V4 => self.mem(FLdr, 16, d, am)
                V3 => {
                    // x, y as one 8-byte load; z into lane 2
                    t := self.fp()
                    self.mem(FLdr, 8, d, am)
                    hi := am
                    hi.imm += 8
                    self.mem(FLdr, 4, t, hi)
                    ii := ainst(Ins, 16, d, t, NOREG)
                    ii.sh = 2
                    self.out.push(ii)
                }
                _ => self.mem(Ldr, sz_of(ty), d, am)
            }
        }
        Store => {
            val := i.args[1]
            vi := &self.f.insts[val]
            if ty.is_fp() {
                r := self.reg(val)
                am := self.addr(i.args[0])
                match ty {
                    F32 => self.mem(FStr, 4, r, am)
                    F64, V2 => self.mem(FStr, 8, r, am)
                    V4 => self.mem(FStr, 16, r, am)
                    _ => {
                        // V3: x, y, then z
                        self.mem(FStr, 8, r, am)
                        t := self.fp()
                        di := ainst(DupS, 4, t, r, NOREG)
                        di.sh = 2
                        self.out.push(di)
                        hi := am
                        hi.imm += 8
                        self.mem(FStr, 4, t, hi)
                    }
                }
            } else {
                r := if vi.op == Const && vi.k == 0 { A_ZR } else { self.reg(val) }
                am := self.addr(i.args[0])
                self.mem(Str, sz_of(ty), r, am)
            }
        }
        Call, CallInd => self.call(v, i)
        Syscall => self.syscall(v, i)
        Atomic => self.atomic(v)
        MemCpy, MemSet => {
            // the loop of the encoder changes its three registers: copies of the operands
            dst := self.gp()
            n := self.gp()
            self.mov(dst, self.reg(i.args[0]))
            self.mov(n, self.reg(i.args[2]))
            src := self.reg(i.args[1])
            if i.op == MemCpy {
                s2 := self.gp()
                self.mov(s2, src)
                src = s2
            }
            mi := ainst(if i.op == MemCpy { MemCopy } else { MemFill }, 8, NOREG, dst, src)
            mi.a = i32(n)
            self.out.push(mi)
        }
        VSplat => {
            di := ainst(DupV, 16, self.vr(v), self.reg(i.args[0]), NOREG)
            self.out.push(di)
        }
        VBuild => {
            d := self.vr(v)
            all_const := true
            bits := Bits128{lo: 0, hi: 0}
            for k, a in i.args {
                if self.f.insts[a].op != FConst {
                    all_const = false
                    break
                }
                c := u32(self.f.insts[a].k)
                sh := (32 * k) & 127
                if sh < 64 {
                    bits.lo |= u64(c) << sh
                } else {
                    bits.hi |= u64(c) << (sh - 64)
                }
            }
            if all_const {
                if bits.lo == 0 && bits.hi == 0 {
                    self.e(FZero, 16, d, NOREG, NOREG)
                } else {
                    self.fconst_load(d, bits, 16)
                }
                return
            }
            rs := vec[i64]()
            for a in i.args {
                rs.push(self.reg(a))
            }
            self.fmov(d, rs[0])
            for k in 1..rs.len {
                ii := ainst(Ins, 16, d, rs[k], NOREG)
                ii.sh = u8(k)
                self.out.push(ii)
            }
        }
        VExt => {
            di := ainst(DupS, 4, self.vr(v), self.reg(i.args[0]), NOREG)
            di.sh = u8(i.k)
            self.out.push(di)
        }
        VIns => {
            d := self.vr(v)
            x := self.reg(i.args[0])
            s := self.reg(i.args[1])
            self.fmov(d, x)
            ii := ainst(Ins, 16, d, s, NOREG)
            ii.sh = u8(i.k)
            self.out.push(ii)
        }
        VShuf => {
            si := ainst(Shuf, 16, self.vr(v), self.reg(i.args[0]), self.reg(i.args[1]))
            si.imm = i.k
            self.out.push(si)
        }
        RaAddr => {
            // the address of the saved link register (the frame record, see emit.al)
            self.mem(AdrS, 8, self.vr(v), AM{k: AK_INARG, base: NOREG, idx: NOREG, sh: 0, imm: 0, id: -1})
            self.mf.save_all = true
        }
        Bswap => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            self.e(Rev, osz(ty), d, s, NOREG)
            if ty == I16 {
                self.ei(LsrI, 4, d, d, 16)
            } else if ty == I8 {
                self.ei(LsrI, 4, d, d, 24)
            }
        }
        Popcnt => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            x := s
            if ty != I64 {
                x = self.gp()
                match ty {
                    I8 => self.e(Uxtb, 4, x, s, NOREG)
                    I16 => self.e(Uxth, 4, x, s, NOREG)
                    _ => self.e(Mov, 4, x, s, NOREG)
                }
            }
            self.e(Cnt, 8, d, x, NOREG)
        }
        Ctz => {
            d := self.vr(v)
            s := self.reg(i.args[0])
            x := s
            if ty == I8 || ty == I16 {
                // a bit just above the type: a zero counts as its width
                x = self.gp()
                self.ei(OrrI, 4, x, s, 1 << ty.bits())
            }
            t := self.gp()
            self.e(Rbit, osz(ty), t, x, NOREG)
            self.e(Clz, osz(ty), d, t, NOREG)
        }
        Clz => {
            d := self.vr(v)
            x := self.ext32(i.args[0], false)
            self.e(Clz, osz(ty), d, x, NOREG)
            if ty == I8 || ty == I16 {
                self.ei(SubI, 4, d, d, 32 - ty.bits())
            }
        }
        _ => {
            if i.op.is_cmp() {
                cc := self.cmp_flags(v)
                ci := ainst(Cset, 4, self.vr(v), NOREG, NOREG)
                ci.cc = u8(cc)
                self.out.push(ci)
            } else {
                panic(fmt("arm64 isel: unhandled op ", i.op))
            }
        }
    }
}

// the arguments in x0-x7 and v0-v7, the rest in stack words (a vector in two); the results in
// x0-x3 and v0-v3
priv fn call(self: *Sel, v: i64, i: *Inst) {
    self.mf.has_calls = true
    args := i.args
    target := NOREG
    if i.op == CallInd {
        args = args[1..]
    }
    ni := 0
    nf := 0
    nstack := 0
    regs := vec[(i64, i64)]()
    for a in args {
        at := self.f.insts[a].ty
        r := self.reg(a)
        if at.is_fp() {
            if nf < A_NARG {
                regs.push((A_V0 + nf, r))
                nf += 1
            } else {
                self.mem(FStr, if at.is_vec() { 16 } else { fsz(at) }, r, AM{k: AK_OUTARG, base: NOREG, idx: NOREG, sh: 0, imm: 0, id: nstack})
                nstack += if at.is_vec() { 2 } else { 1 }
            }
        } else if ni < A_NARG {
            regs.push((ni, r))
            ni += 1
        } else {
            self.mem(Str, 8, r, AM{k: AK_OUTARG, base: NOREG, idx: NOREG, sh: 0, imm: 0, id: nstack})
            nstack += 1
        }
    }
    if i.op == CallInd {
        target = self.reg(i.args[0])
    }
    self.mf.out_args = max(self.mf.out_args, nstack)
    used := vec[i64]()
    for rm in regs {
        if rm.0 >= A_V0 {
            self.fmov(rm.0, rm.1)
        } else {
            self.mov(rm.0, rm.1)
        }
        used.push(rm.0)
    }
    if i.op == CallInd {
        ci := self.mf.a_with_uses(Blr, used.items())
        ci.n = i32(target)
        self.out.push(ci)
    } else {
        ci := self.mf.a_with_uses(Bl, used.items())
        ci.id = i32(i.k)
        self.out.push(ci)
    }
    // results
    if i.ty != Void {
        if self.needed[v] {
            if i.ty.is_fp() {
                self.fmov(self.vr(v), A_V0)
            } else {
                self.mov(self.vr(v), 0)
            }
        }
        return
    }
    ps, has := self.projs.get(v)
    if !has {
        return
    }
    by_idx := clone(ps)
    sort_by(by_idx.items(), fn(a: (i64, i64), b: (i64, i64)) -> bool { a.0 < b.0 || (a.0 == b.0 && a.1 < b.1) })
    maxi := by_idx.last().0
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
            locs.push(A_V0 + nf2)
            nf2 += 1
        } else {
            locs.push(ni2)
            ni2 += 1
        }
    }
    for kp in by_idx {
        k, p := kp
        if !self.needed[p] {
            continue
        }
        if self.f.insts[p].ty.is_fp() {
            self.fmov(self.vr(p), locs[k])
        } else {
            self.mov(self.vr(p), locs[k])
        }
    }
}

// a Linux system call: the number in x8, the arguments in x0-x5, the result in x0. k 1: the
// clone of a thread (`__clone(flags, stack, ptid, ctid, tls)`, whose x86-64 number the lowering
// put first): number 220, and arm64 takes tls before ctid; the child calls the function on its
// new stack (see emit.al)
priv fn syscall(self: *Sel, v: i64, i: *Inst) {
    srcs := vec[i64]()
    for a in i.args {
        srcs.push(self.reg(a))
    }
    nr := srcs[0]
    args := srcs[1..]
    if i.k == 1 {
        nr = self.gp()
        self.movi(nr, 220)
        swap(&args[3], &args[4])
    }
    used := vec[i64]()
    self.mov(8, nr)
    used.push(8)
    for k, r in args {
        self.mov(k, r)
        used.push(k)
    }
    si := self.mf.a_with_uses(Svc, used.items())
    si.cc = u8(i.k)
    self.out.push(si)
    if self.needed[v] {
        self.mov(self.vr(v), 0)
    }
}

// Op.Atomic: acquire / release accesses and loops of exclusive accesses (LDAXR / STLXR), which
// work on every ARMv8 processor; results narrower than 64 bits are zero-extended
priv fn atomic(self: *Sel, v: i64) {
    i := &self.f.insts[v]
    k := i.k
    if k == ATOMIC_FENCE {
        self.e(Dmb, 0, NOREG, NOREG, NOREG)
        return
    }
    sz := sz_of(i.ty)
    p := self.reg(i.args[0])
    match k {
        ATOMIC_LOAD => self.e(Ldar, sz, self.vr(v), p, NOREG)
        ATOMIC_STORE => {
            si := ainst(Stlr, sz, NOREG, p, NOREG)
            si.a = i32(self.reg(i.args[1]))
            self.out.push(si)
        }
        ATOMIC_SWAP, ATOMIC_ADD => {
            x := self.reg(i.args[1])
            d := self.vr(v)
            self.e(if k == ATOMIC_ADD { AtAdd } else { AtSwap }, sz, d, p, x)
        }
        _ => {
            x := self.reg(i.args[1])
            y := self.reg(i.args[2])
            d := self.vr(v)
            ci := ainst(AtCas, sz, d, p, x)
            ci.a = i32(y)
            self.out.push(ci)
        }
    }
}
