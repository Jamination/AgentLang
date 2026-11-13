// Checks on the AST that need the types of the function being lowered.
//
// Writes to a copy: `x := v[i]` copies the element. If afterwards fields of `x` are assigned
// and `x` is never used in any other way, the writes are lost; almost always the element
// itself was meant. `lint_copy_writes` finds that pattern for one `:=` statement.

priv struct Use {
    name: str
    // direct field assignments `name.f = e` / `name.f op= e`
    writes: i64
    first: Pos
    field: str
    // every other occurrence of the name
    others: i64
}

// is `e` a place that is copied when read: a field or element of something (not a call)
priv fn is_place(e: *Expr) -> bool {
    match e.k {
        Index(b, _), Field(b, _) => is_root(b)
        _ => false
    }
}

priv fn is_root(e: *Expr) -> bool {
    match e.k {
        Ident(_) => true
        Index(b, _), Field(b, _), Un(Deref, b) => is_root(b)
        _ => false
    }
}

// is `e` the name `n`
priv fn is_name(e: *Expr, n: str) -> bool {
    match e.k {
        Ident(x) => x == n
        _ => false
    }
}

// source text of a place expression (an index that is not a name or number is shown as `..`)
priv fn place_str(e: *Expr) -> str {
    match e.k {
        Ident(n) => ast_plain(n)
        Int(v, _) => fmt(v)
        Field(b, f) => fmt(place_str(b), ".", f)
        Index(b, idx) => {
            parts := vec[str]()
            for i in 0..idx.len {
                parts.push(place_str(&idx[i]))
            }
            fmt(place_str(b), "[", join(parts.items(), ", "), "]")
        }
        Un(Deref, x) => fmt("(*", place_str(x), ")")
        _ => ".."
    }
}

priv fn exprs(u: *Use, es: *Vec[Expr]) -> bool {
    for i in 0..es.len {
        expr(u, &es[i])
    }
    return true
}

priv fn opt(u: *Use, e: Opt[*Expr]) -> bool {
    match e {
        Some(x) => expr(u, x)
        None => true
    }
}

priv fn block(u: *Use, b: *Block) -> bool {
    for i in 0..b.stmts.len {
        stmt(u, &b.stmts[i])
    }
    return true
}

priv fn expr(u: *Use, e: *Expr) -> bool {
    return match e.k {
        Int(_, _), Float(_, _), Str(_), Bool(_), Nil, TypeE(_), Fn(_) => true
        Ident(n) => {
            if n == u.name {
                u.others += 1
            }
            true
        }
        Un(_, x), Field(x, _) => expr(u, x)
        Bin(_, a, b) => {
            expr(u, a)
            expr(u, b)
        }
        Call(c, args), Index(c, args) => {
            expr(u, c)
            exprs(u, &args)
        }
        Slice(b, lo, hi) => {
            expr(u, b)
            opt(u, lo)
            opt(u, hi)
        }
        Lit(t, fields) => {
            expr(u, t)
            for i in 0..fields.len {
                expr(u, &fields[i].1)
            }
            true
        }
        If(c, a, b) => {
            expr(u, c)
            block(u, a)
            block(u, b)
        }
        Tuple(es) => exprs(u, &es)
        Match(sc, arms) => {
            expr(u, sc)
            for i in 0..arms.len {
                opt(u, arms[i].guard)
                block(u, &arms[i].body)
            }
            true
        }
    }
}

priv fn stmt(u: *Use, s: *Stmt) -> bool {
    return match s.k {
        Expr(e) => expr(u, e)
        Let(_, e) => expr(u, e)
        MultiAssign(lhs, e) => {
            exprs(u, &lhs)
            expr(u, e)
        }
        Var(_, _, init) => opt(u, init)
        Assign(lhs, _, rhs) => {
            expr(u, rhs)
            match lhs.k {
                // a direct field assignment `name.f = e`
                Field(b, f) if is_name(b, u.name) => {
                    if u.writes == 0 {
                        u.first = lhs.pos
                        u.field = f
                    }
                    u.writes += 1
                    true
                }
                _ => expr(u, lhs)
            }
        }
        If(c, t, eo) => {
            expr(u, c)
            block(u, t)
            match eo {
                Some(e) => block(u, e)
                None => true
            }
        }
        While(c, body) => {
            expr(u, c)
            block(u, body)
        }
        Loop(b), Block(b), Defer(b) => block(u, b)
        For(f) => {
            expr(u, f.lo)
            opt(u, f.hi)
            opt(u, f.step)
            block(u, f.body)
        }
        Return(e) => opt(u, e)
        Break, Continue, BreakTo(_), ContinueTo(_) => true
        Assert(c, m) => {
            expr(u, c)
            opt(u, m)
        }
        Labeled(_, st) => stmt(u, st)
        // (a nested function does not see the variable)
        Fn(_) => true
        // (replaced by its taken branch before lowering: src/when.al)
        When(_) => true
    }
}

// Statement `i` of `b` has just been lowered. If it is `x := <field or element>` of a struct
// type and the rest of the block only assigns fields of `x`, that is reported.
fn lint_copy_writes(self: *Fx, b: *Block, i: i64) {
    s := &b.stmts[i]
    names, e := match s.k {
        Let(n, x) => (n, x)
        _ => return
    }
    if names.len != 1 || names[0] == "_" || !is_place(e) {
        return
    }
    name := names[0]
    v := match self.lookup(name) {
        Some(v) => v
        None => return
    }
    match self.cx.types.k(v.0) {
        Struct(_) => {}
        _ => return
    }
    u := Use{name: name, first: s.pos}
    for j in i + 1..b.stmts.len {
        stmt(&u, &b.stmts[j])
        if u.others > 0 {
            return
        }
    }
    if u.writes > 0 {
        src := place_str(e)
        plain := ast_plain(name)
        self.err(u.first, fmt("`", plain, "` is a copy of `", src, "` (`:=` copies a struct), so this assignment changes only the copy, and the copy is never read afterwards. To change the original write `", src, ".", u.field, " = ...`, or take a pointer: `", plain, " := &", src, "`"))
    }
}
