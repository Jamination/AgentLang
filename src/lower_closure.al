// Closures: `|a A, b B| R { body }` literals and values of the closure types `|A, B| R`.
//
// A closure value is two words: a code pointer and an environment pointer. A call through
// it passes the environment as one extra integer argument after the declared ones. The
// literal becomes a function of its own; when it uses variables of the enclosing function
// (captures), that function's last parameter is the environment: an array, in the frame of
// the enclosing function, of the addresses of those variables. A literal without captures
// is a plain function, and a plain function is a closure with a nil environment (it never
// looks at the extra argument).

// ---------- captured variables ----------
// The walk over the body of a closure literal that finds the variables of the enclosing
// function it uses. Every walker returns a value from a `match` over the whole AST enum, so
// a new AST variant that is not handled here is a compile error in the compiler.
struct CapWalk {
    fx *Fx
    // names declared inside the literal that are in scope (innermost last)
    bound Vec[str]
    // the captured variables in order of first use
    names Vec[str]
    seen Map[str, bool]
}

fn lower_closure_use(w *CapWalk, n str) bool {
    for i in w.bound.len - 1..=0 by -1 {
        if w.bound[i] == n {
            return true
        }
    }
    if !w.seen.has(n) && is_some(w.fx.lookup(n)) {
        w.seen.set(n, true)
        w.names.push(n)
    }
    return true
}

fn lower_closure_walk_opt(w *CapWalk, e Opt[*Expr]) bool {
    match e {
        Some(x) => lower_closure_walk_expr(w, x)
        None => true
    }
}

fn lower_closure_walk_exprs(w *CapWalk, es *Vec[Expr]) bool {
    for i in 0..es.len {
        lower_closure_walk_expr(w, &es[i])
    }
    true
}

fn lower_closure_walk_block(w *CapWalk, b *Block) bool {
    mark := w.bound.len
    for i in 0..b.stmts.len {
        lower_closure_walk_stmt(w, &b.stmts[i])
    }
    w.bound.truncate(mark)
    true
}

fn lower_closure_walk_pats(w *CapWalk, ps *Vec[Pat]) bool {
    for i in 0..ps.len {
        lower_closure_walk_pat(w, &ps[i])
    }
    true
}

fn lower_closure_walk_pat(w *CapWalk, p *Pat) bool {
    match *p {
        PatWild => true
        PatConst(e) => lower_closure_walk_expr(w, &e)
        // a name inside a variant or tuple pattern is a constant, a variant or a new binding:
        // walking it as an expression captures a variable of that name of the enclosing
        // function, which is harmless if the name turns out to be a binding
        PatVariant(name, subs, pos, qual) => lower_closure_walk_pats(w, &subs)
        PatTuple(subs, pos) => lower_closure_walk_pats(w, &subs)
        PatRef(name, pos) => {
            w.bound.push(name)
            true
        }
    }
}

fn lower_closure_walk_expr(w *CapWalk, e *Expr) bool {
    match e.k {
        EKInt(n) => true
        EKFloat(f) => true
        EKStr(s) => true
        EKBool(b) => true
        EKNil => true
        EKIdent(n) => lower_closure_use(w, n)
        EKUn(op, x) => lower_closure_walk_expr(w, x)
        EKBin(op, a, b) => {
            lower_closure_walk_expr(w, a)
            lower_closure_walk_expr(w, b)
        }
        EKCall(c, args) => {
            lower_closure_walk_expr(w, c)
            lower_closure_walk_exprs(w, &args)
        }
        EKIndex(b, idx) => {
            lower_closure_walk_expr(w, b)
            lower_closure_walk_exprs(w, &idx)
        }
        EKSlice(b, lo, hi) => {
            lower_closure_walk_expr(w, b)
            lower_closure_walk_opt(w, lo)
            lower_closure_walk_opt(w, hi)
        }
        EKField(b, name) => lower_closure_walk_expr(w, b)
        EKLit(te, items) => {
            // (`te` is a type)
            for i in 0..items.len {
                lower_closure_walk_expr(w, &items[i].1)
            }
            true
        }
        EKTypeE(t) => true
        EKIf(c, t, el) => {
            lower_closure_walk_expr(w, c)
            lower_closure_walk_block(w, &t)
            lower_closure_walk_block(w, &el)
        }
        EKTuple(es) => lower_closure_walk_exprs(w, &es)
        EKMatch(sc, arms) => {
            lower_closure_walk_expr(w, sc)
            for i in 0..arms.len {
                arm := &arms[i]
                mark := w.bound.len
                for j in 0..arm.pats.len {
                    lower_closure_walk_pat(w, &arm.pats[j])
                }
                lower_closure_walk_opt(w, arm.guard)
                lower_closure_walk_block(w, &arm.body)
                w.bound.truncate(mark)
            }
            true
        }
        EKClosure(ps, r, body) => {
            // a nested literal: what it captures from outside is captured here too
            mark := w.bound.len
            for i in 0..ps.len {
                w.bound.push(ps[i].0)
            }
            lower_closure_walk_block(w, body)
            w.bound.truncate(mark)
            true
        }
    }
}

fn lower_closure_walk_stmt(w *CapWalk, s *Stmt) bool {
    match s.k {
        SKExpr(e) => lower_closure_walk_expr(w, &e)
        SKLet(names, e) => {
            lower_closure_walk_expr(w, &e)
            w.bound.extend(names.items())
            true
        }
        SKMultiAssign(lhs, e) => {
            lower_closure_walk_expr(w, &e)
            lower_closure_walk_exprs(w, &lhs)
        }
        SKVar(name, ty, init) => {
            match init {
                Some(e) => {
                    lower_closure_walk_expr(w, &e)
                }
                None => {}
            }
            w.bound.push(name)
            true
        }
        SKAssign(lhs, op, rhs) => {
            lower_closure_walk_expr(w, &lhs)
            lower_closure_walk_expr(w, &rhs)
        }
        SKIf(c, t, eo) => {
            lower_closure_walk_expr(w, &c)
            lower_closure_walk_block(w, &t)
            match eo {
                Some(e) => lower_closure_walk_block(w, &e)
                None => true
            }
        }
        SKWhile(c, body) => {
            lower_closure_walk_expr(w, &c)
            lower_closure_walk_block(w, &body)
        }
        SKLoop(body) => lower_closure_walk_block(w, &body)
        SKLabeled(label, st) => lower_closure_walk_stmt(w, st)
        SKBreakTo(label) => true
        SKContinueTo(label) => true
        SKFor(var1, var2, lo, hi, incl, step, body) => {
            lower_closure_walk_expr(w, &lo)
            match hi {
                Some(h) => {
                    lower_closure_walk_expr(w, &h)
                }
                None => {}
            }
            match step {
                Some(st) => {
                    lower_closure_walk_expr(w, &st)
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
            lower_closure_walk_block(w, &body)
            w.bound.truncate(mark)
            true
        }
        SKReturn(eo) => {
            match eo {
                Some(e) => lower_closure_walk_expr(w, &e)
                None => true
            }
        }
        SKBreak => true
        SKContinue => true
        SKAssert(c, msg) => {
            lower_closure_walk_expr(w, &c)
            match msg {
                Some(m) => lower_closure_walk_expr(w, &m)
                None => true
            }
        }
        SKBlock(b) => lower_closure_walk_block(w, &b)
        SKDefer(b) => lower_closure_walk_block(w, &b)
    }
}

// ---------- types ----------
// The closure type of a literal, from its written parameter and result types (T_ERR if one
// of them does not resolve; the errors are reported when the literal is lowered).
fn closure_lit_type(self *Fx, params *Vec[(str, TypeAst)], ret Opt[*TypeAst]) i64 {
    saved := self.cx.errs.len
    ptys := vec[i64]()
    for i in 0..params.len {
        ptys.push(self.cx.resolve(&params[i].1, &self.tenv))
    }
    rty := T_UNIT
    match ret {
        Some(r) => {
            rty = self.cx.resolve(r, &self.tenv)
        }
        None => {}
    }
    self.cx.errs.truncate(saved)
    if contains(&ptys, T_ERR) || rty == T_ERR {
        return T_ERR
    }
    return self.cx.types.closure(ptys, rty)
}

// the closure type of `e` if it is a closure literal, else T_ERR
fn closure_lit_type_of(self *Fx, e *Expr) i64 {
    match e.k {
        EKClosure(ps, r, body) => return self.closure_lit_type(&ps, r)
        _ => return T_ERR
    }
}

// the function type `fn(A) R` with the parameter and result types of the closure type `t`
fn closure_fn_type(self *Fx, t i64) i64 {
    match self.cx.types.k(t) {
        TyKClosure(p, r) => return self.cx.types.intern(TyKFn(p, r))
        _ => return t
    }
}

// the note for a type mismatch where a closure value meets a plain function type
fn closure_fn_hint(self *Fx, from i64, to i64) str {
    if self.cx.types.fn_to_closure(to, from) {
        return " (a closure value may carry an environment, so it is not a plain function; only a closure literal that uses no local variables can be written where `fn` is expected)"
    }
    return ""
}

// ---------- values ----------
// the closure value (code, env) of type `ty` in a fresh temporary
fn closure_make(self *Fx, ty i64, code i64, env i64) Val {
    t := self.temp(ty)
    leaves := vec[Leaf]()
    self.cx.types.leaves(ty, 0, &leaves)
    self.store_raw(t, code, TI64, leaves.at(0).alias)
    a := self.add_off(t, 8)
    self.store_raw(a, env, TI64, leaves.at(1).alias)
    return self.mval(ty, t)
}

// (code pointer, environment pointer) of a closure value
fn closure_parts(self *Fx, c Val) (i64, i64) {
    leaves := vec[Leaf]()
    self.cx.types.leaves(c.ty, 0, &leaves)
    code := self.load_raw(c.v, TI64, leaves.at(0).alias)
    a := self.add_off(c.v, 8)
    env := self.load_raw(a, TI64, leaves.at(1).alias)
    return (code, env)
}

// a function value as a closure of type `to` (same parameter and result types): no environment
fn fn_as_closure(self *Fx, v Val, to i64) Val {
    code := self.scalar(v)
    env := self.iconst(TI64, 0)
    return self.closure_make(to, code, env)
}

// the value of a function name where the closure type `want` (or T_ERR: none) is expected
fn coerce_fn_value(self *Fx, v Val, want i64) Val {
    if want != T_ERR && self.cx.types.fn_to_closure(v.ty, want) {
        return self.fn_as_closure(v, want)
    }
    return v
}

// ---------- literals ----------
fn closure_lit(self *Fx, params *Vec[(str, TypeAst)], ret Opt[*TypeAst], body *Block, expect Opt[i64], pos Pos) Val {
    ptys := vec[i64]()
    for i in 0..params.len {
        ptys.push(self.cx.resolve(&params[i].1, &self.tenv))
    }
    rty := T_UNIT
    match ret {
        Some(r) => {
            rty = self.cx.resolve(r, &self.tenv)
        }
        None => {}
    }
    self.cx.flush_layout_errors(pos)
    if contains(&ptys, T_ERR) || rty == T_ERR {
        return val_err()
    }
    if rty == T_UNIT && body.stmts.len != 0 {
        // `|x i64| { x * 2 }`: the result type is never inferred
        last := &body.stmts[body.stmts.len - 1]
        match last.k {
            SKExpr(e) => {
                if lower_fn_stmt_expr_kind(&e) == 1 {
                    self.err(e.pos, "this closure literal has no result type, so its body cannot end in a value; write the result type after the parameters: `|x i64| i64 { x * 2 }`")
                    return val_err()
                }
            }
            _ => {}
        }
    }
    // the variables of this function that the body uses
    w := CapWalk{fx: self, bound: vec[str](), names: vec[str](), seen: map[str, bool]()}
    for i in 0..params.len {
        w.bound.push(params[i].0)
    }
    lower_closure_walk_block(&w, body)
    caps := vec[(str, i64)]()
    addrs := vec[i64]()
    for i in 0..w.names.len {
        match self.lookup(w.names[i]) {
            Some(x) => {
                caps.push((w.names[i], x.0))
                addrs.push(x.1)
            }
            None => {}
        }
    }
    // the function of the literal, lowered now with the type arguments of this function
    fid := self.cx.module.funcs.len
    f := func_new(fmt(self.f.name, ".closure@", pos.line, ":", pos.col))
    f.noreturn = rty == T_NEVER
    self.cx.fn_abi(&f, ptys.items(), rty)
    if caps.len != 0 {
        f.params.push(TI64)
    }
    self.cx.module.funcs.push(f)
    self.cx.fn_sigs.push((clone(&ptys), rty))
    lower_fn_lower_body(self.cx, fid, params, body, self.tenv, "", pos, caps)
    code := self.ins(OpFAddr, TI64, vec[i64](), fid)
    // where a plain function is expected, a literal without captures is one
    match expect {
        Some(et) => {
            match self.cx.types.k(et) {
                TyKFn(ep, er) => {
                    if er == rty && ep.items() == ptys.items() {
                        if caps.len != 0 {
                            ct := self.cx.types.closure(clone(&ptys), rty)
                            self.err(pos, fmt("this closure literal uses the local variable `", caps[0].0, "`, so it cannot be a plain function ", self.tyname(et), " (a code pointer without environment); give the destination the closure type ", self.tyname(ct), " or do not use local variables of the enclosing function"))
                            return val_err()
                        }
                        return self.sval(et, code)
                    }
                }
                _ => {}
            }
        }
        None => {}
    }
    env := self.iconst(TI64, 0)
    if caps.len != 0 {
        env = self.alloca(8 * caps.len, 8)
        for i in 0..addrs.len {
            a := self.add_off(env, 8 * i)
            self.store_raw(a, addrs[i], TI64, AK_PTR)
        }
    }
    ty := self.cx.types.closure(ptys, rty)
    return self.closure_make(ty, code, env)
}
