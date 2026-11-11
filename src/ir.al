// SSA intermediate representation.

const NOV = 0xFFFFFFFF

enum T {
    TVoid,
    TI8,
    TI16,
    TI32,
    TI64,
    TF64,
    TF32,
    // 128-bit vectors of f32 lanes held in an xmm register; they differ in memory size only
    TV2,
    TV3,
    TV4,
}

fn size(self: T) -> i64 {
    match self {
        TVoid => 0
        TI8 => 1
        TI16 => 2
        TI32, TF32 => 4
        TI64, TF64, TV2 => 8
        TV3 => 12
        TV4 => 16
    }
}

fn bits(self: T) -> i64 {
    return self.size() * 8
}

fn is_int(self: T) -> bool {
    return self == TI8 || self == TI16 || self == TI32 || self == TI64
}

// lives in an xmm register
fn is_fp(self: T) -> bool {
    return self == TF32 || self == TF64 || self == TV2 || self == TV3 || self == TV4
}

fn is_vec(self: T) -> bool {
    return self == TV2 || self == TV3 || self == TV4
}

fn name(self: T) -> str {
    match self {
        TVoid => "void"
        TI8 => "i8"
        TI16 => "i16"
        TI32 => "i32"
        TI64 => "i64"
        TF64 => "f64"
        TF32 => "f32"
        TV2 => "v2"
        TV3 => "v3"
        TV4 => "v4"
    }
}

enum Op {
    OpConst,  // k = value (sign-extended to i64, canonical for type)
    OpFConst, // k = f64 bits (f32 bits for F32; vectors: only 0)
    OpParam,  // k = index
    OpGAddr,  // k = global id
    OpFAddr,  // k = function id
    OpAlloca, // k = size, aux = align
    OpAdd,
    OpSub,
    OpMul,
    OpSDiv,
    OpUDiv,
    OpSRem,
    OpURem,
    OpAnd,
    OpOr,
    OpXor,
    OpShl,
    OpLShr,
    OpAShr,
    OpRotl,
    OpRotr,
    OpMulHiS,
    OpMulHiU,
    OpFAdd,
    OpFSub,
    OpFMul,
    OpFDiv,
    OpFSqrt,
    OpFNeg,
    OpFAbs,
    OpFMin,   // x86 semantics: a < b ? a : b
    OpFMax,   // a > b ? a : b
    OpFExt,   // f32 -> f64
    OpFTrunc, // f64 -> f32
    OpVSplat, // f32 -> vector with every lane equal
    OpVBuild, // f32 lanes -> vector
    OpVExt,   // vector -> f32, k = lane
    OpVIns,   // args = [vector, f32], k = lane
    OpVShuf,  // args = [a, b], k = shufps immediate: lanes 0,1 from a and 2,3 from b
    OpEq,
    OpNe,
    OpSlt,
    OpSle,
    OpSgt,
    OpSge,
    OpUlt,
    OpUle,
    OpUgt,
    OpUge,
    OpFEq,
    OpFNe,
    OpFLt,
    OpFLe,
    OpFGt,
    OpFGe,
    OpSExt,
    OpZExt,
    OpTrunc,
    OpSIToF,
    OpFToSI,
    OpBitsToF,
    OpFToBits,
    OpSelect, // args = [cond, a, b]
    OpLoad,   // args = [addr], aux = alias class
    OpStore,  // args = [addr, val], ty = type of val, aux = alias class
    OpCall,   // k = func id
    OpCallInd, // args[0] = fn pointer
    OpSyscall,
    OpProj, // args[0] = call, k = result index
    OpPhi,
    OpMemCpy, // args = [dst, src, n]
    OpMemSet, // args = [dst, byte, n]
    OpBswap,
    OpPopcnt,
    OpCtz,
    OpClz,
}

fn is_cmp(self: Op) -> bool {
    match self {
        OpEq, OpNe, OpSlt, OpSle, OpSgt, OpSge, OpUlt, OpUle, OpUgt, OpUge, OpFEq, OpFNe, OpFLt, OpFLe, OpFGt, OpFGe => true
        _ => false
    }
}

fn is_icmp(self: Op) -> bool {
    match self {
        OpEq, OpNe, OpSlt, OpSle, OpSgt, OpSge, OpUlt, OpUle, OpUgt, OpUge => true
        _ => false
    }
}

fn is_commutative(self: Op) -> bool {
    match self {
        OpAdd, OpMul, OpAnd, OpOr, OpXor, OpFAdd, OpFMul, OpEq, OpNe, OpFEq, OpFNe, OpMulHiS, OpMulHiU => true
        _ => false
    }
}

// no side effects, no memory dependence, cannot trap
fn is_pure(self: Op) -> bool {
    match self {
        OpParam, OpAlloca, OpSDiv, OpUDiv, OpSRem, OpURem, OpLoad, OpStore, OpCall, OpCallInd, OpSyscall, OpProj, OpPhi, OpMemCpy, OpMemSet => false
        _ => true
    }
}

fn swap_cmp(self: Op) -> Op {
    match self {
        OpSlt => OpSgt
        OpSle => OpSge
        OpSgt => OpSlt
        OpSge => OpSle
        OpUlt => OpUgt
        OpUle => OpUge
        OpUgt => OpUlt
        OpUge => OpUle
        OpFLt => OpFGt
        OpFLe => OpFGe
        OpFGt => OpFLt
        OpFGe => OpFLe
        _ => self
    }
}

// integer compare negation (not valid for float compares because of NaN)
fn negate_icmp(self: Op) -> Op {
    match self {
        OpEq => OpNe
        OpNe => OpEq
        OpSlt => OpSge
        OpSle => OpSgt
        OpSgt => OpSle
        OpSge => OpSlt
        OpUlt => OpUge
        OpUle => OpUgt
        OpUgt => OpUle
        OpUge => OpUlt
        _ => self
    }
}

struct Inst {
    op: Op
    ty: T
    args: Vec[i64]
    k: i64
    aux: i64
    pb: Vec[i64] // phi predecessor blocks, parallel to args
}

// an independent copy (args and pb are not shared)
fn clone(i: *Inst) -> Inst {
    return Inst{op: i.op, ty: i.ty, args: clone(&i.args), k: i.k, aux: i.aux, pb: clone(&i.pb)}
}

enum Term {
    TermNone,
    TermJmp(i64),
    TermBr(i64, i64, i64),
    TermRet(Vec[i64]),
    TermTrap,
}

// Term equality (PartialEq in the Rust source)
fn eq(a: Term, b: Term) -> bool {
    match a {
        TermNone => {
            match b {
                TermNone => return true
                _ => return false
            }
        }
        TermJmp(t) => {
            match b {
                TermJmp(t2) => return t == t2
                _ => return false
            }
        }
        TermBr(c, t, e) => {
            match b {
                TermBr(c2, t2, e2) => return c == c2 && t == t2 && e == e2
                _ => return false
            }
        }
        TermRet(vs) => {
            match b {
                TermRet(vs2) => return vs.items() == vs2.items()
                _ => return false
            }
        }
        TermTrap => {
            match b {
                TermTrap => return true
                _ => return false
            }
        }
    }
}

// an independent copy (the value list of Ret is not shared)
fn clone(t: Term) -> Term {
    match t {
        TermRet(vs) => return TermRet(clone(&vs))
        _ => return t
    }
}

struct BlockData {
    insts: Vec[i64]
    term: Term
}

fn clone(b: *BlockData) -> BlockData {
    return BlockData{insts: clone(&b.insts), term: clone(b.term)}
}

struct Func {
    name: str
    params: Vec[T]
    rets: Vec[T]
    insts: Vec[Inst]
    blocks: Vec[BlockData]
    inl: i64 // `inline` in the Rust source (an AL keyword): 1 = always, -1 = never, 0 = auto
    noreturn: bool
    lowered: bool
    // a C function in a shared library: index into Module::externs
    ext: Opt[i64]
}

// a deep copy
fn clone(f: *Func) -> Func {
    insts := vec[Inst]()
    for i in 0..f.insts.len {
        insts.push(clone(&f.insts[i]))
    }
    blocks := vec[BlockData]()
    for i in 0..f.blocks.len {
        blocks.push(clone(&f.blocks[i]))
    }
    return Func{
        name: f.name,
        params: clone(&f.params),
        rets: clone(&f.rets),
        insts: insts,
        blocks: blocks,
        inl: f.inl,
        noreturn: f.noreturn,
        lowered: f.lowered,
        ext: f.ext,
    }
}

enum RelocTarget {
    RelocTargetGlobal(i64, i64),
    RelocTargetFunc(i64),
}

struct Global {
    name: str
    size: i64
    align: i64
    data: Opt[Vec[u8]]
    relocs: Vec[(i64, RelocTarget)]
    readonly: bool
}

fn clone(g: *Global) -> Global {
    data: Opt[Vec[u8]] = None
    match g.data {
        Some(d) => {
            data = Some(clone(&d))
        }
        None => {}
    }
    return Global{name: g.name, size: g.size, align: g.align, data: data, relocs: clone(&g.relocs), readonly: g.readonly}
}

struct Module {
    funcs: Vec[Func]
    globals: Vec[Global]
    entry: i64
    externs: Vec[ExternFn]
}

// An imported C function: calls load its address from the 8-byte global `got`, which the
// dynamic loader fills in.
struct ExternFn {
    name: str
    lib: str
    got: i64
}

fn ir_canon(ty: T, k: i64) -> i64 {
    match ty {
        TI8 => i64(i8(k))
        TI16 => i64(i16(k))
        TI32 => i64(i32(k))
        _ => k
    }
}

fn func_new(name: str) -> Func {
    return Func{
        name: name,
        params: vec[T](),
        rets: vec[T](),
        insts: vec[Inst](),
        blocks: vec[BlockData](),
        inl: 0,
        noreturn: false,
        lowered: false,
        ext: None,
    }
}

// n empty lists (each with its own buffer)
fn ir_lists(n: i64) -> Vec[Vec[i64]] {
    p := vec[Vec[i64]]()
    for i in 0..n {
        p.push(vec[i64]())
    }
    return p
}

fn new_block(self: *Func) -> i64 {
    self.blocks.push(BlockData{insts: vec[i64](), term: TermNone})
    return self.blocks.len - 1
}

fn mk(self: *Func, op: Op, ty: T, args: Vec[i64], k: i64) -> i64 {
    self.insts.push(Inst{op: op, ty: ty, args: args, k: k, aux: 0, pb: vec[i64]()})
    return self.insts.len - 1
}

fn push(self: *Func, b: i64, op: Op, ty: T, args: Vec[i64], k: i64) -> i64 {
    v := self.mk(op, ty, args, k)
    self.blocks[b].insts.push(v)
    return v
}

// pointer to instruction v (stale after the next mk / push)
fn im(self: *Func, v: i64) -> *Inst {
    return &self.insts[v]
}

fn is_const(self: *Func, v: i64) -> Opt[i64] {
    i := &self.insts[v]
    if i.op == OpConst {
        return Some(i.k)
    } else {
        return None
    }
}

fn succs(self: *Func, b: i64) -> Vec[i64] {
    match self.blocks[b].term {
        TermJmp(t) => return vec_one(t)
        TermBr(c, t, f) => {
            if t == f {
                return vec_one(t)
            } else {
                return vec_two(t, f)
            }
        }
        _ => return vec[i64]()
    }
}

fn preds(self: *Func) -> Vec[Vec[i64]] {
    p := ir_lists(self.blocks.len)
    for b in 0..self.blocks.len {
        ss := self.succs(b)
        for s in ss.items() {
            p[s].push(b)
        }
    }
    return p
}

// reverse postorder of reachable blocks
fn rpo(self: *Func) -> Vec[i64] {
    n := self.blocks.len
    seen := vec_fill(n, false)
    post := vec[i64]()
    stack := vec[(i64, i64)]()
    stack.push((0, 0))
    seen[0] = true
    while stack.len > 0 {
        top := stack.len - 1
        b := stack[top].0
        i := stack[top].1
        ss := self.succs(b)
        if i < ss.len {
            s := ss[i]
            stack[top].1 = i + 1
            if !seen[s] {
                seen[s] = true
                stack.push((s, 0))
            }
        } else {
            post.push(b)
            stack.pop()
        }
    }
    reverse(post.items())
    return post
}

fn term_uses(self: *Func, b: i64) -> Vec[i64] {
    match self.blocks[b].term {
        TermBr(c, t, e) => return vec_of([]i64{c})
        TermRet(v) => return clone(&v)
        _ => return vec[i64]()
    }
}

fn use_counts(self: *Func) -> Vec[i64] {
    c := vec_fill(self.insts.len, 0)
    for bi in 0..self.blocks.len {
        b := &self.blocks[bi]
        for v in b.insts.items() {
            for a in self.insts[v].args.items() {
                c[a] += 1
            }
        }
        match b.term {
            TermBr(v, t, e) => {
                c[v] += 1
            }
            TermRet(vs) => {
                for v in vs.items() {
                    c[v] += 1
                }
            }
            _ => {}
        }
    }
    return c
}

fn ir_apply_repl_find(map: *Vec[i64], v: i64) -> i64 {
    r := v
    while map[r] != NOV {
        r = map[r]
    }
    c := v
    while map[c] != NOV {
        n := map[c]
        map[c] = r
        c = n
    }
    return r
}

// apply a replacement map (map[v] = replacement or NOV) to all uses
fn apply_repl(self: *Func, map: *Vec[i64]) {
    if map.len < self.insts.len {
        map.resize(self.insts.len, NOV)
    }
    for bi in 0..self.blocks.len {
        for ii in 0..self.blocks[bi].insts.len {
            v := self.blocks[bi].insts[ii]
            for ai in 0..self.insts[v].args.len {
                a := self.insts[v].args[ai]
                if map[a] != NOV {
                    self.insts[v].args[ai] = ir_apply_repl_find(map, a)
                }
            }
        }
        match self.blocks[bi].term {
            TermBr(c, t, e) => {
                if map[c] != NOV {
                    self.blocks[bi].term = TermBr(ir_apply_repl_find(map, c), t, e)
                }
            }
            TermRet(vs) => {
                // vs shares its buffer with the terminator: updated in place
                for i in 0..vs.len {
                    if map[vs[i]] != NOV {
                        vs[i] = ir_apply_repl_find(map, vs[i])
                    }
                }
            }
            _ => {}
        }
    }
}

fn block_of(self: *Func) -> Vec[i64] {
    bo := vec_fill(self.insts.len, 0xFFFFFFFF)
    for bi in 0..self.blocks.len {
        for v in self.blocks[bi].insts.items() {
            bo[v] = bi
        }
    }
    return bo
}

fn size(self: *Func) -> i64 {
    n := 0
    for bi in 0..self.blocks.len {
        n += self.blocks[bi].insts.len + 1
    }
    return n
}

// ---------- CFG analysis ----------
struct Cfg {
    rpo: Vec[i64]
    rpo_idx: Vec[i64]
    preds: Vec[Vec[i64]]
    idom: Vec[i64]
    children: Vec[Vec[i64]]
    pre: Vec[i64]
    post: Vec[i64]
}

fn cfg_new(f: *Func) -> Cfg {
    n := f.blocks.len
    rpo := f.rpo()
    rpo_idx := vec_fill(n, 0xFFFFFFFF)
    for i in 0..rpo.len {
        rpo_idx[rpo[i]] = i
    }
    preds := ir_lists(n)
    for b in rpo.items() {
        ss := f.succs(b)
        for s in ss.items() {
            preds[s].push(b)
        }
    }
    idom := vec_fill(n, 0xFFFFFFFF)
    idom[0] = 0
    changed := true
    while changed {
        changed = false
        for bi in 1..rpo.len {
            b := rpo[bi]
            nw := 0xFFFFFFFF
            for p in preds[b].items() {
                if idom[p] == 0xFFFFFFFF {
                    continue
                }
                if nw == 0xFFFFFFFF {
                    nw = p
                } else {
                    x := p
                    y := nw
                    while x != y {
                        while rpo_idx[x] > rpo_idx[y] {
                            x = idom[x]
                        }
                        while rpo_idx[y] > rpo_idx[x] {
                            y = idom[y]
                        }
                    }
                    nw = x
                }
            }
            if idom[b] != nw {
                idom[b] = nw
                changed = true
            }
        }
    }
    children := ir_lists(n)
    for bi in 1..rpo.len {
        b := rpo[bi]
        children[idom[b]].push(b)
    }
    pre := vec_fill(n, 0)
    post := vec_fill(n, 0)
    t := 0
    stack := vec[(i64, i64)]()
    stack.push((0, 0))
    pre[0] = 0
    while stack.len > 0 {
        top := stack.len - 1
        b := stack[top].0
        i := stack[top].1
        if i < children[b].len {
            c := children[b][i]
            stack[top].1 = i + 1
            t += 1
            pre[c] = t
            stack.push((c, 0))
        } else {
            t += 1
            post[b] = t
            stack.pop()
        }
    }
    return Cfg{rpo: rpo, rpo_idx: rpo_idx, preds: preds, idom: idom, children: children, pre: pre, post: post}
}

fn reachable(self: *Cfg, b: i64) -> bool {
    return self.rpo_idx[b] != 0xFFFFFFFF
}

// a dominates b (reflexive)
fn dom(self: *Cfg, a: i64, b: i64) -> bool {
    return self.pre[a] <= self.pre[b] && self.post[b] <= self.post[a]
}

struct Loop {
    header: i64
    blocks: Vec[i64]
    latches: Vec[i64]
    parent: Opt[i64]
    depth: i64
}

struct Loops {
    loops: Vec[Loop]
    loop_of: Vec[Opt[i64]] // innermost loop per block
}

fn loops_new(f: *Func, cfg: *Cfg) -> Loops {
    n := f.blocks.len
    loops := vec[Loop]()
    none: Opt[i64] = None
    by_header := vec_fill(n, none)
    for b in cfg.rpo.items() {
        ss := f.succs(b)
        for s in ss.items() {
            if cfg.dom(s, b) {
                li := 0
                match by_header[s] {
                    Some(x) => {
                        li = x
                    }
                    None => {
                        loops.push(Loop{header: s, blocks: vec_of([]i64{s}), latches: vec[i64](), parent: None, depth: 0})
                        by_header[s] = Some(loops.len - 1)
                        li = loops.len - 1
                    }
                }
                loops[li].latches.push(b)
            }
        }
    }
    for li in 0..loops.len {
        l := &loops[li]
        inl := vec_fill(n, false)
        inl[l.header] = true
        work := vec[i64]()
        for lt in l.latches.items() {
            if !inl[lt] {
                inl[lt] = true
                work.push(lt)
                l.blocks.push(lt)
            }
        }
        while work.len > 0 {
            b := work.pop()
            for p in cfg.preds[b].items() {
                if !inl[p] {
                    inl[p] = true
                    l.blocks.push(p)
                    work.push(p)
                }
            }
        }
    }
    // nesting: process loops from largest to smallest
    // (a stable insertion sort in place of sort_by with a closure)
    order := vec[i64]()
    for i in 0..loops.len {
        order.push(i)
    }
    for i in 1..order.len {
        j := i
        while j > 0 && loops[order[j - 1]].blocks.len < loops[order[j]].blocks.len {
            tmp := order[j - 1]
            order[j - 1] = order[j]
            order[j] = tmp
            j -= 1
        }
    }
    loop_of := vec_fill(n, none)
    for li in order.items() {
        parent := loop_of[loops[li].header]
        loops[li].parent = parent
        match parent {
            Some(p) => {
                loops[li].depth = loops[p].depth + 1
            }
            None => {
                loops[li].depth = 1
            }
        }
        for bi in 0..loops[li].blocks.len {
            loop_of[loops[li].blocks[bi]] = Some(li)
        }
    }
    return Loops{loops: loops, loop_of: loop_of}
}

fn depth(self: *Loops, b: i64) -> i64 {
    match self.loop_of[b] {
        Some(l) => return self.loops[l].depth
        None => return 0
    }
}

fn contains(self: *Loops, li: i64, b: i64) -> bool {
    cur := self.loop_of[b]
    loop {
        match cur {
            Some(c) => {
                if c == li {
                    return true
                }
                cur = self.loops[c].parent
            }
            None => {
                return false
            }
        }
    }
    return false
}

// ---------- printer ----------
// The text Rust's `{:?}` gives for a float, from AL's shortest round-trip text `s`
// (`fmt(x)`): same digits, but exponent notation below 1e-4 and from 1e16 on, and `NaN`.
fn ir_float_debug(s: str) -> str {
    if s == "nan" || s == "-nan" {
        return "NaN"
    }
    if s == "inf" || s == "-inf" {
        return s
    }
    neg := false
    p := 0
    if p < len(s) && s[p] == '-' {
        neg = true
        p += 1
    }
    // digits of the mantissa and the position of the decimal point within them
    digits := vec[u8]()
    point := -1
    while p < len(s) && s[p] != 'e' && s[p] != 'E' {
        if s[p] == '.' {
            point = digits.len
        } else {
            digits.push(s[p])
        }
        p += 1
    }
    if point < 0 {
        point = digits.len
    }
    exp := 0
    if p < len(s) {
        e, ok := parse_i64(s[p + 1..])
        exp = e
    }
    // value = 0.d1d2.. * 10^e10
    e10 := point + exp
    lead := 0
    while lead < digits.len && digits[lead] == '0' {
        lead += 1
    }
    e10 -= lead
    end := digits.len
    while end > lead && digits[end - 1] == '0' {
        end -= 1
    }
    d := digits[lead..end]
    sign := if neg { "-" } else { "" }
    if len(d) == 0 {
        return concat(sign, "0.0")
    }
    if e10 <= -4 || e10 >= 17 {
        if len(d) == 1 {
            return fmt(sign, d, "e", e10 - 1)
        }
        return fmt(sign, d[..1], ".", d[1..], "e", e10 - 1)
    }
    if e10 <= 0 {
        zeros := alloc[u8](-e10)
        fill(zeros, '0')
        return fmt(sign, "0.", zeros, d)
    }
    if len(d) <= e10 {
        zeros := alloc[u8](e10 - len(d))
        fill(zeros, '0')
        return fmt(sign, d, zeros, ".0")
    }
    return fmt(sign, d[..e10], ".", d[e10..])
}

fn ir_print_func(f: *Func, m: Opt[*Module]) -> str {
    s := vec[str]()
    ps := vec[str]()
    for t in f.params.items() {
        ps.push(t.name())
    }
    rs := vec[str]()
    for t in f.rets.items() {
        rs.push(t.name())
    }
    s.push(fmt("fn ", f.name, "(", join(ps.items(), ", "), ") -> (", join(rs.items(), ", "), ") {\n"))
    rpo := f.rpo()
    for b in rpo.items() {
        s.push(fmt("b", b, ":\n"))
        for v in f.blocks[b].insts.items() {
            i := &f.insts[v]
            if i.ty != TVoid && i.op != OpStore {
                s.push(fmt("  %", v, " = "))
            } else {
                s.push("  ")
            }
            // the variant name without its `Op` prefix, as `{:?}` prints it
            s.push(fmt(fmt(i.op)[2..], " ", i.ty.name()))
            match i.op {
                OpConst => {
                    s.push(fmt(" ", i.k))
                }
                OpFConst => {
                    if i.ty == TF32 {
                        s.push(concat(" ", ir_float_debug(fmt(cast[f32](u32(i.k))))))
                    } else {
                        s.push(concat(" ", ir_float_debug(fmt(cast[f64](u64(i.k))))))
                    }
                }
                OpParam, OpProj, OpVExt, OpVIns, OpVShuf => {
                    s.push(fmt(" #", i.k))
                }
                OpGAddr => {
                    name := ""
                    match m {
                        Some(mm) => {
                            name = mm.globals[i.k].name
                        }
                        None => {}
                    }
                    s.push(fmt(" @g", i.k, "(", name, ")"))
                }
                OpCall, OpFAddr => {
                    name := ""
                    match m {
                        Some(mm) => {
                            name = mm.funcs[i.k].name
                        }
                        None => {}
                    }
                    s.push(fmt(" @f", i.k, "(", name, ")"))
                }
                OpAlloca => {
                    s.push(fmt(" size=", i.k, " align=", i.aux))
                }
                OpLoad, OpStore => {
                    s.push(fmt(" !", i.aux & 15, ".", i.aux >> 4))
                }
                _ => {}
            }
            for ai in 0..i.args.len {
                a := i.args[ai]
                if i.op == OpPhi {
                    s.push(fmt(" [b", i.pb[ai], ": %", a, "]"))
                } else {
                    s.push(fmt(" %", a))
                }
            }
            s.push("\n")
        }
        match f.blocks[b].term {
            TermNone => {
                s.push("  <no terminator>\n")
            }
            TermJmp(t) => {
                s.push(fmt("  jmp b", t, "\n"))
            }
            TermBr(c, t, e) => {
                s.push(fmt("  br %", c, " b", t, " b", e, "\n"))
            }
            TermRet(vs) => {
                v := vec[str]()
                for x in vs.items() {
                    v.push(fmt("%", x))
                }
                s.push(fmt("  ret ", join(v.items(), ", "), "\n"))
            }
            TermTrap => {
                s.push("  trap\n")
            }
        }
    }
    s.push("}\n")
    return join(s.items(), "")
}

// ---------- verifier (debugging aid: ALC_DEBUG=verify) ----------
// returns "" if the function is well formed, otherwise the description of the first problem
fn ir_verify(f: *Func) -> str {
    cfg := cfg_new(f)
    n := f.insts.len
    def_block := vec_fill(n, 0xFFFFFFFF)
    def_pos := vec_fill(n, 0)
    for b in cfg.rpo.items() {
        for pi in 0..f.blocks[b].insts.len {
            v := f.blocks[b].insts[pi]
            if def_block[v] != 0xFFFFFFFF {
                return fmt("%", v, " appears twice (b", def_block[v], " and b", b, ")")
            }
            def_block[v] = b
            def_pos[v] = pi
        }
    }
    for b in cfg.rpo.items() {
        blk := &f.blocks[b]
        seen_non_phi := false
        for pi in 0..blk.insts.len {
            v := blk.insts[pi]
            i := &f.insts[v]
            if i.op == OpPhi {
                if seen_non_phi {
                    return fmt("phi %", v, " after non-phi in b", b)
                }
                pbs := clone(&i.pb)
                sort(pbs.items())
                ps := clone(&cfg.preds[b])
                sort(ps.items())
                ps.dedup()
                if pbs.items() != ps.items() {
                    return fmt("phi %", v, " in b", b, " has inputs from ", i.pb.items(), " but predecessors are ", cfg.preds[b].items())
                }
                for k in 0..i.args.len {
                    a := i.args[k]
                    db := def_block[a]
                    if db == 0xFFFFFFFF {
                        return fmt("phi %", v, " in b", b, " uses %", a, " which is not defined in reachable code")
                    }
                    if !cfg.dom(db, i.pb[k]) {
                        return fmt("phi %", v, " in b", b, ": input %", a, " (b", db, ") does not dominate predecessor b", i.pb[k])
                    }
                }
            } else {
                seen_non_phi = true
                for a in i.args.items() {
                    db := def_block[a]
                    if db == 0xFFFFFFFF {
                        return fmt("%", v, " in b", b, " uses %", a, " which is not defined in reachable code")
                    }
                    if db == b {
                        if def_pos[a] >= pi {
                            return fmt("%", v, " in b", b, " uses %", a, " before its definition")
                        }
                    } else if !cfg.dom(db, b) {
                        return fmt("%", v, " in b", b, " uses %", a, " (b", db, ") which does not dominate it")
                    }
                }
            }
        }
        tu := f.term_uses(b)
        for a in tu.items() {
            db := def_block[a]
            if db == 0xFFFFFFFF || !cfg.dom(db, b) {
                return fmt("terminator of b", b, " uses %", a, " which does not dominate it")
            }
        }
        if eq(blk.term, TermNone) {
            return fmt("b", b, " has no terminator")
        }
    }
    return ""
}
