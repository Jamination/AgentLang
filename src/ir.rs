// SSA intermediate representation.
use std::fmt::Write;

pub type V = u32;
pub type B = u32;
pub const NOV: V = u32::MAX;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum T {
    Void,
    I8,
    I16,
    I32,
    I64,
    F64,
    F32,
    // 128-bit vectors of f32 lanes held in an xmm register; they differ in memory size only
    V2,
    V3,
    V4,
}

impl T {
    pub fn size(self) -> u32 {
        match self {
            T::Void => 0,
            T::I8 => 1,
            T::I16 => 2,
            T::I32 | T::F32 => 4,
            T::I64 | T::F64 | T::V2 => 8,
            T::V3 => 12,
            T::V4 => 16,
        }
    }
    pub fn bits(self) -> u32 {
        self.size() * 8
    }
    pub fn is_int(self) -> bool {
        matches!(self, T::I8 | T::I16 | T::I32 | T::I64)
    }
    // lives in an xmm register
    pub fn is_fp(self) -> bool {
        matches!(self, T::F32 | T::F64 | T::V2 | T::V3 | T::V4)
    }
    pub fn is_vec(self) -> bool {
        matches!(self, T::V2 | T::V3 | T::V4)
    }
    pub fn name(self) -> &'static str {
        match self {
            T::Void => "void",
            T::I8 => "i8",
            T::I16 => "i16",
            T::I32 => "i32",
            T::I64 => "i64",
            T::F64 => "f64",
            T::F32 => "f32",
            T::V2 => "v2",
            T::V3 => "v3",
            T::V4 => "v4",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Op {
    Const,  // k = value (sign-extended to i64, canonical for type)
    FConst, // k = f64 bits (f32 bits for F32; vectors: only 0)
    Param,  // k = index
    GAddr,  // k = global id
    FAddr,  // k = function id
    Alloca, // k = size, aux = align
    Add,
    Sub,
    Mul,
    SDiv,
    UDiv,
    SRem,
    URem,
    And,
    Or,
    Xor,
    Shl,
    LShr,
    AShr,
    Rotl,
    Rotr,
    MulHiS,
    MulHiU,
    FAdd,
    FSub,
    FMul,
    FDiv,
    FSqrt,
    FNeg,
    FAbs,
    FMin,   // x86 semantics: a < b ? a : b
    FMax,   // a > b ? a : b
    FExt,   // f32 -> f64
    FTrunc, // f64 -> f32
    VSplat, // f32 -> vector with every lane equal
    VBuild, // f32 lanes -> vector
    VExt,   // vector -> f32, k = lane
    VIns,   // args = [vector, f32], k = lane
    VShuf,  // args = [a, b], k = shufps immediate: lanes 0,1 from a and 2,3 from b
    Eq,
    Ne,
    Slt,
    Sle,
    Sgt,
    Sge,
    Ult,
    Ule,
    Ugt,
    Uge,
    FEq,
    FNe,
    FLt,
    FLe,
    FGt,
    FGe,
    SExt,
    ZExt,
    Trunc,
    SIToF,
    FToSI,
    BitsToF,
    FToBits,
    Select, // args = [cond, a, b]
    Load,   // args = [addr], aux = alias class
    Store,  // args = [addr, val], ty = type of val, aux = alias class
    Call,   // k = func id
    CallInd, // args[0] = fn pointer
    Syscall,
    Proj, // args[0] = call, k = result index
    Phi,
    MemCpy, // args = [dst, src, n]
    MemSet, // args = [dst, byte, n]
    Bswap,
    Popcnt,
    Ctz,
    Clz,
}

impl Op {
    pub fn is_cmp(self) -> bool {
        use Op::*;
        matches!(self, Eq | Ne | Slt | Sle | Sgt | Sge | Ult | Ule | Ugt | Uge | FEq | FNe | FLt | FLe | FGt | FGe)
    }
    pub fn is_icmp(self) -> bool {
        use Op::*;
        matches!(self, Eq | Ne | Slt | Sle | Sgt | Sge | Ult | Ule | Ugt | Uge)
    }
    pub fn is_commutative(self) -> bool {
        use Op::*;
        matches!(self, Add | Mul | And | Or | Xor | FAdd | FMul | Eq | Ne | FEq | FNe | MulHiS | MulHiU)
    }
    // no side effects, no memory dependence, cannot trap
    pub fn is_pure(self) -> bool {
        use Op::*;
        !matches!(
            self,
            Param | Alloca | SDiv | UDiv | SRem | URem | Load | Store | Call | CallInd | Syscall | Proj | Phi | MemCpy | MemSet
        )
    }
    pub fn swap_cmp(self) -> Op {
        use Op::*;
        match self {
            Slt => Sgt,
            Sle => Sge,
            Sgt => Slt,
            Sge => Sle,
            Ult => Ugt,
            Ule => Uge,
            Ugt => Ult,
            Uge => Ule,
            FLt => FGt,
            FLe => FGe,
            FGt => FLt,
            FGe => FLe,
            o => o,
        }
    }
    // integer compare negation (not valid for float compares because of NaN)
    pub fn negate_icmp(self) -> Op {
        use Op::*;
        match self {
            Eq => Ne,
            Ne => Eq,
            Slt => Sge,
            Sle => Sgt,
            Sgt => Sle,
            Sge => Slt,
            Ult => Uge,
            Ule => Ugt,
            Ugt => Ule,
            Uge => Ult,
            o => o,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Inst {
    pub op: Op,
    pub ty: T,
    pub args: Vec<V>,
    pub k: i64,
    pub aux: u32,
    pub pb: Vec<B>, // phi predecessor blocks, parallel to args
}

#[derive(Clone, Debug, PartialEq)]
pub enum Term {
    None,
    Jmp(B),
    Br(V, B, B),
    Ret(Vec<V>),
    Trap,
}

#[derive(Clone, Debug)]
pub struct BlockData {
    pub insts: Vec<V>,
    pub term: Term,
}

#[derive(Clone, Debug)]
pub struct Func {
    pub name: String,
    pub params: Vec<T>,
    pub rets: Vec<T>,
    pub insts: Vec<Inst>,
    pub blocks: Vec<BlockData>,
    pub inline: i8,
    pub noreturn: bool,
    pub lowered: bool,
    // a C function in a shared library: index into Module::externs
    pub ext: Option<u32>,
}

#[derive(Clone, Debug)]
pub enum RelocTarget {
    Global(u32, i64),
    Func(u32),
}

#[derive(Clone, Debug)]
pub struct Global {
    pub name: String,
    pub size: u64,
    pub align: u32,
    pub data: Option<Vec<u8>>,
    pub relocs: Vec<(u32, RelocTarget)>,
    pub readonly: bool,
}

pub struct Module {
    pub funcs: Vec<Func>,
    pub globals: Vec<Global>,
    pub entry: u32,
    pub externs: Vec<ExternFn>,
}

// An imported C function: calls load its address from the 8-byte global `got`, which the
// dynamic loader fills in.
#[derive(Clone, Debug)]
pub struct ExternFn {
    pub name: String,
    pub lib: String,
    pub got: u32,
}

pub fn canon(ty: T, k: i64) -> i64 {
    match ty {
        T::I8 => k as i8 as i64,
        T::I16 => k as i16 as i64,
        T::I32 => k as i32 as i64,
        _ => k,
    }
}

impl Func {
    pub fn new(name: &str) -> Func {
        Func {
            name: name.to_string(),
            params: Vec::new(),
            rets: Vec::new(),
            insts: Vec::new(),
            blocks: Vec::new(),
            inline: 0,
            noreturn: false,
            lowered: false,
            ext: None,
        }
    }
    pub fn new_block(&mut self) -> B {
        self.blocks.push(BlockData { insts: Vec::new(), term: Term::None });
        (self.blocks.len() - 1) as B
    }
    pub fn mk(&mut self, op: Op, ty: T, args: Vec<V>, k: i64) -> V {
        self.insts.push(Inst { op, ty, args, k, aux: 0, pb: Vec::new() });
        (self.insts.len() - 1) as V
    }
    pub fn push(&mut self, b: B, op: Op, ty: T, args: Vec<V>, k: i64) -> V {
        let v = self.mk(op, ty, args, k);
        self.blocks[b as usize].insts.push(v);
        v
    }
    pub fn im(&mut self, v: V) -> &mut Inst {
        &mut self.insts[v as usize]
    }
    pub fn is_const(&self, v: V) -> Option<i64> {
        let i = &self.insts[v as usize];
        if i.op == Op::Const {
            Some(i.k)
        } else {
            None
        }
    }
    pub fn succs(&self, b: B) -> Vec<B> {
        match &self.blocks[b as usize].term {
            Term::Jmp(t) => vec![*t],
            Term::Br(_, t, f) => {
                if t == f {
                    vec![*t]
                } else {
                    vec![*t, *f]
                }
            }
            _ => vec![],
        }
    }
    pub fn preds(&self) -> Vec<Vec<B>> {
        let mut p = vec![Vec::new(); self.blocks.len()];
        for b in 0..self.blocks.len() {
            for s in self.succs(b as B) {
                p[s as usize].push(b as B);
            }
        }
        p
    }
    // reverse postorder of reachable blocks
    pub fn rpo(&self) -> Vec<B> {
        let n = self.blocks.len();
        let mut seen = vec![false; n];
        let mut post = Vec::with_capacity(n);
        let mut stack: Vec<(B, usize)> = vec![(0, 0)];
        seen[0] = true;
        while let Some(&mut (b, ref mut i)) = stack.last_mut() {
            let ss = self.succs(b);
            if *i < ss.len() {
                let s = ss[*i];
                *i += 1;
                if !seen[s as usize] {
                    seen[s as usize] = true;
                    stack.push((s, 0));
                }
            } else {
                post.push(b);
                stack.pop();
            }
        }
        post.reverse();
        post
    }
    pub fn term_uses(&self, b: B) -> Vec<V> {
        match &self.blocks[b as usize].term {
            Term::Br(c, _, _) => vec![*c],
            Term::Ret(v) => v.clone(),
            _ => vec![],
        }
    }
    pub fn use_counts(&self) -> Vec<u32> {
        let mut c = vec![0u32; self.insts.len()];
        for b in &self.blocks {
            for &v in &b.insts {
                for &a in &self.insts[v as usize].args {
                    c[a as usize] += 1;
                }
            }
            match &b.term {
                Term::Br(v, _, _) => c[*v as usize] += 1,
                Term::Ret(vs) => {
                    for v in vs {
                        c[*v as usize] += 1;
                    }
                }
                _ => {}
            }
        }
        c
    }
    // apply a replacement map (map[v] = replacement or NOV) to all uses
    pub fn apply_repl(&mut self, map: &mut Vec<V>) {
        fn find(map: &mut Vec<V>, v: V) -> V {
            let mut r = v;
            while map[r as usize] != NOV {
                r = map[r as usize];
            }
            let mut c = v;
            while map[c as usize] != NOV {
                let n = map[c as usize];
                map[c as usize] = r;
                c = n;
            }
            r
        }
        if map.len() < self.insts.len() {
            map.resize(self.insts.len(), NOV);
        }
        for bi in 0..self.blocks.len() {
            for ii in 0..self.blocks[bi].insts.len() {
                let v = self.blocks[bi].insts[ii];
                for ai in 0..self.insts[v as usize].args.len() {
                    let a = self.insts[v as usize].args[ai];
                    if map[a as usize] != NOV {
                        self.insts[v as usize].args[ai] = find(map, a);
                    }
                }
            }
            match &mut self.blocks[bi].term {
                Term::Br(c, _, _) => {
                    if map[*c as usize] != NOV {
                        *c = find(map, *c);
                    }
                }
                Term::Ret(vs) => {
                    for v in vs.iter_mut() {
                        if map[*v as usize] != NOV {
                            *v = find(map, *v);
                        }
                    }
                }
                _ => {}
            }
        }
    }
    pub fn block_of(&self) -> Vec<B> {
        let mut bo = vec![u32::MAX; self.insts.len()];
        for (bi, b) in self.blocks.iter().enumerate() {
            for &v in &b.insts {
                bo[v as usize] = bi as B;
            }
        }
        bo
    }
    pub fn size(&self) -> usize {
        self.blocks.iter().map(|b| b.insts.len() + 1).sum()
    }
}

// ---------- CFG analysis ----------
pub struct Cfg {
    pub rpo: Vec<B>,
    pub rpo_idx: Vec<u32>,
    pub preds: Vec<Vec<B>>,
    #[allow(dead_code)]
    pub idom: Vec<B>,
    pub children: Vec<Vec<B>>,
    pre: Vec<u32>,
    post: Vec<u32>,
}

impl Cfg {
    pub fn new(f: &Func) -> Cfg {
        let n = f.blocks.len();
        let rpo = f.rpo();
        let mut rpo_idx = vec![u32::MAX; n];
        for (i, &b) in rpo.iter().enumerate() {
            rpo_idx[b as usize] = i as u32;
        }
        let mut preds = vec![Vec::new(); n];
        for &b in &rpo {
            for s in f.succs(b) {
                preds[s as usize].push(b);
            }
        }
        let mut idom = vec![u32::MAX; n];
        idom[0] = 0;
        let mut changed = true;
        while changed {
            changed = false;
            for &b in rpo.iter().skip(1) {
                let mut new = u32::MAX;
                for &p in &preds[b as usize] {
                    if idom[p as usize] == u32::MAX {
                        continue;
                    }
                    if new == u32::MAX {
                        new = p;
                    } else {
                        let (mut x, mut y) = (p, new);
                        while x != y {
                            while rpo_idx[x as usize] > rpo_idx[y as usize] {
                                x = idom[x as usize];
                            }
                            while rpo_idx[y as usize] > rpo_idx[x as usize] {
                                y = idom[y as usize];
                            }
                        }
                        new = x;
                    }
                }
                if idom[b as usize] != new {
                    idom[b as usize] = new;
                    changed = true;
                }
            }
        }
        let mut children = vec![Vec::new(); n];
        for &b in rpo.iter().skip(1) {
            children[idom[b as usize] as usize].push(b);
        }
        let mut pre = vec![0u32; n];
        let mut post = vec![0u32; n];
        let mut t = 0u32;
        let mut stack: Vec<(B, usize)> = vec![(0, 0)];
        pre[0] = 0;
        while let Some(&mut (b, ref mut i)) = stack.last_mut() {
            if *i < children[b as usize].len() {
                let c = children[b as usize][*i];
                *i += 1;
                t += 1;
                pre[c as usize] = t;
                stack.push((c, 0));
            } else {
                t += 1;
                post[b as usize] = t;
                stack.pop();
            }
        }
        Cfg { rpo, rpo_idx, preds, idom, children, pre, post }
    }
    pub fn reachable(&self, b: B) -> bool {
        self.rpo_idx[b as usize] != u32::MAX
    }
    // a dominates b (reflexive)
    pub fn dom(&self, a: B, b: B) -> bool {
        self.pre[a as usize] <= self.pre[b as usize] && self.post[b as usize] <= self.post[a as usize]
    }
}

#[derive(Clone, Debug)]
pub struct Loop {
    pub header: B,
    pub blocks: Vec<B>,
    pub latches: Vec<B>,
    pub parent: Option<usize>,
    pub depth: u32,
}

pub struct Loops {
    pub loops: Vec<Loop>,
    pub loop_of: Vec<Option<usize>>, // innermost loop per block
}

impl Loops {
    pub fn new(f: &Func, cfg: &Cfg) -> Loops {
        let n = f.blocks.len();
        let mut loops: Vec<Loop> = Vec::new();
        let mut by_header: Vec<Option<usize>> = vec![None; n];
        for &b in &cfg.rpo {
            for s in f.succs(b) {
                if cfg.dom(s, b) {
                    let li = match by_header[s as usize] {
                        Some(li) => li,
                        None => {
                            loops.push(Loop { header: s, blocks: vec![s], latches: vec![], parent: None, depth: 0 });
                            by_header[s as usize] = Some(loops.len() - 1);
                            loops.len() - 1
                        }
                    };
                    loops[li].latches.push(b);
                }
            }
        }
        for l in loops.iter_mut() {
            let mut inl = vec![false; n];
            inl[l.header as usize] = true;
            let mut work: Vec<B> = Vec::new();
            for &lt in &l.latches {
                if !inl[lt as usize] {
                    inl[lt as usize] = true;
                    work.push(lt);
                    l.blocks.push(lt);
                }
            }
            while let Some(b) = work.pop() {
                for &p in &cfg.preds[b as usize] {
                    if !inl[p as usize] {
                        inl[p as usize] = true;
                        l.blocks.push(p);
                        work.push(p);
                    }
                }
            }
        }
        // nesting: process loops from largest to smallest
        let mut order: Vec<usize> = (0..loops.len()).collect();
        order.sort_by(|a, b| loops[*b].blocks.len().cmp(&loops[*a].blocks.len()));
        let mut loop_of: Vec<Option<usize>> = vec![None; n];
        for &li in &order {
            let parent = loop_of[loops[li].header as usize];
            loops[li].parent = parent;
            loops[li].depth = match parent {
                Some(p) => loops[p].depth + 1,
                None => 1,
            };
            for &b in &loops[li].blocks.clone() {
                loop_of[b as usize] = Some(li);
            }
        }
        Loops { loops, loop_of }
    }
    pub fn depth(&self, b: B) -> u32 {
        match self.loop_of[b as usize] {
            Some(l) => self.loops[l].depth,
            None => 0,
        }
    }
    pub fn contains(&self, li: usize, b: B) -> bool {
        let mut cur = self.loop_of[b as usize];
        while let Some(c) = cur {
            if c == li {
                return true;
            }
            cur = self.loops[c].parent;
        }
        false
    }
}

// ---------- printer ----------
pub fn print_func(f: &Func, m: Option<&Module>) -> String {
    let mut s = String::new();
    let ps: Vec<&str> = f.params.iter().map(|t| t.name()).collect();
    let rs: Vec<&str> = f.rets.iter().map(|t| t.name()).collect();
    let _ = writeln!(s, "fn {}({}) -> ({}) {{", f.name, ps.join(", "), rs.join(", "));
    let rpo = f.rpo();
    for &b in &rpo {
        let _ = writeln!(s, "b{}:", b);
        for &v in &f.blocks[b as usize].insts {
            let i = &f.insts[v as usize];
            let mut line = String::new();
            if i.ty != T::Void && i.op != Op::Store {
                let _ = write!(line, "  %{} = ", v);
            } else {
                let _ = write!(line, "  ");
            }
            let _ = write!(line, "{:?} {}", i.op, i.ty.name());
            match i.op {
                Op::Const => {
                    let _ = write!(line, " {}", i.k);
                }
                Op::FConst => {
                    if i.ty == T::F32 {
                        let _ = write!(line, " {:?}", f32::from_bits(i.k as u32));
                    } else {
                        let _ = write!(line, " {:?}", f64::from_bits(i.k as u64));
                    }
                }
                Op::Param | Op::Proj | Op::VExt | Op::VIns | Op::VShuf => {
                    let _ = write!(line, " #{}", i.k);
                }
                Op::GAddr => {
                    let name = m.map(|m| m.globals[i.k as usize].name.clone()).unwrap_or_default();
                    let _ = write!(line, " @g{}({})", i.k, name);
                }
                Op::Call | Op::FAddr => {
                    let name = m.map(|m| m.funcs[i.k as usize].name.clone()).unwrap_or_default();
                    let _ = write!(line, " @f{}({})", i.k, name);
                }
                Op::Alloca => {
                    let _ = write!(line, " size={} align={}", i.k, i.aux);
                }
                Op::Load | Op::Store => {
                    let _ = write!(line, " !{}.{}", i.aux & 15, i.aux >> 4);
                }
                _ => {}
            }
            for (ai, a) in i.args.iter().enumerate() {
                if i.op == Op::Phi {
                    let _ = write!(line, " [b{}: %{}]", i.pb[ai], a);
                } else {
                    let _ = write!(line, " %{}", a);
                }
            }
            let _ = writeln!(s, "{}", line);
        }
        match &f.blocks[b as usize].term {
            Term::None => {
                let _ = writeln!(s, "  <no terminator>");
            }
            Term::Jmp(t) => {
                let _ = writeln!(s, "  jmp b{}", t);
            }
            Term::Br(c, t, e) => {
                let _ = writeln!(s, "  br %{} b{} b{}", c, t, e);
            }
            Term::Ret(vs) => {
                let v: Vec<String> = vs.iter().map(|v| format!("%{}", v)).collect();
                let _ = writeln!(s, "  ret {}", v.join(", "));
            }
            Term::Trap => {
                let _ = writeln!(s, "  trap");
            }
        }
    }
    let _ = writeln!(s, "}}");
    s
}

// ---------- verifier (debugging aid: ALC_DEBUG=verify) ----------
pub fn verify(f: &Func) -> Result<(), String> {
    let cfg = Cfg::new(f);
    let n = f.insts.len();
    let mut def_block = vec![u32::MAX; n];
    let mut def_pos = vec![0usize; n];
    for &b in &cfg.rpo {
        for (pi, &v) in f.blocks[b as usize].insts.iter().enumerate() {
            if def_block[v as usize] != u32::MAX {
                return Err(format!("%{} appears twice (b{} and b{})", v, def_block[v as usize], b));
            }
            def_block[v as usize] = b;
            def_pos[v as usize] = pi;
        }
    }
    for &b in &cfg.rpo {
        let blk = &f.blocks[b as usize];
        let mut seen_non_phi = false;
        for (pi, &v) in blk.insts.iter().enumerate() {
            let i = &f.insts[v as usize];
            if i.op == Op::Phi {
                if seen_non_phi {
                    return Err(format!("phi %{} after non-phi in b{}", v, b));
                }
                let mut pbs = i.pb.clone();
                pbs.sort();
                let mut ps = cfg.preds[b as usize].clone();
                ps.sort();
                ps.dedup();
                if pbs != ps {
                    return Err(format!("phi %{} in b{} has inputs from {:?} but predecessors are {:?}", v, b, i.pb, cfg.preds[b as usize]));
                }
                for (k, &a) in i.args.iter().enumerate() {
                    let db = def_block[a as usize];
                    if db == u32::MAX {
                        return Err(format!("phi %{} in b{} uses %{} which is not defined in reachable code", v, b, a));
                    }
                    if !cfg.dom(db, i.pb[k]) {
                        return Err(format!("phi %{} in b{}: input %{} (b{}) does not dominate predecessor b{}", v, b, a, db, i.pb[k]));
                    }
                }
            } else {
                seen_non_phi = true;
                for &a in &i.args {
                    let db = def_block[a as usize];
                    if db == u32::MAX {
                        return Err(format!("%{} in b{} uses %{} which is not defined in reachable code", v, b, a));
                    }
                    if db == b {
                        if def_pos[a as usize] >= pi {
                            return Err(format!("%{} in b{} uses %{} before its definition", v, b, a));
                        }
                    } else if !cfg.dom(db, b) {
                        return Err(format!("%{} in b{} uses %{} (b{}) which does not dominate it", v, b, a, db));
                    }
                }
            }
        }
        for a in f.term_uses(b) {
            let db = def_block[a as usize];
            if db == u32::MAX || !cfg.dom(db, b) {
                return Err(format!("terminator of b{} uses %{} which does not dominate it", b, a));
            }
        }
        if blk.term == Term::None {
            return Err(format!("b{} has no terminator", b));
        }
    }
    Ok(())
}
