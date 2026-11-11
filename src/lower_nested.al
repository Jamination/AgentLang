// Nested functions: `fn name(params) -> R { body }` as a statement of a block, and anonymous
// functions: the expression `fn(params) -> R { body }`.
//
// Both are ordinary functions that happen to be written inside another one. They see
// globals, constants, top-level functions, the type parameters of the enclosing function
// (so they are lowered once per instantiation of it) and the nested functions declared
// before them or around them, but no variable of an enclosing function. Each is therefore a
// plain function value `fn(A) -> R`. In the IR and the symbol table they are `outer.name` and
// `outer.fn@line:col`.
//
// The name of a nested function lives in the scope of its block like a variable
// (`Scope.vars`): the type slot of such an entry is negative, -(index into `Cx.nested`) - 1.
// The body is lowered with an `Fx` of its own whose `parent` is the enclosing one: `lookup`
// continues there, finds the nested functions, and reports a variable as LOWER_NESTED_OUTER.

// a nested or anonymous function
struct NestedFn {
    decl: *FnDecl
    // the name in diagnostics, the IR and the symbol table
    shown: str
    // -1: the declaration has errors (uses of the name are not reported again)
    fid: i64
    ptys: Vec[i64]
    rty: i64
}

// the type slot `lookup` reports for a variable of an enclosing function
const LOWER_NESTED_OUTER = -0x4000000000000000

// The name `name` as seen from a function nested in `p`: a nested function of `p` (or of a
// function around it) is visible, a variable is LOWER_NESTED_OUTER.
fn lower_nested_outer(p: *Fx, name: str) -> Opt[(i64, i64)] {
    fx := p
    while fx != nil {
        for si in fx.scopes.len - 1..=0 by -1 {
            x, ok := fx.scopes[si].vars.get(name)
            if ok {
                if x.0 < 0 {
                    return Some(x)
                }
                return Some((LOWER_NESTED_OUTER, 0))
            }
        }
        fx = fx.parent
    }
    return None
}

// the nested function that the name `n` means here: its index in `cx.nested`, or -1
fn nested_named(self: *Fx, n: str) -> i64 {
    match self.lookup(n) {
        Some(x) => {
            if x.0 < 0 && x.0 != LOWER_NESTED_OUTER {
                return -x.0 - 1
            }
        }
        None => {}
    }
    return -1
}

// the nested function that a method call `x.name(..)` means, or -1
fn nested_method(self: *Fx, name: str) -> i64 {
    if self.cx.nested.len == 0 {
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
    for i in 0..self.cx.nested.len {
        dn := self.cx.nested[i].decl.name
        if len(dn) > n && dn[n] == 1 && dn[..n] == name {
            return self.nested_named(dn)
        }
    }
    return -1
}

// ---------- diagnostics ----------
// "`n` is a variable of the enclosing function": reported once per name; afterwards the name
// is an erroneous local of this function
fn nested_outer_err(self: *Fx, n: str, pos: Pos) {
    owner := ""
    fx := self.parent
    while fx != nil && owner == "" {
        for si in fx.scopes.len - 1..=0 by -1 {
            if fx.scopes[si].vars.has(n) {
                owner = fx.f.name
                break
            }
        }
        fx = fx.parent
    }
    self.err(pos, fmt("`", n, "` is a variable of the enclosing function `", owner, "`", lower_nested_rule(self, n)))
    self.scopes[0].vars.set(n, (T_ERR, self.temp(T_ERR)))
}

// the rule and the way out, for a nested function that uses the variable `n` of its surroundings
fn lower_nested_rule(fx: *Fx, n: str) -> str {
    kind := if find(fx.f.name, ".fn@") >= 0 { "anonymous" } else { "nested" }
    return fmt(": the ", kind, " function `", fx.f.name, "` does not see the variables of the function around it. Pass `", n, "` as a parameter (`&", n, "` if the function must change it); a callback that needs state takes a context argument, like `sort_by(items, ctx, less)`")
}

fn lower_nested_after(a: Pos, b: Pos) -> bool {
    return a.line > b.line || (a.line == b.line && a.col > b.col)
}

// For an unknown name: the note that it is a nested function declared later, or (inside a
// nested function) a variable of an enclosing function that is declared further down; ""
// if neither is the reason.
fn nested_hint(self: *Fx, n: str, pos: Pos) -> str {
    fx := self
    while fx != nil {
        for bi in fx.blocks.len - 1..=0 by -1 {
            b := fx.blocks[bi]
            for i in 0..b.stmts.len {
                s := &b.stmts[i]
                line := 0
                is_fn := false
                match s.k {
                    SKFn(d) => {
                        if d.name == n {
                            line = s.pos.line
                            is_fn = true
                        }
                    }
                    SKLet(names, e) => {
                        if fx != self && contains(&names, n) {
                            line = s.pos.line
                        }
                    }
                    SKVar(name, ty, init) => {
                        if fx != self && name == n {
                            line = s.pos.line
                        }
                    }
                    _ => {}
                }
                if line == 0 {
                    continue
                }
                if !is_fn {
                    return fmt(": `", n, "` is a variable of the enclosing function `", fx.f.name, "` (line ", line, ")", lower_nested_rule(self, n))
                }
                if fx != self {
                    return fmt(": the nested function `", n, "` is declared at line ", line, ", after `", self.f.name, "` (a nested function is visible from its declaration to the end of its block: declare `", n, "` first)")
                }
                if lower_nested_after(s.pos, pos) {
                    return fmt(": the nested function `", n, "` is declared at line ", line, ", after this use (a nested function is visible from its declaration to the end of its block: move it up)")
                }
            }
        }
        fx = fx.parent
    }
    return ""
}

// ---------- declaration ----------
// The function of the declaration `d` (a nested function, or an anonymous one: its name is
// empty): its index in `cx.nested`. It is lowered the first time; a statement or expression
// that is lowered again (a `defer` block on another way out, a loop condition) gets the same
// function. A named one is entered into the innermost scope before its body is lowered, so
// that it can call itself.
fn nested_lower(self: *Fx, d: *FnDecl) -> i64 {
    for i in 0..self.nested_done.len {
        if self.nested_done[i].0 == d {
            return self.nested_done[i].1
        }
    }
    cx := self.cx
    anon := d.name == ""
    idx := cx.nested.len
    self.nested_done.push((d, idx))
    shown := if anon { fmt(self.f.name, ".fn@", d.pos.line, ":", d.pos.col) } else { fmt(self.f.name, ".", ast_plain(d.name)) }
    cx.nested.push(NestedFn{decl: d, shown: shown, fid: -1, ptys: vec[i64](), rty: T_ERR})
    if d.tparams.len != 0 {
        self.err(d.pos, fmt("the nested function `", shown, "` cannot have type parameters of its own (`[", join(d.tparams.items(), ", "), "]`): it may use the type parameters of the enclosing function; a generic function is declared at the top level"))
        return idx
    }
    if !anon && is_some(lower_builtin_type(ast_plain(d.name))) {
        self.err(d.pos, fmt("`", d.name, "` is a builtin type name"))
        return idx
    }
    ptys := vec[i64]()
    for i in 0..d.params.len {
        ptys.push(cx.resolve(&d.params[i].1, &self.tenv))
    }
    rty := T_UNIT
    match d.ret {
        Some(r) => {
            rty = cx.resolve(&r, &self.tenv)
        }
        None => {}
    }
    cx.flush_layout_errors(d.pos)
    if contains(&ptys, T_ERR) || rty == T_ERR {
        return idx
    }
    fid := cx.module.funcs.len
    f := func_new(shown)
    f.noreturn = rty == T_NEVER
    cx.fn_abi(&f, ptys.items(), rty)
    cx.module.funcs.push(f)
    cx.fn_sigs.push((clone(&ptys), rty))
    cx.nested[idx].fid = fid
    cx.nested[idx].ptys = ptys
    cx.nested[idx].rty = rty
    if !anon {
        self.scopes[self.scopes.len - 1].vars.set(d.name, (-(idx + 1), 0))
    }
    lower_fn_lower_body(cx, fid, &d.params, &d.body, self.tenv, shown, d.pos, self)
    return idx
}

// the statement `fn name(params) -> R { body }`
fn nested_fn(self: *Fx, d: *FnDecl) {
    top := self.scopes.len - 1
    if self.scopes[top].vars.has(d.name) {
        self.err(d.pos, fmt("`", d.name, "` is already declared in this scope: a nested function needs a name that no variable or other nested function of its block has (nested functions cannot be overloaded)"))
        return
    }
    idx := self.nested_lower(d)
    self.scopes[top].vars.set(d.name, (-(idx + 1), 0))
}

// ---------- uses ----------
// `name(args)` or `recv.name(args)` of the nested function `idx`
fn call_nested(self: *Fx, idx: i64, recv: Opt[Val], args: []Expr, expect: Opt[i64], pos: Pos) -> Val {
    if self.cx.nested[idx].fid < 0 {
        lower_call_eval_all(self, args)
        return val_err()
    }
    return self.call_fn(self.cx.nested[idx].decl, -1, idx, None, recv, args, expect, pos, lower_call_no_pre())
}

// the nested or anonymous function `idx` as a value
fn nested_value(self: *Fx, idx: i64) -> Val {
    nf := self.cx.nested[idx]
    if nf.fid < 0 {
        return val_err()
    }
    ty := self.cx.types.intern(TyKFn(clone(&nf.ptys), nf.rty))
    v := self.ins(OpFAddr, TI64, vec[i64](), nf.fid)
    return self.sval(ty, v)
}

// a local name that is not a variable of this function, used as a value: a nested function,
// or a variable of an enclosing function
fn nested_ident(self: *Fx, n: str, slot: i64, pos: Pos) -> Val {
    if slot == LOWER_NESTED_OUTER {
        self.nested_outer_err(n, pos)
        return val_err()
    }
    return self.nested_value(-slot - 1)
}
