// Nested functions: `fn name(params) R { body }` as a statement of a block.
//
// A nested function sees the variables of the enclosing function(s) that are in scope at its
// declaration, and may assign them. It is compiled by lambda lifting: it becomes an ordinary
// function `outer.name` with one hidden pointer parameter per variable it uses (after the
// declared parameters), and every call passes the addresses of those variables. There is no
// environment object and no type of its own: calls are direct calls, which the inliner
// treats like any other, after which the variables are plain locals again.
//
// - A nested function that uses no outer variable is an ordinary function, also as a value
//   (`fn(A) R`). One that does can only be called.
// - A nested function that calls another one (declared before it, or itself) needs what the
//   callee needs: those variables become hidden parameters of the caller too and are passed on.
// - The name lives in the scope of the block like a variable (`Scope.vars`): the type slot of
//   such an entry is negative, -(index into `Fx.nested`) - 1.

// a variable of an enclosing function that a nested function needs
struct Capture {
    name str
    ty i64
    // its address: a value of the function whose `Fx.nested` holds the entry
    addr i64
    // used by name in the body (else only passed on to another nested function)
    by_name bool
}

// a nested function as seen from a function that can call it
struct NestedFn {
    decl *FnDecl
    // -1: the declaration has errors (uses of the name are not reported again)
    fid i64
    // the declared parameter types and the result type
    ptys Vec[i64]
    rty i64
    // the hidden parameters, in order
    caps Vec[Capture]
}

// what `lower_fn_lower_body` needs to lower the body of a nested function
struct NestCtx {
    // its hidden parameters (the addresses are values of the enclosing function)
    caps Vec[Capture]
    // the nested functions its body may call: itself, then those of the enclosing function
    // that it uses (their captures are among `caps`)
    imports Vec[NestedFn]
    // names declared after it in the enclosing blocks, with their lines (for diagnostics)
    later Vec[(str, i64)]
}

// ---------- the variables and nested functions a body uses ----------
// The walk over the body of a nested function. Every walker returns a value from a `match`
// over the whole AST enum, so a new AST variant that is not handled here is a compile error
// in the compiler.
struct CapWalk {
    // the enclosing function: names are looked up in its scopes
    fx *Fx
    // names declared inside the body that are in scope (innermost last)
    bound Vec[str]
    // the variables of the enclosing function that are used, in order of first use
    names Vec[str]
    // the nested functions of the enclosing function that are used (indices into fx.nested)
    fns Vec[i64]
}

fn lower_nested_bound(w *CapWalk, n str) bool {
    for i in w.bound.len - 1..=0 by -1 {
        if w.bound[i] == n {
            return true
        }
    }
    return false
}

fn lower_nested_use(w *CapWalk, n str) bool {
    if lower_nested_bound(w, n) {
        return true
    }
    match w.fx.lookup(n) {
        Some(x) => {
            if x.0 < 0 {
                if !contains(&w.fns, -x.0 - 1) {
                    w.fns.push(-x.0 - 1)
                }
            } else if !contains(&w.names, n) {
                w.names.push(n)
            }
        }
        None => {}
    }
    return true
}

// the name of a method call `x.name(..)`
fn lower_nested_use_method(w *CapWalk, name str) bool {
    if lower_nested_bound(w, name) {
        return true
    }
    idx := w.fx.nested_method(name)
    if idx >= 0 && !contains(&w.fns, idx) {
        w.fns.push(idx)
    }
    return true
}

fn lower_nested_walk_opt(w *CapWalk, e Opt[*Expr]) bool {
    match e {
        Some(x) => lower_nested_walk_expr(w, x)
        None => true
    }
}

fn lower_nested_walk_exprs(w *CapWalk, es *Vec[Expr]) bool {
    for i in 0..es.len {
        lower_nested_walk_expr(w, &es[i])
    }
    true
}

fn lower_nested_walk_block(w *CapWalk, b *Block) bool {
    mark := w.bound.len
    for i in 0..b.stmts.len {
        lower_nested_walk_stmt(w, &b.stmts[i])
    }
    w.bound.truncate(mark)
    true
}

fn lower_nested_walk_pats(w *CapWalk, ps *Vec[Pat]) bool {
    for i in 0..ps.len {
        lower_nested_walk_pat(w, &ps[i], false)
    }
    true
}

// `top`: the pattern of an arm itself (an expression); else a part of a variant or tuple pattern
fn lower_nested_walk_pat(w *CapWalk, p *Pat, top bool) bool {
    match *p {
        PatWild => true
        PatConst(e) => {
            name := ""
            match e.k {
                EKIdent(n) => {
                    name = n
                }
                _ => {}
            }
            if top || name == "" {
                lower_nested_walk_expr(w, &e)
            } else if w.fx.cx.const_decls.has(name) || w.fx.bare_variant(name, None).2 != 0 {
                // a constant, a variant or a new binding, depending on the matched type:
                // counted as a use (a binding then simply hides the captured variable)
                lower_nested_use(w, name)
            } else {
                // a new binding of the arm
                w.bound.push(name)
                true
            }
        }
        PatVariant(name, subs, pos, qual) => lower_nested_walk_pats(w, &subs)
        PatTuple(subs, pos) => lower_nested_walk_pats(w, &subs)
        PatRef(name, pos) => {
            if top {
                // (the address of a variable, compared with the matched pointer)
                lower_nested_use(w, name)
            } else {
                w.bound.push(name)
                true
            }
        }
    }
}

fn lower_nested_walk_expr(w *CapWalk, e *Expr) bool {
    match e.k {
        EKInt(n) => true
        EKFloat(f) => true
        EKStr(s) => true
        EKBool(b) => true
        EKNil => true
        EKIdent(n) => lower_nested_use(w, n)
        EKUn(op, x) => lower_nested_walk_expr(w, x)
        EKBin(op, a, b) => {
            lower_nested_walk_expr(w, a)
            lower_nested_walk_expr(w, b)
        }
        EKCall(c, args) => {
            match c.k {
                EKField(recv, name) => {
                    // `x.f(..)` may call a nested function `f`
                    lower_nested_use_method(w, name)
                }
                _ => {}
            }
            lower_nested_walk_expr(w, c)
            lower_nested_walk_exprs(w, &args)
        }
        EKIndex(b, idx) => {
            lower_nested_walk_expr(w, b)
            lower_nested_walk_exprs(w, &idx)
        }
        EKSlice(b, lo, hi) => {
            lower_nested_walk_expr(w, b)
            lower_nested_walk_opt(w, lo)
            lower_nested_walk_opt(w, hi)
        }
        EKField(b, name) => lower_nested_walk_expr(w, b)
        EKLit(te, items) => {
            // (`te` is a type)
            for i in 0..items.len {
                lower_nested_walk_expr(w, &items[i].1)
            }
            true
        }
        EKTypeE(t) => true
        EKIf(c, t, el) => {
            lower_nested_walk_expr(w, c)
            lower_nested_walk_block(w, &t)
            lower_nested_walk_block(w, &el)
        }
        EKTuple(es) => lower_nested_walk_exprs(w, &es)
        EKMatch(sc, arms) => {
            lower_nested_walk_expr(w, sc)
            for i in 0..arms.len {
                arm := &arms[i]
                mark := w.bound.len
                for j in 0..arm.pats.len {
                    lower_nested_walk_pat(w, &arm.pats[j], true)
                }
                lower_nested_walk_opt(w, arm.guard)
                lower_nested_walk_block(w, &arm.body)
                w.bound.truncate(mark)
            }
            true
        }
    }
}

fn lower_nested_walk_stmt(w *CapWalk, s *Stmt) bool {
    match s.k {
        SKExpr(e) => lower_nested_walk_expr(w, &e)
        SKLet(names, e) => {
            lower_nested_walk_expr(w, &e)
            w.bound.extend(names.items())
            true
        }
        SKMultiAssign(lhs, e) => {
            lower_nested_walk_expr(w, &e)
            lower_nested_walk_exprs(w, &lhs)
        }
        SKVar(name, ty, init) => {
            match init {
                Some(e) => {
                    lower_nested_walk_expr(w, &e)
                }
                None => {}
            }
            w.bound.push(name)
            true
        }
        SKAssign(lhs, op, rhs) => {
            lower_nested_walk_expr(w, &lhs)
            lower_nested_walk_expr(w, &rhs)
        }
        SKIf(c, t, eo) => {
            lower_nested_walk_expr(w, &c)
            lower_nested_walk_block(w, &t)
            match eo {
                Some(e) => lower_nested_walk_block(w, &e)
                None => true
            }
        }
        SKWhile(c, body) => {
            lower_nested_walk_expr(w, &c)
            lower_nested_walk_block(w, &body)
        }
        SKLoop(body) => lower_nested_walk_block(w, &body)
        SKLabeled(label, st) => lower_nested_walk_stmt(w, st)
        SKBreakTo(label) => true
        SKContinueTo(label) => true
        SKFor(var1, var2, lo, hi, incl, step, body) => {
            lower_nested_walk_expr(w, &lo)
            match hi {
                Some(h) => {
                    lower_nested_walk_expr(w, &h)
                }
                None => {}
            }
            match step {
                Some(st) => {
                    lower_nested_walk_expr(w, &st)
                }
                None => {}
            }
            mark := w.bound.len
            w.bound.push(var1)
            match var2 {
                Some(v2) => {
                    w.bound.push(v2)
                }
                None => {}
            }
            lower_nested_walk_block(w, &body)
            w.bound.truncate(mark)
            true
        }
        SKReturn(eo) => {
            match eo {
                Some(e) => lower_nested_walk_expr(w, &e)
                None => true
            }
        }
        SKBreak => true
        SKContinue => true
        SKAssert(c, msg) => {
            lower_nested_walk_expr(w, &c)
            match msg {
                Some(m) => lower_nested_walk_expr(w, &m)
                None => true
            }
        }
        SKBlock(b) => lower_nested_walk_block(w, &b)
        SKDefer(b) => lower_nested_walk_block(w, &b)
        SKFn(d) => {
            // a function nested deeper: what it uses from outside is used here too; its
            // name is visible in its own body and in the rest of the block
            w.bound.push(d.name)
            mark := w.bound.len
            for i in 0..d.params.len {
                w.bound.push(d.params[i].0)
            }
            lower_nested_walk_block(w, &d.body)
            w.bound.truncate(mark)
            true
        }
    }
}

// ---------- names ----------
// the nested function that the name `n` means here: its index in `self.nested`, or -1
fn nested_named(self *Fx, n str) i64 {
    match self.lookup(n) {
        Some(x) => {
            if x.0 < 0 {
                return -x.0 - 1
            }
        }
        None => {}
    }
    return -1
}

// the nested function that a method call `x.name(..)` means, or -1
fn nested_method(self *Fx, name str) i64 {
    if self.nested.len == 0 {
        return -1
    }
    idx := self.nested_named(name)
    if idx >= 0 {
        return idx
    }
    // a nested function whose name is also a `priv` name of its file was renamed with it
    // (priv.al: `name` + byte 1 + file); the method name was not, unless a private function
    // has that name
    n := len(name)
    for i in 0..self.nested.len {
        dn := self.nested[i].decl.name
        if len(dn) > n && dn[n] == 1 && dn[..n] == name {
            return self.nested_named(dn)
        }
    }
    return -1
}

// For an unknown name: the note that it is declared later, where a nested function (or the
// use of one) cannot see it; "" if that is not the reason.
fn nested_hint(self *Fx, n str, pos Pos) str {
    for i in 0..self.later.len {
        if self.later[i].0 == n {
            return fmt(": `", n, "` is declared at line ", self.later[i].1, ", after the nested function `", self.f.name, "`, which sees only what is declared before it (declare `", n, "` above the function, or pass it as a parameter)")
        }
    }
    for bi in self.blocks.len - 1..=0 by -1 {
        b := self.blocks[bi]
        for i in 0..b.stmts.len {
            s := &b.stmts[i]
            if lower_nested_after(s.pos, pos) {
                match s.k {
                    SKFn(d) => {
                        if d.name == n {
                            return fmt(": the nested function `", n, "` is declared at line ", s.pos.line, ", after this use (a nested function is visible from its declaration to the end of its block: move it up)")
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    return ""
}

fn lower_nested_after(a Pos, b Pos) bool {
    return a.line > b.line || (a.line == b.line && a.col > b.col)
}

// the names declared after position `after` in the blocks that are being lowered, and those
// that this function itself could not see for that reason
fn nested_later(self *Fx, after Pos) Vec[(str, i64)] {
    out := clone(&self.later)
    for bi in 0..self.blocks.len {
        b := self.blocks[bi]
        for i in 0..b.stmts.len {
            s := &b.stmts[i]
            if !lower_nested_after(s.pos, after) {
                continue
            }
            match s.k {
                SKLet(names, e) => {
                    for j in 0..names.len {
                        out.push((names[j], s.pos.line))
                    }
                }
                SKVar(name, ty, init) => {
                    out.push((name, s.pos.line))
                }
                SKFn(d) => {
                    out.push((d.name, s.pos.line))
                }
                _ => {}
            }
        }
    }
    return out
}

// ---------- declaration ----------
// the name `d.name` means a nested function that cannot be used (its declaration has errors)
fn lower_nested_broken(fx *Fx, d *FnDecl) {
    idx := fx.nested.len
    fx.nested.push(NestedFn{decl: d, fid: -1, ptys: vec[i64](), rty: T_ERR, caps: vec[Capture]()})
    fx.scopes[fx.scopes.len - 1].vars.set(d.name, (-(idx + 1), 0))
}

// the statement `fn name(params) R { body }`
fn nested_fn(self *Fx, d *FnDecl) {
    name := d.name
    top := self.scopes.len - 1
    if self.scopes[top].vars.has(name) {
        self.err(d.pos, fmt("`", name, "` is already declared in this scope: a nested function needs a name that no variable or other nested function of its block has (nested functions cannot be overloaded)"))
        return
    }
    if d.tparams.len != 0 {
        self.err(d.pos, fmt("the nested function `", name, "` cannot have type parameters of its own (`[", join(d.tparams.items(), ", "), "]`): it may use the type parameters of the enclosing function; a generic function is declared at the top level"))
        lower_nested_broken(self, d)
        return
    }
    if is_some(lower_builtin_type(ast_plain(name))) {
        self.err(d.pos, fmt("`", name, "` is a builtin type name"))
        lower_nested_broken(self, d)
        return
    }
    ptys := vec[i64]()
    for i in 0..d.params.len {
        ptys.push(self.cx.resolve(&d.params[i].1, &self.tenv))
    }
    rty := T_UNIT
    match d.ret {
        Some(r) => {
            rty = self.cx.resolve(&r, &self.tenv)
        }
        None => {}
    }
    self.cx.flush_layout_errors(d.pos)
    if contains(&ptys, T_ERR) || rty == T_ERR {
        lower_nested_broken(self, d)
        return
    }
    // what the body uses of this function: variables, and nested functions declared before
    w := CapWalk{fx: self, bound: vec[str](), names: vec[str](), fns: vec[i64]()}
    w.bound.push(name)
    for i in 0..d.params.len {
        w.bound.push(d.params[i].0)
    }
    lower_nested_walk_block(&w, &d.body)
    caps := vec[Capture]()
    for i in 0..w.names.len {
        match self.lookup(w.names[i]) {
            Some(x) => {
                caps.push(Capture{name: w.names[i], ty: x.0, addr: x.1, by_name: true})
            }
            None => {}
        }
    }
    me := NestedFn{decl: d, fid: self.cx.module.funcs.len, ptys: ptys, rty: rty, caps: caps}
    nest := NestCtx{caps: caps, imports: vec_one(me), later: self.nested_later(d.pos)}
    for i in 0..w.fns.len {
        h := self.nested[w.fns[i]]
        nest.imports.push(h)
        // what a callee needs is needed here too
        for j in 0..h.caps.len {
            c := h.caps[j]
            known := false
            for k in 0..caps.len {
                if caps[k].addr == c.addr {
                    known = true
                    break
                }
            }
            if !known {
                caps.push(Capture{name: c.name, ty: c.ty, addr: c.addr, by_name: false})
            }
        }
    }
    me.caps = caps
    nest.caps = caps
    nest.imports[0] = me
    // the lifted function: the declared parameters, then a pointer per captured variable
    full := clone(&ptys)
    for i in 0..caps.len {
        full.push(self.cx.types.ptr_to(caps[i].ty))
    }
    f := func_new(fmt(self.f.name, ".", ast_plain(name)))
    f.noreturn = rty == T_NEVER
    self.cx.fn_abi(&f, full.items(), rty)
    self.cx.module.funcs.push(f)
    self.cx.fn_sigs.push((full, rty))
    lower_fn_lower_body(self.cx, me.fid, &d.params, &d.body, self.tenv, name, d.pos, &nest)
    idx := self.nested.len
    self.nested.push(me)
    self.scopes[top].vars.set(name, (-(idx + 1), 0))
}

// ---------- uses ----------
// `name(args)` or `recv.name(args)` of the nested function `idx`
fn call_nested(self *Fx, idx i64, recv Opt[Val], args []Expr, expect Opt[i64], pos Pos) Val {
    if self.nested[idx].fid < 0 {
        lower_call_eval_all(self, args)
        return val_err()
    }
    return self.call_fn(self.nested[idx].decl, -1, idx, None, recv, args, expect, pos, lower_call_no_pre())
}

// the nested function `idx` used as a value
fn nested_value(self *Fx, idx i64, pos Pos) Val {
    nf := self.nested[idx]
    if nf.fid < 0 {
        return val_err()
    }
    if nf.caps.len != 0 {
        names := vec[str]()
        for i in 0..nf.caps.len {
            names.push(fmt("`", nf.caps[i].name, "`"))
        }
        what := if names.len == 1 { "variable" } else { "variables" }
        self.err(pos, fmt("the nested function `", nf.decl.name, "` uses the ", what, " ", join(names.items(), ", "), " of the enclosing function, so it is not a function value: call it directly (`", nf.decl.name, "(...)`), or pass what it needs as parameters (a callback that needs state takes it as a context argument, like `sort_by(items, ctx, less)`)"))
        return val_err()
    }
    ty := self.cx.types.intern(TyKFn(clone(&nf.ptys), nf.rty))
    v := self.ins(OpFAddr, TI64, vec[i64](), nf.fid)
    return self.sval(ty, v)
}
