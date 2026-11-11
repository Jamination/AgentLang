// Per-function lowering: statements, places, control flow. Type checking is fused with IR generation.

struct Val {
    ty: i64
    v: i64
    mem: bool
    alias: i64
    // for a place that is one f32 lane of a vector in memory: (lane, vector IR type)
    lane: Opt[(i64, T)]
    // a place inside a constant (read-only memory): not assignable, no address
    ro: bool
}

fn val_unit() -> Val {
    return Val{ty: T_UNIT, v: NOV, mem: false, alias: 0, lane: None}
}

fn val_err() -> Val {
    return Val{ty: T_ERR, v: NOV, mem: false, alias: 0, lane: None}
}

fn val_never() -> Val {
    return Val{ty: T_NEVER, v: NOV, mem: false, alias: 0, lane: None}
}

struct Scope {
    vars: Map[str, (i64, i64)]
    defers: Vec[*Block]
}

struct LoopCtx {
    brk: i64
    cont: i64
    scope_depth: i64
}

struct Fx {
    cx: *Cx
    f: Func
    cur: i64
    dead: bool
    scopes: Vec[Scope]
    loops: Vec[LoopCtx]
    tenv: Map[str, i64]
    ret_ty: i64
    sret: Opt[i64]
    allocas: Vec[i64]
    traps: Map[(i64, i64), i64]
    // labels of the enclosing labelled loops: (name, index of the loop in `loops`, line)
    labels: Vec[(str, i64, i64)]
    // argument expressions that were evaluated ahead of their call (see `call_shared`):
    // `expr` yields the stored value instead of lowering the expression again
    memo: Vec[(*Expr, Val)]
    // the blocks that are being lowered, outermost first
    blocks: Vec[*Block]
    // for the body of a nested or anonymous function (lower_nested.al): the function it is
    // written in, which is being lowered at the same time; else nil
    parent: *Fx
    // the nested and anonymous functions lowered for this function: (declaration, index in
    // `cx.nested`)
    nested_done: Vec[(*FnDecl, i64)]
}

fn lower_fn_str_less(a: str, b: str) -> bool {
    return cmp(a, b) < 0
}

fn lower_fn_lower_all(cx: *Cx, entry: str, check_from_file: i64) {
    edi, has_entry := cx.fn_names.get(entry)
    if has_entry {
        cx.entry_file = cx.fn_decls[edi].pos.file
        fid := cx.inst_fn(edi, vec[i64]())
        cx.module.entry = fid
    } else {
        cx.err(Pos{file: 0, line: 0, col: 0}, fmt("missing entry function `", entry, "`"))
        return
    }
    checked_all := false
    loop {
        while cx.work.len > 0 {
            w := cx.work.pop()
            lower_fn_lower_fn(cx, w.0, w.1, w.2)
        }
        if checked_all {
            break
        }
        checked_all = true
        // type-check every non-generic user function, even if unreachable
        for di in 0..cx.fn_decls.len {
            d := cx.fn_decls[di]
            eager := d.pos.file >= check_from_file && !cx.lazy_files.has(d.pos.file)
            if d.tparams.is_empty() && eager {
                l, has_l := cx.fn_over.get(d.name)
                if has_l && contains(&l, di) && cx.fn_names.has(d.name) {
                    cx.inst_fn(di, vec[i64]())
                }
            }
        }
        // two definitions of a name whose parameter types are the same once type aliases
        // are resolved (the texts differ, so the declaration pass did not see it)
        okeys := cx.fn_over.keys()
        sort_by(okeys, lower_fn_str_less)
        for n in okeys {
            l, _ := cx.fn_over.get(n)
            if l.len < 2 || !cx.fn_names.has(n) {
                continue
            }
            for a in 1..l.len {
                da := cx.fn_decls[l[a]]
                if da.tparams.len != 0 || da.pos.file < check_from_file || cx.lazy_files.has(da.pos.file) {
                    continue
                }
                fa, has_a := cx.fn_insts.get((l[a], vec[i64]().items()))
                if !has_a || contains(&cx.fn_sigs[fa].0, T_ERR) {
                    continue
                }
                for b in 0..a {
                    db := cx.fn_decls[l[b]]
                    if db.tparams.len != 0 {
                        continue
                    }
                    fb, has_b := cx.fn_insts.get((l[b], vec[i64]().items()))
                    if has_b && cx.fn_sigs[fa].0.items() == cx.fn_sigs[fb].0.items() {
                        at := cx.pos_str(db.pos)
                        cx.err(da.pos, fmt("`", n, "` is already declared with these parameter types at ", at, " (", lower_new_sig(da), " and ", lower_new_sig(db), " are the same types)"))
                        break
                    }
                }
            }
        }
        // and force evaluation of user constants / globals
        // (the names are visited in sorted order: the Rust source iterates a HashMap, whose
        // order is arbitrary)
        ckeys := cx.const_decls.keys()
        sort_by(ckeys, lower_fn_str_less)
        cnames := vec[str]()
        for n in ckeys {
            d, _ := cx.const_decls.get(n)
            if d.pos.file >= check_from_file && !cx.lazy_files.has(d.pos.file) {
                cnames.push(n)
            }
        }
        for i in 0..cnames.len {
            cx.const_named(cnames[i])
        }
        gkeys := cx.global_decls.keys()
        sort_by(gkeys, lower_fn_str_less)
        gnames := vec[str]()
        for n in gkeys {
            d, _ := cx.global_decls.get(n)
            if d.pos.file >= check_from_file && !cx.lazy_files.has(d.pos.file) {
                gnames.push(n)
            }
        }
        for i in 0..gnames.len {
            cx.global(gnames[i])
        }
    }
    // exposed scalar fields lose their private alias class
    if cx.exposed.len != 0 {
        for fi in 0..cx.module.funcs.len {
            f := &cx.module.funcs[fi]
            for ii in 0..f.insts.len {
                i := &f.insts[ii]
                if (i.op == Load || i.op == Store) && i.aux >> 4 != 0 && cx.exposed.has(i.aux >> 4) {
                    i.aux &= 15
                }
            }
        }
    }
}

fn lower_fn_lower_fn(cx: *Cx, fid: i64, di: i64, targs: Vec[i64]) {
    d := cx.fn_decls[di]
    cx.scope_prelude = cx.internal_file(d.pos.file)
    tenv := map[str, i64]()
    for i in 0..min(d.tparams.len, targs.len) {
        tenv.set(d.tparams[i], targs[i])
    }
    lower_fn_lower_body(cx, fid, &d.params, &d.body, tenv, d.name, d.pos, nil)
}

// Lowers the body of function `fid`, whose IR signature and entry in `fn_sigs` exist: a
// top-level function (`parent` is nil), or a nested or anonymous function written in the
// function that `parent` is lowering.
fn lower_fn_lower_body(cx: *Cx, fid: i64, params: *Vec[(str, TypeAst)], body: *Block, tenv: Map[str, i64], name: str, pos: Pos, parent: *Fx) {
    sig := cx.fn_sigs[fid]
    ptys := sig.0
    rty := sig.1
    f := cx.module.funcs[fid]
    cx.module.funcs[fid] = func_new("")
    fx := Fx{
        cx: cx,
        f: f,
        cur: 0,
        dead: false,
        scopes: vec[Scope](),
        loops: vec[LoopCtx](),
        tenv: tenv,
        ret_ty: rty,
        sret: None,
        allocas: vec[i64](),
        traps: map[(i64, i64), i64](),
        labels: vec[(str, i64, i64)](),
        parent: parent,
    }
    fx.scopes.push(Scope{vars: map[str, (i64, i64)](), defers: vec[*Block]()})
    fx.cur = fx.f.new_block()
    pi := 0
    match fx.cx.abi_ret(rty) {
        SRet => {
            p := fx.ins(Param, I64, vec[i64](), pi)
            pi += 1
            fx.sret = Some(p)
        }
        _ => {}
    }
    for i in 0..params.len {
        pname := params[i].0
        pt := ptys[i]
        match fx.cx.abi_param(pt) {
            Scalar(t) => {
                p := fx.ins(Param, t, vec[i64](), pi)
                pi += 1
                addr := fx.declare(pname, pt, pos)
                ak := fx.cx.types.scalar_ir(pt).1
                fx.store_raw(addr, p, t, ak)
            }
            Flat(leaves) => {
                addr := fx.declare(pname, pt, pos)
                for li in 0..leaves.len {
                    l := leaves[li]
                    p := fx.ins(Param, l.t, vec[i64](), pi)
                    pi += 1
                    a := fx.add_off(addr, l.off)
                    fx.store_raw(a, p, l.t, l.alias)
                }
            }
            ByRef => {
                p := fx.ins(Param, I64, vec[i64](), pi)
                pi += 1
                had := fx.scopes[0].vars.has(pname)
                fx.scopes[0].vars.set(pname, (pt, p))
                if had {
                    fx.cx.err(pos, fmt("duplicate parameter `", pname, "`"))
                }
            }
        }
    }
    want := rty != T_UNIT && rty != T_NEVER
    expect: Opt[i64] = None
    if want {
        expect = Some(rty)
    }
    v := fx.block_value(body, want, expect)
    if !fx.dead {
        if rty == T_NEVER {
            fx.terminate(Trap)
        } else if rty == T_UNIT {
            fx.terminate(Ret(vec[i64]()))
        } else if v.ty == T_UNIT {
            fx.cx.err(body.end, fmt("function `", name, "` must return a value of type ", fx.cx.types.name(rty)))
            fx.terminate(Trap)
        } else {
            v2 := fx.coerce(v, rty, body.end)
            fx.do_return(Some(v2))
        }
    }
    // finalize: allocas at the top of the entry block
    entry := clone(fx.allocas)
    entry.extend(fx.f.blocks[0].insts.items())
    fx.f.blocks[0].insts = entry
    for bi in 0..fx.f.blocks.len {
        match fx.f.blocks[bi].term {
            Term.None => {
                fx.f.blocks[bi].term = Trap
            }
            _ => {}
        }
    }
    lf := fx.f
    lf.lowered = true
    cx.flush_layout_errors(pos)
    cx.module.funcs[fid] = lf
}

// ---------- builder primitives ----------
fn ins(self: *Fx, op: Op, ty: T, args: Vec[i64], k: i64) -> i64 {
    return self.f.push(self.cur, op, ty, args, k)
}

fn iconst(self: *Fx, ty: T, k: i64) -> i64 {
    return self.ins(Const, ty, vec[i64](), ir_canon(ty, k))
}

fn new_block(self: *Fx) -> i64 {
    return self.f.new_block()
}

fn switch_to(self: *Fx, b: i64) {
    self.cur = b
    self.dead = false
}

fn terminate(self: *Fx, t: Term) {
    self.f.blocks[self.cur].term = t
    self.cur = self.f.new_block()
    self.dead = true
}

fn jmp(self: *Fx, b: i64) {
    d := self.dead
    self.f.blocks[self.cur].term = Jmp(b)
    self.cur = self.f.new_block()
    self.dead = d
}

fn br(self: *Fx, c: i64, t: i64, e: i64) {
    self.f.blocks[self.cur].term = Br(c, t, e)
    self.cur = self.f.new_block()
}

fn err(self: *Fx, pos: Pos, msg: str) {
    self.cx.err(pos, msg)
}

fn tyname(self: *Fx, t: i64) -> str {
    return self.cx.types.name(t)
}

fn alloca(self: *Fx, size: i64, align: i64) -> i64 {
    v := self.f.mk(Alloca, I64, vec[i64](), max(size, 1))
    i := self.f.im(v)
    i.aux = max(align, 1)
    self.allocas.push(v)
    return v
}

fn temp(self: *Fx, ty: i64) -> i64 {
    s := self.cx.types.size_of(ty)
    a := self.cx.types.align_of(ty)
    return self.alloca(s, a)
}

fn add_off(self: *Fx, addr: i64, off: i64) -> i64 {
    if off == 0 {
        return addr
    }
    c := self.iconst(I64, off)
    return self.ins(Add, I64, vec_of([]i64{addr, c}), 0)
}

fn load_raw(self: *Fx, addr: i64, t: T, alias: i64) -> i64 {
    v := self.ins(Load, t, vec_of([]i64{addr}), 0)
    i := self.f.im(v)
    i.aux = alias
    return v
}

fn store_raw(self: *Fx, addr: i64, val: i64, t: T, alias: i64) {
    v := self.ins(Store, t, vec_of([]i64{addr, val}), 0)
    i := self.f.im(v)
    i.aux = alias
}

fn sval(self: *Fx, ty: i64, v: i64) -> Val {
    return Val{ty: ty, v: v, mem: false, alias: 0, lane: None}
}

// a memory value; alias class is the generic class of scalar types
fn mval(self: *Fx, ty: i64, addr: i64) -> Val {
    alias := 0
    if self.cx.types.is_scalar(ty) {
        alias = self.cx.types.scalar_ir(ty).1
    }
    return Val{ty: ty, v: addr, mem: true, alias: alias, lane: None}
}

fn irt(self: *Fx, ty: i64) -> T {
    return self.cx.types.scalar_ir(ty).0
}

// scalar SSA value of a Val
fn scalar(self: *Fx, v: Val) -> i64 {
    if v.ty == T_ERR || v.ty == T_NEVER || v.ty == T_UNIT {
        return self.iconst(I64, 0)
    }
    if v.mem {
        match v.lane {
            Some(kv) => {
                // one f32 lane of a vector in memory
                x := self.load_raw(v.v, kv.1, v.alias)
                return self.ins(VExt, F32, vec_of([]i64{x}), kv.0)
            }
            None => {}
        }
        t := self.irt(v.ty)
        return self.load_raw(v.v, t, v.alias)
    }
    return v.v
}

// store `src` into the place `dst`
fn store(self: *Fx, dst: Val, src: Val) {
    if dst.ty == T_ERR || src.ty == T_ERR || src.ty == T_NEVER || dst.ty == T_UNIT {
        return
    }
    if self.cx.types.is_scalar(dst.ty) {
        v := self.scalar(src)
        match dst.lane {
            Some(kv) => {
                old := self.load_raw(dst.v, kv.1, dst.alias)
                nv := self.ins(VIns, kv.1, vec_of([]i64{old, v}), kv.0)
                self.store_raw(dst.v, nv, kv.1, dst.alias)
                return
            }
            None => {}
        }
        t := self.irt(dst.ty)
        self.store_raw(dst.v, v, t, dst.alias)
        return
    }
    if !src.mem {
        return
    }
    if src.v == dst.v {
        return
    }
    n := self.cx.types.leaf_count(dst.ty)
    if n <= 16 {
        leaves := vec[Leaf]()
        self.cx.types.leaves(dst.ty, 0, &leaves)
        vals := vec[i64]()
        for i in 0..leaves.len {
            l := leaves[i]
            a := self.add_off(src.v, l.off)
            vals.push(self.load_raw(a, l.t, l.alias))
        }
        for i in 0..leaves.len {
            l := leaves[i]
            a := self.add_off(dst.v, l.off)
            self.store_raw(a, vals[i], l.t, l.alias)
        }
    } else {
        sz := self.cx.types.size_of(dst.ty)
        c := self.iconst(I64, sz)
        self.ins(MemCpy, Void, vec_of([]i64{dst.v, src.v, c}), 0)
    }
}

fn zero(self: *Fx, dst: Val) {
    if dst.ty == T_ERR {
        return
    }
    n := self.cx.types.leaf_count(dst.ty)
    if n <= 32 {
        leaves := vec[Leaf]()
        self.cx.types.leaves(dst.ty, 0, &leaves)
        for i in 0..leaves.len {
            l := leaves[i]
            a := self.add_off(dst.v, l.off)
            z := if l.t.is_fp() { self.ins(FConst, l.t, vec[i64](), 0) } else { self.iconst(l.t, 0) }
            self.store_raw(a, z, l.t, l.alias)
        }
    } else {
        sz := self.cx.types.size_of(dst.ty)
        c := self.iconst(I64, sz)
        z := self.iconst(I8, 0)
        self.ins(MemSet, Void, vec_of([]i64{dst.v, z, c}), 0)
    }
}

fn coerce(self: *Fx, v: Val, to: i64, pos: Pos) -> Val {
    if v.ty == to {
        return v
    }
    if v.ty == T_ERR || to == T_ERR {
        return val_err()
    }
    if v.ty == T_NEVER {
        return val_never()
    }
    a := self.tyname(to)
    b := self.tyname(v.ty)
    self.err(pos, fmt("type mismatch: expected ", a, ", found ", b, lower_match_same_name(a, b)))
    return val_err()
}

// ---------- scopes ----------
fn push_scope(self: *Fx) {
    self.scopes.push(Scope{vars: map[str, (i64, i64)](), defers: vec[*Block]()})
}

fn pop_scope(self: *Fx) {
    if !self.dead {
        defers := clone(self.scopes[self.scopes.len - 1].defers)
        for i in defers.len - 1..=0 by -1 {
            self.block(defers[i])
        }
    }
    self.scopes.pop()
}

fn run_defers_down_to(self: *Fx, depth: i64) {
    // emit defers of scopes [depth..] innermost first, without popping
    all := vec[*Block]()
    for si in self.scopes.len - 1..=depth by -1 {
        s := &self.scopes[si]
        for di in s.defers.len - 1..=0 by -1 {
            all.push(s.defers[di])
        }
    }
    if all.is_empty() {
        return
    }
    // defers must not see themselves again: temporarily hide them
    saved := vec[Vec[*Block]]()
    for si in 0..self.scopes.len {
        saved.push(self.scopes[si].defers)
        self.scopes[si].defers = vec[*Block]()
    }
    for i in 0..all.len {
        self.block(all[i])
    }
    for si in 0..min(self.scopes.len, saved.len) {
        self.scopes[si].defers = saved[si]
    }
}

// A local name: (type, address) of a variable. A negative type slot is not a variable: a
// nested function (-(index into cx.nested) - 1), or LOWER_NESTED_OUTER for a variable of an
// enclosing function, which a nested function cannot use.
fn lookup(self: *Fx, name: str) -> Opt[(i64, i64)] {
    for si in self.scopes.len - 1..=0 by -1 {
        x, ok := self.scopes[si].vars.get(name)
        if ok {
            return Some(x)
        }
    }
    if self.parent != nil {
        return lower_nested_outer(self.parent, name)
    }
    return None
}

fn declare(self: *Fx, name: str, ty: i64, pos: Pos) -> i64 {
    addr := self.temp(ty)
    if name == "_" {
        return addr
    }
    old, known := self.scopes[self.scopes.len - 1].vars.get(name)
    if known {
        if old.0 < 0 {
            self.err(pos, fmt("`", name, "` is already declared in this scope, as a nested function"))
        } else {
            self.err(pos, fmt("`", name, "` is already declared in this scope (use `=` to assign)"))
        }
    }
    self.scopes[self.scopes.len - 1].vars.set(name, (ty, addr))
    return addr
}

// ---------- blocks / statements ----------
fn block(self: *Fx, b: *Block) {
    self.push_scope()
    self.blocks.push(b)
    for i in 0..b.stmts.len {
        self.stmt(&b.stmts[i])
        lint_copy_writes(self, b, i)
    }
    self.blocks.pop()
    self.pop_scope()
}

fn block_value(self: *Fx, b: *Block, want: bool, expect: Opt[i64]) -> Val {
    if !want {
        self.block(b)
        return val_unit()
    }
    self.push_scope()
    self.blocks.push(b)
    n := b.stmts.len
    v := val_unit()
    for i in 0..n {
        s := &b.stmts[i]
        if i + 1 < n {
            self.stmt(s)
            lint_copy_writes(self, b, i)
            continue
        }
        match s.k {
            ExprStmt(e) => {
                v = self.expr(&e, expect)
            }
            If(c, t, eo) => {
                match eo {
                    Some(e) => {
                        v = self.if_value(&c, &t, &e, true, expect)
                    }
                    None => {
                        self.stmt(s)
                    }
                }
            }
            _ => {
                self.stmt(s)
            }
        }
    }
    if self.dead {
        v = val_never()
    } else if v.mem && !self.scopes[self.scopes.len - 1].defers.is_empty() {
        t := self.temp(v.ty)
        tv := self.mval(v.ty, t)
        self.store(tv, v)
        v = tv
    } else if v.mem && self.cx.types.is_scalar(v.ty) {
        s := self.scalar(v)
        v = self.sval(v.ty, s)
    }
    self.blocks.pop()
    self.pop_scope()
    return v
}

// how an expression statement is treated: 0 = `match`, 1 = an expression without effect,
// 2 = `&&` / `||` (may have effects through its operands), 3 = anything else
fn lower_fn_stmt_expr_kind(e: *Expr) -> i64 {
    match e.k {
        Match(_, _) => return 0
        Int(_) => return 1
        Float(_) => return 1
        Str(_) => return 1
        Bool(_) => return 1
        Ident(_) => return 1
        Fn(_) => return 1
        Bin(op, _, _) => {
            if op == LAnd || op == LOr {
                return 2
            }
            return 1
        }
        _ => {}
    }
    return 3
}

// `break` / `continue`
fn lower_fn_break_continue(fx: *Fx, pos: Pos, is_break: bool) {
    if fx.loops.len == 0 {
        if fx.parent != nil {
            fx.err(pos, fmt("`break`/`continue` outside of a loop (the nested function `", fx.f.name, "` cannot leave a loop of the enclosing function: return a value and test it at the call)"))
        } else {
            fx.err(pos, "`break`/`continue` outside of a loop")
        }
        return
    }
    l := fx.loops[fx.loops.len - 1]
    target := if is_break { l.brk } else { l.cont }
    depth := l.scope_depth
    fx.run_defers_down_to(depth)
    fx.f.blocks[fx.cur].term = Jmp(target)
    fx.cur = fx.f.new_block()
    fx.dead = true
}

// `break label` / `continue label`
fn lower_fn_break_continue_to(fx: *Fx, pos: Pos, is_break: bool, label: str) {
    idx := -1
    for i in fx.labels.len - 1..=0 by -1 {
        if fx.labels[i].0 == label {
            idx = fx.labels[i].1
            break
        }
    }
    word := if is_break { "break" } else { "continue" }
    if idx < 0 || idx >= fx.loops.len {
        if fx.labels.len == 0 && fx.parent != nil {
            fx.err(pos, fmt("`", word, " ", label, "`: there is no loop labelled `", label, "` around this statement in the nested function `", fx.f.name, "` (a nested function cannot leave a loop of the enclosing function: return a value and test it at the call)"))
        } else if fx.labels.len == 0 {
            fx.err(pos, fmt("`", word, " ", label, "`: there is no loop labelled `", label, "` around this statement (label a loop with `", label, ": for ...`, `", label, ": while ...` or `", label, ": loop ...`)"))
        } else {
            names := vec[str]()
            for i in fx.labels.len - 1..=0 by -1 {
                names.push(fmt("`", fx.labels[i].0, "`"))
            }
            fx.err(pos, fmt("`", word, " ", label, "`: there is no loop labelled `", label, "` around this statement (labels in scope: ", join(names.items(), ", "), ")"))
        }
        return
    }
    l := fx.loops[idx]
    target := if is_break { l.brk } else { l.cont }
    fx.run_defers_down_to(l.scope_depth)
    fx.f.blocks[fx.cur].term = Jmp(target)
    fx.cur = fx.f.new_block()
    fx.dead = true
}

fn stmt(self: *Fx, s: *Stmt) {
    match s.k {
        ExprStmt(e) => {
            kind := lower_fn_stmt_expr_kind(&e)
            if kind == 0 {
                match e.k {
                    Match(sc, arms) => {
                        self.match_expr(sc, arms.items(), false, None, e.pos)
                    }
                    _ => {}
                }
            } else if kind == 1 || kind == 2 {
                self.expr(&e, None)
                if kind == 1 {
                    self.err(e.pos, "expression statement has no effect (did you mean `=` or `:=`?)")
                }
            } else {
                self.expr(&e, None)
            }
        }
        Let(names, e) => {
            v := self.expr(&e, None)
            if names.len == 1 {
                if v.ty == T_UNIT || v.ty == T_NEVER {
                    self.err(s.pos, fmt("cannot bind `", names[0], "` to an expression without a value"))
                    return
                }
                addr := self.declare(names[0], v.ty, s.pos)
                dst := self.mval(v.ty, addr)
                self.store(dst, v)
            } else {
                tys: Vec[i64]
                is_tuple := false
                match self.cx.types.k(v.ty) {
                    Tuple(ts) => {
                        if ts.len == names.len {
                            tys = ts
                            is_tuple = true
                        }
                    }
                    Err => return
                    _ => {}
                }
                if !is_tuple {
                    tn := self.tyname(v.ty)
                    self.err(s.pos, fmt("cannot destructure ", tn, " into ", names.len, " names"))
                    return
                }
                offs := self.cx.types.tuple_offsets(tys.items())
                for i in 0..names.len {
                    src_a := self.add_off(v.v, offs[i])
                    src := self.mval(tys[i], src_a)
                    if self.cx.types.is_scalar(tys[i]) {
                        src.alias = self.cx.types.field_alias(v.ty, i, tys[i])
                    }
                    addr := self.declare(names[i], tys[i], s.pos)
                    dst := self.mval(tys[i], addr)
                    self.store(dst, src)
                }
            }
        }
        MultiAssign(lhs, e) => {
            v := self.expr(&e, None)
            is_tuple := false
            match self.cx.types.k(v.ty) {
                Tuple(ts) => {
                    is_tuple = ts.len == lhs.len
                }
                Err => return
                _ => {}
            }
            if !is_tuple {
                tn := self.tyname(v.ty)
                self.err(s.pos, fmt("cannot destructure ", tn, " into ", lhs.len, " places"))
                return
            }
            // copy first: the right side may alias the destinations
            t := self.temp(v.ty)
            tv := self.mval(v.ty, t)
            self.store(tv, v)
            for i in 0..lhs.len {
                src: Val
                match self.field_of(tv, fmt(i), s.pos) {
                    Some(p) => {
                        src = p
                    }
                    None => return
                }
                match self.place(&lhs[i]) {
                    Some(dst) => {
                        sv := self.coerce(src, dst.ty, lhs[i].pos)
                        self.store(dst, sv)
                    }
                    None => {}
                }
            }
        }
        Var(name, ty, init) => {
            t: Opt[i64] = None
            match ty {
                Some(ta) => {
                    t = Some(self.cx.resolve(&ta, &self.tenv))
                }
                None => {}
            }
            match init {
                Some(e) => {
                    v := self.expr(&e, t)
                    match t {
                        Some(tt) => {
                            v = self.coerce(v, tt, e.pos)
                        }
                        None => {}
                    }
                    if v.ty == T_UNIT || v.ty == T_NEVER {
                        self.err(s.pos, fmt("cannot bind `", name, "` to an expression without a value"))
                        return
                    }
                    addr := self.declare(name, v.ty, s.pos)
                    dst := self.mval(v.ty, addr)
                    self.store(dst, v)
                }
                None => {
                    match t {
                        Some(tt) => {
                            addr := self.declare(name, tt, s.pos)
                            dst := self.mval(tt, addr)
                            self.zero(dst)
                        }
                        None => {
                            self.err(s.pos, "a variable needs a type or an initializer")
                        }
                    }
                }
            }
        }
        Assign(lhs, op, rhs) => {
            match lhs.k {
                Ident(n) => {
                    if n == "_" {
                        self.expr(&rhs, None)
                        return
                    }
                }
                _ => {}
            }
            dst: Val
            match self.place(&lhs) {
                Some(d) => {
                    dst = d
                }
                None => {
                    self.expr(&rhs, None)
                    return
                }
            }
            match op {
                None => {
                    v := self.expr(&rhs, Some(dst.ty))
                    v2 := self.coerce(v, dst.ty, rhs.pos)
                    self.store(dst, v2)
                }
                Some(bop) => {
                    cur := self.scalar(dst)
                    l := self.sval(dst.ty, cur)
                    r: Val
                    if bop == Shl || bop == Shr {
                        r = self.expr(&rhs, None)
                    } else {
                        r = self.expr(&rhs, Some(dst.ty))
                    }
                    v := self.binary_vals(bop, l, r, s.pos)
                    v2 := self.coerce(v, dst.ty, rhs.pos)
                    self.store(dst, v2)
                }
            }
        }
        If(c, t, eo) => {
            match eo {
                Some(e) => {
                    self.if_value(&c, &t, &e, false, None)
                }
                None => {
                    bt := self.new_block()
                    bj := self.new_block()
                    self.cond_br(&c, bt, bj)
                    self.switch_to(bt)
                    self.block(&t)
                    self.jmp(bj)
                    self.switch_to(bj)
                }
            }
        }
        While(c, body) => {
            bb := self.new_block()
            bc := self.new_block()
            bx := self.new_block()
            self.cond_br(&c, bb, bx)
            self.switch_to(bb)
            self.loops.push(LoopCtx{brk: bx, cont: bc, scope_depth: self.scopes.len})
            self.block(&body)
            self.loops.pop()
            self.jmp(bc)
            self.switch_to(bc)
            self.cond_br(&c, bb, bx)
            self.switch_to(bx)
        }
        LoopStmt(body) => {
            bb := self.new_block()
            bx := self.new_block()
            self.jmp(bb)
            self.switch_to(bb)
            self.loops.push(LoopCtx{brk: bx, cont: bb, scope_depth: self.scopes.len})
            self.block(&body)
            self.loops.pop()
            self.jmp(bb)
            self.switch_to(bx)
            // reachable only through `break`
            reach := false
            for bi in 0..self.f.blocks.len {
                match self.f.blocks[bi].term {
                    Jmp(t) => {
                        reach = t == bx
                    }
                    Br(_, t, e) => {
                        reach = t == bx || e == bx
                    }
                    _ => {}
                }
                if reach {
                    break
                }
            }
            self.dead = !reach
        }
        For(var1, var2, lo, hi, incl, step_e, body) => {
            // the optional bounds are copied to locals of this arm so that they can be
            // passed by pointer
            hi_e: Expr
            hi_p: Opt[*Expr] = None
            match hi {
                Some(h) => {
                    hi_e = h
                    hi_p = Some(&hi_e)
                }
                None => {}
            }
            step_x: Expr
            step_p: Opt[*Expr] = None
            match step_e {
                Some(se) => {
                    step_x = se
                    step_p = Some(&step_x)
                }
                None => {}
            }
            self.for_stmt(var1, var2, &lo, hi_p, incl, step_p, &body, s.pos)
        }
        Return(eo) => {
            v: Opt[Val] = None
            match eo {
                Some(e) => {
                    rt := self.ret_ty
                    rv := self.expr(&e, Some(rt))
                    if rt == T_UNIT || rt == T_NEVER {
                        if rv.ty != T_UNIT && rv.ty != T_ERR && rv.ty != T_NEVER {
                            self.err(e.pos, "this function does not return a value")
                        }
                    } else {
                        v = Some(self.coerce(rv, rt, e.pos))
                    }
                }
                None => {
                    if self.ret_ty != T_UNIT && self.ret_ty != T_NEVER {
                        tn := self.tyname(self.ret_ty)
                        self.err(s.pos, fmt("`return` needs a value of type ", tn))
                    }
                }
            }
            if !self.dead {
                self.do_return(v)
            }
        }
        Break => {
            lower_fn_break_continue(self, s.pos, true)
        }
        Continue => {
            lower_fn_break_continue(self, s.pos, false)
        }
        Assert(c, msg) => {
            ok := self.new_block()
            fail := self.new_block()
            self.cond_br(&c, ok, fail)
            self.switch_to(fail)
            loc := self.loc_str(s.pos)
            m: Val
            match msg {
                Some(me) => {
                    v := self.expr(&me, Some(T_STR))
                    m = self.coerce(v, T_STR, me.pos)
                }
                None => {
                    m = self.str_val("assertion failed")
                }
            }
            self.call_rt("__assert_fail", vec[i64](), vec_of([]Val{loc, m}), s.pos)
            if !self.dead {
                self.terminate(Trap)
            }
            self.switch_to(ok)
        }
        BlockStmt(b) => {
            self.block(&b)
        }
        Defer(b) => {
            // the scope keeps a pointer: the block is copied to the heap
            bp := new[Block]()
            *bp = b
            self.scopes[self.scopes.len - 1].defers.push(bp)
        }
        Labeled(label, inner) => {
            for i in 0..self.labels.len {
                if self.labels[i].0 == label {
                    self.err(s.pos, fmt("loop label `", label, "` is already used by the enclosing loop at line ", self.labels[i].2, " (give nested loops different labels)"))
                }
            }
            // the loop statement pushes its entry of `loops` at the current length
            self.labels.push((label, self.loops.len, s.pos.line))
            self.stmt(inner)
            self.labels.pop()
        }
        BreakTo(label) => {
            lower_fn_break_continue_to(self, s.pos, true, label)
        }
        ContinueTo(label) => {
            lower_fn_break_continue_to(self, s.pos, false, label)
        }
        Fn(d) => {
            self.nested_fn(d)
        }
    }
}

fn do_return(self: *Fx, v: Opt[Val]) {
    rets := vec[i64]()
    match v {
        Some(rv) => {
            if rv.ty != T_ERR {
                match self.cx.abi_ret(self.ret_ty) {
                    RetAbi.None => {}
                    Scalar(_) => {
                        rets.push(self.scalar(rv))
                    }
                    Flat(leaves) => {
                        for i in 0..leaves.len {
                            l := leaves[i]
                            a := self.add_off(rv.v, l.off)
                            rets.push(self.load_raw(a, l.t, l.alias))
                        }
                    }
                    SRet => {
                        sp: i64
                        match self.sret {
                            Some(p) => {
                                sp = p
                            }
                            None => panic("unwrap of None")
                        }
                        dst := self.mval(self.ret_ty, sp)
                        self.store(dst, rv)
                    }
                }
            } else {
                self.run_defers_down_to(0)
                self.terminate(Trap)
                return
            }
        }
        None => {}
    }
    self.run_defers_down_to(0)
    self.terminate(Ret(rets))
}

fn if_value(self: *Fx, c: *Expr, t: *Block, e: *Block, want: bool, expect: Opt[i64]) -> Val {
    bt := self.new_block()
    be := self.new_block()
    bj := self.new_block()
    self.cond_br(c, bt, be)
    self.switch_to(bt)
    v1 := self.block_value(t, want, expect)
    d1 := self.dead
    slot: Opt[Val] = None
    if want && !d1 && v1.ty != T_UNIT && v1.ty != T_ERR {
        a := self.temp(v1.ty)
        sv := self.mval(v1.ty, a)
        self.store(sv, v1)
        slot = Some(sv)
    }
    self.jmp(bj)
    self.switch_to(be)
    exp2 := expect
    match slot {
        Some(s) => {
            exp2 = Some(s.ty)
        }
        None => {}
    }
    v2 := self.block_value(e, want, exp2)
    d2 := self.dead
    res := val_unit()
    if want {
        match slot {
            Some(sv) => {
                if !d2 {
                    v2c := self.coerce(v2, sv.ty, e.end)
                    self.store(sv, v2c)
                }
                res = sv
            }
            None => {
                if !d2 && v2.ty != T_UNIT && v2.ty != T_ERR {
                    if d1 {
                        a := self.temp(v2.ty)
                        sv := self.mval(v2.ty, a)
                        self.store(sv, v2)
                        res = sv
                    } else if v1.ty == T_UNIT {
                        tn := self.tyname(v2.ty)
                        self.err(e.end, fmt("`if` branches have different types: () and ", tn))
                    }
                } else if v1.ty == T_ERR || v2.ty == T_ERR {
                    res = val_err()
                }
            }
        }
    }
    self.jmp(bj)
    self.switch_to(bj)
    self.dead = d1 && d2
    if self.dead {
        return val_never()
    }
    return res
}

fn for_stmt(self: *Fx, var1: str, var2: Opt[str], lo: *Expr, hi_o: Opt[*Expr], incl: bool, step_o: Opt[*Expr], body: *Block, pos: Pos) {
    bb := self.new_block()
    bc := self.new_block()
    bx := self.new_block()
    self.push_scope()
    match hi_o {
        Some(hi) => {
            if is_some(var2) {
                self.err(pos, "range `for` takes a single loop variable")
            }
            lv: Val
            hv: Val
            if self.is_untyped(lo) && !self.is_untyped(hi) {
                hv = self.expr(hi, None)
                lv = self.expr(lo, Some(hv.ty))
            } else {
                lv = self.expr(lo, None)
                hv = self.expr(hi, Some(lv.ty))
            }
            ty := lv.ty
            if !self.cx.types.is_int(ty) {
                if ty != T_ERR {
                    tn := self.tyname(ty)
                    self.err(lo.pos, fmt("range bounds must be integers, found ", tn))
                }
                self.pop_scope()
                return
            }
            hv = self.coerce(hv, ty, hi.pos)
            it := self.irt(ty)
            step_dyn: Opt[i64] = None
            stepk := 1
            match step_o {
                Some(se) => {
                    match self.cx.const_eval(se) {
                        Some(cv) => {
                            good := false
                            match cv {
                                Int(k) => {
                                    if k != 0 {
                                        stepk = k
                                        good = true
                                    }
                                }
                                _ => {}
                            }
                            if !good {
                                self.err(se.pos, "`by` step must be a non-zero integer")
                                stepk = 1
                            }
                        }
                        None => {
                            // runtime step: must be positive
                            sv0 := self.expr(se, Some(ty))
                            sv := self.coerce(sv0, ty, se.pos)
                            s := self.scalar(sv)
                            if self.cx.opts.checks {
                                z := self.iconst(it, 0)
                                ok := self.ins(if self.cx.types.is_signed(ty) { Sgt } else { Ne }, I8, vec_of([]i64{s, z}), 0)
                                self.check(ok, 2, se.pos)
                            }
                            step_dyn = Some(s)
                            stepk = 1
                        }
                    }
                }
                None => {}
            }
            signed := self.cx.types.is_signed(ty)
            cmpop: Op
            if signed {
                if stepk > 0 {
                    cmpop = if incl { Sle } else { Slt }
                } else {
                    cmpop = if incl { Sge } else { Sgt }
                }
            } else {
                if stepk > 0 {
                    cmpop = if incl { Ule } else { Ult }
                } else {
                    cmpop = if incl { Uge } else { Ugt }
                }
            }
            lo_s := self.scalar(lv)
            end := self.scalar(hv)
            addr := self.declare(var1, ty, pos)
            iv := self.mval(ty, addr)
            self.store_raw(addr, lo_s, it, iv.alias)
            c := self.ins(cmpop, I8, vec_of([]i64{lo_s, end}), 0)
            self.br(c, bb, bx)
            self.switch_to(bb)
            self.loops.push(LoopCtx{brk: bx, cont: bc, scope_depth: self.scopes.len})
            self.block(body)
            self.loops.pop()
            self.jmp(bc)
            self.switch_to(bc)
            cur := self.load_raw(addr, it, iv.alias)
            st: i64
            match step_dyn {
                Some(s) => {
                    st = s
                }
                None => {
                    st = self.iconst(it, stepk)
                }
            }
            next := self.ins(Add, it, vec_of([]i64{cur, st}), 0)
            self.store_raw(addr, next, it, iv.alias)
            c2 := self.ins(cmpop, I8, vec_of([]i64{next, end}), 0)
            self.br(c2, bb, bx)
        }
        None => {
            if is_some(step_o) {
                self.err(pos, "`by` is only valid with a range")
            }
            cv := self.expr(lo, None)
            p: i64
            ln: i64
            et: i64
            iterable := false
            match self.cx.types.k(cv.ty) {
                Slice(st) => {
                    parts := self.slice_parts(cv)
                    p = parts.0
                    ln = parts.1
                    et = st
                    iterable = true
                }
                Array(at, n) => {
                    ln = self.iconst(I64, n)
                    p = cv.v
                    et = at
                    iterable = true
                }
                Err => {
                    self.pop_scope()
                    return
                }
                _ => {
                    // the live elements of a Vec (also through a pointer)
                    match self.vec_parts(self.auto_deref(cv), true) {
                        Some(x) => {
                            p = x.0
                            ln = x.1
                            et = x.2
                            iterable = true
                        }
                        None => {}
                    }
                }
            }
            if !iterable {
                tn := self.tyname(cv.ty)
                self.err(lo.pos, fmt("cannot iterate over ", tn))
                self.pop_scope()
                return
            }
            iname: str = "_"
            ename: Opt[str] = Some(var1)
            match var2 {
                Some(v2) => {
                    iname = var1
                    ename = Some(v2)
                }
                None => {}
            }
            iaddr := self.declare(iname, T_I64, pos)
            zero := self.iconst(I64, 0)
            self.store_raw(iaddr, zero, I64, AK_I64)
            c := self.ins(Slt, I8, vec_of([]i64{zero, ln}), 0)
            self.br(c, bb, bx)
            self.switch_to(bb)
            self.push_scope()
            match ename {
                Some(en) => {
                    i := self.load_raw(iaddr, I64, AK_I64)
                    es := self.cx.types.size_of(et)
                    esz := self.iconst(I64, es)
                    off := self.ins(Mul, I64, vec_of([]i64{i, esz}), 0)
                    ea := self.ins(Add, I64, vec_of([]i64{p, off}), 0)
                    src := self.mval(et, ea)
                    eaddr := self.declare(en, et, pos)
                    dst := self.mval(et, eaddr)
                    self.store(dst, src)
                }
                None => {}
            }
            self.loops.push(LoopCtx{brk: bx, cont: bc, scope_depth: self.scopes.len})
            self.block(body)
            self.loops.pop()
            self.pop_scope()
            self.jmp(bc)
            self.switch_to(bc)
            cur := self.load_raw(iaddr, I64, AK_I64)
            one := self.iconst(I64, 1)
            next := self.ins(Add, I64, vec_of([]i64{cur, one}), 0)
            self.store_raw(iaddr, next, I64, AK_I64)
            c2 := self.ins(Slt, I8, vec_of([]i64{next, ln}), 0)
            self.br(c2, bb, bx)
        }
    }
    self.switch_to(bx)
    self.pop_scope()
}

// ---------- conditions ----------
fn cond_br(self: *Fx, e: *Expr, t: i64, f: i64) {
    match e.k {
        Bin(op, a, b) => {
            if op == LAnd {
                mid := self.new_block()
                self.cond_br(a, mid, f)
                self.switch_to(mid)
                self.cond_br(b, t, f)
                return
            }
            if op == LOr {
                mid := self.new_block()
                self.cond_br(a, t, mid)
                self.switch_to(mid)
                self.cond_br(b, t, f)
                return
            }
        }
        Un(op, a) => {
            if op == Not {
                self.cond_br(a, f, t)
                return
            }
        }
        _ => {}
    }
    v0 := self.expr(e, Some(T_BOOL))
    v := self.coerce(v0, T_BOOL, e.pos)
    c := self.scalar(v)
    d := self.dead
    self.br(c, t, f)
    self.dead = d
}

// ---------- runtime failure blocks ----------
fn loc_str(self: *Fx, pos: Pos) -> Val {
    fname: str = ""
    if pos.file >= 0 && pos.file < self.cx.file_names.len {
        fname = self.cx.file_names[pos.file]
    }
    s := fmt(fname, ":", pos.line)
    return self.str_val(s)
}

fn str_val(self: *Fx, s: str) -> Val {
    g := self.cx.string_global(s)
    t := self.temp(T_STR)
    p := self.ins(GAddr, I64, vec[i64](), g)
    n := self.iconst(I64, len(s))
    v := self.mval(T_STR, t)
    self.store_slice(v, p, n)
    return v
}

fn store_slice(self: *Fx, dst: Val, p: i64, n: i64) {
    leaves := vec[Leaf]()
    self.cx.types.leaves(dst.ty, 0, &leaves)
    self.store_raw(dst.v, p, I64, leaves.at(0).alias)
    a := self.add_off(dst.v, 8)
    self.store_raw(a, n, I64, leaves.at(1).alias)
}

fn slice_parts(self: *Fx, s: Val) -> (i64, i64) {
    leaves := vec[Leaf]()
    self.cx.types.leaves(s.ty, 0, &leaves)
    p := self.load_raw(s.v, I64, leaves.at(0).alias)
    a := self.add_off(s.v, 8)
    l := self.load_raw(a, I64, leaves.at(1).alias)
    return (p, l)
}

// kind: 0 = bounds, 1 = division by zero
fn trap_block(self: *Fx, kind: i64, pos: Pos) -> i64 {
    known, found := self.traps.get((kind, pos.line))
    if found {
        return known
    }
    save_cur := self.cur
    save_dead := self.dead
    b := self.new_block()
    self.switch_to(b)
    loc := self.loc_str(pos)
    name := match kind {
        0 => "__bounds_fail"
        1 => "__div_fail"
        _ => "__step_fail"
    }
    self.call_rt(name, vec[i64](), vec_of([]Val{loc}), pos)
    if !self.dead {
        self.terminate(Trap)
    }
    self.cur = save_cur
    self.dead = save_dead
    self.traps.set((kind, pos.line), b)
    return b
}

fn check(self: *Fx, cond: i64, kind: i64, pos: Pos) {
    tb := self.trap_block(kind, pos)
    ok := self.new_block()
    d := self.dead
    self.br(cond, ok, tb)
    self.switch_to(ok)
    self.dead = d
}
