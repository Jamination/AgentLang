// Instruction selection: SSA IR -> x86-64 machine IR with virtual registers.
use super::mir::*;
use crate::ir::*;
use std::collections::HashMap;

// A header phi `p` whose old value is needed after the loop is found in the register of the
// header phi `q` that receives it on the back edge.
pub struct ExitAlias {
    pub p: V,
    pub q: V,
    pub header: B,
}

// Split critical edges so that phi copies have a place to live. A loop back edge is left alone
// when the loop is only left through its latch (or through traps): its copies are emitted in
// the latch before the branch, and uses of header phis after the loop are redirected.
pub fn split_critical_edges(f: &mut Func) -> Vec<ExitAlias> {
    let cfg = Cfg::new(f);
    let loops = Loops::new(f, &cfg);
    let preds = f.preds();
    let nb = f.blocks.len();
    let def_block = f.block_of();
    let mut aliases: Vec<ExitAlias> = Vec::new();
    // can the back edge latch -> header stay unsplit? returns the aliases needed after the loop
    let analyze = |f: &Func, latch: B, header: B, other: B, c: V| -> Option<Vec<ExitAlias>> {
        if !cfg.reachable(latch) || !cfg.dom(header, latch) {
            return None;
        }
        let li = (0..loops.loops.len()).find(|&li| loops.loops[li].header == header)?;
        let l = &loops.loops[li];
        if l.latches.len() != 1 || loops.contains(li, other) {
            return None;
        }
        let phis: Vec<V> = f.blocks[header as usize].insts.iter().copied().take_while(|v| f.insts[*v as usize].op == Op::Phi).collect();
        if phis.is_empty() {
            return None;
        }
        // the branch condition (and what gets folded into it) must not read the header phis
        let is_hphi = |v: V| f.insts[v as usize].op == Op::Phi && def_block[v as usize] == header;
        let ci = &f.insts[c as usize];
        if is_hphi(c) || (ci.op.is_cmp() && ci.args.iter().any(|a| is_hphi(*a))) {
            return None;
        }
        // operands folded into the compare are evaluated after the copies: they must not
        // depend on a header phi through anything that gets folded (addresses, test operands)
        fn tree_has(f: &Func, v: V, depth: u32, is_hphi: &dyn Fn(V) -> bool) -> bool {
            if is_hphi(v) {
                return true;
            }
            let i = &f.insts[v as usize];
            if !matches!(i.op, Op::Add | Op::Sub | Op::Shl | Op::Mul | Op::Load | Op::And) {
                return false;
            }
            if depth == 0 {
                return true;
            }
            i.args.iter().any(|a| tree_has(f, *a, depth - 1, is_hphi))
        }
        if ci.args.iter().any(|a| {
            let ai = &f.insts[*a as usize];
            matches!(ai.op, Op::And | Op::Load) && tree_has(f, *a, 12, &is_hphi)
        }) {
            return None;
        }
        // every other way out of the loop must be a trap
        let mut trap_exits: Vec<B> = Vec::new();
        for &b in &l.blocks {
            for s in f.succs(b) {
                if loops.contains(li, s) || (b == latch && s == other) {
                    continue;
                }
                if f.blocks[s as usize].term != Term::Trap {
                    return None;
                }
                trap_exits.push(s);
            }
            if matches!(f.blocks[b as usize].term, Term::Ret(_)) {
                return None;
            }
        }
        // Instruction selection may evaluate address arithmetic and compares lazily at their
        // use. Anything computed from a header phi inside the loop that could be re-evaluated
        // after the loop would then read the already-updated phi register: keep the edge split.
        let mut derived: Vec<V> = phis.clone();
        let mut qi = 0;
        while qi < derived.len() {
            let x = derived[qi];
            qi += 1;
            for &b in &l.blocks {
                for &u in &f.blocks[b as usize].insts {
                    let ui = &f.insts[u as usize];
                    let lazy = matches!(ui.op, Op::Add | Op::Sub | Op::Shl | Op::Mul | Op::And) || ui.op.is_cmp();
                    if lazy && ui.args.contains(&x) && !derived.contains(&u) {
                        derived.push(u);
                    }
                }
            }
        }
        for b in 0..nb {
            if !cfg.reachable(b as B) || loops.contains(li, b as B) {
                continue;
            }
            let lazy_use = |a: &V| derived.contains(a) && !phis.contains(a);
            if f.blocks[b].insts.iter().any(|v| f.insts[*v as usize].args.iter().any(lazy_use)) || f.term_uses(b as B).iter().any(lazy_use) {
                return None;
            }
        }
        // phis used after the loop need a partner that receives them on the back edge
        let mut out = Vec::new();
        for b in 0..nb {
            if !cfg.reachable(b as B) || loops.contains(li, b as B) {
                continue;
            }
            let mut used: Vec<V> = Vec::new();
            for &v in &f.blocks[b].insts {
                for a in &f.insts[v as usize].args {
                    if phis.contains(a) {
                        used.push(*a);
                    }
                }
            }
            for a in f.term_uses(b as B) {
                if phis.contains(&a) {
                    used.push(a);
                }
            }
            if used.is_empty() {
                continue;
            }
            if trap_exits.contains(&(b as B)) {
                return None;
            }
            for p in used {
                let partner = phis.iter().copied().find(|&q| {
                    let qi = &f.insts[q as usize];
                    q != p && qi.pb.iter().zip(qi.args.iter()).any(|(pb, a)| *pb == latch && *a == p)
                })?;
                out.push(ExitAlias { p, q: partner, header });
            }
        }
        Some(out)
    };
    // decide first (on the unmodified CFG), then split
    let mut keep: Vec<(B, B)> = Vec::new();
    for b in 0..nb {
        if let Term::Br(c, t, e) = f.blocks[b].term.clone() {
            if t == e {
                continue;
            }
            for (s, other) in [(t, e), (e, t)] {
                if preds[s as usize].len() > 1 {
                    if let Some(al) = analyze(f, b as B, s, other, c) {
                        aliases.extend(al);
                        keep.push((b as B, s));
                    }
                }
            }
        }
    }
    for b in 0..nb {
        if let Term::Br(c, t, e) = f.blocks[b].term.clone() {
            if t == e {
                f.blocks[b].term = Term::Jmp(t);
                continue;
            }
            let mut nt = t;
            let mut ne = e;
            for (which, s) in [(0, t), (1, e)] {
                if preds[s as usize].len() > 1 {
                    if keep.contains(&(b as B, s)) {
                        continue;
                    }
                    let nbk = f.new_block();
                    f.blocks[nbk as usize].term = Term::Jmp(s);
                    for ii in 0..f.blocks[s as usize].insts.len() {
                        let v = f.blocks[s as usize].insts[ii];
                        if f.insts[v as usize].op != Op::Phi {
                            continue;
                        }
                        for p in f.insts[v as usize].pb.iter_mut() {
                            if *p == b as B {
                                *p = nbk;
                            }
                        }
                    }
                    if which == 0 {
                        nt = nbk;
                    } else {
                        ne = nbk;
                    }
                }
            }
            f.blocks[b].term = Term::Br(c, nt, ne);
        }
    }
    aliases
}

fn sz_of(t: T) -> u8 {
    match t {
        T::I8 => 1,
        T::I16 => 2,
        T::I32 => 4,
        _ => 8,
    }
}
// operation size for wrap-around arithmetic: narrow types use 32-bit instructions
fn osz(t: T) -> u8 {
    match t {
        T::I64 => 8,
        _ => 4,
    }
}
fn fits32(k: i64) -> bool {
    k >= i32::MIN as i64 && k <= i32::MAX as i64
}
// operation size of an xmm type: scalar single, scalar double, packed
fn fsz(t: T) -> u8 {
    match t {
        T::F32 => 4,
        T::F64 => 8,
        _ => 16,
    }
}
// size of a plain memory move of an xmm type (vec3 takes two moves)
fn fsz_mem(t: T) -> u8 {
    match t {
        T::F32 => 4,
        T::F64 | T::V2 => 8,
        _ => 16,
    }
}

struct Sel<'a> {
    f: &'a Func,
    m: &'a Module,
    mf: MFunc,
    vreg: Vec<Reg>,
    uses: Vec<u32>,
    needed: Vec<bool>,
    addr_only: Vec<bool>,
    blk_of: Vec<B>,
    slot_of: HashMap<V, u32>,
    projs: HashMap<V, Vec<(i64, V)>>,
    out: Vec<MInst>,
    fconst_ix: HashMap<u128, u32>,
    // memory-clobber counter position of each instruction within its block (for load folding)
    pos_in_block: Vec<u32>,
    clob: Vec<u32>,
    cur_clob: u32,
    cur_block: B,
    exit_alias: HashMap<V, (V, usize)>,
    loops: Loops,
}

pub fn select(f: &Func, m: &Module, depths: &[u32], aliases: &[ExitAlias]) -> MFunc {
    let n = f.insts.len();
    let cfg = Cfg::new(f);
    let loops = Loops::new(f, &cfg);
    let mut exit_alias: HashMap<V, (V, usize)> = HashMap::new();
    for a in aliases {
        if let Some(li) = (0..loops.loops.len()).find(|&li| loops.loops[li].header == a.header) {
            exit_alias.insert(a.p, (a.q, li));
        }
    }
    let mut s = Sel {
        f,
        m,
        mf: MFunc {
            name: f.name.clone(),
            blocks: Vec::new(),
            vclass: Vec::new(),
            slots: Vec::new(),
            out_args: 0,
            fconsts: Vec::new(),
            has_calls: false,
            wide_xmm: f.insts.iter().any(|i| i.ty.is_vec()),
        },
        vreg: vec![NOREG; n],
        uses: f.use_counts(),
        needed: vec![false; n],
        addr_only: vec![true; n],
        blk_of: f.block_of(),
        slot_of: HashMap::new(),
        projs: HashMap::new(),
        out: Vec::new(),
        fconst_ix: HashMap::new(),
        pos_in_block: vec![0; n],
        clob: vec![0; n],
        cur_clob: 0,
        cur_block: 0,
        exit_alias,
        loops,
    };
    for b in 0..f.blocks.len() {
        s.mf.blocks.push(MBlock { insts: Vec::new(), succs: f.succs(b as B), depth: depths.get(b).copied().unwrap_or(0), align: false });
    }
    // per-value facts
    for b in &f.blocks {
        let mut nclob = 0u32;
        for (pi, &v) in b.insts.iter().enumerate() {
            s.pos_in_block[v as usize] = pi as u32;
            s.clob[v as usize] = nclob;
            if crate::opt::cleanup::is_root(f.insts[v as usize].op) {
                nclob += 1;
            }
            let i = &f.insts[v as usize];
            match i.op {
                Op::Load => {}
                Op::Store => {
                    s.addr_only[i.args[1] as usize] = false;
                }
                Op::Proj => {
                    s.projs.entry(i.args[0]).or_default().push((i.k, v));
                    s.addr_only[i.args[0] as usize] = false;
                }
                _ => {
                    for &a in &i.args {
                        s.addr_only[a as usize] = false;
                    }
                }
            }
        }
        match &b.term {
            Term::Br(c, _, _) => s.addr_only[*c as usize] = false,
            Term::Ret(vs) => {
                for v in vs {
                    s.addr_only[*v as usize] = false;
                }
            }
            _ => {}
        }
    }
    for &v in &f.blocks[0].insts {
        if f.insts[v as usize].op == Op::Alloca {
            let sl = s.mf.new_slot(f.insts[v as usize].k as u32, f.insts[v as usize].aux);
            s.slot_of.insert(v, sl);
        }
    }
    let rpo = f.rpo();
    for &b in rpo.iter().rev() {
        s.cur_block = b;
        s.cur_clob = f.blocks[b as usize].insts.iter().filter(|v| crate::opt::cleanup::is_root(f.insts[**v as usize].op)).count() as u32;
        let mut rev: Vec<MInst> = Vec::new();
        // terminator (with phi copies for the unique successor)
        s.out.clear();
        s.term(b);
        rev.extend(s.out.drain(..).rev());
        for &v in f.blocks[b as usize].insts.iter().rev() {
            let op = f.insts[v as usize].op;
            if op == Op::Const && s.needed[v as usize] {
                // a wide constant kept in a register (so that loops do not rebuild it)
                let d = s.vr(v);
                rev.push(MInst::new(MOp::Mov, 8, Opnd::R(d), Opnd::I(f.insts[v as usize].k)));
                continue;
            }
            if matches!(op, Op::Phi | Op::Param | Op::Alloca | Op::Const | Op::FConst | Op::GAddr | Op::FAddr | Op::Proj) {
                continue;
            }
            if crate::opt::cleanup::is_root(op) || s.needed[v as usize] {
                s.out.clear();
                s.cur_clob = s.clob[v as usize];
                s.inst(v);
                rev.extend(s.out.drain(..).rev());
            }
        }
        if b == 0 {
            s.out.clear();
            s.params();
            rev.extend(s.out.drain(..).rev());
        }
        rev.reverse();
        s.mf.blocks[b as usize].insts = rev;
    }
    s.mf
}

impl<'a> Sel<'a> {
    fn e(&mut self, op: MOp, sz: u8, a: Opnd, b: Opnd) {
        self.out.push(MInst::new(op, sz, a, b));
    }
    fn shufps(&mut self, d: Reg, s: Reg, imm: i64) {
        let mut mi = MInst::new(MOp::Shufps, 16, Opnd::R(d), Opnd::R(s));
        mi.c = Opnd::I(imm);
        self.out.push(mi);
    }
    fn class_of(&self, v: V) -> u8 {
        if self.f.insts[v as usize].ty.is_fp() {
            1
        } else {
            0
        }
    }
    // the vreg holding IR value v (allocated on demand)
    fn vr(&mut self, v: V) -> Reg {
        if self.vreg[v as usize] == NOREG {
            let c = self.class_of(v);
            self.vreg[v as usize] = self.mf.new_vreg(c);
        }
        self.vreg[v as usize]
    }
    fn fconst(&mut self, bits: u128) -> Mem {
        let ix = match self.fconst_ix.get(&bits) {
            Some(&i) => i,
            None => {
                self.mf.fconsts.push(bits);
                let i = (self.mf.fconsts.len() - 1) as u32;
                self.fconst_ix.insert(bits, i);
                i
            }
        };
        Mem { base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKind::FConst, id: ix }
    }
    // a register holding v at the current point (materializes constants and addresses)
    fn reg(&mut self, v: V) -> Reg {
        let i = &self.f.insts[v as usize];
        match i.op {
            Op::Const if fits32(i.k) || self.blk_of[v as usize] == self.cur_block => {
                let r = self.mf.new_vreg(0);
                self.e(MOp::Mov, 8, Opnd::R(r), Opnd::I(i.k));
                r
            }
            Op::FConst => {
                let r = self.mf.new_vreg(1);
                if i.k == 0 {
                    self.e(MOp::Zero, 8, Opnd::R(r), Opnd::None);
                } else {
                    let m = self.fconst(i.k as u64 as u128);
                    self.e(MOp::MovSd, 8, Opnd::R(r), Opnd::M(m));
                }
                r
            }
            Op::GAddr => {
                let r = self.mf.new_vreg(0);
                self.e(MOp::Mov, 8, Opnd::R(r), Opnd::GAddr(i.k as u32, 0));
                r
            }
            Op::FAddr => {
                let r = self.mf.new_vreg(0);
                self.e(MOp::Mov, 8, Opnd::R(r), Opnd::FAddr(i.k as u32));
                r
            }
            Op::Alloca => {
                let r = self.mf.new_vreg(0);
                let sl = self.slot_of[&v];
                self.e(MOp::Lea, 8, Opnd::R(r), Opnd::M(Mem::slot(sl, 0)));
                r
            }
            _ => {
                if let Some(&(q, li)) = self.exit_alias.get(&v) {
                    if !self.loops.contains(li, self.cur_block) {
                        // after the loop the old value of this phi lives in its partner
                        self.needed[q as usize] = true;
                        return self.vr(q);
                    }
                }
                self.needed[v as usize] = true;
                self.vr(v)
            }
        }
    }
    // register or 32-bit immediate
    fn rmi(&mut self, v: V) -> Opnd {
        if let Some(k) = self.f.is_const(v) {
            if fits32(k) {
                return Opnd::I(k);
            }
        }
        Opnd::R(self.reg(v))
    }
    // can the load `v` be folded into the instruction currently being selected?
    fn can_fold_load(&self, v: V) -> bool {
        let i = &self.f.insts[v as usize];
        i.op == Op::Load
            && self.uses[v as usize] == 1
            && self.blk_of[v as usize] == self.cur_block
            && self.clob[v as usize] == self.cur_clob
            && self.vreg[v as usize] == NOREG
            && !self.needed[v as usize]
    }
    fn load_mem(&mut self, v: V) -> Option<Mem> {
        if !self.can_fold_load(v) {
            return None;
        }
        let a = self.f.insts[v as usize].args[0];
        Some(self.addr(a))
    }
    // register, 32-bit immediate, or a folded load of the full operation width
    fn rmi_mem(&mut self, v: V, ty: T) -> Opnd {
        if (ty == T::I32 || ty == T::I64) && self.f.insts[v as usize].ty == ty {
            if let Some(m) = self.load_mem(v) {
                return Opnd::M(m);
            }
        }
        self.rmi(v)
    }
    // xmm register or memory (float constant or folded load)
    fn xm(&mut self, v: V) -> Opnd {
        let i = &self.f.insts[v as usize];
        if i.op == Op::FConst && i.k != 0 {
            let m = self.fconst(i.k as u64 as u128);
            return Opnd::M(m);
        }
        if i.ty.is_vec() {
            // packed operations need aligned memory operands: vector loads are never folded
            return Opnd::R(self.reg(v));
        }
        if let Some(m) = self.load_mem(v) {
            return Opnd::M(m);
        }
        Opnd::R(self.reg(v))
    }

    // ---------- addressing modes ----------
    fn foldable_add(&self, v: V) -> bool {
        let i = &self.f.insts[v as usize];
        if i.op != Op::Add || i.ty != T::I64 {
            return false;
        }
        if self.uses[v as usize] <= 1 || self.addr_only[v as usize] {
            return true;
        }
        // x + const never lengthens live ranges
        let leafy = |a: V| matches!(self.f.insts[a as usize].op, Op::Const | Op::GAddr | Op::Alloca);
        leafy(i.args[0]) || leafy(i.args[1])
    }

    fn addr_term(&mut self, v: V, m: &mut Mem, depth: u32) {
        let i = &self.f.insts[v as usize];
        match i.op {
            Op::Const if fits32(i.k) && fits32(m.disp as i64 + i.k) => {
                m.disp += i.k as i32;
                return;
            }
            Op::GAddr if m.kind == MemKind::Normal => {
                m.kind = MemKind::Global;
                m.id = i.k as u32;
                return;
            }
            Op::Alloca if m.kind == MemKind::Normal && m.base == NOREG => {
                m.kind = MemKind::Slot;
                m.id = self.slot_of[&v];
                return;
            }
            Op::Add if depth < 8 && self.foldable_add(v) => {
                let (a, b) = (i.args[0], i.args[1]);
                self.addr_term(a, m, depth + 1);
                self.addr_term(b, m, depth + 1);
                return;
            }
            Op::Shl | Op::Mul if m.idx == NOREG && i.ty == T::I64 => {
                if let Some(k) = self.f.is_const(i.args[1]) {
                    let scale = if i.op == Op::Shl {
                        if (1..=3).contains(&k) {
                            1u8 << k
                        } else {
                            0
                        }
                    } else if k == 2 || k == 4 || k == 8 {
                        k as u8
                    } else {
                        0
                    };
                    if scale != 0 {
                        let x = i.args[0];
                        m.idx = self.reg(x);
                        m.scale = scale;
                        return;
                    }
                }
            }
            _ => {}
        }
        let r = self.reg(v);
        let base_free = m.base == NOREG && m.kind != MemKind::Slot;
        if base_free {
            m.base = r;
        } else if m.idx == NOREG {
            m.idx = r;
            m.scale = 1;
        } else {
            // out of components: collapse what we have into a temporary
            let t = self.mf.new_vreg(0);
            self.e(MOp::Lea, 8, Opnd::R(t), Opnd::M(*m));
            *m = Mem::new();
            m.base = t;
            m.idx = r;
            m.scale = 1;
        }
    }

    fn addr(&mut self, v: V) -> Mem {
        let mut m = Mem::new();
        self.addr_term(v, &mut m, 0);
        m
    }

    // ---------- parameters ----------
    fn params(&mut self) {
        let mut ni = 0usize;
        let mut nf = 0usize;
        let mut nstack = 0u32;
        // locate Param instructions by index
        let mut by_index: HashMap<i64, V> = HashMap::new();
        for b in &self.f.blocks {
            for &v in &b.insts {
                if self.f.insts[v as usize].op == Op::Param {
                    by_index.insert(self.f.insts[v as usize].k, v);
                }
            }
        }
        let params = self.f.params.clone();
        for (pi, &t) in params.iter().enumerate() {
            let pv = by_index.get(&(pi as i64)).copied();
            let want = pv.map(|v| self.needed[v as usize]).unwrap_or(false);
            if t.is_fp() {
                if nf < NUM_FLOAT_ARGS {
                    if want {
                        let d = self.vr(pv.unwrap());
                        self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(XMM0 + nf as Reg));
                    }
                    nf += 1;
                } else {
                    if want {
                        let d = self.vr(pv.unwrap());
                        let m = Mem { base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKind::InArg, id: nstack };
                        self.e(MOp::MovSd, fsz(t), Opnd::R(d), Opnd::M(m));
                    }
                    nstack += if t.is_vec() { 2 } else { 1 };
                }
            } else if ni < INT_ARGS.len() {
                if want {
                    let d = self.vr(pv.unwrap());
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(INT_ARGS[ni]));
                }
                ni += 1;
            } else {
                if want {
                    let d = self.vr(pv.unwrap());
                    let m = Mem { base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKind::InArg, id: nstack };
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::M(m));
                }
                nstack += 1;
            }
        }
    }

    // ---------- terminators ----------
    fn phi_copies(&mut self, b: B, s: B) {
        // parallel copies for the phis of s along edge b -> s
        let mut moves: Vec<(Reg, Opnd, u8)> = Vec::new();
        let phis: Vec<V> = self.f.blocks[s as usize].insts.iter().copied().take_while(|v| self.f.insts[*v as usize].op == Op::Phi).collect();
        for p in phis {
            self.needed[p as usize] = true;
            let inst = &self.f.insts[p as usize];
            let ai = match inst.pb.iter().position(|x| *x == b) {
                Some(ai) => ai,
                None => continue,
            };
            let src = inst.args[ai];
            let cls = self.class_of(p);
            let d = self.vr(p);
            let si = &self.f.insts[src as usize];
            let so = match si.op {
                Op::Const => Opnd::I(si.k),
                Op::GAddr => Opnd::GAddr(si.k as u32, 0),
                Op::FAddr => Opnd::FAddr(si.k as u32),
                Op::FConst if si.k == 0 => Opnd::None,
                Op::FConst => Opnd::M(self.fconst(si.k as u64 as u128)),
                Op::Alloca => Opnd::M(Mem::slot(self.slot_of[&src], 0)),
                _ => {
                    let r = self.reg(src);
                    if r == d {
                        continue;
                    }
                    Opnd::R(r)
                }
            };
            moves.push((d, so, cls));
        }
        // sequentialize: register sources first, respecting dependencies
        let mut pending: Vec<(Reg, Opnd, u8)> = moves.iter().copied().filter(|m| matches!(m.1, Opnd::R(_))).collect();
        while !pending.is_empty() {
            let mut progressed = false;
            let mut i = 0;
            while i < pending.len() {
                let d = pending[i].0;
                let blocked = pending.iter().enumerate().any(|(j, m)| j != i && m.1 == Opnd::R(d));
                if !blocked {
                    let (d, s, cls) = pending.remove(i);
                    self.e(if cls == 1 { MOp::MovSd } else { MOp::Mov }, 8, Opnd::R(d), s);
                    progressed = true;
                } else {
                    i += 1;
                }
            }
            if !progressed {
                // cycle: save one destination in a temporary
                let (d, _, cls) = pending[0];
                let t = self.mf.new_vreg(cls);
                self.e(if cls == 1 { MOp::MovSd } else { MOp::Mov }, 8, Opnd::R(t), Opnd::R(d));
                for m in pending.iter_mut() {
                    if m.1 == Opnd::R(d) {
                        m.1 = Opnd::R(t);
                    }
                }
            }
        }
        for (d, s, cls) in moves {
            match s {
                Opnd::R(_) => {}
                Opnd::None => self.e(MOp::Zero, 8, Opnd::R(d), Opnd::None),
                Opnd::M(m) if m.kind == MemKind::Slot => self.e(MOp::Lea, 8, Opnd::R(d), s),
                Opnd::M(_) => self.e(MOp::MovSd, 8, Opnd::R(d), s),
                _ => {
                    let _ = cls;
                    self.e(MOp::Mov, 8, Opnd::R(d), s)
                }
            }
        }
    }

    // emit a flag-setting compare for IR compare `c`; returns the condition code(s) to test
    // result: (cc, extra) where extra: 0 = none, 1 = "and not parity" (FEq), 2 = "or parity" (FNe)
    fn cmp_flags(&mut self, c: V) -> (u8, u8) {
        let i = &self.f.insts[c as usize];
        let (a, b) = (i.args[0], i.args[1]);
        let at = self.f.insts[a as usize].ty;
        if i.op.is_icmp() {
            let sz = sz_of(at);
            let mut op = i.op;
            let (mut x, mut y) = (a, b);
            // constant on the left: swap
            if self.f.is_const(x).is_some() && self.f.is_const(y).is_none() {
                std::mem::swap(&mut x, &mut y);
                op = op.swap_cmp();
            }
            let cc = match op {
                Op::Eq => cc::E,
                Op::Ne => cc::NE,
                Op::Slt => cc::L,
                Op::Sle => cc::LE,
                Op::Sgt => cc::G,
                Op::Sge => cc::GE,
                Op::Ult => cc::B,
                Op::Ule => cc::BE,
                Op::Ugt => cc::A,
                _ => cc::AE,
            };
            if self.f.is_const(y) == Some(0) && matches!(op, Op::Eq | Op::Ne | Op::Slt | Op::Sle | Op::Sgt | Op::Sge) && !self.can_fold_load(x) {
                // test x, x  (or test a, b for (a & b) ==/!= 0)
                let xi = &self.f.insts[x as usize];
                if matches!(op, Op::Eq | Op::Ne) && xi.op == Op::And && self.uses[x as usize] == 1 && self.blk_of[x as usize] == self.cur_block {
                    let (p, q) = (xi.args[0], xi.args[1]);
                    let pr = self.reg(p);
                    let qo = self.rmi(q);
                    self.e(MOp::Test, sz, Opnd::R(pr), qo);
                    return (cc, 0);
                }
                let xr = self.reg(x);
                self.e(MOp::Test, sz, Opnd::R(xr), Opnd::R(xr));
                return (cc, 0);
            }
            // memory operands: cmp [mem], imm  /  cmp reg, [mem]
            if let Some(k) = self.f.is_const(y) {
                if fits32(k) {
                    if let Some(m) = self.load_mem(x) {
                        self.e(MOp::Cmp, sz, Opnd::M(m), Opnd::I(k));
                        return (cc, 0);
                    }
                }
            }
            let xr = self.reg(x);
            let yo = match self.load_mem(y) {
                Some(m) => Opnd::M(m),
                None => self.rmi(y),
            };
            self.e(MOp::Cmp, sz, Opnd::R(xr), yo);
            return (cc, 0);
        }
        // float compares: arrange operands so that unordered yields false
        match i.op {
            Op::FLt | Op::FLe => {
                let br = self.reg(b);
                let ao = self.xm(a);
                self.e(MOp::Ucomisd, fsz(at), Opnd::R(br), ao);
                (if i.op == Op::FLt { cc::A } else { cc::AE }, 0)
            }
            Op::FGt | Op::FGe => {
                let ar = self.reg(a);
                let bo = self.xm(b);
                self.e(MOp::Ucomisd, fsz(at), Opnd::R(ar), bo);
                (if i.op == Op::FGt { cc::A } else { cc::AE }, 0)
            }
            Op::FEq => {
                let ar = self.reg(a);
                let bo = self.xm(b);
                self.e(MOp::Ucomisd, fsz(at), Opnd::R(ar), bo);
                (cc::E, 1)
            }
            _ => {
                let ar = self.reg(a);
                let bo = self.xm(b);
                self.e(MOp::Ucomisd, fsz(at), Opnd::R(ar), bo);
                (cc::NE, 2)
            }
        }
    }

    fn jcc(&mut self, cc: u8, t: B) {
        let mut i = MInst::new(MOp::Jcc, 0, Opnd::None, Opnd::None);
        i.cc = cc;
        i.tgt = t;
        self.out.push(i);
    }
    fn jmp(&mut self, t: B) {
        let mut i = MInst::new(MOp::Jmp, 0, Opnd::None, Opnd::None);
        i.tgt = t;
        self.out.push(i);
    }

    fn term(&mut self, b: B) {
        match self.f.blocks[b as usize].term.clone() {
            Term::Jmp(t) => {
                self.phi_copies(b, t);
                self.jmp(t);
            }
            Term::Br(c, t, e) => {
                // an unsplit loop back edge: its phi copies go before the compare
                for s in [t, e] {
                    let has_phi = self.f.blocks[s as usize].insts.first().map(|v| self.f.insts[*v as usize].op == Op::Phi).unwrap_or(false);
                    if has_phi {
                        self.phi_copies(b, s);
                    }
                }
                let ci = &self.f.insts[c as usize];
                if ci.op.is_cmp() {
                    let (cc, extra) = self.cmp_flags(c);
                    match extra {
                        0 => {
                            self.jcc(cc, t);
                            self.jmp(e);
                        }
                        1 => {
                            // true iff ZF && !PF
                            self.jcc(cc::NE, e);
                            self.jcc(cc::P, e);
                            self.jmp(t);
                        }
                        _ => {
                            // true iff !ZF || PF
                            self.jcc(cc::NE, t);
                            self.jcc(cc::P, t);
                            self.jmp(e);
                        }
                    }
                } else {
                    let r = self.reg(c);
                    self.e(MOp::Test, 1, Opnd::R(r), Opnd::R(r));
                    self.jcc(cc::NE, t);
                    self.jmp(e);
                }
            }
            Term::Ret(vals) => {
                let mut ni = 0;
                let mut nf = 0;
                let mut used = Vec::new();
                let mut moves: Vec<(Reg, V)> = Vec::new();
                for &v in &vals {
                    if self.f.insts[v as usize].ty.is_fp() {
                        moves.push((XMM0 + nf as Reg, v));
                        nf += 1;
                    } else {
                        moves.push((INT_RETS[ni], v));
                        ni += 1;
                    }
                }
                // evaluate sources into vregs first, then move to the fixed registers
                let srcs: Vec<(Reg, Opnd, bool)> = moves
                    .iter()
                    .map(|&(d, v)| {
                        let isf = self.f.insts[v as usize].ty.is_fp();
                        let o = if !isf { self.mov_src(v) } else { Opnd::R(self.reg(v)) };
                        (d, o, isf)
                    })
                    .collect();
                for (d, o, isf) in srcs {
                    self.e(if isf { MOp::MovSd } else { MOp::Mov }, 8, Opnd::R(d), o);
                    used.push(d);
                }
                let mut i = MInst::new(MOp::Ret, 0, Opnd::None, Opnd::None);
                i.uses = used;
                self.out.push(i);
            }
            Term::Trap | Term::None => {
                self.e(MOp::Ud2, 0, Opnd::None, Opnd::None);
            }
        }
    }

    // a source operand for a full-width integer move: immediate, symbol address or register
    fn mov_src(&mut self, v: V) -> Opnd {
        let i = &self.f.insts[v as usize];
        match i.op {
            Op::Const => Opnd::I(i.k),
            Op::GAddr => Opnd::GAddr(i.k as u32, 0),
            Op::FAddr => Opnd::FAddr(i.k as u32),
            _ => Opnd::R(self.reg(v)),
        }
    }

    // ---------- instructions ----------
    fn binop(&mut self, v: V, mop: MOp, commutative: bool) {
        let i = &self.f.insts[v as usize];
        let (mut a, mut b) = (i.args[0], i.args[1]);
        let ty = i.ty;
        let sz = osz(ty);
        let wide = ty == T::I32 || ty == T::I64;
        if commutative && wide && !self.can_fold_load(b) && self.can_fold_load(a) {
            std::mem::swap(&mut a, &mut b);
        } else if commutative && !self.can_fold_load(b) && self.f.is_const(a).is_none() && self.uses[a as usize] > 1 && self.uses[b as usize] == 1 && self.f.is_const(b).is_none() {
            std::mem::swap(&mut a, &mut b);
        }
        let d = self.vr(v);
        let ar = self.reg(a);
        let bo = self.rmi_mem(b, ty);
        self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(ar));
        self.e(mop, sz, Opnd::R(d), bo);
    }

    fn fbinop(&mut self, v: V, mop: MOp, commutative: bool) {
        let i = &self.f.insts[v as usize];
        let (mut a, mut b) = (i.args[0], i.args[1]);
        let is_c = |s: &Self, x: V| s.f.insts[x as usize].op == Op::FConst;
        if commutative && !self.can_fold_load(b) && (is_c(self, a) || self.can_fold_load(a) || (self.uses[a as usize] > 1 && self.uses[b as usize] == 1 && !is_c(self, b))) {
            std::mem::swap(&mut a, &mut b);
        }
        let d = self.vr(v);
        let ar = self.reg(a);
        let bo = self.xm(b);
        let sz = fsz(self.f.insts[v as usize].ty);
        self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(ar));
        self.e(mop, sz, Opnd::R(d), bo);
    }

    fn zext_free(&self, v: V) -> bool {
        let i = &self.f.insts[v as usize];
        i.ty == T::I32
            && matches!(
                i.op,
                Op::Add | Op::Sub | Op::Mul | Op::And | Op::Or | Op::Xor | Op::Shl | Op::LShr | Op::AShr | Op::Rotl | Op::Rotr | Op::Load | Op::ZExt | Op::SDiv | Op::UDiv | Op::SRem | Op::URem | Op::Bswap
            )
    }

    // value extended to 32 bits (for narrow division/shift inputs)
    fn ext32(&mut self, v: V, signed: bool) -> Reg {
        let t = self.f.insts[v as usize].ty;
        let r = self.reg(v);
        if t == T::I8 || t == T::I16 {
            let d = self.mf.new_vreg(0);
            let mut i = MInst::new(if signed { MOp::Movsx } else { MOp::Movzx }, sz_of(t), Opnd::R(d), Opnd::R(r));
            i.sz2 = 4;
            self.out.push(i);
            d
        } else {
            r
        }
    }

    fn inst(&mut self, v: V) {
        let i = self.f.insts[v as usize].clone();
        let ty = i.ty;
        match i.op {
            Op::Add => {
                if ty == T::I64 {
                    let mut m = Mem::new();
                    self.addr_term(i.args[0], &mut m, 1);
                    self.addr_term(i.args[1], &mut m, 1);
                    let d = self.vr(v);
                    let simple = m.kind == MemKind::Normal && m.idx == NOREG && m.base != NOREG;
                    if simple && m.disp == 0 {
                        self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(m.base));
                    } else if simple && self.uses_of_reg_single(&i, m.base) {
                        self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(m.base));
                        self.e(MOp::Add, 8, Opnd::R(d), Opnd::I(m.disp as i64));
                    } else if m.kind == MemKind::Normal && m.base != NOREG && m.idx != NOREG && m.scale == 1 && m.disp == 0 {
                        // a + b: two-address add when one side dies here
                        let (a, b) = (i.args[0], i.args[1]);
                        let (ra, rb) = (m.base, m.idx);
                        let direct = self.vreg[a as usize] == ra && self.vreg[b as usize] == rb;
                        if direct && self.dies_here(a) {
                            self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(ra));
                            self.e(MOp::Add, 8, Opnd::R(d), Opnd::R(rb));
                        } else if direct && self.dies_here(b) {
                            self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(rb));
                            self.e(MOp::Add, 8, Opnd::R(d), Opnd::R(ra));
                        } else {
                            self.e(MOp::Lea, 8, Opnd::R(d), Opnd::M(m));
                        }
                    } else if m.kind == MemKind::Global && m.base == NOREG && m.idx == NOREG {
                        self.e(MOp::Mov, 8, Opnd::R(d), Opnd::GAddr(m.id, m.disp));
                    } else {
                        self.e(MOp::Lea, 8, Opnd::R(d), Opnd::M(m));
                    }
                } else {
                    self.binop(v, MOp::Add, true);
                }
            }
            Op::Sub => {
                // 0 - x => neg
                if self.f.is_const(i.args[0]) == Some(0) {
                    let d = self.vr(v);
                    let r = self.reg(i.args[1]);
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(r));
                    self.e(MOp::Neg, osz(ty), Opnd::R(d), Opnd::None);
                } else {
                    self.binop(v, MOp::Sub, false);
                }
            }
            Op::Mul => {
                let (mut a, mut b) = (i.args[0], i.args[1]);
                if self.f.is_const(a).is_some() {
                    std::mem::swap(&mut a, &mut b);
                }
                let d = self.vr(v);
                match self.f.is_const(b) {
                    Some(k) if fits32(k) => {
                        let ar = self.reg(a);
                        let mut mi = MInst::new(MOp::Imul3, osz(ty), Opnd::R(d), Opnd::R(ar));
                        mi.c = Opnd::I(k);
                        self.out.push(mi);
                    }
                    Some(_) => {
                        // a constant too wide for an immediate: multiply two registers
                        let ar = self.reg(a);
                        let br = self.reg(b);
                        self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(ar));
                        self.e(MOp::Imul, osz(ty), Opnd::R(d), Opnd::R(br));
                    }
                    None => self.binop(v, MOp::Imul, true),
                }
            }
            Op::And => {
                // masks that are zero-extensions
                if let Some(k) = self.f.is_const(i.args[1]) {
                    if (k == 0xFF || k == 0xFFFF) && ty != T::I8 {
                        let d = self.vr(v);
                        let r = self.reg(i.args[0]);
                        let mut mi = MInst::new(MOp::Movzx, if k == 0xFF { 1 } else { 2 }, Opnd::R(d), Opnd::R(r));
                        mi.sz2 = 4;
                        self.out.push(mi);
                        return;
                    }
                    if k == 0xFFFF_FFFF && ty == T::I64 {
                        let d = self.vr(v);
                        let r = self.reg(i.args[0]);
                        self.e(MOp::Mov, 4, Opnd::R(d), Opnd::R(r));
                        return;
                    }
                }
                self.binop(v, MOp::And, true)
            }
            Op::Or => self.binop(v, MOp::Or, true),
            Op::Xor => {
                if self.f.is_const(i.args[1]) == Some(-1) {
                    let d = self.vr(v);
                    let r = self.reg(i.args[0]);
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(r));
                    self.e(MOp::Not, osz(ty), Opnd::R(d), Opnd::None);
                } else {
                    self.binop(v, MOp::Xor, true)
                }
            }
            Op::Shl | Op::LShr | Op::AShr | Op::Rotl | Op::Rotr => {
                let mop = match i.op {
                    Op::Shl => MOp::Shl,
                    Op::LShr => MOp::Shr,
                    Op::AShr => MOp::Sar,
                    Op::Rotl => MOp::Rol,
                    _ => MOp::Ror,
                };
                let sz = sz_of(ty);
                let d = self.vr(v);
                let bits = ty.bits() as i64;
                if let Some(k) = self.f.is_const(i.args[1]) {
                    let r = self.reg(i.args[0]);
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(r));
                    let k = k & (bits - 1);
                    if k != 0 {
                        self.e(mop, sz, Opnd::R(d), Opnd::I(k));
                    }
                } else {
                    let cnt = self.reg(i.args[1]);
                    let r = self.reg(i.args[0]);
                    self.e(MOp::Mov, 8, Opnd::R(RCX), Opnd::R(cnt));
                    if sz < 4 {
                        self.e(MOp::And, 4, Opnd::R(RCX), Opnd::I(bits - 1));
                    }
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(r));
                    self.e(mop, sz, Opnd::R(d), Opnd::R(RCX));
                }
            }
            Op::SDiv | Op::UDiv | Op::SRem | Op::URem => {
                let signed = matches!(i.op, Op::SDiv | Op::SRem);
                let sz = osz(ty);
                let d = self.vr(v);
                let a = self.ext32(i.args[0], signed);
                let b = self.ext32(i.args[1], signed);
                self.e(MOp::Mov, 8, Opnd::R(RAX), Opnd::R(a));
                if signed {
                    self.e(MOp::Cqo, sz, Opnd::None, Opnd::None);
                    self.e(MOp::Idiv, sz, Opnd::R(b), Opnd::None);
                } else {
                    self.e(MOp::Zero, 4, Opnd::R(RDX), Opnd::None);
                    self.e(MOp::Div, sz, Opnd::R(b), Opnd::None);
                }
                let res = if matches!(i.op, Op::SDiv | Op::UDiv) { RAX } else { RDX };
                self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(res));
            }
            Op::MulHiS | Op::MulHiU => {
                let d = self.vr(v);
                let a = self.reg(i.args[0]);
                let b = self.reg(i.args[1]);
                self.e(MOp::Mov, 8, Opnd::R(RAX), Opnd::R(a));
                self.e(if i.op == Op::MulHiS { MOp::Imul1 } else { MOp::Mul1 }, osz(ty), Opnd::R(b), Opnd::None);
                self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(RDX));
            }
            Op::FAdd => self.fbinop(v, MOp::Addsd, true),
            Op::FMul => self.fbinop(v, MOp::Mulsd, true),
            Op::FSub => self.fbinop(v, MOp::Subsd, false),
            Op::FDiv => self.fbinop(v, MOp::Divsd, false),
            Op::FMin => self.fbinop(v, MOp::Minsd, false),
            Op::FMax => self.fbinop(v, MOp::Maxsd, false),
            Op::FSqrt => {
                let d = self.vr(v);
                let s = self.xm(i.args[0]);
                self.e(MOp::Zero, 8, Opnd::R(d), Opnd::None);
                self.e(MOp::Sqrtsd, fsz(ty), Opnd::R(d), s);
            }
            Op::FNeg | Op::FAbs => {
                let d = self.vr(v);
                let s = self.reg(i.args[0]);
                let neg = i.op == Op::FNeg;
                let mask: u128 = if ty == T::F64 {
                    if neg {
                        0x8000_0000_0000_0000
                    } else {
                        0x7FFF_FFFF_FFFF_FFFF
                    }
                } else {
                    let lane: u128 = if neg { 0x8000_0000 } else { 0x7FFF_FFFF };
                    lane | lane << 32 | lane << 64 | lane << 96
                };
                let m = self.fconst(mask);
                self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(s));
                self.e(if neg { MOp::Xorpd } else { MOp::Andpd }, if ty == T::F64 { 8 } else { 16 }, Opnd::R(d), Opnd::M(m));
            }
            op if op.is_cmp() => {
                let d = self.vr(v);
                let (cc, extra) = self.cmp_flags(v);
                let mut s = MInst::new(MOp::Setcc, 1, Opnd::R(d), Opnd::None);
                s.cc = cc;
                self.out.push(s);
                if extra != 0 {
                    let t = self.mf.new_vreg(0);
                    let mut s2 = MInst::new(MOp::Setcc, 1, Opnd::R(t), Opnd::None);
                    s2.cc = if extra == 1 { cc::NP } else { cc::P };
                    self.out.push(s2);
                    self.e(if extra == 1 { MOp::And } else { MOp::Or }, 4, Opnd::R(d), Opnd::R(t));
                }
            }
            Op::SExt => {
                let d = self.vr(v);
                let st = self.f.insts[i.args[0] as usize].ty;
                let s = match self.load_mem(i.args[0]) {
                    Some(m) => Opnd::M(m),
                    None => Opnd::R(self.reg(i.args[0])),
                };
                let mut mi = MInst::new(MOp::Movsx, sz_of(st), Opnd::R(d), s);
                mi.sz2 = if ty == T::I64 { 8 } else { 4 };
                self.out.push(mi);
            }
            Op::ZExt => {
                let d = self.vr(v);
                let src = i.args[0];
                let st = self.f.insts[src as usize].ty;
                if let Some(m) = self.load_mem(src) {
                    if st == T::I32 {
                        self.e(MOp::Mov, 4, Opnd::R(d), Opnd::M(m));
                    } else {
                        let mut mi = MInst::new(MOp::Movzx, sz_of(st), Opnd::R(d), Opnd::M(m));
                        mi.sz2 = 4;
                        self.out.push(mi);
                    }
                    return;
                }
                let s = self.reg(src);
                if st == T::I32 {
                    if self.zext_free(src) {
                        self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(s));
                    } else {
                        self.e(MOp::Mov, 4, Opnd::R(d), Opnd::R(s));
                    }
                } else if self.f.insts[src as usize].op == Op::Load {
                    // byte loads are already zero-extended
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(s));
                } else {
                    let mut mi = MInst::new(MOp::Movzx, sz_of(st), Opnd::R(d), Opnd::R(s));
                    mi.sz2 = 4;
                    self.out.push(mi);
                }
            }
            Op::Trunc => {
                let d = self.vr(v);
                let s = self.reg(i.args[0]);
                self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(s));
            }
            Op::SIToF => {
                let d = self.vr(v);
                let st = self.f.insts[i.args[0] as usize].ty;
                let s = if st == T::I32 || st == T::I64 {
                    match self.load_mem(i.args[0]) {
                        Some(m) => Opnd::M(m),
                        None => Opnd::R(self.reg(i.args[0])),
                    }
                } else {
                    Opnd::R(self.ext32(i.args[0], true))
                };
                self.e(MOp::Zero, 8, Opnd::R(d), Opnd::None);
                let mut mi = MInst::new(MOp::Cvtsi2sd, if st == T::I64 { 8 } else { 4 }, Opnd::R(d), s);
                mi.sz2 = fsz(ty);
                self.out.push(mi);
            }
            Op::FToSI => {
                let d = self.vr(v);
                let s = self.xm(i.args[0]);
                let mut mi = MInst::new(MOp::Cvttsd2si, if ty == T::I64 { 8 } else { 4 }, Opnd::R(d), s);
                mi.sz2 = fsz(self.f.insts[i.args[0] as usize].ty);
                self.out.push(mi);
            }
            Op::BitsToF => {
                let d = self.vr(v);
                let s = self.reg(i.args[0]);
                self.e(MOp::MovqToX, fsz(ty), Opnd::R(d), Opnd::R(s));
            }
            Op::FToBits => {
                let d = self.vr(v);
                let s = self.reg(i.args[0]);
                self.e(MOp::MovqToR, fsz(self.f.insts[i.args[0] as usize].ty), Opnd::R(d), Opnd::R(s));
            }
            Op::Select => {
                let d = self.vr(v);
                let c = i.args[0];
                let a = self.reg(i.args[1]);
                let b = self.mov_src(i.args[2]);
                self.e(MOp::Mov, 8, Opnd::R(d), b);
                let ci = &self.f.insts[c as usize];
                let cc = if ci.op.is_icmp() {
                    self.cmp_flags(c).0
                } else {
                    let r = self.reg(c);
                    self.e(MOp::Test, 1, Opnd::R(r), Opnd::R(r));
                    cc::NE
                };
                let mut mi = MInst::new(MOp::Cmov, if ty == T::I64 { 8 } else { 4 }, Opnd::R(d), Opnd::R(a));
                mi.cc = cc;
                self.out.push(mi);
            }
            Op::Load => {
                let d = self.vr(v);
                let m = self.addr(i.args[0]);
                match ty {
                    T::F64 | T::F32 | T::V2 | T::V4 => self.e(MOp::MovSd, fsz_mem(ty), Opnd::R(d), Opnd::M(m)),
                    T::V3 => {
                        // x, y as one 8-byte load; z joins as the upper half
                        let t = self.mf.new_vreg(1);
                        let mut hi = m;
                        hi.disp += 8;
                        self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::M(m));
                        self.e(MOp::MovSd, 4, Opnd::R(t), Opnd::M(hi));
                        self.shufps(d, t, 0x44);
                    }
                    T::I8 | T::I16 => {
                        let mut mi = MInst::new(MOp::Movzx, sz_of(ty), Opnd::R(d), Opnd::M(m));
                        mi.sz2 = 4;
                        self.out.push(mi);
                    }
                    _ => self.e(MOp::Mov, sz_of(ty), Opnd::R(d), Opnd::M(m)),
                }
            }
            Op::Store => {
                let val = i.args[1];
                let vi = &self.f.insts[val as usize];
                if ty.is_fp() {
                    if vi.op == Op::FConst && (vi.k == 0 || ty == T::F32) {
                        let m = self.addr(i.args[0]);
                        if ty == T::V3 || ty == T::V4 {
                            let mut hi = m;
                            hi.disp += 8;
                            self.e(MOp::Mov, 8, Opnd::M(m), Opnd::I(0));
                            self.e(MOp::Mov, if ty == T::V3 { 4 } else { 8 }, Opnd::M(hi), Opnd::I(0));
                        } else {
                            self.e(MOp::Mov, if ty == T::F32 { 4 } else { 8 }, Opnd::M(m), Opnd::I(vi.k as i32 as i64));
                        }
                    } else if ty == T::V3 {
                        let r = self.reg(val);
                        let m = self.addr(i.args[0]);
                        let t = self.mf.new_vreg(1);
                        let mut hi = m;
                        hi.disp += 8;
                        self.e(MOp::MovSd, 8, Opnd::M(m), Opnd::R(r));
                        self.e(MOp::MovSd, 8, Opnd::R(t), Opnd::R(r));
                        self.shufps(t, t, 2);
                        self.e(MOp::MovSd, 4, Opnd::M(hi), Opnd::R(t));
                    } else {
                        let r = self.reg(val);
                        let m = self.addr(i.args[0]);
                        self.e(MOp::MovSd, fsz_mem(ty), Opnd::M(m), Opnd::R(r));
                    }
                } else {
                    let src = match vi.op {
                        Op::Const if fits32(vi.k) => Opnd::I(vi.k),
                        _ => Opnd::R(self.reg(val)),
                    };
                    let m = self.addr(i.args[0]);
                    self.e(MOp::Mov, sz_of(ty), Opnd::M(m), src);
                }
            }
            Op::Call | Op::CallInd => self.call(v, &i),
            Op::Syscall => {
                const SR: [Reg; 7] = [RAX, RDI, RSI, RDX, R10, R8, R9];
                let srcs: Vec<Opnd> = i.args.iter().map(|&a| self.mov_src(a)).collect();
                let mut used = Vec::new();
                for (k, s) in srcs.into_iter().enumerate() {
                    self.e(MOp::Mov, 8, Opnd::R(SR[k]), s);
                    used.push(SR[k]);
                }
                let mut mi = MInst::new(MOp::Syscall, 0, Opnd::None, Opnd::None);
                mi.uses = used;
                self.out.push(mi);
                if self.needed[v as usize] {
                    let d = self.vr(v);
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(RAX));
                }
            }
            Op::MemCpy | Op::MemSet => {
                let d = self.mov_src(i.args[0]);
                let s = self.mov_src(i.args[1]);
                let n = self.mov_src(i.args[2]);
                self.e(MOp::Mov, 8, Opnd::R(RDI), d);
                self.e(MOp::Mov, 8, Opnd::R(if i.op == Op::MemCpy { RSI } else { RAX }), s);
                self.e(MOp::Mov, 8, Opnd::R(RCX), n);
                self.e(if i.op == Op::MemCpy { MOp::RepMovsb } else { MOp::RepStosb }, 0, Opnd::None, Opnd::None);
            }
            Op::FExt | Op::FTrunc => {
                let d = self.vr(v);
                let s = self.xm(i.args[0]);
                self.e(MOp::Zero, 8, Opnd::R(d), Opnd::None);
                self.e(MOp::Cvtf, fsz(ty), Opnd::R(d), s);
            }
            Op::VSplat => {
                let d = self.vr(v);
                let s = self.reg(i.args[0]);
                self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(s));
                self.shufps(d, d, 0);
            }
            Op::VBuild => {
                let d = self.vr(v);
                let consts: Vec<Option<u32>> = i.args.iter().map(|a| if self.f.insts[*a as usize].op == Op::FConst { Some(self.f.insts[*a as usize].k as u32) } else { None }).collect();
                if consts.iter().all(|c| c.is_some()) {
                    let mut bits = 0u128;
                    for (k, c) in consts.iter().enumerate() {
                        bits |= (c.unwrap() as u128) << (32 * k);
                    }
                    if bits == 0 {
                        self.e(MOp::Zero, 8, Opnd::R(d), Opnd::None);
                    } else {
                        let m = self.fconst(bits);
                        self.e(MOp::MovSd, 16, Opnd::R(d), Opnd::M(m));
                    }
                    return;
                }
                let rs: Vec<Reg> = i.args.iter().map(|a| self.reg(*a)).collect();
                self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(rs[0]));
                self.e(MOp::Unpcklps, 16, Opnd::R(d), Opnd::R(rs[1]));
                if rs.len() == 3 {
                    self.shufps(d, rs[2], 0x44);
                } else if rs.len() == 4 {
                    let t = self.mf.new_vreg(1);
                    self.e(MOp::MovSd, 8, Opnd::R(t), Opnd::R(rs[2]));
                    self.e(MOp::Unpcklps, 16, Opnd::R(t), Opnd::R(rs[3]));
                    self.shufps(d, t, 0x44);
                }
            }
            Op::VExt => {
                let d = self.vr(v);
                let s = self.reg(i.args[0]);
                self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(s));
                if i.k != 0 {
                    self.shufps(d, d, i.k);
                }
            }
            Op::VIns => {
                let d = self.vr(v);
                let x = self.reg(i.args[0]);
                let s = self.reg(i.args[1]);
                match i.k {
                    0 => {
                        self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(x));
                        self.e(MOp::Movlo, 4, Opnd::R(d), Opnd::R(s));
                    }
                    1 => {
                        // [x0, s, x1, s1] then lanes 2, 3 from x
                        self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(x));
                        self.e(MOp::Unpcklps, 16, Opnd::R(d), Opnd::R(s));
                        self.shufps(d, x, 0xE4);
                    }
                    k => {
                        // t = [s, s, x3, x3] (lane 2) or [s, s, x2, x2] (lane 3)
                        let t = self.mf.new_vreg(1);
                        self.e(MOp::MovSd, 8, Opnd::R(t), Opnd::R(s));
                        self.shufps(t, x, if k == 2 { 0xF0 } else { 0xA0 });
                        self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(x));
                        self.shufps(d, t, if k == 2 { 0x84 } else { 0x24 });
                    }
                }
            }
            Op::VShuf => {
                let d = self.vr(v);
                let a = self.reg(i.args[0]);
                self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(a));
                if i.args[0] == i.args[1] {
                    self.shufps(d, d, i.k);
                } else {
                    let b = self.reg(i.args[1]);
                    self.shufps(d, b, i.k);
                }
            }
            Op::Bswap | Op::Popcnt | Op::Ctz | Op::Clz => {
                let d = self.vr(v);
                let sz = osz(ty);
                if i.op == Op::Bswap {
                    let s = self.reg(i.args[0]);
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(s));
                    self.e(MOp::Bswap, sz, Opnd::R(d), Opnd::None);
                    if ty == T::I16 {
                        self.e(MOp::Shr, 4, Opnd::R(d), Opnd::I(16));
                    } else if ty == T::I8 {
                        self.e(MOp::Shr, 4, Opnd::R(d), Opnd::I(24));
                    }
                } else {
                    let s = self.ext32(i.args[0], false);
                    let mop = match i.op {
                        Op::Popcnt => MOp::Popcnt,
                        Op::Ctz => MOp::Tzcnt,
                        _ => MOp::Lzcnt,
                    };
                    self.e(mop, sz, Opnd::R(d), Opnd::R(s));
                    if i.op == Op::Clz && (ty == T::I8 || ty == T::I16) {
                        self.e(MOp::Sub, 4, Opnd::R(d), Opnd::I(32 - ty.bits() as i64));
                    }
                    if i.op == Op::Ctz && (ty == T::I8 || ty == T::I16) {
                        // tzcnt of a zero-extended zero gives 32: clamp to the type width
                        let t = self.mf.new_vreg(0);
                        self.e(MOp::Mov, 8, Opnd::R(t), Opnd::I(ty.bits() as i64));
                        self.e(MOp::Cmp, 4, Opnd::R(d), Opnd::R(t));
                        let mut mi = MInst::new(MOp::Cmov, 4, Opnd::R(d), Opnd::R(t));
                        mi.cc = cc::A;
                        self.out.push(mi);
                    }
                }
            }
            _ => panic!("isel: unhandled op {:?}", i.op),
        }
    }

    // a value with a single use that is defined in the block being selected ends its life at
    // that use, so a two-address instruction can reuse its register
    fn dies_here(&self, v: V) -> bool {
        self.uses[v as usize] == 1 && self.blk_of[v as usize] == self.cur_block && self.f.insts[v as usize].op != Op::Phi
    }

    fn uses_of_reg_single(&self, i: &Inst, base: Reg) -> bool {
        // x + const where x dies here: two-address add coalesces
        for &a in &i.args {
            if self.vreg[a as usize] == base {
                return self.dies_here(a);
            }
        }
        false
    }

    fn call(&mut self, v: V, i: &Inst) {
        self.mf.has_calls = true;
        let (target, args): (Option<V>, &[V]) = if i.op == Op::CallInd { (Some(i.args[0]), &i.args[1..]) } else { (None, &i.args[..]) };
        // evaluate sources
        let mut ni = 0usize;
        let mut nf = 0usize;
        let mut nstack = 0u32;
        let mut reg_moves: Vec<(Reg, Opnd, bool)> = Vec::new();
        let mut stack_moves: Vec<(u32, Opnd, u8)> = Vec::new();
        for &a in args {
            let at = self.f.insts[a as usize].ty;
            if at.is_fp() {
                let r = Opnd::R(self.reg(a));
                if nf < NUM_FLOAT_ARGS {
                    reg_moves.push((XMM0 + nf as Reg, r, true));
                    nf += 1;
                } else {
                    stack_moves.push((nstack, r, fsz(at)));
                    nstack += if at.is_vec() { 2 } else { 1 };
                }
            } else if ni < INT_ARGS.len() {
                let s = self.mov_src(a);
                reg_moves.push((INT_ARGS[ni], s, false));
                ni += 1;
            } else {
                let s = match self.mov_src(a) {
                    Opnd::I(k) if fits32(k) => Opnd::I(k),
                    Opnd::R(r) => Opnd::R(r),
                    _ => Opnd::R(self.reg(a)),
                };
                stack_moves.push((nstack, s, 0));
                nstack += 1;
            }
        }
        let tr = target.map(|t| self.reg(t));
        self.mf.out_args = self.mf.out_args.max(nstack);
        for (slot, s, fs) in stack_moves {
            let m = Mem { base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKind::OutArg, id: slot };
            if fs != 0 {
                self.e(MOp::MovSd, fs, Opnd::M(m), s);
            } else {
                self.e(MOp::Mov, 8, Opnd::M(m), s);
            }
        }
        let mut used = Vec::new();
        for (d, s, isf) in reg_moves {
            self.e(if isf { MOp::MovSd } else { MOp::Mov }, 8, Opnd::R(d), s);
            used.push(d);
        }
        let mut c = match tr {
            Some(r) => MInst::new(MOp::CallInd, 8, Opnd::R(r), Opnd::None),
            None => {
                let mut c = MInst::new(MOp::Call, 0, Opnd::None, Opnd::None);
                c.tgt = i.k as u32;
                c
            }
        };
        c.uses = used;
        self.out.push(c);
        // results
        let nrets = if i.op == Op::Call { self.m.funcs[i.k as usize].rets.len() } else { usize::MAX };
        if i.ty != T::Void {
            if self.needed[v as usize] {
                let d = self.vr(v);
                if i.ty.is_fp() {
                    self.e(MOp::MovSd, 8, Opnd::R(d), Opnd::R(XMM0));
                } else {
                    self.e(MOp::Mov, 8, Opnd::R(d), Opnd::R(RAX));
                }
            }
        } else if let Some(ps) = self.projs.get(&v).cloned() {
            // multi-value results: assign registers in order of result index
            let mut by_idx: Vec<(i64, V)> = ps;
            by_idx.sort();
            let maxi = by_idx.iter().map(|p| p.0).max().unwrap_or(-1);
            let _ = nrets;
            // result types: from callee signature when known, else from projections
            let mut types: Vec<T> = Vec::new();
            if i.op == Op::Call {
                types = self.m.funcs[i.k as usize].rets.clone();
            } else {
                for k in 0..=maxi {
                    let t = by_idx.iter().find(|p| p.0 == k).map(|p| self.f.insts[p.1 as usize].ty).unwrap_or(T::I64);
                    types.push(t);
                }
            }
            let mut ni = 0;
            let mut nf = 0;
            let mut locs: Vec<Reg> = Vec::new();
            for t in &types {
                if t.is_fp() {
                    locs.push(XMM0 + nf as Reg);
                    nf += 1;
                } else {
                    locs.push(INT_RETS[ni]);
                    ni += 1;
                }
            }
            for (k, p) in by_idx {
                if !self.needed[p as usize] {
                    continue;
                }
                let d = self.vr(p);
                let isf = self.f.insts[p as usize].ty.is_fp();
                self.e(if isf { MOp::MovSd } else { MOp::Mov }, 8, Opnd::R(d), Opnd::R(locs[k as usize]));
            }
        }
    }
}

