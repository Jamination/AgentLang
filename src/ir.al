// SSA intermediate representation.

const NOV = 0xFFFFFFFF

enum T {
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

fn size(self: T) -> i64 {
    match self {
        Void => 0
        I8 => 1
        I16 => 2
        I32, F32 => 4
        I64, F64, V2 => 8
        V3 => 12
        V4 => 16
    }
}

fn bits(self: T) -> i64 {
    return self.size() * 8
}

fn is_int(self: T) -> bool {
    return self == I8 || self == I16 || self == I32 || self == I64
}

// lives in an xmm register
fn is_fp(self: T) -> bool {
    return self == F32 || self == F64 || self == V2 || self == V3 || self == V4
}

fn is_vec(self: T) -> bool {
    return self == V2 || self == V3 || self == V4
}

priv fn name(self: T) -> str {
    match self {
        Void => "void"
        I8 => "i8"
        I16 => "i16"
        I32 => "i32"
        I64 => "i64"
        F64 => "f64"
        F32 => "f32"
        V2 => "v2"
        V3 => "v3"
        V4 => "v4"
    }
}

enum Op {
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

fn is_cmp(self: Op) -> bool {
    match self {
        Eq, Ne, Slt, Sle, Sgt, Sge, Ult, Ule, Ugt, Uge, FEq, FNe, FLt, FLe, FGt, FGe => true
        _ => false
    }
}

fn is_icmp(self: Op) -> bool {
    match self {
        Eq, Ne, Slt, Sle, Sgt, Sge, Ult, Ule, Ugt, Uge => true
        _ => false
    }
}

fn is_commutative(self: Op) -> bool {
    match self {
        Add, Mul, And, Or, Xor, FAdd, FMul, Eq, Ne, FEq, FNe, MulHiS, MulHiU => true
        _ => false
    }
}

// no side effects, no memory dependence, cannot trap
fn is_pure(self: Op) -> bool {
    match self {
        Param, Alloca, SDiv, UDiv, SRem, URem, Load, Store, Call, CallInd, Syscall, Proj, Phi, MemCpy, MemSet => false
        _ => true
    }
}

fn swap_cmp(self: Op) -> Op {
    match self {
        Slt => Sgt
        Sle => Sge
        Sgt => Slt
        Sge => Sle
        Ult => Ugt
        Ule => Uge
        Ugt => Ult
        Uge => Ule
        FLt => FGt
        FLe => FGe
        FGt => FLt
        FGe => FLe
        _ => self
    }
}

// integer compare negation (not valid for float compares because of NaN)
fn negate_icmp(self: Op) -> Op {
    match self {
        Eq => Ne
        Ne => Eq
        Slt => Sge
        Sle => Sgt
        Sgt => Sle
        Sge => Slt
        Ult => Uge
        Ule => Ugt
        Ugt => Ule
        Uge => Ult
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

enum Term {
    None,
    Jmp(i64),
    Br(i64, i64, i64),
    Ret(Vec[i64]),
    Trap,
}

struct BlockData {
    insts: Vec[i64]
    term: Term
}

struct Func {
    name: str
    params: Vec[T]
    rets: Vec[T]
    insts: Vec[Inst]
    blocks: Vec[BlockData]
    inl: i64 // inlining hint: 1 = always, -1 = never, 0 = auto
    noreturn: bool
    lowered: bool
    // a C function in a shared library: index into Module.externs
    ext: Opt[i64]
}

enum RelocTarget {
    Global(i64, i64),
    Func(i64),
}

struct Global {
    name: str
    size: i64
    align: i64
    data: Opt[Vec[u8]]
    relocs: Vec[(i64, RelocTarget)]
    readonly: bool
}

struct Module {
    funcs: Vec[Func]
    globals: Vec[Global]
    entry: i64
    externs: Vec[ExternFn]
}

// An imported C symbol: calls of a C function load its address from the 8-byte global `got`,
// which the dynamic loader fills in; for a C variable (`data`) `got` holds the variable's address.
struct ExternFn {
    name: str
    lib: str
    got: i64
    data: bool
}

fn ir_canon(ty: T, k: i64) -> i64 {
    match ty {
        I8 => i64(i8(k))
        I16 => i64(i16(k))
        I32 => i64(i32(k))
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
priv fn lists(n: i64) -> Vec[Vec[i64]] {
    p := vec[Vec[i64]]()
    for i in 0..n {
        p.push(vec[i64]())
    }
    return p
}

fn new_block(self: *Func) -> i64 {
    self.blocks.push(BlockData{insts: vec[i64](), term: Term.None})
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
    if i.op == Const {
        return Some(i.k)
    } else {
        return None
    }
}

// a block that only traps (the failure block of a check)
fn is_trap_block(f: *Func, b: i64) -> bool {
    if f.blocks[b].term != Trap {
        return false
    }
    for v in f.blocks[b].insts {
        if f.insts[v].op == Phi {
            return false
        }
    }
    return true
}

fn succs(self: *Func, b: i64) -> Vec[i64] {
    match self.blocks[b].term {
        Jmp(t) => vec_one(t)
        Br(_, t, f) => if t == f { vec_one(t) } else { vec_two(t, f) }
        _ => vec[i64]()
    }
}

fn preds(self: *Func) -> Vec[Vec[i64]] {
    p := lists(self.blocks.len)
    for b in 0..self.blocks.len {
        ss := self.succs(b)
        for s in ss {
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
        Br(c, _, _) => vec_of([]i64{c})
        Ret(v) => clone(v)
        _ => vec[i64]()
    }
}

fn use_counts(self: *Func) -> Vec[i64] {
    c := vec_fill(self.insts.len, 0)
    for bi in 0..self.blocks.len {
        b := &self.blocks[bi]
        for v in b.insts {
            for a in self.insts[v].args {
                c[a] += 1
            }
        }
        match b.term {
            Br(v, t, e) => {
                c[v] += 1
            }
            Ret(vs) => {
                for v in vs {
                    c[v] += 1
                }
            }
            _ => {}
        }
    }
    return c
}

priv fn apply_repl_find(map: *Vec[i64], v: i64) -> i64 {
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
                    self.insts[v].args[ai] = apply_repl_find(map, a)
                }
            }
        }
        match self.blocks[bi].term {
            Br(&c, _, _) => {
                if map[*c] != NOV {
                    *c = apply_repl_find(map, *c)
                }
            }
            Ret(vs) => {
                // vs shares its buffer with the terminator: updated in place
                for i in 0..vs.len {
                    if map[vs[i]] != NOV {
                        vs[i] = apply_repl_find(map, vs[i])
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
        for v in self.blocks[bi].insts {
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
    preds := lists(n)
    for b in rpo {
        ss := f.succs(b)
        for s in ss {
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
            for p in preds[b] {
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
    children := lists(n)
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

priv struct Loop {
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
    for b in cfg.rpo {
        ss := f.succs(b)
        for s in ss {
            if cfg.dom(s, b) {
                li := match by_header[s] {
                    Some(x) => x
                    None => {
                        loops.push(Loop{header: s, blocks: vec_of([]i64{s}), latches: vec[i64](), parent: None, depth: 0})
                        by_header[s] = Some(loops.len - 1)
                        loops.len - 1
                    }
                }
                loops[li].latches.push(b)
            }
        }
    }
    // one membership buffer for all loops, cleared after each (a fresh one per loop made every
    // loop analysis O(loops x blocks) in memory)
    inl := vec_fill(n, false)
    for li in 0..loops.len {
        l := &loops[li]
        inl[l.header] = true
        work := vec[i64]()
        for lt in l.latches {
            if !inl[lt] {
                inl[lt] = true
                work.push(lt)
                l.blocks.push(lt)
            }
        }
        while work.len > 0 {
            b := work.pop()
            for p in cfg.preds[b] {
                if !inl[p] {
                    inl[p] = true
                    l.blocks.push(p)
                    work.push(p)
                }
            }
        }
        for b in l.blocks {
            inl[b] = false
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
    for li in order {
        parent := loop_of[loops[li].header]
        loops[li].parent = parent
        loops[li].depth = match parent {
            Some(p) => loops[p].depth + 1
            None => 1
        }
        for bi in 0..loops[li].blocks.len {
            loop_of[loops[li].blocks[bi]] = Some(li)
        }
    }
    return Loops{loops: loops, loop_of: loop_of}
}

fn depth(self: *Loops, b: i64) -> i64 {
    match self.loop_of[b] {
        Some(l) => self.loops[l].depth
        None => 0
    }
}

fn contains(self: *Loops, li: i64, b: i64) -> bool {
    cur := self.loop_of[b]
    loop {
        match cur {
            Some(c) if c == li => return true
            Some(c) => cur = self.loops[c].parent
            None => return false
        }
    }
    return false
}

// ---------- printer ----------
// The text of a float in IR dumps, from AL's shortest round-trip text `s`
// (`fmt(x)`): same digits, but exponent notation below 1e-4 and from 1e16 on, and `NaN`.
priv fn float_debug(s: str) -> str {
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
    for t in f.params {
        ps.push(t.name())
    }
    rs := vec[str]()
    for t in f.rets {
        rs.push(t.name())
    }
    s.push(fmt("fn ", f.name, "(", join(ps.items(), ", "), ") -> (", join(rs.items(), ", "), ") {\n"))
    rpo := f.rpo()
    for b in rpo {
        s.push(fmt("b", b, ":\n"))
        for v in f.blocks[b].insts {
            i := &f.insts[v]
            if i.ty != Void && i.op != Store {
                s.push(fmt("  %", v, " = "))
            } else {
                s.push("  ")
            }
            // the variant name without its `Op` prefix, as `{:?}` prints it
            s.push(fmt(fmt(i.op)[2..], " ", i.ty.name()))
            match i.op {
                Const => {
                    s.push(fmt(" ", i.k))
                }
                FConst => {
                    if i.ty == F32 {
                        s.push(concat(" ", float_debug(fmt(cast[f32](u32(i.k))))))
                    } else {
                        s.push(concat(" ", float_debug(fmt(cast[f64](u64(i.k))))))
                    }
                }
                Param, Proj, VExt, VIns, VShuf => {
                    s.push(fmt(" #", i.k))
                }
                GAddr => {
                    name := match m {
                        Some(mm) => mm.globals[i.k].name
                        None => ""
                    }
                    s.push(fmt(" @g", i.k, "(", name, ")"))
                }
                Call, FAddr => {
                    name := match m {
                        Some(mm) => mm.funcs[i.k].name
                        None => ""
                    }
                    s.push(fmt(" @f", i.k, "(", name, ")"))
                }
                Alloca => {
                    s.push(fmt(" size=", i.k, " align=", i.aux))
                }
                Load, Store => {
                    s.push(fmt(" !", i.aux & 15, ".", i.aux >> 4))
                }
                _ => {}
            }
            for ai in 0..i.args.len {
                a := i.args[ai]
                if i.op == Phi {
                    s.push(fmt(" [b", i.pb[ai], ": %", a, "]"))
                } else {
                    s.push(fmt(" %", a))
                }
            }
            s.push("\n")
        }
        match f.blocks[b].term {
            Term.None => {
                s.push("  <no terminator>\n")
            }
            Jmp(t) => {
                s.push(fmt("  jmp b", t, "\n"))
            }
            Br(c, t, e) => {
                s.push(fmt("  br %", c, " b", t, " b", e, "\n"))
            }
            Ret(vs) => {
                v := vec[str]()
                for x in vs {
                    v.push(fmt("%", x))
                }
                s.push(fmt("  ret ", join(v.items(), ", "), "\n"))
            }
            Trap => {
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
    for b in cfg.rpo {
        for pi in 0..f.blocks[b].insts.len {
            v := f.blocks[b].insts[pi]
            if def_block[v] != 0xFFFFFFFF {
                return fmt("%", v, " appears twice (b", def_block[v], " and b", b, ")")
            }
            def_block[v] = b
            def_pos[v] = pi
        }
    }
    for b in cfg.rpo {
        blk := &f.blocks[b]
        seen_non_phi := false
        for pi in 0..blk.insts.len {
            v := blk.insts[pi]
            i := &f.insts[v]
            if i.op == Phi {
                if seen_non_phi {
                    return fmt("phi %", v, " after non-phi in b", b)
                }
                pbs := clone(i.pb)
                sort(pbs.items())
                ps := clone(cfg.preds[b])
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
                for a in i.args {
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
        for a in tu {
            db := def_block[a]
            if db == 0xFFFFFFFF || !cfg.dom(db, b) {
                return fmt("terminator of b", b, " uses %", a, " which does not dominate it")
            }
        }
        if blk.term == Term.None {
            return fmt("b", b, " has no terminator")
        }
    }
    return ""
}
